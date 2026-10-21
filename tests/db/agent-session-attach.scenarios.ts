import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";

import { agentTurnFixtures } from "./agent-turn-start.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// 외부 세션 이어받기 서버 (OA 외부 세션 PR2s, 계약 7장 ES-17 · ES-18 · 10장 · 12.2): SQL 함수 attach_agent_session 하나.
// 새 표 0 — 기존 agent_sessions · conversations 모양 그대로 쓴다. 같은 시나리오를 PGlite(tests/db/agent-session-attach.test.ts)와
// 실제 Postgres(tests/pg/agent-session-attach.test.ts)에서 돌린다. 연결 둘이 겹치는 경합은 실제 Postgres 파일에만 있다.

export const ATTACH_MIGRATION = "20261204000000_agent_session_attach.sql";
export const CLAUDE = "agent:claude-code";
export const CODEX = "agent:codex";
const NOTHING = { status: "not_found" };
const IN_USE = { status: "session_in_use" };

export const wsRef = () => `/taskforce/ws_${randomUUID()}`;

export type AttachResult = { status: string; session_id?: string; conversation_id?: string };

export function attachFixtures(db: () => ConversationAgentDb) {
  const base = agentTurnFixtures(db);
  const f = {
    ...base,
    attach: async (user: string | null, bridge: string | null, external: string | null = randomUUID(), ref: string | null = wsRef(), adapter: string | null = CLAUDE) =>
      (await base.one("select public.attach_agent_session($1, $2, $3, $4, $5) as result", [user, bridge, adapter, external, ref])).result as AttachResult,
    /** 사용자 + 활성 bridge + 활성 연결 (register_bridge가 만든 모양: 연결은 bridge에 묶인다) */
    async world(adapter = CLAUDE) {
      const user = await base.user();
      const bridge = await base.bridge(user);
      const connection = await base.agentConnection(user, bridge, { adapter });
      return { user, bridge, connection };
    },
    /** 이 사용자의 쓰기 대상 행 수 (이어받기가 만들면 안 되는 것까지) */
    async rows(user: string) {
      const n = (table: string) => base.count(`select 1 from public.${table} where user_id = $1`, [user]);
      return {
        sessions: await n("agent_sessions"),
        conversations: await n("conversations"),
        events: await base.count("select 1 from public.metric_events where user_id = $1 and type = 'session_attached'", [user]),
        actions: await n("actions"),
        runs: await n("execution_runs"),
        tasks: await n("agent_tasks"),
        messages: await n("conversation_messages"),
        steps: await n("execution_steps"),
      };
    },
    /** 역할을 바꿔 호출한다 (끝나면 원래대로) */
    async asRole<T>(role: string, fn: () => Promise<T>): Promise<T> {
      await base.q(`set role ${role}`);
      try {
        return await fn();
      } finally {
        await base.q("reset role");
      }
    },
  };
  return f;
}

