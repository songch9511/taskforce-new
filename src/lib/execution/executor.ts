import { LlmError, llmAttemptsOf, type LlmAttempt } from "@/lib/ai/llm";
import { ConsentRequiredError, withConsentGate } from "@/lib/consent/gate";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { draftEffect } from "./effects/draft";
import { planEffect } from "./effects/plan";
import { ExecutionInputError } from "./material";
import { OPEN_RUN_STATES, type EffectInput, type EffectResult, type ExecutionStore, type RunRow, type StepRow } from "./types";

// 실행기 (B2, docs/EXECUTION.md 2 · 3 · 13장). advance(runId) 한 번 = 단계 하나. 모든 상태는 DB에 있어 함수가 어디서 죽어도 DB만 보고 이어 간다.
// 흐름은 A29 드라이버(tests/execution/driver.ts)와 같다: 다음 단계 준비(prepare_step) → begin_call(스위치 · 허용 목록 · 크레딧 예약 · lease)
// → 효과(계획 · 초안의 AI 호출) → complete_internal_step(called + 산출물 + 원가 + 정산, 한 트랜잭션).
// 모든 입구(route의 after() · 자기 호출 · sweep)가 이 함수 하나를 지나고, 부르기 전 판단은 begin_call 하나가 한다.
// 외부 효과는 없다: 외부 단계(kind external)는 부르지 않고 그대로 둔다 (발송은 U6a).
// 원가: 받은 시도는 어느 길로 끝나든 남긴다 (끝내면 complete_internal_step, 그 밖은 record_usage를 단계를 내보내기 전에).
// 로그에는 id · 상태 · gate만 남긴다 (요청 · 원문 · 초안 · 모델의 이유는 남기지 않는다).

export type ExecutorDeps = {
  store: ExecutionStore;
  /** 모델 호출 (llm.ts completeJson). 실행기가 사용자 동의 확인으로 감싼다 */
  complete: CompleteJson;
  /** lease 소유자: 함수 호출마다 새 값 */
  owner: string;
  now?: () => Date;
};

export type AdvanceResult =
  /** run이 없거나 끝났다 */
  | { status: "closed" }
  /** 남은 단계가 없어 run을 닫았다 (finish_run) */
  | { status: "finished" }
  /** 다른 함수가 먼저 준비 · 부르는 중이거나, 결과를 기다리는 단계다 (부르지 않았다) */
  | { status: "busy"; step: string }
  /** begin_call이 막았다 (stale · stopped · actor · blocked · tool · insufficient_credit 등). 단계는 prepared에 남는다 */
  | { status: "held"; step: string; gate: string }
  /** 단계를 끝냈다. next: 다음 단계가 있다 (깨운다) */
  | { status: "completed"; step: string; next: boolean }
  /** 다시 해도 같은 실패라 단계 · run을 실패로 끝냈다 */
  | { status: "failed"; step: string; reason: string }
  /** 응답을 못 받았다: 내부 효과라 다시 준비했다 (2번을 넘으면 SQL이 실패로 끝낸다). sweep이 다시 깨운다 */
  | { status: "retry"; step: string }
  /** 그 사이 lease를 잃었다 (lease 만료 뒤 다른 함수가 다시 준비함). 결과를 쓰지 않았다 */
  | { status: "lost"; step: string };

/** 받은 뒤의 쓰기(다음 단계 붙이기 · 결과 쓰기)를 해 보는 횟수 (EXECUTION 4장: 다시 쓰고, 그래도 안 되면 오류) */
const WRITE_TRIES = 3;

