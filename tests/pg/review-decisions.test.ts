import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import type { ReviewDecisionsResponse } from "@/lib/api/contract";
import { loadReview, loadReviewDecisions } from "@/lib/review/review";

import { sqlAdmin } from "../conversation/sql-admin";
import { seed } from "../coordinator/support";
import { supabaseSchemaScripts } from "../db/local-supabase";
import { BOTH, reviewAgentInputsFixtures, SECRET } from "../db/review-agent-inputs.scenarios";

// OA R-dec P1–P3: 결정만 읽는 경로(loadReviewDecisions)가 Taskforce 행을 쓰지 않는다는 것을 실제 Postgres에서 증명한다(로더가 쓰는 연결 기준 — 인증 계층의 쿠키 세션 갱신은 이 시험의 범위 밖이다).
//  - P1 쓰기 0: 트랜잭션 id가 배정되지 않고(어떤 표에 한 번이라도 쓰면 배정된다 — 미래의 쓰기 경로도 잡는다), pg_stat_xact_user_tables의 삽입 · 갱신 · 삭제 증감이 0이고,
//    앞뒤 public 모든 표의 digest · suggestions 전 열이 같고, `begin read only`에서도 결정이 ok다. 대조: 같은 세계에서 loadReview는 셋 다 바뀐다.
//  - P2 같음: 같은 세계에서 결정만 → loadReview 순서로 decisions JSON 바이트 동일.
//  - P3 잠금 0: 제안 advisory lock · suggestions 행 잠금을 다른 연결이 쥐고 있어도 결정만은 기다리지 않는다. 대조: loadReview는 그 advisory lock에서 기다린다.
// 코디네이터의 일회용 PostgreSQL에서만 돈다 (npm run test:pg). DATABASE_URL이 없으면 건너뛰지 않고 실패한다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL.");
const DB_NAME = `taskforce_review_decisions_${process.pid}_${Date.now()}`;
let admin: pg.Client, setup: pg.Client, a: pg.Client, tx: pg.Client, reader: pg.Client;
let aPid: number, readerPid: number;
let s: ReturnType<typeof seed>;
let f: ReturnType<typeof reviewAgentInputsFixtures>;

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
  tx = await connect(DB_NAME);
  reader = await connect(DB_NAME);
  aPid = await pidOf(a);
  readerPid = await pidOf(reader);
  // seed는 db.query(sql, params).rows만 쓴다: pg 연결이 그대로 맞는다
  s = seed(setup as unknown as PGlite);
  f = reviewAgentInputsFixtures(() => ({
    query: async (sql, params) => (await setup.query(sql, params)).rows,
    asUser: async (user, fn) => {
      await setup.query("set role authenticated");
      await setup.query("select set_config('request.jwt.claim.sub',$1,false)", [user]);
      try {
        return await fn();
      } finally {
        await setup.query("reset role");
        await setup.query("select set_config('request.jwt.claim.sub','',false)");
      }
    },
  }));
}, 120_000);
afterEach(async () => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  // a(잠금을 쥔 연결)를 먼저 놓아야 기다리던 연결이 끝난다
  for (const client of [a, tx, reader]) await client?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), tx?.end(), reader?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

const NOW = new Date();
const hoursFromNow = (h: number) => new Date(NOW.getTime() + h * 3_600_000).toISOString();
const SEOUL = async () => "Asia/Seoul";
/** 한 pg 연결 위에서 운영 TS를 돌린다 (열린 트랜잭션이 있으면 그 안에서). 한 연결에 쿼리를 차례로 보낸다 (겹쳐 보내지 않는다) */
const over = (client: pg.Client) => {
  let chain: Promise<unknown> = Promise.resolve();
  return sqlAdmin((sql, params) => {
    const run = async () => (await client.query(sql, params)).rows;
    const next = chain.then(run, run);
    chain = next.catch(() => undefined);
    return next;
  });
};
const decisionsOn = (client: pg.Client, user: string, agentAdapters?: readonly string[]) => loadReviewDecisions(over(client), user, NOW, { agentAdapters });
const reviewOn = (client: pg.Client, user: string, agentAdapters?: readonly string[]) => loadReview(over(client), user, NOW, { coordinatorEnabled: false, timeZone: SEOUL, agentAdapters });

const pending = <T,>(promise: Promise<T>) => promise.then((value) => ({ value }), (error) => ({ error }));
async function resolved<T>(promise: ReturnType<typeof pending<T>>) {
  const result = await promise;
  if ("error" in result) throw result.error;
  return result.value;
}

