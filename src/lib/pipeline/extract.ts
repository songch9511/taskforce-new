import { z } from "zod";

import type { JsonCompletion, JsonCompletionRequest } from "@/lib/ai/llm";
import { buildExtractUserPrompt, EXTRACT_PROMPT_VERSION, EXTRACT_SYSTEM_PROMPT } from "@/lib/ai/prompts/extract";

import type { Participants, UserIdentity } from "./identity";

// Source 텍스트 → Action 후보. LLM 호출은 인자로 받아 eval과 테스트에서 그대로 돌린다.

export const sourceKindSchema = z.enum(["meeting", "message", "email", "doc", "note"]);
export type SourceKind = z.infer<typeof sourceKindSchema>;

export type ExtractInput = {
  text: string;
  kind: z.infer<typeof sourceKindSchema>;
  occurredAt: Date;
  identity: UserIdentity;
  /** 메일의 보낸 사람 · 받는 사람 · 참조, 회의 참석자 */
  participants?: Participants;
};

// 모델에게 주는 응답 스키마. 공급자마다 JSON 스키마 지원 범위가 달라 형식 제약(날짜 패턴, 범위)은 넣지 않고
// 받은 뒤 코드로 정리한다.
export const extractResponseSchema = z.object({
  candidates: z.array(
    z.object({
      signal: z.enum(["commitment", "update", "completion", "cancellation"]),
      rationale: z.string(),
      title: z.string(),
      quote: z.string(),
      owner: z.enum(["me", "unknown"]),
      owner_confidence: z.number(),
      counterpart: z.string().nullable(),
      due_text: z.string().nullable(),
      due: z.string().nullable().describe("YYYY-MM-DD"),
      due_confidence: z.number().nullable(),
    }),
  ),
});

/** commitment: 새 약속 · 할당(또는 다시 말함). 나머지는 기존 약속의 변화로, 매칭에서만 쓴다. */
export type CandidateSignal = "commitment" | "update" | "completion" | "cancellation";

export type ActionCandidate = {
  signal: CandidateSignal;
  title: string;
  quote: string;
  owner: "me" | "unknown";
  owner_confidence: number;
  counterpart: string | null;
  due_text: string | null;
  due: string | null;
  due_confidence: number | null;
  rationale: string;
};

export type ExtractResult = {
  candidates: ActionCandidate[];
  promptVersion: string;
  model: string;
  usage?: JsonCompletion<unknown>["usage"];
};

export type CompleteJson = <T extends z.ZodType>(request: JsonCompletionRequest<T>) => Promise<JsonCompletion<z.infer<T>>>;

export async function extractCandidates(input: ExtractInput, complete: CompleteJson): Promise<ExtractResult> {
  const result = await complete({
    system: EXTRACT_SYSTEM_PROMPT,
    user: buildExtractUserPrompt(input),
    schemaName: "action_candidates",
    schema: extractResponseSchema,
  });

  const candidates = result.data.candidates
    .map((c) => {
      const due = isIsoDate(c.due) ? c.due : null;
      return {
        signal: c.signal,
        title: c.title.trim(),
        quote: c.quote.trim(),
        owner: c.owner,
        owner_confidence: clamp01(c.owner_confidence),
        counterpart: blankToNull(c.counterpart),
        due_text: blankToNull(c.due_text),
        due,
        due_confidence: due === null || c.due_confidence === null ? null : clamp01(c.due_confidence),
        rationale: c.rationale.trim(),
      };
    })
    .filter((c) => c.title.length > 0 && c.quote.length > 0);

  return { candidates, promptVersion: EXTRACT_PROMPT_VERSION, model: result.model, usage: result.usage };
}

function isIsoDate(value: string | null): value is string {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

function clamp01(value: number): number {
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
}

function blankToNull(value: string | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}
