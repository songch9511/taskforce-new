import { randomUUID } from "node:crypto";
import { readdir } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { agentSessionStatusSchema, agentTaskStateSchema } from "@/lib/api/contract";
import { RUN_KINDS } from "@/lib/execution/types";

import { additiveFixtures, type ExecutionAdditiveDb, type FreshDb, type Rows } from "./execution-additive-contract.scenarios";
import { supabaseSchemaScripts } from "./local-supabase";

// 0.2.0 에이전트 게이트웨이 저장 계약 (20261113000000_agent_gateway_core, 구현 계획 D1a): 저장 계약만 시험한다 — 표 넷(bridges · agent_connections · agent_sessions · agent_tasks)의
// 열 · CHECK · 복합 외래키 · 부분 unique · RLS · 삭제 전파, execution_runs 새 열, execution_events의 type 'agent' + 사건 봉투 열, 그리고 실행 입구(create_run · append_step ·
// execution_tools · execution_controls)가 바뀌지 않은 것. 같은 시나리오를 PGlite(tests/db/agent-gateway-core.test.ts)와 실제 Postgres(tests/pg/agent-gateway-core.test.ts)에서 돌린다.
// 연결 둘이 겹치는 경합(T8)은 실제 Postgres 파일에만 있다.

export type AgentGatewayDb = ExecutionAdditiveDb;
export const D1A_MIGRATION = "20261113000000_agent_gateway_core.sql";

/** 계약 v3 3.4 · 런타임 계약 5장의 값. 테스트의 기대값은 마이그레이션이 아니라 이 목록이다 */
export const TASK_STATES = ["dispatched", "accepted", "running", "awaiting_answer", "idle", "completed", "failed", "cancelled", "unreachable"];
// unreachable도 진행 중으로 센다: 끊긴 작업이 있는 동안 세션은 reconcile을 기다린다 (계약 v3 3.2-5)
export const IN_PROGRESS_STATES = ["dispatched", "accepted", "running", "awaiting_answer", "unreachable"];
export const SESSION_STATUSES = ["bound", "external", "unreachable", "closed"];
export const AGENT_TABLES = ["bridges", "agent_connections", "agent_sessions", "agent_tasks"];

export const AGENT_QUESTION = {
  question_key: ["00000000-0000-0000-0000-000000000001", "q-1"],
  provider_request_id: "q-1", kind: "input", structured: true,
  questions: [{ id: "file", header: "파일", text: "어느 파일부터 볼까요?", options: [], multi_select: false, allow_other: true, secret: false }],
  asked_at: "2026-10-13T12:00:00Z",
};

/** 에러 메시지가 정규식과 맞는지 (PGlite와 실제 Postgres 모두 같은 문구) */
const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 */
export function agentGatewayFixtures(db: () => AgentGatewayDb) {
  const base = additiveFixtures(db);
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);

  /** 열 이름 → 값. 객체 · 배열은 jsonb로 보낸다 (null은 그대로 null) */
  async function insertRow(table: string, values: Record<string, unknown>): Promise<string> {
    const columns = Object.keys(values);
    const isJson = (v: unknown) => v !== null && typeof v === "object";
    const params = columns.map((column) => (isJson(values[column]) ? JSON.stringify(values[column]) : values[column]));
    const placeholders = columns.map((column, i) => (isJson(values[column]) ? `$${i + 1}::jsonb` : `$${i + 1}`));
    return String((await base.one(`insert into public.${table} (${columns.join(", ")}) values (${placeholders.join(", ")}) returning id`, params)).id);
  }
  async function updateRow(table: string, id: string, values: Record<string, unknown>) {
    const columns = Object.keys(values);
    const isJson = (v: unknown) => v !== null && typeof v === "object";
    const params = columns.map((column) => (isJson(values[column]) ? JSON.stringify(values[column]) : values[column]));
    const set = columns.map((column, i) => `${column} = ${isJson(values[column]) ? `$${i + 2}::jsonb` : `$${i + 2}`}`).join(", ");
    return q(`update public.${table} set ${set} where id = $1 returning id`, [id, ...params]);
  }

  const f = {
    ...base,
    q,
    insertRow,
    updateRow,
    bridge: (userId: string, o: Record<string, unknown> = {}) => insertRow("bridges", { user_id: userId, device_ref: randomUUID(), ...o }),
    agentConnection: (userId: string, bridgeId: string | null = null, o: Record<string, unknown> = {}) =>
      insertRow("agent_connections", { user_id: userId, adapter: "agent:claude-code", bridge_id: bridgeId, ...o }),
    session: (userId: string, connectionId: string, o: Record<string, unknown> = {}) =>
      insertRow("agent_sessions", { user_id: userId, connection_id: connectionId, external_session_id: randomUUID(), workspace_ref: "ws-1", ...o }),
    message: (userId: string, conversationId: string, seq = 1) =>
      insertRow("conversation_messages", { user_id: userId, conversation_id: conversationId, seq, role: "user", client_message_id: randomUUID(), text: "이어서 해 줘" }),
    /** goal agent run은 create_run이 아직 만들지 못한다(입구는 D1c): 서버가 직접 넣듯 넣는다. 정책은 사용자 정책 하나 */
    async agentRun(userId: string, actionId: string, o: Record<string, unknown> = {}) {
      await q(`insert into public.execution_policies (user_id) values ($1) on conflict (user_id) do nothing`, [userId]);
      const policy = String((await base.one(`select id from public.execution_policies where user_id = $1`, [userId])).id);
      return insertRow("execution_runs", { user_id: userId, action_id: actionId, policy_id: policy, goal: "agent", request: "대화", kind: "conversation", ...o });
    },
    task: (userId: string, runId: string, sessionId: string, o: Record<string, unknown> = {}) => {
      const id = randomUUID();
      return insertRow("agent_tasks", { id, user_id: userId, run_id: runId, agent_session_id: sessionId, ...o,
        ...(o.pending_question === AGENT_QUESTION ? { pending_question: { ...AGENT_QUESTION, question_key: [o.id ?? id, AGENT_QUESTION.provider_request_id] } } : {}),
      });
    },
    /** 그 run의 단계 하나 (대화 run은 create_run이 첫 단계를 만들지 않아 직접 넣는다). 작업의 step_id는 자기 run의 단계여야 한다(서버 규칙, D1c) */
    step: (userId: string, runId: string, seq = 1) =>
      insertRow("execution_steps", { user_id: userId, run_id: runId, seq, kind: "agent_dispatch", provider: "agent:claude-code", tool: "dispatch", purpose: "맡기기" }),
    /** 에이전트 사건 한 줄 (서버가 bridge 사건을 받아 쓰듯). id는 execution_events의 identity */
    agentEvent: (userId: string, runId: string, externalEventId: string | null, o: Record<string, unknown> = {}) =>
      insertRow("execution_events", { user_id: userId, run_id: runId, type: "agent", external_event_id: externalEventId, ...o }),
    /** 사용자 한 명의 에이전트 세계: bridge → 연결 → 세션(처음 맡긴 이슈) → 대화 run → 작업(idle) + 사건 */
    async world() {
      const user = await base.user();
      const action = await base.action(user);
      const bridge = await f.bridge(user);
      const connection = await f.agentConnection(user, bridge);
      const session = await f.session(user, connection, { bound_action_id: action });
      const run = await f.agentRun(user, action, { agent_session_id: session });
      const taskRun = await base.run(user, action);
      const step = await f.step(user, run); // 작업의 step_id는 작업의 run(대화 run)의 단계다 — 다른 run의 단계를 가리키는 행은 유효한 행이 아니다
      const conversation = await base.conversation(user);
      const message = await f.message(user, conversation);
      const task = await f.task(user, run, session, { step_id: step, message_id: message, turn_seq: 1, state: "idle" });
      const event = await f.agentEvent(user, run, `evt-${randomUUID()}`, { bridge_id: bridge, turn_seq: 1 });
      return { user, action, bridge, connection, session, run, taskRun, step, conversation, message, task, event };
    },
  };
  return f;
}

