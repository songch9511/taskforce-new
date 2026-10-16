import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { deliveryFixesFixtures, deliveryFixesTests, PAST } from "../db/agent-delivery-fixes.scenarios";
import { answerQuestionFixture } from "../db/agent-questions-stop.scenarios";
import { BOTH, REQUEST, sha256 } from "../db/answer-local.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// OA F3 P1–P15: 실제 Postgres에서만 증명되는 경합 (코디네이터의 일회용 PG, DATABASE_URL). 같은 시나리오 T1–T11도 실제 Postgres에서 한 번 더 돈다.
// 기다림은 pg_blocking_pids로 증명한다. 교착(40P01)이 나면 PG가 한 쪽을 물므로 코드로 가른다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL databases.");
const DB_NAME = `taskforce_delivery_fixes_${process.pid}_${Date.now()}`;
let admin: pg.Client, setup: pg.Client, a: pg.Client, b: pg.Client, c: pg.Client, d: pg.Client;
const pids = new Map<pg.Client, number>();
async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '15s'");
  pids.set(client, (await client.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid);
  return client;
}
beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  [a, b, c, d] = await Promise.all([connect(DB_NAME), connect(DB_NAME), connect(DB_NAME), connect(DB_NAME)]);
}, 120_000);
afterEach(async () => {
  for (const client of [a, b, c, d]) await client?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), c?.end(), d?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});
const db = (client: () => pg.Client): (() => ConversationAgentDb) => () => ({
  query: async (sql, params) => (await client().query(sql, params)).rows,
  asUser: async (user, fn) => {
    await client().query("set role authenticated");
    await client().query("select set_config('request.jwt.claim.sub',$1,false)", [user]);
    try {
      return await fn();
    } finally {
      await client().query("reset role");
      await client().query("select set_config('request.jwt.claim.sub','',false)");
    }
  },
});
const f = deliveryFixesFixtures(db(() => setup));
const fa = deliveryFixesFixtures(db(() => a));
const fb = deliveryFixesFixtures(db(() => b));
const fc = deliveryFixesFixtures(db(() => c));
type World = Awaited<ReturnType<typeof f.world>>;

const pending = <T,>(promise: Promise<T>) => promise.then((value) => ({ value }), (error: unknown) => ({ error }));
type Outcome<T> = Awaited<ReturnType<typeof pending<T>>>;
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
/** 실패하면 바로 rollback해서 상대가 풀리게 한다 (교착으로 한 쪽이 물렸을 때 시험이 멈추지 않게) */
const guard = <T,>(client: pg.Client, promise: Promise<Outcome<T>>) => promise.then(async (outcome) => {
  if ("error" in outcome) await client.query("rollback").catch(() => {});
  return outcome;
});
const codeOf = <T,>(outcome: Outcome<T>) => ("error" in outcome ? String((outcome.error as { code?: string }).code ?? "error") : "ok");
const valueOf = <T,>(outcome: Outcome<T>): T => {
  if ("error" in outcome) throw outcome.error;
  return outcome.value;
};
/** waiter가 blocker를 기다린다 (pg_blocking_pids) */
async function blocked(waiter: pg.Client, blocker: pg.Client) {
  for (let i = 0; i < 250; i++) {
    const row = (await setup.query<{ blocked: boolean }>("select $2::int = any(pg_blocking_pids($1)) as blocked", [pids.get(waiter), pids.get(blocker)])).rows[0];
    if (row.blocked) return;
    await sleep(20);
  }
  throw new Error("Expected the waiter to block on the holder via pg_blocking_pids");
}

/** promise가 끝났거나(settled) waiter가 blocker를 기다리는(blocked) 순간까지 기다린다. 기다리지 않는 쪽 · 기다리는 쪽 코드를 같은 줄거리로 시험하려고 쓴다 */
async function settledOrBlocked(promise: Promise<unknown>, waiter: pg.Client, blocker: pg.Client) {
  let settled = false;
  void promise.then(() => { settled = true; });
  for (let i = 0; i < 250; i++) {
    if (settled) return "settled" as const;
    const row = (await setup.query<{ blocked: boolean }>("select $2::int = any(pg_blocking_pids($1)) as blocked", [pids.get(waiter), pids.get(blocker)])).rows[0];
    if (row.blocked) return "blocked" as const;
    await sleep(20);
  }
  throw new Error("Expected the call to settle or to block on the holder");
}

async function done(client: pg.Client, w: { user: string; action: string }) {
  const claim = { id: randomUUID(), source_id: null, field: "status", value: "done", quote: null, occurred_at: new Date().toISOString(), speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "shared", origin: "user", channel: "note", state: "active" };
  const result = await client.query<{ written: boolean }>(
    `select public.write_action($1,id,version,to_jsonb(actions)||'{"status":"done"}'::jsonb,$3::jsonb,'[]','[]') as written from public.actions where user_id=$1 and id=$2`, [w.user, w.action, JSON.stringify([claim])]);
  expect(result.rows).toEqual([{ written: true }]);
}
const retry = async (client: pg.Client, run: () => Promise<unknown>) => {
  await client.query("begin");
  const result = await run();
  await client.query("commit");
  return result;
};

// ─── 세계 ───
/** 비밀값 질문을 기다리는 작업 (F2 secretWorld와 같은 모양): 명령은 lease됐고 질문은 awaiting_answer */
async function questionWorld(question = answerQuestionFixture({ secret: true, options: [] }, { provider_request_id: REQUEST })): Promise<World> {
  const w = await f.world();
  await f.lease(w);
  expect(await f.bridgeEvent(w, f.event(w, "question", { text: "Question card", question }))).toMatchObject({ status: "applied" });
  expect(await f.state(w)).toMatchObject({ state: "awaiting_answer" });
  return w;
}
const choiceWorld = () => questionWorld(answerQuestionFixture());
/** 질문 없이 접수된 작업 */
async function plainWorld(): Promise<World> {
  const w = await f.world();
  await f.lease(w);
  expect(await f.bridgeEvent(w, f.event(w, "accepted"))).toMatchObject({ status: "applied" });
  return w;
}
const local = async (fx: typeof f, w: Pick<World, "user" | "bridge" | "task">) =>
  (await fx.one("select public.answer_agent_question_locally($1,$2,$3,$4,$5::text[]) as result", [w.user, w.bridge, w.task, sha256(REQUEST), BOTH])).result as { status: string };
const plainAnswer = async (client: pg.Client, w: Pick<World, "user" | "task">) =>
  (await client.query("select public.answer_agent_question($1,$2,$3,null,true,null) as result", [w.user, w.task, REQUEST])).rows[0].result as { status: string };
