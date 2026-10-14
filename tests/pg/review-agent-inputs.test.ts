import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { answerQuestionFixture } from "../db/agent-questions-stop.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";
import { BOTH, reviewAgentInputsFixtures, reviewAgentInputsTests } from "../db/review-agent-inputs.scenarios";

// OA D4b-s P1–P4: 읽기 함수(review_agent_inputs)는 잠금을 기다리지 않고, 답 · 해소 · 사후 충돌과 겹쳐도 commit 전에는 옛 상태, commit 뒤에는 새 상태를 오류 · 반쪽 없이 본다.
// 코디네이터의 일회용 PostgreSQL에서만 돈다 (npm run test:pg).
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL.");
const DB_NAME = `taskforce_review_inputs_${process.pid}_${Date.now()}`;
let admin: pg.Client, setup: pg.Client, a: pg.Client, b: pg.Client, reader: pg.Client;
let aPid: number, bPid: number;

async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '10s'");
  return client;
}
const pidOf = async (client: pg.Client) => (await client.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;

beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(DB_NAME);
  b = await connect(DB_NAME);
  reader = await connect(DB_NAME);
  aPid = await pidOf(a);
  bPid = await pidOf(b);
}, 120_000);
afterEach(async () => {
  for (const client of [a, b, reader]) await client?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), reader?.end(), setup?.end()]);
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
const f = reviewAgentInputsFixtures(db(() => setup));

const pending = <T,>(promise: Promise<T>) => promise.then((value) => ({ value }), (error) => ({ error }));
async function resolved<T>(promise: ReturnType<typeof pending<T>>) {
  const result = await promise;
  if ("error" in result) throw result.error;
  return result.value;
}
async function expectBWaitsForA() {
  for (let i = 0; i < 200; i++) {
    const rows = (await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [bPid])).rows;
    if (rows[0].blockers.includes(aPid)) return;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("Expected B to wait for A");
}
/** reader가 읽는다 (다른 연결). 잠금을 기다리면 3초 안에 끝나지 않는다 */
async function read(user: string, adapters: string[] = BOTH) {
  const started = Date.now();
  const query = pending(reader.query("select * from public.review_agent_inputs($1, $2::text[]) order by kind, item_ref", [user, adapters]));
  const timeout = new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), 3_000));
  const winner = await Promise.race([query, timeout]);
  if (winner === "timeout") throw new Error("review_agent_inputs waited for a lock");
  const rows = (await resolved(query)).rows as { kind: string; item_ref: string; version: string; detail: Record<string, unknown> }[];
  return { rows, ms: Date.now() - started };
}
const lockWaits = async () => (await setup.query<{ n: number }>("select count(*)::int n from pg_stat_activity where datname=$1 and wait_event_type='Lock'", [DB_NAME])).rows[0].n;

describe("review_agent_inputs on PostgreSQL (same scenarios as PGlite)", () => {
  reviewAgentInputsTests(db(() => setup));
});

describe("P1 읽기는 기다리지 않는다", () => {
  it("다른 연결이 agent_tasks · agent_path_leases 행을 for update, execution_runs 행을 for no key update로 쥔 동안에도 잠금 대기 없이 끝난다", async () => {
    const w = await f.conflictWorld();
    await f.ask(w);
    await a.query("begin");
    await a.query("select id from public.agent_tasks where id=$1 for update", [w.task]);
    await a.query("select id from public.agent_path_leases where id=$1 for update", [w.lease]);
    await a.query("select id from public.execution_runs where id=any($1) for no key update", [[w.run, w.later.run]]);
    await a.query("select id from public.agent_artifacts where user_id=$1 for update", [w.user]);
    const { rows, ms } = await read(w.user);
    expect(rows.map((r) => r.kind).sort()).toEqual(["agent_question", "path_conflict"]);
    expect(ms).toBeLessThan(3_000);
    expect(await lockWaits()).toBe(0); // reader는 누구도 기다리지 않았다
    await a.query("rollback");
  });
});