/**
 * 열린 트랜잭션이 쓴 흔적: 배정된 트랜잭션 id(없으면 null) + 이 트랜잭션 **동안** 늘어난 표 삽입 · 갱신 · 삭제 합.
 * pg_stat_xact_user_tables에는 같은 연결의 앞선 트랜잭션이 아직 내보내지 않은(1초 간격) 통계도 섞여 보이므로 절대값이 아니라 begin 직후 값과의 차이를 본다.
 */
const writeSum = async (client: pg.Client) =>
  Number((await client.query<{ n: string }>("select coalesce(sum(n_tup_ins + n_tup_upd + n_tup_del), 0)::text as n from pg_stat_xact_user_tables")).rows[0].n);
/** 트랜잭션을 열고 그 시점의 표 쓰기 합(기준값)을 돌려준다 */
async function begin(client: pg.Client) {
  await client.query("begin");
  return writeSum(client);
}
async function writeProof(client: pg.Client, baseline: number) {
  const xid = (await client.query<{ xid: string | null }>("select pg_current_xact_id_if_assigned()::text as xid")).rows[0].xid;
  return { xid, writes: (await writeSum(client)) - baseline };
}

/** 결정 대기 세계 (review-agents.test.ts richWorld와 같은 모양) */
async function richWorld() {
  const w = await f.agentWorld();
  await f.updateRow("actions", w.action, { title: "비밀 이슈 제목" });
  const confirm = await s.action(w.user, { title: "확인 요청 일", needsConfirmation: true });
  await s.q("update public.actions set last_activity_at = $2 where id = $1", [confirm, "2026-10-10T00:00:00Z"]);
  // C3 입력 대기 하나 더: run이 needs_input으로 끝난 열린 Action → run_input. 에이전트 gate와 무관한 C3 종류라 새 경로가 빠뜨리면 같음 시험이 빨개진다
  const inputAction = await s.action(w.user, { title: "답이 필요한 일" });
  const inputRun = await s.run(w.user, inputAction);
  await s.q("update public.execution_runs set state = 'running' where id = $1", [inputRun]);
  await s.q("update public.execution_runs set state = 'done', outcome = 'needs_input' where id = $1", [inputRun]);
  await f.ask(w, { asked_at: "2026-10-11T00:00:00Z" }, "req-q");
  const approvalRun = await f.otherRun(w);
  await f.asking(w.user, approvalRun, { kind: "approval", asked_at: "2026-10-11T01:00:00Z" });
  await f.updateRow("actions", approvalRun.action, { due_at: hoursFromNow(2) });
  const secretRun = await f.otherRun(w);
  await f.asking(w.user, secretRun, { secrets: [false, true], asked_at: "2026-10-11T02:00:00Z" });
  const resultRun = await f.otherRun(w);
  const resultTask = await f.task(w.user, resultRun.run, resultRun.session, { turn_seq: 1, state: "idle" });
  await f.insertRow("agent_artifacts", { user_id: w.user, run_id: resultRun.run, agent_task_id: resultTask, turn_seq: 1, path: "비밀 파일.md", content_hash: "hash", summary: SECRET, created_at: "2026-10-11T03:00:00Z" });
  const laterRun = await f.otherRun(w);
  await f.insertRow("agent_path_leases", {
    user_id: w.user, bridge_id: w.bridge, run_id: w.run, agent_session_id: w.session, workspace_ref: "/w/proj", path_key: `/w/proj/${randomUUID()}.mdx`, rel_path: "/w/proj/비밀 경로.mdx",
    source: "observed", conflict_run_id: laterRun.run, conflict_at: "2026-10-11T04:00:00Z", conflict_version: 1,
  });
  return { w, user: w.user, confirm, inputAction };
}

/** 제안이 생길 세계 (PGlite D6과 같다): 생산 후보(due_window · run_failed), snooze가 끝난 제안, 하루 묶음에 들어갈 비긴급 제안, 증거 있는 만료 후보 + 결정 대기 항목 */
async function suggestionWorld() {
  const r = await richWorld();
  const user = r.user;
  await s.action(user, { title: "곧 마감", dueAt: hoursFromNow(10) });
  const failedAction = await s.action(user, { title: "실패한 일" });
  await s.q("update public.execution_runs set state = 'failed' where id = $1", [await s.run(user, failedAction)]);
  const plainAction = await s.action(user, { title: "다시 검토할 일" });
  const plainRun = await s.run(user, plainAction);
  const plain: string[] = [];
  for (let i = 0; i < 3; i++) {
    plain.push(
      await s.id(
        `insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key, created_at)
         values ($1, 'source_revised_run', $2, $3, $4, $5, $6, now() + make_interval(secs => $7)) returning id`,
        [user, plainAction, plainRun, `run:${plainRun}:${i}`, `r${i}`, `source_revised_run:run:${plainRun}:${i}:${randomUUID()}`, i],
      ),
    );
  }
  await s.q("update public.suggestions set state = 'snoozed', snooze_until = $2 where id = $1", [plain[2], hoursFromNow(-1)]);
  const closed = await s.action(user, { title: "이미 끝난 일", status: "done" });
  const stale = await s.id(
    `insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key, urgent) values ($1, 'due_window', $2, $3, '1', $4, true) returning id`,
    [user, closed, `action:${closed}`, `due_window:action:${closed}:1`],
  );
  return { ...r, plain, stale };
}

