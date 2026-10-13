import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { actionNumbersTests, actionNumbersUpgradeTests, type ActionNumbersDb } from "../db/action-numbers.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 OA D4c-3a (20261120000000_action_numbers) — 실제 Postgres. PGlite와 같은 시나리오 + 연결이 둘 이상 필요한 경합 (T7):
//  - 같은 사용자 동시 insert 20개: 번호 중복 0, 1..20 빈틈 0. 카운터 행이 아직 없을 때(첫 insert)와 이미 있을 때 모두.
//  - 그 가운데 롤백된 트랜잭션 1건은 번호를 쓰지 않는다 (카운터 증가가 함께 돌아온다).
//  - 한 트랜잭션에서 여러 행을 넣는 쪽들이 겹쳐도 교착 없이 줄을 선다. 두 사용자의 번호는 서로 닿지 않는다.
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
const DB_NAME = `taskforce_action_numbers_${SUFFIX}`;

let admin: pg.Client;
let setup: pg.Client;
const extraDatabases: string[] = [];
const extraClients: pg.Client[] = [];
let racers: pg.Client[] = [];

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

/** 경합에 쓰는 연결 n개 (시험이 끝나면 닫는다) */
async function openRacers(n: number): Promise<pg.Client[]> {
  const opened = await Promise.all(Array.from({ length: n }, () => connect(urlFor(DB_NAME))));
  racers.push(...opened);
  return opened;
}

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
}, 120_000);

afterEach(async () => {
  await Promise.allSettled(racers.map(async (client) => {
    await client.query("rollback").catch(() => undefined);
    await client.end();
  }));
  racers = [];
});

afterAll(async () => {
  await Promise.allSettled([setup?.end(), ...extraClients.map((client) => client.end())]);
  if (admin) {
    for (const name of [DB_NAME, ...extraDatabases]) await admin.query(`drop database if exists ${name} with (force)`);
    await admin.end();
  }
});

