import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { contextLayerFixtures, contextLayerTests, vector } from "../db/context-layer.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 맥락층 (20261104000000_context_layer) — 실제 Postgres. PGlite와 같은 시나리오 + 연결 둘 이상이 겹치는 경합:
// 원문 글 지우기와 조각 · 기억 쓰기(가드의 for share), 범위 version 동시 증가(행 잠금), 같은 사실 · 같은 계정 · 같은 문서의 동시 쓰기(advisory 잠금).
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_context_${process.pid}_${Date.now()}`;

let admin: pg.Client; // DATABASE_URL의 데이터베이스: 일회용 데이터베이스를 만들고 지운다
let setup: pg.Client; // 일회용 데이터베이스: 준비와 commit된 상태 확인
let a: pg.Client;
let b: pg.Client;
let aPid: number;
let bPid: number;
const burst: pg.Client[] = [];

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

const pidOf = async (client: pg.Client) => (await client.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
  [aPid, bPid] = [await pidOf(a), await pidOf(b)];
  for (let i = 0; i < 6; i++) burst.push(await connect(urlFor(DB_NAME)));
});

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end(), ...burst.map((c) => c.end())]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

afterEach(async () => {
  // 테스트가 중간에 실패해도 열린 트랜잭션 · 기다리는 쿼리를 남기지 않는다
  await a.query("rollback").catch(() => {});
  await b.query("rollback").catch(() => {});
});

const db = () => ({
  query: async (sql: string, params?: unknown[]) => (await setup.query(sql, params)).rows,
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

describe("맥락층 (실제 Postgres)", () => {
  contextLayerTests(db);
});

/** 그 연결이 잠금을 기다리는 중인지 (pg_stat_activity). 5초 안에 기다리지 않으면 실패 */
async function waitForLockWait(pid: number) {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [pid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`연결 ${pid}가 잠금을 기다리지 않는다`);
}

describe("맥락층 경합 (실제 Postgres, 연결 둘 이상)", () => {
  const f = contextLayerFixtures(db);

  /** 보관 기간이 지난 원문 하나 (purge_expired_source_text가 고를 수 있게 created_at을 앞당긴다) */
  async function expiringSource(userId: string, externalId = "page-1") {
    const notion = await f.connection(userId, "notion");
    const source = await f.source(userId, { connectionId: notion, externalId, version: "v1" });
    await setup.query(`update public.sources set created_at = now() - interval '100 days' where id = $1`, [source]);
    return source;
  }
  const purge = (client: pg.Client) => client.query(`select * from public.purge_expired_source_text(now() - interval '90 days')`);
  const leftovers = async (sourceId: string) =>
    Number((await setup.query(`select count(*)::int as n from public.source_chunks where source_id = $1`, [sourceId])).rows[0].n);

  it("조각을 넣는 트랜잭션이 먼저면 지우기는 그 commit을 기다렸다가 넣은 조각까지 지운다", async () => {
    const me = await f.user();
    const source = await expiringSource(me);
    await a.query("begin");
    await a.query(`insert into public.source_chunks (user_id, source_id, source_revision, seq, text, embedding) values ($1, $2, 'v1', 0, '경합 조각', $3)`, [
      me,
      source,
      vector(0),
    ]);
    const purging = purge(b);
    await waitForLockWait(bPid);
    await a.query("commit");
    await purging;
    expect(await leftovers(source)).toBe(0);
    expect((await setup.query(`select raw_text_purged_at is not null as purged from public.sources where id = $1`, [source])).rows[0].purged).toBe(true);
  });

  it("지우기가 먼저 잠그면 조각 넣기는 기다렸다가 지운 값을 읽고 거절된다 (조각 교체 RPC는 purged)", async () => {
    const me = await f.user();
    const source = await expiringSource(me);
    await b.query("begin");
    await purge(b);
    const inserting = a.query(`insert into public.source_chunks (user_id, source_id, seq, text) values ($1, $2, 0, '늦은 조각')`, [me, source]);
    await waitForLockWait(aPid);
    await b.query("commit");
    await expect(inserting).rejects.toThrow(/source text was purged/);
    expect(await leftovers(source)).toBe(0);

    const other = await expiringSource(me, "page-2");
    await b.query("begin");
    await purge(b);
    const replacing = a.query(`select * from public.replace_source_chunks($1, $2, $3, $4)`, [me, other, ["늦은 조각"], [vector(1)]]);
    await waitForLockWait(aPid);
    await b.query("commit");
    expect((await replacing).rows[0]).toEqual({ status: "purged", chunks: 0 });
    expect(await leftovers(other)).toBe(0);
  });

  it("observed 기억 쓰기와 지우기가 겹쳐도 글이 남지 않는다 (어느 쪽이 먼저든)", async () => {
    const me = await f.user();
    const first = await expiringSource(me, "page-m1");
    const item = (sourceId: string) =>
      JSON.stringify({ kind: "fact", scope_kind: "global", subject: `s-${sourceId}`, statement: "자료에서 읽은 사실", origin: "observed", source_ref: { source_id: sourceId, quote: "인용" } });
    // 쓰기가 먼저: 지우기가 기다렸다가 비운다
    await a.query("begin");
    const written = (await a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, item(first)])).rows[0];
    const purging = purge(b);
    await waitForLockWait(bPid);
    await a.query("commit");
    await purging;
    expect((await setup.query(`select statement, source_purged, source_ref from public.memory_items where id = $1`, [written.id])).rows[0]).toEqual({
      statement: "",
      source_purged: true,
      source_ref: { source_id: first },
    });
    // 지우기가 먼저: 쓰기가 기다렸다가 거절된다
    const second = await expiringSource(me, "page-m2");
    await b.query("begin");
    await purge(b);
    const writing = a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, item(second)]);
    await waitForLockWait(aPid);
    await b.query("commit");
    await expect(writing).rejects.toThrow(/source text was purged/);
    expect((await setup.query(`select count(*)::int as n from public.memory_items where source_ref ->> 'source_id' = $1`, [second])).rows[0].n).toBe(0);
  });

  it("범위 version은 동시에 올려도 잃지 않는다: 겹친 트랜잭션 둘 + 연결 여섯이 한꺼번에 멤버를 넣으면 정확히 그만큼(트랜잭션마다 1) 오른다", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const sources = await Promise.all(Array.from({ length: 8 }, (_, i) => f.source(me, { text: `원문 ${i}` })));
    const add = (client: pg.Client, sourceId: string) =>
      client.query(`insert into public.context_members (user_id, context_id, member_kind, source_id, origin) values ($1, $2, 'source', $3, 'auto')`, [me, context, sourceId]);

    // 범위 행은 commit 직전에만 잠근다: 겹친 트랜잭션의 멤버 넣기는 서로 기다리지 않고, commit에서 한 줄로 선다
    await a.query("begin");
    await add(a, sources[0]);
    await b.query("begin");
    await add(b, sources[1]);
    expect(await f.version(context)).toBe(1); // 아직 commit 전
    await b.query(`update public.work_contexts set name = name where id = $1`, [context]); // B가 범위 행을 먼저 잠근다
    const committing = a.query("commit");
    await waitForLockWait(aPid); // A의 commit 직전 version 올리기가 B의 잠금을 기다린다
    await b.query("commit");
    await committing;
    expect(await f.version(context)).toBe(3);

    await Promise.all(burst.map((client, i) => add(client, sources[i + 2])));
    expect(await f.version(context)).toBe(9);
    // 범위 기억도 같은 행을 올린다: 동시에 다른 사실 여섯
    await Promise.all(
      burst.map((client, i) =>
        client.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [
          me,
          JSON.stringify({ kind: "fact", scope_kind: "context", context_id: context, subject: `fact ${i}`, statement: `사실 ${i}`, origin: "explicit" }),
        ]),
      ),
    );
    expect(await f.version(context)).toBe(15);
  });

  it("같은 범위 · 같은 사실을 동시에 말하면 한 줄로 서서 지금 행은 하나만 남는다", async () => {
    const me = await f.user();
    const item = (statement: string) => JSON.stringify({ kind: "fact", scope_kind: "global", subject: "deploy day", statement, origin: "explicit" });
    await a.query("begin");
    const first = (await a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, item("금요일")])).rows[0];
    const second = b.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, item("목요일")]);
    await waitForLockWait(bPid);
    await a.query("commit");
    const later = (await second).rows[0];
    expect(later.superseded).toEqual([first.id]);
    const current = await setup.query(`select id from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null`, [me]);
    expect(current.rows.map((r) => r.id)).toEqual([later.id]);

    // 여섯이 한꺼번에 말해도 지금 행은 하나
    await Promise.all(burst.map((client, i) => client.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, item(`요일 ${i}`)])));
    const after = await setup.query(`select count(*)::int as n from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null`, [me]);
    expect(after.rows[0].n).toBe(1);

    // 가리킨 항목의 정정과 같은 사실의 다시 말함이 겹쳐도 교착하지 않는다 (둘 다 같은 사실 잠금 → 행 잠금 순서): 뒤의 정정은 conflict
    const [{ id: target, version }] = (
      await setup.query(`select id, version from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null`, [me])
    ).rows;
    await a.query("begin");
    await a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, item("다시 말함")]);
    const correcting = b.query(`select * from public.remember_memory_item($1, $2::jsonb, $3, $4)`, [me, item("가리켜 정정"), target, version]);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await correcting).rows[0]).toMatchObject({ status: "conflict", id: null });
    const final = await setup.query(`select statement from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null`, [me]);
    expect(final.rows).toEqual([{ statement: "다시 말함" }]);
  });

  it("같은 주소의 다른 계정(gmail · google)을 동시에 봐도 사람은 하나다 (주소 잠금)", async () => {
    for (let round = 0; round < 5; round++) {
      const me = await f.user();
      const email = `peer-${round}@example.com`;
      const providers = ["gmail", "google", "gmail", "google", "gmail", "google"];
      const ids = await Promise.all(
        burst.map((client, i) =>
          client.query(`select public.observe_person_handle($1, $2, $3, '상대', $4, null) as id`, [me, providers[i], `${email}#${i}`, email]).then((r) => r.rows[0].id),
        ),
      );
      expect(new Set(ids).size).toBe(1);
      expect((await setup.query(`select count(*)::int as n from public.people where user_id = $1`, [me])).rows[0].n).toBe(1);
    }
  });

  it("같은 사실의 기억 쓰기와 그 출처 원문의 글 지우기가 겹쳐도 교착하지 않는다 (어느 쪽이 먼저든)", async () => {
    for (const first of ["remember", "purge"] as const) {
      const me = await f.user();
      const source = await expiringSource(me, `page-${first}`);
      const context = await f.context(me);
      await f.member(me, context, source);
      const observed = { kind: "fact", scope_kind: "context", context_id: context, subject: "launch day", origin: "observed", source_ref: { source_id: source, quote: "목요일" } };
      await f.remember(me, { ...observed, statement: "자료: 목요일" });
      await f.remember(me, { ...observed, kind: "goal", subject: "goal", origin: "inferred", confidence: 0.5, statement: "추정" });
      const said = JSON.stringify({ kind: "fact", scope_kind: "context", context_id: context, subject: "launch day", statement: "내가 정함: 금요일", origin: "explicit" });
      const before = await f.version(context);
      const [holder, other] = first === "remember" ? [a, b] : [b, a];
      await holder.query("begin");
      if (first === "remember") await a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, said]);
      else await purge(b);
      const pending = first === "remember" ? purge(b) : a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, said]);
      await waitForLockWait(first === "remember" ? bPid : aPid);
      await holder.query("commit");
      await pending; // 교착이면 여기서 deadlock detected
      void other;
      const current = await setup.query(
        `select statement, origin from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null and statement <> '' order by statement`,
        [me],
      );
      expect(current.rows).toEqual([{ statement: "내가 정함: 금요일", origin: "explicit" }]);
      expect(await f.version(context)).toBe(before + 2); // 트랜잭션 둘이 각각 1
    }
  });

  it("출처 원문을 인용한 기억 쓰기는 원문 → 기억 행 순서로 잠근다: Slack 끊기가 원문을 먼저 잡아도 교착하지 않는다", async () => {
    const me = await f.user();
    const slack = await f.connection(me, "slack", `T-${me}:U1`);
    const s1 = await f.source(me, { connectionId: slack, externalId: "C:1", version: "1" });
    const s2 = await f.source(me, { connectionId: slack, externalId: "C:2", version: "2" });
    const fact = { kind: "fact", scope_kind: "global", subject: "launch day", origin: "observed" };
    const current = await f.remember(me, { ...fact, statement: "자료 1: 목요일", source_ref: { source_id: s1 }, observed_at: "2026-10-01T00:00:00Z" });
    const later = JSON.stringify({ ...fact, statement: "자료 2: 금요일", source_ref: { source_id: s2 }, observed_at: "2026-10-02T00:00:00Z" });

    // 지우기 쪽(B)이 인용 원문 s2를 먼저 잡고 있으면 기억 쓰기(A)는 기억 행을 잡기 전에 기다린다: B가 지금 행을 잠가도 막히지 않는다
    await b.query("begin");
    await b.query(`select 1 from public.sources where id = $1 for update`, [s2]);
    const writing = a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, later]);
    await waitForLockWait(aPid);
    await b.query(`select 1 from public.memory_items where id = $1 for update`, [current.id]); // 옛 순서였다면 여기서 교착
    await b.query("commit");
    expect((await writing).rows[0]).toMatchObject({ status: "written", superseded: [current.id] });

    // 실제 Slack 끊기와 겹쳐도: 쓰기가 먼저 commit되면 끊기가 새 행까지 비운다
    const s3 = await f.source(me, { connectionId: slack, externalId: "C:3", version: "3" });
    await a.query("begin");
    await a.query(`select * from public.remember_memory_item($1, $2::jsonb)`, [
      me,
      JSON.stringify({ ...fact, statement: "자료 3: 토요일", source_ref: { source_id: s3, quote: "토요일" }, observed_at: "2026-10-03T00:00:00Z" }),
    ]);
    const disconnecting = b.query(`select public.disconnect_connection($1, $2) as ok`, [me, slack]);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await disconnecting).rows[0]).toEqual({ ok: true });
    const left = await setup.query(`select count(*)::int as n from public.memory_items where user_id = $1 and (statement <> '' or source_ref ? 'quote')`, [me]);
    expect(left.rows[0].n).toBe(0);
  });

  it("같은 계정을 동시에 보면 사람은 하나만 생긴다", async () => {
    const me = await f.user();
    const slack = await f.connection(me, "slack", "T1:U1");
    const ids = await Promise.all(
      burst.map((client) => client.query(`select public.observe_person_handle($1, 'slack', 'T1:U2', '지훈', null, $2) as id`, [me, slack]).then((r) => r.rows[0].id)),
    );
    expect(new Set(ids).size).toBe(1);
    expect((await setup.query(`select count(*)::int as n from public.people where user_id = $1`, [me])).rows[0].n).toBe(1);
  });

  it("같은 문서의 옛 revision과 새 revision 조각 교체가 겹쳐도 새 revision 조각만 남는다 (어느 쪽이 먼저든)", async () => {
    const me = await f.user();
    const notion = await f.connection(me, "notion");
    const v1 = await f.source(me, { connectionId: notion, externalId: "doc", version: "v1", occurredAt: "2026-10-01T00:00:00Z" });
    const v2 = await f.source(me, { connectionId: notion, externalId: "doc", version: "v2", occurredAt: "2026-10-02T00:00:00Z" });
    const replace = (client: pg.Client, sourceId: string, text: string) =>
      client.query(`select * from public.replace_source_chunks($1, $2, $3, $4)`, [me, sourceId, [text], [vector(0)]]).then((r) => r.rows[0]);
    const texts = async () => (await setup.query(`select c.text from public.source_chunks c join public.sources s on s.id = c.source_id where s.external_id = 'doc' and s.user_id = $1`, [me])).rows.map((r) => r.text);

    // 새 것이 먼저 잡고, 옛 것은 기다렸다가 stale
    await a.query("begin");
    expect(await replace(a, v2, "v2")).toEqual({ status: "replaced", chunks: 1 });
    const old = replace(b, v1, "v1");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await old).toEqual({ status: "stale", chunks: 0 });
    expect(await texts()).toEqual(["v2"]);

    // 옛 것이 먼저 잡혀도 (지운 뒤 다시 넣는 v1 처리), 새 것이 기다렸다가 옛 조각을 지우고 바꾼다
    await setup.query(`delete from public.source_chunks where source_id = any ($1::uuid[])`, [[v1, v2]]);
    await setup.query(`update public.sources set occurred_at = '2026-09-30T00:00:00Z' where id = $1`, [v2]); // 잠깐 v1이 최신
    await a.query("begin");
    expect(await replace(a, v1, "v1")).toEqual({ status: "replaced", chunks: 1 });
    await setup.query(`update public.sources set occurred_at = '2026-10-02T00:00:00Z' where id = $1`, [v2]); // v2가 다시 최신 (A는 아직 commit 전)
    const newer = replace(b, v2, "v2");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await newer).toEqual({ status: "replaced", chunks: 1 });
    expect(await texts()).toEqual(["v2"]);
  });
});