export async function advance(deps: ExecutorDeps, runId: string): Promise<AdvanceResult> {
  const { store } = deps;
  const run = await store.loadRun(runId);
  if (!run || !(OPEN_RUN_STATES as readonly string[]).includes(run.state)) return { status: "closed" };

  let step = await store.nextOpenStep(runId);
  if (!step) {
    await store.finishRun(runId);
    return { status: "finished" };
  }
  // 외부 단계는 준비도 부르기도 하지 않는다 (발송은 U6a)
  if (step.kind === "external") return { status: "busy", step: step.id };
  if (step.state === "pending") {
    if (!(await store.prepareStep(step.id, step.version))) return { status: "busy", step: step.id };
    // prepare_step은 CAS로 version을 하나 올린다. 그 사이 다른 함수가 바꿨으면 begin_call이 stale로 막는다
    step = { ...step, state: "prepared", version: step.version + 1 };
  }
  // calling(다른 함수가 부르는 중) · unknown_outcome(sweep이 확인) · failed는 부르지 않는다
  if (step.state !== "prepared") return { status: "busy", step: step.id };

  const gate = await store.beginCall(step.id, deps.owner, step.version);
  if (gate.gate !== "ok") {
    log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "held", gate: gate.gate });
    return { status: "held", step: step.id, gate: gate.gate };
  }
  return runEffect(deps, run, step, gate.args ?? {});
}

/** 후속 계획: 초안 뒤에 남은 조각을 다시 보는 계획 단계 (계획 단계는 seq 1과, 끝낸 초안이 붙인 것뿐이다) */
const isFollowUpPlan = (step: StepRow) => step.kind === "plan" && step.seq > 1;

async function runEffect(deps: ExecutorDeps, run: RunRow, step: StepRow, args: Record<string, unknown>): Promise<AdvanceResult> {
  const { store, owner } = deps;
  const input: EffectInput = {
    store,
    // 동의 철회는 모델을 부르기 직전마다 다시 본다 (원문 처리와 같은 관문)
    complete: withConsentGate({ complete: deps.complete }, () => store.hasConsent(run.user_id)).complete!,
    run,
    step,
    args,
    now: deps.now?.() ?? new Date(),
  };

  let effect: EffectResult;
  try {
    effect = step.kind === "plan" ? await planEffect(input) : await draftEffect(input);
  } catch (error) {
    // 원가는 단계를 내보내기 전에 남긴다: 그 사이에 죽어도 원가 행은 남고, 단계는 lease 만료로 다시 준비된다 (record_usage)
    await recordUsage(store, step.id, llmAttemptsOf(error));
    const reason = definitiveFailure(error);
    if (isFollowUpPlan(step)) {
      // 후속 계획은 남은 조각을 다시 볼 뿐이다: 실패해도 다시 하지 않고 이미 만든 초안으로 run을 끝낸다 (초안을 받고 청구된 run을 실패로 두지 않는다)
      effect = { receipt: { decision: "done", error: reason ?? "unavailable" }, attempts: [], artifact: null, append: null, outcome: "draft_ready", finish: false };
    } else if (reason) {
      await store.settleFailed(step.id, owner, { error: reason });
      log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "failed", reason });
      return { status: "failed", step: step.id, reason };
    } else {
      await store.markUnknown(step.id, owner);
      log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "retry", error: errorName(error) });
      return { status: "retry", step: step.id };
    }
  }

  let next = effect.stepAfterExists === true;
  let completed: Awaited<ReturnType<typeof writeWithRetry<boolean>>>;
  try {
    if (effect.append) {
      // lease를 잃은 함수는 다음 단계를 붙이지 않는다 (append_step은 run만 본다). 확인과 붙이기 사이의 틈은 lease(330초)가
      // 실행 한도(300초)보다 길어 운영에서는 생기지 않는다
      if (!(await store.holdsLease(step.id, owner))) return await lost(store, run, step, effect.attempts);
      // 다음 단계를 먼저 붙인다: 이 단계를 끝내며 남은 단계가 없으면 run이 끝나므로. 앞 시도가 이미 붙였으면(seq가 찼다) null
      const appended = await writeWithRetry(() => store.appendStep(run.id, step.seq + 1, effect.append!));
      // 확인 읽기가 실패해도 결과 쓰기를 막지 않는다: 깨워서 할 일이 없으면 advance가 그냥 끝난다
      next = appended.value !== null || (await store.hasStepAfter(run.id, step.seq).catch(() => true));
    }
    completed = await writeWithRetry(() => store.completeInternalStep(step.id, owner, effect.receipt, effect.attempts, effect.artifact, effect.outcome));
  } catch (error) {
    // 받은 응답을 끝내 쓰지 못했다: 단계는 calling에 남고 lease 만료 뒤 다시 부르므로, 이번 시도의 원가를 먼저 남긴다.
    // 앞 쓰기가 commit됐을 수도 있어 generation id가 있는 시도만 (같은 id는 한 번만 남는다)
    await recordUsage(store, step.id, effect.attempts.filter((a) => a.generationId !== null));
    throw error;
  }
  if (!completed.value) {
    // 첫 쓰기가 false: lease를 잃었다. 다시 쓴 쪽이 false면 앞 쓰기가 commit한 뒤 응답만 잃었을 수도 있다 (같은 id는 한 번만 남는다)
    if (!completed.retried) return lost(store, run, step, effect.attempts);
    await recordUsage(store, step.id, effect.attempts.filter((a) => a.generationId !== null));
  }
  if (effect.finish) await store.finishRun(run.id);
  log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "completed", outcome: effect.outcome, next });
  return { status: "completed", step: step.id, next };
}

