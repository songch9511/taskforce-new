import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { MAX_LIVE_EXTERNAL_TASKS } from "../../src/lib/execution/limits";

import { conversationAgentFixtures, type ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 작성만: 실제 Postgres의 두 연결과 pg_stat_activity로 잠금 대기를 확인한다. PGlite는 이 경합을 증명하지 않는다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(일회용 데이터베이스를 만들 수 있는 실제 Postgres)이 필요합니다.");
const DB_NAME = `taskforce_agent_turn_start_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let bPid: number;

async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '15s'");
  return client;
}

beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(DB_NAME);
  b = await connect(DB_NAME);
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

afterEach(async () => {
  // A를 먼저 놓아 B의 대기를 풀어 준 뒤 정리한다.
  await a?.query("rollback").catch(() => {});
  await b?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

const db = (): ConversationAgentDb => ({
  query: async (sql, params) => (await setup.query(sql, params)).rows,
  asUser: async <T,>(user: string, fn: () => Promise<T>) => {
    await setup.query("set role authenticated");
    await setup.query("select set_config('request.jwt.claim.sub', $1, false)", [user]);
    try {
      return await fn();
    } finally {
      await setup.query("reset role");
      await setup.query("select set_config('request.jwt.claim.sub', '', false)");
    }
  },
});
const f = conversationAgentFixtures(db);
type Turn = { status: string; action_id: string | null; run_id: string | null; agent_task_id: string | null; turn_seq: number | null; step_id: string | null; created_action: boolean; reason?: string; candidates?: string[] };
const start = async (client: pg.Client, user: string, message: string, actions: string[] = []) =>
  (await client.query<{ result: Turn }>("select public.start_agent_turn($1, $2, $3::uuid[], '{}'::uuid[], 'read_only', $4) as result", [user, message, actions, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
const next = async (client: pg.Client, user: string, session: string) => {
  const message = (await client.query<{ id: string | null }>("select public.next_queued_agent_message($1, $2) as id", [user, session])).rows[0].id;
  if (!message) return null;
  const { rows } = await client.query<{ actions: string[] }>(
    "select coalesce(refs->'agent_turn'->'action_ids', selected->'action_ids', '[]'::jsonb) as actions from public.conversation_messages where id=$1", [message],
  );
  const result = await start(client, user, message, rows[0].actions);
  if (result.status === "not_found" || result.status === "already_dispatched") {
    return (await client.query<{ result: Turn }>("select public.mark_agent_message_not_sent($1,$2,$3) as result", [user, message, result.status])).rows[0].result;
  }
  return result;
};
const openRun = async (client: pg.Client, user: string, session: string, action: string) =>
  (await client.query<{ id: string }>("select public.open_agent_conversation_run($1, $2, $3) as id", [user, session, action])).rows[0].id;

async function world() {
  const user = await f.user();
  const bridge = await f.bridge(user);
  const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
  const conversation = await f.agentConversation(user, connection);
  const first = await f.post(user, conversation, randomUUID(), "첫 요청\n원문 근거");
  const second = await f.post(user, conversation, randomUUID(), "다음 요청");
  return { user, connection, conversation, first: String(first.message_id), second: String(second.message_id) };
}

async function waitForLockWait() {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [bPid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("둘째 연결이 잠금을 기다리지 않는다");
}

async function expectOneTurn(user: string) {
  for (const table of ["actions", "agent_sessions", "execution_runs", "agent_tasks", "execution_steps"]) {
    expect(await f.count(`select 1 from public.${table} where user_id = $1`, [user])).toBe(1);
  }
  expect(await f.q("select state, turn_seq from public.agent_tasks where user_id = $1", [user])).toEqual([{ state: "dispatched", turn_seq: 1 }]);
  expect(await f.q("select state, kind from public.execution_steps where user_id = $1", [user])).toEqual([{ state: "prepared", kind: "agent_message" }]);
  expect(await f.count("select 1 from public.metric_events where user_id = $1 and type = 'agent_message_sent'", [user])).toBe(1);
}

describe("D1c-1 T2 대화 run unique 경합", () => {
  for (const finish of ["commit", "rollback"] as const) {
    it(`동시 run 열기: 먼저 ${finish}하면 재사용 또는 새 run 하나, plan 단계 없음`, async () => {
      const w = await world();
      const action = await f.action(w.user);
      const session = await f.session(w.user, w.connection);
      // 정책 생성 경합이 run unique 경합을 가리지 않게 미리 만든다.
      await f.q("insert into public.execution_policies (user_id) values ($1)", [w.user]);
      await a.query("begin");
      await b.query("begin");
      const first = await openRun(a, w.user, session, action);
      const waiting = openRun(b, w.user, session, action);
      await waitForLockWait();
      await a.query(finish);
      const second = await waiting;
      await b.query("commit");
      if (finish === "commit") expect(second).toBe(first);
      else expect(second).not.toBe(first);
      expect(await f.q("select id, kind, goal, agent_session_id, action_id from public.execution_runs where user_id = $1", [w.user])).toEqual([
        { id: second, kind: "conversation", goal: "agent", agent_session_id: session, action_id: action },
      ]);
      expect(await f.count("select 1 from public.execution_steps where run_id = $1", [second])).toBe(0);
    });
  }
});

describe("D1c-1 T4 첫 메시지와 재시도 경합", () => {
  it("한 대화의 첫 메시지 둘: 세션 없는 첫 턴이 직렬화되어 started + queued, Action·세션·run 하나", async () => {
    const w = await world();
    await a.query("begin");
    await b.query("begin");
    const first = await start(a, w.user, w.first);
    const waiting = start(b, w.user, w.second);
    await waitForLockWait();
    await a.query("commit");
    const second = await waiting;
    await b.query("commit");
    expect(first).toMatchObject({ status: "started", turn_seq: 1, created_action: true });
    expect(second.status).toBe("queued");
    await expectOneTurn(w.user);
    expect(await f.q("select delivery_state, delivery_reason from public.conversation_messages where id = $1", [w.second])).toEqual([{ delivery_state: "queued", delivery_reason: "session_busy" }]);
    expect((await f.one("select agent_session_id from public.conversations where id = $1", [w.conversation])).agent_session_id).toBeTruthy();
    expect(await f.count("select 1 from public.sources where user_id = $1 and kind = 'note'", [w.user])).toBe(1);
    expect(await f.q("select type, actor, rule, source_id from public.action_events where action_id = $1", [first.action_id])).toEqual([
      { type: "user_created", actor: "user", rule: "assistant_agent", source_id: null },
    ]);
  });

  it("같은 메시지 재시도는 잠금 뒤 already_dispatched: 작업·단계·지표 한 번", async () => {
    const w = await world();
    await a.query("begin");
    await b.query("begin");
    expect((await start(a, w.user, w.first)).status).toBe("started");
    const waiting = start(b, w.user, w.first);
    await waitForLockWait();
    await a.query("commit");
    expect((await waiting).status).toBe("already_dispatched");
    await b.query("commit");
    await expectOneTurn(w.user);
  });

  it("첫 턴 rollback 뒤 기다린 재시도가 턴 1을 만든다: Action·note·세션·intent 잔재 없음", async () => {
    const w = await world();
    await a.query("begin");
    await b.query("begin");
    const rolledBack = await start(a, w.user, w.first);
    const waiting = start(b, w.user, w.first);
    await waitForLockWait();
    await a.query("rollback");
    const retried = await waiting;
    await b.query("commit");
    expect(retried).toMatchObject({ status: "started", action_id: rolledBack.action_id, turn_seq: 1, created_action: true });
    expect(retried.run_id).not.toBe(rolledBack.run_id);
    await expectOneTurn(w.user);
    expect(await f.count("select 1 from public.sources where user_id = $1 and kind = 'note'", [w.user])).toBe(1);
    expect(await f.count("select 1 from public.execution_intents where user_id = $1", [w.user])).toBe(0);
  });
});

describe("D1c-1 T8 AC-33 세션 단위 직렬화", () => {
  it("같은 세션의 대화 둘이 동시에 시작하면 started + queued, 다음 턴은 2로 이어지고 run은 하나", async () => {
    const w = await world();
    await f.updateRow("conversation_messages", w.second, { delivery_state: "cancelled" });
    const session = await f.session(w.user, w.connection);
    await f.updateRow("conversations", w.conversation, { agent_session_id: session });
    const otherConversation = await f.agentConversation(w.user, w.connection, session);
    const other = await f.post(w.user, otherConversation, randomUUID(), "같은 세션의 다른 대화");
    await a.query("begin");
    await b.query("begin");
    const first = await start(a, w.user, w.first);
    const waiting = start(b, w.user, String(other.message_id));
    await waitForLockWait();
    await a.query("commit");
    expect((await waiting).status).toBe("queued");
    await b.query("commit");
    await expectOneTurn(w.user);
    expect((await f.one("select last_turn_seq from public.agent_sessions where id = $1", [session])).last_turn_seq).toBe(1);
    // 사건 수신 WP가 수행할 턴 종료를 fixture로 표현한다. 외부 호출은 실행하지 않는다.
    await f.updateRow("agent_tasks", String(first.agent_task_id), { state: "idle" });
    const next = await start(a, w.user, String(other.message_id));
    expect(next).toMatchObject({ status: "started", action_id: first.action_id, run_id: first.run_id, turn_seq: 2, created_action: false });
    expect(await f.q("select turn_seq from public.agent_tasks where agent_session_id = $1 order by turn_seq", [session])).toEqual([{ turn_seq: 1 }, { turn_seq: 2 }]);
    expect(await f.count("select 1 from public.execution_runs where agent_session_id = $1", [session])).toBe(1);
  });
});

it("T9 different sessions compete for the fifth live slot: one started, one queued", async () => {
  const w = await world();
  const action = await f.action(w.user);
  for (let i = 0; i < MAX_LIVE_EXTERNAL_TASKS - 1; i++) {
    const session = await f.session(w.user, w.connection);
    const run = await openRun(setup, w.user, session, action);
    await f.task(w.user, run, session, { state: "running", turn_seq: 1 });
  }
  const otherConversation = await f.agentConversation(w.user, w.connection);
  const other = await f.post(w.user, otherConversation, randomUUID(), "another session");
  await a.query("begin");
  await b.query("begin");
  const occupying = await start(a, w.user, w.first);
  expect(occupying.status).toBe("started");
  const waiting = start(b, w.user, String(other.message_id));
  await waitForLockWait();
  await a.query("commit");
  expect(await waiting).toMatchObject({ status: "queued", reason: "live_limit" });
  await b.query("commit");
  expect(await f.count("select 1 from public.agent_tasks where user_id=$1 and state in ('dispatched','accepted','running','unreachable')", [w.user])).toBe(MAX_LIVE_EXTERNAL_TASKS);
  const otherSession = String((await f.one("select agent_session_id from public.conversations where id=$1", [otherConversation])).agent_session_id);
  expect(await f.count("select 1 from public.actions where user_id=$1", [w.user])).toBe(2);
  await f.updateRow("agent_tasks", occupying.agent_task_id!, { state: "idle" });
  expect(await next(setup, w.user, otherSession)).toMatchObject({ status: "started", turn_seq: 1, created_action: true });
  expect(await f.count("select 1 from public.actions where user_id=$1", [w.user])).toBe(3);
});

describe("D1c-1 검토 정정 회귀", () => {
  it("직접 보낸 메시지는 승인 0, run/step에 원문 사본 0, 대화 id 보존", async () => {
    const w = await world();
    const turn = await start(setup, w.user, w.first);
    expect(turn.status).toBe("started");
    expect(await f.q("select kind from public.coordinator_pending_inputs($1) where kind='approval'", [w.user])).toEqual([]);
    expect(await f.q("select request, conversation_id from public.execution_runs where id=$1", [turn.run_id])).toEqual([{ request: "", conversation_id: w.conversation }]);
    expect(await f.q("select body, args, needs_approval from public.execution_steps where id=$1", [turn.step_id])).toEqual([{ body: "", args: { message_id: w.first }, needs_approval: false }]);
  });

  for (const status of ["done", "dropped"] as const) {
    it(`직전 이슈 ${status} 뒤 칩 없는 메시지는 새 Action으로 시작`, async () => {
      const w = await world();
      const first = await start(setup, w.user, w.first);
      await f.updateRow("agent_tasks", first.agent_task_id!, { state: "idle" });
      await f.updateRow("actions", first.action_id!, { status });
      await f.q("select public.stop_run($1,$2)", [w.user, first.run_id]);
      const second = await start(setup, w.user, w.second);
      expect(second).toMatchObject({ status: "started", turn_seq: 2, created_action: true });
      expect(second.action_id).not.toBe(first.action_id);
      expect(await f.count("select 1 from public.actions where user_id=$1", [w.user])).toBe(2);
    });
  }

  it("external 보류 첫 메시지와 둘째 메시지는 Action을 만들지 않고 복귀 뒤 한 Action을 공유", async () => {
    const w = await world();
    const session = await f.session(w.user, w.connection, { status: "external" });
    await f.updateRow("conversations", w.conversation, { agent_session_id: session });
    for (const message of [w.first, w.second]) expect(await start(setup, w.user, message)).toMatchObject({ status: "queued", reason: "session_external" });
    for (const table of ["actions", "sources", "action_events", "execution_runs", "agent_tasks"]) {
      expect(await f.count(`select 1 from public.${table} where user_id=$1`, [w.user])).toBe(0);
    }
    await f.updateRow("agent_sessions", session, { status: "bound" });
    expect(await start(setup, w.user, w.second)).toMatchObject({ status: "queued", reason: "queue_order" });
    const first = await next(setup, w.user, session);
    expect(first).toMatchObject({ status: "started", created_action: true });
    await f.updateRow("agent_tasks", first!.agent_task_id!, { state: "idle" });
    expect(await next(setup, w.user, session)).toMatchObject({ status: "started", action_id: first!.action_id, run_id: first!.run_id, turn_seq: 2, created_action: false });
    expect(await f.count("select 1 from public.actions where user_id=$1", [w.user])).toBe(1);
  });

  it("referent 입력을 기다리는 머리는 건너뛰고 선택 뒤 같은 메시지를 한 번 전달", async () => {
    const w = await world();
    const session = await f.session(w.user, w.connection);
    await f.updateRow("conversations", w.conversation, { agent_session_id: session });
    const choices = [await f.action(w.user), await f.action(w.user)];
    expect(await start(setup, w.user, w.first, choices)).toMatchObject({ status: "needs_referent", candidates: expect.arrayContaining(choices) });
    const second = await next(setup, w.user, session);
    expect(second).toMatchObject({ status: "started", turn_seq: 1 });
    expect(await f.q("select message_id from public.agent_tasks where id=$1", [second!.agent_task_id])).toEqual([{ message_id: w.second }]);
    await f.updateRow("agent_tasks", second!.agent_task_id!, { state: "idle" });
    await f.q("select public.set_agent_message_referent($1,$2,$3)", [w.user, w.first, choices[0]]);
    expect(await next(setup, w.user, session)).toMatchObject({ status: "started", action_id: choices[0], turn_seq: 2 });
    expect((await start(setup, w.user, w.first)).status).toBe("already_dispatched");
  });

  it("다른 대화의 늦은 메시지가 잠금을 먼저 얻어도 오래된 메시지를 추월하지 않는다", async () => {
    const w = await world();
    await f.updateRow("conversation_messages", w.second, { delivery_state: "cancelled" });
    const session = await f.session(w.user, w.connection);
    await f.updateRow("conversations", w.conversation, { agent_session_id: session });
    const otherConversation = await f.agentConversation(w.user, w.connection, session);
    const newer = String((await f.post(w.user, otherConversation, randomUUID(), "newer")).message_id);
    await f.updateRow("conversation_messages", w.first, { created_at: "2026-01-01T00:00:00Z" });
    await a.query("begin");
    await b.query("begin");
    expect(await start(a, w.user, newer)).toMatchObject({ status: "queued", reason: "queue_order" });
    const waiting = start(b, w.user, w.first);
    await waitForLockWait();
    await a.query("commit");
    const first = await waiting;
    await b.query("commit");
    expect(first).toMatchObject({ status: "started", turn_seq: 1 });
    await expectOneTurn(w.user);
    expect(await f.q("select message_id from public.agent_tasks where user_id=$1", [w.user])).toEqual([{ message_id: w.first }]);
    await f.updateRow("agent_tasks", first.agent_task_id!, { state: "idle" });
    expect(await next(setup, w.user, session)).toMatchObject({ status: "started", action_id: first.action_id, turn_seq: 2 });
  });
});

it("이미 묶인 대화 세션과 최초 bound_action_id는 다른 이슈를 시작해도 보존", async () => {
  const w = await world();
  const original = await f.action(w.user);
  const selected = await f.action(w.user);
  const session = await f.session(w.user, w.connection, { bound_action_id: original });
  await f.updateRow("conversations", w.conversation, { agent_session_id: session });
  expect(await start(setup, w.user, w.first, [selected, selected])).toMatchObject({ status: "started", action_id: selected, created_action: false });
  expect(await f.q("select agent_session_id from public.conversations where id=$1", [w.conversation])).toEqual([{ agent_session_id: session }]);
  expect(await f.q("select bound_action_id from public.agent_sessions where id=$1", [session])).toEqual([{ bound_action_id: original }]);
  expect(await f.count("select 1 from public.agent_sessions where user_id=$1", [w.user])).toBe(1);
});

it("메시지 잠금 뒤 바뀐 referent 후보를 재확인하고 invalid_referent를 줄에서 뺀다", async () => {
  const w = await world();
  const session = await f.session(w.user, w.connection);
  await f.updateRow("conversations", w.conversation, { agent_session_id: session });
  const choices = [await f.action(w.user), await f.action(w.user)];
  expect((await start(setup, w.user, w.first, choices)).status).toBe("needs_referent");
  await f.q("select public.set_agent_message_referent($1,$2,$3)", [w.user, w.first, choices[0]]);
  await a.query("begin");
  await b.query("begin");
  await a.query("update public.conversation_messages set refs=jsonb_set(refs, '{referent_candidates}', $2::jsonb) where id=$1", [w.first, JSON.stringify([choices[1]])]);
  const waiting = start(b, w.user, w.first);
  await waitForLockWait();
  await a.query("commit");
  expect(await waiting).toMatchObject({ status: "not_sent", reason: "invalid_referent" });
  await b.query("commit");
  expect(await f.q("select delivery_state, delivery_reason from public.conversation_messages where id=$1", [w.first])).toEqual([{ delivery_state: "not_sent", delivery_reason: "invalid_referent" }]);
  expect(await next(setup, w.user, session)).toMatchObject({ status: "started", turn_seq: 1 });
  expect(await f.q("select message_id from public.agent_tasks where user_id=$1", [w.user])).toEqual([{ message_id: w.second }]);
});

it("닫힌 세션의 첫 메시지는 not_sent/session_closed이고 Action을 만들지 않는다", async () => {
  const w = await world();
  const session = await f.session(w.user, w.connection, { status: "closed" });
  await f.updateRow("conversations", w.conversation, { agent_session_id: session });
  expect(await start(setup, w.user, w.first)).toMatchObject({ status: "not_sent", reason: "session_closed" });
  expect(await f.count("select 1 from public.actions where user_id=$1", [w.user])).toBe(0);
});

it("트랜잭션 시작 시각이 뒤집혀도 같은 대화에서는 created_at보다 seq를 우선", async () => {
  const w = await world();
  const session = await f.session(w.user, w.connection);
  const conversation = await f.agentConversation(w.user, w.connection, session);
  await a.query("begin");
  // now()를 먼저 고정한 트랜잭션이 나중에 seq 2를 적는다.
  await a.query("select now()");
  const first = String((await f.post(w.user, conversation, randomUUID(), "seq 1")).message_id);
  const second = String((await a.query<{ message_id: string }>(
    "select * from public.conversation_post_message($1,$2,$3,$4,$5::jsonb,75)",
    [w.user, conversation, randomUUID(), "seq 2", JSON.stringify({ action_ids: [], run_ids: [], artifact_ids: [] })],
  )).rows[0].message_id);
  await a.query("commit");
  expect(await f.q("select newer.created_at < older.created_at as inverted from public.conversation_messages newer, public.conversation_messages older where newer.id=$1 and older.id=$2", [second, first])).toEqual([{ inverted: true }]);
  expect(await start(setup, w.user, second)).toMatchObject({ status: "queued", reason: "queue_order" });
  const turn = await next(setup, w.user, session);
  expect(turn).toMatchObject({ status: "started", turn_seq: 1 });
  expect(await f.q("select message_id from public.agent_tasks where id=$1", [turn!.agent_task_id])).toEqual([{ message_id: first }]);
  await f.updateRow("agent_tasks", turn!.agent_task_id!, { state: "idle" });
  expect(await next(setup, w.user, session)).toMatchObject({ status: "started", turn_seq: 2, action_id: turn!.action_id });
});

it("삭제된 저장 칩은 not_sent/not_found로 빼고 다음 메시지를 전달", async () => {
  const w = await world();
  const session = await f.session(w.user, w.connection);
  await f.updateRow("conversations", w.conversation, { agent_session_id: session });
  const deleted = await f.action(w.user);
  await f.updateRow("conversation_messages", w.first, { selected: { action_ids: [deleted], run_ids: [], artifact_ids: [] } });
  await f.q("delete from public.actions where id=$1", [deleted]);
  expect(await next(setup, w.user, session)).toMatchObject({ status: "not_sent", reason: "not_found" });
  expect(await f.q("select delivery_state, delivery_reason from public.conversation_messages where id=$1", [w.first])).toEqual([{ delivery_state: "not_sent", delivery_reason: "not_found" }]);
  const turn = await next(setup, w.user, session);
  expect(turn).toMatchObject({ status: "started", turn_seq: 1 });
  expect(await f.q("select message_id from public.agent_tasks where id=$1", [turn!.agent_task_id])).toEqual([{ message_id: w.second }]);
});

it("실패하지 않은 단계를 not_sent로 되돌린 메시지는 already_dispatched로 줄에서 제외", async () => {
  const w = await world();
  const first = await start(setup, w.user, w.first);
  const session = String((await f.one("select agent_session_id from public.conversations where id=$1", [w.conversation])).agent_session_id);
  await f.updateRow("agent_tasks", first.agent_task_id!, { state: "idle" });
  await f.updateRow("conversation_messages", w.first, { delivery_state: "not_sent" });
  expect(await next(setup, w.user, session)).toMatchObject({ status: "not_sent", reason: "already_dispatched" });
  expect(await f.q("select delivery_state, delivery_reason from public.conversation_messages where id=$1", [w.first])).toEqual([{ delivery_state: "not_sent", delivery_reason: "already_dispatched" }]);
  const second = await next(setup, w.user, session);
  expect(second).toMatchObject({ status: "started", turn_seq: 2, action_id: first.action_id });
  expect(await f.count("select 1 from public.agent_tasks where message_id=$1", [w.first])).toBe(1);
});