const answerCommand = async (w: Pick<World, "task">) => String((await f.one("select c.id from public.bridge_commands c where c.agent_task_id=$1 and c.kind='answer' order by c.cursor desc limit 1", [w.task])).id);
const runState = async (w: Pick<World, "run">) => (await f.one("select state from public.execution_runs where id=$1", [w.run])).state;
/** 이 작업의 (고른 종류의) 명령은 끝 상태에서 lease할 수 없다. 확인한 명령 수를 돌려준다 */
async function expectNothingLeasable(w: World, kind?: string) {
  const commands = await f.q("select id from public.bridge_commands where agent_task_id=$1 and ($2::text is null or kind=$2)", [w.task, kind ?? null]);
  for (const { id } of commands) expect((await f.lease({ ...w, command: String(id) })).status, String(id)).not.toBe("leased");
  return commands.length;
}

type Racer = { client: pg.Client; run: () => Promise<unknown> };
/**
 * 제3 연결(a)이 작업 행을 쥐게 하고, first가 먼저 줄을 서고(Action · run을 쥐고 task를 기다림) second가 first를 기다리게 한 뒤 a를 푼다.
 * 이 순서가 main에서 순환 대기를 만든다 (Done은 run을 먼저 쥐고, 상대는 메시지 · 세션을 쥔 채 그 run을 기다린다).
 * 반환: 각자의 결과와, a를 푼 뒤 first가 끝나기까지(성공이든 실패든) 걸린 ms. 실패한 쪽은 바로 rollback한다.
 */
async function crossed(w: Pick<World, "task">, first: Racer, second: Racer) {
  await a.query("begin");
  await a.query("select id from public.agent_tasks where id=$1 for update", [w.task]);
  await first.client.query("begin");
  const p1 = guard(first.client, pending(first.run()));
  await blocked(first.client, a);
  await second.client.query("begin");
  const p2 = guard(second.client, pending(second.run()));
  await blocked(second.client, first.client);
  const released = Date.now();
  await a.query("rollback");
  const r1 = await p1;
  const firstMs = Date.now() - released;
  const r2 = await p2;
  return { r1, r2, firstMs };
}

describe("P1 Done ↔ 답 (F2 P5b 순서: Done이 run을 먼저 쥠)", () => {
  it.each(["wrapper", "plain"] as const)("Done(%s 답): 첫 시도는 풀린 직후 55P03, 답은 answered, 40P01 0. Done을 다시 하면 끝난다 (run stopped · 답 단계 skipped · 답 명령 lease 불가 · Claim 한 줄)", async (kind) => {
    const w = await questionWorld();
    const { r1, r2, firstMs } = await crossed(w, { client: c, run: () => done(c, w) }, { client: b, run: () => (kind === "wrapper" ? local(fb, w) : plainAnswer(b, w)) });
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    expect(firstMs).toBeLessThan(500); // deadlock_timeout(1초) 전에 NOWAIT가 바로 물러난다
    expect(valueOf(r2)).toMatchObject({ status: "answered" });
    await b.query("commit");
    expect(await f.count("select 1 from public.claims where action_id=$1 and origin='user' and field='status' and value='done'", [w.action])).toBe(0); // 물러난 시도는 흔적 0
    await retry(c, () => done(c, w));
    expect(await runState(w)).toBe("stopped");
    expect(await f.one("select cancel_requested_at is not null as requested from public.agent_tasks where id=$1", [w.task])).toEqual({ requested: true });
    expect(await f.q("select state from public.execution_steps where run_id=$1 and intent_key like $2", [w.run, `answer:${w.task}:%`])).toEqual([{ state: "skipped" }]);
    expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='cancel'", [w.task])).toBe(1);
    expect(await expectNothingLeasable(w, "answer")).toBe(1);
    expect(await f.lease({ ...w, command: await answerCommand(w) })).toEqual({ status: "stale", reason: "not_prepared" });
    expect(await f.count("select 1 from public.claims where action_id=$1 and origin='user' and field='status' and value='done'", [w.action])).toBe(1);
    expect(await f.count("select 1 from public.metric_events where user_id=$1 and type='question_answered'", [w.user])).toBe(kind === "wrapper" ? 1 : 0); // 지표는 래퍼(로컬 답)만 남긴다
  });

  it("Claude Code(거절 갈래)도 같다: 첫 시도 55P03 · 답 answered · 다시 하면 끝남", async () => {
    const base = await f.questionWorld(answerQuestionFixture({ secret: true, options: [] }, { provider_request_id: REQUEST }), "agent:claude-code");
    const w = { ...base, bridge: base.bridge };
    const { r1, r2 } = await crossed(w, { client: c, run: () => done(c, w) }, { client: b, run: () => local(fb, w) });
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    await b.query("commit");
    await retry(c, () => done(c, w));
    expect(await runState(w)).toBe("stopped");
    expect(await f.one("select state from public.agent_tasks where id=$1", [w.task])).toEqual({ state: "cancelled" });
    expect(await f.q("select state from public.execution_steps where run_id=$1 and intent_key like $2", [w.run, `answer:${w.task}:%`])).toEqual([{ state: "skipped" }]);
  });
});

describe("P1b 합성 상대: 세션만 · 메시지만 쥐고 run을 기다리는 연결 (A1의 두 줄을 따로 지킨다)", () => {
  it.each([["세션", "agent_sessions", "session"], ["메시지", "conversation_messages", "message"]] as const)("%s 행만 FOR UPDATE로 쥐고 Done이 쥔 run을 기다리면: Done은 55P03으로 물러나고 상대는 끝난다 (40P01 0)", async (_name, table, key) => {
    const w = await questionWorld();
    const holder = async () => {
      await b.query(`select id from public.${table} where id=$1 for update`, [w[key]]);
      return b.query("select id from public.execution_runs where id=$1 for no key update", [w.run]);
    };
    const { r1, r2 } = await crossed(w, { client: c, run: () => done(c, w) }, { client: b, run: holder });
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    await b.query("commit");
    await retry(c, () => done(c, w));
    expect(await runState(w)).toBe("stopped");
  });
});