export function agentGatewayCoreTests(db: () => AgentGatewayDb) {
  const f = agentGatewayFixtures(db);
  const q = f.q;
  const count = (table: string, where = "true", params: unknown[] = []) => f.count(`select 1 from public.${table} where ${where}`, params);

  // ───────────────────────── 0) 열의 모양 ─────────────────────────
  describe("열의 모양 (저장 계약)", () => {
    it("새 표 넷의 열: 형 · null 허용 · 기본값", async () => {
      const rows = await q(
        `select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns
          where table_schema = 'public' and table_name = any ($1) order by table_name, ordinal_position`,
        [AGENT_TABLES],
      );
      const shape = rows.map((r) => `${r.table_name}.${r.column_name} ${r.data_type} ${r.is_nullable === "YES" ? "null" : "not null"}${r.column_default ? ` = ${r.column_default}` : ""}`);
      expect(shape).toEqual([
        "agent_connections.id uuid not null = gen_random_uuid()",
        "agent_connections.user_id uuid not null = auth.uid()",
        "agent_connections.adapter text not null",
        "agent_connections.bridge_id uuid null",
        "agent_connections.device_ref text null",
        "agent_connections.status text not null = 'active'::text",
        "agent_connections.created_at timestamp with time zone not null = now()",
        "agent_connections.updated_at timestamp with time zone not null = now()",
        "agent_sessions.id uuid not null = gen_random_uuid()",
        "agent_sessions.user_id uuid not null = auth.uid()",
        "agent_sessions.connection_id uuid not null",
        "agent_sessions.external_session_id text not null",
        "agent_sessions.workspace_ref text not null",
        "agent_sessions.display_name text not null = ''::text",
        "agent_sessions.status text not null = 'bound'::text",
        "agent_sessions.bound_action_id uuid null",
        "agent_sessions.last_turn_seq integer not null = 0",
        "agent_sessions.last_event_seq bigint not null = 0",
        "agent_sessions.last_seen_at timestamp with time zone null",
        "agent_sessions.created_at timestamp with time zone not null = now()",
        "agent_sessions.updated_at timestamp with time zone not null = now()",
        "agent_tasks.id uuid not null = gen_random_uuid()",
        "agent_tasks.user_id uuid not null = auth.uid()",
        "agent_tasks.run_id uuid not null",
        "agent_tasks.step_id uuid null",
        "agent_tasks.agent_session_id uuid not null",
        "agent_tasks.message_id uuid null",
        "agent_tasks.external_task_id text null",
        "agent_tasks.turn_seq integer null",
        "agent_tasks.state text not null = 'dispatched'::text",
        "agent_tasks.last_live_state text null",
        "agent_tasks.directive_version integer not null = 1",
        "agent_tasks.result_revision integer not null = 0",
        "agent_tasks.expected_result_revision integer not null = 1",
        "agent_tasks.pending_question jsonb null",
        "agent_tasks.cancel_requested_at timestamp with time zone null",
        "agent_tasks.last_event_seq bigint not null = 0",
        "agent_tasks.last_seen_at timestamp with time zone null",
        "agent_tasks.result_refs jsonb not null = '[]'::jsonb",
        "agent_tasks.created_at timestamp with time zone not null = now()",
        "agent_tasks.updated_at timestamp with time zone not null = now()",
        "agent_tasks.answered_question jsonb null",
        "agent_tasks.abandoned_question jsonb null",
        "bridges.id uuid not null = gen_random_uuid()",
        "bridges.user_id uuid not null = auth.uid()",
        "bridges.device_ref text not null",
        "bridges.status text not null = 'active'::text",
        "bridges.capabilities jsonb not null = '{}'::jsonb",
        "bridges.last_heartbeat_at timestamp with time zone null",
        "bridges.revoked_at timestamp with time zone null",
        "bridges.created_at timestamp with time zone not null = now()",
        "bridges.updated_at timestamp with time zone not null = now()",
        "bridges.heartbeat_result jsonb null",
        "bridges.secret_hash text null",
        "bridges.secret_rotated_at timestamp with time zone null",
        "bridges.app_version text null",
        "bridges.device_name text null",
      ]);
      // 원문 비밀값은 금지; 장치 자격의 hash와 회전 시각만 허용한다.
      expect(rows.filter((r) => /email|token|secret|password|account|login/i.test(String(r.column_name))).map(r => `${r.table_name}.${r.column_name}`)).toEqual(["bridges.secret_hash", "bridges.secret_rotated_at"]);
    });

    it("execution_runs · execution_events 새 열: 형 · null 허용 · 기본값", async () => {
      const rows = await q(
        `select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns
          where table_schema = 'public' and (
            (table_name = 'execution_runs' and column_name in ('kind', 'agent_session_id', 'reviewed_turn_seq'))
            or (table_name = 'execution_events' and column_name in ('external_event_id', 'external_seq', 'directive_version', 'turn_seq', 'bridge_id', 'payload')))
          order by table_name, column_name`,
      );
      expect(rows.map((r) => `${r.table_name}.${r.column_name} ${r.data_type} ${r.is_nullable === "YES" ? "null" : "not null"}${r.column_default ? ` = ${r.column_default}` : ""}`)).toEqual([
        "execution_events.bridge_id uuid null",
        "execution_events.directive_version integer null",
        "execution_events.external_event_id text null",
        "execution_events.external_seq bigint null",
        "execution_events.payload jsonb null",
        "execution_events.turn_seq integer null",
        "execution_runs.agent_session_id uuid null",
        "execution_runs.kind text not null = 'task'::text",
        "execution_runs.reviewed_turn_seq integer not null = 0",
      ]);
    });

    it("지금 코드가 만든 run은 새 열이 기본값이다: kind task, 세션 없음, 검토한 턴 0 (create_run은 그대로)", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      expect(await f.one(`select goal, kind, agent_session_id, reviewed_turn_seq from public.execution_runs where id = $1`, [run])).toEqual({
        goal: "draft",
        kind: "task",
        agent_session_id: null,
        reviewed_turn_seq: 0,
      });
      // create_run이 남긴 사건은 새 열이 모두 null이다
      const events = await q(`select type, external_event_id, external_seq, directive_version, turn_seq, bridge_id, payload from public.execution_events where run_id = $1`, [run]);
      expect(events.length).toBeGreaterThan(0);
      for (const event of events) expect(event).toMatchObject({ external_event_id: null, external_seq: null, directive_version: null, turn_seq: null, bridge_id: null, payload: null });
    });

    it("새 열 기본값: 세션 · 작업을 최소 열로 만들면 계약의 기본값이 들어간다", async () => {
      const w = await f.world();
      const idle = await f.one(`select state, directive_version, result_revision, expected_result_revision, last_event_seq::int as last_event_seq, result_refs, pending_question, last_live_state from public.agent_tasks where id = $1`, [w.task]);
      expect(idle).toMatchObject({ state: "idle", directive_version: 1, result_revision: 0, expected_result_revision: 1, last_event_seq: 0, result_refs: [], pending_question: null, last_live_state: null });
      expect(await f.one(`select status, display_name, last_turn_seq, last_event_seq::int as last_event_seq from public.agent_sessions where id = $1`, [w.session])).toEqual({
        status: "bound",
        display_name: "",
        last_turn_seq: 0,
        last_event_seq: 0,
      });
      expect(await f.one(`select status, capabilities, last_heartbeat_at, revoked_at from public.bridges where id = $1`, [w.bridge])).toEqual({
        status: "active",
        capabilities: {},
        last_heartbeat_at: null,
        revoked_at: null,
      });
      expect(await f.one(`select status, device_ref from public.agent_connections where id = $1`, [w.connection])).toEqual({ status: "active", device_ref: null });
    });

    it("updated_at 트리거: 네 표 모두 갱신하면 updated_at이 현재로 바뀐다 (만들 때 넣은 옛 시각은 갱신 때 덮어쓴다)", async () => {
      const old = "2020-01-01T00:00:00Z";
      const user = await f.user();
      const action = await f.action(user);
      const bridge = await f.bridge(user, { updated_at: old });
      const connection = await f.agentConnection(user, bridge, { updated_at: old });
      const session = await f.session(user, connection, { updated_at: old });
      const run = await f.agentRun(user, action, { agent_session_id: session });
      const task = await f.task(user, run, session, { state: "idle", updated_at: old });
      const targets: [string, string, Record<string, unknown>][] = [
        ["bridges", bridge, { last_heartbeat_at: new Date().toISOString() }],
        ["agent_connections", connection, { status: "error" }],
        ["agent_sessions", session, { display_name: "이름" }],
        ["agent_tasks", task, { result_revision: 1 }],
      ];
      for (const [table, id, change] of targets) {
        expect(String((await f.one(`select updated_at from public.${table} where id = $1`, [id])).updated_at), table).toMatch(/2020/);
        await f.updateRow(table, id, change);
        expect(String((await f.one(`select updated_at from public.${table} where id = $1`, [id])).updated_at), table).not.toMatch(/2020/);
      }
    });
  });

  // ───────────────────────── 값 목록 (TS ↔ DB) ─────────────────────────
  describe("값 목록: 코드의 값 상수와 DB CHECK가 같다 (한 쪽만 넓어지지 않는다)", () => {
    const checkValues = async (table: string, column: string) => {
      const row = await f.one(
        `select pg_get_constraintdef(c.oid) as def from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
          where c.conrelid = ('public.' || $1)::regclass and c.contype = 'c' and array_length(c.conkey, 1) = 1 and a.attname = $2`,
        [table, column],
      );
      return [...String(row.def).matchAll(/'([a-z_]+)'/g)].map((m) => m[1]).sort();
    };

    it("agent_tasks.state = agentTaskStateSchema(idle 포함), agent_sessions.status = agentSessionStatusSchema, execution_runs.kind = RUN_KINDS", async () => {
      expect([...agentTaskStateSchema.options]).toEqual(TASK_STATES);
      expect([...agentSessionStatusSchema.options]).toEqual(SESSION_STATUSES);
      expect(await checkValues("agent_tasks", "state")).toEqual([...agentTaskStateSchema.options].sort());
      expect(await checkValues("agent_sessions", "status")).toEqual([...agentSessionStatusSchema.options].sort());
      expect(await checkValues("execution_runs", "kind")).toEqual([...RUN_KINDS].sort());
      // last_live_state는 열린 상태 넷뿐이다 (idle · 끝 상태 · unreachable은 끊김의 직전 상태가 아니다)
      expect(await checkValues("agent_tasks", "last_live_state")).toEqual(["accepted", "awaiting_answer", "dispatched", "running"]);
      // 사건 type은 기존 셋 + agent
      expect(await checkValues("execution_events", "type")).toEqual(["agent", "hold", "run", "step"]);
    });
  });

  // ───────────────────────── T1) RLS ─────────────────────────
  describe("T1 RLS: 앱은 자기 행만 읽고 쓰지 못한다 (owner_all 정책 + select 권한)", () => {
    it("네 표 모두: 정책은 owner_all 하나, RLS 켜짐, 권한은 authenticated select뿐(anon 없음), service role은 모두", async () => {
      for (const table of AGENT_TABLES) {
        expect(await q(`select policyname, cmd, roles::text as roles from pg_policies where schemaname = 'public' and tablename = $1`, [table]), table).toEqual([
          { policyname: "owner_all", cmd: "ALL", roles: "{authenticated}" },
        ]);
        expect(await f.one(`select relrowsecurity from pg_class where oid = ('public.' || $1)::regclass`, [table]), table).toEqual({ relrowsecurity: true });
        const privilege = async (role: string, kind: string) => (await f.one(`select has_table_privilege($1, ('public.' || $2)::regclass, $3) as ok`, [role, table, kind])).ok;
        for (const kind of ["select"]) expect(await privilege("authenticated", kind), `${table} authenticated ${kind}`).toBe(table !== "bridges");
        if (table === "bridges") {
          const columns = await q(`select column_name, has_column_privilege('authenticated', 'public.bridges', column_name, 'select') as readable from information_schema.columns where table_schema='public' and table_name='bridges'`);
          for (const column of columns) expect(column.readable, String(column.column_name)).toBe(!["secret_hash", "heartbeat_result"].includes(String(column.column_name)));
        }
        for (const kind of ["insert", "update", "delete", "truncate", "references", "trigger"]) expect(await privilege("authenticated", kind), `${table} authenticated ${kind}`).toBe(false);
        for (const kind of ["select", "insert", "update", "delete", "truncate", "references", "trigger"]) expect(await privilege("anon", kind), `${table} anon ${kind}`).toBe(false);
        for (const kind of ["select", "insert", "update", "delete"]) expect(await privilege("service_role", kind), `${table} service_role ${kind}`).toBe(true);
      }
    });

    it("네 표 모두: 다른 사용자의 행은 0행이고 자기 행만 보인다. 쓰기(insert · update · delete)는 권한이 없다. 익명은 읽지도 못한다", async () => {
      const [alice, bob] = [await f.world(), await f.world()];
      const rows: Record<string, [string, string]> = {
        bridges: [alice.bridge, bob.bridge],
        agent_connections: [alice.connection, bob.connection],
        agent_sessions: [alice.session, bob.session],
        agent_tasks: [alice.task, bob.task],
      };
      await db().asUser(alice.user, async () => {
        for (const table of AGENT_TABLES) {
          expect(await q(`select id, user_id from public.${table}`), table).toEqual([{ id: rows[table][0], user_id: alice.user }]);
          expect(await q(`select id from public.${table} where id = $1`, [rows[table][1]]), table).toEqual([]);
          await rejects(q(`insert into public.${table} (user_id) values ($1)`, [alice.user]), /permission denied/);
          await rejects(q(`update public.${table} set updated_at = now() where id = $1`, [rows[table][0]]), /permission denied/);
          await rejects(q(`delete from public.${table} where id = $1`, [rows[table][0]]), /permission denied/);
        }
      });
      await db().asUser(bob.user, async () => {
        for (const table of AGENT_TABLES) expect(await q(`select id from public.${table} where id = $1`, [rows[table][0]]), table).toEqual([]);
      });
      await q(`set role anon`);
      try {
        for (const table of AGENT_TABLES) await rejects(q(`select * from public.${table}`), /permission denied/);
      } finally {
        await q(`reset role`);
      }
      // 거절된 쓰기는 아무것도 바꾸지 않았다
      for (const table of AGENT_TABLES) expect(await count(table, "user_id = $1", [alice.user]), table).toBe(1);
    });

    it("execution_runs의 새 열은 RLS 그대로다(내 run만 읽고 쓰기 권한 없음). execution_events(사건 봉투 · payload)는 앱이 읽지도 못한다", async () => {
      const [alice, bob] = [await f.world(), await f.world()];
      await db().asUser(alice.user, async () => {
        expect(await q(`select id, kind, agent_session_id, reviewed_turn_seq from public.execution_runs where kind = 'conversation'`)).toEqual([
          { id: alice.run, kind: "conversation", agent_session_id: alice.session, reviewed_turn_seq: 0 },
        ]);
        expect(await q(`select id from public.execution_runs where id = $1`, [bob.run])).toEqual([]);
        await rejects(q(`update public.execution_runs set reviewed_turn_seq = 5 where id = $1`, [alice.run]), /permission denied/);
        await rejects(q(`update public.execution_runs set agent_session_id = null where id = $1`, [alice.run]), /permission denied/);
        await rejects(q(`select external_event_id, payload from public.execution_events`), /permission denied/);
      });
      expect(await f.one(`select reviewed_turn_seq from public.execution_runs where id = $1`, [alice.run])).toEqual({ reviewed_turn_seq: 0 });
    });
  });

  // ───────────────────────── T2) 복합 외래키 ─────────────────────────
  describe("T2 복합 외래키: 남의 행 · 없는 행을 가리키지 못하고 내 것과 null은 된다", () => {
    it("agent_connections.bridge_id · agent_sessions.connection_id · bound_action_id", async () => {
      const [alice, bob] = [await f.world(), await f.world()];
      await rejects(f.agentConnection(alice.user, bob.bridge, { adapter: "agent:codex" }), /agent_connections_bridge_fkey/);
      await rejects(f.agentConnection(alice.user, randomUUID()), /agent_connections_bridge_fkey/);
      await rejects(f.session(alice.user, bob.connection), /agent_sessions_connection_fkey/);
      await rejects(f.session(alice.user, randomUUID()), /agent_sessions_connection_fkey/);
      await rejects(f.session(alice.user, alice.connection, { bound_action_id: bob.action }), /agent_sessions_bound_action_fkey/);
      await rejects(f.session(alice.user, alice.connection, { bound_action_id: randomUUID() }), /agent_sessions_bound_action_fkey/);
      // 갱신으로 옮겨도 같다
      await rejects(f.updateRow("agent_connections", alice.connection, { bridge_id: bob.bridge, adapter: "agent:codex" }), /agent_connections_bridge_fkey/);
      await rejects(f.updateRow("agent_sessions", alice.session, { bound_action_id: bob.action }), /agent_sessions_bound_action_fkey/);
      // 내 것과 null은 된다
      await f.agentConnection(alice.user, alice.bridge, { adapter: "agent:codex" });
      await f.agentConnection(alice.user, null);
      await f.session(alice.user, alice.connection, { bound_action_id: alice.action });
      await f.session(alice.user, alice.connection, { bound_action_id: null });
    });

    it("agent_tasks.run_id · step_id · agent_session_id · message_id", async () => {
      const [alice, bob] = [await f.world(), await f.world()];
      const own = (o: Record<string, unknown>) => f.task(alice.user, alice.run, alice.session, { state: "idle", ...o });
      await rejects(f.task(alice.user, bob.run, alice.session, { state: "idle" }), /agent_tasks_run_fkey/);
      await rejects(f.task(alice.user, randomUUID(), alice.session, { state: "idle" }), /agent_tasks_run_fkey/);
      await rejects(own({ step_id: bob.step }), /agent_tasks_step_fkey/);
      await rejects(own({ step_id: randomUUID() }), /agent_tasks_step_fkey/);
      await rejects(f.task(alice.user, alice.run, bob.session, { state: "idle" }), /agent_tasks_session_fkey/);
      await rejects(f.task(alice.user, alice.run, randomUUID(), { state: "idle" }), /agent_tasks_session_fkey/);
      await rejects(own({ message_id: bob.message }), /agent_tasks_message_fkey/);
      await rejects(own({ message_id: randomUUID() }), /agent_tasks_message_fkey/);
      // 갱신으로 옮겨도 같다
      await rejects(f.updateRow("agent_tasks", alice.task, { run_id: bob.run }), /agent_tasks_run_fkey/);
      await rejects(f.updateRow("agent_tasks", alice.task, { agent_session_id: bob.session, turn_seq: null }), /agent_tasks_session_fkey/);
      await rejects(f.updateRow("agent_tasks", alice.task, { message_id: bob.message }), /agent_tasks_message_fkey/);
      // 내 것과 null은 된다
      await own({ step_id: alice.step, message_id: alice.message });
      await own({ step_id: null, message_id: null });
    });

    it("execution_runs.agent_session_id · execution_events.bridge_id", async () => {
      const [alice, bob] = [await f.world(), await f.world()];
      await rejects(f.updateRow("execution_runs", alice.run, { agent_session_id: bob.session }), /execution_runs_agent_session_fkey/);
      await rejects(f.updateRow("execution_runs", alice.run, { agent_session_id: randomUUID() }), /execution_runs_agent_session_fkey/);
      await rejects(f.agentRun(alice.user, await f.action(alice.user), { agent_session_id: bob.session }), /execution_runs_agent_session_fkey/);
      await rejects(f.agentEvent(alice.user, alice.run, "evt-x", { bridge_id: bob.bridge }), /execution_events_bridge_fkey/);
      await rejects(f.agentEvent(alice.user, alice.run, "evt-x", { bridge_id: randomUUID() }), /execution_events_bridge_fkey/);
      await rejects(f.updateRow("execution_events", alice.event, { bridge_id: bob.bridge }), /execution_events_bridge_fkey/);
      // 내 것과 null은 된다
      await f.updateRow("execution_runs", alice.run, { agent_session_id: alice.session });
      await f.updateRow("execution_runs", alice.run, { agent_session_id: null });
      await f.agentEvent(alice.user, alice.run, "evt-own", { bridge_id: alice.bridge });
      await f.agentEvent(alice.user, alice.run, "evt-none", { bridge_id: null });
    });
  });

  // ───────────────────────── T3) CHECK ─────────────────────────
  describe("T3 CHECK", () => {
    it("bridges: device_ref 1–200자 · status · capabilities 객체 · revoked ↔ revoked_at · 사용자별 device_ref 유일", async () => {
      const user = await f.user();
      for (const bad of ["", "x".repeat(201)]) await rejects(f.bridge(user, { device_ref: bad }), /bridges_device_ref_check/);
      await f.bridge(user, { device_ref: "x" });
      await f.bridge(user, { device_ref: "y".repeat(200) });
      for (const bad of ["paused", "Active", "", "error"]) await rejects(f.bridge(user, { status: bad }), /bridges_status_check/);
      // 문자열 · 숫자는 JSON 값 그대로 보낸다 (jsonb 열)
      for (const bad of [[], ["a"], '"text"', "1", "true"]) await rejects(f.bridge(user, { capabilities: bad }), /bridges_capabilities_check/);
      await rejects(f.bridge(user, { capabilities: null }), /not-null constraint/);
      await f.bridge(user, { capabilities: { "agent:claude-code": { installed: true, version: "2.1.241" } } });

      // revoked ↔ revoked_at: 한 쪽만 있으면 거절
      const now = new Date().toISOString();
      await rejects(f.bridge(user, { status: "revoked" }), /bridges_revoked_consistent/);
      await rejects(f.bridge(user, { status: "active", revoked_at: now }), /bridges_revoked_consistent/);
      const revoked = await f.bridge(user, { status: "revoked", revoked_at: now });
      expect(await f.one(`select status from public.bridges where id = $1`, [revoked])).toEqual({ status: "revoked" });
      const live = await f.bridge(user);
      await rejects(f.updateRow("bridges", live, { status: "revoked" }), /bridges_revoked_consistent/);
      await f.updateRow("bridges", live, { status: "revoked", revoked_at: now });
      await rejects(f.updateRow("bridges", live, { status: "active" }), /bridges_revoked_consistent/);
      await f.updateRow("bridges", live, { status: "active", revoked_at: null });

      // 사용자별 device_ref 유일: 같은 사용자 둘은 거절, 다른 사용자는 된다
      const device = randomUUID();
      await f.bridge(user, { device_ref: device });
      await rejects(f.bridge(user, { device_ref: device }), /bridges_user_id_device_ref_key/);
      await f.bridge(await f.user(), { device_ref: device });
    });

    it("agent_connections: adapter는 registry 문자열(agent:소문자 · 숫자 · _ · -, 64자 이하), status, device_ref 200자 이하", async () => {
      const user = await f.user();
      for (const ok of ["agent:claude-code", "agent:codex", "agent:a", "agent:0x", "agent:my_agent-2", "agent:" + "a".repeat(58)]) {
        await f.agentConnection(user, null, { adapter: ok });
      }
      const invalid = [
        "claude-code", "", "agent:", "agent:-x", "agent:_x", "Agent:codex", "agent:Codex", "agent:co dex", "agent:codex\n", "agent:codex/x", "agent:é", "agent: codex",
        "agent:" + "a".repeat(59),
      ];
      for (const bad of invalid) await rejects(f.agentConnection(user, null, { adapter: bad }), /agent_connections_adapter_check/);
      await rejects(f.agentConnection(user, null, { adapter: null }), /not-null constraint/);
      for (const ok of ["active", "error", "revoked"]) await f.agentConnection(user, null, { status: ok });
      for (const bad of ["bound", "paused", "", "Active"]) await rejects(f.agentConnection(user, null, { status: bad }), /agent_connections_status_check/);
      await f.agentConnection(user, null, { device_ref: "d".repeat(200) });
      await f.agentConnection(user, null, { device_ref: null });
      await rejects(f.agentConnection(user, null, { device_ref: "d".repeat(201) }), /agent_connections_device_ref_check/);
    });

    it("agent_sessions: external_session_id 1–200자 · workspace_ref 1–500자 · display_name 200자 이하 · status · 순서 번호는 0 이상 · 연결 안에서 외부 세션 유일", async () => {
      const w = await f.world();
      const make = (o: Record<string, unknown>) => f.session(w.user, w.connection, o);
      for (const bad of ["", "x".repeat(201)]) await rejects(make({ external_session_id: bad }), /agent_sessions_external_session_id_check/);
      await make({ external_session_id: "x".repeat(200) });
      for (const bad of ["", "x".repeat(501)]) await rejects(make({ workspace_ref: bad }), /agent_sessions_workspace_ref_check/);
      await make({ workspace_ref: "x".repeat(500) });
      await rejects(make({ display_name: "x".repeat(201) }), /agent_sessions_display_name_check/);
      await make({ display_name: "x".repeat(200) });
      await rejects(make({ display_name: null }), /not-null constraint/);
      for (const ok of SESSION_STATUSES) await make({ status: ok });
      for (const bad of ["active", "Bound", "", "idle", "revoked"]) await rejects(make({ status: bad }), /agent_sessions_status_check/);
      await rejects(make({ last_turn_seq: -1 }), /agent_sessions_last_turn_seq_check/);
      await rejects(make({ last_event_seq: -1 }), /agent_sessions_last_event_seq_check/);
      await make({ last_turn_seq: 7, last_event_seq: 9_000_000_000 });
      // 같은 연결의 같은 외부 세션은 하나, 다른 연결이면 된다
      await rejects(make({ external_session_id: "dup" }).then(() => make({ external_session_id: "dup" })), /agent_sessions_connection_id_external_session_id_key/);
      await f.session(w.user, await f.agentConnection(w.user), { external_session_id: "dup" });
    });

    it("agent_tasks: state 아홉 값(idle 포함) · last_live_state(열린 상태 넷, unreachable이면 필수) · 번호 · jsonb 모양", async () => {
      const w = await f.world();
      // 상태마다 새 세션: 세션당 진행 중 턴은 하나라서(T5) 같은 세션에 진행 중 상태를 겹쳐 만들지 않는다
      const make = async (o: Record<string, unknown>) => f.task(w.user, w.run, await f.session(w.user, w.connection), o);
      for (const ok of TASK_STATES) await make({ state: ok, pending_question: ok === "awaiting_answer" ? AGENT_QUESTION : null, last_live_state: ok === "unreachable" ? "running" : null });
      for (const bad of ["done", "Idle", "", "waiting", "stopped", "queued"]) await rejects(make({ state: bad }), /agent_tasks_state_check/);
      await rejects(make({ state: null }), /not-null constraint/);
      // idle은 허용된다 (턴의 끝, completed가 아니다)
      expect(await f.one(`select state from public.agent_tasks where id = $1`, [await make({ state: "idle" })])).toEqual({ state: "idle" });

      // last_live_state: unreachable 직전 상태 — 열린 상태 넷(dispatched · accepted · running · awaiting_answer)만. idle · 끝 상태 · unreachable은 거절
      // (런타임 계약 5장: 열린 상태만 unreachable이 된다. AC-21: idle 작업은 끊긴 것으로 바꾸지 않는다)
      for (const ok of ["dispatched", "accepted", "running", "awaiting_answer"]) await make({ state: "unreachable", last_live_state: ok });
      for (const bad of ["idle", "completed", "failed", "cancelled", "unreachable", "done", "", "Running"]) {
        await rejects(make({ state: "unreachable", last_live_state: bad }), /agent_tasks_last_live_state_check/);
      }
      // state가 unreachable이면 last_live_state는 반드시 있다 (reconcile이 돌아갈 곳). 만들 때 · 바꿀 때 모두
      await rejects(make({ state: "unreachable", last_live_state: null }), /agent_tasks_unreachable_live_state/);
      await rejects(make({ state: "unreachable" }), /agent_tasks_unreachable_live_state/);
      const live = await make({ state: "running" });
      await rejects(f.updateRow("agent_tasks", live, { state: "unreachable" }), /agent_tasks_unreachable_live_state/);
      await f.updateRow("agent_tasks", live, { state: "unreachable", last_live_state: "running" });
      await rejects(f.updateRow("agent_tasks", live, { last_live_state: null }), /agent_tasks_unreachable_live_state/);
      // unreachable이 아닌 상태는 last_live_state 없이 된다 (idle 작업은 끊긴 적이 없다)
      await make({ state: "idle", last_live_state: null });
      await make({ state: "completed" });

      await rejects(make({ directive_version: 0 }), /agent_tasks_directive_version_check/);
      await rejects(make({ result_revision: -1 }), /agent_tasks_result_revision_check/);
      await rejects(make({ expected_result_revision: 0 }), /agent_tasks_expected_result_revision_check/);
      await rejects(make({ turn_seq: 0 }), /agent_tasks_turn_seq_check/);
      await rejects(make({ last_event_seq: -1 }), /agent_tasks_last_event_seq_check/);
      await rejects(make({ external_task_id: "x".repeat(201) }), /agent_tasks_external_task_id_check/);
      await make({ directive_version: 3, result_revision: 0, expected_result_revision: 4, turn_seq: 12, last_event_seq: 9_000_000_000, external_task_id: "x".repeat(200) });
      for (const bad of [[], ["q"], '"text"', "1"]) await rejects(make({ pending_question: bad }), /agent_tasks_pending_question_check/);
      for (const bad of [{}, { a: 1 }, '"text"']) await rejects(make({ result_refs: bad }), /agent_tasks_result_refs_check/);
      await rejects(make({ result_refs: null }), /not-null constraint/);
      await make({ result_refs: [{ artifact_id: randomUUID(), turn_seq: 1 }] });
    });

    it("agent_tasks: awaiting_answer인데 pending_question이 null이면 거절한다 (만들 때 · 상태를 바꿀 때 · 질문을 비울 때)", async () => {
      const w = await f.world();
      const session = await f.session(w.user, w.connection);
      await rejects(f.task(w.user, w.run, session, { state: "awaiting_answer" }), /agent_tasks_awaiting_question/);
      await rejects(f.task(w.user, w.run, await f.session(w.user, w.connection), { state: "awaiting_answer", pending_question: null }), /agent_tasks_awaiting_question/);
      const running = await f.task(w.user, w.run, session, { state: "running" });
      await rejects(f.updateRow("agent_tasks", running, { state: "awaiting_answer" }), /agent_tasks_awaiting_question/);
      await f.updateRow("agent_tasks", running, { state: "awaiting_answer", pending_question: { ...AGENT_QUESTION, question_key: [running, AGENT_QUESTION.provider_request_id] } });
      await rejects(f.updateRow("agent_tasks", running, { pending_question: null }), /agent_tasks_awaiting_question/);
      // 답을 받아 running으로 돌아가면 질문을 비울 수 있다. 다른 상태에서는 질문이 있어도 된다 (오래된 질문 기록)
      await f.updateRow("agent_tasks", running, { state: "running", pending_question: null });
      await f.updateRow("agent_tasks", running, { state: "idle", pending_question: { ...AGENT_QUESTION, question_key: [running, AGENT_QUESTION.provider_request_id] } });
    });

    it("execution_runs: kind는 task · conversation, conversation은 goal agent뿐, reviewed_turn_seq는 0 이상", async () => {
      const w = await f.world();
      const action = () => f.action(w.user);
      for (const bad of ["Task", "", "agent", "chat"]) await rejects(f.agentRun(w.user, await action(), { goal: "agent", kind: bad }), /execution_runs_kind_check/);
      await rejects(f.agentRun(w.user, await action(), { goal: "agent", kind: null }), /not-null constraint/);
      // conversation인데 goal이 draft(또는 다른 goal)이면 거절 — 만들 때와 바꿀 때 모두
      for (const goal of ["draft", "send", "followup"]) await rejects(f.agentRun(w.user, await action(), { goal, kind: "conversation" }), /execution_runs_conversation_goal/);
      const draft = await f.run(w.user, await action());
      await rejects(f.updateRow("execution_runs", draft, { kind: "conversation" }), /execution_runs_conversation_goal/);
      await rejects(f.updateRow("execution_runs", w.run, { goal: "draft" }), /execution_runs_conversation_goal/);
      // goal agent는 두 kind 모두 된다 (DB가 받는 것일 뿐 실행 입구는 아니다 — T9)
      await f.agentRun(w.user, await action(), { goal: "agent", kind: "conversation" });
      await f.agentRun(w.user, await action(), { goal: "agent", kind: "task" });
      await rejects(f.agentRun(w.user, await action(), { reviewed_turn_seq: -1 }), /execution_runs_reviewed_turn_seq_check/);
      await f.agentRun(w.user, await action(), { reviewed_turn_seq: 3 });
    });

    it("execution_events: type agent ↔ external_event_id, 번호 · payload 모양, 기존 type(run · step · hold)은 그대로", async () => {
      const w = await f.world();
      // type 'agent'는 사건 id가 있어야 한다. 다른 type은 사건 id를 쓰지 않는다
      await rejects(f.agentEvent(w.user, w.run, null), /execution_events_agent_event_id/);
      for (const type of ["run", "step", "hold"]) {
        await rejects(f.insertRow("execution_events", { user_id: w.user, run_id: w.run, type, external_event_id: "evt-x" }), /execution_events_agent_event_id/);
        await f.insertRow("execution_events", { user_id: w.user, run_id: w.run, type });
      }
      for (const bad of ["agentic", "Agent", "", "bridge"]) await rejects(f.insertRow("execution_events", { user_id: w.user, run_id: w.run, type: bad }), /execution_events_type_check/);
      await rejects(f.updateRow("execution_events", w.event, { external_event_id: null }), /execution_events_agent_event_id/);
      await rejects(f.updateRow("execution_events", w.event, { type: "run" }), /execution_events_agent_event_id/);

      await rejects(f.agentEvent(w.user, w.run, "x".repeat(201)), /execution_events_external_event_id_check/);
      // 빈 사건 id는 거절한다 (멱등 열쇠가 비면 run마다 하나만 저장되고 나머지 사건이 중복으로 버려진다)
      await rejects(f.agentEvent(w.user, w.run, ""), /execution_events_external_event_id_check/);
      await f.agentEvent(w.user, w.run, "x");
      await f.agentEvent(w.user, w.run, "x".repeat(200));
      await rejects(f.agentEvent(w.user, w.run, "evt-a", { external_seq: -1 }), /execution_events_external_seq_check/);
      await rejects(f.agentEvent(w.user, w.run, "evt-b", { directive_version: 0 }), /execution_events_directive_version_check/);
      await rejects(f.agentEvent(w.user, w.run, "evt-c", { turn_seq: 0 }), /execution_events_turn_seq_check/);
      for (const bad of [[], ["a"], '"text"', "1"]) await rejects(f.agentEvent(w.user, w.run, "evt-d", { payload: bad }), /execution_events_payload_check/);
      await f.agentEvent(w.user, w.run, "evt-ok", { external_seq: 0, directive_version: 2, turn_seq: 3, payload: { kind: "progress" } });
      await f.agentEvent(w.user, w.run, "evt-null-payload", { payload: null });
    });
  });

  // ───────────────────────── T4) 열린 대화 run은 세션 × 이슈마다 하나 ─────────────────────────
  describe("T4 부분 unique: 세션 × 이슈마다 열린 대화 run은 하나", () => {
    it("같은 (세션, 이슈)의 열린 대화 run 둘은 거절한다 — 열린 상태 셋(queued · running · waiting_approval) 모두", async () => {
      const w = await f.world();
      const action = await f.action(w.user);
      const first = await f.agentRun(w.user, action, { agent_session_id: w.session });
      await rejects(f.agentRun(w.user, action, { agent_session_id: w.session }), /execution_runs_open_conversation_idx/);
      for (const state of ["running", "waiting_approval"]) {
        await f.updateRow("execution_runs", first, { state });
        await rejects(f.agentRun(w.user, action, { agent_session_id: w.session }), /execution_runs_open_conversation_idx/);
      }
      expect(await count("execution_runs", "agent_session_id = $1 and action_id = $2", [w.session, action])).toBe(1);
    });

    it("하나가 끝나면(done · failed · stopped) 둘째가 허용된다. 끝난 run은 여럿 있어도 되고, 끝난 run을 되살려 열린 둘이 되는 갱신은 거절한다", async () => {
      const w = await f.world();
      for (const ended of ["stopped", "done", "failed"]) {
        const action = await f.action(w.user);
        const first = await f.agentRun(w.user, action, { agent_session_id: w.session });
        await f.updateRow("execution_runs", first, { state: ended });
        const second = await f.agentRun(w.user, action, { agent_session_id: w.session });
        await rejects(f.agentRun(w.user, action, { agent_session_id: w.session }), /execution_runs_open_conversation_idx/);
        // 첫째를 다시 열린 상태로 돌리면 열린 둘이 된다
        await rejects(f.updateRow("execution_runs", first, { state: "running" }), /execution_runs_open_conversation_idx/);
        await f.updateRow("execution_runs", second, { state: ended });
        await f.agentRun(w.user, action, { agent_session_id: w.session });
        expect(await count("execution_runs", "agent_session_id = $1 and action_id = $2", [w.session, action])).toBe(3);
      }
    });

    it("다른 세션이거나 다른 이슈면 열린 대화 run이 여럿이어도 된다. kind task는 이 제약 밖이다", async () => {
      const w = await f.world();
      const action = await f.action(w.user);
      const otherSession = await f.session(w.user, w.connection);
      await f.agentRun(w.user, action, { agent_session_id: w.session });
      await f.agentRun(w.user, action, { agent_session_id: otherSession });
      await f.agentRun(w.user, await f.action(w.user), { agent_session_id: w.session });
      // task run은 (세션, 이슈)가 같아도 둘 이상 열려 있을 수 있다
      await f.agentRun(w.user, action, { kind: "task", agent_session_id: w.session });
      await f.agentRun(w.user, action, { kind: "task", agent_session_id: w.session });
      expect(await count("execution_runs", "action_id = $1", [action])).toBe(4);
    });
  });

  // ───────────────────────── T5) 세션당 진행 중 턴 하나 ─────────────────────────
  describe("T5 세션당 진행 중 턴은 하나 (DB 백스톱)", () => {
    it("같은 세션에 진행 중 작업(dispatched · accepted · running · awaiting_answer · unreachable) 둘은 거절한다 — 모든 조합", async () => {
      const w = await f.world();
      for (const first of IN_PROGRESS_STATES) {
        const session = await f.session(w.user, w.connection);
        const question = (state: string) => (state === "awaiting_answer" ? AGENT_QUESTION : null);
        const live = (state: string) => (state === "unreachable" ? "running" : null); // unreachable은 끊기기 전 상태가 있어야 한다
        await f.task(w.user, w.run, session, { state: first, pending_question: question(first), last_live_state: live(first) });
        for (const second of IN_PROGRESS_STATES) {
          await rejects(f.task(w.user, w.run, session, { state: second, pending_question: question(second), last_live_state: live(second) }), /agent_tasks_in_progress_idx/);
        }
        expect(await count("agent_tasks", "agent_session_id = $1", [session]), first).toBe(1);
      }
    });

    it("idle · completed · failed · cancelled는 여럿 있어도 된다. 진행 중 하나와도 함께 있을 수 있다", async () => {
      const w = await f.world();
      const session = await f.session(w.user, w.connection);
      for (const state of ["idle", "completed", "failed", "cancelled"]) {
        await f.task(w.user, w.run, session, { state });
        await f.task(w.user, w.run, session, { state });
      }
      await f.task(w.user, w.run, session, { state: "running" });
      expect(await count("agent_tasks", "agent_session_id = $1", [session])).toBe(9);
      // 다른 세션의 진행 중 작업은 서로 막지 않는다
      await f.task(w.user, w.run, await f.session(w.user, w.connection), { state: "running" });
    });

    it("unreachable 작업이 있는 동안 그 세션에 새 진행 중 작업을 만들 수 없다 (reconcile을 기다린다). 같은 행을 last_live_state로 되돌리는 갱신은 된다", async () => {
      const w = await f.world();
      const session = await f.session(w.user, w.connection);
      const first = await f.task(w.user, w.run, session, { state: "running", turn_seq: 1 });
      // 끊김: 직전 상태를 적고 unreachable로 (진행 중 → 진행 중이라 자기 자신과 부딪히지 않는다)
      await f.updateRow("agent_tasks", first, { state: "unreachable", last_live_state: "running" });
      for (const state of ["dispatched", "accepted", "running", "awaiting_answer", "unreachable"]) {
        await rejects(
          f.task(w.user, w.run, session, { state, turn_seq: 2, pending_question: state === "awaiting_answer" ? AGENT_QUESTION : null, last_live_state: state === "unreachable" ? "running" : null }),
          /agent_tasks_in_progress_idx/,
        );
      }
      // 끝났거나 턴이 끝난 작업은 끊긴 작업과 함께 있어도 된다
      await f.task(w.user, w.run, session, { state: "idle", turn_seq: 3 });
      expect(await count("agent_tasks", "agent_session_id = $1", [session])).toBe(2);
      // reconcile: 같은 행을 직전 상태로 되돌린다
      await f.updateRow("agent_tasks", first, { state: "running", last_live_state: null });
      expect(await f.one(`select state from public.agent_tasks where id = $1`, [first])).toEqual({ state: "running" });
      // 끊긴 작업이 reconcile로 끝 상태가 되면 길이 비어 새 턴을 시작할 수 있다
      await f.updateRow("agent_tasks", first, { state: "unreachable", last_live_state: "running" });
      await f.updateRow("agent_tasks", first, { state: "completed", last_live_state: null });
      await f.task(w.user, w.run, session, { state: "dispatched", turn_seq: 2 });
    });

    it("끝난 작업은 길을 비운다: running → idle로 바뀐 뒤에는 새 진행 중 작업이 된다. idle을 다시 running으로 돌릴 때 이미 진행 중이 있으면 거절한다", async () => {
      const w = await f.world();
      const session = await f.session(w.user, w.connection);
      const first = await f.task(w.user, w.run, session, { state: "running", turn_seq: 1 });
      await rejects(f.task(w.user, w.run, session, { state: "dispatched", turn_seq: 2 }), /agent_tasks_in_progress_idx/);
      await f.updateRow("agent_tasks", first, { state: "idle" });
      const second = await f.task(w.user, w.run, session, { state: "dispatched", turn_seq: 2 });
      await rejects(f.updateRow("agent_tasks", first, { state: "running" }), /agent_tasks_in_progress_idx/);
      await f.updateRow("agent_tasks", second, { state: "completed" });
      await f.updateRow("agent_tasks", first, { state: "running" });
    });

    it("같은 (세션, turn_seq) 둘은 거절한다. turn_seq가 없는 작업 · 다른 세션 · 다른 번호는 된다", async () => {
      const w = await f.world();
      const session = await f.session(w.user, w.connection);
      await f.task(w.user, w.run, session, { state: "idle", turn_seq: 1 });
      await rejects(f.task(w.user, w.run, session, { state: "idle", turn_seq: 1 }), /agent_tasks_session_turn_idx/);
      await rejects(f.task(w.user, w.run, session, { state: "completed", turn_seq: 1 }), /agent_tasks_session_turn_idx/);
      await f.task(w.user, w.run, session, { state: "idle", turn_seq: 2 });
      await f.task(w.user, w.run, session, { state: "idle", turn_seq: null });
      await f.task(w.user, w.run, session, { state: "idle", turn_seq: null });
      await f.task(w.user, w.run, await f.session(w.user, w.connection), { state: "idle", turn_seq: 1 });
      // 번호를 갱신으로 겹치게 만드는 것도 거절한다
      const third = await f.task(w.user, w.run, session, { state: "idle", turn_seq: 3 });
      await rejects(f.updateRow("agent_tasks", third, { turn_seq: 2 }), /agent_tasks_session_turn_idx/);
    });
  });

  // ───────────────────────── T6) 사건 중복 ─────────────────────────
  describe("T6 execution_events: (run, external_event_id) 한 번만", () => {
    it("같은 run의 같은 사건 id 둘은 거절한다. 다른 run이면 같은 id도 된다", async () => {
      const w = await f.world();
      const other = await f.agentRun(w.user, await f.action(w.user), { agent_session_id: w.session });
      await f.agentEvent(w.user, w.run, "evt-1");
      await rejects(f.agentEvent(w.user, w.run, "evt-1"), /execution_events_agent_dedup_idx/);
      await rejects(f.agentEvent(w.user, w.run, "evt-1", { external_seq: 9, payload: { kind: "progress" } }), /execution_events_agent_dedup_idx/);
      await f.agentEvent(w.user, w.run, "evt-2");
      await f.agentEvent(w.user, other, "evt-1");
      expect(await count("execution_events", "run_id = $1 and external_event_id = 'evt-1'", [w.run])).toBe(1);
      expect(await count("execution_events", "run_id = $1 and external_event_id = 'evt-1'", [other])).toBe(1);
      // 갱신으로 겹치게 만드는 것도 거절한다
      const third = await f.agentEvent(w.user, w.run, "evt-3");
      await rejects(f.updateRow("execution_events", third, { external_event_id: "evt-1" }), /execution_events_agent_dedup_idx/);
    });

    it("type이 agent가 아닌 사건(run · step · hold)은 이 제약 밖이다: 같은 run에 여러 줄이 쌓인다", async () => {
      const w = await f.world();
      const before = await count("execution_events", "run_id = $1 and type = 'hold'", [w.taskRun]);
      for (let i = 0; i < 3; i++) await f.insertRow("execution_events", { user_id: w.user, run_id: w.taskRun, type: "hold" });
      for (let i = 0; i < 2; i++) await f.insertRow("execution_events", { user_id: w.user, run_id: w.taskRun, type: "run" });
      expect(await count("execution_events", "run_id = $1 and type = 'hold'", [w.taskRun])).toBe(before + 3);
      // 기존 트리거가 남기는 사건도 그대로 쌓인다 (run을 만들 때 run · step 사건)
      expect(await count("execution_events", "run_id = $1 and type in ('run', 'step') and external_event_id is null", [w.taskRun])).toBeGreaterThanOrEqual(2);
    });
  });

  // ───────────────────────── T7) 삭제 전파 ─────────────────────────
  describe("T7 삭제 전파", () => {
    it("connection 삭제 → 세션 · 작업이 함께 지워지고, 세션을 가리키던 run은 남고 agent_session_id만 비는다", async () => {
      const w = await f.world();
      const other = await f.world();
      await q(`delete from public.agent_connections where id = $1`, [w.connection]);
      expect(await count("agent_sessions", "id = $1", [w.session])).toBe(0);
      expect(await count("agent_tasks", "id = $1", [w.task])).toBe(0);
      expect(await f.one(`select kind, agent_session_id from public.execution_runs where id = $1`, [w.run])).toEqual({ kind: "conversation", agent_session_id: null });
      expect(await count("execution_events", "id = $1", [w.event])).toBe(1);
      expect(await count("bridges", "id = $1", [w.bridge])).toBe(1);
      // 다른 사용자의 세계는 그대로
      expect(await count("agent_tasks", "id = $1", [other.task])).toBe(1);
      expect(await f.one(`select agent_session_id from public.execution_runs where id = $1`, [other.run])).toEqual({ agent_session_id: other.session });
    });

    it("session 삭제 → 작업은 지워지고, 열린 run은 stopped로 남고 agent_session_id가 비며, 연결은 그대로다", async () => {
      const w = await f.world();
      await q(`delete from public.agent_sessions where id = $1`, [w.session]);
      expect(await count("agent_tasks", "id = $1", [w.task])).toBe(0);
      expect(await f.one(`select state, kind, agent_session_id from public.execution_runs where id = $1`, [w.run])).toEqual({ state: "stopped", kind: "conversation", agent_session_id: null });
      expect(await count("agent_connections", "id = $1", [w.connection])).toBe(1);
      expect(await count("execution_events", "id = $1", [w.event])).toBe(1);
    });

    it("bridge 삭제 → 연결(남는다)과 사건(남는다)의 bridge_id만 비고, 연결 · 세션 · 작업은 지워지지 않는다", async () => {
      const w = await f.world();
      await q(`delete from public.bridges where id = $1`, [w.bridge]);
      expect(await f.one(`select bridge_id from public.agent_connections where id = $1`, [w.connection])).toEqual({ bridge_id: null });
      expect(await f.one(`select bridge_id, type, turn_seq from public.execution_events where id = $1`, [w.event])).toEqual({ bridge_id: null, type: "agent", turn_seq: 1 });
      expect(await count("agent_sessions", "id = $1", [w.session])).toBe(1);
      expect(await count("agent_tasks", "id = $1", [w.task])).toBe(1);
    });

    it("message 삭제 → 작업의 message_id만 비고 작업은 남는다. 단계가 지워져도 작업의 step_id만 빈다", async () => {
      const w = await f.world();
      await q(`delete from public.conversation_messages where id = $1`, [w.message]);
      expect(await f.one(`select message_id, step_id, state from public.agent_tasks where id = $1`, [w.task])).toEqual({ message_id: null, step_id: w.step, state: "idle" });
      await q(`delete from public.execution_steps where id = $1`, [w.step]);
      expect(await f.one(`select message_id, step_id, state from public.agent_tasks where id = $1`, [w.task])).toEqual({ message_id: null, step_id: null, state: "idle" });
      // 대화를 지우면 메시지도 지워지는 기존 경로에서도 같다
      const second = await f.world();
      await q(`delete from public.conversations where id = $1`, [second.conversation]);
      expect(await f.one(`select message_id from public.agent_tasks where id = $1`, [second.task])).toEqual({ message_id: null });
    });

    it("Action 삭제 → 세션의 bound_action_id만 비고(세션 유지), 그 Action의 run을 따라 작업은 지워진다", async () => {
      const w = await f.world();
      await q(`delete from public.actions where id = $1`, [w.action]);
      expect(await f.one(`select bound_action_id, status from public.agent_sessions where id = $1`, [w.session])).toEqual({ bound_action_id: null, status: "bound" });
      expect(await count("execution_runs", "id = $1", [w.run])).toBe(0);
      expect(await count("agent_tasks", "id = $1", [w.task])).toBe(0);
      expect(await count("execution_events", "id = $1", [w.event])).toBe(0);
    });

    it("계정 삭제 → 네 표 · 사건 · run이 모두 사라지고 다른 사용자의 것은 그대로다", async () => {
      const [alice, bob] = [await f.world(), await f.world()];
      const counts = async (user: string) => ({
        ...Object.fromEntries(await Promise.all(AGENT_TABLES.map(async (table) => [table, await count(table, "user_id = $1", [user])] as const))),
        runs: await count("execution_runs", "user_id = $1", [user]),
        agent_events: await count("execution_events", "user_id = $1 and type = 'agent'", [user]),
      });
      expect(await counts(alice.user)).toEqual({ bridges: 1, agent_connections: 1, agent_sessions: 1, agent_tasks: 1, runs: 2, agent_events: 1 });
      const bobBefore = await counts(bob.user);
      await q(`delete from auth.users where id = $1`, [alice.user]);
      expect(await counts(alice.user)).toEqual({ bridges: 0, agent_connections: 0, agent_sessions: 0, agent_tasks: 0, runs: 0, agent_events: 0 });
      expect(await counts(bob.user)).toEqual(bobBefore);
    });
  });

  // ───────────────────────── T9) 실행 입구는 바뀌지 않았다 ─────────────────────────
  describe("T9 실행 입구 불변: 이 묶음 뒤에도 goal agent run은 만들어지지 않고 에이전트 단계는 붙지 않는다", () => {
    it("create_run은 goal agent · send · followup을 여전히 거절하고 run · 단계 · 세션 · 작업을 한 줄도 만들지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const snapshot = async () => ({
        runs: await count("execution_runs", "user_id = $1", [user]),
        steps: await count("execution_steps", "user_id = $1", [user]),
        events: await count("execution_events", "user_id = $1", [user]),
        agent: await Promise.all(AGENT_TABLES.map((table) => count(table, "user_id = $1", [user]))),
      });
      const before = await snapshot();
      for (const goal of ["agent", "send", "followup", "conversation", "", "Draft"]) {
        await rejects(q(`select public.create_run($1, $2, $3, '맡길 일')`, [user, action, goal]), /아직 실행하지 않는다/);
      }
      await rejects(q(`select public.create_run($1, $2, null, '맡길 일')`, [user, action]), /아직 실행하지 않는다/);
      expect(await snapshot()).toEqual(before);
      // goal draft는 그대로 만들어지고 새 열은 기본값이다
      const run = await f.run(user, action);
      expect(await f.one(`select kind, agent_session_id, reviewed_turn_seq from public.execution_runs where id = $1`, [run])).toEqual({ kind: "task", agent_session_id: null, reviewed_turn_seq: 0 });
    });

    it("task run의 append_step은 에이전트 단계 종류(agent_dispatch · agent_message · agent_cancel · review · check · send · observe)를 여전히 거절한다. plan · draft는 붙는다", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const steps = () => count("execution_steps", "run_id = $1", [run]);
      expect(await steps()).toBe(1);
      for (const kind of ["agent_dispatch", "agent_message", "agent_cancel", "review", "check", "send", "observe"]) {
        await rejects(
          q(`select public.append_step($1, 2, $2::jsonb)`, [run, JSON.stringify({ kind, provider: "agent:claude-code", tool: "dispatch", purpose: "맡기기" })]),
          /아직 붙이지 않는다/,
        );
        expect(await steps(), kind).toBe(1);
      }
      expect(await f.one(`select public.append_step($1, 2, $2::jsonb) is not null as ok`, [run, JSON.stringify({ kind: "draft", provider: "taskforce", tool: "draft", purpose: "초안" })])).toEqual({ ok: true });
      expect(await steps()).toBe(2);
    });

    it("D1c-1 message 도구 둘은 external이고 provider 스위치는 blocked, 다른 새 도구는 없다", async () => {
      expect(await count("execution_tools", "tool in ('dispatch', 'cancel', 'review', 'check', 'observe')")).toBe(0);
      expect(await q(`select key, blocked from public.execution_controls where scope = 'provider' and key like 'agent:%' order by key`)).toEqual([
        { key: "agent:claude-code", blocked: true }, { key: "agent:codex", blocked: true },
      ]);
      expect(await q(`select provider, tool, effect_class from public.execution_tools order by provider, tool`)).toEqual([
        { provider: "agent:claude-code", tool: "message", effect_class: "external" },
        { provider: "agent:codex", tool: "message", effect_class: "external" },
        { provider: "taskforce", tool: "draft", effect_class: "internal" },
        { provider: "taskforce", tool: "plan", effect_class: "internal" },
      ]);
    });

    it("실행 함수는 새 표를 보지 않는다: D1c-1 append_step/prepare_step의 대화 kind 검사만 예외", async () => {
      const functions = await q(
        `select p.proname as name, pg_get_functiondef(p.oid) as body from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and (p.proname like 'execution\\_%' or p.proname in ('create_run', 'append_step', 'begin_call', 'prepare_step', 'approve_step', 'show_plan', 'revoke_approval', 'settle_step', 'complete_internal_step', 'stop_run', 'finish_run', 'approval_hash', 'auto_allowed'))`,
      );
      expect(functions.length).toBeGreaterThan(10);
      for (const row of functions) {
        expect(String(row.body), String(row.name)).not.toMatch(/agent_tasks|agent_sessions|agent_connections|bridges|reviewed_turn_seq|agent_session_id|external_event_id/);
        if (!["append_step", "prepare_step"].includes(String(row.name))) expect(String(row.body), String(row.name)).not.toMatch(/\bkind = 'conversation'/);
      }
    });
  });
}

