import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 실행의 글 보관 기간 (20261024000000_execution_text_retention, 처리방침 D9a-1 5장, docs/EXECUTION.md 12장).
// 끝난 run(done · failed · stopped)이 끝난 지 보관 기간이 지나면 요청 · 지시(args.brief) · 받는 사람 후보(receipt.to) · 되묻는 질문(receipt.question)만 지운다.
// 실행기(U2 PR6)가 부를 순서 그대로 SQL을 부른다: run → 계획 단계(초안 단계를 붙임) → 초안 단계(산출물 · 원가 · 정산) → 후속 계획(되묻기).
// "보관 기간이 지났다"는 기준 시각(p_before)을 앞으로 옮겨 본다. 끝난 시각을 뒤로 미룬 run은 테스트 시계(app.now)로 끝낸다.

// 테스트 시계 (execution-credits.test.ts와 같은 판): 마이그레이션을 적용한 뒤 테스트 안에서만 바꾼다. app.now가 비면 now()
const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;

const REQUEST = "김 대표님(kim@example.com)께 견적 회신 초안 써 줘";
const BRIEF = "김 대표님께 견적 일정과 금액을 확인하는 회신";
const TO = ["김 대표 <kim@example.com>"];
const QUESTION = "견적 금액을 알려 주실 수 있나요?";
const ARTIFACT = { title: "견적 회신", body: "김 대표님, 지난 회의에서 말씀하신 견적을 보내드립니다.", model: "m", prompt_version: "draft-v1" };

let db: PGlite;

const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
const count = async (sql: string, params: unknown[] = []) => (await one<{ n: number }>(`select count(*)::int as n from (${sql}) x`, params)).n;

/** 정리: 기준 시각(p_before, SQL 식)보다 먼저 끝난 run의 글을 지우고 지운 run 수 */
const purge = async (before: string, limit = 5000) =>
  (await one<{ n: number }>(`select public.purge_expired_execution_text(${before}, $1) as n`, [limit])).n;
/** 앞선 테스트가 남긴 끝난 run을 모두 지운다 (수를 세는 테스트가 자기 run만 보게) */
const drain = () => purge("now() + interval '1000 days'");

const attempts = (cost = 0.001) => JSON.stringify([{ generationId: `gen-${randomUUID()}`, model: "m", usage: { prompt_tokens: 100, completion_tokens: 50, cost } }]);

async function newUser(credits = 100) {
  const userId = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await db.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  if (credits) await db.query("select public.grant_credits($1, $2, gen_random_uuid())", [userId, credits]);
  return userId;
}

/** 단계를 준비하고(pending이면) 지금 버전으로 begin_call */
async function gate(stepId: string, owner = "fn-1") {
  const step = await one<{ state: string; version: number }>("select state, version from public.execution_steps where id = $1", [stepId]);
  let version = step.version;
  if (step.state === "pending") {
    expect((await one<{ ok: boolean }>("select public.prepare_step($1, $2) as ok", [stepId, version])).ok).toBe(true);
    version += 1;
  }
  return (await one<{ g: { gate: string } }>("select public.begin_call($1, $2, $3) as g", [stepId, owner, version])).g.gate;
}

const complete = async (stepId: string, receipt: object, artifact: object | null = null, outcome: string | null = null) =>
  (
    await one<{ ok: boolean }>("select public.complete_internal_step($1, 'fn-1', $2::jsonb, $3::jsonb, $4::jsonb, $5) as ok", [
      stepId,
      JSON.stringify(receipt),
      attempts(),
      artifact === null ? null : JSON.stringify(artifact),
      outcome,
    ])
  ).ok;

const append = async (runId: string, seq: number, step: object) =>
  (await one<{ id: string }>("select public.append_step($1, $2, $3::jsonb) as id", [runId, seq, JSON.stringify(step)])).id;

