import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { AGENT_QUESTION } from "./agent-gateway-core.scenarios";
import { agentEventFixtures } from "./agent-events.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// OA D1d-s 마이그레이션 (20261121000000_agent_conversation_api): 서버 전용 SQL 함수 셋 —
// requeue_agent_messages(Send again) · open_agent_session_external(Open in Terminal) · resume_agent_session_here(Resume here) —
// 과 공통 metric 블록 v2(새 type 5개). 같은 시나리오를 PGlite(tests/db/agent-conversation-api.test.ts)와 실제 Postgres(tests/pg)에서 돌린다.

export const D1D_MIGRATION = "20261121000000_agent_conversation_api.sql";
export const D1D_FUNCTIONS = ["open_agent_session_external", "requeue_agent_messages", "resume_agent_session_here"];
/** 공통 블록 v2(handoffs/oa-metric-events-block.sql)의 SHA-256. 블록은 코디네이터 소유라 글자 그대로 넣는다 */
export const METRIC_BLOCK_V2_SHA256 = "d39b4566b79607d0057e2c6de53ef309831b4509659e40f8132448fdade4f440";
export const METRIC_TYPES_V1 = [
  "app_opened", "action_started", "handoff_used", "connection_created", "connection_reauth", "reconnect_notified", "source_failed",
  "assistant_opened", "context_attached", "agent_message_sent", "stop_requested",
  "project_created", "project_renamed", "project_archived", "project_icon_changed", "issue_moved",
];
export const METRIC_TYPES_NEW = ["message_resent", "question_answered", "session_renamed", "session_opened_external", "session_resumed"];
const IN_PROGRESS = ["dispatched", "accepted", "running", "awaiting_answer", "unreachable"] as const;

type Requeue = { status: string; messages: { message_id: string; result: string; reason?: string }[] };

export function agentConversationApiFixtures(db: () => ConversationAgentDb) {
  const base = agentEventFixtures(db);
  const f = {
    ...base,
    requeue: async (user: string, conversation: string, ids: string[] | null = null) =>
      (await base.one(`select public.requeue_agent_messages($1,$2,$3::uuid[]) as result`, [user, conversation, ids])).result as Requeue,
    openExternal: async (user: string, session: string) =>
      (await base.one(`select public.open_agent_session_external($1,$2) as result`, [user, session])).result as { status: string },
    resumeHere: async (user: string, session: string) =>
      (await base.one(`select public.resume_agent_session_here($1,$2) as result`, [user, session])).result as { status: string },
    text: (n: number) => `메시지 ${n}`,
    async setMessage(id: string, state: string, reason: string | null = null, extra: Record<string, unknown> = {}) {
      await base.updateRow("conversation_messages", id, { delivery_state: state, delivery_reason: reason, ...extra });
    },
    /** 연결(Codex)과 대화를 갖고 세션은 아직 없는 사용자 */
    async plainWorld(adapter = "agent:codex") {
      const user = await base.user();
      const bridge = await base.bridge(user);
      const connection = await base.agentConnection(user, bridge, { adapter });
      const conversation = await base.agentConversation(user, connection);
      return { user, bridge, connection, conversation };
    },
    /** 실제 외부 id를 가진 bound 세션에 묶인 대화 둘 + 턴이 끝난 task 하나 */
    async sessionWorld(status = "bound") {
      const w = await f.plainWorld();
      const session = await base.session(w.user, w.connection, { status });
      const second = await base.agentConversation(w.user, w.connection, session);
      await base.updateRow("conversations", w.conversation, { agent_session_id: session });
      const run = await base.agentRun(w.user, await base.action(w.user), { agent_session_id: session });
      const task = await base.task(w.user, run, session, { state: "idle" });
      return { ...w, session, second, run, task };
    },
    async eventLines(conversation: string) {
      return base.q(`select seq,role,text,content,delivery_state from public.conversation_messages where conversation_id=$1 and role='event' order by seq`, [conversation]);
    },
    async metrics(user: string, type: string) {
      return base.q(`select type,props from public.metric_events where user_id=$1 and type=$2 order by props::text`, [user, type]);
    },
  };
  return f;
}

