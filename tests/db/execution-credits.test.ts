import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 산출물 · 크레딧 원장 · AI 원가(20261022000000_execution_credits_artifacts, docs/EXECUTION.md 12장, A45 · A46 · A51).
// 실행기(U2 PR6)가 부를 순서 그대로 SQL을 부른다: 지급 → run → 계획 단계 → 초안 단계(begin_call 예약 → complete_internal_step 정산).
// 동시 commit 경합(두 run의 예약 · 같은 단계 원가의 동시 확정)은 연결이 하나인 PGlite로 볼 수 없어 tests/pg/execution-locks.test.ts가 본다.

const MIGRATION = path.resolve(__dirname, "../../supabase/migrations/20261022000000_execution_credits_artifacts.sql");

// 테스트 시계 (tests/execution/driver.ts와 같은 판): 마이그레이션을 적용한 뒤 테스트 안에서만 바꾼다. app.now가 비면 now()
const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;

const ARTIFACT = { title: "제안서 초안", body: "안녕하세요, 지난 회의에서 말씀드린 제안서를 보내드립니다.", model: "z-ai/glm-5.3-flash", prompt_version: "draft-v1" };

let db: PGlite;

const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
const count = async (sql: string, params: unknown[] = []) => (await one<{ n: number }>(`select count(*)::int as n from (${sql}) x`, params)).n;

type Attempt = { generationId: string | null; model: string; usage?: { prompt_tokens: number; completion_tokens: number; cost?: number } };
/** llm.ts LlmAttempt 한 건. cost를 주지 않으면 비용을 모르는 시도, id가 null이면 응답을 받지 못한 시도(시간 초과) */
const attempt = (cost?: number, generationId: string | null = `gen-${randomUUID()}`): Attempt => ({
  generationId,
  model: "z-ai/glm-5.3-flash",
  ...(generationId === null ? {} : { usage: { prompt_tokens: 1200, completion_tokens: 400, ...(cost === undefined ? {} : { cost }) } }),
});

async function newUser(credits = 0) {
  const userId = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await db.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  if (credits) expect(await grant(userId, credits)).toBe(true);
  return userId;
}

const grant = async (userId: string, credits: number, grantId: string = randomUUID()) =>
  (await one<{ ok: boolean }>("select public.grant_credits($1, $2, $3) as ok", [userId, credits, grantId])).ok;
const account = (userId: string) =>
  one<{ granted: number; reserved: number; settled: number }>("select granted, reserved, settled from public.credit_accounts where user_id = $1", [userId]);
const ledger = async (userId: string) =>
  (
    await db.query<{ kind: string; credits: number; receipt_key: string; rate_version: string | null; cost_usd: string | null }>(
      "select kind, credits, receipt_key, rate_version, cost_usd from public.credit_ledger where user_id = $1 order by id",
      [userId],
    )
  ).rows;
const runState = (runId: string) => one<{ state: string; hold_reason: string | null; outcome: string | null }>(
  "select state, hold_reason, outcome from public.execution_runs where id = $1",
  [runId],
);

/** 단계를 준비하고(pending이면) 지금 버전으로 begin_call */
async function gate(stepId: string, owner = "fn-1") {
  const step = await one<{ state: string; version: number }>("select state, version from public.execution_steps where id = $1", [stepId]);
  let version = step.version;
  if (step.state === "pending") {
    expect((await one<{ ok: boolean }>("select public.prepare_step($1, $2) as ok", [stepId, version])).ok).toBe(true);
    version += 1;
  }
  return (await one<{ g: Record<string, unknown> }>("select public.begin_call($1, $2, $3) as g", [stepId, owner, version])).g;
}

const complete = async (stepId: string, attempts: Attempt[], artifact: object | null = null, outcome: string | null = null, owner = "fn-1") =>
  (
    await one<{ ok: boolean }>("select public.complete_internal_step($1, $2, '{}', $3::jsonb, $4::jsonb, $5) as ok", [
      stepId,
      owner,
      JSON.stringify(attempts),
      artifact === null ? null : JSON.stringify(artifact),
      outcome,
    ])
  ).ok;

/**
 * 실행기 흐름으로 초안 단계 앞까지: run(예산 선택) → 계획 단계 부르기 → planner가 초안 단계들을 붙이고 계획 단계를 끝냄.
 * 초안 단계는 pending (begin_call 전이라 예약 없음)
 */
async function draftRun(userId: string, estimates: number[], budget: number | null = null) {
  const actionId = (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, '제안서 보내기') returning id", [userId])).id;
  const runId = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '제안서 초안 써 줘', $3) as id", [userId, actionId, budget])).id;
  const planId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1 and seq = 1", [runId])).id;
  expect((await gate(planId)).gate).toBe("ok");
  const drafts: string[] = [];
  for (const [i, estimate] of estimates.entries()) {
    const step = { kind: "draft", provider: "taskforce", tool: "draft", purpose: `draft-${i + 1}`, estimate_credits: estimate };
    drafts.push((await one<{ id: string }>("select public.append_step($1, $2, $3::jsonb) as id", [runId, i + 2, JSON.stringify(step)])).id);
  }
  expect(await complete(planId, [attempt(0.0007)])).toBe(true);
  return { runId, planId, actionId, drafts };
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(TEST_CLOCK);
  // 처음 상태는 전체 스위치가 막혀 있다 (execution-core.test.ts). 여기서는 크레딧만 본다
  await db.query("update public.execution_controls set blocked = false where scope = 'global'");
}, 60_000);