type Row = Record<string, unknown>;
/** public의 모든 표: 행 수 + 내용 digest (update만 하는 쓰기도 digest가 달라진다) */
async function tableDigests(): Promise<Record<string, string>> {
  const names = (await s.q(`select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1`)).map((row) => String(row.table_name));
  const out: Record<string, string> = {};
  for (const name of names) {
    const row = await s.one(`select count(*)::int as n, coalesce(md5(string_agg(x::text, '|' order by x::text)), '') as h from public.${name} x`);
    out[name] = `${row.n}:${row.h}`;
  }
  return out;
}
const suggestionRows = async (user: string): Promise<Row[]> => (await s.q(`select * from public.suggestions where user_id = $1 order by id`, [user])).map((row) => JSON.parse(JSON.stringify(row)) as Row);
const snapshotOf = async (user: string) => ({ tables: await tableDigests(), suggestions: await suggestionRows(user) });
const changedTables = (before: Record<string, string>, after: Record<string, string>) => Object.keys(after).filter((name) => after[name] !== before[name]);

describe("P1 쓰기 0 증명 (실제 Postgres)", () => {
  it("결정만 읽기: 트랜잭션 id 미배정 · 표 증감 0 · 앞뒤 public 모든 표와 suggestions 전 열이 같다. 대조: 같은 세계에서 loadReview는 셋 다 바뀐다", async () => {
    const w = await suggestionWorld();
    const before = await snapshotOf(w.user);
    expect(before.suggestions).toHaveLength(4); // 시드한 제안 넷 (읽기 전에는 생산도 노출도 없다)

    // 결정만: 어댑터 세 경우를 한 트랜잭션에서 모두 읽는다
    const base = await begin(tx);
    const results: ReviewDecisionsResponse[] = [];
    for (const adapters of [BOTH, [], undefined]) results.push(await decisionsOn(tx, w.user, adapters));
    const proof = await writeProof(tx, base);
    await tx.query("commit");
    expect(results.map((r) => r.sources.decisions)).toEqual(["ok", "ok", "ok"]);
    expect(results[0].decisions!.length).toBeGreaterThan(1); // 빈 읽기가 아니다
    expect(proof.xid).toBeNull();
    expect(proof.writes).toBe(0);
    expect(await snapshotOf(w.user)).toEqual(before);

    // 대조: 같은 세계에서 loadReview는 xid를 배정받고, 표를 쓰고, 스냅숏이 달라진다
    const contrastBase = await begin(tx);
    await reviewOn(tx, w.user, BOTH);
    const contrast = await writeProof(tx, contrastBase);
    await tx.query("commit");
    const after = await snapshotOf(w.user);
    expect(contrast.xid).not.toBeNull();
    expect(contrast.writes).toBeGreaterThan(0);
    expect(after).not.toEqual(before);
    expect(changedTables(before.tables, after.tables)).toEqual(["suggestions"]);
    expect(after.suggestions.length).toBeGreaterThan(before.suggestions.length);
    expect(after.suggestions.filter((row) => row.shown_at !== null).length).toBeGreaterThan(0);
    expect(after.suggestions.filter((row) => row.batch_day !== null).length).toBeGreaterThan(0);
  });

  it("begin read only에서도 결정이 ok다 (쓰기가 있으면 25006으로 원천이 unavailable이 되어 실패한다). 대조: 같은 세계에서 loadReview는 제안 원천이 unavailable이 된다", async () => {
    const w = await suggestionWorld();
    await tx.query("begin read only");
    const only = await decisionsOn(tx, w.user, BOTH);
    await tx.query("commit");
    expect(only).toMatchObject({ complete: true, empty: false, sources: { decisions: "ok" } });
    expect(only.decisions!.length).toBeGreaterThan(1);

    vi.spyOn(console, "error").mockImplementation(() => {});
    await tx.query("begin read only");
    const review = await reviewOn(tx, w.user, BOTH);
    await tx.query("rollback");
    expect(review.sources.suggestions).toBe("unavailable"); // suggestions_produce의 insert가 읽기 전용 트랜잭션에서 거절됐다
    expect(review.complete).toBe(false);
  });

  it("제안 후보가 전혀 없는 사용자도 xid를 배정받지 않는다 (빈 읽기)", async () => {
    const user = await s.user();
    const base = await begin(tx);
    const only = await decisionsOn(tx, user, BOTH);
    const proof = await writeProof(tx, base);
    await tx.query("commit");
    expect(only).toMatchObject({ complete: true, empty: true, decisions: [] });
    expect(proof).toEqual({ xid: null, writes: 0 });
  });
});

