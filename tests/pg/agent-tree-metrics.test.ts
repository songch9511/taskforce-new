// 에이전트 트리 지표 넷 (T3s, 20261209000000): 실제 Postgres에서 같은 단위(턴 · 사용자의 UTC 하루)의 동시 요청 둘이 한 행만 남기는지.
// PGlite는 연결이 하나라 "동시에 온 두 요청"을 증명하지 못한다. 코디네이터의 일회용 Postgres(DATABASE_URL)에서 돌린다.
// route(src/lib/api/agent-tree-metrics.ts)가 쓰는 insert와 같은 모양(user_id · type · props)을 서버 권한으로 직접 넣는다.
import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(일회용 데이터베이스를 만들 수 있는 실제 Postgres)이 필요합니다.");
const DB_NAME = `taskforce_agent_tree_metrics_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
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
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

afterEach(async () => {
  // A를 먼저 놓아 B의 대기를 풀어 준 뒤 정리한다.
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

const TURN_TYPES = ["subagent_turn_used", "subagent_question_redirected"] as const;
const DAY_TYPES = ["project_sessions_opened", "subagent_row_opened"] as const;

async function owner() {
  const id = randomUUID();
  await setup.query("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
  return id;
}
const insertTurn = (client: pg.Client, user: string, type: string, task: string) =>
  client.query("insert into public.metric_events (user_id, type, props) values ($1, $2, $3::jsonb)", [user, type, JSON.stringify({ agent_task_id: task })]);
const insertDay = (client: pg.Client, user: string, type: string, at: string) =>
  client.query("insert into public.metric_events (user_id, type, props, at) values ($1, $2, '{}'::jsonb, $3::timestamptz)", [user, type, at]);
const count = async (user: string, type: string) => Number((await setup.query("select count(*)::int as n from public.metric_events where user_id = $1 and type = $2", [user, type])).rows[0].n);
/** 성공하면 "ok", 실패하면 SQLSTATE */
const outcome = (promise: Promise<unknown>) => promise.then(() => "ok", (error: { code?: string }) => error.code ?? "error");

async function waitForLockWait() {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [bPid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("둘째 연결이 잠금을 기다리지 않는다");
}

describe.each(TURN_TYPES)("같은 턴 동시 요청 둘 (연결 둘): %s", (type) => {
  it("먼저 온 쪽이 commit하면 뒤 쪽은 기다렸다가 23505로 밀려난다: 한 행만 남는다", async () => {
    const user = await owner();
    const task = randomUUID();
    await a.query("begin");
    await b.query("begin");
    await insertTurn(a, user, type, task);
    const second = outcome(insertTurn(b, user, type, task));
    await waitForLockWait();
    await a.query("commit");
    expect(await second).toBe("23505");
    await b.query("rollback");
    expect(await count(user, type)).toBe(1);
  });

  it("먼저 온 쪽이 rollback하면 뒤 쪽이 남긴다: 한 행", async () => {
    const user = await owner();
    const task = randomUUID();
    await a.query("begin");
    await b.query("begin");
    await insertTurn(a, user, type, task);
    const second = outcome(insertTurn(b, user, type, task));
    await waitForLockWait();
    await a.query("rollback");
    expect(await second).toBe("ok");
    await b.query("commit");
    expect(await count(user, type)).toBe(1);
  });

  it("두 연결이 같은 턴을 자동 commit으로 번갈아 20번 던져도 성공은 한 번이고 나머지는 23505다", async () => {
    const user = await owner();
    const task = randomUUID();
    const results: string[] = [];
    for (let round = 0; round < 10; round++) results.push(...(await Promise.all([outcome(insertTurn(a, user, type, task)), outcome(insertTurn(b, user, type, task))])));
    expect(results.filter((r) => r === "ok")).toHaveLength(1);
    expect(results.filter((r) => r === "23505")).toHaveLength(19);
    expect(await count(user, type)).toBe(1);
  });

  it("서로 다른 턴을 동시에 남기면 모두 남는다", async () => {
    const user = await owner();
    const tasks = Array.from({ length: 10 }, () => randomUUID());
    await Promise.all([
      (async () => {
        for (const task of tasks.slice(0, 5)) await insertTurn(a, user, type, task);
      })(),
      (async () => {
        for (const task of tasks.slice(5)) await insertTurn(b, user, type, task);
      })(),
    ]);
    expect(await count(user, type)).toBe(10);
  });
});

describe("같은 턴의 두 종류 동시 요청은 서로 막지 않는다", () => {
  it("turn_used와 question_redirected를 동시에 넣으면 둘 다 남는다", async () => {
    const user = await owner();
    const task = randomUUID();
    const results = await Promise.all([outcome(insertTurn(a, user, "subagent_turn_used", task)), outcome(insertTurn(b, user, "subagent_question_redirected", task))]);
    expect(results).toEqual(["ok", "ok"]);
    expect(await count(user, "subagent_turn_used")).toBe(1);
    expect(await count(user, "subagent_question_redirected")).toBe(1);
  });
});

describe.each(DAY_TYPES)("같은 사용자 · 같은 UTC 날짜 동시 요청 둘 (연결 둘): %s", (type) => {
  it("먼저 온 쪽이 commit하면 뒤 쪽은 23505로 밀려난다: 한 행만 남는다", async () => {
    const user = await owner();
    await a.query("begin");
    await b.query("begin");
    await insertDay(a, user, type, "2026-10-22T01:00:00Z");
    const second = outcome(insertDay(b, user, type, "2026-10-22T23:00:00Z"));
    await waitForLockWait();
    await a.query("commit");
    expect(await second).toBe("23505");
    await b.query("rollback");
    expect(await count(user, type)).toBe(1);
  });

  it("자동 commit으로 번갈아 20번 던져도 성공은 한 번이다. 다른 날 · 다른 사용자는 따로 센다", async () => {
    const user = await owner();
    const other = await owner();
    const results: string[] = [];
    for (let round = 0; round < 10; round++) results.push(...(await Promise.all([outcome(insertDay(a, user, type, "2026-10-22T05:00:00Z")), outcome(insertDay(b, user, type, "2026-10-22T06:00:00Z"))])));
    expect(results.filter((r) => r === "ok")).toHaveLength(1);
    expect(results.filter((r) => r === "23505")).toHaveLength(19);
    expect(await outcome(insertDay(a, user, type, "2026-10-23T00:00:00Z"))).toBe("ok");
    expect(await outcome(insertDay(b, other, type, "2026-10-22T05:00:00Z"))).toBe("ok");
    expect(await count(user, type)).toBe(2);
    expect(await count(other, type)).toBe(1);
  });
});

describe("실제 Postgres에서도 같은 제약이 걸려 있다", () => {
  it("T2 props 검사: 키를 더하거나 uuid가 아니거나 대문자인 값은 23514, 정상 값은 들어간다", async () => {
    const user = await owner();
    const task = randomUUID();
    for (const props of [{}, { agent_task_id: task, count: 2 }, { agent_task_id: "nope" }, { agent_task_id: task.toUpperCase() }, { agent_task_id: null }]) {
      expect(await outcome(setup.query("insert into public.metric_events (user_id, type, props) values ($1, 'subagent_turn_used', $2::jsonb)", [user, JSON.stringify(props)])), JSON.stringify(props)).toBe("23514");
    }
    expect(await outcome(insertTurn(setup, user, "subagent_turn_used", task))).toBe("ok");
  });

  it("앱 역할(authenticated)은 네 종류를 직접 넣지 못한다", async () => {
    const user = await owner();
    await setup.query("set role authenticated");
    await setup.query("select set_config('request.jwt.claim.sub', $1, false)", [user]);
    try {
      for (const type of [...TURN_TYPES, ...DAY_TYPES]) {
        const code = await outcome(setup.query("insert into public.metric_events (type) values ($1)", [type]));
        expect(["42501", "23514"], type).toContain(code);
      }
    } finally {
      await setup.query("reset role");
      await setup.query("select set_config('request.jwt.claim.sub', '', false)");
    }
    for (const type of [...TURN_TYPES, ...DAY_TYPES]) expect(await count(user, type)).toBe(0);
  });
});