describe("처음 상태", () => {
  it("요율은 c3-v1 하나(1 크레딧 = $0.001, 원가를 크레딧에 1:1로 옮기지 않는다), 계정 · 원장 · 원가 · 산출물은 비어 있다", async () => {
    expect((await db.query("select version, usd_per_credit::text as usd, active from public.credit_rates")).rows).toEqual([{ version: "c3-v1", usd: "0.001", active: true }]);
    for (const table of ["credit_accounts", "credit_ledger", "execution_usage", "execution_artifacts"]) {
      expect(await count(`select 1 from public.${table}`), table).toBe(0);
    }
    // 지금 쓰는 요율은 하나뿐이다
    await expect(db.query("insert into public.credit_rates (version, usd_per_credit, active) values ('x', 0.002, true)")).rejects.toThrow(/duplicate key/);
  });
});

describe("운영자 지급 (grant_credits)", () => {
  it("지급 id마다 한 번이고, 같은 id로 다른 지급은 오류, 음수는 회수(adjust), 예약 · 정산된 만큼은 회수할 수 없다", async () => {
    const user = await newUser();
    const id = randomUUID();
    expect(await grant(user, 100, id)).toBe(true);
    expect(await grant(user, 100, id)).toBe(false); // 같은 지급을 다시 적용해도 한 번
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 0 });
    await expect(grant(user, 50, id)).rejects.toThrow(/이미 다른 지급/);
    await expect(grant(await newUser(), 100, id)).rejects.toThrow(/이미 다른 지급/);
    await expect(grant(user, 0)).rejects.toThrow(/잘못된 인자/);

    expect(await grant(user, -30)).toBe(true);
    expect(await account(user)).toEqual({ granted: 70, reserved: 0, settled: 0 });
    expect((await ledger(user)).map((l) => [l.kind, l.credits, l.receipt_key.startsWith("grant:")])).toEqual([
      ["grant", 100, true],
      ["adjust", -30, true],
    ]);
    expect((await ledger(user))[0].receipt_key).toBe(`grant:${id}`);

    // 70 중 60을 예약하면 남은 10보다 많이는 회수하지 못한다
    const { drafts } = await draftRun(user, [60]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    await expect(grant(user, -11)).rejects.toThrow(/credit_accounts_balance/);
    expect(await grant(user, -10)).toBe(true);
    expect(await account(user)).toEqual({ granted: 60, reserved: 60, settled: 0 });
  });
});

describe("예약 (begin_call)", () => {
  it("추정치가 0인 단계(계획)는 예약하지 않고, 계정이 없어도 부른다", async () => {
    const user = await newUser();
    await draftRun(user, []);
    expect(await account(user)).toBeUndefined();
    expect(await ledger(user)).toEqual([]);
  });

  it("가용이 모자라면 부르지 않는다: insufficient_credit, 단계는 prepared, run에 이유 credit(바뀔 때만 이벤트). 지급 뒤 다시 부르면 예약 1", async () => {
    const user = await newUser(20);
    const { runId, drafts } = await draftRun(user, [30]);
    for (let i = 0; i < 3; i++) expect(await gate(drafts[0])).toEqual({ gate: "insufficient_credit" });
    expect(await one("select state from public.execution_steps where id = $1", [drafts[0]])).toEqual({ state: "prepared" });
    expect(await runState(runId)).toEqual({ state: "running", hold_reason: "credit", outcome: null });
    expect(await count("select 1 from public.execution_events where run_id = $1 and type = 'hold' and to_state = 'credit'", [runId])).toBe(1);
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["grant"]);

    expect(await grant(user, 10)).toBe(true);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await runState(runId)).toEqual({ state: "running", hold_reason: null, outcome: null });
    expect(await account(user)).toEqual({ granted: 30, reserved: 30, settled: 0 });
    expect((await ledger(user)).at(-1)).toEqual({ kind: "reserve", credits: 30, receipt_key: `reserve:${drafts[0]}`, rate_version: "c3-v1", cost_usd: null });
  });

  it("두 run이 같은 잔액을 두고 예약하면 잔액을 넘는 예약은 없다 (동시 commit은 tests/pg)", async () => {
    const user = await newUser(100);
    const first = await draftRun(user, [60]);
    const second = await draftRun(user, [60]);
    expect((await gate(first.drafts[0])).gate).toBe("ok");
    expect((await gate(second.drafts[0])).gate).toBe("insufficient_credit");
    expect(await account(user)).toEqual({ granted: 100, reserved: 60, settled: 0 });
  });

  it("run 예산: 예약 - 해제(= 정산 + 남은 예약)를 넘는 단계는 막고, 정산하고 해제한 만큼은 다시 쓸 수 있다", async () => {
    const user = await newUser(1000);
    const over = await draftRun(user, [60], 50);
    expect((await gate(over.drafts[0])).gate).toBe("insufficient_credit");
    expect((await runState(over.runId)).hold_reason).toBe("credit");

    const { runId, drafts } = await draftRun(user, [30, 45], 50);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await complete(drafts[0], [attempt(0.01)], ARTIFACT)).toBe(true); // 10 정산 · 20 해제 → 쓴 예산 10
    expect((await runState(runId)).state).toBe("running"); // 다음 초안 단계가 남았다
    expect((await gate(drafts[1])).gate).toBe("insufficient_credit"); // 45 > 50 - 10
    await db.query("update public.execution_steps set estimate_credits = 40 where id = $1", [drafts[1]]);
    expect((await gate(drafts[1])).gate).toBe("ok");
    expect(await account(user)).toEqual({ granted: 1000, reserved: 40, settled: 10 });
  });

  it("청구 대상인 초안 단계는 추정치가 있어야 부른다 (추정치 0이면 no_estimate)", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [0]);
    expect(await gate(drafts[0])).toEqual({ gate: "no_estimate" });
    expect((await runState(runId)).hold_reason).toBe("credit");
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["grant"]);
  });

  it("지금 쓰는 요율이 없으면 새 유료 단계를 보류한다 (no_rate)", async () => {
    const user = await newUser(100);
    const { drafts } = await draftRun(user, [10]);
    await db.query("update public.credit_rates set active = false");
    try {
      expect(await gate(drafts[0])).toEqual({ gate: "no_rate" });
    } finally {
      await db.query("update public.credit_rates set active = true where version = 'c3-v1'");
    }
    expect((await gate(drafts[0])).gate).toBe("ok");
  });

  it("이미 정산 · 해제된 예약으로는 다시 부르지 않는다 (reservation_closed)", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [40]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await one("select public.mark_unknown($1, 'fn-1') as ok", [drafts[0]])).toEqual({ ok: true });
    // 계약 밖에서 예약이 닫혔다 (해제 행)
    await db.query("insert into public.credit_ledger (user_id, kind, credits, run_id, step_id, receipt_key) values ($1, 'release', 40, $2, $3, $4)", [
      user,
      runId,
      drafts[0],
      `release:${drafts[0]}`,
    ]);
    await db.query("update public.credit_accounts set reserved = reserved - 40 where user_id = $1", [user]);
    expect(await gate(drafts[0], "fn-2")).toEqual({ gate: "reservation_closed" });
    expect(await one("select state from public.execution_steps where id = $1", [drafts[0]])).toEqual({ state: "prepared" });
  });

  it("같은 단계의 재시도(내부 효과 다시 준비)는 처음 예약을 그대로 쓰고(reserve 하나), 한도를 넘겨 실패하면 run이 끝나며 해제한다", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [40]);
    const step = drafts[0];
    for (let i = 0; i < 3; i++) {
      expect((await gate(step, `fn-${i}`)).gate).toBe("ok");
      expect(await account(user)).toEqual({ granted: 100, reserved: 40, settled: 0 });
      // 응답 없이 끝난 호출: 시도는 플랫폼 원가로 남기고, 다시 준비(한도 2번 뒤 failed)
      expect((await one<{ n: number }>("select public.record_usage($1, $2::jsonb) as n", [step, JSON.stringify([attempt(undefined, null)])])).n).toBe(1);
      expect((await one<{ ok: boolean }>("select public.mark_unknown($1, $2) as ok", [step, `fn-${i}`])).ok).toBe(true);
    }
    expect(await one("select state, attempt from public.execution_steps where id = $1", [step])).toEqual({ state: "failed", attempt: 2 });
    expect((await runState(runId)).state).toBe("failed");
    expect((await ledger(user)).map((l) => [l.kind, l.credits])).toEqual([
      ["grant", 100],
      ["reserve", 40],
      ["release", 40],
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 0 });
    // 잃은 시도 셋은 원가로 남는다: 미확정(0원이 아니다), 청구 대상 아님
    const usage = await db.query("select cost_usd, cost_status, billable from public.execution_usage where step_id = $1", [step]);
    expect(usage.rows).toEqual(Array(3).fill({ cost_usd: null, cost_status: "unconfirmed", billable: false }));
  });
});

