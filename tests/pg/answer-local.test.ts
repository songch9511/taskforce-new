import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { answerQuestionFixture } from "../db/agent-questions-stop.scenarios";
import { BOTH, REQUEST, sha256 } from "../db/answer-local.scenarios";
import { bridgeCommandFixtures } from "../db/bridge-commands.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// OA F2 P1–P7: 실제 Postgres에서만 증명되는 경합. 코디네이터의 일회용 PG(DATABASE_URL)에 데이터베이스를 새로 만든다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL databases.");
const DB_NAME = `taskforce_answer_local_${process.pid}_${Date.now()}`;
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
const db = (client: () => pg.Client): (() => ConversationAgentDb) => () => ({
  query: async (sql, params) => (await client().query(sql, params)).rows,
  asUser: async () => { throw new Error("No application role needed for concurrency cases"); },
});
const f = bridgeCommandFixtures(db(() => setup));
const fa = bridgeCommandFixtures(db(() => a));
const fb = bridgeCommandFixtures(db(() => b));
type World = Awaited<ReturnType<typeof f.world>>;

const pending = <T,>(promise: Promise<T>) => promise.then((value) => ({ value }), (error) => ({ error }));
async function resolved<T>(promise: ReturnType<typeof pending<T>>) {
  const result = await promise;
  if ("error" in result) throw result.error;
  return result.value;
}
async function blocked(waiter = bPid, blocker = aPid) {
  for (let i = 0; i < 150; i++) {
    const row = (await setup.query<{ blocked: boolean }>("select $2::int = any(pg_blocking_pids($1)) as blocked", [waiter, blocker])).rows[0];
    if (row.blocked) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error("Expected B to demonstrably block on A via pg_blocking_pids");
}

type Local = { status: string; step_id?: string; reason?: string };
const local = async (fx: typeof f, w: Pick<World, "user" | "bridge" | "task">, request = REQUEST): Promise<Local> =>
  (await fx.one("select public.answer_agent_question_locally($1,$2,$3,$4,$5::text[]) as result", [w.user, w.bridge, w.task, sha256(request), BOTH])).result as Local;
async function secretWorld(request = REQUEST): Promise<World> {
  const w = await f.world();
  await f.lease(w);
  expect(await f.bridgeEvent(w, f.event(w, "question", { text: "Answer on this Mac", question: answerQuestionFixture({ secret: true, options: [] }, { provider_request_id: request }) }))).toMatchObject({ status: "applied" });
  expect(await f.state(w)).toMatchObject({ state: "awaiting_answer" });
  return w;
}
const answerSteps = (w: World, request = REQUEST) => f.count("select 1 from public.execution_steps where run_id=$1 and args->>'agent_task_id'=$2 and args->>'provider_request_id'=$3", [w.run, w.task, request]);
const answerCommand = async (w: World) => String((await f.one("select c.id from public.bridge_commands c where c.agent_task_id=$1 and c.kind='answer' order by c.cursor desc limit 1", [w.task])).id);
/** 답이 먼저 commit된 뒤 Stop · Done이 오면: 취소가 요청되고 답 단계는 건너뛰며, 답 명령은 lease에서 거둬진다 (Mac이 받는 것은 취소 명령뿐) */
async function expectAnswerWithdrawn(w: World) {
  expect(await f.one("select cancel_requested_at is not null as requested from public.agent_tasks where id=$1", [w.task])).toEqual({ requested: true });
  expect(await f.q("select state from public.execution_steps where run_id=$1 and intent_key like $2", [w.run, `answer:${w.task}:%`])).toEqual([{ state: "skipped" }]);
  expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='cancel'", [w.task])).toBe(1);
  expect(await f.lease({ ...w, command: await answerCommand(w) })).toEqual({ status: "stale", reason: "not_prepared" });
}
async function done(client: pg.Client, w: World) {
  const claim = { id: randomUUID(), source_id: null, field: "status", value: "done", quote: null, occurred_at: new Date().toISOString(), speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "shared", origin: "user", channel: "note", state: "active" };
  const result = await client.query<{ written: boolean }>(
    `select public.write_action($1,id,version,to_jsonb(actions)||'{"status":"done"}'::jsonb,$3::jsonb,'[]','[]') as written from public.actions where user_id=$1 and id=$2`, [w.user, w.action, JSON.stringify([claim])]);
  expect(result.rows).toEqual([{ written: true }]);
}

describe("P1 같은 로컬 답 둘", () => {
  for (const finish of ["commit", "rollback"] as const) {
    it(`첫 쪽이 ${finish}하면 답 단계는 하나 (commit이면 duplicate, rollback이면 둘째가 answered)`, async () => {
      const w = await secretWorld();
      await a.query("begin");
      await b.query("begin");
      const first = await local(fa, w);
      expect(first.status).toBe("answered");
      const waiting = pending(local(fb, w));
      await blocked();
      await a.query(finish);
      const second = await resolved(waiting);
      expect(second.status).toBe(finish === "commit" ? "duplicate" : "answered");
      if (finish === "commit") expect(second.step_id).toBe(first.step_id);
      await b.query("commit");
      expect(await answerSteps(w)).toBe(1);
      expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='answer'", [w.task])).toBe(1);
      expect(await f.count("select 1 from public.metric_events where user_id=$1 and type='question_answered'", [w.user])).toBe(1);
    });
  }
});

describe("P2 로컬 답 ↔ 세션 Stop", () => {
  it("답이 먼저 commit되면 Stop이 그 작업을 취소하고 답 명령은 더 이상 lease되지 않는다", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await b.query("begin");
    expect((await local(fa, w)).status).toBe("answered");
    const waiting = pending(fb.stop(w.user, w.session));
    await blocked();
    await a.query("commit");
    expect(await resolved(waiting)).toMatchObject({ tasks: [{ agent_task_id: w.task }] });
    await b.query("commit");
    await expectAnswerWithdrawn(w);
  });
  it("Stop이 먼저 commit되면 답은 stale이고 쓰기 0 (교착 0)", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await b.query("begin");
    await fa.stop(w.user, w.session);
    const waiting = pending(local(fb, w));
    await blocked();
    await a.query("commit");
    expect(await resolved(waiting)).toEqual({ status: "stale", reason: "question_closed" });
    await b.query("commit");
    expect(await answerSteps(w)).toBe(0);
    expect(await f.count("select 1 from public.metric_events where user_id=$1 and type='question_answered'", [w.user])).toBe(0);
  });
});

