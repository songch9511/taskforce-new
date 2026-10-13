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
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
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
const f = agentConversationApiFixtures(db);

type Turn = { status: string; reason?: string; agent_task_id?: string; step_id?: string };
type Requeue = { status: string; messages: { message_id: string; result: string; reason?: string }[] };
const start = async (client: pg.Client, user: string, message: string) =>
  (await client.query<{ result: Turn }>("select public.start_agent_turn($1,$2,'{}','{}','read_only',$3) as result", [user, message, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
const route = async (client: pg.Client, user: string, message: string) =>
  (await client.query<{ result: Turn }>("select public.route_agent_message($1,$2,'read_only',$3) as result", [user, message, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
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