describe("정산 (complete_internal_step)", () => {
  it("산출물 · 원가 행(다시 물은 시도까지) · 정산을 한 번에: 확정 원가 합 × 요율(올림), 예약 상한 안, 나머지 해제. 두 번 불러도 한 번", async () => {
    const user = await newUser(100);
    const { runId, planId, actionId, drafts } = await draftRun(user, [50]);
    const step = drafts[0];
    const g = await gate(step);
    expect(g.gate).toBe("ok");

    // 형식이 깨져 다시 물은 시도 + 답을 받은 시도: 둘 다 원가이고 둘 다 청구 대상이다 (마지막 시도의 usage.cost만이 아니다)
    const attempts = [attempt(0.0123), attempt(0.004)];
    expect(await complete(step, attempts, ARTIFACT, "draft_ready", "fn-other")).toBe(false); // lease 소유자만
    expect(await complete(step, attempts, ARTIFACT, "draft_ready")).toBe(true);
    expect(await complete(step, attempts, ARTIFACT, "draft_ready")).toBe(false); // 응답 뒤 쓰기를 다시 해도

    // 0.0163 USD / 0.001 = 16.3 → 17 크레딧, 남은 33 해제
    expect((await ledger(user)).map((l) => [l.kind, l.credits, l.receipt_key, l.rate_version, l.cost_usd])).toEqual([
      ["grant", 100, expect.stringMatching(/^grant:/), null, null],
      ["reserve", 50, `reserve:${step}`, "c3-v1", null],
      ["settle", 17, `settle:${step}`, "c3-v1", "0.0163"],
      ["release", 33, `release:${step}`, null, null],
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 17 });
    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" });

    const usage = await db.query<{ step_id: string; generation_id: string; cost_usd: string; cost_status: string; billable: boolean; prompt_tokens: number }>(
      "select step_id, generation_id, cost_usd::text, cost_status, billable, prompt_tokens from public.execution_usage where run_id = $1 order by id",
      [runId],
    );
    expect(usage.rows.map((u) => [u.step_id, u.cost_usd, u.cost_status, u.billable, u.prompt_tokens])).toEqual([
      [planId, "0.0007", "confirmed", false, 1200], // 계획 단계는 플랫폼 원가
      [step, "0.0123", "confirmed", true, 1200],
      [step, "0.004", "confirmed", true, 1200],
    ]);
    expect(usage.rows.slice(1).map((u) => u.generation_id)).toEqual(attempts.map((a) => a.generationId));

    const artifact = await one<Record<string, unknown>>(
      `select a.action_id, a.kind, a.title, a.body, a.model, a.prompt_version, a.marker = i.marker as marker_is_intent,
              a.retain_until - a.created_at as retention, a.body_purged_at
       from public.execution_artifacts a join public.execution_intents i on i.step_id = a.step_id where a.step_id = $1`,
      [step],
    );
    expect(artifact).toEqual({
      action_id: actionId,
      kind: "draft",
      title: ARTIFACT.title,
      body: ARTIFACT.body,
      model: ARTIFACT.model,
      prompt_version: ARTIFACT.prompt_version,
      marker_is_intent: true,
      retention: "90 days",
      body_purged_at: null,
    });
    expect(g.marker).toBe((await one<{ marker: string }>("select marker from public.execution_artifacts where step_id = $1", [step])).marker);
  });

  it("확정 원가가 예약보다 크면 예약만큼만 정산하고(넘친 원가는 플랫폼 몫) 해제는 없다", async () => {
    const user = await newUser(100);
    const { drafts } = await draftRun(user, [5]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await complete(drafts[0], [attempt(0.02)], ARTIFACT, "draft_ready")).toBe(true);
    expect((await ledger(user)).slice(1).map((l) => [l.kind, l.credits, l.cost_usd])).toEqual([
      ["reserve", 5, null],
      ["settle", 5, "0.02"],
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 5 });
  });

  it("같은 generation id는 한 번만 남는다 (중복 영수증)", async () => {
    const user = await newUser(100);
    const { planId, drafts } = await draftRun(user, [10]);
    const repeated = attempt(0.001);
    expect((await one<{ n: number }>("select public.record_usage($1, $2::jsonb) as n", [planId, JSON.stringify([repeated, repeated])])).n).toBe(1);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await complete(drafts[0], [repeated, attempt(0.002)], ARTIFACT, "draft_ready")).toBe(true);
    expect(await count("select 1 from public.execution_usage where generation_id = $1", [repeated.generationId])).toBe(1);
    // 먼저 남은 행(계획 단계 · 플랫폼 원가)이 그대로라 초안 청구에는 0.002만 들어간다
    expect((await ledger(user)).find((l) => l.kind === "settle")).toMatchObject({ credits: 2, cost_usd: "0.002" });
  });

  it("초안 단계는 산출물 · 시도 기록과 함께, 계획 단계는 산출물 없이만 끝내고, 외부 단계는 끝내지 않는다", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [10]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    await expect(complete(drafts[0], [attempt(0.001)], null)).rejects.toThrow(/산출물과 함께/);
    await expect(complete(drafts[0], [], ARTIFACT)).rejects.toThrow(/시도 기록이 없다/);
    await expect(complete(drafts[0], [attempt(0.001)], { ...ARTIFACT, body: null })).rejects.toThrow(/not-null/);
    await expect(db.query("select public.complete_internal_step($1, 'fn-1', '{}', '{}'::jsonb, $2::jsonb)", [drafts[0], JSON.stringify(ARTIFACT)])).rejects.toThrow(
      /배열/,
    );
    expect(await one("select state from public.execution_steps where id = $1", [drafts[0]])).toEqual({ state: "calling" });
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [runId])).toBe(0);

    // 계획 단계는 산출물 없이 끝낸다
    const action = (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, '다른 할 일') returning id", [user])).id;
    const fresh = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '초안') as id", [user, action])).id;
    const planStep = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1", [fresh])).id;
    expect((await gate(planStep)).gate).toBe("ok");
    await expect(complete(planStep, [attempt(0.001)], ARTIFACT)).rejects.toThrow(/산출물 없이/);

    // 외부 단계는 settle_step으로 끝낸다
    const external = await one<{ id: string }>(
      `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, state, policy_version, lease_owner)
       values ($1, $2, 2, 'external', 'gmail', 'send', 'send', 'calling', 1, 'fn-1') returning id`,
      [user, fresh],
    );
    await expect(complete(external.id, [attempt(0.001)])).rejects.toThrow(/내부 효과 단계가 아니다/);
  });
});