describe("P2 Done(질문 있음) ↔ bridge_heartbeat", () => {
  it("heartbeat가 세션을 쥐고 run을 기다리는 순서: 40P01 0, heartbeat 끝남, Done은 55P03 뒤 다시 하면 끝남", async () => {
    const w = await questionWorld();
    const { r1, r2, firstMs } = await crossed(w, { client: c, run: () => done(c, w) }, { client: b, run: () => b.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb) as result", [w.user, w.bridge]) });
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    expect(firstMs).toBeLessThan(500);
    await b.query("commit");
    await retry(c, () => done(c, w));
    expect(await runState(w)).toBe("stopped");
    expect(await f.one("select state from public.agent_tasks where id=$1", [w.task])).toMatchObject({ state: "running" });
  });
});

describe("P3 Done(질문 있음) ↔ 메시지 · 세션을 쥐고 run을 기다리는 것들", () => {
  const racers: [string, () => Promise<World>, (w: World) => Racer][] = [
    ["lease replay (message 명령)", questionWorld, (w) => ({ client: b, run: () => fb.lease(w) })],
    ["apply_bridge_event", questionWorld, (w) => ({ client: b, run: () => fb.bridgeEvent(w, f.event(w, "progress")) })],
    ["답 명령 lease (선택지 답이라 답 글 행이 없다)", async () => { const q = await choiceWorld(); expect((await f.answer(q.user, q.task)).status).toBe("answered"); return q; },
      (w) => ({ client: b, run: async () => fb.lease({ ...w, command: await answerCommand(w) }) })],
  ];
  it.each(racers)("%s: 40P01 0, Done은 55P03 뒤 다시 하면 끝남", async (_name, make, racer) => {
    const w = await make();
    const { r1, r2 } = await crossed(w, { client: c, run: () => done(c, w) }, racer(w));
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    await b.query("commit");
    await retry(c, () => done(c, w));
    expect(await runState(w)).toBe("stopped");
    expect(await f.one("select cancel_requested_at is not null as requested from public.agent_tasks where id=$1", [w.task])).toEqual({ requested: true });
  });
});

describe("P4 Done(질문 없음)은 세션 · 메시지를 쥔 연결을 기다리지 않는다 (R-L6 회귀 방지)", () => {
  it.each([["세션", "agent_sessions", "session"], ["메시지", "conversation_messages", "message"]] as const)("%s 행을 다른 연결이 쥐고 있어도 끝난다", async (_name, table, key) => {
    const w = await plainWorld();
    await a.query("begin");
    await a.query(`select id from public.${table} where id=$1 for update`, [w[key]]);
    await c.query("begin");
    await c.query("set local lock_timeout = '1500ms'"); // 기다리면 55P03으로 시험이 분명히 실패한다
    const started = Date.now();
    await done(c, w);
    await c.query("commit");
    expect(Date.now() - started).toBeLessThan(1000);
    await a.query("rollback");
    expect(await runState(w)).toBe("stopped");
  });
});

describe("P5 revoke_bridge ↔ 답 · 사건 (폐기가 세션을 쥐고 task를 기다림 → 상대가 메시지를 쥐고 세션을 기다림 → 해제)", () => {
  const cases: [string, () => Promise<World>, (w: World) => Racer][] = [
    ["질문 있음: 평범한 답", choiceWorld, (w) => ({ client: b, run: () => fb.answer(w.user, w.task) })],
    ["질문 없음: Mac 사건", plainWorld, (w) => ({ client: b, run: () => fb.bridgeEvent(w, f.event(w, "progress")) })],
  ];
  it.each(cases)("%s: 40P01 0, 폐기는 55P03 뒤 다시 하면 revoked, 끝 상태에 lease할 수 있는 명령 0", async (_name, make, racer) => {
    const w = await make();
    const revoke = () => c.query<{ result: { status: string } }>("select public.revoke_bridge($1,$2) as result", [w.user, w.bridge]);
    const { r1, r2 } = await crossed(w, { client: c, run: revoke }, racer(w));
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    await b.query("commit");
    const revoked = (await retry(c, revoke)) as { rows: { result: { status: string } }[] };
    expect(revoked.rows[0].result.status).toBe("revoked");
    expect(await f.one("select status from public.bridges where id=$1", [w.bridge])).toEqual({ status: "revoked" });
    expect(await f.state(w)).toMatchObject({ state: "cancelled" });
    expect(await expectNothingLeasable(w)).toBeGreaterThanOrEqual(1);
  });
});

describe("P6 stop_agent_session ↔ Done(질문 있음)", () => {
  it("교착 0: Stop은 자기 행이라 KS NOWAIT를 통과하고, 물러나는 쪽은 Done이다", async () => {
    const w = await questionWorld();
    const { r1, r2 } = await crossed(w, { client: c, run: () => done(c, w) }, { client: b, run: () => fb.stop(w.user, w.session) });
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    expect(valueOf(r2)).toMatchObject({ tasks: [{ agent_task_id: w.task }] });
    await b.query("commit");
    await retry(c, () => done(c, w));
    expect(await runState(w)).toBe("stopped");
    expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='cancel'", [w.task])).toBe(1);
  });
});

describe("P7 재시도 소진 측정 (단언은 40P01 0뿐)", () => {
  it("세션을 0–285ms 쥐는 연결 20번에 Done(질문 있음)을 writeRpc와 같은 간격(0 · 50 · 150ms)으로 최대 3번 시도한다", async ({ annotate }) => {
    let exhausted = 0;
    let attemptsTotal = 0;
    const holds: number[] = [];
    for (let i = 0; i < 20; i++) {
      const hold = i * 15;
      const w = await questionWorld();
      await d.query("begin");
      await d.query("select id from public.agent_sessions where id=$1 for update", [w.session]);
      const releasing = sleep(hold).then(() => d.query("rollback"));
      let finished = false;
      for (const wait of [0, 50, 150]) {
        await sleep(wait);
        attemptsTotal++;
        await c.query("begin");
        const outcome = await pending(done(c, w));
        if ("error" in outcome) {
          await c.query("rollback");
          expect(codeOf(outcome), `hold ${hold}ms`).toBe("55P03"); // 40P01은 한 번도 나지 않는다
          continue;
        }
        await c.query("commit");
        finished = true;
        break;
      }
      await releasing;
      if (!finished) {
        exhausted++;
        holds.push(hold);
        await retry(c, () => done(c, w)); // 소진된 호출은 v1 route에서 500이 된다. 여기서는 풀린 뒤 한 번 더 해 끝낸다
      }
      expect(await runState(w)).toBe("stopped");
    }
    await annotate(`P7: ${exhausted}/20 hold들에서 3번 모두 55P03으로 소진 (총 ${attemptsTotal}번 시도, 소진된 hold ms: ${holds.join(",") || "없음"})`);
  }, 120_000);
});

describe("P8 회수 ↔ lease", () => {
  it("lease가 먼저(commit 전): 회수는 그 메시지를 건너뛴다(skip locked → busy)·쓰기 0·기다림 0, lease가 commit되면 단계 calling이고 회수는 더 하지 않는다", async () => {
    const w = await f.world();
    await f.q("update public.conversation_messages set delivery_expires_at = clock_timestamp() + interval '1200 milliseconds' where id=$1", [w.message]);
    await a.query("begin");
    expect(await fa.lease(w)).toMatchObject({ status: "leased" }); // 아직 만료 전이라 lease가 이긴다
    await sleep(1400); // 이제 만료. lease는 commit 전이라 회수의 후보 조회에는 아직 lease 전 prepared로 보인다
    const started = Date.now();
    expect(await fb.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(500);
    await a.query("commit");
    expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({ state: "calling" });
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "dispatched" });
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 0, sessions: [] });
    expect(await f.count("select 1 from public.execution_intents where step_id=$1", [w.step])).toBe(1);
  });

  it("회수가 먼저(commit 전): lease가 메시지 잠금에서 기다렸다가 stale/not_prepared, intent 0, Mac은 명령을 받지 않는다 (교착 0)", async () => {
    const w = await f.world();
    await f.updateRow("conversation_messages", w.message, { delivery_expires_at: PAST });
    await a.query("begin");
    expect(await fa.expire()).toMatchObject({ reclaimed: 1, busy: 0 });
    await b.query("begin");
    const leasing = pending(fb.lease(w));
    await blocked(b, a);
    await a.query("commit");
    expect(valueOf(await leasing)).toEqual({ status: "stale", reason: "not_prepared" });
    await b.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
    expect(await f.count("select 1 from public.execution_intents where step_id=$1", [w.step])).toBe(0);
    expect((await f.list(w)).commands.filter((command) => command.id === w.command)).toEqual([]);
  });

  it("잠금 아래 다시 확인: 후보 조회 뒤 만료가 늘어난 메시지는 회수하지 않는다 (낡은 후보 목록)", async () => {
    const first = await f.offlineWorld("2000-01-01T00:00:00Z");
    const second = await f.anotherOffline(first, "2000-01-02T00:00:00Z");
    // 첫 후보를 회수(쓰기)하는 동안 멈추게 하는 트리거를 시험 DB에만 건다. 회수는 기다리지 않으므로 멈추는 자리를 이렇게 만든다
    await f.q("create function public.tmp_f3_slow() returns trigger language plpgsql as $$ begin perform pg_sleep(1.5); return new; end $$");
    await f.q(`create trigger tmp_f3_slow before update of delivery_state on public.conversation_messages for each row
      when (new.delivery_state = 'expired' and old.delivery_state is distinct from 'expired') execute function public.tmp_f3_slow()`);
    try {
      const reclaiming = pending(fb.expire());
      for (let i = 0; i < 250; i++) {
        const row = (await setup.query<{ wait_event: string | null }>("select wait_event from pg_stat_activity where pid=$1", [pids.get(b)])).rows[0];
        if (row.wait_event === "PgSleep") break;
        await sleep(20);
      }
      await f.q("update public.conversation_messages set delivery_expires_at = now() + interval '1 day' where id=$1", [second.message]); // 둘째 후보의 만료가 미뤄짐
      const result = valueOf(await reclaiming);
      expect(result).toEqual({ reclaimed: 1, busy: 0, sessions: [{ user_id: first.user, agent_session_id: first.session }] }); // 둘째는 다시 확인에서 건너뜀
    } finally {
      await f.q("drop trigger if exists tmp_f3_slow on public.conversation_messages");
      await f.q("drop function if exists public.tmp_f3_slow()");
    }
    expect(await f.msg(second.message)).toMatchObject({ delivery_state: "dispatched" });
    expect(await f.one("select state from public.execution_steps where id=$1", [second.step])).toEqual({ state: "prepared" });
    await f.updateRow("conversation_messages", second.message, { delivery_state: "cancelled" }); // 시험 DB를 깨끗이
  });
});

