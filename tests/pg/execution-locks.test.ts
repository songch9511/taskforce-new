import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

// 실행 코어의 잠금 경합 (docs/EXECUTION.md 6장 · 11장 한계). PGlite는 연결이 하나라 트랜잭션이 실제로 겹치지 않는다.
// 실제 Postgres에 연결 둘(A · B)을 열어, begin_call의 for share(스위치 · 실행 주체 · 도구 · 수신자 허용 목록) · intent unique ·
// 단계 for update(같은 단계 · 승인 철회)가 동시 commit에서 지키는 것을 본다.
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

type User = { userId: string; actionId: string; connectionId: string };

/** 시험 사용자 하나: Auto 정책(규칙 RULE), 실행 주체 허용 목록 안, 보내는 연결 · Action 하나 */
async function newUser(): Promise<User> {
  const userId = randomUUID();
  const actionId = randomUUID();
  await setup.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await setup.query("insert into public.actions (id, user_id, title) values ($1, $2, '견적서 보내기')", [actionId, userId]);
  await setup.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  await setup.query("insert into public.execution_policies (user_id, mode, auto_recipients) values ($1, 'auto', $2::jsonb)", [userId, JSON.stringify([RULE])]);
  const { rows } = await setup.query<{ id: string }>(
    "insert into public.connections (user_id, provider, external_account_id) values ($1, 'gmail', $2) returning id",
    [userId, `${userId}@example.com`],
  );
  return { userId, actionId, connectionId: rows[0].id };
}

/** 외부 단계(fake.send → RULE) 하나를 가진 run을 새로 만들고 prepared까지. 같은 Action · 목적이면 intent key가 같다.
 *  수신자 출처가 user가 아니면(origin) Auto 규칙을 충족하지 못해 승인이 필요하다 */
async function preparedStep(user: User, purpose: string, origin = "user") {
  const runId = randomUUID();
  await setup.query(
    `insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request)
     select $1, $2, $3, id, 'draft', '견적서 보내 줘' from public.execution_policies where user_id = $2`,
    [runId, user.userId, user.actionId],
  );
  const { rows } = await setup.query<{ id: string }>(
    `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, connection_id, recipients, body)
     values ($1, $2, 1, 'external', 'fake', 'send', $3, $4, $5::jsonb, '견적서 보내드립니다') returning id`,
    [user.userId, runId, purpose, user.connectionId, JSON.stringify([{ address: RULE, origin }])],
  );
  const stepId = rows[0].id;
  const prepared = await setup.query<{ ok: boolean }>("select public.prepare_step($1, 0) as ok", [stepId]);
  expect(prepared.rows[0].ok).toBe(true);
  return { stepId, version: 1 };
}

/** 내장 초안 단계(내부 효과, 추정치 estimate) 하나를 가진 run을 새로 만들고 prepared까지 */
async function preparedDraft(user: User, estimate: number) {
  const runId = randomUUID();
  await setup.query(
    `insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request)
     select $1, $2, $3, id, 'draft', '제안서 초안 써 줘' from public.execution_policies where user_id = $2`,
    [runId, user.userId, user.actionId],
  );
  const { rows } = await setup.query<{ id: string }>(
    `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose, estimate_credits)
     values ($1, $2, 1, 'draft', 'taskforce', 'draft', 'internal', 'draft', $3) returning id`,
    [user.userId, runId, estimate],
  );
  const prepared = await setup.query<{ ok: boolean }>("select public.prepare_step($1, 0) as ok", [rows[0].id]);
  expect(prepared.rows[0].ok).toBe(true);
  return { stepId: rows[0].id, version: 1 };
}