describe("미확정 원가 (A46 · A51)", () => {
  const reconcile = async (id: string, cost: number) => (await one<{ ok: boolean }>("select public.reconcile_usage($1, $2) as ok", [id, cost])).ok;
  const usageOf = async (step: string) =>
    (
      await db.query<{ id: string; generation_id: string | null; cost_usd: string | null; cost_status: string; billable: boolean }>(
        "select id, generation_id, cost_usd, cost_status, billable from public.execution_usage where step_id = $1 order by id",
        [step],
      )
    ).rows;

  it("청구 대상 시도의 비용을 모르면 정산하지 않고 예약을 둔다(0원 처리 · 해제 없음, run이 끝나도). 모두 확정되면 정산하고, 같은 확정은 한 번", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [50]);
    const step = drafts[0];
    expect((await gate(step)).gate).toBe("ok");
    // 비용이 응답에 없던 시도 둘 (generation 조회로 확정할 수 있다)
    const first = attempt();
    const second = attempt();
    expect(await complete(step, [first, second], ARTIFACT, "draft_ready")).toBe(true);

    expect(await runState(runId)).toEqual({ state: "done", hold_reason: null, outcome: "draft_ready" }); // 산출물은 쓸 수 있다
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["grant", "reserve"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 50, settled: 0 });
    const rows = await usageOf(step);
    expect(rows.map((r) => [r.generation_id, r.cost_usd, r.cost_status, r.billable])).toEqual([
      [first.generationId, null, "unconfirmed", true],
      [second.generationId, null, "unconfirmed", true],
    ]);
    // 끝난 run의 예약 해제를 다시 불러도 끝낸 단계(called)의 미확정 예약은 그대로다
    expect(await one("select public.release_run_credits($1) as n", [runId])).toEqual({ n: 0 });
    expect(await one("select public.release_run_credits() as n")).toEqual({ n: 0 });
    expect(await account(user)).toEqual({ granted: 100, reserved: 50, settled: 0 });

    await expect(reconcile(rows[0].id, -1)).rejects.toThrow(/잘못된 비용/);
    expect(await reconcile(rows[0].id, 0.004)).toBe(true); // sweep: generation 조회
    expect(await reconcile(rows[0].id, 0.004)).toBe(false); // 같은 확정을 다시 받아도
    expect(await account(user)).toEqual({ granted: 100, reserved: 50, settled: 0 }); // 둘째 시도가 아직 미확정

    expect(await reconcile(rows[1].id, 0.0021)).toBe(true);
    expect((await ledger(user)).slice(1).map((l) => [l.kind, l.credits, l.cost_usd])).toEqual([
      ["reserve", 50, null],
      ["settle", 7, "0.0061"],
      ["release", 43, null],
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 7 });
  });

  it("응답을 받지 못한(generation id 없는) 시도는 청구 근거가 없어 플랫폼 원가(미확정)로 남고, 정산은 확인된 시도로 한다", async () => {
    const user = await newUser(100);
    const { drafts } = await draftRun(user, [50]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    // 시간 초과 뒤 다시 물어 받은 답 (llm.ts는 시간 초과도 다시 묻는다)
    const answered = attempt(0.003);
    expect(await complete(drafts[0], [attempt(undefined, null), answered], ARTIFACT, "draft_ready")).toBe(true);
    expect((await usageOf(drafts[0])).map((r) => [r.generation_id, r.cost_usd, r.cost_status, r.billable])).toEqual([
      [null, null, "unconfirmed", false],
      [answered.generationId, "0.003", "confirmed", true],
    ]);
    expect((await ledger(user)).slice(1).map((l) => [l.kind, l.credits])).toEqual([
      ["reserve", 50],
      ["settle", 3],
      ["release", 47],
    ]);
  });

  it("끝내지 않은 단계(다시 준비 중)의 원가를 확정해도 정산 · 해제하지 않는다: 재시도가 그 예약을 그대로 쓴다", async () => {
    const user = await newUser(100);
    const { drafts } = await draftRun(user, [40]);
    const step = drafts[0];
    expect((await gate(step, "fn-a")).gate).toBe("ok");
    // 응답 없이 끝난 호출: 비용 없는 시도를 원가로 남기고 다시 준비
    expect((await one<{ n: number }>("select public.record_usage($1, $2::jsonb) as n", [step, JSON.stringify([attempt()])])).n).toBe(1);
    expect(await one("select public.mark_unknown($1, 'fn-a') as ok", [step])).toEqual({ ok: true });
    expect(await reconcile((await usageOf(step))[0].id, 0.002)).toBe(true); // sweep이 그 사이에 확정
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["grant", "reserve"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 40, settled: 0 });

    // 예약이 잡혀 있어 다른 run이 그 잔액을 쓰지 못한다
    const other = await draftRun(user, [70]);
    expect(await gate(other.drafts[0])).toEqual({ gate: "insufficient_credit" });
    expect((await gate(step, "fn-b")).gate).toBe("ok"); // 재시도는 열린 예약을 쓴다
    expect(await complete(step, [attempt(0.01)], ARTIFACT, "draft_ready", "fn-b")).toBe(true);
    expect((await ledger(user)).slice(1).map((l) => [l.kind, l.credits, l.cost_usd])).toEqual([
      ["reserve", 40, null],
      ["settle", 10, "0.01"], // 앞 호출의 원가는 플랫폼 몫
      ["release", 30, null],
    ]);
  });

  it("초안 단계를 원가 기록 없이 끝냈으면(complete_internal_step을 거치지 않음) 원가를 모르는 것이라 정산하지 않는다", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [40]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await one("select public.settle_step($1, 'fn-1', 'called', '{}', 'draft_ready') as ok", [drafts[0]])).toEqual({ ok: true });
    expect((await runState(runId)).state).toBe("done");
    expect((await ledger(user)).map((l) => l.kind)).toEqual(["grant", "reserve"]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 40, settled: 0 });
  });
});

