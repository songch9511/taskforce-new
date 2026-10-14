import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { MAX_LIVE_EXTERNAL_TASKS } from "../../src/lib/execution/limits";

import { agentConversationApiFixtures } from "../db/agent-conversation-api.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// OA D1d-s 실제 Postgres 경합 (P1–P4): 두 연결로 잠금 대기와 교착을 확인한다. PGlite는 이 경합을 증명하지 않는다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(일회용 데이터베이스를 만들 수 있는 실제 Postgres)이 필요합니다.");
const DB_NAME = `taskforce_agent_conversation_api_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let c: pg.Client;
let aPid: number;
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
  c = await connect(DB_NAME);
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

afterEach(async () => {
  // A를 먼저 놓아 B의 대기를 풀어 준 뒤 정리한다.
  await a?.query("rollback").catch(() => {});
  await b?.query("rollback").catch(() => {});
  await c?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), c?.end(), setup?.end()]);
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
const f = agentConversationApiFixtures(db);

type Turn = { status: string; reason?: string; agent_task_id?: string; step_id?: string };
type Requeue = { status: string; messages: { message_id: string; result: string; reason?: string }[] };
const start = async (client: pg.Client, user: string, message: string) =>
  (await client.query<{ result: Turn }>("select public.start_agent_turn($1,$2,'{}','{}','read_only',$3) as result", [user, message, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
const route = async (client: pg.Client, user: string, message: string) =>
  (await client.query<{ result: Turn }>("select public.route_agent_message($1,$2,'read_only',$3) as result", [user, message, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
const startAuto = async (client: pg.Client, user: string, message: string) =>
  (await client.query<{ result: Turn }>("select public.start_agent_turn_auto($1,$2,'read_only',$3) as result", [user, message, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
const requeue = async (client: pg.Client, user: string, conversation: string, ids: string[] | null = null) =>
  (await client.query<{ result: Requeue }>("select public.requeue_agent_messages($1,$2,$3::uuid[]) as result", [user, conversation, ids])).rows[0].result;
const expire = async (client: pg.Client) => Number((await client.query<{ n: number }>("select public.conversation_expire_agent_messages(now()) as n")).rows[0].n);
const open = async (client: pg.Client, user: string, session: string) =>
  (await client.query<{ result: { status: string } }>("select public.open_agent_session_external($1,$2) as result", [user, session])).rows[0].result.status;
const resume = async (client: pg.Client, user: string, session: string) =>
  (await client.query<{ result: { status: string } }>("select public.resume_agent_session_here($1,$2) as result", [user, session])).rows[0].result.status;
const stop = async (client: pg.Client, user: string, session: string) =>
  (await client.query<{ result: { tasks?: unknown[]; status?: string } }>("select public.stop_agent_session($1,$2,'assistant','turn') as result", [user, session])).rows[0].result;

async function waitForLockWait(pid = bPid) {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [pid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("둘째 연결이 잠금을 기다리지 않는다");
}
/** B가 A만 기다리고 A는 아무것도 기다리지 않는다 (교착 0) */
async function expectBWaitsForA() {
  const { rows } = await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [bPid]);
  expect(rows[0].blockers).toContain(aPid);
  const { rows: aRows } = await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [aPid]);
  expect(aRows[0].blockers).toEqual([]);
}

async function world(options: { bound?: boolean; status?: string; connectionAdapter?: string } = {}) {
  const user = await f.user();
  const bridge = await f.bridge(user);
  const connection = await f.agentConnection(user, bridge, { adapter: options.connectionAdapter ?? "agent:codex" });
  const session = options.bound ? await f.session(user, connection, { status: options.status ?? "bound" }) : null;
  const conversation = await f.agentConversation(user, connection, session);
  const message = String((await f.post(user, conversation, randomUUID(), "첫 요청\n원문")).message_id);
  return { user, connection, session, conversation, message };
}

describe("P1 Send again 두 번 동시", () => {
  it("먼저 다시 대기시킨 쪽이 시작하고, 기다린 쪽은 건너뛴다: task · 단계 · 지표 하나", async () => {
    const w = await world();
    await f.q("select public.mark_agent_message_not_sent($1,$2,'not_connected')", [w.user, w.message]);
    await a.query("begin");
    await b.query("begin");
    const first = await requeue(a, w.user, w.conversation);
    expect(first.messages).toEqual([{ message_id: w.message, result: "requeued" }]);
    const waiting = requeue(b, w.user, w.conversation, [w.message]);
    await waitForLockWait();
    await expectBWaitsForA();
    expect((await start(a, w.user, w.message)).status).toBe("started");
    await a.query("commit");
    const second = await waiting;
    await b.query("commit");
    expect(second.messages).toEqual([{ message_id: w.message, result: "skipped", reason: "not_eligible" }]);
    expect(await f.count("select 1 from public.agent_tasks where user_id = $1", [w.user])).toBe(1);
    expect(await f.count("select 1 from public.execution_steps where user_id = $1 and kind = 'agent_message'", [w.user])).toBe(1);
    expect(await f.count("select 1 from public.metric_events where user_id = $1 and type = 'message_resent'", [w.user])).toBe(1);
    expect(await f.count("select 1 from public.metric_events where user_id = $1 and type = 'agent_message_sent'", [w.user])).toBe(1);
  });

  it("먼저 롤백하면 기다린 쪽이 다시 대기시키고 시작한다 (잃은 갱신 0)", async () => {
    const w = await world();
    await f.q("select public.mark_agent_message_not_sent($1,$2,'not_connected')", [w.user, w.message]);
    await a.query("begin");
    await b.query("begin");
    await requeue(a, w.user, w.conversation);
    const waiting = requeue(b, w.user, w.conversation);
    await waitForLockWait();
    await a.query("rollback");
    expect((await waiting).messages).toEqual([{ message_id: w.message, result: "requeued" }]);
    expect((await start(b, w.user, w.message)).status).toBe("started");
    await b.query("commit");
    expect(await f.count("select 1 from public.agent_tasks where user_id = $1", [w.user])).toBe(1);
    expect(await f.count("select 1 from public.metric_events where user_id = $1 and type = 'message_resent'", [w.user])).toBe(1);
  });
});

describe("P2 requeue ↔ 만료 sweep 같은 행", () => {
  async function expiredWorld() {
    const w = await world();
    await f.updateRow("conversation_messages", w.message, { delivery_state: "queued", delivery_reason: "session_busy", delivery_expires_at: new Date(Date.now() - 3600_000).toISOString() });
    return w;
  }
  const fresh = (message: string) =>
    f.one("select delivery_state, delivery_reason, (delivery_expires_at - public.db_now()) between interval '23 hours 59 minutes' and interval '24 hours' as fresh from public.conversation_messages where id = $1", [message]);

  it("sweep이 먼저 expired로 바꾸고 commit하지 않은 동안 이름을 준 requeue는 기다렸다가 expired를 다시 대기시킨다 (잃은 갱신 0)", async () => {
    const w = await expiredWorld();
    await a.query("begin");
    await b.query("begin");
    // sweep은 전체 표를 본다: 다른 시험이 남긴 만료 행도 세므로 이 행이 바뀌었는지는 상태로 확인한다
    expect(await expire(a)).toBeGreaterThanOrEqual(1);
    const waiting = requeue(b, w.user, w.conversation, [w.message]);
    await waitForLockWait();
    await a.query("commit");
    expect((await waiting).messages).toEqual([{ message_id: w.message, result: "requeued" }]);
    await b.query("commit");
    expect(await fresh(w.message)).toEqual({ delivery_state: "queued", delivery_reason: null, fresh: true });
  });

  it("requeue가 먼저 잡고 있으면 sweep은 그 행을 건너뛴다 (기다리지 않고, 새 24시간을 덮어쓰지 않는다)", async () => {
    const w = await expiredWorld();
    await f.q("update public.conversation_messages set delivery_state = 'expired' where id = $1", [w.message]);
    await a.query("begin");
    expect((await requeue(a, w.user, w.conversation)).messages).toEqual([{ message_id: w.message, result: "requeued" }]);
    await expire(b); // 기다리지 않고 돌아온다 (이 행은 건너뛴다)
    await a.query("commit");
    expect(await fresh(w.message)).toEqual({ delivery_state: "queued", delivery_reason: null, fresh: true });
    await expire(b);
    expect(await fresh(w.message)).toEqual({ delivery_state: "queued", delivery_reason: null, fresh: true });
  });
});

describe("P3 open-external ↔ start_agent_turn 같은 세션", () => {
  it("start가 먼저 잡으면 open은 기다렸다가 busy (started, busy), 교착 0", async () => {
    const w = await world({ bound: true });
    await a.query("begin");
    await b.query("begin");
    expect((await start(a, w.user, w.message)).status).toBe("started");
    const waiting = open(b, w.user, w.session!);
    await waitForLockWait();
    await expectBWaitsForA();
    await a.query("commit");
    expect(await waiting).toBe("busy");
    await b.query("commit");
    expect((await f.one("select status from public.agent_sessions where id = $1", [w.session])).status).toBe("bound");
    expect(await f.count("select 1 from public.agent_tasks where user_id = $1", [w.user])).toBe(1);
  });

  it("open이 먼저 잡으면 start는 기다렸다가 queued/session_external (external, session_external), 교착 0", async () => {
    const w = await world({ bound: true });
    await a.query("begin");
    await b.query("begin");
    expect(await open(a, w.user, w.session!)).toBe("external");
    const waiting = start(b, w.user, w.message);
    await waitForLockWait();
    await expectBWaitsForA();
    await a.query("commit");
    expect(await waiting).toEqual({ status: "queued", reason: "session_external" });
    await b.query("commit");
    expect((await f.one("select status from public.agent_sessions where id = $1", [w.session])).status).toBe("external");
    expect(await f.count("select 1 from public.agent_tasks where user_id = $1", [w.user])).toBe(0);
    expect(await f.count("select 1 from public.actions where user_id = $1", [w.user])).toBe(0);
  });
});

describe("P4 resume-here ↔ stop · open-external ↔ route_agent_message", () => {
  it("stop이 먼저: resume은 기다리고 둘 다 끝난다 (교착 0), external 세션의 stop은 대기 메시지를 그대로 둔다", async () => {
    const w = await world({ bound: true, status: "external" });
    await f.updateRow("conversation_messages", w.message, { delivery_state: "queued", delivery_reason: "session_external" });
    await a.query("begin");
    await b.query("begin");
    expect(await stop(a, w.user, w.session!)).toEqual({ tasks: [] });
    const waiting = resume(b, w.user, w.session!);
    await waitForLockWait();
    await expectBWaitsForA();
    await a.query("commit");
    expect(await waiting).toBe("bound");
    await b.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "queued", delivery_reason: "session_external" });
    expect((await f.one("select status from public.agent_sessions where id = $1", [w.session])).status).toBe("bound");
  });

  it("resume이 먼저: stop은 기다렸다가 bound 세션으로 대기 메시지를 취소한다 (교착 0)", async () => {
    const w = await world({ bound: true, status: "external" });
    await f.updateRow("conversation_messages", w.message, { delivery_state: "queued", delivery_reason: "session_external" });
    await a.query("begin");
    await b.query("begin");
    expect(await resume(a, w.user, w.session!)).toBe("bound");
    const waiting = stop(b, w.user, w.session!);
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting).toEqual({ tasks: [] });
    await b.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "cancelled" });
  });

  it("route가 먼저: open은 기다렸다가 busy (교착 0)", async () => {
    const w = await world({ bound: true });
    await a.query("begin");
    await b.query("begin");
    expect((await route(a, w.user, w.message)).status).toBe("started");
    const waiting = open(b, w.user, w.session!);
    await waitForLockWait();
    await expectBWaitsForA();
    await a.query("commit");
    expect(await waiting).toBe("busy");
    await b.query("commit");
    expect(await f.count("select 1 from public.agent_tasks where user_id = $1", [w.user])).toBe(1);
  });

  it("open이 먼저: route는 기다렸다가 queued/session_external (교착 0)", async () => {
    const w = await world({ bound: true });
    await a.query("begin");
    await b.query("begin");
    expect(await open(a, w.user, w.session!)).toBe("external");
    const waiting = route(b, w.user, w.message);
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting).toEqual({ status: "queued", reason: "session_external" });
    await b.query("commit");
    expect(await f.count("select 1 from public.agent_tasks where user_id = $1", [w.user])).toBe(0);
  });
});

describe("P5 세션을 잡은 직후 묶인 대화를 NOWAIT로 다시 확인한다 (검토 반영 7-2)", () => {
  // 시나리오: 호출이 첫 대화 조회를 끝내고 세션 잠금을 기다리는 동안 새 대화 C2가 같은 세션에 연결 · commit되고, 다른 요청 A가 C2 행 잠금을 쥔다.
  // 다시 확인이 없으면 호출(세션 → C2)과 A(C2 → 세션)가 서로 기다려 교착한다. NOWAIT이면 호출만 55P03으로 원자 실패한다.
  const cases = [
    ["open_agent_session_external", "bound", open, "external"],
    ["resume_agent_session_here", "external", resume, "bound"],
  ] as const;
  for (const [name, status, call, ok] of cases) {
    it(`${name}: 새로 연결된 대화를 다른 요청이 쥐고 있으면 교착 대신 55P03으로 원자 실패하고, 풀린 뒤 다시 부르면 새 대화까지 포함해 성공한다`, async () => {
      const w = await world({ bound: true, status });
      const c2 = await f.agentConversation(w.user, w.connection);
      await c.query("begin");
      await c.query("update public.conversations set agent_session_id = $1 where id = $2", [w.session, c2]); // C2 행 + 세션 key-share
      await a.query("begin");
      const holdingC2 = a.query("select id from public.conversations where id = $1 for update", [c2]); // c가 commit되면 곧바로 C2를 쥔다
      await waitForLockWait(aPid);
      const failing = call(b, w.user, w.session!).then(() => null, (error: unknown) => error);
      await waitForLockWait(bPid); // 세션 잠금 대기
      await c.query("commit"); // C2는 A에게, 세션은 호출에게 동시에 넘어간다
      expect(await failing).toMatchObject({ code: "55P03" });
      await holdingC2;
      // A는 이어서 세션을 잡을 수 있다 (호출이 롤백했다: 교착 0)
      await a.query("select id from public.agent_sessions where id = $1 for update", [w.session]);
      await a.query("commit");
      expect((await f.one("select status from public.agent_sessions where id = $1", [w.session])).status).toBe(status);
      expect(await f.count("select 1 from public.metric_events where user_id = $1 and type in ('session_opened_external', 'session_resumed')", [w.user])).toBe(0);
      expect(await call(b, w.user, w.session!)).toBe(ok);
      expect(await f.count("select 1 from public.conversation_messages where conversation_id = $1 and role = 'event'", [c2])).toBe(1);
    });
  }
});

describe("P6 자동 시작은 고정한 메시지를 잠금 안에서 다시 확인한다 (검토 반영 8-1)", () => {
  // 시나리오: TS가 대기열 머리 B(queued)를 검사해 고정한 뒤 시작하려는 사이, 다른 요청이 B를 not_sent/spawn_failed로 바꾸는 트랜잭션을 쥐고 있다.
  // 시작은 B의 행 잠금에서 기다렸다가 풀린 뒤 상태를 다시 읽어 skipped — 검사한 시점의 낡은 상태로 새 회차를 만들지 않는다.
  const tallies = async (user: string) => ({
    tasks: await f.count("select 1 from public.agent_tasks where user_id = $1", [user]),
    steps: await f.count("select 1 from public.execution_steps where user_id = $1 and kind = 'agent_message'", [user]),
    sent: await f.count("select 1 from public.metric_events where user_id = $1 and type = 'agent_message_sent'", [user]),
  });

  it("검사한 뒤 not_sent/spawn_failed로 바뀐 메시지는 시작하지 않는다: 기다린 자동 시작은 skipped, task · 단계 · 지표 0", async () => {
    const w = await world();
    await a.query("begin");
    await a.query("update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = 'spawn_failed' where id = $1", [w.message]);
    const waiting = startAuto(b, w.user, w.message);
    await waitForLockWait();
    await expectBWaitsForA();
    await a.query("commit");
    expect(await waiting).toEqual({ status: "skipped" });
    expect(await tallies(w.user)).toEqual({ tasks: 0, steps: 0, sent: 0 });
    expect((await f.one("select delivery_state, delivery_reason from public.conversation_messages where id = $1", [w.message]))).toEqual({ delivery_state: "not_sent", delivery_reason: "spawn_failed" });
  });

  it("대조: 잠금 안 재확인이 없는 길(route_agent_message 직접)은 같은 상황에서 새 회차를 만든다 — 위 시험이 지키는 위험", async () => {
    const w = await world();
    await a.query("begin");
    await a.query("update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = 'spawn_failed' where id = $1", [w.message]);
    const waiting = route(b, w.user, w.message);
    await waitForLockWait();
    await a.query("commit");
    expect((await waiting).status).toBe("started");
    expect((await tallies(w.user)).tasks).toBe(1);
  });

  it("gate 이유로 바뀐 메시지는 기다렸다가 시작한다 (같은 잠금 경로, 플래그가 풀린 뒤의 자동 재시작)", async () => {
    const w = await world();
    await a.query("begin");
    await a.query("update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = 'not_connected' where id = $1", [w.message]);
    const waiting = startAuto(b, w.user, w.message);
    await waitForLockWait();
    await a.query("commit");
    expect((await waiting).status).toBe("started");
    expect((await tallies(w.user)).tasks).toBe(1);
  });

  it("만료가 먼저 끝나면(A expires) 고정한 A는 skipped이고 뒤의 not_sent/spawn_failed B도 새 회차가 없다", async () => {
    const w = await world({ bound: true });
    const second = String((await f.post(w.user, w.conversation, randomUUID(), "B")).message_id);
    await f.setMessage(second, "not_sent", "spawn_failed");
    await f.setMessage(w.message, "queued", null, { delivery_expires_at: new Date(Date.now() - 1000).toISOString() });
    await a.query("begin");
    expect(await expire(a)).toBe(1); // 만료 sweep이 A를 잡고 있다
    const waiting = startAuto(b, w.user, w.message);
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting).toEqual({ status: "skipped" });
    expect(await startAuto(b, w.user, second)).toEqual({ status: "skipped" });
    expect(await tallies(w.user)).toEqual({ tasks: 0, steps: 0, sent: 0 });
  });
});

describe("P7 자동 시작 래퍼는 잠금 대상(질문의 원문)을 고정한다 — 바뀌면 추가 잠금 전에 40001 (검토 반영 9-2)", () => {
  // 시나리오: 래퍼가 M의 잠금을 기다리는 동안 그 세션의 질문이 열리거나 닫힌다. 래퍼가 그대로 route_agent_message로 가면 route는 다른 원문 O를 보고 M → O 순으로 잠그려 하고,
  // 다른 요청(O → M 순)과 서로 기다려 교착한다. 래퍼는 M을 잡은 직후 원문 · 사건 기준을 다시 읽어 달라졌으면 O를 잠그기 전에 40001로 롤백한다 → 풀린 뒤 다시 부르면 성공.
  async function questionWorld() {
    const w = await f.questionWorld();
    const pending = (await f.state(w)).pending_question;
    const incoming = String((await f.post(w.user, w.conversation, randomUUID(), "답변이에요")).message_id);
    return { ...w, pending, origin: w.message, incoming };
  }
  const lockMessage = (client: pg.Client, id: string) => client.query("select id from public.conversation_messages where id = $1 for update", [id]);
  const closeQuestion = (client: pg.Client, task: string) => client.query("update public.agent_tasks set state = 'running', pending_question = null where id = $1", [task]);
  const openQuestion = (client: pg.Client, task: string, pending: unknown) =>
    client.query("update public.agent_tasks set state = 'awaiting_answer', pending_question = $2::jsonb where id = $1", [task, JSON.stringify(pending)]);
  const settle = <T,>(promise: Promise<T>) => promise.then((value) => ({ value }), (error: unknown) => ({ error }));

  it("질문이 열리는 사이: 래퍼는 M만 잠근 채 기다리고, 다른 요청이 O → M 순으로 잠그려 해도 교착하지 않는다 — 래퍼가 40001로 물러나고 다른 요청이 끝난 뒤 다시 부르면 성공", async () => {
    const w = await questionWorld();
    await closeQuestion(setup, w.task); // 시작 상태: 질문이 아직 안 열린 세션
    await c.query("begin");
    await lockMessage(c, w.incoming); // M을 쥔 요청이 질문을 연다 (commit 전)
    await openQuestion(c, w.task, w.pending);
    const wrapper = settle(startAuto(b, w.user, w.incoming));
    await waitForLockWait(bPid); // 래퍼는 질문이 안 열린 것으로 읽고 M의 잠금에서 기다린다
    await a.query("begin");
    await lockMessage(a, w.origin); // 다른 요청: O를 먼저 잡고
    const other = settle(lockMessage(a, w.incoming)); // M을 원한다 (래퍼 뒤에 줄을 선다)
    await waitForLockWait(aPid);
    await c.query("commit"); // M이 래퍼에게 넘어가고, 래퍼는 질문이 열린 것을 본다
    const result = await wrapper;
    expect(result).toMatchObject({ error: { code: "40001" } }); // 교착(40P01)이 아니라 직렬화 실패로 물러난다
    expect(await other).toHaveProperty("value"); // 다른 요청은 M을 얻는다 (래퍼가 롤백하며 놓았다)
    await a.query("commit");
    // 다시 부르면 이제 열린 질문을 같은 눈으로 보고 끝까지 간다
    const retry = await startAuto(b, w.user, w.incoming);
    expect(typeof retry.status).toBe("string");
    expect(retry.status).not.toBe("skipped");
  });

  it("질문이 닫히는 사이도 같다: 래퍼가 읽은 원문 O와 달라지면 40001, 다시 부르면 성공", async () => {
    const w = await questionWorld(); // 질문이 열려 있다 → 래퍼는 {M, O}를 잠그려 한다
    await c.query("begin");
    await lockMessage(c, w.incoming);
    await closeQuestion(c, w.task); // M을 쥔 요청이 질문을 닫는다 (commit 전)
    const wrapper = settle(startAuto(b, w.user, w.incoming));
    await waitForLockWait(bPid);
    await c.query("commit");
    expect(await wrapper).toMatchObject({ error: { code: "40001" } });
    const retry = await startAuto(b, w.user, w.incoming);
    expect(typeof retry.status).toBe("string");
    expect(retry.status).not.toBe("skipped");
  });

  it("같은 task에서 질문이 바뀌어도(원문은 같고 사건 기준 provider_request_id만 달라짐) 40001 — 다시 부르면 성공", async () => {
    const w = await questionWorld(); // 질문 q가 열려 있다 → 래퍼는 {M, O, 사건 행}을 기준으로 삼는다
    await c.query("begin");
    await lockMessage(c, w.incoming);
    await c.query(
      "update public.agent_tasks set pending_question = jsonb_set(jsonb_set(pending_question, '{provider_request_id}', '\"another-question\"'), '{question_key}', jsonb_build_array(id, 'another-question')) where id = $1",
      [w.task],
    );
    const wrapper = settle(startAuto(b, w.user, w.incoming));
    await waitForLockWait(bPid);
    await c.query("commit");
    expect(await wrapper).toMatchObject({ error: { code: "40001" } });
    const retry = await startAuto(b, w.user, w.incoming);
    expect(retry.status).not.toBe("skipped");
  });

  it("바뀌지 않았으면 40001 없이 그대로 진행한다 (질문이 열린 채 M을 기다렸다 받음)", async () => {
    const w = await questionWorld();
    await c.query("begin");
    await lockMessage(c, w.incoming);
    const wrapper = settle(startAuto(b, w.user, w.incoming));
    await waitForLockWait(bPid);
    await c.query("commit");
    const result = await wrapper;
    expect(result).toHaveProperty("value");
    expect((result as { value: Turn }).value.status).not.toBe("skipped");
  });
});

describe("P8 거절 · 꺼짐 표시는 메시지 잠금 안에서 현재 상태를 다시 본다 (검토 반영 9-1)", () => {
  const markAuto = async (client: pg.Client, user: string, message: string, reason: string, fromGate = false) =>
    (await client.query<{ result: { status: string; reason?: string } }>("select public.mark_agent_message_not_sent_auto($1,$2,$3,$4) as result", [user, message, reason, fromGate])).rows[0].result;
  const markPlain = async (client: pg.Client, user: string, message: string, reason: string) =>
    (await client.query<{ result: { status: string; reason?: string } }>("select public.mark_agent_message_not_sent($1,$2,$3) as result", [user, message, reason])).rows[0].result;
  const flip = (client: pg.Client, message: string) =>
    client.query("update public.conversation_messages set delivery_state = 'not_sent', delivery_reason = 'spawn_failed' where id = $1", [message]);

  it("TS가 queued로 읽은 뒤 다른 요청이 spawn_failed로 만드는 중이면, 기다린 늦은 표시는 풀린 뒤 상태를 다시 읽어 skipped — 이유를 덮지 않는다", async () => {
    for (const fromGate of [false, true]) {
      const w = await world();
      await a.query("begin");
      await flip(a, w.message);
      const waiting = markAuto(b, w.user, w.message, "write_gate_closed", fromGate);
      await waitForLockWait();
      await expectBWaitsForA();
      await a.query("commit");
      expect(await waiting).toEqual({ status: "skipped" });
      expect(await f.one("select delivery_state, delivery_reason from public.conversation_messages where id = $1", [w.message])).toEqual({ delivery_state: "not_sent", delivery_reason: "spawn_failed" });
    }
  });

  it("대조: 무조건 표시 함수(mark_agent_message_not_sent)는 같은 상황에서 실패 이유를 덮는다 — 위 시험이 지키는 위험", async () => {
    const w = await world();
    await a.query("begin");
    await flip(a, w.message);
    const waiting = markPlain(b, w.user, w.message, "write_gate_closed");
    await waitForLockWait();
    await a.query("commit");
    expect((await waiting).status).toBe("not_sent");
    expect(await f.one("select delivery_reason from public.conversation_messages where id = $1", [w.message])).toEqual({ delivery_reason: "write_gate_closed" });
  });

  it("그대로 queued이면 기다렸다가 표시한다 (선 요청이 롤백하면)", async () => {
    const w = await world();
    await a.query("begin");
    await a.query("select id from public.conversation_messages where id = $1 for update", [w.message]);
    const waiting = markAuto(b, w.user, w.message, "write_gate_closed");
    await waitForLockWait();
    await a.query("rollback");
    expect(await waiting).toEqual({ status: "not_sent", reason: "write_gate_closed" });
  });
});

describe("P9 일괄 Send again은 처음 잠근 id 집합만 처리한다 (검토 반영 10-1)", () => {
  // 시나리오(일괄 = message_ids 없음): ① 호출이 대상 X의 잠금을 기다리는 동안 처음 조회에서 빠졌던 Y(dispatched)가 not_sent로 바뀐다
  // ② 호출은 풀려 X를 처리하다가 지표 insert에서 멈춰 있고(metric_events 잠금을 쥔 다른 연결) ③ 그 사이 다른 요청이 Y를 재전송해 dispatched로 commit한다.
  // 고정하지 않은 구현은 두 번째 조회에서 Y를 만나 낡은 not_sent로 판단해 dispatched를 queued로 덮는다. 고정한 구현은 Y를 처리하지 않는다(결과에도 없다).
  const waitForRelationLock = async (pid: number) => {
    for (let i = 0; i < 100; i++) {
      const { rows } = await setup.query<{ wait_event_type: string | null; wait_event: string | null }>("select wait_event_type, wait_event from pg_stat_activity where pid = $1", [pid]);
      if (rows[0]?.wait_event_type === "Lock" && rows[0]?.wait_event === "relation") return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("호출이 표(metric_events) 잠금을 기다리지 않는다");
  };

  async function raceWorld() {
    const w = await world();
    const x = w.message;
    const y = String((await f.post(w.user, w.conversation, randomUUID(), "둘째")).message_id);
    await f.setMessage(x, "not_sent", "usage_limited"); // seq 1: 처음부터 대상
    await f.setMessage(y, "dispatched"); // seq 2: 처음 조회에서는 대상이 아니다
    return { ...w, x, y };
  }

  it("두 조회 사이 대상이 하나 더 생기고 다른 요청이 그 행을 재전송해 dispatched로 commit해도, 그 행은 dispatched 그대로이고 결과 · 지표에 없다", async () => {
    const w = await raceWorld();
    await a.query("begin");
    await a.query("select id from public.conversation_messages where id = $1 for update", [w.x]); // 호출의 첫 조회를 X에서 붙잡는다
    const call = requeue(b, w.user, w.conversation).then((value) => ({ value }), (error: unknown) => ({ error }));
    await waitForLockWait(); // 첫 조회는 X를 기다린다 (Y는 dispatched라 대상이 아니다)
    await f.setMessage(w.y, "not_sent", "spawn_failed"); // 두 조회 사이 대상이 하나 더 생긴다
    await c.query("begin");
    await c.query("lock table public.metric_events in access exclusive mode"); // X 처리 중 지표 insert에서 멈추게 한다
    await a.query("rollback"); // 첫 조회 끝 → 두 번째 조회가 X · Y를 읽고 X부터 처리한다
    await waitForRelationLock(bPid);
    await f.setMessage(w.y, "dispatched"); // 다른 요청이 Y를 다시 보내 전달까지 commit
    await c.query("rollback"); // 호출이 이어진다
    const outcome = await call;
    expect(outcome).toHaveProperty("value");
    const result = (outcome as { value: Requeue }).value;
    expect(result).toEqual({ status: "ok", messages: [{ message_id: w.x, result: "requeued" }] }); // 고정한 집합(X)만 — Y는 결과에 없다
    expect(await f.one("select delivery_state, delivery_reason from public.conversation_messages where id = $1", [w.y])).toEqual({ delivery_state: "dispatched", delivery_reason: null });
    expect(await f.count("select 1 from public.metric_events where user_id = $1 and type = 'message_resent'", [w.user])).toBe(1);
    expect((await f.one("select delivery_state from public.conversation_messages where id = $1", [w.x])).delivery_state).toBe("queued");
  });

  it("대조(경합 없음): 일괄은 평소처럼 그 시점의 대상 상태를 모두 다시 대기시킨다", async () => {
    const w = await raceWorld();
    await f.setMessage(w.y, "not_sent", "spawn_failed");
    const result = await requeue(b, w.user, w.conversation);
    expect(result.messages.map((item) => [item.message_id, item.result])).toEqual([[w.x, "requeued"], [w.y, "requeued"]]);
  });
});
