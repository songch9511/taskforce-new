import type { LlmAttempt } from "@/lib/ai/llm";
import type { CompleteJson } from "@/lib/pipeline/extract";

import type { ExecutionContextInput } from "./context";

// 실행기가 쓰는 DB 연산. 운영은 store.ts(supabase · service role), 테스트는 같은 SQL 함수를 PGlite에서 부르는 store다.

export type OpenRunState = "queued" | "running" | "waiting_approval";
export type RunState = OpenRunState | "done" | "failed" | "stopped";
export type StepState = "pending" | "prepared" | "calling" | "called" | "unknown_outcome" | "failed" | "skipped";
export type RunOutcome = "draft_ready" | "needs_connection" | "needs_input";

export type RunRow = { id: string; user_id: string; action_id: string; state: RunState; request: string };
export type StepRow = { id: string; run_id: string; seq: number; kind: "plan" | "draft" | "external"; state: StepState; version: number };

/** begin_call 결과. ok면 검증한 그대로의 내용 (실행기는 이것만 쓴다) */
export type BeginCallResult = { gate: string; marker?: string; args?: Record<string, unknown> };

/** append_step의 p_step. 효과 종류는 도구 목록이 정한다 */
export type AppendStep = {
  kind: "plan" | "draft";
  provider: "taskforce";
  tool: "plan" | "draft";
  purpose: string;
  args?: Record<string, unknown>;
  estimate_credits: number;
};

/** complete_internal_step의 p_artifact (초안 단계만) */
export type ArtifactInput = { title: string; body: string; model: string; prompt_version: string };

/** 계획 단계에 넘기는 앞선 초안 단계 (seq 순) */
export type DraftHistoryRow = { state: "called" | "failed"; brief: string | null; title: string | null };

export interface ExecutionStore {
  loadRun(runId: string): Promise<RunRow | null>;
  /** 끝나지 않은(called · skipped가 아닌) 첫 단계 */
  nextOpenStep(runId: string): Promise<StepRow | null>;
  hasStepAfter(runId: string, seq: number): Promise<boolean>;
  draftHistory(runId: string, beforeSeq: number): Promise<DraftHistoryRow[]>;
  /** Action과 근거 원문 (본인 것만). Action이 없으면 null */
  loadMaterial(userId: string, actionId: string): Promise<ExecutionContextInput | null>;
  hasConsent(userId: string): Promise<boolean>;
  userName(userId: string): Promise<string>;

  prepareStep(stepId: string, version: number): Promise<boolean>;
  beginCall(stepId: string, owner: string, version: number): Promise<BeginCallResult>;
  appendStep(runId: string, seq: number, step: AppendStep): Promise<string | null>;
  completeInternalStep(
    stepId: string,
    owner: string,
    receipt: Record<string, unknown>,
    attempts: LlmAttempt[],
    artifact: ArtifactInput | null,
    outcome: RunOutcome | null,
  ): Promise<boolean>;
  recordUsage(stepId: string, attempts: LlmAttempt[]): Promise<number>;
  settleFailed(stepId: string, owner: string, receipt: Record<string, unknown>): Promise<boolean>;
  markUnknown(stepId: string, owner: string): Promise<boolean>;
  finishRun(runId: string): Promise<boolean>;

  sweepExpire(): Promise<number>;
  unconfirmedUsage(limit: number, since: Date): Promise<{ id: number; generation_id: string }[]>;
  reconcileUsage(usageId: number, costUsd: number): Promise<boolean>;
  openEndedCreditRuns(limit: number): Promise<string[]>;
  releaseRunCredits(runId: string): Promise<number>;
  /** 깨울 run: 끝나지 않았고 부르는 중인 단계가 없다. 막힌 run은 뒤로 */
  wakeableRuns(limit: number): Promise<string[]>;
}

/** create_run이 열린 Action을 찾지 못했다 (없음 · 남의 것 · 열리지 않음, SQLSTATE P0002) */
export class RunActionNotFoundError extends Error {
  constructor() {
    super("열린 Action이 없습니다");
    this.name = "RunActionNotFoundError";
  }
}

/** 효과(effects/plan.ts · draft.ts) 하나의 입력: lease를 가진 단계와 begin_call이 돌려준 인자 */
export type EffectInput = {
  store: ExecutionStore;
  /** 동의를 부를 때마다 다시 확인하는 모델 호출 (withConsentGate) */
  complete: CompleteJson;
  run: RunRow;
  step: StepRow;
  args: Record<string, unknown>;
  now: Date;
};

/** 효과의 결과: complete_internal_step에 넘길 것과, 그 전에 붙일 다음 단계 */
export type EffectResult = {
  receipt: Record<string, unknown>;
  /** 이 호출의 모든 시도 (다시 물은 시도 포함). 원가 기록 */
  attempts: LlmAttempt[];
  artifact: ArtifactInput | null;
  /** 이 단계를 끝내기 전에 붙일 다음 단계 (seq + 1) */
  append: AppendStep | null;
  outcome: RunOutcome | null;
  /** 결과 없이 끝내고 붙인 단계도 없다: 단계를 끝낸 뒤 run을 닫는다 (계획 단계는 결과 없이 run을 끝내지 않는다) */
  finish: boolean;
};
