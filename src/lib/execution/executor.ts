import { LlmError, llmAttemptsOf } from "@/lib/ai/llm";
import { ConsentRequiredError, withConsentGate } from "@/lib/consent/gate";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { draftEffect } from "./effects/draft";
import { planEffect } from "./effects/plan";
import { ExecutionInputError } from "./material";
import type { EffectInput, EffectResult, ExecutionStore, RunRow, StepRow } from "./types";

// 실행기 (B2, docs/EXECUTION.md 2 · 3장). advance(runId) 한 번 = 단계 하나. 모든 상태는 DB에 있어 함수가 어디서 죽어도 DB만 보고 이어 간다.
// 흐름은 A29 드라이버(tests/execution/driver.ts)와 같다: 다음 단계 준비(prepare_step) → begin_call(스위치 · 허용 목록 · 크레딧 예약 · lease)
// → 효과(계획 · 초안의 AI 호출) → complete_internal_step(called + 산출물 + 원가 + 정산, 한 트랜잭션).
// 모든 입구(route의 after() · 자기 호출 · sweep)가 이 함수 하나를 지나고, 부르기 전 판단은 begin_call 하나가 한다.
// 외부 효과는 없다: 외부 단계(kind external)는 부르지 않고 그대로 둔다 (발송은 U6a).
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
  /** 단계를 끝냈다. next: 다음 단계를 붙였다 (깨운다) */
  | { status: "completed"; step: string; next: boolean }
  /** 다시 해도 같은 실패라 단계 · run을 실패로 끝냈다 */
  | { status: "failed"; step: string; reason: string }
  /** 응답을 못 받았다: 내부 효과라 다시 준비했다 (2번을 넘으면 SQL이 실패로 끝낸다). sweep이 다시 깨운다 */
  | { status: "retry"; step: string }
  /** 그 사이 lease를 잃었다 (lease 만료 뒤 다른 함수가 다시 준비함). 결과를 쓰지 않았다 */
  | { status: "lost"; step: string };

const OPEN_RUN_STATES = new Set(["queued", "running", "waiting_approval"]);

/** 받은 뒤 결과 쓰기(complete_internal_step)를 다시 해 보는 횟수 (EXECUTION 4장: 다시 쓰고, 그래도 안 되면 오류) */
const COMPLETE_TRIES = 3;

export async function advance(deps: ExecutorDeps, runId: string): Promise<AdvanceResult> {
  const { store } = deps;
  const run = await store.loadRun(runId);
  if (!run || !OPEN_RUN_STATES.has(run.state)) return { status: "closed" };

  let step = await store.nextOpenStep(runId);
  if (!step) {
    await store.finishRun(runId);
    return { status: "finished" };
  }
  // 외부 단계는 준비도 부르기도 하지 않는다 (발송은 U6a)
  if (step.kind === "external") return { status: "busy", step: step.id };
  if (step.state === "pending") {
    if (!(await store.prepareStep(step.id, step.version))) return { status: "busy", step: step.id };
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
    await store.recordUsage(step.id, llmAttemptsOf(error));
    const reason = definitiveFailure(error);
    if (reason) {
      await store.settleFailed(step.id, owner, { error: reason });
      log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "failed", reason });
      return { status: "failed", step: step.id, reason };
    }
    await store.markUnknown(step.id, owner);
    log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "retry", error: errorName(error) });
    return { status: "retry", step: step.id };
  }

  // 다음 단계를 먼저 붙인다: 이 단계를 끝내며 남은 단계가 없으면 run이 끝나므로. 앞 시도가 이미 붙였으면(seq가 찼다) null이고 그대로 둔다
  if (effect.append) await store.appendStep(run.id, step.seq + 1, effect.append);
  const completed = await completeWithRetry(store, step.id, owner, effect);
  if (completed === "lost") {
    // lease를 잃은 뒤 받은 응답: 원가만 플랫폼 원가로 남긴다 (청구 · 단계 상태는 그대로)
    await store.recordUsage(step.id, effect.attempts);
    log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "lost" });
    return { status: "lost", step: step.id };
  }
  if (effect.finish) await store.finishRun(run.id);
  log({ event: "execution_step", run: run.id, step: step.id, kind: step.kind, status: "completed", outcome: effect.outcome, next: effect.append !== null });
  return { status: "completed", step: step.id, next: effect.append !== null };
}

/**
 * called + 산출물 + 원가 + 정산 (complete_internal_step). 응답을 받은 뒤의 DB 오류는 결과 불명이 아니다: 다시 쓰고, 계속 실패하면 오류를 낸다
 * (단계는 calling에 남고 lease 만료 뒤 다시 준비된다). false는 lease를 잃었다는 뜻이지만, 앞 시도가 commit한 뒤 응답만 잃었을 수도 있어
 * 그때는 "done"으로 본다(원가를 다시 남기지 않는다: id 없는 시도 행이 두 번 생긴다).
 */
async function completeWithRetry(store: ExecutionStore, stepId: string, owner: string, effect: EffectResult): Promise<"done" | "lost"> {
  for (let attempt = 1; ; attempt++) {
    try {
      const ok = await store.completeInternalStep(stepId, owner, effect.receipt, effect.attempts, effect.artifact, effect.outcome);
      return ok || attempt > 1 ? "done" : "lost";
    } catch (error) {
      if (attempt >= COMPLETE_TRIES) throw error;
    }
  }
}

/** 다시 해도 같은 실패: 단계를 실패로 끝낸다. 그 밖(시간 초과 · 연결 · 형식 · 공급자 5xx · 429 · DB 읽기)은 다시 준비한다 */
export function definitiveFailure(error: unknown): string | null {
  if (error instanceof ConsentRequiredError) return "consent";
  if (error instanceof ExecutionInputError) return error.code;
  if (error instanceof LlmError) {
    if (error.kind === "unsupported_parameters") return "rejected";
    const status = Number(/요청 실패 \((\d{3})\)/.exec(error.message)?.[1]);
    if (status >= 400 && status < 500 && status !== 408 && status !== 429) return "rejected";
  }
  return null;
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "unknown";
}

function log(entry: Record<string, unknown>): void {
  console.info(JSON.stringify(entry));
}