describe("해제", () => {
  it("실패한 단계의 예약은 run이 끝나며 해제한다. 실패한 호출의 시도는 플랫폼 원가로 남는다", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [40]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect((await one<{ n: number }>("select public.record_usage($1, $2::jsonb) as n", [drafts[0], JSON.stringify([attempt(0.003)])])).n).toBe(1);
    expect(await one("select public.settle_step($1, 'fn-1', 'failed', '{\"error\": \"output\"}') as ok", [drafts[0]])).toEqual({ ok: true });
    expect((await runState(runId)).state).toBe("failed");
    expect((await ledger(user)).slice(1).map((l) => [l.kind, l.credits])).toEqual([
      ["reserve", 40],
      ["release", 40],
    ]);
    expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 0 });
    expect(await one("select cost_usd::text, cost_status, billable from public.execution_usage where step_id = $1", [drafts[0]])).toEqual({
      cost_usd: "0.003",
      cost_status: "confirmed",
      billable: false,
    });
  });

  it("중단: 부르기 전이면 예약 자체가 없고, 부르는 중이면 해제하지 않고 결과를 받아 정산하고, 다시 준비한 단계는 해제한다", async () => {
    const user = await newUser(200);
    const before = await draftRun(user, [40]);
    expect(await one("select public.stop_run($1, $2) as s", [user, before.runId])).toEqual({ s: "stopped" });
    expect(await count("select 1 from public.credit_ledger where run_id = $1", [before.runId])).toBe(0);

    const calling = await draftRun(user, [40]);
    expect((await gate(calling.drafts[0])).gate).toBe("ok");
    expect(await one("select public.stop_run($1, $2) as s", [user, calling.runId])).toEqual({ s: "stopped" });
    expect(await account(user)).toEqual({ granted: 200, reserved: 40, settled: 0 }); // 부르는 중이라 그대로
    expect(await complete(calling.drafts[0], [attempt(0.01)], ARTIFACT, "draft_ready")).toBe(true); // 진행 중 호출은 결과를 받는다
    expect(await runState(calling.runId)).toEqual({ state: "stopped", hold_reason: null, outcome: null });
    expect(await account(user)).toEqual({ granted: 200, reserved: 0, settled: 10 });
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [calling.runId])).toBe(1);

    const retried = await draftRun(user, [40]);
    expect((await gate(retried.drafts[0])).gate).toBe("ok");
    expect(await one("select public.mark_unknown($1, 'fn-1') as ok", [retried.drafts[0]])).toEqual({ ok: true }); // prepared, 예약은 그대로
    expect(await account(user)).toEqual({ granted: 200, reserved: 40, settled: 10 });
    expect(await one("select public.stop_run($1, $2) as s", [user, retried.runId])).toEqual({ s: "stopped" });
    expect(await account(user)).toEqual({ granted: 200, reserved: 0, settled: 10 });
    expect(await one("select public.release_run_credits($1) as n", [retried.runId])).toEqual({ n: 0 }); // 다시 불러도 두 번 해제하지 않는다

    // 멈춘 뒤 부르던 단계가 끝내지 못하고 나오면(응답 없음 → 다시 준비, 확정 거절 → failed) 그때 해제한다
    for (const exit of ["select public.mark_unknown($1, 'fn-1')", "select public.settle_step($1, 'fn-1', 'failed', '{}')"]) {
      const late = await draftRun(user, [40]);
      expect((await gate(late.drafts[0])).gate).toBe("ok");
      expect(await one("select public.stop_run($1, $2) as s", [user, late.runId])).toEqual({ s: "stopped" });
      expect(await account(user)).toEqual({ granted: 200, reserved: 40, settled: 10 });
      await db.query(exit, [late.drafts[0]]);
      expect(await runState(late.runId)).toMatchObject({ state: "stopped" });
      expect(await account(user)).toEqual({ granted: 200, reserved: 0, settled: 10 });
    }
  });

  it("멈춘 run에서 부르던 외부 단계가 나중에 끝나면(응답 · readback) 그때 정산 · 해제하고, 결과 불명인 동안은 예약을 둔다", async () => {
    await db.query("insert into public.execution_tools (provider, tool, effect_class) values ('fake', 'send', 'external') on conflict do nothing");
    await db.query("insert into public.execution_controls (scope, key, blocked) values ('provider', 'fake', false) on conflict (scope, key) do update set blocked = false");
    await db.query("insert into public.execution_recipient_allowlist (address) values ('rule@example.com') on conflict do nothing");
    for (const finish of ["response", "readback"]) {
      const user = await newUser(100);
      const connection = (
        await one<{ id: string }>("insert into public.connections (user_id, provider, external_account_id) values ($1, 'gmail', $2) returning id", [
          user,
          `${user}@example.com`,
        ])
      ).id;
      const { runId } = await draftRun(user, []);
      const send = {
        kind: "external", provider: "fake", tool: "send", purpose: "send", connection_id: connection,
        recipients: [{ address: "rule@example.com", origin: "user" }], body: "견적서 보내드립니다", estimate_credits: 20,
      };
      const step = (await one<{ id: string }>("select public.append_step($1, 2, $2::jsonb) as id", [runId, JSON.stringify(send)])).id;
      expect(await one("select public.prepare_step($1, 0) as ok", [step])).toEqual({ ok: true });
      const shown = await one<{ hash: string; expires_at: Date }>("select * from public.show_plan($1, $2)", [user, step]);
      expect(await one("select public.approve_step($1, $2, $3, $4) as ok", [user, step, shown.hash, shown.expires_at])).toEqual({ ok: true });
      expect((await gate(step)).gate).toBe("ok");
      expect(await one("select public.stop_run($1, $2) as s", [user, runId])).toEqual({ s: "stopped" });
      expect(await account(user)).toEqual({ granted: 100, reserved: 20, settled: 0 });

      if (finish === "response") {
        expect(await one("select public.settle_step($1, 'fn-1', 'called', '{\"id\": 1}') as ok", [step])).toEqual({ ok: true });
      } else {
        expect(await one("select public.mark_unknown($1, 'fn-1') as ok", [step])).toEqual({ ok: true });
        expect(await account(user)).toEqual({ granted: 100, reserved: 20, settled: 0 }); // 결과 불명: 둔다
        expect(await one("select public.readback_settle($1, '{\"id\": 1}') as ok", [step])).toEqual({ ok: true });
      }
      // 외부 단계는 청구 대상 AI 원가가 없어 0 정산 · 나머지 해제
      expect((await ledger(user)).slice(1).map((l) => [l.kind, l.credits])).toEqual([
        ["reserve", 20],
        ["settle", 0],
        ["release", 20],
      ]);
      expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 0 });
    }
  });

  it("잔액이 0이면 새 단계는 부르지 않고, 이미 만든 산출물은 그대로다", async () => {
    const user = await newUser(17);
    const first = await draftRun(user, [17]);
    expect((await gate(first.drafts[0])).gate).toBe("ok");
    expect(await complete(first.drafts[0], [attempt(0.017)], ARTIFACT, "draft_ready")).toBe(true);
    expect(await account(user)).toEqual({ granted: 17, reserved: 0, settled: 17 });

    const second = await draftRun(user, [10]);
    expect(await gate(second.drafts[0])).toEqual({ gate: "insufficient_credit" });
    expect(await count("select 1 from public.execution_artifacts where run_id = $1", [second.runId])).toBe(0);
    expect(await one("select body from public.execution_artifacts where run_id = $1", [first.runId])).toEqual({ body: ARTIFACT.body });
    expect((await runState(second.runId)).hold_reason).toBe("credit");
  });
});