describe("P9 회수 ↔ Send again (메시지 FU 경합)", () => {
  it("Send again이 먼저(commit 전): not_eligible, 회수는 그 분을 건너뛰고(busy) commit 뒤 다음 회수가 expired로 만든다", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    expect((await fa.requeue(w, [w.message])).messages).toEqual([{ message_id: w.message, result: "skipped", reason: "not_eligible" }]);
    const started = Date.now();
    expect(await fb.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(500);
    await a.query("commit");
    expect((await f.expire()).reclaimed).toBe(1);
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired" });
  });

  it("회수가 먼저(commit 전): Send again이 기다렸다가 requeued", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    expect((await fa.expire()).reclaimed).toBe(1);
    await b.query("begin");
    const again = pending(fb.requeue(w, [w.message]));
    await blocked(b, a);
    await a.query("commit");
    expect(valueOf(await again).messages).toEqual([{ message_id: w.message, result: "requeued" }]);
    await b.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "queued", delivery_reason: null });
  });
});

describe("P10 회수 ↔ Done · Stop · revoke_bridge · heartbeat 복귀 (회수는 기다리지 않는다)", () => {
  it.each([
    ["Done", (w: World) => ({ client: c, run: () => done(c, w) })],
    ["revoke_bridge", (w: World) => ({ client: c, run: () => c.query("select public.revoke_bridge($1,$2) as result", [w.user, w.bridge]) })],
  ] as const)("%s이 run · task를 쥐고 줄 서 있어도 회수는 기다리지 않고 busy로 건너뛴다 (교착 0). %s이 끝나면 메시지는 cancelled", async (name, racer) => {
    const w = await f.offlineWorld();
    await d.query("begin");
    await d.query("select id from public.agent_tasks where id=$1 for update", [w.task]); // 제3 연결이 task를 쥔다
    await c.query("begin");
    const closing = guard(c, pending(racer(w).run())); // Done · 폐기: run(과 폐기는 세션)을 쥐고 task에서 기다린다
    await blocked(c, d);
    const started = Date.now();
    expect(await fb.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(500);
    await d.query("rollback");
    const closed = await closing;
    expect(codeOf(closed), name).toBe("ok");
    await c.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "cancelled" });
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 0, sessions: [] });
  });

  it("Stop이 먼저면 회수는 그 메시지를 건너뛰고(busy) Stop이 commit하면 메시지는 cancelled — 회수할 것이 남지 않는다", async () => {
    const w = await f.offlineWorld();
    await c.query("begin");
    await fc.stop(w.user, w.session);
    expect(await fb.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    await c.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "cancelled" });
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 0, sessions: [] });
  });

  it("회수가 먼저면 Stop은 메시지 잠금에서 기다렸다가 취소할 작업이 없고, 메시지는 expired 그대로", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    expect((await fa.expire()).reclaimed).toBe(1);
    await b.query("begin");
    const stopping = pending(fb.stop(w.user, w.session));
    await blocked(b, a);
    await a.query("commit");
    expect(valueOf(await stopping)).toEqual({ tasks: [] });
    await b.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired" });
  });

  it("heartbeat가 먼저(commit 전): 회수는 그 세션을 기다리지 않고 busy, heartbeat가 commit한 뒤 다음 회수가 메시지를 expired로 만든다 (세션은 bound)", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    await a.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb)", [w.user, w.bridge]);
    const started = Date.now();
    expect(await fb.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(500);
    await a.query("commit");
    expect((await f.expire()).reclaimed).toBe(1);
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
    expect(await f.one("select status from public.agent_sessions where id=$1", [w.session])).toEqual({ status: "bound" });
  });

  it("회수가 먼저(commit 전): heartbeat(사용자 경로)가 세션 잠금에서 기다렸다가 끝나고, 끝 상태는 메시지 expired · 세션 bound", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    expect((await fa.expire()).reclaimed).toBe(1);
    await b.query("begin");
    const beating = pending<unknown>(b.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb)", [w.user, w.bridge]));
    await blocked(b, a);
    await a.query("commit");
    expect(codeOf(await beating)).toBe("ok");
    await b.query("commit");
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
    expect(await f.one("select status from public.agent_sessions where id=$1", [w.session])).toEqual({ status: "bound" });
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 0, sessions: [] });
  });
});

