import { z } from "zod";

import type { LlmAttempt, LlmUsage } from "@/lib/ai/llm";
import { buildPlanUserPrompt, PLAN_CAPABILITIES, PLAN_PROMPT_VERSION, PLAN_SYSTEM_PROMPT, type PlanCapability, type PlanPromptHistoryStep } from "@/lib/ai/prompts/plan";
import type { CompleteJson } from "@/lib/pipeline/extract";

import type { ExecutionContext } from "./context";

// 다음 단계 고르기 (실행 계획). DB와 분리된 순수 함수라 실행기 · eval(E2) · 테스트에서 같은 코드를 쓴다.
// 모델은 다음 단계 하나만 고르고, 그 단계를 할 수 있는지(차단 스위치 · 허용 목록 · 크레딧)는 실행기와 DB가 정한다 (docs/EXECUTION.md).

const capabilities = Object.keys(PLAN_CAPABILITIES) as [PlanCapability, ...PlanCapability[]];

export const nextStepSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("draft"), brief: z.string() }),
  z.object({ kind: z.literal("needs_connection"), capability: z.enum(capabilities) }),
  z.object({ kind: z.literal("ask_user"), question: z.string() }),
  z.object({ kind: z.literal("done") }),
]);
export type NextStep = z.infer<typeof nextStepSchema>;
export type NextStepKind = NextStep["kind"];

// 구조화 출력(json_schema strict)은 최상위가 객체여야 해서 union을 객체 안에 둔다 (K8, 관문 ①에서 이 모양으로 확인).
// reason을 먼저 쓰게 해 남은 조각을 따져 본 뒤 고르게 한다.
export const planModelResponseSchema = z.object({ reason: z.string(), step: nextStepSchema });

export type PlanHistoryStep = PlanPromptHistoryStep;

export type PlanInput = {
  request: string;
  now: Date;
  user: { name: string };
  context: ExecutionContext;
  history: PlanHistoryStep[];
};

export type PlanResult = {
  step: NextStep;
  /** 모델이 적은 이유 (사용자 글이 섞일 수 있어 로그에 남기지 않는다) */
  reason: string;
  model: string;
  promptVersion: string;
  usage?: LlmUsage;
  /** 원가 기록: 다시 물은 시도까지 모두 (llm.ts LlmAttempt) */
  attempts: LlmAttempt[];
  reasoningLimited: boolean;
};

export async function planNextStep(input: PlanInput, complete: CompleteJson): Promise<PlanResult> {
  const result = await complete({
    system: PLAN_SYSTEM_PROMPT,
    user: buildPlanUserPrompt({ request: input.request, now: input.now, user: input.user, material: input.context.material, history: input.history }),
    schemaName: "next_step",
    schema: planModelResponseSchema,
  });
  return {
    step: result.data.step,
    reason: result.data.reason,
    model: result.model,
    promptVersion: PLAN_PROMPT_VERSION,
    usage: result.usage,
    attempts: result.attempts ?? [],
    reasoningLimited: result.reasoningLimited === true,
  };
}