// ───────────────────────── 업그레이드 ─────────────────────────
const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");

/** Supabase 흉내 + D1a 앞의 모든 마이그레이션 / D1a / 그 뒤의 마이그레이션 */
async function splitScripts() {
  const files = (await readdir(MIGRATIONS_DIR)).filter((file) => file.endsWith(".sql")).sort();
  const index = files.indexOf(D1A_MIGRATION);
  expect(index, `${D1A_MIGRATION}이 마이그레이션 목록에 있다`).toBeGreaterThan(0);
  const scripts = await supabaseSchemaScripts();
  return { before: scripts.slice(0, 2 + index), d1a: scripts[2 + index], after: scripts.slice(3 + index) };
}

/** 옛 행에서 옛 열만 뽑는다: 새 마이그레이션이 열을 더해도 옛 열의 값이 그대로인지만 본다 */
const onlyOldKeys = (oldRows: Rows, nowRows: Rows) =>
  oldRows.map((oldRow, i) => {
    const old = oldRow.row as Record<string, unknown>;
    const now = nowRows[i].row as Record<string, unknown>;
    return { old, now: Object.fromEntries(Object.keys(old).map((key) => [key, now[key]])) };
  });

/**
 * D1a 앞 상태에서 옛 행(draft run · 단계 · 사건)을 만들고, 마이그레이션을 적용한 뒤에도 그대로인지 본다. 새 열은 기본값이다.
 * 마지막 시나리오는 기대와 다른 제약이 있으면 아무것도 바꾸지 않고 실패하는 것(롤백)을 본다.
 */
