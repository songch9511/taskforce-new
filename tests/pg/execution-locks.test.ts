import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

// 실행 코어의 잠금 경합 (docs/EXECUTION.md 6장 · 11장 한계). PGlite는 연결이 하나라 트랜잭션이 실제로 겹치지 않는다.
// 실제 Postgres에 연결 둘(A · B)을 열어, begin_call의 스위치 for share · intent unique · 단계 for update가 동시 commit에서 지키는 것을 본다.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 운영 마이그레이션을 그대로 적용하고, 끝나면 지운다.
// DATABASE_URL이 없으면 건너뛰지 않고 실패한다 (CI는 check 작업의 postgres service).

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_locks_${process.pid}_${Date.now()}`;
const RULE = "rule@example.com";

let admin: pg.Client; // DATABASE_URL의 데이터베이스: 일회용 데이터베이스를 만들고 지운다
let setup: pg.Client; // 일회용 데이터베이스: 준비와 commit된 상태 확인
let a: pg.Client;
let b: pg.Client;
let aPid: number;
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

const pidOf = async (client: pg.Client) => (await client.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  // 시험 전용 외부 도구와 그 공급자 스위치, 수신자 허용 목록
  await setup.query(`
    insert into public.execution_tools (provider, tool, effect_class) values ('fake', 'send', 'external');
    insert into public.execution_controls (scope, key) values ('provider', 'fake');
    insert into public.execution_recipient_allowlist (address) values ('${RULE}');
  `);
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
  [aPid, bPid] = [await pidOf(a), await pidOf(b)];
});

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

// 스위치는 모두 켬 (시드는 전체 · auto · full이 막혀 있다)
beforeEach(async () => {
  await setup.query("update public.execution_controls set blocked = false");
});

afterEach(async () => {
  // 테스트가 중간에 실패해도 열린 트랜잭션 · 기다리는 쿼리를 남기지 않는다 (A를 먼저 풀어야 B가 끝난다)
  await a.query("rollback").catch(() => {});
  await b.query("rollback").catch(() => {});
});

/** 시험 사용자 하나: Auto 정책(규칙 RULE), 실행 주체 허용 목록 안, Action 하나 */
async function newUser() {
  const userId = randomUUID();
  const actionId = randomUUID();
  await setup.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await setup.query("insert into public.actions (id, user_id, title) values ($1, $2, '견적서 보내기')", [actionId, userId]);
  await setup.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  await setup.query("insert into public.execution_policies (user_id, mode, auto_recipients) values ($1, 'auto', $2::jsonb)", [userId, JSON.stringify([RULE])]);
  return { userId, actionId };
}

/** 외부 단계(fake.send → RULE) 하나를 가진 run을 새로 만들고 prepared까지. 같은 Action · 목적이면 intent key가 같다 */
async function preparedStep(user: { userId: string; actionId: string }, purpose: string) {
  const runId = randomUUID();
  await setup.query(
    `insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request)
     select $1, $2, $3, id, 'draft', '견적서 보내 줘' from public.execution_policies where user_id = $2`,
    [runId, user.userId, user.actionId],
  );
  const { rows } = await setup.query<{ id: string }>(
    `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, recipients, body)
     values ($1, $2, 1, 'external', 'fake', 'send', $3, $4::jsonb, '견적서 보내드립니다') returning id`,
    [user.userId, runId, purpose, JSON.stringify([{ address: RULE, origin: "user" }])],
  );
  const stepId = rows[0].id;
  const prepared = await setup.query<{ ok: boolean }>("select public.prepare_step($1, 0) as ok", [stepId]);
  expect(prepared.rows[0].ok).toBe(true);
  return { stepId, version: 1 };
}

const beginCall = async (client: pg.Client, step: { stepId: string; version: number }, owner: string) =>
  (await client.query<{ g: { gate: string } }>("select public.begin_call($1, $2, $3) as g", [step.stepId, owner, step.version])).rows[0].g.gate;
const stepState = async (stepId: string) =>
  (await setup.query<{ state: string }>("select state from public.execution_steps where id = $1", [stepId])).rows[0].state;

/** 그 연결이 잠금을 기다리는 중인지 (pg_stat_activity). 5초 안에 기다리지 않으면 실패 */
async function waitForLockWait(pid: number) {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [pid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`연결 ${pid}가 잠금을 기다리지 않는다`);
}

describe("실행 코어 잠금 경합 (실제 Postgres, 연결 둘)", () => {
  it("스위치를 끄는 update는 진행 중인 begin_call(for share)이 commit될 때까지 기다린다. 그 전이는 남고, 끈 뒤의 begin_call은 막힌다", async () => {
    const user = await newUser();
    const first = await preparedStep(user, "send-1");
    const second = await preparedStep(user, "send-2");

    await a.query("begin");
    expect(await beginCall(a, first, "fn-a")).toBe("ok");
    const off = b.query("update public.execution_controls set blocked = true where scope = 'global'");
    await waitForLockWait(bPid);
    expect(await stepState(first.stepId)).toBe("prepared"); // A는 아직 commit 전
    await a.query("commit");
    await off;

    expect(await stepState(first.stepId)).toBe("calling"); // 끄기 전에 commit된 전이 하나만
    expect(await beginCall(a, second, "fn-a")).toBe("blocked");
    expect(await stepState(second.stepId)).toBe("prepared");
  });

  it("끄는 쪽이 먼저 잠그면 begin_call이 기다렸다가 끈 값을 읽고 막는다: 끈 뒤에 commit되는 전이는 없다", async () => {
    const step = await preparedStep(await newUser(), "send-1");

    await b.query("begin");
    await b.query("update public.execution_controls set blocked = true where scope = 'global'");
    const call = beginCall(a, step, "fn-a");
    await waitForLockWait(aPid);
    await b.query("commit");

    expect(await call).toBe("blocked");
    expect(await stepState(step.stepId)).toBe("prepared");
  });

  it("같은 intent를 두 연결이 동시에 begin_call하면 뒤의 쪽은 앞의 commit을 기다렸다가 건너뛴다(skipped)", async () => {
    const user = await newUser();
    const first = await preparedStep(user, "send-1");
    const second = await preparedStep(user, "send-1"); // 다른 run, 같은 Action · 목적 · 대상 · 회차

    await a.query("begin");
    expect(await beginCall(a, first, "fn-a")).toBe("ok");
    const late = beginCall(b, second, "fn-b"); // 중복 확인 때는 A의 intent가 아직 안 보인다 → insert에서 기다린다
    await waitForLockWait(bPid);
    await a.query("commit");

    expect(await late).toBe("duplicate");
    expect([await stepState(first.stepId), await stepState(second.stepId)]).toEqual(["calling", "skipped"]);
    const { rows } = await setup.query<{ n: number }>(
      "select count(*)::int as n from public.execution_intents i join public.execution_steps s on s.id = i.step_id where s.id in ($1, $2)",
      [first.stepId, second.stepId],
    );
    expect(rows[0].n).toBe(1);
  });

  it("같은 intent에서 앞의 쪽이 rollback하면 기다리던 쪽이 표식을 갖고 부른다", async () => {
    const user = await newUser();
    const first = await preparedStep(user, "send-1");
    const second = await preparedStep(user, "send-1");

    await a.query("begin");
    expect(await beginCall(a, first, "fn-a")).toBe("ok");
    const late = beginCall(b, second, "fn-b");
    await waitForLockWait(bPid);
    await a.query("rollback");

    expect(await late).toBe("ok");
    expect([await stepState(first.stepId), await stepState(second.stepId)]).toEqual(["prepared", "calling"]);
  });

  it("같은 단계를 두 연결이 같은 버전으로 begin_call하면 뒤의 쪽은 단계 잠금을 기다렸다가 stale", async () => {
    const step = await preparedStep(await newUser(), "send-1");

    await a.query("begin");
    expect(await beginCall(a, step, "fn-a")).toBe("ok");
    const late = beginCall(b, step, "fn-b");
    await waitForLockWait(bPid);
    await a.query("commit");

    expect(await late).toBe("stale");
    const { rows } = await setup.query<{ state: string; lease_owner: string }>("select state, lease_owner from public.execution_steps where id = $1", [step.stepId]);
    expect(rows[0]).toEqual({ state: "calling", lease_owner: "fn-a" });
  });
});