const userWithCredits = async (credits: number) => {
  const user = await newUser();
  await setup.query("select public.grant_credits($1, $2, gen_random_uuid())", [user.userId, credits]);
  return user;
};
const account = async (user: User) =>
  (await setup.query("select granted, reserved, settled from public.credit_accounts where user_id = $1", [user.userId])).rows[0];

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

  // 허용 목록 · 도구 목록도 스위치처럼 for share로 읽는다: 지우는 쪽은 진행 중인 전이를 기다리고, 지운 뒤에 commit되는 전이는 없다
  it.each([
    [
      "실행 주체",
      (user: User) => `delete from public.execution_actors where user_id = '${user.userId}'`,
      (user: User) => `insert into public.execution_actors (user_id) values ('${user.userId}') on conflict do nothing`,
      "actor",
    ],
    [
      "수신자 허용 목록",
      () => `delete from public.execution_recipient_allowlist where address = '${RULE}'`,
      () => `insert into public.execution_recipient_allowlist (address) values ('${RULE}') on conflict do nothing`,
      "recipient",
    ],
    [
      "도구 목록",
      () => "delete from public.execution_tools where provider = 'fake' and tool = 'send'",
      () => "insert into public.execution_tools (provider, tool, effect_class) values ('fake', 'send', 'external') on conflict do nothing",
      "tool",
    ],
  ] as [string, (user: User) => string, (user: User) => string, string][])(
    "%s에서 지우는 쪽은 진행 중인 begin_call이 commit될 때까지 기다리고, 먼저 지우면 begin_call이 기다렸다가 막힌다",
    async (_, remove, restore, gate) => {
      const user = await newUser();
      const first = await preparedStep(user, "send-1");
      const second = await preparedStep(user, "send-2");
      try {
        // begin_call이 먼저: 지우기는 그 commit을 기다린다. 전이는 남는다
        await a.query("begin");
        expect(await beginCall(a, first, "fn-a")).toBe("ok");
        const removal = b.query(remove(user));
        await waitForLockWait(bPid);
        await a.query("commit");
        await removal;
        expect(await stepState(first.stepId)).toBe("calling");
        await setup.query(restore(user));

        // 지우기가 먼저: begin_call은 기다렸다가 지워진 것을 보고 막는다
        await b.query("begin");
        await b.query(remove(user));
        const call = beginCall(a, second, "fn-a");
        await waitForLockWait(aPid);
        await b.query("commit");
        expect(await call).toBe(gate);
        expect(await stepState(second.stepId)).toBe("prepared");
      } finally {
        // 실패해도 다음 테스트를 위해 되돌린다 (열린 트랜잭션은 먼저 푼다)
        await a.query("rollback").catch(() => {});
        await b.query("rollback").catch(() => {});
        await setup.query(restore(user));
      }
    },
  );

  it("승인 철회가 먼저 단계를 잠그면 begin_call은 기다렸다가 철회된 승인을 보고 부르지 않는다", async () => {
    const user = await newUser();
    const step = await preparedStep(user, "send-1", "source");
    await approve(user, step.stepId);

    await b.query("begin");
    expect((await b.query("select * from public.revoke_approval($1, $2)", [user.userId, step.stepId])).rows).toEqual([{ revoked: 1, step_state: "prepared" }]);
    const call = beginCall(a, step, "fn-a");
    await waitForLockWait(aPid);
    await b.query("commit");

    expect(await call).toBe("not_approved");
    expect(await stepState(step.stepId)).toBe("prepared");
  });

  it("begin_call이 먼저면 승인 철회는 그 commit을 기다린 뒤, 이미 부르기 시작했다(calling)고 알린다", async () => {
    const user = await newUser();
    const step = await preparedStep(user, "send-1", "source");
    await approve(user, step.stepId);

    await a.query("begin");
    expect(await beginCall(a, step, "fn-a")).toBe("ok");
    const revoke = b.query("select * from public.revoke_approval($1, $2)", [user.userId, step.stepId]);
    await waitForLockWait(bPid);
    await a.query("commit");

    expect((await revoke).rows).toEqual([{ revoked: 1, step_state: "calling" }]);
  });
});