describe("P10c · P13b 백그라운드 작업(sweep · 회수)은 사용자 경로가 쥘 수 있는 잠금을 기다리지 않는다 — 여러 bridge (재검토 P2)", () => {
  let counter = 0;
  /**
   * bridge가 둘: A는 bridge id가 작고 세션 id가 크다, B는 bridge id가 크고 세션 id가 작다.
   * sweep은 bridge id 순(A → B), 회수 · Done은 세션 id 순(B → A)이라 서로 반대로 잠그면 순환이 된다.
   */
  async function twoBridgeWorld(shareAction: boolean) {
    const user = await f.user();
    await f.q("insert into public.execution_actors(user_id) values($1) on conflict do nothing", [user]);
    await f.q("update public.execution_controls set blocked=false");
    const tag = `d${String(++counter).padStart(3, "0")}`;
    let action: string | undefined;
    const open = async (bridgeId: string, sessionId: string, expires: string) => {
      const bridge = await f.bridge(user, { id: bridgeId });
      const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
      const session = await f.session(user, connection, { id: sessionId });
      const conversation = await f.agentConversation(user, connection, session);
      const message = String((await f.post(user, conversation, randomUUID(), "work")).message_id);
      const started = await f.start(user, message, shareAction && action ? [action] : []);
      expect(started.status).toBe("started");
      action ??= started.action_id!;
      await f.updateRow("conversation_messages", message, { delivery_expires_at: expires });
      return { bridge, session, message, task: started.agent_task_id!, run: started.run_id!, step: started.step_id! };
    };
    const A = await open(`aaaaaaaa-${tag}-4000-8000-0000000000a1`, `ffffffff-${tag}-4000-8000-0000000000f1`, "1990-01-02T00:00:00Z");
    const B = await open(`bbbbbbbb-${tag}-4000-8000-0000000000b1`, `00000001-${tag}-4000-8000-0000000000f2`, "1990-01-01T00:00:00Z");
    await f.q("update public.bridges set last_heartbeat_at='2000-01-01T00:00:00Z' where id = any($1::uuid[])", [[A.bridge, B.bridge]]);
    return { user, action: action!, A, B };
  }
  const sweep = (client: pg.Client) => client.query("select * from public.sweep_bridge_heartbeats(now(),50)");

  it("P10c 회수 ↔ sweep: 회수는 B 세션을 쥔 채 A를, sweep은 A 세션을 쥔 채 B를 기다리게 줄을 세워도 둘 다 기다리지 않고 끝난다 (교착 0)", async () => {
    const w = await twoBridgeWorld(false);
    await d.query("begin");
    await d.query("select id from public.agent_tasks where id=$1 for update", [w.A.task]); // 제3 연결이 A의 task를 쥔다
    await b.query("begin");
    const sweeping = guard(b, pending(sweep(b))); // 예전: bridge A의 세션 · run을 쥐고 task A에서 기다림. 지금: 못 쥐는 bridge A는 롤백하고 B를 처리해 끝남
    await settledOrBlocked(sweeping, b, d);
    await a.query("begin");
    const reclaiming = guard(a, pending(fa.expire())); // 예전: 세션 id 순이라 B를 쥔 채 A(sweep이 쥠)를 기다림. 지금: 못 쥐는 후보는 busy로 건너뜀
    await settledOrBlocked(reclaiming, a, b);
    const released = Date.now();
    await d.query("rollback");
    const swept = await sweeping;
    const reclaimed = await reclaiming;
    expect(Date.now() - released, "백그라운드 작업끼리 기다려 서로 물지 않는다(교착 감지는 1초)").toBeLessThan(600);
    if (codeOf(reclaimed) === "ok") await a.query("commit");
    if (codeOf(swept) === "ok") await b.query("commit");
    expect([codeOf(reclaimed), codeOf(swept)]).toEqual(["ok", "ok"]);
    // 건너뛴 쪽은 다음 분에 처리된다
    for (let round = 0; round < 3; round++) if ((await f.expire()).busy === 0) break;
    for (const x of [w.A, w.B]) expect(await f.msg(x.message)).toMatchObject({ delivery_state: "expired" });
  });

  it("P13b Done ↔ sweep: 같은 Action의 두 세션(다른 bridge)에서 Done(run을 세션 id 순)과 sweep(bridge id 순)이 서로 반대로 run을 잡으려 해도 교착이 없다 (sweep은 기다리지 않는다)", async () => {
    const w = await twoBridgeWorld(true);
    await d.query("begin");
    await d.query("select id from public.agent_tasks where id=$1 for update", [w.A.task]);
    await b.query("begin");
    const sweeping = guard(b, pending(sweep(b))); // 예전: bridge A의 세션 · run을 쥐고 task A에서 기다림. 지금: bridge A는 롤백하고 bridge B를 처리해 끝남
    await settledOrBlocked(sweeping, b, d);
    await c.query("begin");
    const closing = guard(c, pending(done(c, { user: w.user, action: w.action }))); // Done: run B를 쥐려 하고(sweep이 쥔 쪽이 있으면 기다림) 이어 run A
    await blocked(c, b);
    const released = Date.now();
    await d.query("rollback");
    const swept = await sweeping;
    expect(Date.now() - released, "sweep은 Done을 기다리지 않는다(교착 감지는 1초)").toBeLessThan(600);
    if (codeOf(swept) === "ok") await b.query("commit");
    const closed = await closing;
    if (codeOf(closed) === "ok") await c.query("commit");
    expect([codeOf(swept), codeOf(closed)]).toEqual(["ok", "ok"]);
    for (const x of [w.A, w.B]) expect((await f.one("select state from public.execution_runs where id=$1", [x.run])).state).toBe("stopped");
  });

  it("P10d 회수 ↔ heartbeat(같은 bridge): heartbeat가 쥔 세션은 기다리지 않고 busy, 푼 뒤 다음 호출이 회수한다", async () => {
    const w = await twoBridgeWorld(false);
    await a.query("begin");
    await a.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb)", [w.user, w.A.bridge]); // 세션 A · run A · task A를 쥔다
    const started = Date.now();
    const result = await fb.expire();
    expect(Date.now() - started).toBeLessThan(500);
    expect(result.busy).toBeGreaterThanOrEqual(1); // A 후보는 건너뜀
    expect(await f.msg(w.A.message)).toMatchObject({ delivery_state: "dispatched" });
    await a.query("commit");
    expect((await f.expire()).busy).toBe(0);
    for (const x of [w.A, w.B]) expect(await f.msg(x.message)).toMatchObject({ delivery_state: "expired" });
  });
});