describe("P3 로컬 답 ↔ 이슈 Done", () => {
  it("답이 먼저면 Done이 그 작업을 취소하고 run이 멈춘다", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await b.query("begin");
    expect((await local(fa, w)).status).toBe("answered");
    const waiting = pending(done(b, w));
    await blocked();
    await a.query("commit");
    await resolved(waiting);
    await b.query("commit");
    expect(await f.one("select state from public.execution_runs where id=$1", [w.run])).toEqual({ state: "stopped" });
    await expectAnswerWithdrawn(w);
  });
  it("Done이 먼저면 답은 stale이고 답 단계 0", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await b.query("begin");
    await done(a, w);
    const waiting = pending(local(fb, w));
    await blocked();
    await a.query("commit");
    expect(await resolved(waiting)).toEqual({ status: "stale", reason: "question_closed" });
    await b.query("commit");
    expect(await answerSteps(w)).toBe(0);
    expect(await f.one("select state from public.execution_runs where id=$1", [w.run])).toEqual({ state: "stopped" });
  });
});

describe("P4 로컬 답 ↔ 질문 교체", () => {
  it("이미 답한 질문의 digest를 새 질문이 열리는 동안 다시 보내면 stale이고 새 질문의 답은 0", async () => {
    const w = await secretWorld();
    const first = await local(f, w);
    expect(first.status).toBe("answered");
    // 답 단계가 전달되고 에이전트가 이어간 뒤 새 질문(새 열쇠)을 한다
    await f.lease({ ...w, command: await answerCommand(w) });
    expect(await f.bridgeEvent(w, f.event(w, "accepted"))).toMatchObject({ status: "applied" });
    await a.query("begin");
    await b.query("begin");
    const asked = await fa.bridgeEvent(w, f.event(w, "question", { text: "Next", question: answerQuestionFixture({ secret: true, options: [] }, { provider_request_id: "request-2" }) }));
    expect(asked).toMatchObject({ status: "applied" });
    const waiting = pending(local(fb, w, REQUEST));
    await blocked();
    await a.query("commit");
    expect(await resolved(waiting)).toEqual({ status: "stale", reason: "question_closed" });
    await b.query("commit");
    expect(await answerSteps(w, "request-2")).toBe(0);
    expect(await f.state(w)).toMatchObject({ state: "awaiting_answer" });
    expect((await local(f, w, "request-2")).status).toBe("answered");
  });
});

