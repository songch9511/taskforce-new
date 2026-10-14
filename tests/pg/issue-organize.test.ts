import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";
import { bodyEqualityTests, organizeFixtures, organizeMoveTests } from "../db/issue-organize.scenarios";

// 서버 코드(src/lib/context/member-writes.ts)를 실제 SQL로 부르는 시나리오가 있다
vi.mock("server-only", () => ({}));

// 0.2.0 OA D4c-2 · D4c-3b (20261125000000_issue_organize) — 실제 Postgres. PGlite와 같은 시나리오 + 연결 둘이 겹치는 경합.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_organize_${process.pid}_${Date.now()}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let bPid: number;

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
});

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

afterEach(async () => {
  await a.query("rollback").catch(() => {});
  await b.query("rollback").catch(() => {});
});

// 한 연결(setup)에 쿼리를 차례로 보낸다: 서버 코드가 Promise.all로 동시에 읽어도 pg 클라이언트에 겹쳐 보내지 않게
let chain: Promise<unknown> = Promise.resolve();
const serial = <T,>(run: () => Promise<T>): Promise<T> => {
  const next = chain.then(run, run);
  chain = next.catch(() => undefined);
  return next;
};

const db = () => ({
  query: (sql: string, params?: unknown[]) => serial(async () => (await setup.query(sql, params)).rows),
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

describe("이슈 정리 (실제 Postgres)", () => {
  bodyEqualityTests();
  organizeMoveTests(db);
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

const finish = (client: pg.Client, userId: string, messageId: string, turn: Record<string, unknown>) =>
  client.query(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [userId, messageId, JSON.stringify(turn)]).then((r) => r.rows[0] as { status: string; reply_id: string | null });
const menuMove = (client: pg.Client, userId: string, actionId: string, addContext: string, addVersion: number) =>
  client
    .query(`select * from public.change_context_membership_with_metric($1, $2, $3, $4, null, null, 'menu')`, [userId, actionId, addContext, addVersion])
    .then((r) => r.rows[0] as { status: string; added_changed: boolean });

describe("이슈 정리 경합 (실제 Postgres, 연결 둘)", () => {
  const f = organizeFixtures(db);

  it("P3 말로 이동 ↔ 메뉴 이동(같은 Action · 같은 범위 · 같은 version) 동시: (사용자 × Action) advisory 잠금으로 한 줄로 서고, 먼저 쓴 쪽만 이기고 다른 쪽은 conflict, 지표는 한 줄", async () => {
    const w = await f.world();
    const seen = await f.version(w.b);
    const move = { action_id: w.issue.id, add: { context_id: w.b, expected_version: seen }, remove: null };

    await a.query("begin");
    const talk = await finish(a, w.user, w.message, f.moveTurn([move]));
    const menu = menuMove(b, w.user, w.issue.id, w.b, seen);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(talk.status).toBe("written");
    expect(await menu).toMatchObject({ status: "conflict", added_changed: false });
    expect(await f.moved(w.user)).toEqual([{ action_id: w.issue.id, props: { via: "talk", from_context: null, to_context: w.b } }]);
    expect((await f.current(w.issue.id)).map((m) => m.context_id).sort()).toEqual([w.a, w.b].sort());

    // 반대 순서: 메뉴가 먼저 쓰면 말로 이동 한 턴이 conflict로 끝나고 답 · 지표가 늘지 않는다
    const second = await f.world();
    const v = await f.version(second.b);
    const turnMove = { action_id: second.issue.id, add: { context_id: second.b, expected_version: v }, remove: null };
    await a.query("begin");
    expect((await menuMove(a, second.user, second.issue.id, second.b, v)).status).toBe("ok");
    const late = finish(b, second.user, second.message, f.moveTurn([turnMove]));
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await late).status).toBe("conflict");
    expect(await f.moved(second.user)).toEqual([{ action_id: second.issue.id, props: { via: "menu", from_context: null, to_context: second.b } }]);
    expect(await f.q(`select 1 from public.conversation_messages where reply_to = $1`, [second.message])).toEqual([]);
  });
});