const db = (): ActionNumbersDb => ({
  query: async (sql, params) => (await setup.query(sql, params)).rows,
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

describe("이슈 번호 (실제 Postgres)", () => {
  actionNumbersTests(db);
});

// 업그레이드 시험: 마이그레이션 직전까지만 적용한 새 데이터베이스 (실제 Postgres)
actionNumbersUpgradeTests(async () => {
  const name = `taskforce_action_numbers_upgrade_${SUFFIX}_${extraDatabases.length}`;
  extraDatabases.push(name);
  await admin.query(`create database ${name}`);
  const client = await connect(urlFor(name));
  extraClients.push(client);
  return { exec: (sql) => client.query(sql), query: async (sql, params) => (await client.query(sql, params)).rows };
});

// ───────────────────────── T7 경합 (연결 둘 이상) ─────────────────────────

async function newUser(): Promise<string> {
  const id = randomUUID();
  await setup.query(`insert into auth.users (id, email) values ($1, $2)`, [id, `${id}@example.com`]);
  return id;
}

const range = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => from + i);
const sorted = (values: number[]) => [...values].sort((a, b) => a - b);
const insertSql = `insert into public.actions (user_id, title) values ($1, $2) returning number`;

const numbersOf = async (userId: string) =>
  (await setup.query(`select number from public.actions where user_id = $1 order by number`, [userId])).rows.map((r) => r.number as number);
const counterOf = async (userId: string) => {
  const rows = (await setup.query(`select next from public.action_counters where user_id = $1`, [userId])).rows;
  return rows.length === 0 ? null : (rows[0].next as number);
};

/** 데이터베이스 안에서 잠금을 기다리는 연결 수 (카운터를 쥔 트랜잭션을 기다리는 insert들) */
async function waitForBlocked(n: number) {
  const deadline = Date.now() + 15_000;
  let blocked = 0;
  while (Date.now() < deadline) {
    blocked = Number((await admin.query(`select count(*)::int as n from pg_stat_activity where datname = $1 and wait_event_type = 'Lock'`, [DB_NAME])).rows[0].n);
    if (blocked >= n) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`잠금을 기다리는 연결이 ${n}개가 되지 않았다 (지금 ${blocked}개)`);
}

/**
 * holder가 트랜잭션 안에서 번호(와 카운터 행 잠금)를 쥔 채, count개의 연결이 같은 사용자로 동시에 insert한다.
 * 모두 줄을 선 것을 확인한 뒤 holder를 끝낸다(rollback 또는 commit). 돌려주는 값: holder가 쥐었던 번호, 줄 선 쪽이 받은 번호들
 */
async function race(userId: string, count: number, end: "rollback" | "commit") {
  const [holder, ...workers] = await openRacers(count + 1);
  await holder.query("begin");
  const held = (await holder.query(insertSql, [userId, "holder"])).rows[0].number as number;
  const pending = workers.map((client, i) => client.query(insertSql, [userId, `동시 ${i}`]));
  await waitForBlocked(count);
  await holder.query(end);
  const results = await Promise.all(pending);
  return { held, got: results.map((r) => r.rows[0].number as number) };
}

describe("T7 같은 사용자 동시 insert (실제 Postgres)", () => {
  it("카운터 행도 아직 없는 사용자에게 20개가 동시에: 롤백된 트랜잭션 1건이 번호를 쥐었다 놓아도 번호는 1..20, 중복 0, 빈틈 0", async () => {
    const userId = await newUser();
    expect(await counterOf(userId)).toBeNull();
    const { held, got } = await race(userId, 20, "rollback");
    expect(held).toBe(1); // 롤백된 쪽이 쥐었던 번호 — 다음 사람이 그대로 받는다
    expect(sorted(got)).toEqual(range(1, 20));
    expect(await numbersOf(userId)).toEqual(range(1, 20));
    expect(await counterOf(userId)).toBe(21);
    expect((await setup.query(`select count(*)::int as n from public.actions where user_id = $1 and title = 'holder'`, [userId])).rows[0].n).toBe(0);
  });

  it("카운터 행이 이미 있을 때도 같다: 이어서 20개 + 롤백 1건 → 21..40", async () => {
    const userId = await newUser();
    await setup.query(insertSql, [userId, "먼저"]); // #1, 카운터 행 생성
    const { held, got } = await race(userId, 20, "rollback");
    expect(held).toBe(2);
    expect(sorted(got)).toEqual(range(2, 21));
    expect(await numbersOf(userId)).toEqual(range(1, 21));
    expect(await counterOf(userId)).toBe(22);
    // 한 번 더: 이어서 20개
    const again = await race(userId, 20, "rollback");
    expect(sorted(again.got)).toEqual(range(22, 41));
    expect(await numbersOf(userId)).toEqual(range(1, 41));
  });

  it("holder가 commit하면 holder가 그 번호를 갖고 나머지는 이어서 받는다", async () => {
    const userId = await newUser();
    const { held, got } = await race(userId, 20, "commit");
    expect(held).toBe(1);
    expect(sorted(got)).toEqual(range(2, 21));
    expect(await numbersOf(userId)).toEqual(range(1, 21));
    expect(await counterOf(userId)).toBe(22);
  });

  it("두 사용자가 동시에 만들어도 번호는 사용자별로 따로 1..10이다", async () => {
    const alice = await newUser();
    const bob = await newUser();
    const clients = await openRacers(20);
    await Promise.all(clients.map((client, i) => client.query(insertSql, [i % 2 === 0 ? alice : bob, `동시 ${i}`])));
    expect(await numbersOf(alice)).toEqual(range(1, 10));
    expect(await numbersOf(bob)).toEqual(range(1, 10));
    expect(await counterOf(alice)).toBe(11);
    expect(await counterOf(bob)).toBe(11);
  });

  it("한 트랜잭션에서 여러 행을 넣는 쪽들이 겹쳐도 교착 없이 줄을 서고, 번호는 겹치지 않는다", async () => {
    const userId = await newUser();
    const clients = await openRacers(6);
    await Promise.all(
      clients.map(async (client, i) => {
        await client.query("begin");
        for (let k = 0; k < 3; k++) await client.query(insertSql, [userId, `트랜잭션 ${i}-${k}`]);
        await client.query("commit");
      }),
    );
    expect(await numbersOf(userId)).toEqual(range(1, 18));
    expect(await counterOf(userId)).toBe(19);
    // 한 트랜잭션의 번호는 이어진다 (카운터를 commit까지 쥔다)
    const perTransaction = (await setup.query(`select title, number from public.actions where user_id = $1 order by title, number`, [userId])).rows;
    for (let i = 0; i < 6; i++) {
      const mine = perTransaction.filter((r) => String(r.title).startsWith(`트랜잭션 ${i}-`)).map((r) => r.number as number);
      expect(mine, `트랜잭션 ${i}`).toHaveLength(3);
      expect(mine[2] - mine[0], `트랜잭션 ${i}`).toBe(2);
    }
  });

  it("number를 바꾸려는 update는 동시에 insert가 도는 중에도 거절된다", async () => {
    const userId = await newUser();
    await setup.query(insertSql, [userId, "첫번째"]);
    const [writer, updater] = await openRacers(2);
    await writer.query("begin");
    await writer.query(insertSql, [userId, "쥐고 있음"]); // #2, 카운터 행을 쥔다
    // update는 카운터를 보지 않으므로 기다리지 않고 바로 거절된다
    await expect(updater.query(`update public.actions set number = 99 where user_id = $1 and title = '첫번째'`, [userId])).rejects.toThrow(/actions_number_immutable/);
    await writer.query("commit");
    expect(await numbersOf(userId)).toEqual([1, 2]);
  });
});
