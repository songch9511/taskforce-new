import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { CHANGE_EVENT_TYPES } from "../../src/lib/actions/changed";
import { supabaseSchemaScripts } from "../db/local-supabase";
import { reviewFixtures, reviewSummaryTests, reviewSummaryUpgradeTests, TEST_CLOCK, type ReviewDb } from "../db/review-summary.scenarios";

// 0.2.0 C3 (20261111000000_review_summary + 후속 20261112000000_review_summary_baseline) — 실제 Postgres. PGlite와 같은 시나리오 + 연결이 둘 이상 필요한 경합:
//  - P2-A: Clear가 "조회가 본 사건 id"만 읽음으로 삼는다. 쓰는 트랜잭션이 조회 · Clear 사이에 미커밋이거나 아직 쓰기 전이어도(created_at = 트랜잭션 시작 시각이 지평 이전)
//    그 행은 Clear 뒤 commit되어 다음 조회에 보인다. 대조: 조회 뒤 Clear 전에 commit되면 stale.
//  - 같은 하루 묶음 동시 노출 · 동시 생산 · 동시 전이 · 동시 Clear(두 기기).
//  - 첫 정상 표시 기준점(A–D 후속 C): 조회 · 확정 사이에 commit된 범위 안 사건 → stale, 조회 때 미커밋이던 사건 → 확정 뒤에도 보임, 두 기기 동시 확정 → 하나만 initialized, 확정 vs Clear 동시.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const SUFFIX = `${process.pid}_${Date.now()}`;
const DB_NAME = `taskforce_review_${SUFFIX}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let writer: pg.Client;
const extraDatabases: string[] = [];
const extraClients: pg.Client[] = [];

function urlFor(database: string) {
  const url = new URL(DATABASE_URL!);
  url.pathname = `/${database}`;
  return url.toString();
}

async function connect(url: string) {
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  return client;
}

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
  writer = await connect(urlFor(DB_NAME));
}, 120_000);

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), writer?.end(), setup?.end(), ...extraClients.map((client) => client.end())]);
  if (admin) {
    for (const name of [DB_NAME, ...extraDatabases]) await admin.query(`drop database if exists ${name} with (force)`);
    await admin.end();
  }
});

afterEach(async () => {
  for (const client of [a, b, writer]) await client.query("rollback").catch(() => {});
});

// 한 연결(setup)에 쿼리를 차례로 보낸다: 시나리오가 Promise.all로 동시에 읽어도 pg 클라이언트에 겹쳐 보내지 않게
let chain: Promise<unknown> = Promise.resolve();
const serial = <T,>(run: () => Promise<T>): Promise<T> => {
  const next = chain.then(run, run);
  chain = next.catch(() => undefined);
  return next;
};

const db = (): ReviewDb => ({
  query: (sql, params) => serial(async () => (await setup.query(sql, params)).rows),
  asUser: async <T,>(userId: string, fn: () => Promise<T>) => {
    await setup.query(`set role authenticated`);
    await setup.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId]);
    try {
      return await fn();
    } finally {
      await setup.query(`reset role`);
      await setup.query(`select set_config('request.jwt.claim.sub', '', false)`);
    }
  },
});

describe("제안 · 복귀 요약 · Clear (실제 Postgres)", () => {
  reviewSummaryTests(db);
});

// 업그레이드 · 되돌리기 회귀: 마이그레이션 중간까지만 적용한 새 데이터베이스 (실제 Postgres)
reviewSummaryUpgradeTests(async () => {
  const name = `taskforce_review_upgrade_${SUFFIX}_${extraDatabases.length}`;
  extraDatabases.push(name);
  await admin.query(`create database ${name}`);
  const client = await connect(urlFor(name));
  extraClients.push(client);
  return { exec: (sql) => client.query(sql), query: async (sql, params) => (await client.query(sql, params)).rows };
});

// ───────────────────────── 경합 (연결 둘 이상) ─────────────────────────
const TYPES = [...CHANGE_EVENT_TYPES];
type Row = Record<string, unknown>;
type Scan = {
  since: string | null;
  horizon: string;
  digest: string;
  truncated: boolean;
  page: string[] | null;
  baseline: boolean;
  baseline_state: "cleared" | "initialized" | "never_cleared";
  init_digest: string | null;
  works: { action_id: string; changes: { source: string; kind: string }[] }[];
};

const scanOn = async (client: pg.Client, user: string, limit = 300): Promise<Scan> =>
  (await client.query(`select public.return_summary_scan($1, $2::text[], null, $3) as r`, [user, TYPES, limit])).rows[0].r as Scan;
const clearOn = async (client: pg.Client, user: string, cursor: { horizon: string; digest: string; page?: string[] | null; baseline?: boolean }): Promise<{ status: string; applied?: boolean }> =>
  (await client.query(`select public.return_summary_clear($1, $2::text[], $3::timestamptz, $4, null, $5::uuid[], $6) as r`, [user, TYPES, cursor.horizon, cursor.digest, cursor.page ?? null, cursor.baseline ?? false])).rows[0].r;
const kinds = (scan: Scan) => scan.works.flatMap((w) => w.changes.map((c) => `${c.source}:${c.kind}`)).sort();
const readsOf = async (user: string) => Number((await setup.query(`select count(*)::int as n from public.return_summary_reads where user_id = $1`, [user])).rows[0].n);

async function fresh() {
  const f = reviewFixtures(db);
  const user = await f.user();
  const action = await f.action(user, { title: "제안서" });
  // 이미 commit된 AI 변화 하나 (이번 조회가 본다)
  await setup.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'due_changed', 'ai')`, [user, action]);
  return { f, user, action };
}