describe("P10e sweep_bridge_heartbeats는 세션 · run · task · 단계 어느 잠금도 기다리지 않는다 (재검토 P2)", () => {
  it.each([
    ["세션", "agent_sessions", "session"], ["run", "execution_runs", "run"], ["task", "agent_tasks", "task"], ["단계", "execution_steps", "step"],
  ] as const)("남이 %s 행을 쥐고 있으면 기다리지 않고 그 bridge를 롤백해 실패 수 1로 돌려주고(세션은 그대로 bound), 풀린 뒤 다음 sweep이 처리한다", async (_name, table, key) => {
    const w = await f.world();
    await f.updateRow("bridges", w.bridge, { last_heartbeat_at: "2000-01-01T00:00:00Z" });
    await a.query("begin");
    await a.query(`select id from public.${table} where id=$1 for update`, [w[key]]);
    const started = Date.now();
    const rows = await fb.q("select * from public.sweep_bridge_heartbeats(now(),50)");
    expect(Date.now() - started).toBeLessThan(500);
    expect(rows).toEqual([{ user_id: null, bridge_id: null, agent_session_id: null, agent_task_id: null, turn_seq: null, failure_count: 1 }]);
    expect(await f.one("select status from public.agent_sessions where id=$1", [w.session])).toEqual({ status: "bound" }); // 롤백: 다음 분에 처음부터
    await a.query("rollback");
    expect(await fb.q("select * from public.sweep_bridge_heartbeats(now(),50)")).toEqual([]); // lease 전 dispatched는 바뀌는 task가 없다
    expect(await f.one("select status from public.agent_sessions where id=$1", [w.session])).toEqual({ status: "unreachable" });
  });
});

describe("P10f 같은 cron의 단계 lease 정리 · 실행 sweep · 보관 정리는 사용자 경로와 역순으로 기다리지 않는다 (재검토 2 P2)", () => {
  /** lease가 이미 지난 calling 단계 하나 (세션 bound) */
  async function overdue() {
    const w = await f.world();
    await f.lease(w);
    await f.updateRow("execution_steps", w.step, { lease_expires_at: PAST });
    return w;
  }
  const partners: [string, (w: World) => Promise<unknown>][] = [
    ["Done", (w) => done(c, w)],
    ["사용자 Stop", (w) => fc.stop(w.user, w.session)],
    ["revoke_bridge", (w) => c.query("select public.revoke_bridge($1,$2)", [w.user, w.bridge])],
    ["heartbeat", (w) => c.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb)", [w.user, w.bridge])],
    ["lease 재요청", (w) => fc.lease(w)],
    ["settlement(readback)", (w) => fc.settle(w, "readback", "received", true)],
  ];
  const sweeps: [string, (client: pg.Client) => Promise<unknown>][] = [
    ["sweep_agent_step_leases", (client) => client.query("select public.sweep_agent_step_leases(null) as n")],
    ["sweep_expire", (client) => client.query("select public.sweep_expire() as n")],
  ];
  const cases = sweeps.flatMap(([sweepName, sweepCall]) => partners.map(([partnerName, partnerRun]) => [sweepName, partnerName, sweepCall, partnerRun] as const));

  it.each(cases)("%s ↔ %s: 사용자 경로가 run을 쥐고 단계를 기다리는 동안 sweep은 기다리지 않고 물러난다 (교착 0)", async (_sweepName, _partnerName, sweepCall, partnerRun) => {
    const w = await overdue();
    await d.query("begin");
    await d.query("select id from public.agent_tasks where id=$1 for update", [w.task]); // 제3 연결이 task를 쥔다
    await c.query("begin");
    const partner = guard(c, pending(partnerRun(w))); // 사용자 경로: run(과 앞 순서 행)을 쥐고 task에서 기다린다 — 이어서 단계를 잠그려 한다
    await blocked(c, d);
    const sweeping = pending(sweepCall(b)); // 예전: 단계를 먼저 쥐고 트리거가 run을 기다림(step -> run). 지금: run을 SKIP LOCKED로 먼저 쥐려다 건너뜀
    await settledOrBlocked(sweeping, b, c);
    const released = Date.now();
    await d.query("rollback");
    const swept = await sweeping;
    const closed = await partner;
    expect(Date.now() - released, "교착 감지(1초)를 기다리지 않는다").toBeLessThan(800);
    if (codeOf(closed) === "ok") await c.query("commit");
    expect([codeOf(swept), codeOf(closed)]).toEqual(["ok", "ok"]);
  });

  it.each(sweeps)("%s: 사용자 경로가 run을 쥐고 있으면 건너뛰고(쓰기 0, 남은 만료 lease 1), 풀린 뒤 다음 호출이 처리한다", async (_name, sweepCall) => {
    const w = await overdue();
    await a.query("begin");
    await a.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb)", [w.user, w.bridge]); // 세션 · run · task · 단계를 쥔다 (단계는 바꾸지 않는다)
    const sweeping = pending(sweepCall(b));
    const early = await Promise.race([sweeping, sleep(800).then(() => "waiting" as const)]);
    if (early === "waiting") {
      await a.query("rollback"); // 기다리고 있었다면 풀어서 시험이 멈추지 않게
      await sweeping;
    }
    expect(early, "사용자 경로가 쥔 행을 기다리지 않는다").not.toBe("waiting");
    expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({ state: "calling" });
    expect((await f.one("select public.count_overdue_agent_step_leases(0) as n")).n).toBeGreaterThanOrEqual(1); // 건너뛴 단계가 숫자로 남는다
    await a.query("commit");
    await sweepCall(b);
    expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({ state: "unknown_outcome" });
  });

  it("보관 정리(purge_expired_execution_text): 다른 연결이 쥔 run은 기다리지 않고 건너뛰고, 풀린 뒤 다음 정리가 비운다", async () => {
    const w = await f.world();
    await done(setup, w); // run을 끝 상태(stopped)로
    expect(await runState(w)).toBe("stopped");
    await a.query("begin");
    await a.query("select id from public.execution_runs where id=$1 for no key update", [w.run]);
    const purging = pending(b.query("select public.purge_expired_execution_text(now() + interval '1 day', 5000) as n"));
    const early = await Promise.race([purging, sleep(800).then(() => "waiting" as const)]);
    await a.query("rollback"); // 정리가 기다리고 있었다면 여기서 풀린다
    expect(early, "정리는 남이 쥔 run을 기다리지 않는다").not.toBe("waiting");
    expect(await f.one("select text_purged_at is null as pending from public.execution_runs where id=$1", [w.run])).toEqual({ pending: true });
    await b.query("select public.purge_expired_execution_text(now() + interval '1 day', 5000)");
    expect(await f.one("select text_purged_at is null as pending from public.execution_runs where id=$1", [w.run])).toEqual({ pending: false });
  });
});