// 계정 삭제는 Supabase Auth가 supabase_auth_admin으로 한다: cascade로 불리는 맥락층 트리거(범위 version · 사람 계산 · 원문 전파)가
// 그 역할의 권한 때문에 실패하지 않아야 한다 (소유자 권한 트리거). PGlite 테스트는 superuser로 지워 이 문제가 드러나지 않는다
describe("계정 삭제 (supabase_auth_admin, 실제 Postgres)", () => {
  it("범위 멤버 · 범위 기억(정정 사슬) · 사람 계정 · 조각이 있는 사용자도 지워지고, 다른 사용자의 행은 그대로다", async () => {
    await setup.query(`
      grant usage on schema auth to supabase_auth_admin;
      grant select, delete on auth.users to supabase_auth_admin;
    `);
    const f = contextLayerFixtures(db);
    const seedUser = async () => {
      const userId = await f.user();
      const slack = await f.connection(userId, "slack", `T-${userId}:U1`);
      const source = await f.source(userId, { connectionId: slack, externalId: "C:1", version: "1" });
      const context = await f.context(userId);
      await f.member(userId, context, source);
      await f.chunks(userId, source, ["조각"]);
      const item = { kind: "fact", scope_kind: "context", context_id: context, subject: "deploy day", origin: "explicit" };
      await f.remember(userId, { ...item, statement: "금요일" });
      await f.remember(userId, { ...item, statement: "목요일" }); // 정정 사슬 (지울 때 포인터 set null)
      await f.remember(userId, { kind: "fact", scope_kind: "context", context_id: context, statement: "관찰", origin: "observed", source_ref: { source_id: source } });
      await setup.query(`select public.observe_person_handle($1, 'slack', 'T:U9', '사람', 'p@example.com', $2)`, [userId, slack]);
      await setup.query(`insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'slack', 'T:U1', $2, 'oauth')`, [userId, slack]);
      return userId;
    };
    const leaving = await seedUser();
    const staying = await seedUser();
    const tables = ["people", "people_handles", "source_chunks", "memory_items", "work_contexts", "context_members", "identity_links", "sources"];
    const count = async (userId: string) =>
      Object.fromEntries(
        await Promise.all(tables.map(async (t) => [t, (await setup.query(`select count(*)::int as n from public.${t} where user_id = $1`, [userId])).rows[0].n])),
      );
    const stayingBefore = await count(staying);

    await setup.query("set role supabase_auth_admin");
    try {
      expect((await setup.query("delete from auth.users where id = $1", [leaving])).rowCount).toBe(1);
    } finally {
      await setup.query("reset role");
    }
    expect(await count(leaving)).toEqual(Object.fromEntries(tables.map((t) => [t, 0])));
    expect(await count(staying)).toEqual(stayingBefore);
  });
});