describe("P2-A: Clear 뒤에 commit되는 사건은 시각이 이르더라도 숨지 않는다 (실제 Postgres, writer 연결 따로)", () => {
  it("대조: writer가 조회 전에 BEGIN(트랜잭션 시작 시각이 지평 이전), 조회 뒤 Clear 전에 commit → Clear는 stale이고 아무것도 읽음 처리하지 않는다. 다시 조회해 Clear하면 둘 다 읽음", async () => {
    const { user, action } = await fresh();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user);
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, action]);
    await writer.query("commit");
    expect(await clearOn(a, user, seen)).toEqual({ status: "stale" });
    expect(await readsOf(user)).toBe(0);
    const again = await scanOn(a, user);
    expect(kinds(again)).toEqual(["action_event:due_changed", "action_event:merged"]);
    expect((await clearOn(a, user, again)).status).toBe("cleared");
    expect(kinds(await scanOn(a, user))).toEqual([]);
  });

  it("경합 1: writer가 미커밋 INSERT를 쥔 채 조회 → Clear → writer COMMIT: 그 행은 다음 조회에 보인다 (조회가 보지 못했으므로 읽음이 아니다). 이미 본 행은 읽음", async () => {
    const { user, action } = await fresh();
    await writer.query("begin");
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, action]);
    const seen = await scanOn(a, user);
    expect(kinds(seen)).toEqual(["action_event:due_changed"]); // 미커밋 행은 보이지 않는다
    expect(await clearOn(a, user, seen)).toMatchObject({ status: "cleared", applied: true });
    await writer.query("commit");
    expect(Number((await setup.query(`select count(*)::int as n from public.action_events where user_id = $1`, [user])).rows[0].n)).toBe(2);
    const after = await scanOn(a, user);
    expect(kinds(after)).toEqual(["action_event:merged"]);
    // 이제 조회했으니 Clear할 수 있다: 영구히 잠기지 않는다
    expect((await clearOn(a, user, after)).status).toBe("cleared");
    expect(kinds(await scanOn(a, user))).toEqual([]);
    expect(await readsOf(user)).toBe(2);
  });

  it("경합 2: writer BEGIN이 먼저, 조회 → Clear, 그다음에야 INSERT + COMMIT: 행의 created_at이 지평 이전이어도 다음 조회에 보인다", async () => {
    const { user, action } = await fresh();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user);
    expect(await clearOn(a, user, seen)).toMatchObject({ status: "cleared", applied: true });
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, action]);
    await writer.query("commit");
    const stored = (await setup.query(`select (created_at < $2::timestamptz) as before_horizon from public.action_events where user_id = $1 and type = 'merged'`, [user, seen.horizon])).rows[0];
    expect(stored.before_horizon).toBe(true); // 재현의 전제: 늦게 commit된 행의 시각이 지평보다 이르다
    const after = await scanOn(a, user);
    expect(kinds(after)).toEqual(["action_event:merged"]);
    expect((await clearOn(a, user, after)).status).toBe("cleared");
    expect(kinds(await scanOn(a, user))).toEqual([]);
  });

  it("run 결과도 같다: 미커밋 run 전이(done)를 쥔 채 조회 → Clear → COMMIT하면 다음 조회에 run:done이 보인다", async () => {
    const { f, user, action } = await fresh();
    const run = await f.run(user, action);
    // 한 번 Clear해 읽음 기준을 만든다 (run 이력은 Clear한 적이 있어야 변화로 오른다)
    const first = await scanOn(a, user);
    expect((await clearOn(a, user, first)).status).toBe("cleared");
    await writer.query("begin");
    await writer.query(`update public.execution_runs set state = 'done', outcome = 'draft_ready' where id = $1`, [run]);
    const seen = await scanOn(a, user);
    expect(kinds(seen)).toEqual([]);
    expect((await clearOn(a, user, seen)).status).toBe("cleared");
    await writer.query("commit");
    expect(kinds(await scanOn(a, user))).toEqual(["run:done"]);
  });

  it("대화 메시지도 같다: 미커밋 assistant 메시지를 쥔 채 조회 → Clear → COMMIT하면 다음 조회에 message가 보인다", async () => {
    const { f, user, action } = await fresh();
    const conversation = await f.conversation(user, null);
    const first = await scanOn(a, user);
    expect((await clearOn(a, user, first)).status).toBe("cleared");
    await writer.query("begin");
    await writer.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs) values ($1, $2, 1, 'assistant', '답', $3)`, [user, conversation, JSON.stringify({ action_ids: [action] })]);
    const seen = await scanOn(a, user);
    expect((await clearOn(a, user, seen)).status).toBe("cleared");
    await writer.query("commit");
    expect(kinds(await scanOn(a, user))).toEqual(["message:assistant"]);
  });

  it("조회 뒤 Clear 전에 commit된 새 행(지평 뒤 시각)은 stale 없이 남는다: 지평 뒤 시각은 집합에 없다", async () => {
    const { user, action } = await fresh();
    const seen = await scanOn(a, user);
    await new Promise((resolve) => setTimeout(resolve, 5));
    await setup.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, action]);
    expect((await clearOn(a, user, seen)).status).toBe("cleared");
    expect(kinds(await scanOn(a, user))).toEqual(["action_event:merged"]);
  });
});

describe("P2-C: 잘린 조회의 Clear도 보인 작업의 사건만 읽음 처리하고, 늦게 commit되는 사건은 숨지 않는다 (실제 Postgres, writer 연결 따로)", () => {
  /** 작업 3개, 변화가 하나씩 (이미 commit). 작업 순서: 일 3(가장 최근) → 일 2 → 일 1. limit 2면 보이는 작업 = 일 3 · 일 2 */
  async function three() {
    const f = reviewFixtures(db);
    const user = await f.user();
    const actions: string[] = [];
    for (let i = 1; i <= 3; i++) {
      const action = await f.action(user, { title: `일 ${i}` });
      actions.push(action);
      await setup.query(`insert into public.action_events (user_id, action_id, type, actor, created_at) values ($1, $2, 'due_changed', 'ai', now() - make_interval(secs => $3))`, [user, action, 10 - i]);
    }
    return { user, actions };
  }

  it("경합: 보인 작업(일 3)에 미커밋 INSERT를 쥔 채 조회(limit 2) → Clear → COMMIT: 늦은 사건이 다음 조회에 보이고, 보이지 않은 작업(일 1)도 나온다", async () => {
    const { user, actions } = await three();
    await writer.query("begin");
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, actions[2]]);
    const seen = await scanOn(a, user, 2);
    expect(seen.truncated).toBe(true);
    expect(seen.page).toEqual([actions[2], actions[1]]);
    expect(await clearOn(a, user, seen)).toMatchObject({ status: "cleared", applied: true });
    expect(await readsOf(user)).toBe(2); // 보인 작업의 사건 둘뿐 (일 1은 읽음이 아니다)
    await writer.query("commit");
    const after = await scanOn(a, user, 2);
    expect(after.works.map((w) => [w.action_id, w.changes.map((c) => c.kind)])).toEqual([
      [actions[2], ["merged"]],
      [actions[0], ["due_changed"]],
    ]);
    expect(after.truncated).toBe(false);
    expect((await clearOn(a, user, after)).status).toBe("cleared");
    expect(kinds(await scanOn(a, user, 2))).toEqual([]);
  });

  it("경합: BEGIN이 먼저인 writer가 Clear 뒤에 보인 작업에 INSERT + COMMIT해도 다음 조회에 보인다", async () => {
    const { user, actions } = await three();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user, 2);
    expect(await clearOn(a, user, seen)).toMatchObject({ status: "cleared", applied: true });
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, actions[1]]);
    await writer.query("commit");
    const after = await scanOn(a, user, 2);
    expect(after.works.find((w) => w.action_id === actions[1])!.changes.map((c) => c.kind)).toEqual(["merged"]);
  });

  it("대조: 조회 뒤 Clear 전에 보인 작업에 commit되면 stale (아무것도 읽음 처리하지 않는다). 다시 조회해 Clear하면 읽음", async () => {
    const { user, actions } = await three();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user, 2);
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, actions[2]]);
    await writer.query("commit");
    expect(await clearOn(a, user, seen)).toEqual({ status: "stale" });
    expect(await readsOf(user)).toBe(0);
    const again = await scanOn(a, user, 2);
    expect(again.works.find((w) => w.action_id === actions[2])!.changes.map((c) => c.kind)).toEqual(["due_changed", "merged"]);
    expect((await clearOn(a, user, again)).status).toBe("cleared");
  });

  it("보이지 않은 작업(일 1)에 조회 뒤 Clear 전에 commit된 사건은 stale을 만들지 않고, 읽음도 되지 않아 다음 조회에 나온다", async () => {
    const { user, actions } = await three();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user, 2);
    expect(seen.page).toEqual([actions[2], actions[1]]);
    await writer.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'scope_changed', 'ai')`, [user, actions[0]]);
    await writer.query("commit");
    expect(await clearOn(a, user, seen)).toMatchObject({ status: "cleared", applied: true });
    const after = await scanOn(a, user, 2);
    expect(after.works.map((w) => [w.action_id, w.changes.map((c) => c.kind)])).toEqual([[actions[0], ["due_changed", "scope_changed"]]]);
  });

  it("두 연결이 같은 잘린 커서를 동시에 Clear: 둘 다 cleared이고 쓰기는 한 번이다", async () => {
    const { user } = await three();
    const cursor = await scanOn(a, user, 2);
    const results = await Promise.all([clearOn(a, user, cursor), clearOn(b, user, cursor)]);
    expect(results.map((r) => r.status)).toEqual(["cleared", "cleared"]);
    expect(results.filter((r) => r.applied).length).toBe(1);
    expect(await readsOf(user)).toBe(2);
  });
});

