import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { additiveFixtures, executionAdditiveTests, executionUpgradeTests, type ExecutionAdditiveDb } from "../db/execution-additive-contract.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 실행 additive 확장 (20261109000000_execution_additive_contract, 구현 계획 C1) — 실제 Postgres. PGlite와 같은 시나리오 + 같은 업그레이드 회귀(실제 Postgres에서 마이그레이션 앞뒤) +
// 연결 둘이 겹치는 경합: 연결별 정책 version 조건부 갱신 · 같은 연결의 정책 중복 생성 · 연결 삭제 ↔ 정책 만들기 · 대화 / 범위 삭제 ↔ run 참조 쓰기.
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
const DB_NAME = `taskforce_exec_additive_${SUFFIX}`;

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

const db = (): ExecutionAdditiveDb => ({
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

describe("실행 additive 확장 (실제 Postgres)", () => {
  executionAdditiveTests(db);
});

// 업그레이드 회귀: 마이그레이션 중간까지만 적용한 새 데이터베이스
executionUpgradeTests(async () => {
  const name = `taskforce_exec_upgrade_${SUFFIX}_${extraDatabases.length}`;
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

describe("실행 additive 확장 경합 (실제 Postgres, 연결 둘)", () => {
  const f = additiveFixtures(db);
  const policyRow = (policy: string) => f.one(`select mode, version, standing_budget_credits from public.execution_connection_policies where id = $1`, [policy]);

  it("연결별 정책 version 조건부 갱신 둘이 겹치면 한 쪽만 이긴다: 나중 쪽은 행 잠금을 기다린 뒤 조건(version)이 어긋나 0행이고, 정책은 이긴 쪽 내용이다", async () => {
    const user = await f.user();
    const policy = await f.policy(user, await f.connection(user));
    const update = (client: pg.Client, mode: string) =>
      client.query(`update public.execution_connection_policies set mode = $2, version = version + 1 where id = $1 and version = 1 returning version`, [policy, mode]);
    await a.query("begin");
    await b.query("begin");
    const first = await update(a, "auto");
    const second = update(b, "full");
    await waitForLockWait(bPid);
    await a.query("commit");
    const lost = await second;
    await b.query("commit");
    expect(first.rows).toEqual([{ version: 2 }]);
    expect(lost.rows).toEqual([]);
    expect(await policyRow(policy)).toEqual({ mode: "auto", version: 2, standing_budget_credits: 0 });
    // 진 쪽이 다시 읽고(version 2) 다시 쓰면 이긴다
    expect((await b.query(`update public.execution_connection_policies set mode = 'full', version = version + 1 where id = $1 and version = 2 returning version`, [policy])).rows).toEqual([{ version: 3 }]);
  });

  it("version을 정해 놓고 쓰는 낡은 갱신(조건 없음)은 거절된다: 둘 다 version = 2로 쓰면 나중 쪽은 앞 쪽이 commit한 2에서 내용만 바뀌므로 트리거가 막는다", async () => {
    const user = await f.user();
    const policy = await f.policy(user, await f.connection(user));
    await a.query("begin");
    await b.query("begin");
    await a.query(`update public.execution_connection_policies set mode = 'auto', version = 2 where id = $1`, [policy]);
    const blind = b.query(`update public.execution_connection_policies set mode = 'full', version = 2 where id = $1`, [policy]);
    const rejected = expect(blind).rejects.toThrow(/version은 내용이 바뀔 때 정확히 \+ 1/);
    await waitForLockWait(bPid);
    await a.query("commit");
    await rejected;
    await b.query("rollback");
    expect(await policyRow(policy)).toEqual({ mode: "auto", version: 2, standing_budget_credits: 0 });
  });

  it("version + 1로 쓰는 갱신 둘은 둘 다 반영돼 version이 두 번 오른다 (올림이 사라지지 않는다 — 승인이 묶인 version이 되돌아가지 않는다)", async () => {
    const user = await f.user();
    const policy = await f.policy(user, await f.connection(user));
    await a.query("begin");
    await b.query("begin");
    await a.query(`update public.execution_connection_policies set mode = 'auto', version = version + 1 where id = $1`, [policy]);
    const second = b.query(`update public.execution_connection_policies set standing_budget_credits = 7, version = version + 1 where id = $1 returning version`, [policy]);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await second).rows).toEqual([{ version: 3 }]);
    await b.query("commit");
    expect(await policyRow(policy)).toEqual({ mode: "auto", version: 3, standing_budget_credits: 7 });
  });

  it("같은 연결의 정책을 동시에 만들면 하나만 생긴다: 앞 쪽이 commit하면 뒤 쪽은 unique 위반", async () => {
    const user = await f.user();
    const connection = await f.connection(user);
    const insert = (client: pg.Client, mode: string) =>
      client.query(`insert into public.execution_connection_policies (user_id, connection_id, mode) values ($1, $2, $3) returning id`, [user, connection, mode]);
    await a.query("begin");
    await b.query("begin");
    await insert(a, "auto");
    const rejected = expect(insert(b, "full")).rejects.toThrow(/duplicate key value violates unique constraint/);
    await waitForLockWait(bPid);
    await a.query("commit");
    await rejected;
    await b.query("rollback");
    expect(await f.one(`select count(*)::int as n, min(mode) as mode from public.execution_connection_policies where connection_id = $1`, [connection])).toEqual({ n: 1, mode: "auto" });
  });

  it("앞 쪽이 rollback하면 기다리던 뒤 쪽이 만든다 (정책이 둘이 되지도, 둘 다 사라지지도 않는다)", async () => {
    const user = await f.user();
    const connection = await f.connection(user);
    const insert = (client: pg.Client, mode: string) =>
      client.query(`insert into public.execution_connection_policies (user_id, connection_id, mode) values ($1, $2, $3) returning id`, [user, connection, mode]);
    await a.query("begin");
    await b.query("begin");
    await insert(a, "auto");
    const waiting = insert(b, "full");
    await waitForLockWait(bPid);
    await a.query("rollback");
    expect((await waiting).rows).toHaveLength(1);
    await b.query("commit");
    expect(await f.one(`select count(*)::int as n, min(mode) as mode from public.execution_connection_policies where connection_id = $1`, [connection])).toEqual({ n: 1, mode: "full" });
  });

  it("연결 삭제 ↔ 정책 만들기: 정책이 먼저면 삭제가 기다렸다가 정책도 함께 지우고, 삭제가 먼저면 정책 만들기는 외래키 위반이다 (고아 정책이 없다)", async () => {
    const user = await f.user();
    // 정책이 먼저
    const first = await f.connection(user);
    await a.query("begin");
    await a.query(`insert into public.execution_connection_policies (user_id, connection_id) values ($1, $2)`, [user, first]);
    const deletion = b.query(`delete from public.connections where id = $1`, [first]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await deletion;
    expect(await f.count(`select 1 from public.connections where id = $1`, [first])).toBe(0);
    expect(await f.count(`select 1 from public.execution_connection_policies where connection_id = $1`, [first])).toBe(0);
    // 삭제가 먼저
    const second = await f.connection(user);
    await b.query("begin");
    await b.query(`delete from public.connections where id = $1`, [second]);
    const creation = a.query(`insert into public.execution_connection_policies (user_id, connection_id) values ($1, $2)`, [user, second]);
    const rejected = expect(creation).rejects.toThrow(/violates foreign key constraint/);
    await waitForLockWait(aPid);
    await b.query("commit");
    await rejected;
    expect(await f.count(`select 1 from public.execution_connection_policies where user_id = $1`, [user])).toBe(0);
  });

  it.each([
    ["conversation_id", "conversations", (userId: string) => f.conversation(userId)],
    ["context_id", "work_contexts", (userId: string) => f.context(userId)],
  ] as const)(
    "run의 %s 쓰기 ↔ 부모(%s) 삭제: 쓰기가 먼저면 삭제가 기다렸다가 참조를 비우고 run은 남고, 삭제가 먼저면 쓰기는 외래키 위반이라 run이 그대로다",
    async (column, parentTable, makeParent) => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const read = () => f.one(`select ${column} as ref, state, goal, directive_version from public.execution_runs where id = $1`, [run]);

      // 쓰기가 먼저
      const first = await makeParent(user);
      await a.query("begin");
      await a.query(`update public.execution_runs set ${column} = $2 where id = $1`, [run, first]);
      const deletion = b.query(`delete from public.${parentTable} where id = $1`, [first]);
      await waitForLockWait(bPid);
      await a.query("commit");
      await deletion;
      expect(await read()).toEqual({ ref: null, state: "queued", goal: "draft", directive_version: 1 });
      expect(await f.count(`select 1 from public.${parentTable} where id = $1`, [first])).toBe(0);

      // 삭제가 먼저
      const second = await makeParent(user);
      await b.query("begin");
      await b.query(`delete from public.${parentTable} where id = $1`, [second]);
      const writing = a.query(`update public.execution_runs set ${column} = $2 where id = $1`, [run, second]);
      const rejected = expect(writing).rejects.toThrow(/violates foreign key constraint/);
      await waitForLockWait(aPid);
      await b.query("commit");
      await rejected;
      expect(await read()).toEqual({ ref: null, state: "queued", goal: "draft", directive_version: 1 });
      // 끝난 뒤에도 run은 한 줄이다 (고아 참조 없음)
      expect(await f.count(`select 1 from public.execution_runs where user_id = $1`, [user])).toBe(1);
    },
  );

  it("부모(대화 · 범위) 삭제가 run의 상태 전이와 겹쳐도 서로 막지 않는다: 멈추기 ↔ 범위 삭제", async () => {
    const user = await f.user();
    const context = await f.context(user);
    const run = await f.run(user, await f.action(user));
    await setup.query(`update public.execution_runs set context_id = $2, bundle_context_version = 5 where id = $1`, [run, context]);
    await a.query("begin");
    await a.query(`select public.stop_run($1, $2)`, [user, run]);
    const deletion = b.query(`delete from public.work_contexts where id = $1`, [context]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await deletion;
    expect(await f.one(`select state, context_id, bundle_context_version from public.execution_runs where id = $1`, [run])).toEqual({ state: "stopped", context_id: null, bundle_context_version: 5 });
  });
});