// 크레딧 원장(20261022000000_execution_credits_artifacts)의 잠금: 예약 · 정산 · 해제 · 지급은 모두 사용자의 계정 행을 for update로 잠그고 확인한다.
// 같은 사용자의 두 run이 동시에 예약해도 잔액을 넘지 않고, 같은 단계의 원가를 두 함수가 동시에 확정해도 정산은 한 번이다
describe("크레딧 원장 잠금 경합 (실제 Postgres, 연결 둘)", () => {
  it("같은 사용자의 두 run이 동시에 예약하면 뒤의 쪽은 계정 잠금을 기다렸다가 남은 잔액으로 판단한다: 잔액을 넘는 예약은 없다", async () => {
    const user = await userWithCredits(100);
    const first = await preparedDraft(user, 60);
    const second = await preparedDraft(user, 60);

    await a.query("begin");
    expect(await beginCall(a, first, "fn-a")).toBe("ok");
    const late = beginCall(b, second, "fn-b");
    await waitForLockWait(bPid);
    await a.query("commit");

    expect(await late).toBe("insufficient_credit");
    expect([await stepState(first.stepId), await stepState(second.stepId)]).toEqual(["calling", "prepared"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 60, settled: 0 });
    const { rows } = await setup.query("select step_id from public.credit_ledger where user_id = $1 and kind = 'reserve'", [user.userId]);
    expect(rows).toEqual([{ step_id: first.stepId }]);
  });

  it("앞의 예약이 rollback되면 기다리던 쪽이 그 잔액으로 예약한다", async () => {
    const user = await userWithCredits(100);
    const first = await preparedDraft(user, 60);
    const second = await preparedDraft(user, 60);

    await a.query("begin");
    expect(await beginCall(a, first, "fn-a")).toBe("ok");
    const late = beginCall(b, second, "fn-b");
    await waitForLockWait(bPid);
    await a.query("rollback");

    expect(await late).toBe("ok");
    expect([await stepState(first.stepId), await stepState(second.stepId)]).toEqual(["prepared", "calling"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 60, settled: 0 });
  });

  it("같은 단계의 미확정 원가 두 행을 두 연결이 동시에 확정해도 정산은 한 번이고, 뒤의 쪽이 앞의 확정을 보고 정산한다", async () => {
    const user = await userWithCredits(100);
    const step = await preparedDraft(user, 50);
    expect(await beginCall(setup, step, "fn-setup")).toBe("ok");
    // 비용이 응답에 없던 시도 둘 (generation 조회로 확정할 수 있다): 정산을 보류하고 예약을 둔다
    const attempts = [1, 2].map(() => ({ generationId: `gen-${randomUUID()}`, model: "m", usage: { prompt_tokens: 10, completion_tokens: 5 } }));
    const artifact = { title: "제안서 초안", body: "초안 본문", model: "m", prompt_version: "draft-v1" };
    const completed = await setup.query<{ ok: boolean }>(
      "select public.complete_internal_step($1, 'fn-setup', '{}', $2::jsonb, $3::jsonb, 'draft_ready') as ok",
      [step.stepId, JSON.stringify(attempts), JSON.stringify(artifact)],
    );
    expect(completed.rows[0].ok).toBe(true);
    expect(await account(user)).toEqual({ granted: 100, reserved: 50, settled: 0 });
    const usage = (await setup.query<{ id: string }>("select id from public.execution_usage where step_id = $1 order by id", [step.stepId])).rows;
    const reconcile = async (client: pg.Client, id: string, cost: number) =>
      (await client.query<{ ok: boolean }>("select public.reconcile_usage($1, $2) as ok", [id, cost])).rows[0].ok;

    await a.query("begin");
    expect(await reconcile(a, usage[0].id, 0.01)).toBe(true); // 다른 행이 아직 미확정이라 정산하지 않는다
    const late = reconcile(b, usage[1].id, 0.02); // 계정 잠금을 기다린다
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await late).toBe(true);

    const ledger = await setup.query("select kind, credits from public.credit_ledger where step_id = $1 order by id", [step.stepId]);
    expect(ledger.rows).toEqual([
      { kind: "reserve", credits: 50 },
      { kind: "settle", credits: 30 },
      { kind: "release", credits: 20 },
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 30 });
  });
});