describe("두 기기 · 동시 Clear · 동시 제안 (실제 Postgres 연결 둘)", () => {
  it("같은 커서를 두 연결이 동시에 Clear: 둘 다 cleared이고 쓰기는 한 번이다 (applied true는 하나)", async () => {
    const { user } = await fresh();
    const cursor = await scanOn(a, user);
    const results = await Promise.all([clearOn(a, user, cursor), clearOn(b, user, cursor)]);
    expect(results.map((r) => r.status)).toEqual(["cleared", "cleared"]);
    expect(results.filter((r) => r.applied).length).toBe(1);
    expect(await readsOf(user)).toBe(1);
    expect(Number((await setup.query(`select version from public.return_summary_state where user_id = $1`, [user])).rows[0].version)).toBe(1);
  });

  it("서로 다른 시점의 커서를 두 연결이 동시에 Clear: 교착 없이 둘 다 끝나고 읽음은 본 것의 합이다. 그 뒤 사건은 남는다", async () => {
    const { user, action } = await fresh();
    const early = await scanOn(a, user);
    await setup.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, action]);
    const late = await scanOn(b, user);
    await setup.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'completed', 'ai')`, [user, action]);
    const results = await Promise.all([clearOn(a, user, early), clearOn(b, user, late)]);
    expect(results.map((r) => r.status)).toEqual(["cleared", "cleared"]);
    expect(await readsOf(user)).toBe(2);
    expect(kinds(await scanOn(a, user))).toEqual(["action_event:completed"]);
  });

  it("같은 날 비긴급 묶음을 두 연결이 동시에 노출: 묶음은 하나(3개)이고 두 응답이 같다", async () => {
    const f = reviewFixtures(db);
    const user = await f.user();
    const action = await f.action(user);
    for (let i = 0; i < 5; i++) await f.suggestion(user, action, { createdAt: new Date(Date.UTC(2026, 9, 12, 0, 0, i)).toISOString() });
    const call = (client: pg.Client) => client.query(`select id, batch_day::text as batch_day from public.suggestions_expose($1, '2026-10-12', 3, null)`, [user]);
    const [one, two] = await Promise.all([call(a), call(b)]);
    expect(one.rows).toHaveLength(3);
    expect(two.rows.map((r: Row) => r.id)).toEqual(one.rows.map((r: Row) => r.id));
    expect(Number((await setup.query(`select count(*)::int as n from public.suggestions where user_id = $1 and batch_day is not null`, [user])).rows[0].n)).toBe(3);
  });

  it("같은 계기를 두 worker가 동시에 생산: 제안은 하나다 (A08 두 worker)", async () => {
    const f = reviewFixtures(db);
    const user = await f.user();
    await f.action(user, { dueAt: new Date(Date.now() + 3_600_000).toISOString() });
    const call = (client: pg.Client) => client.query(`select public.suggestions_produce($1, now(), 24, false) as n`, [user]);
    const results = await Promise.all([call(a), call(b)]);
    expect(results.map((r) => Number(r.rows[0].n)).sort()).toEqual([0, 1]);
    expect(Number((await setup.query(`select count(*)::int as n from public.suggestions where user_id = $1`, [user])).rows[0].n)).toBe(1);
  });

  it("같은 version으로 두 기기가 동시에 처리: 하나만 ok이고 하나는 conflict (먼저 처리한 쪽이 이긴다)", async () => {
    const f = reviewFixtures(db);
    const user = await f.user();
    const suggestion = await f.suggestion(user, await f.action(user));
    const snooze = (client: pg.Client) => client.query(`select public.suggestion_transition($1, $2, 1, 'snooze', now() + interval '1 day', null, null) as r`, [user, suggestion]);
    const dismiss = (client: pg.Client) => client.query(`select public.suggestion_transition($1, $2, 1, 'dismiss', null, 'topic', null) as r`, [user, suggestion]);
    const results = (await Promise.all([snooze(a), dismiss(b)])).map((r) => (r.rows[0].r as { status: string }).status).sort();
    expect(results).toEqual(["conflict", "ok"]);
    expect(Number((await setup.query(`select version from public.suggestions where id = $1`, [suggestion])).rows[0].version)).toBe(2);
  });

  it("제안 생산과 topic 거절이 동시에 와도 거절 뒤에 같은 주제의 새 계기가 만들어지지 않는다 (같은 사용자 advisory lock)", async () => {
    const f = reviewFixtures(db);
    const user = await f.user();
    const action = await f.action(user, { dueAt: new Date(Date.now() + 3_600_000).toISOString() });
    await f.produce(user, new Date().toISOString());
    const suggestion = (await setup.query(`select id from public.suggestions where user_id = $1`, [user])).rows[0].id as string;
    await setup.query(`update public.actions set due_at = due_at + interval '1 hour' where id = $1`, [action]); // 새 계기
    const dismiss = a.query(`select public.suggestion_transition($1, $2, 1, 'dismiss', null, 'topic', null) as r`, [user, suggestion]);
    const produce = b.query(`select public.suggestions_produce($1, now(), 24, false) as n`, [user]);
    await Promise.all([dismiss, produce]);
    // 어느 순서든 일관: 거절이 먼저면 새 계기는 만들지 않고, 생산이 먼저면 새 계기 하나가 이미 있는 채로 거절이 끝난다. 둘이 엇갈려 "거절 뒤 새 제안"이 되지는 않는다
    const rows = (await setup.query(`select state, dismiss_scope from public.suggestions where user_id = $1 order by created_at, id`, [user])).rows;
    expect(rows[0]).toEqual({ state: "dismissed", dismiss_scope: "topic" });
    expect(rows.length === 1 || (rows.length === 2 && rows[1].state === "open")).toBe(true);
    // 거절이 끝난 뒤의 생산은 같은 주제의 계기를 더 만들지 않는다
    await setup.query(`update public.actions set due_at = due_at + interval '1 hour' where id = $1`, [action]);
    const before = rows.length;
    await setup.query(`select public.suggestions_produce($1, now(), 24, false)`, [user]);
    expect(Number((await setup.query(`select count(*)::int as n from public.suggestions where user_id = $1`, [user])).rows[0].n)).toBe(before);
  });

  it("TEST_CLOCK 판 db_now()는 시험 연결에만 영향을 준다 (다른 연결은 now())", async () => {
    await setup.query(TEST_CLOCK);
    await setup.query(`select set_config('app.now', '2020-01-01T00:00:00Z', false)`);
    expect((await a.query(`select extract(year from public.db_now())::int as y`)).rows[0].y).toBeGreaterThanOrEqual(2026);
    await setup.query(`select set_config('app.now', '', false)`);
  });
});

// ───────────────────────── 첫 정상 표시 기준점 경합 (연결 여럿) ─────────────────────────
const initOn = async (client: pg.Client, user: string, token: { horizon: string; init_digest: string | null }): Promise<{ status: string }> =>
  (await client.query(`select public.return_summary_baseline_init($1, $2::text[], $3::timestamptz, $4, null) as r`, [user, TYPES, token.horizon, token.init_digest])).rows[0].r;
const baselineRowsOf = async (user: string) => Number((await setup.query(`select count(*)::int as n from public.return_summary_baseline where user_id = $1`, [user])).rows[0].n);
const insertMessage = (client: pg.Client, user: string, conversation: string, seq: number, action: string) =>
  client.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs) values ($1, $2, $3, 'assistant', '답', $4)`, [user, conversation, seq, JSON.stringify({ action_ids: [action] })]);