describe("P2 답 ↔ 읽기", () => {
  it("답이 commit 되기 전에는 옛 version으로 보이고, commit 뒤에는 항목이 없다 (오류 · 반쪽 0)", async () => {
    const w = await f.questionWorld(answerQuestionFixture(), "agent:codex");
    const before = (await read(w.user)).rows;
    expect(before).toHaveLength(1);
    await a.query("begin");
    const answered = (await a.query("select public.answer_agent_question($1,$2,'request',$3::jsonb,false) as result", [w.user, w.task, JSON.stringify({ choice: "A" })])).rows[0].result;
    expect(answered.status).toBe("answered");
    const during = (await read(w.user)).rows;
    expect(during).toEqual(before); // 옛 version 그대로 (commit 전 변경은 보이지 않는다)
    await a.query("commit");
    expect((await read(w.user)).rows).toEqual([]);
  });

  it("답이 rollback 되면 항목이 그대로 남는다", async () => {
    const w = await f.questionWorld(answerQuestionFixture(), "agent:codex");
    await a.query("begin");
    await a.query("select public.answer_agent_question($1,$2,'request',$3::jsonb,false)", [w.user, w.task, JSON.stringify({ choice: "A" })]);
    await a.query("rollback");
    const rows = (await read(w.user)).rows;
    expect(rows).toHaveLength(1);
    expect(rows[0].version).toBe(`question:${w.task}:request`);
  });
});

describe("P3 사후 충돌 트리거 ↔ 읽기", () => {
  it("다른 run의 산출물 insert가 commit 되기 전에는 충돌이 0, commit 뒤에는 1 (conflict_version 1)", async () => {
    const holder = await f.live();
    const later = await f.competitor(holder);
    await f.decide(holder, { decision: "allow", reason: "policy_auto", lease_op: "acquire" });
    expect((await read(holder.user)).rows.filter((r) => r.kind === "path_conflict")).toEqual([]);
    await a.query("begin");
    await a.query("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')", [later.user, later.run, later.task, later.turn]);
    expect((await read(holder.user)).rows.filter((r) => r.kind === "path_conflict")).toEqual([]);
    await a.query("commit");
    const rows = (await read(holder.user)).rows.filter((r) => r.kind === "path_conflict");
    expect(rows).toHaveLength(1);
    expect(rows[0].version).toBe(`conflict:${rows[0].item_ref}:1`);
    expect(rows[0].detail).toMatchObject({ holder_run_id: holder.run, later_run_id: later.run, conflict_version: 1 });
  });
});

describe("P4 해소 ↔ 새 충돌", () => {
  const resolve = (client: pg.Client, w: { user: string }, lease: string, keep: string, version: number) =>
    client.query("select public.resolve_path_conflict($1,$2,$3,$4) as result", [w.user, lease, keep, version]).then((r) => r.rows[0].result as { status: string });
  const conflicts = async (user: string) => (await read(user)).rows.filter((r) => r.kind === "path_conflict");

  it("해소 중(commit 전)에는 옛 version이 보이고, 그 해소에 막힌 새 충돌은 해소 뒤 새 version으로 나타난다. 옛 version 해소는 stale이다", async () => {
    const holder = await f.live();
    const later = await f.competitor(holder);
    await f.decide(holder, { decision: "allow", reason: "policy_auto", lease_op: "acquire" });
    await setup.query("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')", [later.user, later.run, later.task, later.turn]);
    const [first] = await conflicts(holder.user);
    expect(first.version).toBe(`conflict:${first.item_ref}:1`);

    await setup.query("update public.agent_artifacts set superseded_at=now() where run_id=$1", [later.run]); // 같은 경로의 현재 산출물은 run마다 하나라 옛 것을 교체한다
    await a.query("begin");
    await b.query("begin");
    expect(await resolve(a, holder, first.item_ref, "holder", 1)).toEqual({ status: "resolved" });
    expect((await conflicts(holder.user))[0].version).toBe(first.version); // 아직 commit 전: 옛 version
    // 새 충돌을 만드는 산출물 insert(B)는 lease 행을 기다린다
    const insertion = pending(b.query("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash2','Changed again')", [later.user, later.run, later.task, later.turn]));
    await expectBWaitsForA();
    await a.query("commit");
    await resolved(insertion);
    await b.query("commit");

    const [second] = await conflicts(holder.user);
    expect(second.item_ref).toBe(first.item_ref);
    expect(second.version).toBe(`conflict:${first.item_ref}:2`);
    expect(await resolve(setup, holder, first.item_ref, "later", 1)).toEqual({ status: "stale" });
    expect((await conflicts(holder.user))[0].version).toBe(second.version);
    expect(await resolve(setup, holder, first.item_ref, "later", 2)).toEqual({ status: "resolved" });
    expect(await conflicts(holder.user)).toEqual([]);
    const metrics = (await f.q("select props->>'keep' as keep from public.metric_events where user_id=$1 and type='path_conflict_resolved'", [holder.user])).map((r) => r.keep);
    expect(metrics.sort()).toEqual(["holder", "later"]); // 해소 두 번(stale 하나는 지표 0)
  });
});