// 이벤트 기록 트리거는 소유자 권한(security definer)으로 돈다: 서버가 아닌 역할이 연결을 지워(set null) 단계가 다시 계획돼도
// 그 역할에 execution_events 권한이 없어 실패하지 않는다. Supabase Auth의 계정 삭제(supabase_auth_admin)도 같은 길이다.
// PGlite에서는 이 권한 문제가 드러나지 않아 실제 Postgres로 본다.
describe("서버가 아닌 역할의 삭제가 단계를 다시 계획할 때 (실제 Postgres)", () => {
  it("supabase_auth_admin이 연결 · 계정을 지워도 실패하지 않고, 다시 계획된 단계의 이벤트가 남는다", async () => {
    await setup.query(`
      grant select, delete on public.connections to supabase_auth_admin;
      create policy "auth_admin_select_test" on public.connections for select to supabase_auth_admin using (true);
      create policy "auth_admin_delete_test" on public.connections for delete to supabase_auth_admin using (true);
      grant usage on schema auth to supabase_auth_admin; -- Supabase에서는 supabase_auth_admin이 auth 스키마 · users의 소유자다
      grant select, delete on auth.users to supabase_auth_admin;
    `);
    const user = await newUser();
    const step = await preparedStep(user, "send-1");

    await setup.query("set role supabase_auth_admin");
    try {
      const deleted = await setup.query("delete from public.connections where id = $1", [user.connectionId]);
      expect(deleted.rowCount).toBe(1);
    } finally {
      await setup.query("reset role");
    }
    const { rows } = await setup.query<{ state: string; connection_id: string | null }>(
      "select state, connection_id from public.execution_steps where id = $1",
      [step.stepId],
    );
    expect(rows[0]).toEqual({ state: "pending", connection_id: null });
    const events = await setup.query("select 1 from public.execution_events where step_id = $1 and from_state = 'prepared' and to_state = 'pending'", [step.stepId]);
    expect(events.rowCount).toBe(1);

    // 계정 삭제: 연결 · run · 단계 · 이벤트가 cascade로 함께 지워진다. 원장 · 원가의 run · step 외래키는 지울 때 막지만(no action)
    // 같은 문장 안에서 원장도 auth.users cascade로 지워져 막히지 않는다
    const other = await userWithCredits(100);
    await preparedStep(other, "send-1");
    const draft = await preparedDraft(other, 40);
    expect(await beginCall(setup, draft, "fn-setup")).toBe("ok");
    await setup.query("select public.record_usage($1, $2::jsonb)", [draft.stepId, JSON.stringify([{ generationId: null, model: "m" }])]);
    await setup.query("set role supabase_auth_admin");
    try {
      expect((await setup.query("delete from auth.users where id = $1", [other.userId])).rowCount).toBe(1);
    } finally {
      await setup.query("reset role");
    }
    for (const table of ["execution_runs", "credit_accounts", "credit_ledger", "execution_usage"]) {
      expect((await setup.query(`select 1 from public.${table} where user_id = $1`, [other.userId])).rowCount, table).toBe(0);
    }
  });
});

/** route: 사용자가 본 계획 그대로 승인 */
async function approve(user: User, stepId: string) {
  const shown = (await setup.query<{ hash: string; expires_at: Date }>("select * from public.show_plan($1, $2)", [user.userId, stepId])).rows[0];
  const { rows } = await setup.query<{ ok: boolean }>("select public.approve_step($1, $2, $3, $4) as ok", [user.userId, stepId, shown.hash, shown.expires_at]);
  expect(rows[0].ok).toBe(true);
}
