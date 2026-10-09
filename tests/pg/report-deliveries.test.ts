import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

// 일일 보고 원장을 실제 Postgres(CI: pgvector/pgvector:pg17)에서: cron이 겹쳐 돌 때 같은 날 보고를 두 번 잡지 않는다
// (설정 행 잠금 + 유일 키), 다시 잡기도 한 실행만, RLS는 본인 행만.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error("DATABASE_URL is required for actual Postgres report delivery tests");

const database = `taskforce_reports_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let clients: pg.Client[] = [];

/** 서울 10-10 08:30 KST 보고 */
const SEOUL = ["Asia/Seoul", "2026-10-10", "2026-10-09T15:00:00Z", "2026-10-09T23:30:00Z", "2026-10-10T01:30:00Z", "2026-10-09T23:30:00Z"] as const;
/** 런던 10-10 08:30 BST 보고: 런던 10-10은 서울 보고(10-09 23:30Z)가 예정된 날이다 */
const LONDON = ["Europe/London", "2026-10-10", "2026-10-09T23:00:00Z", "2026-10-10T07:30:00Z", "2026-10-10T09:30:00Z", "2026-10-10T07:30:00Z"] as const;
/**
 * 로스앤젤레스 10-09 08:30 PDT 보고를 LA 16:40(23:40Z)에 시간대를 바꾼 뒤 잡는 경우(바꾼 뒤 2시간 창): LA 10-09(07:00Z–다음 날 07:00Z)도
 * 서울 보고(10-09 23:30Z)가 예정된 날이다. 시간대 · 날짜가 모두 달라 유일 키와 겹치지 않는다
 */
const LA = ["America/Los_Angeles", "2026-10-09", "2026-10-09T07:00:00Z", "2026-10-09T15:30:00Z", "2026-10-10T01:40:00Z", "2026-10-09T23:40:00Z"] as const;

const claimSql = `select id from public.claim_report_delivery($1, 'daily', $2, $3, $4, $5, $6, $7, 300)`;
const claim = (client: pg.Client, userId: string, args: readonly string[]) => client.query(claimSql, [userId, ...args]).then((r) => r.rows.length);

async function newUser(timeZone = "Asia/Seoul"): Promise<string> {
  const id = randomUUID();
  await clients[0].query("insert into auth.users (id) values ($1)", [id]);
  await clients[0].query("insert into public.report_preferences (user_id, time_zone) values ($1, $2)", [id, timeZone]);
  return id;
}

const pidOf = async (client: pg.Client) => (await client.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;

/** pid가 다른 연결의 잠금을 기다리기 시작할 때까지 잠금 표(pg_blocking_pids)를 본다. 막은 연결들의 pid (시간으로 추측하지 않는다) */
async function blockersOf(pid: number): Promise<number[]> {
  for (let i = 0; i < 500; i++) {
    const { rows } = await clients[5].query<{ pids: number[] }>("select pg_blocking_pids($1) as pids", [pid]);
    if (rows[0].pids.length > 0) return rows[0].pids;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  return [];
}

/** 첫 클라이언트가 트랜잭션 안에서 잡고 있는 동안 두 번째가 같은 사용자를 잡으려 한다. 두 번째가 첫째에게 막혔는지 잠금 표로 확인한다 */
async function race(userId: string, first: readonly string[], second: readonly string[]) {
  const [a, b] = clients;
  const [aPid, bPid] = [await pidOf(a), await pidOf(b)];
  await a.query("begin");
  const won = await claim(a, userId, first);
  const pending = claim(b, userId, second);
  const blockedByFirst = (await blockersOf(bPid)).includes(aPid);
  await a.query("commit");
  return { won, lost: await pending, blockedByFirst };
}

beforeAll(async () => {
  admin = new pg.Client({ connectionString });
  await admin.connect();
  await admin.query(`create database ${database}`);
  const url = new URL(connectionString!);
  url.pathname = `/${database}`;
  clients = Array.from({ length: 6 }, () => new pg.Client({ connectionString: url.toString() }));
  await Promise.all(clients.map((c) => c.connect()));
  for (const sql of await supabaseSchemaScripts()) await clients[0].query(sql);
});

afterAll(async () => {
  await Promise.allSettled(clients.map((c) => c.end()));
  if (admin) {
    await admin.query(`drop database if exists ${database} with (force)`);
    await admin.end();
  }
});

beforeEach(async () => {
  for (const c of clients) await c.query("rollback").catch(() => undefined);
});

describe("겹친 cron의 잡기 (실제 Postgres)", () => {
  it("잡기는 사용자의 설정 행을 잠근다: 다른 연결이 그 행만 잠그고 있으면(원장 행 0, 유일 키와 무관) 잡기가 그 연결에 막혀 기다린다", async () => {
    const user = await newUser();
    const [holder, claimer] = clients;
    const [holderPid, claimerPid] = [await pidOf(holder), await pidOf(claimer)];
    await holder.query("begin");
    // for no key update: 함수의 for update와는 부딪히지만, 원장 insert의 외래키 확인(for key share)과는 부딪히지 않는다.
    // 그래서 기다린다면 함수의 설정 행 잠금 때문이다 (잠금을 빼면 이 테스트가 실패하는 것을 확인했다)
    await holder.query("select 1 from public.report_preferences where user_id = $1 for no key update", [user]);
    const pending = claim(claimer, user, SEOUL);
    expect(await blockersOf(claimerPid)).toEqual([holderPid]);
    await holder.query("commit");
    expect(await pending).toBe(1);
  });

  it("같은 날을 두 실행이 동시에 잡으면 하나만 잡는다: 둘째는 첫째에게 막혀 기다렸다가 빈 결과", async () => {
    const user = await newUser();
    expect(await race(user, SEOUL, SEOUL)).toEqual({ won: 1, lost: 0, blockedByFirst: true });
    expect((await clients[0].query("select count(*)::int as n from public.report_deliveries where user_id = $1", [user])).rows[0].n).toBe(1);
  });

  it.each([
    ["런던 10-10", LONDON],
    ["로스앤젤레스 10-09 (시간대 · 날짜 모두 다름)", LA],
  ])("시간대를 바꾼 직후 다른 시간대로 같은 현지 날(%s)을 동시에 잡아도 하나만: 유일 키가 아니라 설정 행 잠금 + 예정 시각 확인이 막는다", async (_name, other) => {
    const user = await newUser();
    expect(await race(user, SEOUL, other)).toEqual({ won: 1, lost: 0, blockedByFirst: true });
    const { rows } = await clients[0].query("select time_zone from public.report_deliveries where user_id = $1", [user]);
    expect(rows).toEqual([{ time_zone: "Asia/Seoul" }]);
  });

  it("여섯 연결이 한꺼번에 잡아도 원장에는 한 줄", async () => {
    const user = await newUser();
    const results = await Promise.all(clients.map((c) => claim(c, user, SEOUL)));
    expect(results.reduce((sum, n) => sum + n, 0)).toBe(1);
    expect((await clients[0].query("select count(*)::int as n from public.report_deliveries where user_id = $1", [user])).rows[0].n).toBe(1);
  });

  it("다시 잡기도 겹친 실행 중 하나만: attempts가 한 번만 오른다", async () => {
    const user = await newUser();
    const { rows } = await clients[0].query(claimSql, [user, ...SEOUL]);
    const id = rows[0].id as string;
    const retrySql = `select id from public.claim_report_retry($1, '2026-10-09T23:40:00Z', 300, 3)`;
    const [a, b] = clients;
    const [aPid, bPid] = [await pidOf(a), await pidOf(b)];
    await a.query("begin");
    expect((await a.query(retrySql, [id])).rows).toHaveLength(1);
    const pending = b.query(retrySql, [id]);
    expect(await blockersOf(bPid)).toEqual([aPid]);
    await a.query("commit");
    expect((await pending).rows).toHaveLength(0);
    expect((await clients[0].query("select attempts from public.report_deliveries where id = $1", [id])).rows).toEqual([{ attempts: 2 }]);

    const results = await Promise.all(clients.map((c) => c.query(`select id from public.claim_report_retry($1, '2026-10-09T23:45:00Z', 300, 3)`, [id])));
    expect(results.reduce((sum, r) => sum + r.rows.length, 0)).toBe(1);
    expect((await clients[0].query("select attempts from public.report_deliveries where id = $1", [id])).rows).toEqual([{ attempts: 3 }]);
  });
});

describe("RLS (실제 Postgres)", () => {
  it("앱은 자기 설정 · 원장만 읽고, 쓰지 못한다", async () => {
    const alice = await newUser();
    const bob = await newUser("Europe/London");
    await claim(clients[0], alice, SEOUL);
    await claim(clients[0], bob, LONDON);
    const c = clients[1];
    await c.query("set role authenticated");
    await c.query("select set_config('request.jwt.claim.sub', $1, false)", [alice]);
    try {
      for (const table of ["report_preferences", "report_deliveries"]) {
        const { rows } = await c.query(`select user_id from public.${table}`);
        expect(rows.map((r) => r.user_id), table).toEqual([alice]);
        await expect(c.query(`update public.${table} set user_id = user_id where user_id = $1`, [alice]), table).rejects.toThrow(/permission denied/);
      }
      await expect(c.query(`insert into public.report_preferences (user_id, time_zone) values ($1, 'Asia/Seoul')`, [alice])).rejects.toThrow(/permission denied/);
      await expect(c.query(claimSql, [alice, ...SEOUL])).rejects.toThrow(/permission denied/);
    } finally {
      await c.query("reset role");
      await c.query("select set_config('request.jwt.claim.sub', '', false)");
    }
  });
});