/** run을 만들고 계획 단계를 부른 뒤 초안 단계(지시 brief)를 붙이고 계획 단계를 끝낸다. 초안 단계는 pending */
async function plannedRun(userId: string) {
  const actionId = (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, '견적 회신') returning id", [userId])).id;
  const runId = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', $3) as id", [userId, actionId, REQUEST])).id;
  const planId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1 and seq = 1", [runId])).id;
  expect(await gate(planId)).toBe("ok");
  const draftId = await append(runId, 2, { kind: "draft", provider: "taskforce", tool: "draft", purpose: "draft", args: { brief: BRIEF }, estimate_credits: 20 });
  expect(await complete(planId, { decision: "draft", model: "m", prompt_version: "plan-v1" })).toBe(true);
  return { runId, actionId, planId, draftId };
}

/** 글이 모두 있는 끝난 run: 계획 → 초안(받는 사람 후보) → 후속 계획(되묻기) → done · needs_input */
async function finishedRun(userId: string) {
  const run = await plannedRun(userId);
  expect(await gate(run.draftId)).toBe("ok");
  const followId = await append(run.runId, 3, { kind: "plan", provider: "taskforce", tool: "plan", purpose: "plan", estimate_credits: 0 });
  expect(await complete(run.draftId, { to: TO, model: "m", prompt_version: "draft-v1" }, ARTIFACT)).toBe(true);
  expect(await gate(followId)).toBe("ok");
  expect(await complete(followId, { decision: "ask_user", question: QUESTION, model: "m", prompt_version: "plan-v1" }, null, "needs_input")).toBe(true);
  expect(await one("select state, outcome from public.execution_runs where id = $1", [run.runId])).toEqual({ state: "done", outcome: "needs_input" });
  return { ...run, followId };
}

/** 테스트 시계를 at(SQL 식)으로 맞춘 채 fn을 부른다 */
async function at<T>(when: string, fn: () => Promise<T>): Promise<T> {
  await db.query(`select set_config('app.now', (${when})::text, false)`);
  try {
    return await fn();
  } finally {
    await db.query("select set_config('app.now', '', false)");
  }
}

type RunRow = { request: string; state: string; outcome: string | null; hold_reason: string | null; purged: boolean };
const runRow = (runId: string) =>
  one<RunRow>("select request, state, outcome, hold_reason, text_purged_at is not null as purged from public.execution_runs where id = $1", [runId]);

type StepRow = { id: string; seq: number; state: string; version: number; intent_key: string | null; policy_version: number | null; args: Record<string, unknown>; receipt: Record<string, unknown> | null };
const stepRows = async (runId: string) =>
  (
    await db.query<StepRow>(
      "select id, seq, state, version, intent_key, policy_version, args, receipt from public.execution_steps where run_id = $1 order by seq",
      [runId],
    )
  ).rows;

/** 단계의 글 아닌 값: id · 순번 · 상태 · 버전 · intent · 정책 버전 (다시 계획되면 바뀐다) */
const planState = (rows: StepRow[]) =>
  rows.map(({ id, seq, state, version, intent_key, policy_version }) => ({ id, seq, state, version, intent_key, policy_version }));

/** 글이 남았는지: 요청 · 지시 · 받는 사람 후보 · 되묻는 질문 */
async function hasText(runId: string) {
  return {
    request: (await runRow(runId)).request !== "",
    brief: await count("select 1 from public.execution_steps where run_id = $1 and args ? 'brief'", [runId]),
    receiptText: await count("select 1 from public.execution_steps where run_id = $1 and receipt ?| array['to', 'question']", [runId]),
  };
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(TEST_CLOCK);
  // 처음 상태는 전체 스위치가 막혀 있다 (execution-core.test.ts). 여기서는 보관만 본다
  await db.query("update public.execution_controls set blocked = false where scope = 'global'");
}, 60_000);