describe("P5 로컬 답 ↔ revoke_bridge", () => {
  it("폐기가 먼저면 답은 stale이거나 not_found이고 쓰기 0", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await b.query("begin");
    await a.query("select public.revoke_bridge($1,$2)", [w.user, w.bridge]);
    const waiting = pending(local(fb, w));
    await blocked();
    await a.query("commit");
    const result = await resolved(waiting);
    expect(["stale", "not_found"]).toContain(result.status);
    await b.query("commit");
    expect(await answerSteps(w)).toBe(0);
    expect(await f.count("select 1 from public.metric_events where user_id=$1 and type='question_answered'", [w.user])).toBe(0);
  });
  it("답이 먼저면 폐기가 작업을 취소하고, 끝 상태에 lease할 수 있는 답 명령은 없다 (교착 0)", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await b.query("begin");
    expect((await local(fa, w)).status).toBe("answered");
    const waiting = pending<unknown>(fb.one("select public.revoke_bridge($1,$2) as result", [w.user, w.bridge]));
    await blocked();
    await a.query("commit");
    await resolved(waiting);
    await b.query("commit");
    expect(await f.state(w)).toMatchObject({ state: "cancelled" });
    expect((await f.lease({ ...w, command: await answerCommand(w) })).status).not.toBe("leased");
    expect(await f.one("select status from public.agent_sessions where id=$1", [w.session])).toEqual({ status: "closed" });
  });
});

describe("P6 로컬 답 ↔ heartbeat sweep", () => {
  it("sweep이 먼저면 작업이 unreachable이라 stale/not_live이고 쓰기 0", async () => {
    const w = await secretWorld();
    await f.updateRow("bridges", w.bridge, { last_heartbeat_at: "2000-01-01T00:00:00Z" });
    await a.query("begin");
    await b.query("begin");
    await a.query("select * from public.sweep_bridge_heartbeats(now(),50)");
    const waiting = pending(local(fb, w));
    await blocked();
    await a.query("commit");
    expect(await resolved(waiting)).toEqual({ status: "stale", reason: "not_live" });
    await b.query("commit");
    expect(await answerSteps(w)).toBe(0);
    expect(await f.state(w)).toMatchObject({ state: "unreachable" });
    // 되살아나면(heartbeat) 같은 digest로 다시 표시할 수 있다
    await f.updateRow("agent_tasks", w.task, { state: "awaiting_answer" });
    expect((await local(f, w)).status).toBe("answered");
  });
  it("답이 먼저면 answered이고 sweep이 그 뒤 작업을 unreachable로 (교착 0)", async () => {
    const w = await secretWorld();
    await f.updateRow("bridges", w.bridge, { last_heartbeat_at: "2000-01-01T00:00:00Z" });
    await a.query("begin");
    await b.query("begin");
    expect((await local(fa, w)).status).toBe("answered");
    const waiting = pending<unknown>(b.query("select * from public.sweep_bridge_heartbeats(now(),50)"));
    await blocked();
    await a.query("commit");
    await resolved(waiting);
    await b.query("commit");
    expect(await answerSteps(w)).toBe(1);
    expect(await f.state(w)).toMatchObject({ state: "unreachable" });
  });
});

describe("P7 잠금을 붙잡으면 2초 안에 물러난다", () => {
  it("다른 연결이 task 행을 쥐고 있으면 함수의 lock_timeout(2초)으로 55P03이고 쓰기 0 (세션의 lock_timeout에 기대지 않는다)", async () => {
    const w = await secretWorld();
    await a.query("begin");
    await a.query("select id from public.agent_tasks where id=$1 for update", [w.task]);
    // 부르는 연결에는 세션 lock_timeout이 없다: 물러나는 시간은 함수의 set lock_timeout이 정한다
    await b.query("set lock_timeout = 0");
    const started = Date.now();
    await expect(b.query("select public.answer_agent_question_locally($1,$2,$3,$4,$5::text[])", [w.user, w.bridge, w.task, sha256(REQUEST), BOTH])).rejects.toMatchObject({ code: "55P03" });
    const elapsed = Date.now() - started;
    expect(elapsed).toBeGreaterThanOrEqual(1500);
    expect(elapsed).toBeLessThan(4000);
    await a.query("rollback");
    expect(await answerSteps(w)).toBe(0);
    expect(await f.state(w)).toMatchObject({ state: "awaiting_answer" });
    expect((await local(f, w)).status).toBe("answered");
  });
});

describe("P8 남의 호출은 잠금을 기다리지 않는다", () => {
  it("다른 Mac · 폐기된 bridge의 호출은 세션 · 작업을 다른 연결이 쥐고 있어도 바로 not_found (잠그기 전에 거른다)", async () => {
    const w = await secretWorld();
    const stranger = await f.bridge(w.user);
    const revoked = await f.bridge(w.user);
    await f.q("update public.bridges set status='revoked', revoked_at=now() where id=$1", [revoked]);
    await a.query("begin");
    await a.query("select id from public.agent_sessions where id=$1 for update", [w.session]);
    await a.query("select id from public.agent_tasks where id=$1 for update", [w.task]);
    const started = Date.now();
    expect(await local(fb, { ...w, bridge: stranger })).toEqual({ status: "not_found" });
    expect(await local(fb, { ...w, bridge: revoked })).toEqual({ status: "not_found" });
    expect(Date.now() - started).toBeLessThan(1000);
    await a.query("rollback");
    expect(await answerSteps(w)).toBe(0);
  });
});