describe("첫 정상 표시 기준점: 조회 · 확정 · 늦은 commit · 두 기기 (실제 Postgres, writer 연결 따로)", () => {
  /** 첫 사용: 이미 commit된 run 결과(done) 하나 + 읽은 시각 없는 대화 메시지 하나(같은 작업). Clear한 적도 기준점도 없다 (쌍 2개) */
  async function firstUse() {
    await setup.query(`select set_config('app.now', '', false)`);
    const f = reviewFixtures(db);
    const user = await f.user();
    const action = await f.action(user, { title: "제안서" });
    const run = await f.run(user, action);
    await f.setRun(run, "running");
    await f.setRun(run, "done", "draft_ready");
    const conversation = await f.conversation(user, null);
    await setup.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs) values ($1, $2, 1, 'assistant', '답', $3)`, [user, conversation, JSON.stringify({ action_ids: [action] })]);
    return { f, user, action, conversation };
  }

  it("대조(기본): 조회 → 확정은 initialized이고 옛 run · 메시지 쌍 둘만 읽음이다. 읽는 동안 아무것도 쓰지 않는다", async () => {
    const { user } = await firstUse();
    const seen = await scanOn(a, user);
    expect(seen).toMatchObject({ baseline_state: "never_cleared", works: [] });
    expect(await readsOf(user)).toBe(0);
    expect(await baselineRowsOf(user)).toBe(0);
    expect(await initOn(b, user, seen)).toEqual({ status: "initialized" });
    expect(await readsOf(user)).toBe(2);
    expect(await baselineRowsOf(user)).toBe(1);
    expect(await initOn(b, user, seen)).toEqual({ status: "already_initialized" });
    expect(await readsOf(user)).toBe(2);
  });

  it("경합 1: writer가 조회 전에 BEGIN, 조회 뒤 확정 전에 범위 안 메시지를 commit → 확정은 stale이고 아무것도 쓰지 않는다. 다시 조회한 새 토큰으로 확정하면 그 메시지도 읽음이다", async () => {
    const { user, action, conversation } = await firstUse();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user);
    await insertMessage(writer, user, conversation, 2, action);
    await writer.query("commit");
    const stored = (await setup.query(`select (created_at < $2::timestamptz) as before_horizon from public.conversation_messages where user_id = $1 and seq = 2`, [user, seen.horizon])).rows[0];
    expect(stored.before_horizon).toBe(true); // 재현의 전제: 늦게 commit된 행의 시각이 지평보다 이르다
    expect(await initOn(b, user, seen)).toEqual({ status: "stale" });
    expect(await readsOf(user)).toBe(0);
    expect(await baselineRowsOf(user)).toBe(0);
    const again = await scanOn(a, user);
    expect(again.init_digest).not.toBe(seen.init_digest);
    expect(await initOn(a, user, again)).toEqual({ status: "initialized" });
    expect(await readsOf(user)).toBe(3);
    expect(kinds(await scanOn(a, user))).toEqual([]);
  });

  it("경합 2: writer가 미커밋 메시지를 쥔 채 조회 → 확정 → writer COMMIT: 그 메시지는 확정 때 보이지 않았으므로 읽음이 아니고 기준점 뒤 새 변화로 보인다", async () => {
    const { user, action, conversation } = await firstUse();
    await writer.query("begin");
    await insertMessage(writer, user, conversation, 2, action);
    const seen = await scanOn(a, user);
    expect(await initOn(a, user, seen)).toEqual({ status: "initialized" });
    await writer.query("commit");
    expect(await readsOf(user)).toBe(2);
    const after = await scanOn(a, user);
    expect(after.baseline_state).toBe("initialized");
    expect(kinds(after)).toEqual(["message:assistant"]);
    // 이제 Clear는 평소처럼 된다 (기준점은 이력을 다시 다루지 않는다)
    expect((await clearOn(a, user, after)).status).toBe("cleared");
    expect(kinds(await scanOn(a, user))).toEqual([]);
  });

  it("경합 3: run 결과도 같다 — writer가 미커밋 run 전이(done)를 쥔 채 조회 → 확정 → COMMIT하면 다음 조회에 run:done이 보인다", async () => {
    const { f, user, action } = await firstUse();
    const second = await f.run(user, action);
    await writer.query("begin");
    await writer.query(`update public.execution_runs set state = 'running' where id = $1`, [second]);
    await writer.query(`update public.execution_runs set state = 'done', outcome = 'needs_input' where id = $1`, [second]);
    const seen = await scanOn(a, user);
    expect(await initOn(a, user, seen)).toEqual({ status: "initialized" });
    await writer.query("commit");
    expect(kinds(await scanOn(a, user))).toEqual(["run:done"]);
  });

  it("경합 4: BEGIN이 먼저인 writer가 확정 뒤에 INSERT + COMMIT해도(created_at이 지평 이전) 다음 조회에 보인다", async () => {
    const { user, action, conversation } = await firstUse();
    await writer.query("begin");
    await writer.query("select 1");
    const seen = await scanOn(a, user);
    expect(await initOn(a, user, seen)).toEqual({ status: "initialized" });
    await insertMessage(writer, user, conversation, 2, action);
    await writer.query("commit");
    expect(kinds(await scanOn(a, user))).toEqual(["message:assistant"]);
  });

  it("두 기기가 같은 토큰으로 동시에 확정: 하나만 initialized이고 하나는 already_initialized다. 읽음 쌍은 한 번, 기준점 행은 하나", async () => {
    const { user } = await firstUse();
    const seen = await scanOn(a, user);
    const results = await Promise.all([initOn(a, user, seen), initOn(b, user, seen)]);
    expect(results.map((r) => r.status).sort()).toEqual(["already_initialized", "initialized"]);
    expect(await readsOf(user)).toBe(2);
    expect(await baselineRowsOf(user)).toBe(1);
  });

  it("서로 다른 시점의 토큰을 두 기기가 동시에 확정: 교착 없이 정확히 하나가 initialized이고 다른 하나는 stale 또는 already_initialized (순서에 따라). 기준점은 하나", async () => {
    const { user, action, conversation } = await firstUse();
    const early = await scanOn(a, user);
    await setup.query(`select pg_sleep(0.01)`);
    await setup.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, created_at) values ($1, $2, 2, 'assistant', '답', $3, $4::timestamptz - interval '1 millisecond')`, [user, conversation, JSON.stringify({ action_ids: [action] }), early.horizon]);
    const late = await scanOn(b, user);
    const results = await Promise.all([initOn(a, user, early), initOn(b, user, late)]);
    const statuses = results.map((r) => r.status);
    expect(statuses.filter((status) => status === "initialized")).toHaveLength(1);
    expect(statuses.filter((status) => status === "stale" || status === "already_initialized")).toHaveLength(1);
    expect(await baselineRowsOf(user)).toBe(1);
    // 어느 순서든 일관: 모든 읽음 쌍은 실제 있었던 (사건, 작업)이고 다음 조회는 기준점 상태다
    expect((await scanOn(a, user)).baseline_state).toBe("initialized");
  });

  it("확정과 Clear가 동시에 오면(같은 사용자 advisory lock) 어느 순서든 일관: 사용자는 cleared가 되고 옛 이력이 변화로 되살아나지 않는다. Clear가 먼저면 확정은 already_initialized(기준점 행 없음), 확정이 먼저면 둘 다 성공(Clear가 우선)", async () => {
    const { user } = await firstUse();
    const seen = await scanOn(a, user);
    const [initResult, clearResult] = await Promise.all([initOn(a, user, seen), clearOn(b, user, seen)]);
    const outcome = `${initResult.status}/${clearResult.status}`;
    expect(["initialized/cleared", "already_initialized/cleared"], outcome).toContain(outcome);
    expect(await baselineRowsOf(user)).toBe(initResult.status === "initialized" ? 1 : 0);
    expect(await readsOf(user)).toBe(2); // 어느 순서든 옛 run · 메시지 쌍이 읽음이다 (한 번씩)
    const after = await scanOn(a, user);
    expect(after.baseline_state).toBe("cleared");
    expect(after.init_digest).toBeNull();
    expect(kinds(after)).toEqual([]); // 옛 이력이 변화로 되살아나지 않는다
  });

  it("Clear한 사용자는 확정이 already_initialized이고 아무것도 쓰지 않는다 (업그레이드 이전 Clear 사용자)", async () => {
    const { user } = await firstUse();
    const seen = await scanOn(a, user);
    expect((await clearOn(a, user, seen)).status).toBe("cleared");
    const reads = await readsOf(user);
    expect(await initOn(b, user, seen)).toEqual({ status: "already_initialized" });
    expect(await readsOf(user)).toBe(reads);
    expect(await baselineRowsOf(user)).toBe(0);
  });

  it("빈 첫 화면: 토큰이 있고 확정되면 읽음 쌍 없이 기준점만 생긴다. 그 뒤 새 메시지는 Clear 없이 보인다", async () => {
    await setup.query(`select set_config('app.now', '', false)`);
    const f = reviewFixtures(db);
    const user = await f.user();
    const action = await f.action(user);
    const seen = await scanOn(a, user);
    expect(seen).toMatchObject({ baseline_state: "never_cleared", works: [] });
    expect(typeof seen.init_digest).toBe("string");
    expect(await initOn(b, user, seen)).toEqual({ status: "initialized" });
    expect(await readsOf(user)).toBe(0);
    const conversation = await f.conversation(user, null);
    await insertMessage(setup, user, conversation, 1, action);
    expect(kinds(await scanOn(a, user))).toEqual(["message:assistant"]);
  });

  it("꾸민 토큰: 미래 지평은 invalid, 남의 토큰 · 꾸민 digest는 stale — 어느 쪽도 아무것도 쓰지 않는다", async () => {
    const { user } = await firstUse();
    const other = await firstUse();
    const seen = await scanOn(a, user);
    const future = new Date(Date.now() + 3_600_000).toISOString();
    expect(await initOn(a, user, { horizon: future, init_digest: seen.init_digest })).toEqual({ status: "invalid" });
    expect(await initOn(a, user, { horizon: seen.horizon, init_digest: "a:0:0|r:9:9|m:9:9" })).toEqual({ status: "stale" });
    expect(await initOn(a, other.user, seen)).toEqual({ status: "stale" });
    expect(await readsOf(user)).toBe(0);
    expect(await readsOf(other.user)).toBe(0);
    expect(await baselineRowsOf(user)).toBe(0);
    expect(await baselineRowsOf(other.user)).toBe(0);
  });
});