describe("끝난 run의 글 지우기 (purge_expired_execution_text)", () => {
  it("끝난 지 보관 기간이 지난 run은 요청 · 지시 · 받는 사람 후보 · 되묻는 질문만 지우고, id · 상태 · 결과 · receipt의 다른 값 · 산출물 · 원가 · 원장 · 이벤트는 그대로", async () => {
    await drain();
    const user = await newUser();
    const run = await finishedRun(user);
    const steps = await stepRows(run.runId);
    const snapshot = async () => ({
      artifacts: (await db.query("select id, step_id, title, body, body_purged_at from public.execution_artifacts where run_id = $1 order by id", [run.runId])).rows,
      usage: (await db.query("select id, step_id, generation_id, cost_usd, cost_status, billable from public.execution_usage where run_id = $1 order by id", [run.runId])).rows,
      ledger: (await db.query("select id, kind, credits, receipt_key from public.credit_ledger where run_id = $1 order by id", [run.runId])).rows,
      events: (await db.query("select id, step_id, type, from_state, to_state, gate, at from public.execution_events where run_id = $1 order by id", [run.runId])).rows,
      intents: (await db.query("select i.intent_key, i.marker from public.execution_intents i join public.execution_steps s on s.id = i.step_id where s.run_id = $1 order by 1", [run.runId])).rows,
      claims: await count("select 1 from public.claims where action_id = $1", [run.actionId]),
    });
    const before = await snapshot();
    expect(before.artifacts).toHaveLength(1);
    expect(before.ledger.length).toBeGreaterThan(0);
    expect(await hasText(run.runId)).toEqual({ request: true, brief: 1, receiptText: 2 });

    // 오늘의 cron (기준 = 지금 - 90일): 방금 끝난 run은 그대로
    expect(await purge("now() - interval '90 days'")).toBe(0);
    expect(await hasText(run.runId)).toEqual({ request: true, brief: 1, receiptText: 2 });

    // 91일 뒤의 cron (기준 = 91일 뒤 - 90일 = 지금 + 1일)
    expect(await purge("now() + interval '1 day'")).toBe(1);
    expect(await hasText(run.runId)).toEqual({ request: false, brief: 0, receiptText: 0 });
    expect(await runRow(run.runId)).toEqual({ request: "", state: "done", outcome: "needs_input", hold_reason: null, purged: true });

    const after = await stepRows(run.runId);
    // 단계: id · 순번 · 상태 · 버전 · intent · 정책 버전 그대로(다시 계획하지 않았다), 지시 키만 빠지고 receipt는 글 아닌 값만 남는다
    expect(planState(after)).toEqual(planState(steps));
    expect(after.map((s) => s.args)).toEqual([{}, {}, {}]);
    expect(after.map((s) => s.receipt)).toEqual([
      { decision: "draft", model: "m", prompt_version: "plan-v1" },
      { model: "m", prompt_version: "draft-v1" },
      { decision: "ask_user", model: "m", prompt_version: "plan-v1" },
    ]);
    // 산출물(본문은 purge_expired_artifacts가 retain_until에 따로 비운다) · 원가 · 원장 · 실행 이벤트(새 이벤트 없음) · intent · Claim 그대로
    expect(await snapshot()).toEqual(before);
  });

  it("다시 불러도 같은 run을 두 번 지우지 않는다 (지운 시각도 그대로)", async () => {
    await drain();
    const run = await finishedRun(await newUser());
    expect(await purge("now() + interval '1 day'")).toBe(1);
    const first = await one<{ at: Date }>("select text_purged_at as at from public.execution_runs where id = $1", [run.runId]);
    const steps = await stepRows(run.runId);
    expect(await purge("now() + interval '1 day'")).toBe(0);
    expect(await purge("now() + interval '1000 days'")).toBe(0);
    expect(await one("select text_purged_at as at from public.execution_runs where id = $1", [run.runId])).toEqual(first);
    expect(await stepRows(run.runId)).toEqual(steps);
  });

  it("만든 시각이 아니라 끝난 시각으로 센다: 오래 열려 있다가 늦게 끝난 run은 끝난 뒤 보관 기간이 지나야 지운다", async () => {
    await drain();
    const user = await newUser();
    const early = await finishedRun(user);
    // 같은 때 만들었지만 30일 뒤에 끝난 run (초안 단계부터 테스트 시계 30일 뒤)
    const late = await plannedRun(user);
    await at("now() + interval '30 days'", async () => {
      expect(await gate(late.draftId)).toBe("ok");
      expect(await complete(late.draftId, { to: TO, model: "m", prompt_version: "draft-v1" }, ARTIFACT, "draft_ready")).toBe(true);
    });
    expect((await runRow(late.runId)).state).toBe("done");

    expect(await purge("now() + interval '1 day'")).toBe(1);
    expect((await runRow(early.runId)).purged).toBe(true);
    expect(await hasText(late.runId)).toEqual({ request: true, brief: 1, receiptText: 1 });

    expect(await purge("now() + interval '31 days'")).toBe(1);
    expect(await hasText(late.runId)).toEqual({ request: false, brief: 0, receiptText: 0 });
  });

  it("끝나지 않은 run(대기 · 크레딧으로 막힘)은 아무리 오래돼도 건드리지 않는다", async () => {
    await drain();
    const user = await newUser();
    const action = (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, 'x') returning id", [user])).id;
    const queued = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', $3) as id", [user, action, REQUEST])).id;
    const held = await plannedRun(await newUser(0));
    expect(await gate(held.draftId)).toBe("insufficient_credit");
    expect(await runRow(held.runId)).toMatchObject({ state: "running", hold_reason: "credit" });
    const heldSteps = await stepRows(held.runId);

    expect(await purge("now() + interval '1000 days'")).toBe(0);
    expect(await runRow(queued)).toMatchObject({ request: REQUEST, state: "queued", purged: false });
    expect(await runRow(held.runId)).toMatchObject({ request: REQUEST, state: "running", hold_reason: "credit", purged: false });
    expect(await stepRows(held.runId)).toEqual(heldSteps);
  });

  it("멈춘 · 실패한 run도 지운다. 준비된 · 대기 중인 채 멈춘 단계는 다시 계획되지 않고(상태 · 버전 그대로, 이벤트 없음), 부르는 중 · 결과 불명인 단계가 남은 run은 그 단계가 나온 뒤에 지운다", async () => {
    await drain();
    const user = await newUser();
    // 초안 단계를 준비한 채 멈춘 run
    const stopped = await plannedRun(user);
    const { version } = await one<{ version: number }>("select version from public.execution_steps where id = $1", [stopped.draftId]);
    expect(await one("select public.prepare_step($1, $2) as ok", [stopped.draftId, version])).toEqual({ ok: true });
    expect(await one("select public.stop_run($1, $2) as s", [user, stopped.runId])).toEqual({ s: "stopped" });
    // 초안 단계가 대기(pending)인 채 멈춘 run
    const pending = await plannedRun(user);
    expect(await one("select public.stop_run($1, $2) as s", [user, pending.runId])).toEqual({ s: "stopped" });
    const pendingSteps = await stepRows(pending.runId);
    expect(pendingSteps[1]).toMatchObject({ state: "pending", args: { brief: BRIEF } });
    // 계획 단계가 확정적으로 실패한 run
    const failedAction = (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, 'y') returning id", [user])).id;
    const failed = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', $3) as id", [user, failedAction, REQUEST])).id;
    const failedPlan = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1", [failed])).id;
    expect(await gate(failedPlan)).toBe("ok");
    expect(await one("select public.settle_step($1, 'fn-1', 'failed', '{\"error\": \"rejected\"}') as ok", [failedPlan])).toEqual({ ok: true });
    expect((await runRow(failed)).state).toBe("failed");
    // 초안 단계를 부르는 중에 멈춘 run (부르던 호출은 결과를 받는다, EXECUTION 5장)
    const calling = await plannedRun(user);
    expect(await gate(calling.draftId)).toBe("ok");
    expect(await one("select public.stop_run($1, $2) as s", [user, calling.runId])).toEqual({ s: "stopped" });
    // 결과 불명인 외부 단계가 남은 채 멈춘 run (U6a의 모양을 직접 넣는다. readback이 나중에 receipt를 쓴다)
    const unknown = await plannedRun(user);
    const externalId = (await one<{ id: string }>(
      `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, state, policy_version, unknown_since)
       values ($1, $2, 3, 'external', 'gmail', 'send', 'send', 'unknown_outcome', 1, now()) returning id`,
      [user, unknown.runId],
    )).id;
    expect(await one("select public.stop_run($1, $2) as s", [user, unknown.runId])).toEqual({ s: "stopped" });

    const stoppedSteps = await stepRows(stopped.runId);
    expect(stoppedSteps[1]).toMatchObject({ state: "prepared", args: { brief: BRIEF } });
    const runIds = [stopped.runId, pending.runId, failed, calling.runId, unknown.runId];
    const events = await count("select 1 from public.execution_events where run_id = any ($1)", [runIds]);

    expect(await purge("now() + interval '1 day'")).toBe(3);
    expect(await runRow(stopped.runId)).toMatchObject({ request: "", state: "stopped", purged: true });
    expect(await runRow(pending.runId)).toMatchObject({ request: "", state: "stopped", purged: true });
    expect(await runRow(failed)).toMatchObject({ request: "", state: "failed", purged: true });
    expect(await one("select receipt from public.execution_steps where id = $1", [failedPlan])).toEqual({ receipt: { error: "rejected" } });
    for (const [runId, before] of [[stopped.runId, stoppedSteps], [pending.runId, pendingSteps]] as const) {
      const after = await stepRows(runId);
      expect(planState(after)).toEqual(planState(before));
      expect(after.map((s) => s.receipt)).toEqual(before.map((s) => s.receipt));
      expect(after[1].args).toEqual({});
    }
    // 부르는 중 · 결과 불명인 단계가 남은 run은 미룬다
    expect(await runRow(calling.runId)).toMatchObject({ request: REQUEST, state: "stopped", purged: false });
    expect(await runRow(unknown.runId)).toMatchObject({ request: REQUEST, state: "stopped", purged: false });
    expect(await count("select 1 from public.execution_events where run_id = any ($1)", [runIds])).toBe(events);

    // 결과 불명 단계를 readback이 찾아 끝내면 다음 정리에서 지운다
    expect(await one("select public.readback_settle($1, $2::jsonb) as ok", [externalId, JSON.stringify({ to: TO })])).toEqual({ ok: true });
    expect(await purge("now() + interval '1 day'")).toBe(1);
    expect(await hasText(unknown.runId)).toEqual({ request: false, brief: 0, receiptText: 0 });

    // 그 호출이 결과(받는 사람 후보)를 받아 끝나면 다음 정리에서 지운다
    expect(await complete(calling.draftId, { to: TO, model: "m", prompt_version: "draft-v1" }, ARTIFACT)).toBe(true);
    expect(await hasText(calling.runId)).toEqual({ request: true, brief: 1, receiptText: 1 });
    expect(await purge("now() + interval '1 day'")).toBe(1);
    expect(await hasText(calling.runId)).toEqual({ request: false, brief: 0, receiptText: 0 });
    expect((await stepRows(calling.runId))[1]).toMatchObject({ state: "called", receipt: { model: "m", prompt_version: "draft-v1" } });
  });

  it("한 번에 p_limit개 run씩, 오래된 것부터 지운다. 인자가 없거나 한도가 1보다 작으면 오류", async () => {
    await drain();
    const user = await newUser();
    const first = await finishedRun(user);
    const second = await finishedRun(user);
    expect(await purge("now() + interval '1 day'", 1)).toBe(1);
    expect([(await runRow(first.runId)).purged, (await runRow(second.runId)).purged]).toEqual([true, false]);
    expect(await purge("now() + interval '1 day'", 1)).toBe(1);
    expect((await runRow(second.runId)).purged).toBe(true);

    await expect(db.query("select public.purge_expired_execution_text(null)")).rejects.toThrow(/잘못된 인자/);
    await expect(db.query("select public.purge_expired_execution_text(now(), 0)")).rejects.toThrow(/잘못된 인자/);
  });
});

