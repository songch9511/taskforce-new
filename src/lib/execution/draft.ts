import { z } from "zod";

import type { LlmAttempt, LlmUsage } from "@/lib/ai/llm";
import { buildDraftUserPrompt, DRAFT_PROMPT_VERSION, DRAFT_SYSTEM_PROMPT } from "@/lib/ai/prompts/draft";
import type { CompleteJson } from "@/lib/pipeline/extract";

import type { ExecutionContext } from "./context";

// 내장 초안 쓰기 (실행 단계 draft, 내부 효과). DB와 분리된 순수 함수라 실행기 · eval(E1) · 테스트에서 같은 코드를 쓴다.
// 초안은 저장만 하고 보내지 않는다(발송은 U6a). 자료는 context.ts가 만든 것(Slack 원문 제외)만 받는다.

export const draftModelResponseSchema = z.object({
  title: z.string(),
  /** 받는 사람 (이름, 자료에 주소가 있으면 "이름 <주소>"). 사용자가 쓸 문서면 빈 배열 */
  to: z.array(z.string()),
  body: z.string(),
});
export type Draft = z.infer<typeof draftModelResponseSchema>;

export type DraftInput = {
  request: string;
  /** 계획 단계가 고른 지시 (plan.ts draft.brief). 없으면 요청만으로 쓴다 */
  brief: string | null;
  now: Date;
  user: { name: string };
  context: ExecutionContext;
};

export type DraftResult = {
  draft: Draft;
  model: string;
  promptVersion: string;
  usage?: LlmUsage;
  /** 원가 기록: 다시 물은 시도까지 모두 (llm.ts LlmAttempt) */
  attempts: LlmAttempt[];
  reasoningLimited: boolean;
};

export async function writeDraft(input: DraftInput, complete: CompleteJson): Promise<DraftResult> {
  const result = await complete({
    system: DRAFT_SYSTEM_PROMPT,
    user: buildDraftUserPrompt({ request: input.request, brief: input.brief, now: input.now, user: input.user, material: input.context.material }),
    schemaName: "draft",
    schema: draftModelResponseSchema,
  });
  return {
    draft: result.data,
    model: result.model,
    promptVersion: DRAFT_PROMPT_VERSION,
    usage: result.usage,
    attempts: result.attempts ?? [],
    reasoningLimited: result.reasoningLimited === true,
  };
}