export function attachAgentSessionTests(db: () => ConversationAgentDb) {
  const f = attachFixtures(db);
  const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);
  const NO_WRITES = { sessions: 0, conversations: 0, events: 0, actions: 0, runs: 0, tasks: 0, messages: 0, steps: 0 };

  describe("함수 권한 · 모양", () => {
    it("security definer + search_path 빈 값, 하나뿐, public · anon · authenticated 실행 권한 0, service_role만", async () => {
      const rows = await f.q(
        `select p.prosecdef, p.proconfig, p.proacl::text as acl, pg_get_function_result(p.oid) as result,
                has_function_privilege('anon', p.oid, 'execute') as anon,
                has_function_privilege('authenticated', p.oid, 'execute') as app,
                has_function_privilege('service_role', p.oid, 'execute') as server
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'attach_agent_session'`,
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ prosecdef: true, proconfig: ['search_path=""'], result: "jsonb", anon: false, app: false, server: true });
      // PUBLIC에 준 권한은 acl에 `=X/…`로 남는다
      expect(String(rows[0].acl)).not.toMatch(/(^|[{,])=X\//);
    });

    it("anon · authenticated는 직접 부를 수 없고(42501) 아무것도 쓰지 않는다. service_role은 부를 수 있다", async () => {
      const w = await f.world();
      const external = randomUUID();
      const call = () => f.attach(w.user, w.bridge, external);
      await expect(f.asRole("anon", call)).rejects.toMatchObject({ code: "42501" });
      await expect(db().asUser(w.user, call)).rejects.toMatchObject({ code: "42501" });
      expect(await f.rows(w.user)).toEqual(NO_WRITES);
      expect(await f.asRole("service_role", call)).toMatchObject({ status: "created" });
      expect(await f.rows(w.user)).toMatchObject({ sessions: 1, conversations: 1, events: 1 });
    });
  });

  describe("이어받기 (created)", () => {
    it("세션 하나 + 대화 하나를 만든다: bound · 빈 이름 · 받은 id와 가상 루트 그대로 · 같은 사용자 · 같은 연결", async () => {
      const w = await f.world();
      const external = randomUUID();
      const ref = wsRef();
      const result = await f.attach(w.user, w.bridge, external, ref);
      expect(result).toMatchObject({ status: "created" });
      expect(Object.keys(result).sort()).toEqual(["conversation_id", "session_id", "status"]);
      expect(await f.one("select * from public.agent_sessions where id = $1", [result.session_id])).toMatchObject({
        user_id: w.user, connection_id: w.connection, external_session_id: external, workspace_ref: ref,
        status: "bound", display_name: "", last_turn_seq: 0, bound_action_id: null,
      });
      expect(await f.one("select * from public.conversations where id = $1", [result.conversation_id])).toMatchObject({
        user_id: w.user, target_kind: "agent", agent_connection_id: w.connection, agent_session_id: result.session_id, context_id: null, title: null,
      });
      expect(await f.rows(w.user)).toEqual({ ...NO_WRITES, sessions: 1, conversations: 1, events: 1 });
    });

    it("Action · run · 작업 · 메시지 · 단계를 만들지 않는다 (붙이기만 한다)", async () => {
      const w = await f.world();
      await f.attach(w.user, w.bridge);
      const rows = await f.rows(w.user);
      expect({ actions: rows.actions, runs: rows.runs, tasks: rows.tasks, messages: rows.messages, steps: rows.steps }).toEqual({ actions: 0, runs: 0, tasks: 0, messages: 0, steps: 0 });
    });

    it("같은 트랜잭션: 롤백하면 세션 · 대화 · 이벤트가 함께 사라진다", async () => {
      const w = await f.world();
      await f.q("begin");
      try {
        expect(await f.attach(w.user, w.bridge)).toMatchObject({ status: "created" });
        expect(await f.rows(w.user)).toMatchObject({ sessions: 1, conversations: 1, events: 1 });
      } finally {
        await f.q("rollback");
      }
      expect(await f.rows(w.user)).toEqual(NO_WRITES);
    });

    it("이벤트 session_attached 하나: props는 adapter뿐 (id · 경로 · 제목 없음)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const ref = wsRef();
      await f.attach(w.user, w.bridge, external, ref);
      const events = await f.q("select type, props, action_id from public.metric_events where user_id = $1 and type = 'session_attached'", [w.user]);
      expect(events).toEqual([{ type: "session_attached", props: { adapter: CLAUDE }, action_id: null }]);
      const text = JSON.stringify(await f.q("select * from public.metric_events where user_id = $1", [w.user]));
      expect(text).not.toContain(external);
      expect(text).not.toContain(ref);
    });

    it("RLS: 이어받은 세션 · 대화는 주인만 읽고, 앱은 직접 쓰지 못한다", async () => {
      const mine = await f.world();
      const other = await f.world();
      const result = await f.attach(mine.user, mine.bridge);
      await db().asUser(mine.user, async () => {
        expect((await f.q("select id from public.agent_sessions")).map((r) => r.id)).toEqual([result.session_id]);
        expect((await f.q("select id from public.conversations")).map((r) => r.id)).toEqual([result.conversation_id]);
        await expect(f.q("update public.agent_sessions set status = 'closed' where id = $1", [result.session_id])).rejects.toMatchObject({ code: "42501" });
        await expect(f.q("insert into public.agent_sessions (connection_id, external_session_id, workspace_ref) values ($1, $2, 'x')", [mine.connection, randomUUID()])).rejects.toMatchObject({ code: "42501" });
      });
      await db().asUser(other.user, async () => {
        expect(await f.q("select id from public.agent_sessions")).toEqual([]);
        expect(await f.q("select id from public.conversations")).toEqual([]);
        expect(await f.q("select id from public.metric_events where type = 'session_attached'")).toEqual([]);
      });
    });
  });

  describe("멱등 (existing)", () => {
    it("같은 요청 두 번 → 둘째는 existing, 같은 세션 · 같은 대화, 행 1 · 이벤트 1", async () => {
      const w = await f.world();
      const external = randomUUID();
      const ref = wsRef();
      const first = await f.attach(w.user, w.bridge, external, ref);
      const second = await f.attach(w.user, w.bridge, external, ref);
      expect(second).toEqual({ ...first, status: "existing" });
      expect(await f.rows(w.user)).toEqual({ ...NO_WRITES, sessions: 1, conversations: 1, events: 1 });
    });

    it("다른 가상 루트로 다시 불러도 이미 묶인 값을 고치지 않는다 (existing, workspace_ref 그대로)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const ref = wsRef();
      const first = await f.attach(w.user, w.bridge, external, ref);
      expect(await f.attach(w.user, w.bridge, external, wsRef())).toEqual({ ...first, status: "existing" });
      expect(await f.one("select workspace_ref from public.agent_sessions where id = $1", [first.session_id])).toEqual({ workspace_ref: ref });
    });

    it("Taskforce가 시작한 세션이든 이어받은 세션이든 같은 id면 기존 대화를 돌려준다 (이미 열려 있다)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const session = await f.session(w.user, w.connection, { external_session_id: external, workspace_ref: "/taskforce/ws_x" });
      const conversation = await f.agentConversation(w.user, w.connection, session);
      expect(await f.attach(w.user, w.bridge, external)).toEqual({ status: "existing", session_id: session, conversation_id: conversation });
      expect(await f.rows(w.user)).toMatchObject({ sessions: 1, conversations: 1, events: 0 });
    });

    it("세션은 있고 대화가 없으면 대화만 새로 만든다 (created, 이벤트 1)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const session = await f.session(w.user, w.connection, { external_session_id: external });
      const result = await f.attach(w.user, w.bridge, external);
      expect(result).toMatchObject({ status: "created", session_id: session });
      expect(await f.rows(w.user)).toMatchObject({ sessions: 1, conversations: 1, events: 1 });
    });

    it("대화가 보관돼 있어도 새 대화를 만들지 않는다 (둘째 대화 0)", async () => {
      const w = await f.world();
      const first = await f.attach(w.user, w.bridge, randomUUID());
      await f.q("update public.conversations set archived_at = now() where id = $1", [first.conversation_id]);
      const external = String((await f.one("select external_session_id from public.agent_sessions where id = $1", [first.session_id])).external_session_id);
      expect(await f.attach(w.user, w.bridge, external)).toEqual({ ...first, status: "existing" });
      expect(await f.rows(w.user)).toMatchObject({ sessions: 1, conversations: 1 });
    });

    it("세션에 대화가 둘이면 보관한 대화보다 열린 대화를 돌려준다 (나중에 만든 것이어도)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const session = await f.session(w.user, w.connection, { external_session_id: external });
      const archived = await f.agentConversation(w.user, w.connection, session);
      await f.q("update public.conversations set archived_at = now(), created_at = now() - interval '1 day' where id = $1", [archived]);
      const open = await f.agentConversation(w.user, w.connection, session);
      expect(await f.attach(w.user, w.bridge, external)).toEqual({ status: "existing", session_id: session, conversation_id: open });
    });

    it("동시에 온 두 요청 → 세션 1 · 대화 1 · created 하나 + existing 하나 · 이벤트 1", async () => {
      const w = await f.world();
      const external = randomUUID();
      const ref = wsRef();
      const results = await Promise.all([f.attach(w.user, w.bridge, external, ref), f.attach(w.user, w.bridge, external, ref)]);
      expect(results.map((r) => r.status).sort()).toEqual(["created", "existing"]);
      expect(results[0].session_id).toBe(results[1].session_id);
      expect(results[0].conversation_id).toBe(results[1].conversation_id);
      expect(await f.rows(w.user)).toEqual({ ...NO_WRITES, sessions: 1, conversations: 1, events: 1 });
    });
  });

  describe("소유 · bridge (not_found)", () => {
    it("없는 bridge · 남의 bridge · 해제된 bridge는 모두 같은 not_found이고 아무것도 쓰지 않는다", async () => {
      const w = await f.world();
      const stranger = await f.world();
      const revoked = await f.world();
      await f.q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [revoked.bridge]);
      for (const [user, bridge] of [[w.user, randomUUID()], [w.user, stranger.bridge], [revoked.user, revoked.bridge]] as const) {
        expect(await f.attach(user, bridge)).toEqual(NOTHING);
      }
      for (const user of [w.user, stranger.user, revoked.user]) expect(await f.rows(user)).toEqual(NO_WRITES);
    });

    it("그 bridge에 이 adapter의 active 연결이 없으면 not_found: 연결 없음 · error · revoked · 다른 adapter만", async () => {
      const user = await f.user();
      const bare = await f.bridge(user);
      const broken = await f.bridge(user);
      await f.agentConnection(user, broken, { adapter: CLAUDE, status: "error" });
      const revokedConnection = await f.bridge(user);
      await f.agentConnection(user, revokedConnection, { adapter: CLAUDE, status: "revoked" });
      const otherAdapter = await f.bridge(user);
      await f.agentConnection(user, otherAdapter, { adapter: CODEX });
      for (const bridge of [bare, broken, revokedConnection, otherAdapter]) expect(await f.attach(user, bridge)).toEqual(NOTHING);
      expect(await f.rows(user)).toEqual(NO_WRITES);
    });

    it("남의 연결에는 붙지 않는다: 내 id로 남의 bridge를 대면 not_found, 남의 세션 행도 안 생긴다", async () => {
      const mine = await f.world();
      const theirs = await f.world();
      expect(await f.attach(mine.user, theirs.bridge)).toEqual(NOTHING);
      expect(await f.rows(theirs.user)).toEqual(NO_WRITES);
      expect(await f.rows(mine.user)).toEqual(NO_WRITES);
    });

    it("다른 사용자가 같은 Claude id를 자기 bridge에 붙이는 것은 서로 막지 않는다", async () => {
      const a = await f.world();
      const b = await f.world();
      const external = randomUUID();
      expect(await f.attach(a.user, a.bridge, external)).toMatchObject({ status: "created" });
      expect(await f.attach(b.user, b.bridge, external)).toMatchObject({ status: "created" });
    });
  });

  describe("이미 쓰이는 세션 (session_in_use)", () => {
    it("같은 사용자의 다른 연결(다른 Mac)에 이미 이어받은 id면 session_in_use: 아무것도 더 쓰지 않는다", async () => {
      const user = await f.user();
      const first = await f.bridge(user);
      await f.agentConnection(user, first);
      const second = await f.bridge(user);
      await f.agentConnection(user, second);
      const external = randomUUID();
      expect(await f.attach(user, first, external)).toMatchObject({ status: "created" });
      const before = await f.rows(user);
      expect(await f.attach(user, second, external)).toEqual(IN_USE);
      expect(await f.rows(user)).toEqual(before);
    });

    it("다른 연결의 세션이 closed(해제된 bridge)면 막지 않는다: 새 연결에서 새 세션으로 이어받는다", async () => {
      const user = await f.user();
      const old = await f.bridge(user);
      const oldConnection = await f.agentConnection(user, old);
      const external = randomUUID();
      await f.attach(user, old, external);
      await f.q("update public.agent_sessions set status = 'closed' where connection_id = $1", [oldConnection]);
      const next = await f.bridge(user);
      await f.agentConnection(user, next);
      const result = await f.attach(user, next, external);
      expect(result).toMatchObject({ status: "created" });
      expect((await f.one("select count(*)::int as n from public.agent_sessions where user_id = $1", [user])).n).toBe(2);
    });

    it("다른 adapter의 세션은 id가 같아도 막지 않는다 (id 공간은 adapter마다 따로다)", async () => {
      const w = await f.world();
      const codexBridge = await f.bridge(w.user);
      const codexConnection = await f.agentConnection(w.user, codexBridge, { adapter: CODEX });
      const shared = randomUUID();
      await f.session(w.user, codexConnection, { external_session_id: shared });
      expect(await f.attach(w.user, w.bridge, shared)).toMatchObject({ status: "created" });
    });

    it("같은 연결의 closed 세션은 다시 붙이지 않는다 (session_in_use)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const first = await f.attach(w.user, w.bridge, external);
      await f.q("update public.agent_sessions set status = 'closed' where id = $1", [first.session_id]);
      expect(await f.attach(w.user, w.bridge, external)).toEqual(IN_USE);
    });

    it("터미널로 내준 세션(external)도 existing이다 (상태를 바꾸지 않는다)", async () => {
      const w = await f.world();
      const external = randomUUID();
      const first = await f.attach(w.user, w.bridge, external);
      await f.q("update public.agent_sessions set status = 'external' where id = $1", [first.session_id]);
      expect(await f.attach(w.user, w.bridge, external)).toEqual({ ...first, status: "existing" });
      expect(await f.one("select status from public.agent_sessions where id = $1", [first.session_id])).toEqual({ status: "external" });
    });
  });

  describe("입력 모양 (서버가 다시 강제한다)", () => {
    const BAD_IDS: [string, string][] = [
      ["대문자", randomUUID().toUpperCase()],
      ["중괄호", `{${randomUUID()}}`],
      ["하이픈 없음", randomUUID().replaceAll("-", "")],
      ["pending 접두", `pending:${randomUUID()}`],
      ["앞 공백", ` ${randomUUID()}`],
      ["뒤 개행", `${randomUUID()}\n`],
      ["경로", "/tmp/a.jsonl"],
      ["상대 경로", "../" + randomUUID()],
      ["옵션 모양", "--resume"],
      ["빈 글", ""],
      ["길이 초과", randomUUID() + "0"],
      ["hex 아님", "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"],
    ];
    it.each(BAD_IDS)("정규 소문자 UUID가 아닌 id(%s)는 22023이고 아무것도 쓰지 않는다", async (_name, bad) => {
      const w = await f.world();
      await expect(f.attach(w.user, w.bridge, bad)).rejects.toMatchObject({ code: "22023" });
      expect(await f.rows(w.user)).toEqual(NO_WRITES);
    });

    const BAD_REFS: [string, string][] = [
      ["실제 경로", "/Users/daniel/project"],
      ["홈 경로", "/Users/daniel/Documents/Life Design"],
      ["ws_id 대문자", `/taskforce/ws_${randomUUID().toUpperCase()}`],
      ["하위 경로", `/taskforce/ws_${randomUUID()}/src`],
      ["ws_ 없음", `/taskforce/${randomUUID()}`],
      ["고정 자리", "/taskforce/ws_unregistered"],
      ["루트 접두 없음", `ws_${randomUUID()}`],
      ["세션 cwd 자리", "/taskforce-session/cwd"],
      ["뒤 개행", `/taskforce/ws_${randomUUID()}\n`],
      ["pending", `pending:${randomUUID()}`],
      ["빈 글", ""],
    ];
    it.each(BAD_REFS)("가상 루트 모양이 아닌 workspace_ref(%s)는 22023이고 아무것도 쓰지 않는다", async (_name, bad) => {
      const w = await f.world();
      await expect(f.attach(w.user, w.bridge, randomUUID(), bad)).rejects.toMatchObject({ code: "22023" });
      expect(await f.rows(w.user)).toEqual(NO_WRITES);
    });

    it("null 인자는 22023이다", async () => {
      const w = await f.world();
      await rejects(f.attach(null, w.bridge), /invalid argument/);
      await rejects(f.attach(w.user, null), /invalid argument/);
      await rejects(f.attach(w.user, w.bridge, randomUUID(), wsRef(), null), /invalid argument/);
      await rejects(f.attach(w.user, w.bridge, null), /invalid argument/);
      await rejects(f.attach(w.user, w.bridge, randomUUID(), null), /invalid argument/);
      expect(await f.rows(w.user)).toEqual(NO_WRITES);
    });

    it("adapter는 registry 문자열 모양이어야 한다 (agent: 접두)", async () => {
      const w = await f.world();
      for (const adapter of ["claude-code", "AGENT:CLAUDE-CODE", "agent:", "agent:" + "x".repeat(64)]) {
        await expect(f.attach(w.user, w.bridge, randomUUID(), wsRef(), adapter), adapter).rejects.toMatchObject({ code: "22023" });
      }
      expect(await f.rows(w.user)).toEqual(NO_WRITES);
    });
  });

  describe("start_agent_turn이 이어받은 세션에 바로 resume 명령을 만든다", () => {
    it("pending 세션을 만들지 않고, 명령의 세션 칸이 받은 id · 가상 루트 · resume true", async () => {
      const w = await f.world();
      const external = randomUUID();
      const ref = wsRef();
      const attached = await f.attach(w.user, w.bridge, external, ref);
      const message = String((await f.post(w.user, attached.conversation_id!, randomUUID(), "이어서 해 줘")).message_id);
      const started = await f.start(w.user, message, [], [], "write");
      expect(started.status).toBe("started");

      // 새 세션(pending:)이 생기지 않았고, 이어받은 세션이 그 턴의 세션이다
      expect(await f.q("select id, external_session_id from public.agent_sessions where user_id = $1", [w.user])).toEqual([{ id: attached.session_id, external_session_id: external }]);
      expect(await f.one("select agent_session_id, turn_seq from public.agent_tasks where id = $1", [started.agent_task_id])).toEqual({ agent_session_id: attached.session_id, turn_seq: 1 });
      expect(await f.one("select last_turn_seq, status from public.agent_sessions where id = $1", [attached.session_id])).toEqual({ last_turn_seq: 1, status: "bound" });

      // lease_bridge_command이 만드는 명령 (Mac이 받는 모양)
      await f.q("insert into public.execution_actors (user_id) values ($1) on conflict do nothing", [w.user]);
      await f.q("update public.execution_controls set blocked = false");
      const command = String((await f.one("select id from public.bridge_commands where step_id = $1", [started.step_id])).id);
      const mode = String((await f.one("select mode from public.execution_policies where user_id = $1", [w.user])).mode);
      const leased = (await f.one("select public.lease_bridge_command($1, $2, $3, 'write', $4) as result", [w.user, w.bridge, command, mode])).result as {
        status: string;
        command: { kind: string; adapter: string; agent_session_id: string; session: Record<string, unknown> };
      };
      expect(leased.status).toBe("leased");
      expect(leased.command).toMatchObject({ kind: "message", adapter: CLAUDE, agent_session_id: attached.session_id });
      expect(leased.command.session).toEqual({ external_session_id: external, workspace_ref: ref, resume: true });
    });
  });

  describe("지표 종류 검사", () => {
    it("session_attached를 받고 기존 종류는 그대로 받으며, 앱(authenticated)이 직접 남길 수는 없다", async () => {
      const user = await f.user();
      await f.q("insert into public.metric_events (user_id, type) values ($1, 'session_attached')", [user]);
      for (const type of ["app_opened", "assistant_opened", "session_resumed", "external_sessions_shown", "billing_checkout_started", "ai_key_saved"]) {
        await f.q("insert into public.metric_events (user_id, type) values ($1, $2)", [user, type]);
      }
      await expect(f.q("insert into public.metric_events (user_id, type) values ($1, 'session_attach_refused')", [user])).rejects.toMatchObject({ code: "23514" });
      await db().asUser(user, async () => {
        await expect(f.q("insert into public.metric_events (type) values ('session_attached')")).rejects.toMatchObject({ code: expect.stringMatching(/^(42501|23514)$/) });
      });
    });
  });
}
