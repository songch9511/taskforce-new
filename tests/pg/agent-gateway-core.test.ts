import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { agentGatewayCoreTests, agentGatewayFixtures, agentGatewayUpgradeTests, type AgentGatewayDb } from "../db/agent-gateway-core.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 에이전트 게이트웨이 저장 계약 (20261113000000_agent_gateway_core, 구현 계획 D1a) — 실제 Postgres. PGlite와 같은 시나리오 + 같은 업그레이드 회귀(실제 Postgres에서 마이그레이션 앞뒤) +
// 연결 둘이 겹치는 경합(T8): 같은 (세션, 이슈)의 열린 대화 run 동시 insert · 같은 세션의 진행 중 작업 동시 insert · 멈춤 ↔ 새 대화 run · 부모(세션 · 연결) 삭제 ↔ 참조 쓰기.
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
const DB_NAME = `taskforce_agent_gateway_${SUFFIX}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let aPid: number;
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
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
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

const db = (): AgentGatewayDb => ({
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

describe("에이전트 게이트웨이 저장 계약 (실제 Postgres)", () => {
  agentGatewayCoreTests(db);
});

// 업그레이드 회귀: 마이그레이션 중간까지만 적용한 새 데이터베이스
agentGatewayUpgradeTests(async () => {
  const name = `taskforce_agent_gateway_upgrade_${SUFFIX}_${extraDatabases.length}`;
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

describe("T8 에이전트 게이트웨이 경합 (실제 Postgres, 연결 둘)", () => {
  const f = agentGatewayFixtures(db);

  /** 정책이 있는 사용자 하나와 그의 연결 · 세션 · 이슈 */
  async function setupSession() {
    const user = await f.user();
    const connection = await f.agentConnection(user);
    const session = await f.session(user, connection);
    const action = await f.action(user);
    await f.q(`insert into public.execution_policies (user_id) values ($1) on conflict (user_id) do nothing`, [user]);
    const policy = String((await f.one(`select id from public.execution_policies where user_id = $1`, [user])).id);
    const run = (client: pg.Client, sessionId: string, actionId: string) =>
      client.query(
        `insert into public.execution_runs (user_id, action_id, policy_id, goal, request, kind, agent_session_id) values ($1, $2, $3, 'agent', '대화', 'conversation', $4) returning id`,
        [user, actionId, policy, sessionId],
      );
    const task = (client: pg.Client, runId: string, sessionId: string, state: string) =>
      client.query(`insert into public.agent_tasks (user_id, run_id, agent_session_id, state) values ($1, $2, $3, $4) returning id`, [user, runId, sessionId, state]);
    return { user, connection, session, action, policy, run, task };
  }

  it("같은 (세션, 이슈)의 열린 대화 run을 두 연결이 동시에 넣으면 정확히 하나만 성공한다: 뒤 쪽은 앞 쪽의 commit을 기다린 뒤 unique 위반", async () => {
    const s = await setupSession();
    await a.query("begin");
    await b.query("begin");
    const first = await s.run(a, s.session, s.action);
    const second = s.run(b, s.session, s.action);
    const rejected = expect(second).rejects.toThrow(/execution_runs_open_conversation_idx/);
    await waitForLockWait(bPid);
    await a.query("commit");
    await rejected;
    await b.query("rollback");
    expect(first.rows).toHaveLength(1);
    expect(await f.count(`select 1 from public.execution_runs where agent_session_id = $1 and action_id = $2`, [s.session, s.action])).toBe(1);
  });

  it("앞 쪽이 rollback하면 기다리던 뒤 쪽이 만든다 (열린 대화 run이 둘이 되지도, 0이 되지도 않는다)", async () => {
    const s = await setupSession();
    await a.query("begin");
    await b.query("begin");
    await s.run(a, s.session, s.action);
    const waiting = s.run(b, s.session, s.action);
    await waitForLockWait(bPid);
    await a.query("rollback");
    expect((await waiting).rows).toHaveLength(1);
    await b.query("commit");
    expect(await f.count(`select 1 from public.execution_runs where agent_session_id = $1 and action_id = $2`, [s.session, s.action])).toBe(1);
  });

  it("같은 세션에 진행 중 작업을 두 연결이 동시에 넣으면 하나만 성공한다 (세션당 진행 중 턴 하나)", async () => {
    const s = await setupSession();
    const run = String((await s.run(a, s.session, s.action)).rows[0].id);
    await a.query("begin");
    await b.query("begin");
    await s.task(a, run, s.session, "dispatched");
    const second = s.task(b, run, s.session, "running");
    const rejected = expect(second).rejects.toThrow(/agent_tasks_in_progress_idx/);
    await waitForLockWait(bPid);
    await a.query("commit");
    await rejected;
    await b.query("rollback");
    expect(await f.count(`select 1 from public.agent_tasks where agent_session_id = $1`, [s.session])).toBe(1);
    // 같은 세션의 idle 작업은 겹쳐도 된다
    await a.query("begin");
    await b.query("begin");
    await s.task(a, run, s.session, "idle");
    await s.task(b, run, s.session, "idle");
    await a.query("commit");
    await b.query("commit");
    expect(await f.count(`select 1 from public.agent_tasks where agent_session_id = $1`, [s.session])).toBe(3);
  });

  it("같은 (세션, turn_seq)를 동시에 쓰면 하나만 성공한다", async () => {
    const s = await setupSession();
    const run = String((await s.run(a, s.session, s.action)).rows[0].id);
    const insert = (client: pg.Client) =>
      client.query(`insert into public.agent_tasks (user_id, run_id, agent_session_id, state, turn_seq) values ($1, $2, $3, 'idle', 1)`, [s.user, run, s.session]);
    await a.query("begin");
    await b.query("begin");
    await insert(a);
    const rejected = expect(insert(b)).rejects.toThrow(/agent_tasks_session_turn_idx/);
    await waitForLockWait(bPid);
    await a.query("commit");
    await rejected;
    await b.query("rollback");
    expect(await f.count(`select 1 from public.agent_tasks where agent_session_id = $1 and turn_seq = 1`, [s.session])).toBe(1);
  });

  it("멈춤 ↔ 새 대화 run: 앞 run을 stopped로 바꾸는 중에 같은 (세션, 이슈)의 새 대화 run을 넣으면, 새 run은 멈춤이 commit된 뒤 만들어진다 (열린 run은 항상 하나)", async () => {
    const s = await setupSession();
    const first = String((await s.run(a, s.session, s.action)).rows[0].id);
    await a.query("begin");
    await a.query(`update public.execution_runs set state = 'stopped' where id = $1`, [first]);
    const creation = s.run(b, s.session, s.action);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await creation).rows).toHaveLength(1);
    expect(await f.count(`select 1 from public.execution_runs where agent_session_id = $1 and action_id = $2 and state not in ('done', 'failed', 'stopped')`, [s.session, s.action])).toBe(1);
    expect(await f.count(`select 1 from public.execution_runs where agent_session_id = $1 and action_id = $2`, [s.session, s.action])).toBe(2);
  });

  it("세션 삭제 ↔ run 참조 쓰기: 쓰기가 먼저면 삭제가 기다렸다가 참조를 비우고 run은 남고, 삭제가 먼저면 쓰기는 외래키 위반이다 (고아 참조가 없다)", async () => {
    const s = await setupSession();
    const run = String((await s.run(a, s.session, s.action)).rows[0].id);
    const read = () => f.one(`select agent_session_id as ref, kind, state, stopped_at from public.execution_runs where id = $1`, [run]);
    // 쓰기가 먼저
    const sessionA = await f.session(s.user, s.connection);
    await a.query("begin");
    await a.query(`update public.execution_runs set agent_session_id = $2 where id = $1`, [run, sessionA]);
    const deletion = b.query(`delete from public.agent_sessions where id = $1`, [sessionA]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await deletion;
    expect(await read()).toEqual({ ref: null, kind: "conversation", state: "stopped", stopped_at: null });
    expect(await f.count(`select 1 from public.inbox_events where user_id = $1 and dedup_key = $2`, [s.user, `run_stop:${run}`])).toBe(0);
    // 삭제가 먼저
    const sessionB = await f.session(s.user, s.connection);
    await b.query("begin");
    await b.query(`delete from public.agent_sessions where id = $1`, [sessionB]);
    const writing = a.query(`update public.execution_runs set agent_session_id = $2 where id = $1`, [run, sessionB]);
    const rejected = expect(writing).rejects.toThrow(/violates foreign key constraint/);
    await waitForLockWait(aPid);
    await b.query("commit");
    await rejected;
    expect(await read()).toEqual({ ref: null, kind: "conversation", state: "stopped", stopped_at: null });
  });

  it("연결 삭제 ↔ 세션 만들기: 세션이 먼저면 삭제가 기다렸다가 세션 · 작업도 함께 지우고, 삭제가 먼저면 세션 만들기는 외래키 위반이다 (고아 세션이 없다)", async () => {
    const s = await setupSession();
    // 세션이 먼저
    const first = await f.agentConnection(s.user);
    await a.query("begin");
    await a.query(`insert into public.agent_sessions (user_id, connection_id, external_session_id, workspace_ref) values ($1, $2, $3, 'ws')`, [s.user, first, randomUUID()]);
    const deletion = b.query(`delete from public.agent_connections where id = $1`, [first]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await deletion;
    expect(await f.count(`select 1 from public.agent_sessions where connection_id = $1`, [first])).toBe(0);
    // 삭제가 먼저
    const second = await f.agentConnection(s.user);
    await b.query("begin");
    await b.query(`delete from public.agent_connections where id = $1`, [second]);
    const creation = a.query(`insert into public.agent_sessions (user_id, connection_id, external_session_id, workspace_ref) values ($1, $2, $3, 'ws')`, [s.user, second, randomUUID()]);
    const rejected = expect(creation).rejects.toThrow(/violates foreign key constraint/);
    await waitForLockWait(aPid);
    await b.query("commit");
    await rejected;
    expect(await f.count(`select 1 from public.agent_sessions where connection_id = $1`, [second])).toBe(0);
  });

  it("같은 사건을 두 연결이 동시에 적재하면 하나만 남는다 ((run, external_event_id) 한 번만)", async () => {
    const s = await setupSession();
    const run = String((await s.run(a, s.session, s.action)).rows[0].id);
    const insert = (client: pg.Client) =>
      client.query(`insert into public.execution_events (user_id, run_id, type, external_event_id) values ($1, $2, 'agent', 'evt-race')`, [s.user, run]);
    await a.query("begin");
    await b.query("begin");
    await insert(a);
    const rejected = expect(insert(b)).rejects.toThrow(/execution_events_agent_dedup_idx/);
    await waitForLockWait(bPid);
    await a.query("commit");
    await rejected;
    await b.query("rollback");
    expect(await f.count(`select 1 from public.execution_events where run_id = $1 and external_event_id = 'evt-race'`, [run])).toBe(1);
  });
});
