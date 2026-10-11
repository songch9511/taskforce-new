import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { coordinatorCoreTests, coordinatorFixtures, coordinatorUpgradeTests, type CoordinatorDb } from "../db/coordinator-core.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 코디네이터 1 (20261110000000_coordinator_core, 구현 계획 C2) — 실제 Postgres. PGlite와 같은 시나리오 + 연결이 둘 이상 필요한 경합:
// ARCH12 (사건 100건이 두 소비자에게 동시에 집힘: 사건당 처리 1회 · commit unique 위반 0 · 사용자별 순서 보존), 같은 사용자를 동시에 집기,
// 끝내기가 쥔 머리 행을 가로채지 않기, 늦은 소비자 commit 거절, 모델 예약 동시 호출, 같은 키 동시 적재.
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
const DB_NAME = `taskforce_coordinator_${SUFFIX}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let bPid: number;
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
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end(), ...extraClients.map((client) => client.end())]);
  if (admin) {
    for (const name of [DB_NAME, ...extraDatabases]) await admin.query(`drop database if exists ${name} with (force)`);
    await admin.end();
  }
});

afterEach(async () => {
  await a.query("rollback").catch(() => {});
  await b.query("rollback").catch(() => {});
});

// 한 연결(setup)에 쿼리를 차례로 보낸다: 시나리오가 Promise.all로 동시에 읽어도 pg 클라이언트에 겹쳐 보내지 않게
let chain: Promise<unknown> = Promise.resolve();
const serial = <T,>(run: () => Promise<T>): Promise<T> => {
  const next = chain.then(run, run);
  chain = next.catch(() => undefined);
  return next;
};

const db = (): CoordinatorDb => ({
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

describe("코디네이터 사건 큐 (실제 Postgres)", () => {
  coordinatorCoreTests(db);
});

// 업그레이드 회귀: 마이그레이션 중간까지만 적용한 새 데이터베이스 (실제 Postgres)
coordinatorUpgradeTests(async () => {
  const name = `taskforce_coordinator_upgrade_${SUFFIX}_${extraDatabases.length}`;
  extraDatabases.push(name);
  await admin.query(`create database ${name}`);
  const client = await connect(urlFor(name));
  extraClients.push(client);
  return { exec: (sql) => client.query(sql), query: async (sql, params) => (await client.query(sql, params)).rows };
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

type Row = Record<string, unknown>;
const claimOn = async (client: pg.Client, consumer: string, lease = 30, limit = 3, max = 5): Promise<Row[]> =>
  (await client.query(`select * from public.coordinator_claim($1, $2, $3, $4)`, [consumer, lease, limit, max])).rows;
const finishOn = async (client: pg.Client, eventId: string, token: unknown): Promise<string> =>
  (await client.query(`select public.coordinator_finish($1, $2, 'no_impact', '{}', null) as s`, [eventId, token])).rows[0].s;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

describe("ARCH12: 사건 100건 · 두 소비자 동시 집기 (실제 Postgres, 연결 둘)", () => {
  it("각 사건은 한 번만 처리되고(lost_claim 0 · 오류 0), 사용자별 처리 순서는 쌓인 순서이며, 한 사용자를 두 소비자가 동시에 처리하지 않는다", async () => {
    await setup.query(`delete from public.inbox_events`);
    const f = coordinatorFixtures(db);
    const users: string[] = [];
    for (let i = 0; i < 10; i++) users.push(await f.user());
    // 10명 × 10건 = 100건. 일부러 같은 시각(created_at)에 여럿을 쌓아 tie-break(seq)도 함께 시험한다
    const expectedOrder = new Map<string, string[]>();
    for (const user of users) {
      const ids: string[] = [];
      for (let n = 0; n < 10; n++) ids.push(await f.event(user, "user_message", `k${n}`, {}, `2026-10-12T00:00:0${Math.floor(n / 3)}Z`));
      expectedOrder.set(user, ids);
    }
    const processedOrder: string[] = [];
    const busy = new Set<string>();
    const overlaps: string[] = [];
    const statuses: string[] = [];
    const errors: string[] = [];
    const byConsumer: Record<string, number> = {};

    const consumer = async (client: pg.Client, name: string) => {
      for (let idle = 0; idle < 3; ) {
        let rows: Row[];
        try {
          rows = await claimOn(client, name, 30, 3, 5);
        } catch (error) {
          errors.push(String(error));
          break;
        }
        if (rows.length === 0) {
          const { rows: left } = await client.query(`select count(*)::int as n from public.inbox_events where processed_at is null and dead_at is null`);
          if (left[0].n === 0) break;
          idle++;
          await sleep(20);
          continue;
        }
        idle = 0;
        for (const row of rows) {
          const user = row.user_id as string;
          if (busy.has(user)) overlaps.push(user);
          busy.add(user);
          await sleep(3);
          try {
            const status = await finishOn(client, row.event_id as string, row.claim_token);
            statuses.push(status);
            if (status === "finished") {
              processedOrder.push(row.event_id as string);
              byConsumer[name] = (byConsumer[name] ?? 0) + 1;
            }
          } catch (error) {
            errors.push(String(error));
          } finally {
            busy.delete(user);
          }
        }
      }
    };

    await Promise.all([consumer(a, "fn-a"), consumer(b, "fn-b")]);

    expect(errors).toEqual([]);
    // 두 소비자가 실제로 나눠 처리했다 (한쪽이 혼자 다 한 것이 아니다)
    expect(Object.keys(byConsumer).sort()).toEqual(["fn-a", "fn-b"]);
    expect(overlaps).toEqual([]);
    expect(statuses).toHaveLength(100);
    expect(new Set(statuses)).toEqual(new Set(["finished"]));
    expect(new Set(processedOrder).size).toBe(100);
    for (const [user, ids] of expectedOrder) expect(processedOrder.filter((id) => ids.includes(id)), user).toEqual(ids);
    const { rows } = await setup.query(
      `select count(*)::int as processed, count(*) filter (where attempts = 1)::int as once, count(*) filter (where dead_at is not null)::int as dead from public.inbox_events where processed_at is not null`,
    );
    expect(rows[0]).toEqual({ processed: 100, once: 100, dead: 0 });
    expect((await setup.query(`select count(*)::int as n from public.inbox_events where processed_at is null`)).rows[0].n).toBe(0);
  }, 60_000);
});

describe("사용자별 직렬화 (실제 Postgres, 연결 둘)", () => {
  it("같은 사용자를 두 소비자가 같은 순간에 집으면 하나만 얻는다: 앞 트랜잭션이 사용자 잠금을 쥔 동안 뒤는 기다리지 않고 건너뛴다 (그 사용자 0건, 다른 사용자는 진행)", async () => {
    await setup.query(`delete from public.inbox_events`);
    const f = coordinatorFixtures(db);
    const [alice, bob] = [await f.user(), await f.user()];
    const aliceHead = await f.event(alice, "user_message", "a1", {}, "2026-10-12T00:00:00Z");
    await f.event(alice, "user_message", "a2", {}, "2026-10-12T00:00:01Z");
    const bobHead = await f.event(bob, "user_message", "b1", {}, "2026-10-12T00:00:02Z");

    await a.query("begin");
    const first = await claimOn(a, "fn-a", 60, 1);
    expect(first.map((r) => r.event_id)).toEqual([aliceHead]);
    // a가 commit하기 전에 b가 집는다: alice는 a가 잠금 · lease를 쥐었으므로 건너뛰고 bob이 집힌다 (대기 0)
    const second = await claimOn(b, "fn-b", 60, 5);
    expect(second.map((r) => r.event_id)).toEqual([bobHead]);
    await a.query("commit");
    // a의 commit 뒤: alice의 머리는 살아 있는 lease가 있어 b는 여전히 못 집고, 둘째 alice 사건도 집히지 않는다
    expect(await claimOn(b, "fn-b", 60, 5)).toEqual([]);
    expect(await finishOn(a, aliceHead, first[0].claim_token)).toBe("finished");
    expect((await claimOn(b, "fn-b", 60, 5)).map((r) => r.user_id)).toEqual([alice]);
  });

  it("끝내기가 쥔 머리 행을 가로채지 않는다: 머리가 잠겨 있는 동안(finish 트랜잭션 진행 중) 같은 사용자의 뒤 사건을 집지 않는다 (skip locked로 순서가 뒤집히지 않는다)", async () => {
    await setup.query(`delete from public.inbox_events`);
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const head = await f.event(user, "user_message", "h", {}, "2026-10-12T00:00:00Z");
    await f.event(user, "user_message", "t", {}, "2026-10-12T00:00:01Z");
    const [claimed] = await claimOn(a, "fn-a", 60, 1);
    expect(claimed.event_id).toBe(head);
    await f.expire(head);
    // a: lease가 끝난 머리의 finish를 열어 둔다(아직 거절될 사건이지만 행 잠금을 쥔다) — 대신 reserve로 행을 잠근다
    await a.query("begin");
    await a.query(`update public.inbox_events set last_error_kind = 'holding' where id = $1`, [head]);
    const during = await claimOn(b, "fn-b", 60, 5);
    expect(during).toEqual([]); // 머리가 잠겨 있으니 이 사용자는 건너뛴다. 뒤 사건을 집지 않았다
    await a.query("commit");
    const after = await claimOn(b, "fn-b", 60, 5);
    expect(after.map((r) => r.event_id)).toEqual([head]);
  });

  it("늦은(만료된) 소비자의 commit 거절 · 새 소비자의 commit 성공: lease가 끝난 뒤 다시 집힌 사건을 옛 토큰으로 끝내려 하면 lost_claim이고 처리 기록은 하나다", async () => {
    await setup.query(`delete from public.inbox_events`);
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const e = await f.event(user, "user_message", "late");
    const [old] = await claimOn(a, "fn-a", 60, 1);
    await f.expire(e);
    const [fresh] = await claimOn(b, "fn-b", 60, 1);
    expect(fresh.attempts).toBe(2);
    // 옛 소비자(a)가 뒤늦게 commit을 시도: 거절. 새 소비자(b)가 끝낸다
    expect(await finishOn(a, e, old.claim_token)).toBe("lost_claim");
    expect(await finishOn(b, e, fresh.claim_token)).toBe("finished");
    expect(await finishOn(a, e, old.claim_token)).toBe("lost_claim");
    expect((await setup.query(`select count(*)::int as n from public.inbox_events where id = $1 and processed_at is not null`, [e])).rows[0].n).toBe(1);
  });

  it("모델 호출 예약을 같은 순간에 두 번 하면 정확히 한 번만 true다 (두 번째는 첫 트랜잭션의 행 잠금을 기다렸다가 false)", async () => {
    await setup.query(`delete from public.inbox_events`);
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const e = await f.event(user, "source_revised", "m");
    const [row] = await claimOn(a, "fn-a", 60, 1);
    const reserve = (client: pg.Client) => client.query(`select public.coordinator_reserve_model_call($1, $2) as ok`, [e, row.claim_token]);
    await a.query("begin");
    await b.query("begin");
    const first = await reserve(a);
    const second = reserve(b);
    await waitForLockWait(bPid);
    await a.query("commit");
    const lost = await second;
    await b.query("commit");
    expect(first.rows[0].ok).toBe(true);
    expect(lost.rows[0].ok).toBe(false);
    expect((await setup.query(`select model_calls from public.inbox_events where id = $1`, [e])).rows[0].model_calls).toBe(1);
  });

  it("Jev 호출 예약 둘이 같은 순간에 상한을 넘기려 하면 한 쪽만 얻는다 (합이 상한을 넘지 않는다)", async () => {
    await setup.query(`delete from public.inbox_events`);
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const e = await f.event(user, "source_revised", "j");
    const [row] = await claimOn(a, "fn-a", 60, 1);
    const reserve = (client: pg.Client) => client.query(`select public.coordinator_reserve_jev_calls($1, $2, 3, 5) as ok`, [e, row.claim_token]);
    await a.query("begin");
    await b.query("begin");
    const first = await reserve(a);
    const second = reserve(b);
    await waitForLockWait(bPid);
    await a.query("commit");
    const lost = await second;
    await b.query("commit");
    expect([first.rows[0].ok, lost.rows[0].ok]).toEqual([true, false]);
    expect((await setup.query(`select jev_calls from public.inbox_events where id = $1`, [e])).rows[0].jev_calls).toBe(3);
  });

  it("같은 dedup_key를 동시에 적재하면 하나만 생기고 둘 다 오류가 없다 (뒤 쪽은 앞 쪽의 commit을 기다린 뒤 created false)", async () => {
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const key = `race-${randomUUID()}`;
    const enqueue = (client: pg.Client) => client.query(`select * from public.coordinator_enqueue($1, 'user_message', $2, '{}')`, [user, key]);
    await a.query("begin");
    await b.query("begin");
    const first = await enqueue(a);
    const second = enqueue(b);
    await waitForLockWait(bPid);
    await a.query("commit");
    const dup = await second;
    await b.query("commit");
    expect(first.rows[0].created).toBe(true);
    expect(dup.rows[0]).toEqual({ event_id: first.rows[0].event_id, created: false });
    expect((await setup.query(`select count(*)::int as n from public.inbox_events where user_id = $1 and dedup_key = $2`, [user, key])).rows[0].n).toBe(1);
  });

  it("앞 쪽이 rollback하면 기다리던 뒤 쪽이 적재한다 (사건이 둘이 되지도, 둘 다 사라지지도 않는다)", async () => {
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const key = `rollback-${randomUUID()}`;
    const enqueue = (client: pg.Client) => client.query(`select * from public.coordinator_enqueue($1, 'user_message', $2, '{}')`, [user, key]);
    await a.query("begin");
    await b.query("begin");
    await enqueue(a);
    const waiting = enqueue(b);
    await waitForLockWait(bPid);
    await a.query("rollback");
    expect((await waiting).rows[0].created).toBe(true);
    await b.query("commit");
    expect((await setup.query(`select count(*)::int as n from public.inbox_events where user_id = $1 and dedup_key = $2`, [user, key])).rows[0].n).toBe(1);
  });

  it("원문 done 쓰기와 사건 적재는 같은 트랜잭션이다: 쓰기가 rollback되면 사건도 없다, commit되면 둘 다 있다 (틈이 없다)", async () => {
    const f = coordinatorFixtures(db);
    const user = await f.user();
    const source = await f.source(user);
    await a.query("begin");
    await a.query(`update public.sources set processing_status = 'processing' where id = $1`, [source]);
    await a.query(`update public.sources set processing_status = 'done', processed_at = now(), processing_summary = '{"attempt":1}' where id = $1`, [source]);
    // commit 전에는 다른 연결에서 사건이 보이지 않는다
    expect((await setup.query(`select count(*)::int as n from public.inbox_events where user_id = $1`, [user])).rows[0].n).toBe(0);
    await a.query("rollback");
    expect((await setup.query(`select processing_status from public.sources where id = $1`, [source])).rows[0].processing_status).toBe("pending");
    expect((await setup.query(`select count(*)::int as n from public.inbox_events where user_id = $1`, [user])).rows[0].n).toBe(0);
    await a.query("begin");
    await a.query(`update public.sources set processing_status = 'done', processed_at = now(), processing_summary = '{"attempt":1}' where id = $1`, [source]);
    await a.query("commit");
    expect((await setup.query(`select type from public.inbox_events where user_id = $1`, [user])).rows).toEqual([{ type: "source_processed" }]);
  });
});