describe("계획 동결 트리거의 예외는 정리 함수 안의 지시 지우기뿐이다 (execution_steps_replan)", () => {
  it("정리 함수 밖에서 끝낸 단계의 지시를 지우거나, gate retention이어도 지시를 바꾸거나 다른 계획 값을 바꾸면 plan is frozen", async () => {
    await drain();
    const run = await finishedRun(await newUser());
    const dropBrief = (id: string) => `update public.execution_steps set args = args - 'brief' where id = '${id}'`;
    /** gate retention인 트랜잭션에서 sql을 부르면 plan is frozen으로 막히고 되돌려진다 */
    const frozenUnderGate = (sql: string) =>
      expect(
        db.transaction(async (tx) => {
          await tx.query("select set_config('execution.gate', 'retention', true)");
          await tx.query(sql);
        }),
      ).rejects.toThrow(/plan is frozen/);

    await expect(db.query(dropBrief(run.draftId))).rejects.toThrow(/plan is frozen/);
    await frozenUnderGate(`update public.execution_steps set args = args - 'brief', body = 'x' where id = '${run.draftId}'`);
    await frozenUnderGate(`update public.execution_steps set args = jsonb_set(args, '{brief}', '"다른 지시"') where id = '${run.draftId}'`);
    await frozenUnderGate(`update public.execution_steps set args = (args - 'brief') || '{"extra": 1}' where id = '${run.draftId}'`);
    expect(await hasText(run.runId)).toEqual({ request: true, brief: 1, receiptText: 2 });

    // 정리 함수는 끝날 때 부른 쪽의 gate로 되돌린다: 같은 트랜잭션의 뒤 문장이 지시를 지우면 다시 막힌다 (정리까지 함께 되돌려진다)
    // 정리 기준보다 늦게(10일 뒤) 끝난 run: 이번 정리가 지우지 않아 지시가 남아 있다
    const other = await plannedRun(await newUser());
    await at("now() + interval '10 days'", async () => {
      expect(await gate(other.draftId)).toBe("ok");
      expect(await complete(other.draftId, { to: TO, model: "m", prompt_version: "draft-v1" }, ARTIFACT, "draft_ready")).toBe(true);
    });
    await expect(
      db.transaction(async (tx) => {
        await tx.query("select public.purge_expired_execution_text(now() + interval '1 day')");
        expect((await tx.query<{ purged: boolean }>("select text_purged_at is not null as purged from public.execution_runs where id = $1", [run.runId])).rows).toEqual([
          { purged: true },
        ]);
        await tx.query(dropBrief(other.draftId));
      }),
    ).rejects.toThrow(/plan is frozen/);
    expect(await hasText(run.runId)).toEqual({ request: true, brief: 1, receiptText: 2 });

    // 부른 쪽이 정한 gate는 그대로 남는다
    await db.transaction(async (tx) => {
      await tx.query("select set_config('execution.gate', 'stop', true)");
      await tx.query("select public.purge_expired_execution_text(now() + interval '1 day')");
      expect((await tx.query("select current_setting('execution.gate', true) as gate")).rows).toEqual([{ gate: "stop" }]);
      await tx.rollback();
    });
    expect(await hasText(run.runId)).toEqual({ request: true, brief: 1, receiptText: 2 });
  });
});

describe("권한", () => {
  it("클라이언트는 정리 함수를 부를 수 없고, 자기 run의 지운 시각(text_purged_at)은 읽는다", async () => {
    await drain();
    const user = await newUser();
    const run = await finishedRun(user);
    expect(await purge("now() + interval '1 day'")).toBe(1);
    await asUser(db, user, async () => {
      await expect(db.query("select public.purge_expired_execution_text(now())")).rejects.toThrow(/permission denied/);
      const { rows } = await db.query<{ request: string; purged: boolean }>(
        "select request, text_purged_at is not null as purged from public.execution_runs where id = $1",
        [run.runId],
      );
      expect(rows).toEqual([{ request: "", purged: true }]);
    });
  });

  it("service_role은 정리 함수를 부른다 (트리거 · 이벤트 기록이 service_role 권한으로 돈다)", async () => {
    await drain();
    const run = await finishedRun(await newUser());
    await db.exec("set role service_role");
    try {
      expect(await purge("now() + interval '1 day'")).toBe(1);
    } finally {
      await db.exec("reset role");
    }
    expect(await hasText(run.runId)).toEqual({ request: false, brief: 0, receiptText: 0 });
  });
});