export function agentConversationApiTests(db: () => ConversationAgentDb) {
  const f = agentConversationApiFixtures(db);
  const count = (table: string, user: string) => f.count(`select 1 from public.${table} where user_id=$1`, [user]);
  const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

  describe("마이그레이션 파일 모양", () => {
    const read = () => readFileSync(path.resolve(__dirname, "../../supabase/migrations", D1D_MIGRATION), "utf8");
    const code = (migration: string) => migration.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n").trim();

    it("한 트랜잭션, lock_timeout 5초, 잠금은 모두 NOWAIT, 새 함수는 정확히 셋이고 기존 함수는 교체하지 않는다", () => {
      const sql = code(read());
      expect(sql.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
      expect(sql.endsWith("commit;")).toBe(true);
      expect(sql.match(/^begin;$/gm)).toHaveLength(1);
      expect(sql.match(/^commit;$/gm)).toHaveLength(1);
      const locks = sql.match(/^lock table .*;$/gm) ?? [];
      expect(locks.length).toBeGreaterThan(0);
      for (const lock of locks) expect(lock).toMatch(/ nowait;$/);
      expect([...sql.matchAll(/create function public\.([a-z_]+)/g)].map((m) => m[1]).sort()).toEqual(D1D_FUNCTIONS);
      expect(sql).not.toMatch(/create or replace function/);
      expect(sql).not.toMatch(/create table|create trigger|create index|create unique index/);
      // 바꾸는 표는 metric_events뿐이다 (CHECK · 정책). 다른 표의 DDL 0
      expect([...new Set([...sql.matchAll(/alter table public\.([a-z_]+)/g)].map((m) => m[1]))]).toEqual(["metric_events"]);
    });

    it("공통 metric 블록 v2를 글자 그대로 넣는다 (코디네이터 소유)", () => {
      const block = read().match(/-- OA 공통 블록:[\s\S]*?with check \(user_id = \(select auth.uid\(\)\) and type in \('app_opened', 'assistant_opened'\)\);\n/)?.[0];
      expect(block).toBeDefined();
      expect(createHash("sha256").update(block!).digest("hex")).toBe(METRIC_BLOCK_V2_SHA256);
    });

    it("새 함수 셋은 service_role만 실행한다 (권한 블록)", () => {
      const migration = read();
      for (const name of D1D_FUNCTIONS) expect(migration).toContain(`'${name}'`);
      expect(migration).toContain("revoke all on function public.%I from public, anon, authenticated");
      expect(migration).toContain("grant execute on function public.%I to service_role");
    });
  });

  describe("S3 권한 · 모양: 서버 전용 invoker 함수", () => {
    it("새 함수 셋: security invoker, search_path 비움, anon · authenticated 실행 거절, service_role만 실행", async () => {
      const rows = await f.q(
        `select p.proname,p.prosecdef,p.proconfig,has_function_privilege('anon',p.oid,'execute') as anon,has_function_privilege('authenticated',p.oid,'execute') as app,has_function_privilege('service_role',p.oid,'execute') as server
           from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any($1) order by p.proname`,
        [D1D_FUNCTIONS],
      );
      expect(rows).toHaveLength(3);
      for (const row of rows) expect(row).toMatchObject({ prosecdef: false, proconfig: ['search_path=""'], anon: false, app: false, server: true });
    });

    it("앱(authenticated)이 직접 부르면 거절된다", async () => {
      const w = await f.sessionWorld();
      const calls: [string, unknown[]][] = [
        [`select public.requeue_agent_messages($1,$2,null)`, [w.user, w.conversation]],
        [`select public.open_agent_session_external($1,$2)`, [w.user, w.session]],
        [`select public.resume_agent_session_here($1,$2)`, [w.user, w.session]],
      ];
      for (const [sql, params] of calls) await rejects(db().asUser(w.user, () => db().query(sql, params)), /permission denied/);
    });
  });

  describe("metric_events: 공통 블록 v2", () => {
    it("type은 기존 16개 + 새 5개뿐이다. 새 type은 서버(service role)가 쓰고 props에는 id · 종류 · 이유 코드만 담는다", async () => {
      const user = await f.user();
      for (const type of [...METRIC_TYPES_V1, ...METRIC_TYPES_NEW]) {
        await f.q(`insert into public.metric_events (user_id,type,props) values ($1,$2,'{"kind":"x"}')`, [user, type]);
      }
      expect(await count("metric_events", user)).toBe(METRIC_TYPES_V1.length + METRIC_TYPES_NEW.length);
      for (const bad of ["message_sent", "question_answer", "session_rename", "Session_Resumed", ""]) {
        await rejects(f.q(`insert into public.metric_events (user_id,type) values ($1,$2)`, [user, bad]), /metric_events_type_check/);
      }
      await rejects(f.q(`insert into public.metric_events (user_id,type,props) values ($1,'message_resent','[]')`, [user]), /metric_events_props_shape/);
    });

    it("앱이 직접 쓸 수 있는 type은 app_opened · assistant_opened뿐이다 (새 type 5개는 앱 insert 거절)", async () => {
      const user = await f.user();
      const insert = (type: string) => db().asUser(user, () => db().query(`insert into public.metric_events (type) values ($1)`, [type]));
      await insert("app_opened");
      await insert("assistant_opened");
      for (const type of [...METRIC_TYPES_NEW, "context_attached", "agent_message_sent", "stop_requested"]) await rejects(insert(type), /row-level security|permission denied/);
    });
  });

  describe("S1 requeue_agent_messages (Send again)", () => {
    async function pending(w: Awaited<ReturnType<typeof f.plainWorld>>, n = 6) {
      const ids: string[] = [];
      for (let i = 1; i <= n; i++) ids.push(String((await f.post(w.user, w.conversation, randomUUID(), f.text(i))).message_id));
      return ids;
    }

    it("대상 상태(not_sent · expired)만 다시 대기한다: queued, 이유 비움, 보관 24시간 새로, seq 순, 다른 상태는 not_eligible", async () => {
      const w = await f.plainWorld();
      const [notSent, expired, queued, dispatched, cancelled] = await pending(w, 5);
      await f.setMessage(notSent, "not_sent", "write_gate_closed", { delivery_expires_at: new Date(Date.now() + 3600_000).toISOString() });
      await f.setMessage(expired, "expired", "session_busy", { delivery_expires_at: new Date(Date.now() - 3600_000).toISOString() });
      await f.setMessage(dispatched, "dispatched");
      await f.setMessage(cancelled, "cancelled");
      const before = await f.q(`select id,delivery_state,delivery_reason,delivery_expires_at from public.conversation_messages where id=any($1) order by seq`, [[queued, dispatched, cancelled]]);

      const result = await f.requeue(w.user, w.conversation, null);
      expect(result.status).toBe("ok");
      expect(result.messages).toEqual([
        { message_id: notSent, result: "requeued" },
        { message_id: expired, result: "requeued" },
      ]);
      for (const id of [notSent, expired]) {
        expect(await f.msg(id)).toMatchObject({ delivery_state: "queued", delivery_reason: null });
        const left = await f.one(`select (delivery_expires_at - public.db_now()) between interval '23 hours 59 minutes' and interval '24 hours' as fresh from public.conversation_messages where id=$1`, [id]);
        expect(left).toEqual({ fresh: true });
      }
      // 이름을 주지 않은 호출은 대상 상태만 본다: 나머지 행은 그대로
      expect(await f.q(`select id,delivery_state,delivery_reason,delivery_expires_at from public.conversation_messages where id=any($1) order by seq`, [[queued, dispatched, cancelled]])).toEqual(before);

      // 이름을 준 호출: 대상 상태가 아니면 건너뛴다 (cancelled는 끝 상태: OD-8)
      const named = await f.requeue(w.user, w.conversation, [cancelled, dispatched, queued]);
      expect(named.messages).toEqual([
        { message_id: queued, result: "skipped", reason: "not_eligible" },
        { message_id: dispatched, result: "skipped", reason: "not_eligible" },
        { message_id: cancelled, result: "skipped", reason: "not_eligible" },
      ]);
    });

    it("두 번 눌러도 다시 대기하지 않는다: 이미 queued이면 건너뛰고 지표도 늘지 않는다", async () => {
      const w = await f.plainWorld();
      const [a, b] = await pending(w, 2);
      await f.setMessage(a, "not_sent", "not_connected");
      await f.setMessage(b, "expired", null, { delivery_expires_at: new Date(Date.now() - 1000).toISOString() });
      expect((await f.requeue(w.user, w.conversation)).messages.map((m) => m.result)).toEqual(["requeued", "requeued"]);
      expect(await f.metrics(w.user, "message_resent")).toHaveLength(2);
      const again = await f.requeue(w.user, w.conversation);
      expect(again.messages).toEqual([]);
      expect((await f.requeue(w.user, w.conversation, [a, b])).messages.map((m) => `${m.result}/${m.reason}`)).toEqual(["skipped/not_eligible", "skipped/not_eligible"]);
      expect(await f.metrics(w.user, "message_resent")).toHaveLength(2);
    });

    it("지표 message_resent: 다시 대기한 메시지마다 한 줄, props는 adapter · 이전 상태 · 이유 코드뿐 (글 0)", async () => {
      const w = await f.plainWorld();
      const [a, b] = await pending(w, 2);
      await f.setMessage(a, "not_sent", "usage_limited");
      await f.setMessage(b, "expired", null, { delivery_expires_at: new Date(Date.now() - 1000).toISOString() });
      await f.requeue(w.user, w.conversation);
      const rows = await f.metrics(w.user, "message_resent");
      expect(rows.map((r) => r.props)).toEqual([
        { adapter: "agent:codex", from: "expired" },
        { adapter: "agent:codex", from: "not_sent", reason: "usage_limited" },
      ]);
      expect(JSON.stringify(rows)).not.toContain(f.text(1));
    });

    it("이름을 준 id가 이 대화 · 이 사용자의 것이 아니면 not_found로 건너뛴다 (다른 대화의 행은 바뀌지 않는다)", async () => {
      const w = await f.plainWorld();
      const [own] = await pending(w, 1);
      await f.setMessage(own, "not_sent", "not_connected");
      const otherConversation = await f.agentConversation(w.user, w.connection);
      const elsewhere = String((await f.post(w.user, otherConversation, randomUUID(), "다른 대화")).message_id);
      await f.setMessage(elsewhere, "not_sent", "not_connected");
      const stranger = await f.plainWorld();
      const foreign = String((await f.post(stranger.user, stranger.conversation, randomUUID(), "남의 글")).message_id);
      await f.setMessage(foreign, "not_sent", "not_connected");
      const missing = randomUUID();
      // 같은 대화의 사용자 글이 아닌 행(에이전트 글 · event 줄)의 id도 이 함수의 대상이 아니다
      const agentText = await f.insertRow("conversation_messages", { user_id: w.user, conversation_id: w.conversation, seq: 99, role: "assistant", text: "에이전트 글" });

      const result = await f.requeue(w.user, w.conversation, [foreign, own, elsewhere, missing, agentText]);
      expect(result.messages).toEqual([
        { message_id: own, result: "requeued" },
        { message_id: foreign, result: "skipped", reason: "not_found" },
        { message_id: elsewhere, result: "skipped", reason: "not_found" },
        { message_id: missing, result: "skipped", reason: "not_found" },
        { message_id: agentText, result: "skipped", reason: "not_found" },
      ]);
      expect(await f.msg(elsewhere)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "not_connected" });
      expect(await f.msg(foreign)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "not_connected" });
    });

    it("대화 쪽 거절: 없거나 남의 대화는 not_found, taskforce 대화는 wrong_target, 쓰기 0", async () => {
      const w = await f.plainWorld();
      const stranger = await f.plainWorld();
      const taskforce = await f.conversation(w.user);
      const writes = async () => [await count("metric_events", w.user), await count("conversation_messages", w.user)];
      const before = await writes();
      expect(await f.requeue(w.user, stranger.conversation)).toEqual({ status: "not_found", messages: [] });
      expect(await f.requeue(w.user, randomUUID())).toEqual({ status: "not_found", messages: [] });
      expect(await f.requeue(w.user, taskforce)).toEqual({ status: "wrong_target", messages: [] });
      expect(await writes()).toEqual(before);
    });

    it("답이 된 글(refs.answer_for)과 결과 불명(unknown_outcome)은 다시 보내지 않는다", async () => {
      const w = await f.turnWorld(true);
      const first = await f.start(w.user, w.message);
      expect(first.status).toBe("started");
      await f.updateRow("execution_steps", first.step_id!, { state: "unknown_outcome" });
      const answer = String((await f.post(w.user, w.conversation, randomUUID(), "답")).message_id);
      await f.setMessage(answer, "not_sent", "usage_limited", { refs: { answer_for: [first.agent_task_id, "request"] } });
      const result = await f.requeue(w.user, w.conversation, [w.message, answer]);
      expect(result.messages).toEqual([
        { message_id: w.message, result: "skipped", reason: "unknown_outcome" },
        { message_id: answer, result: "skipped", reason: "not_eligible" },
      ]);
      expect(await f.msg(answer)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "usage_limited" });
      expect(await f.metrics(w.user, "message_resent")).toEqual([]);
    });

    it("인자: 이름 목록은 1–50개 (빈 배열 · 51개는 22023)", async () => {
      const w = await f.plainWorld();
      await rejects(f.requeue(w.user, w.conversation, []), /requeue_agent_messages: message ids must be 1-50/);
      await rejects(f.requeue(w.user, w.conversation, Array.from({ length: 51 }, () => randomUUID())), /requeue_agent_messages: message ids must be 1-50/);
      expect((await f.requeue(w.user, w.conversation, Array.from({ length: 50 }, () => randomUUID()))).messages).toHaveLength(50);
    });
  });

  describe("R10 AC-22 Send again: 보낸 순서대로 한 번씩", () => {
    it("not_sent 둘 → deliver → 첫째 started · 둘째 queued(session_busy) → 턴이 끝나면 둘째 started → 다시 deliver는 새 task 0", async () => {
      const world = await f.plainWorld();
      const first = String((await f.post(world.user, world.conversation, randomUUID(), "첫째")).message_id);
      const second = String((await f.post(world.user, world.conversation, randomUUID(), "둘째")).message_id);
      for (const id of [first, second]) await f.q(`select public.mark_agent_message_not_sent($1,$2,'not_connected')`, [world.user, id]);

      const requeued = await f.requeue(world.user, world.conversation);
      expect(requeued.messages).toEqual([{ message_id: first, result: "requeued" }, { message_id: second, result: "requeued" }]);

      // 앱 route가 하듯 seq 순으로 하나씩 시작한다
      const a = await f.start(world.user, first);
      const b = await f.start(world.user, second);
      expect(a.status).toBe("started");
      expect(b).toEqual({ status: "queued", reason: "session_busy" });
      expect(await f.msg(second)).toMatchObject({ delivery_state: "queued", delivery_reason: "session_busy" });

      // D2a의 "턴 끝" 계기를 시험이 대신한다: accepted → turn_completed, 그리고 다음 대기 메시지 시작
      const session = String((await f.one(`select agent_session_id from public.agent_tasks where id=$1`, [a.agent_task_id])).agent_session_id);
      await f.updateRow("execution_steps", a.step_id!, { state: "calling", lease_owner: "fixture" });
      const ctx = { session, task: a.agent_task_id!, turn: a.turn_seq! };
      expect(await f.apply(world.user, f.event(ctx, "accepted"))).toMatchObject({ applied: true });
      expect(await f.apply(world.user, f.event(ctx, "turn_completed"))).toMatchObject({ applied: true, task_state: "idle" });
      expect(await f.next(world.user, session)).toMatchObject({ status: "started", turn_seq: 2 });
      expect(await f.msg(second)).toMatchObject({ delivery_state: "dispatched" });

      // 다시 눌러도: 둘 다 dispatched라 건너뛰고 새 task · 단계 0
      const again = await f.requeue(world.user, world.conversation, [first, second]);
      expect(again.messages.map((m) => `${m.result}/${m.reason}`)).toEqual(["skipped/not_eligible", "skipped/not_eligible"]);
      expect(await count("agent_tasks", world.user)).toBe(2);
      expect(await f.count(`select 1 from public.execution_steps where user_id=$1 and kind='agent_message'`, [world.user])).toBe(2);
    });
  });

  describe("R11 AC-26 보관 24시간", () => {
    it("24시간 지난 queued · not_sent는 만료되고 자동 선택에서 빠진다 → Send again이 새 24시간을 주고 한 번만 전달된다", async () => {
      const w = await f.turnWorld(true);
      const old = new Date(Date.now() - 25 * 3600_000).toISOString();
      const second = String((await f.post(w.user, w.conversation, randomUUID(), "둘째")).message_id);
      await f.setMessage(w.message, "queued", "session_busy", { delivery_expires_at: old });
      await f.setMessage(second, "not_sent", "usage_limited", { delivery_expires_at: old });

      expect(await f.expire(new Date())).toBe(2);
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired", delivery_reason: "session_busy" });
      expect(await f.one(`select public.next_queued_agent_message($1,$2) as id`, [w.user, w.session])).toEqual({ id: null });
      // 만료된 행은 전달 전 상태(queued · not_sent)가 아니라서 start_agent_turn이 건드리지 않는다
      expect(await f.start(w.user, w.message)).toEqual({ status: "already_dispatched" });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired" });
      expect(await count("agent_tasks", w.user)).toBe(0);

      const result = await f.requeue(w.user, w.conversation);
      expect(result.messages.map((m) => m.result)).toEqual(["requeued", "requeued"]);
      expect(await f.start(w.user, w.message)).toMatchObject({ status: "started" });
      expect((await f.start(w.user, w.message)).status).toBe("already_dispatched");
      expect(await count("agent_tasks", w.user)).toBe(1);
      expect(await f.expire(new Date())).toBe(0);
    });

    it("2,500행은 한 번에 1,000행씩 1,000 · 1,000 · 500 · 0으로 줄어든다 (sweep이 반복하는 근거)", async () => {
      const w = await f.plainWorld();
      await f.q(
        `insert into public.conversation_messages (user_id,conversation_id,seq,role,client_message_id,text,delivery_state,delivery_expires_at)
         select $1,$2,n,'user',gen_random_uuid(),'x','queued',now() - interval '1 hour' from generate_series(1,2500) n`,
        [w.user, w.conversation],
      );
      expect([await f.expire(new Date()), await f.expire(new Date()), await f.expire(new Date()), await f.expire(new Date())]).toEqual([1000, 1000, 500, 0]);
    });
  });

  describe("S2 open_agent_session_external · resume_agent_session_here", () => {
    it("bound 세션을 external로: 묶인 대화마다 event 한 줄, 지표 한 줄, 쓰기는 세션 상태 + event 줄 + 지표뿐", async () => {
      const w = await f.sessionWorld();
      const before = {
        tasks: await f.q(`select id,state from public.agent_tasks where user_id=$1 order by id`, [w.user]),
        runs: await f.q(`select id,state from public.execution_runs where user_id=$1 order by id`, [w.user]),
        messages: await count("conversation_messages", w.user),
      };
      expect(await f.openExternal(w.user, w.session)).toEqual({ status: "external" });
      expect(await f.one(`select status from public.agent_sessions where id=$1`, [w.session])).toEqual({ status: "external" });
      for (const conversation of [w.conversation, w.second]) {
        const lines = await f.eventLines(conversation);
        expect(lines).toHaveLength(1);
        expect(lines[0]).toMatchObject({ role: "event", text: "Opened in Terminal", content: { kind: "event" }, delivery_state: null });
      }
      expect((await f.metrics(w.user, "session_opened_external")).map((r) => r.props)).toEqual([{ adapter: "agent:codex" }]);
      // event 줄을 쓴 대화는 목록에서 위로 올라온다 (last_message_at)
      for (const conversation of [w.conversation, w.second]) {
        expect((await f.one(`select last_message_at is not null as touched from public.conversations where id = $1`, [conversation])).touched).toBe(true);
      }
      expect({
        tasks: await f.q(`select id,state from public.agent_tasks where user_id=$1 order by id`, [w.user]),
        runs: await f.q(`select id,state from public.execution_runs where user_id=$1 order by id`, [w.user]),
        messages: await count("conversation_messages", w.user) - 2,
      }).toEqual(before);
    });

    it("이미 external이면 unchanged (쓰기 0, 지표 늘지 않음)", async () => {
      const w = await f.sessionWorld();
      await f.openExternal(w.user, w.session);
      expect(await f.openExternal(w.user, w.session)).toEqual({ status: "unchanged" });
      expect(await f.eventLines(w.conversation)).toHaveLength(1);
      expect(await f.metrics(w.user, "session_opened_external")).toHaveLength(1);
    });

    it.each(IN_PROGRESS)("턴이 진행 중(%s)이면 busy: 세션 · 대화 · 지표 변화 0", async (state) => {
      const w = await f.sessionWorld();
      await f.updateRow("agent_tasks", w.task, { state: "idle" });
      const run = await f.agentRun(w.user, await f.action(w.user), { agent_session_id: w.session });
      await f.task(w.user, run, w.session, state === "awaiting_answer" ? { state, pending_question: AGENT_QUESTION } : state === "unreachable" ? { state, last_live_state: "running" } : { state });
      expect(await f.openExternal(w.user, w.session)).toEqual({ status: "busy" });
      expect(await f.one(`select status from public.agent_sessions where id=$1`, [w.session])).toEqual({ status: "bound" });
      expect(await f.eventLines(w.conversation)).toEqual([]);
      expect(await count("metric_events", w.user)).toBe(0);
    });

    it("첫 턴의 실제 세션 id를 아직 못 받은 세션(pending:)은 not_started, 닫힌 세션 · unreachable 세션은 not_bound, 남의 세션은 not_found", async () => {
      const w = await f.sessionWorld();
      const pending = await f.session(w.user, w.connection, { external_session_id: `pending:${randomUUID()}` });
      const closed = await f.session(w.user, w.connection, { status: "closed" });
      const lost = await f.session(w.user, w.connection, { status: "unreachable" });
      const stranger = await f.sessionWorld();
      expect(await f.openExternal(w.user, pending)).toEqual({ status: "not_started" });
      expect(await f.openExternal(w.user, closed)).toEqual({ status: "not_bound" });
      expect(await f.openExternal(w.user, lost)).toEqual({ status: "not_bound" });
      expect(await f.openExternal(w.user, stranger.session)).toEqual({ status: "not_found" });
      expect(await f.openExternal(w.user, randomUUID())).toEqual({ status: "not_found" });
      for (const id of [pending, closed, lost]) expect((await f.one(`select status from public.agent_sessions where id=$1`, [id])).status).not.toBe("external");
      expect(await count("metric_events", w.user)).toBe(0);
    });

    it("external 동안 새 메시지는 전달되지 않고 queued/session_external로 쌓인다 → Resume here가 bound로 되돌리고 보낸 순서대로 첫째부터 시작한다", async () => {
      const w = await f.sessionWorld();
      expect(await f.openExternal(w.user, w.session)).toEqual({ status: "external" });
      const first = String((await f.post(w.user, w.conversation, randomUUID(), "첫째")).message_id);
      const second = String((await f.post(w.user, w.second, randomUUID(), "둘째")).message_id);
      // 대화가 다른 두 메시지의 순서는 만든 시각이다: 같은 밀리초에 만들어져도 순서가 흔들리지 않게 시각을 고정한다
      await f.updateRow("conversation_messages", first, { created_at: new Date(Date.now() - 2000).toISOString() });
      await f.updateRow("conversation_messages", second, { created_at: new Date(Date.now() - 1000).toISOString() });
      for (const id of [first, second]) expect(await f.start(w.user, id)).toEqual({ status: "queued", reason: "session_external" });
      expect(await count("agent_tasks", w.user)).toBe(1); // 처음부터 있던 idle task뿐
      expect(await f.one(`select public.next_queued_agent_message($1,$2) as id`, [w.user, w.session])).toEqual({ id: first });

      expect(await f.resumeHere(w.user, w.session)).toEqual({ status: "bound" });
      expect(await f.one(`select status from public.agent_sessions where id=$1`, [w.session])).toEqual({ status: "bound" });
      for (const conversation of [w.conversation, w.second]) {
        const lines = await f.eventLines(conversation);
        expect(lines.map((l) => l.text)).toEqual(["Opened in Terminal", "Resumed here"]);
      }
      expect((await f.metrics(w.user, "session_resumed")).map((r) => r.props)).toEqual([{ adapter: "agent:codex" }]);
      // 다음 메시지 시작은 TS가 commit 뒤에 부른다 (SQL은 순서만 정한다): 첫째가 먼저, 첫째가 끝나야 둘째
      expect((await f.next(w.user, w.session)).status).toBe("started");
      expect(await f.msg(first)).toMatchObject({ delivery_state: "dispatched" });
      expect(await f.start(w.user, second)).toEqual({ status: "queued", reason: "session_busy" });
    });

    it("Resume here: 이미 bound이면 unchanged, bound가 아닌 세션(closed · unreachable)과 external이 아닌 세션은 not_external, 남의 세션은 not_found", async () => {
      const w = await f.sessionWorld();
      const closed = await f.session(w.user, w.connection, { status: "closed" });
      const stranger = await f.sessionWorld("external");
      expect(await f.resumeHere(w.user, w.session)).toEqual({ status: "unchanged" });
      expect(await f.resumeHere(w.user, closed)).toEqual({ status: "not_external" });
      expect(await f.resumeHere(w.user, stranger.session)).toEqual({ status: "not_found" });
      expect(await f.resumeHere(w.user, randomUUID())).toEqual({ status: "not_found" });
      expect(await f.one(`select status from public.agent_sessions where id=$1`, [stranger.session])).toEqual({ status: "external" });
      expect(await f.eventLines(w.conversation)).toEqual([]);
      expect(await count("metric_events", w.user)).toBe(0);
    });
  });

  describe("R7 AC-10: 쓰기 gate가 닫힌 Claude Code 대화는 단계를 만들지 않는다", () => {
    it("not_sent/write_gate_closed로 표시하고 agent_tasks · execution_steps · runs · 지표 0 (D2a 보안 검토 P1 방어도 같은 표시 경로)", async () => {
      const w = await f.plainWorld("agent:claude-code");
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "고쳐 줘")).message_id);
      expect((await f.one(`select public.mark_agent_message_not_sent($1,$2,'write_gate_closed') as result`, [w.user, message])).result).toEqual({ status: "not_sent", reason: "write_gate_closed" });
      expect(await f.msg(message)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "write_gate_closed" });
      for (const table of ["agent_tasks", "execution_steps", "execution_runs", "agent_sessions", "actions", "metric_events"]) expect(await count(table, w.user)).toBe(0);
      // Send again은 상태만 되돌린다 (전달은 TS가 같은 등급 판정으로 다시 not_sent로 만든다)
      expect((await f.requeue(w.user, w.conversation)).messages).toEqual([{ message_id: message, result: "requeued" }]);
      expect(await count("agent_tasks", w.user)).toBe(0);
    });
  });
}