describe("원장은 DB가 지킨다", () => {
  it("같은 단계의 두 번째 예약 · 규칙과 다른 키 · 가용을 넘는 계정 합계는 거절한다", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [10]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    const insert = (key: string, kind = "reserve") =>
      db.query(
        "insert into public.credit_ledger (user_id, kind, credits, run_id, step_id, receipt_key, rate_version) values ($1, $2, 10, $3, $4, $5, 'c3-v1')",
        [user, kind, runId, drafts[0], key],
      );
    await expect(insert(`reserve:${drafts[0]}`)).rejects.toThrow(/duplicate key/);
    await expect(insert(`reserve:${randomUUID()}`)).rejects.toThrow(/credit_ledger_key/);
    await expect(insert(`grant:${randomUUID()}`, "grant")).rejects.toThrow(/credit_ledger_(key|rate)/);
    await expect(db.query("update public.credit_accounts set reserved = 200 where user_id = $1", [user])).rejects.toThrow(/credit_accounts_balance/);
    await db.query("select public.record_usage($1, $2::jsonb)", [drafts[0], JSON.stringify([attempt()])]);
    await expect(
      db.query("update public.execution_usage set cost_status = 'confirmed' where step_id = $1 and cost_usd is null", [drafts[0]]),
    ).rejects.toThrow(/execution_usage_cost/);
  });

  it("원장 · 원가는 지우지 않는다: 원장이 가리키는 run은 지울 수 없다 (계정 삭제는 account-deletion.test.ts)", async () => {
    const user = await newUser(100);
    const { runId, drafts } = await draftRun(user, [10]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    await expect(db.query("delete from public.execution_runs where id = $1", [runId])).rejects.toThrow(/foreign key/);
  });
});