/** lease를 잃은 뒤 받은 응답: 결과를 버리고 원가만 플랫폼 원가로 남긴다 (청구 · 단계 상태는 그대로) */
async function lost(store: ExecutionStore, run: RunRow, step: StepRow, attempts: LlmAttempt[]): Promise<AdvanceResult> {
  await recordUsage(store, step.id, attempts);
  log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "lost" });
  return { status: "lost", step: step.id };
}

/** 받은 뒤의 DB 쓰기는 결과 불명이 아니다: 다시 쓰고(WRITE_TRIES번), 그래도 안 되면 오류를 낸다. retried: 앞 시도가 오류였다 */
async function writeWithRetry<T>(write: () => Promise<T>): Promise<{ value: T; retried: boolean }> {
  for (let attempt = 1; ; attempt++) {
    try {
      return { value: await write(), retried: attempt > 1 };
    } catch (error) {
      if (attempt >= WRITE_TRIES) throw error;
    }
  }
}

/** 원가 기록은 단계를 내보내는 것을 막지 않는다: 실패하면 로그만 남기고 이어 간다 (lease를 330초 붙잡지 않게) */
async function recordUsage(store: ExecutionStore, stepId: string, attempts: LlmAttempt[]): Promise<void> {
  if (attempts.length === 0) return;
  try {
    await store.recordUsage(stepId, attempts);
  } catch (error) {
    log({ event: "execution_usage_record_failed", step: stepId, attempts: attempts.length, error: errorName(error) });
  }
}

/**
 * 다시 해도 같은 실패: 단계를 실패로 끝낸다. 그 밖(시간 초과 · 연결 · 형식 · 공급자 5xx · 408 · 429 · DB 읽기)은 다시 준비한다.
 * 401 · 402 · 403(키 · 잔액 · 권한)은 운영 설정 문제라 바로 실패로 두지 않고 다시 준비하지만, 다시 준비 한도(2번, sweep 1분 간격) 안에서만이다:
 * 2분쯤 넘게 이어지면 SQL이 retries_exhausted로 실패시킨다. 공급자 장애 동안 시도를 쓰지 않고 기다리게(hold) 하려면 SQL 전이가 필요하다 (후속 마이그레이션)
 */
export function definitiveFailure(error: unknown): string | null {
  if (error instanceof ConsentRequiredError) return "consent";
  if (error instanceof ExecutionInputError) return error.code;
  if (error instanceof LlmError) {
    if (error.kind === "unsupported_parameters") return "rejected";
    // llm.ts의 "OpenRouter 요청 실패 (NNN)" (sources/process.ts sourceFailureCode와 같은 읽기)
    const status = Number(/요청 실패 \((\d{3})\)/.exec(error.message)?.[1]);
    if (status >= 400 && status < 500 && ![401, 402, 403, 408, 429].includes(status)) return "rejected";
  }
  return null;
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "unknown";
}

function log(entry: Record<string, unknown>): void {
  console.info(JSON.stringify(entry));
}