export function agentGatewayUpgradeTests(fresh: () => Promise<FreshDb>) {
  describe("업그레이드 회귀 (D1a 전 상태 → 전체 적용)", () => {
    it("옛 draft run · 단계 · 사건 · 정책이 그대로이고 새 열은 기본값이며 새 표는 비어 있다. create_run은 그대로 draft만 받는다", async () => {
      const { before, d1a, after } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const one = async (sql: string, params: unknown[] = []) => (await db.query(sql, params))[0];
      const id = async (sql: string, params: unknown[] = []) => String((await one(sql, params)).id);

      expect(await db.query(`select 1 from information_schema.columns where table_name = 'execution_runs' and column_name = 'kind'`)).toEqual([]);
      expect(await db.query(`select 1 from information_schema.tables where table_name in ('bridges', 'agent_connections', 'agent_sessions', 'agent_tasks')`)).toEqual([]);
      const alice = randomUUID();
      const bob = randomUUID();
      for (const u of [alice, bob]) await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u, `${u}@example.com`]);
      const runs: string[] = [];
      for (const [user, state] of [[alice, "done"], [alice, "running"], [alice, "stopped"], [bob, "queued"]] as const) {
        const action = await id(`insert into public.actions (user_id, title) values ($1, '할 일') returning id`, [user]);
        const run = await id(`select public.create_run($1, $2, 'draft', '초안 써 줘', 40) as id`, [user, action]);
        await db.query(`update public.execution_runs set state = $2 where id = $1`, [run, state]);
        runs.push(run);
      }
      await db.query(`insert into public.execution_events (user_id, run_id, type, from_state, to_state, gate) values ($1, $2, 'hold', null, 'credit', 'credit')`, [alice, runs[0]]);

      const snapshot = async () => {
        const out: Record<string, Rows> = {};
        for (const table of ["execution_policies", "execution_runs", "execution_steps", "execution_events", "execution_approvals", "execution_intents", "execution_tools", "execution_controls", "actions"]) {
          out[table] = await db.query(`select to_jsonb(t) as row from public.${table} t order by to_jsonb(t)::text`);
        }
        return out;
      };
      const old = await snapshot();
      expect(old.execution_runs).toHaveLength(4);
      expect(old.execution_events.length).toBeGreaterThan(8);

      for (const sql of [d1a, ...after]) await db.exec(sql);

      const now = await snapshot();
      // D1c-1의 새 message/blocked 행만 제외한다. 기존 행 보존 비교는 그대로다.
      now.execution_tools = now.execution_tools.filter(({ row }) => !["agent:claude-code", "agent:codex"].includes(String((row as Record<string, unknown>).provider)));
      now.execution_controls = now.execution_controls.filter(({ row }) => !["agent:claude-code", "agent:codex"].includes(String((row as Record<string, unknown>).key)));
      for (const table of Object.keys(old)) {
        for (const { old: oldRow, now: nowRow } of onlyOldKeys(old[table], now[table])) expect(nowRow, table).toEqual(oldRow);
        expect(now[table], table).toHaveLength(old[table].length);
      }
      // 새 열은 기본값이다
      for (const r of now.execution_runs) expect(r.row).toMatchObject({ kind: "task", agent_session_id: null, reviewed_turn_seq: 0 });
      for (const r of now.execution_events) expect(r.row).toMatchObject({ external_event_id: null, external_seq: null, directive_version: null, turn_seq: null, bridge_id: null, payload: null });
      // 새 표는 비어 있다
      for (const table of AGENT_TABLES) expect((await db.query(`select count(*)::int as n from public.${table}`))[0], table).toEqual({ n: 0 });
      // 실행 입구는 그대로다
      await expect(db.query(`select public.create_run($1, $2, 'agent', 'x')`, [alice, await id(`insert into public.actions (user_id, title) values ($1, 'x') returning id`, [alice])])).rejects.toThrow(/아직 실행하지 않는다/);
      expect((await db.query(`select public.create_run($1, $2, 'draft', 'x') is not null as ok`, [alice, await id(`insert into public.actions (user_id, title) values ($1, 'y') returning id`, [alice])]))[0]).toEqual({ ok: true });
      // 옛 값은 새 제약 아래서도 그대로 쓸 수 있다
      await db.query(`update public.execution_runs set goal = goal, kind = kind`);
      await db.query(`update public.execution_events set type = type`);
    });

    it("execution_events.type CHECK가 기대와 다르면(열마다 하나가 아닌 경우) 마이그레이션은 아무것도 바꾸지 않고 실패한다 (롤백)", async () => {
      const { before, d1a } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      await db.query(`alter table public.execution_events add constraint zz_extra_type check (type <> 'zz')`);
      await expect(db.exec(d1a)).rejects.toThrow(/execution_events\.type CHECK 제약이 2개다/);
      await db.exec("rollback");
      expect(await db.query(`select 1 from information_schema.tables where table_name in ('bridges', 'agent_connections', 'agent_sessions', 'agent_tasks')`)).toEqual([]);
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'execution_runs' and column_name in ('kind', 'agent_session_id', 'reviewed_turn_seq')`)).toEqual([]);
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'execution_events' and column_name in ('external_event_id', 'payload', 'bridge_id')`)).toEqual([]);
      // 옛 제약이 그대로다: type 'agent'는 아직 거절된다
      const user = randomUUID();
      await db.query(`insert into auth.users (id, email) values ($1, 'x@example.com')`, [user]);
      const action = String((await db.query(`insert into public.actions (user_id, title) values ($1, 'x') returning id`, [user]))[0].id);
      const run = String((await db.query(`select public.create_run($1, $2, 'draft', 'x') as id`, [user, action]))[0].id);
      await expect(db.query(`insert into public.execution_events (user_id, run_id, type) values ($1, $2, 'agent')`, [user, run])).rejects.toThrow(/execution_events_type_check/);
    });
  });
}