describe("보관 (purge_expired_artifacts)", () => {
  it("보관 기간(기본 90일)이 지난 산출물의 본문만 비운다: 제목 · 원가 · 원장은 그대로, 다시 불러도 한 번", async () => {
    const user = await newUser(100);
    const { drafts } = await draftRun(user, [10]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await complete(drafts[0], [attempt(0.001)], ARTIFACT, "draft_ready")).toBe(true);
    const total = await count("select 1 from public.execution_artifacts");
    const usage = await count("select 1 from public.execution_usage");

    expect(await one("select public.purge_expired_artifacts() as n", [])).toEqual({ n: 0 });
    await db.query("select set_config('app.now', (now() + interval '91 days')::text, false)");
    try {
      expect(await one("select public.purge_expired_artifacts() as n", [])).toEqual({ n: total });
      expect(await one("select public.purge_expired_artifacts() as n", [])).toEqual({ n: 0 });
    } finally {
      await db.query("select set_config('app.now', '', false)");
    }
    expect(await one("select title, body, body_purged_at is not null as purged from public.execution_artifacts where step_id = $1", [drafts[0]])).toEqual({
      title: ARTIFACT.title,
      body: "",
      purged: true,
    });
    expect(await count("select 1 from public.execution_usage")).toBe(usage);
    expect(await count("select 1 from public.credit_ledger where step_id = $1", [drafts[0]])).toBe(3);
  });
});