describe("P11 회수 중 막힘은 후보 하나만 건너뛴다", () => {
  it("후보의 메시지를 남이 쥐면 기다리지 않고 busy (skip locked)", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    await a.query("select id from public.conversation_messages where id=$1 for update", [w.message]);
    const started = Date.now();
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(400);
    await a.query("rollback");
    expect((await f.expire()).reclaimed).toBe(1);
  });

  it.each([
    ["세션", "agent_sessions", "session"], ["run", "execution_runs", "run"], ["task", "agent_tasks", "task"], ["단계", "execution_steps", "step"], ["명령", "bridge_commands", "command"],
  ] as const)("후보의 %s 행을 남이 쥐면 기다리지 않고 바로 busy, 쓰기 0 (NOWAIT)", async (_name, table, key) => {
    const w = await f.offlineWorld();
    await a.query("begin");
    await a.query(`select id from public.${table} where id=$1 for update`, [w[key]]);
    const started = Date.now();
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(500);
    expect(await f.msg(w.message)).toMatchObject({ delivery_state: "dispatched" });
    await a.query("rollback");
    expect((await f.expire()).reclaimed).toBe(1);
  });

  it("후보 셋 중 메시지가 막힌 것 · 세션이 막힌 것은 busy, 나머지 하나는 회수한다. 전체 시간 < 1초 (기다림 0)", async () => {
    const one = await f.offlineWorld("2000-01-01T00:00:00Z");
    const two = await f.anotherOffline(one, "2000-01-02T00:00:00Z");
    const three = await f.anotherOffline(one, "2000-01-03T00:00:00Z");
    await a.query("begin");
    await a.query("select id from public.conversation_messages where id=$1 for update", [one.message]);
    await d.query("begin");
    await d.query("select id from public.agent_sessions where id=$1 for update", [two.session]);
    const started = Date.now();
    const result = await f.expire();
    expect(Date.now() - started).toBeLessThan(1000);
    expect(result).toEqual({ reclaimed: 1, busy: 2, sessions: [{ user_id: three.user, agent_session_id: three.session }] });
    expect(await f.msg(three.message)).toMatchObject({ delivery_state: "expired" });
    expect(await f.msg(one.message)).toMatchObject({ delivery_state: "dispatched" });
    expect(await f.msg(two.message)).toMatchObject({ delivery_state: "dispatched" });
    await a.query("rollback");
    await d.query("rollback");
    expect((await f.expire()).reclaimed).toBe(2); // 막힘이 풀리면 다음 분에 회수된다 (시험 DB를 깨끗이)
  });
});

describe("P11b 후보가 아닌 행은 잠그지도 않는다 (후보 조건 하나씩)", () => {
  // 세션을 남이 쥐고 있어도 기다리지 않아야 한다: 후보로 잡혔다면 세션 NOWAIT에서 물러나 busy 1이 된다(후보가 아니면 busy 0).
  // 각 사례는 그 조건 하나만 어긋난 행이다 (다른 조건과 withdraw_bridge_command의 자체 확인이 가리지 못하게 일부러 어긋난 행을 만든다)
  const variants: [string, (w: World) => Promise<unknown>][] = [
    ["명령이 lease됨(단계는 prepared)", (w) => f.q("update public.bridge_commands set lease_owner='x', leased_at=now() where id=$1", [w.command])],
    ["단계에 lease_owner가 있음(명령은 lease 전)", (w) => f.q("update public.execution_steps set lease_owner='x' where id=$1", [w.step])],
    ["명령이 이미 끝남(outcome)", (w) => f.q("update public.bridge_commands set outcome='withdrawn', outcome_at=now() where id=$1", [w.command])],
    ["단계가 prepared가 아님", (w) => f.updateRow("execution_steps", w.step, { state: "failed" })],
    ["message 명령이 아님(answer)", (w) => f.q("update public.bridge_commands set kind='answer' where id=$1", [w.command])],
    ["메시지가 dispatched가 아님", (w) => f.updateRow("conversation_messages", w.message, { delivery_state: "cancelled" })],
    ["메시지 만료 전", (w) => f.updateRow("conversation_messages", w.message, { delivery_expires_at: new Date(Date.now() + 3_600_000).toISOString() })],
  ];
  it.each(variants)("%s", async (_name, arrange) => {
    const w = await f.world();
    await f.updateRow("conversation_messages", w.message, { delivery_expires_at: PAST });
    await arrange(w);
    await a.query("begin");
    await a.query("select id from public.agent_sessions where id=$1 for update", [w.session]);
    const started = Date.now();
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 0, sessions: [] });
    expect(Date.now() - started).toBeLessThan(500);
    await a.query("rollback");
  });
});

describe("P12 cron 겹침", () => {
  it("한 쪽이 회수 중(commit 전)이면 다른 쪽은 그 메시지를 건너뛰고(busy) 기다리지 않는다. 회수는 한 번", async () => {
    const w = await f.offlineWorld();
    await a.query("begin");
    expect((await fa.expire()).reclaimed).toBe(1);
    const started = Date.now();
    expect(await fb.expire()).toEqual({ reclaimed: 0, busy: 1, sessions: [] });
    expect(Date.now() - started).toBeLessThan(400);
    await a.query("commit");
    expect(await f.expire()).toEqual({ reclaimed: 0, busy: 0, sessions: [] });
    expect(await f.count("select 1 from public.execution_events where step_id=$1 and type='step' and to_state='failed'", [w.step])).toBe(1);
  });

  it("두 번을 동시에 불러도 각 메시지는 한 번만 회수된다 (교착 0)", async () => {
    const one = await f.offlineWorld("2000-01-01T00:00:00Z");
    const two = await f.anotherOffline(one, "2000-01-02T00:00:00Z");
    const three = await f.anotherOffline(one, "2000-01-03T00:00:00Z");
    const [x, y] = await Promise.all([pending(fb.expire()), pending(fc.expire())]);
    expect([codeOf(x), codeOf(y)]).toEqual(["ok", "ok"]);
    const rest = await f.expire();
    expect(valueOf(x).reclaimed + valueOf(y).reclaimed + rest.reclaimed).toBe(3);
    for (const w of [one, two, three]) {
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired" });
      expect(await f.count("select 1 from public.execution_events where step_id=$1 and type='step' and to_state='failed'", [w.step])).toBe(1);
    }
  });
});