describe("P2 같음 (실제 Postgres): 결정만 → loadReview 순서로 decisions JSON 바이트 동일", () => {
  it("어댑터 여섯 경우 모두 같은 JSON이고 sources.decisions도 같다", async () => {
    const w = await richWorld();
    const cases: [readonly string[] | undefined, Record<string, string>][] = [
      [[], {}],
      [["agent:codex"], {}],
      [["agent:claude-code"], {}],
      [BOTH, {}],
      [undefined, {}],
      [undefined, { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" }],
    ];
    const kinds = new Set<string>();
    for (const [adapters, env] of cases) {
      vi.unstubAllEnvs();
      for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
      const only = await decisionsOn(reader, w.user, adapters);
      const both = await reviewOn(reader, w.user, adapters);
      expect(JSON.stringify(only.decisions), JSON.stringify([adapters, env])).toBe(JSON.stringify(both.decisions));
      expect(only.sources.decisions).toBe(both.sources.decisions);
      // 종류도 순서까지 같고, C3 종류(confirm · run_input)는 adapter가 꺼져 있어도 켜져 있어도 빠지지 않는다 (C3 입력 대기 동등성)
      const kindsOf = (response: ReviewDecisionsResponse) => (response.decisions ?? []).map((g) => g.kind);
      expect(kindsOf(only), JSON.stringify([adapters, env])).toEqual(kindsOf(both));
      for (const c3 of ["confirm", "run_input"]) expect(kindsOf(only), c3).toContain(c3);
      for (const group of only.decisions!) kinds.add(group.kind);
    }
    expect([...kinds].sort()).toEqual(["agent_approval", "agent_question", "agent_secret_question", "confirm", "path_conflict", "result_ready", "run_input"]); // 빈 비교가 아니다
  });
});

describe("P3 제안 잠금을 기다리지 않는다 (실제 Postgres)", () => {
  async function holdSuggestionLocks(user: string) {
    await a.query("begin");
    await a.query("select pg_advisory_xact_lock(hashtextextended('suggestions:' || $1::text, 0))", [user]);
    await a.query("select id from public.suggestions where user_id = $1 for update", [user]);
  }
  const heldByA = async () => Number((await setup.query<{ n: string }>("select count(*)::text as n from pg_locks where pid = $1 and locktype = 'advisory' and granted", [aPid])).rows[0].n);
  const blockersOfReader = async () => (await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [readerPid])).rows[0].blockers;
  const timeout = (ms: number) => new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), ms));

  it("다른 연결이 그 사용자의 제안 advisory lock과 suggestions 행을 쥔 동안에도 결정만은 1초 안에 끝나고 아무도 기다리지 않는다. 대조: loadReview는 그 advisory lock에서 기다린다", async () => {
    const w = await suggestionWorld();
    await holdSuggestionLocks(w.user);
    expect(await heldByA()).toBe(1);

    const started = Date.now();
    const read = pending(decisionsOn(reader, w.user, BOTH));
    const winner = await Promise.race([read, timeout(1_000)]);
    expect(winner, "결정만이 제안 잠금을 기다렸다").not.toBe("timeout");
    const only = await resolved(read);
    expect(Date.now() - started).toBeLessThan(1_000);
    expect(only).toMatchObject({ complete: true, sources: { decisions: "ok" } });
    expect(await blockersOfReader()).toEqual([]);
    expect(await heldByA()).toBe(1); // 읽는 동안 내내 쥐고 있었다

    // 대조: loadReview는 제안 생산의 advisory lock에서 a를 기다린다
    const review = pending(reviewOn(reader, w.user, BOTH));
    let blockers: number[] = [];
    for (let i = 0; i < 300 && !blockers.includes(aPid); i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
      blockers = await blockersOfReader();
    }
    expect(blockers, "loadReview가 기다리지 않았다 (대조가 성립하지 않는다)").toContain(aPid);
    await a.query("rollback");
    const done = await resolved(review);
    expect(done.sources).toMatchObject({ decisions: "ok", suggestions: "ok" });
  });
});