describe("권한", () => {
  it("사용자는 자기 산출물만 읽고, 산출물을 만들거나 고치거나 지우지 못한다", async () => {
    const alice = await newUser(100);
    const bob = await newUser();
    const { drafts } = await draftRun(alice, [10]);
    expect((await gate(drafts[0])).gate).toBe("ok");
    expect(await complete(drafts[0], [attempt(0.001)], ARTIFACT, "draft_ready")).toBe(true);

    await asUser(db, alice, async () => {
      const { rows } = await db.query<{ step_id: string; body: string }>("select step_id, body from public.execution_artifacts");
      expect(rows).toEqual([{ step_id: drafts[0], body: ARTIFACT.body }]);
      await expect(db.query("update public.execution_artifacts set body = 'x'")).rejects.toThrow(/permission denied/);
      await expect(db.query("delete from public.execution_artifacts")).rejects.toThrow(/permission denied/);
      await expect(
        db.query(
          `insert into public.execution_artifacts (user_id, run_id, step_id, action_id, kind, title, body, marker, model, prompt_version)
           select user_id, run_id, step_id, action_id, kind, title, body, gen_random_uuid(), model, prompt_version from public.execution_artifacts`,
        ),
      ).rejects.toThrow(/permission denied/);
    });
    await asUser(db, bob, async () => {
      expect((await db.query("select * from public.execution_artifacts")).rows).toHaveLength(0);
    });
  });

  it("원장 · 계정 · 요율 · 원가는 클라이언트(anon · authenticated)가 읽지도 쓰지도 못한다", async () => {
    const user = await newUser(100);
    expect(await count("select 1 from public.credit_ledger where user_id = $1", [user])).toBe(1); // 서버에서는 행이 있다
    for (const role of ["authenticated", "anon"]) {
      await db.exec(`set role ${role}; select set_config('request.jwt.claim.sub', '${user}', false);`);
      try {
        for (const table of ["credit_accounts", "credit_ledger", "credit_rates", "execution_usage"]) {
          await expect(db.query(`select * from public.${table}`), `${role} ${table}`).rejects.toThrow(/permission denied/);
        }
        await expect(db.query("update public.credit_accounts set granted = 1000000")).rejects.toThrow(/permission denied/);
        await expect(
          db.query("insert into public.credit_ledger (user_id, kind, credits, receipt_key) values ($1, 'grant', 1000, 'grant:x')", [user]),
        ).rejects.toThrow(/permission denied/);
        await expect(db.query("update public.credit_rates set usd_per_credit = 1")).rejects.toThrow(/permission denied/);
      } finally {
        await db.exec("reset role; select set_config('request.jwt.claim.sub', '', false);");
      }
    }
  });

  it("이 마이그레이션의 함수는 모두 서버 전용이다: 파일에서 찾은 모든 함수에 anon · authenticated 실행 권한이 없고 service_role만, search_path = '', 소유자 권한 없음", async () => {
    const sql = await readFile(MIGRATION, "utf8");
    const names = [...new Set([...sql.matchAll(/create (?:or replace )?function public\.(\w+)/g)].map((m) => m[1]))].sort();
    expect(names).toEqual(expect.arrayContaining(["begin_call", "grant_credits", "complete_internal_step", "reconcile_usage", "release_run_credits"]));
    const { rows } = await db.query<{ name: string; anon: boolean; authenticated: boolean; service_role: boolean; definer: boolean; config: string[] | null }>(
      `select p.proname as name,
              has_function_privilege('anon', p.oid, 'execute') as anon,
              has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
              has_function_privilege('service_role', p.oid, 'execute') as service_role,
              p.prosecdef as definer, p.proconfig as config
       from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = any ($1)
       order by p.proname`,
      [names],
    );
    expect(rows.map((r) => r.name)).toEqual(names); // 같은 이름의 다른 판(overload)이 없다
    for (const row of rows) {
      expect(row, row.name).toMatchObject({ anon: false, authenticated: false, service_role: true, definer: false });
      expect(row.config, row.name).toContain('search_path=""');
    }
  });

  it.each([
    ["grant_credits", "select public.grant_credits($1, 1000, gen_random_uuid())"],
    ["complete_internal_step", "select public.complete_internal_step(gen_random_uuid(), 'fn', '{}', '[]')"],
    ["record_usage", "select public.record_usage(gen_random_uuid(), '[]')"],
    ["reconcile_usage", "select public.reconcile_usage(1, 0)"],
    ["release_run_credits", "select public.release_run_credits(gen_random_uuid())"],
    ["purge_expired_artifacts", "select public.purge_expired_artifacts()"],
    ["credit_settle_step", "select public.credit_settle_step(gen_random_uuid())"],
    ["credit_insert_usage", "select public.credit_insert_usage(gen_random_uuid(), '[]', true)"],
  ])("클라이언트는 %s를 부를 수 없다 (자기 크레딧을 늘리는 경로가 없다)", async (name, sql) => {
    const user = await newUser();
    await asUser(db, user, async () => {
      await expect(db.query(sql, name === "grant_credits" ? [user] : []), name).rejects.toThrow(/permission denied/);
    });
  });

  it("service_role은 지급 · 예약 · 정산 · 해제를 부른다 (보조 함수 · run 끝 트리거가 service_role 권한으로 돈다)", async () => {
    const user = await newUser();
    await db.exec("set role service_role");
    try {
      expect(await grant(user, 100)).toBe(true);
      const { runId, drafts } = await draftRun(user, [30, 30]);
      expect((await gate(drafts[0])).gate).toBe("ok");
      expect(await complete(drafts[0], [attempt(0.005)], ARTIFACT)).toBe(true);
      expect((await gate(drafts[1])).gate).toBe("ok");
      expect(await one("select public.stop_run($1, $2) as s", [user, runId])).toEqual({ s: "stopped" });
      expect(await account(user)).toEqual({ granted: 100, reserved: 30, settled: 5 });
      expect(await one("select public.mark_unknown($1, 'fn-1') as ok", [drafts[1]])).toEqual({ ok: true }); // 단계 트리거가 해제
      expect(await account(user)).toEqual({ granted: 100, reserved: 0, settled: 5 });
      expect(await one("select public.release_run_credits($1) as n", [runId])).toEqual({ n: 0 });
      expect((await one<{ n: number }>("select public.record_usage($1, $2::jsonb) as n", [drafts[1], JSON.stringify([attempt()])])).n).toBe(1);
      expect(
        await one("select public.reconcile_usage(id, 0.001) as ok from public.execution_usage where step_id = $1 and cost_status = 'unconfirmed'", [drafts[1]]),
      ).toEqual({ ok: true });
      expect(await one("select public.purge_expired_artifacts() as n")).toEqual({ n: 0 });
    } finally {
      await db.exec("reset role");
    }
  });
});

describe("계정 합계 = 원장 합계 (위 모든 사용자)", () => {
  it("지급 = grant + adjust, 예약 = reserve - settle - release, 정산 = settle", async () => {
    const { rows } = await db.query(
      `select a.user_id from public.credit_accounts a
       left join lateral (
         select coalesce(sum(credits) filter (where kind in ('grant', 'adjust')), 0) as granted,
                coalesce(sum(credits) filter (where kind = 'reserve'), 0) - coalesce(sum(credits) filter (where kind in ('settle', 'release')), 0) as reserved,
                coalesce(sum(credits) filter (where kind = 'settle'), 0) as settled
         from public.credit_ledger l where l.user_id = a.user_id
       ) s on true
       where (a.granted, a.reserved, a.settled) is distinct from (s.granted, s.reserved, s.settled)`,
    );
    expect(rows).toEqual([]);
    expect(await count("select 1 from public.credit_accounts")).toBeGreaterThan(10);
  });
});
