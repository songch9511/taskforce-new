import type { LlmAttempt } from "@/lib/ai/llm";
import type { CompleteJson } from "@/lib/pipeline/extract";

import type { ExecutionContextInput } from "./context";
import type { ReceiptStore } from "./receipt";

// 실행기가 쓰는 DB 연산. 운영은 store.ts(supabase · service role), 테스트는 같은 SQL 함수를 PGlite에서 부르는 store다.

export const OPEN_RUN_STATES = ["queued", "running", "waiting_approval"] as const;
export type OpenRunState = (typeof OPEN_RUN_STATES)[number];
export type RunState = OpenRunState | "done" | "failed" | "stopped";
export type StepState = "pending" | "prepared" | "calling" | "called" | "unknown_outcome" | "failed" | "skipped";
export type RunOutcome = "draft_ready" | "needs_connection" | "needs_input";

// DB가 받는 goal · 단계 종류 (20261109000000_execution_additive_contract의 CHECK, 런타임 계약 4장). DB가 받는다고 실행하는 것은 아니다:
// 실행기가 실제로 하는 것은 아래 EXECUTABLE_*뿐이고, 나머지는 읽기만 하고 부르지 않는다(fail closed). 새 goal · 종류를 실행하는 단계가 이 두 목록을 넓힌다.
export const RUN_GOALS = ["draft", "agent", "send", "followup"] as const;
export type RunGoal = (typeof RUN_GOALS)[number];
export const STEP_KINDS = ["plan", "draft", "external", "agent_dispatch", "agent_message", "agent_cancel", "review", "check", "send", "observe"] as const;
export type StepKind = (typeof STEP_KINDS)[number];
/** execution_runs.kind (20261113000000_agent_gateway_core, 계약 v3 3.4): task = Taskforce가 맡긴 작업, conversation = 에이전트 직접 대화(세션 × 이슈마다 열린 run 하나) */
export const RUN_KINDS = ["task", "conversation"] as const;
export type RunKind = (typeof RUN_KINDS)[number];
/** 실행기가 단계를 돌리는 goal. 다른 goal의 run은 깨우지도(sweep) 돌리지도(advance) 않는다 */
export const EXECUTABLE_GOALS = ["draft"] as const satisfies readonly RunGoal[];
/** 실행기가 준비하고 부르는 단계 종류(내장 계획 · 초안). external은 준비도 부르기도 하지 않고(발송은 U6a), 나머지는 아직 실행하는 코드가 없다 */
export const EXECUTABLE_STEP_KINDS = ["plan", "draft"] as const satisfies readonly StepKind[];

export type RunRow = { id: string; user_id: string; action_id: string; goal: RunGoal; state: RunState; request: string };
export type StepRow = { id: string; run_id: string; seq: number; kind: StepKind; state: StepState; version: number };

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

/** receipt 쓰기(receipt.ts)의 DB 연산도 같은 store가 갖는다: 실행기는 끝낸 초안 단계마다, sweep은 보조 안전망으로 부른다 */
export interface ExecutionStore extends ReceiptStore {
  loadRun(runId: string): Promise<RunRow | null>;
  /** 끝나지 않은(called · skipped가 아닌) 첫 단계 */
  nextOpenStep(runId: string): Promise<StepRow | null>;
  hasStepAfter(runId: string, seq: number): Promise<boolean>;
  draftHistory(runId: string, beforeSeq: number): Promise<DraftHistoryRow[]>;
  /** Action과 근거 원문 (본인 것만). Action이 없으면 null */
  loadMaterial(userId: string, actionId: string): Promise<ExecutionContextInput | null>;
  hasConsent(userId: string): Promise<boolean>;
  userName(userId: string): Promise<string>;

  /** 그 단계가 아직 이 함수의 lease 아래 부르는 중인가 (calling + lease 소유자) */
  holdsLease(stepId: string, owner: string): Promise<boolean>;

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

  /** 차단 스위치의 전체 행이 막혔거나 없다 */
  globallyBlocked(): Promise<boolean>;
  sweepExpire(): Promise<number>;
  unconfirmedUsage(limit: number, since: Date): Promise<{ id: number; generation_id: string }[]>;
  reconcileUsage(usageId: number, costUsd: number): Promise<boolean>;
  openEndedCreditRuns(limit: number): Promise<string[]>;
  releaseRunCredits(runId: string): Promise<number>;
  /** 깨울 run: 끝나지 않았고 부르는 중인 단계가 없다. 막힌 run(held: hold_reason 있음)은 뒤로 */
  wakeableRuns(limit: number): Promise<{ id: string; held: boolean }[]>;
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
  /** 앞 시도가 이미 다음 단계를 붙였다 (다시 부른 계획 단계): 끝낸 뒤 깨운다 */
  stepAfterExists?: boolean;
};