describe("P13 Done ↔ heartbeat · revoke_bridge — 한 이슈에 같은 bridge의 두 세션 run (run 순서)", () => {
  let counter = 0; // 시험마다 id가 겹치지 않게 둘째 묶음만 바꾼다 (앞 여덟 글자가 순서를 정한다)
  const ids = () => {
    const n = String(++counter).padStart(4, "0");
    return {
      sessionA: `aaaaaaaa-${n}-4000-8000-0000000000aa`, // 세션 id 순으로 먼저
      sessionB: `bbbbbbbb-${n}-4000-8000-0000000000bb`,
      runOfA: `99999999-${n}-4000-8000-000000000009`, // 앞 세션의 run이 id로는 뒤
      runOfB: `11111111-${n}-4000-8000-000000000001`,
    };
  };

  /** 한 Action에 세션 둘(앞 세션의 run id가 더 큼). 시험 DB에서만 run id 기본값을 잠시 고정한다 */
  async function twoSessionWorld() {
    const user = await f.user();
    const bridge = await f.bridge(user);
    const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
    await f.q("insert into public.execution_actors(user_id) values($1) on conflict do nothing", [user]);
    await f.q("update public.execution_controls set blocked=false");
    const original = String((await f.one("select column_default as d from information_schema.columns where table_schema='public' and table_name='execution_runs' and column_name='id'")).d);
    const open = async (sessionId: string, runId: string, actions: string[]) => {
      const session = await f.session(user, connection, { id: sessionId });
      const conversation = await f.agentConversation(user, connection, session);
      const message = String((await f.post(user, conversation, randomUUID(), "work")).message_id);
      await f.q(`alter table public.execution_runs alter column id set default '${runId}'::uuid`);
      try {
        const started = await f.start(user, message, actions);
        expect(started).toMatchObject({ status: "started", run_id: runId });
        return { session, conversation, message, task: started.agent_task_id!, run: started.run_id!, step: started.step_id!, action: started.action_id! };
      } finally {
        await f.q(`alter table public.execution_runs alter column id set default ${original}`);
      }
    };
    const id = ids();
    const first = await open(id.sessionA, id.runOfA, []);
    const second = await open(id.sessionB, id.runOfB, [first.action]);
    expect(second.action).toBe(first.action);
    return { user, bridge, connection, first, second };
  }

  /** 상대(heartbeat · revoke)가 앞 세션의 run을 쥔 채 그 task에서 멈춰 있을 때, Done이 시작한다 */
  const interleave = async (opposite: (w: Awaited<ReturnType<typeof twoSessionWorld>>) => Promise<unknown>) => {
    const w = await twoSessionWorld();
    await d.query("begin");
    await d.query("select id from public.agent_tasks where id=$1 for update", [w.first.task]); // 앞 세션의 task를 제3 연결이 쥔다
    await b.query("begin");
    const other = guard(b, pending(opposite(w)));
    await blocked(b, d); // 상대: 세션 · 앞 run을 쥐고 task를 기다림
    await c.query("begin");
    const closing = guard(c, pending(done(c, { user: w.user, action: w.first.action })));
    await blocked(c, b); // Done: 앞 세션의 run(상대가 쥠)을 기다림 — main에서는 뒤 세션의 run을 먼저 쥔 채
    await d.query("rollback");
    // 상대(앞 run을 쥠)가 먼저 끝나 commit해야 Done이 이어 간다. 줄 서는 순서가 맞으면 둘 다 ok다
    const r2 = await other;
    if (codeOf(r2) === "ok") await b.query("commit");
    const r1 = await closing;
    if (codeOf(r1) === "ok") await c.query("commit");
    return { w, r1, r2 };
  };

  it.each([
    ["bridge_heartbeat", (w: Awaited<ReturnType<typeof twoSessionWorld>>) => b.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb) as result", [w.user, w.bridge])],
    ["revoke_bridge", (w: Awaited<ReturnType<typeof twoSessionWorld>>) => b.query("select public.revoke_bridge($1,$2) as result", [w.user, w.bridge])],
  ] as const)("Done ↔ %s: run을 같은 순서(세션 → run)로 잡아 줄 선다. 40P01 0, 둘 다 끝남", async (_name, opposite) => {
    const { w, r1, r2 } = await interleave(opposite);
    expect([codeOf(r1), codeOf(r2)]).toEqual(["ok", "ok"]);
    for (const run of [w.first.run, w.second.run]) expect((await f.one("select state from public.execution_runs where id=$1", [run])).state).toBe("stopped");
  });
});

describe("P14 시작 ↔ Done 고정 (지금도 녹색이어야 한다)", () => {
  it("진행 중 task가 있는 세션에 시작을 걸면 Done이 Action을 쥔 채여도 기다리지 않고 queued/session_busy", async () => {
    const w = await f.world();
    const behind = String((await f.post(w.user, w.conversation, randomUUID(), "behind")).message_id);
    await c.query("begin");
    await done(c, w); // Done이 Action · run · task를 쥔 채 commit 전
    await b.query("begin");
    await b.query("set local lock_timeout = '1500ms'");
    const started = Date.now();
    const result = (await fb.start(w.user, behind)) as { status: string; reason?: string };
    await b.query("commit");
    expect(Date.now() - started).toBeLessThan(1000);
    expect(result).toMatchObject({ status: "queued", reason: "session_busy" });
    await c.query("commit");
  });
});

describe("P15 stop_agent_run_for_path_conflict(질문 있음) ↔ 답 (P1 모양)", () => {
  it("40P01 0: 경로 충돌 중단은 55P03 뒤 다시 하면 끝나고, 답은 answered", async () => {
    const w = await questionWorld();
    const holderAction = await f.action(w.user);
    const holderSession = await f.session(w.user, w.connection);
    const holderRun = await f.agentRun(w.user, holderAction, { agent_session_id: holderSession });
    const lease = await f.insertRow("agent_path_leases", {
      user_id: w.user, bridge_id: w.bridge, run_id: holderRun, agent_session_id: holderSession, workspace_ref: "/w", path_key: `/w/${randomUUID()}.mdx`,
      rel_path: "a.mdx", source: "observed", conflict_run_id: w.run, conflict_at: new Date().toISOString(),
    });
    const stopRun = (client: pg.Client) => client.query<{ result: { status: string } }>("select public.stop_agent_run_for_path_conflict($1,$2) as result", [w.user, lease]);
    const { r1, r2, firstMs } = await crossed(w, { client: c, run: () => stopRun(c) }, { client: b, run: () => local(fb, w) });
    expect([codeOf(r1), codeOf(r2)]).toEqual(["55P03", "ok"]);
    expect(firstMs).toBeLessThan(500);
    expect(valueOf(r2)).toMatchObject({ status: "answered" });
    await b.query("commit");
    const again = (await retry(c, () => stopRun(c))) as { rows: { result: { status: string } }[] };
    expect(again.rows[0].result.status).toBe("stopped");
    expect(await runState(w)).toBe("stopped");
  });
});

describe("에이전트 전달 정리 (실제 Postgres)", () => {
  deliveryFixesTests(db(() => setup));
});
