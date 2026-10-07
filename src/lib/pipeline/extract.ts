import { z } from "zod";

import type { JsonCompletion, JsonCompletionRequest } from "@/lib/ai/llm";
import { buildExtractSystemPrompt, buildExtractUserPrompt, EXTRACT_PROMPT_VERSION } from "@/lib/ai/prompts/extract";

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
  /** 사용자가 직접 쓴 원문인가 (sources.written_by_me). 모르면 null · 없음 */
  writtenByMe?: boolean | null;
  /**
   * 연결(Gmail 등)로 가져온 원문인가. 연결로 가져온 메일은 스레드의 앞선 메일이 각각 따로 원문으로 들어오므로, 인용된 옛 메일 안의 후보는
   * 그 메일이 들어올 때 이미 Claim이 됐다(verify.ts). 사용자가 직접 붙여 넣은 메일(false · 없음)은 옛 메일이 따로 들어온 적이 없어
   * 인용 속 약속도 뽑는다. 원문 글이 아니라 어디서 왔는지로 정한다 (sources.external_id가 있으면 연결로 가져온 것).
   */
  fromConnector?: boolean;
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
  /** 한도를 넘겨 추론량을 제한해 다시 물은 답인가 (lib/ai/llm.ts) */
  reasoningLimited: boolean;
};

export type CompleteJson = <T extends z.ZodType>(request: JsonCompletionRequest<T>) => Promise<JsonCompletion<z.infer<T>>>;

export async function extractCandidates(input: ExtractInput, complete: CompleteJson): Promise<ExtractResult> {
  const result = await complete({
    system: buildExtractSystemPrompt(input.kind),
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

  return { candidates, promptVersion: EXTRACT_PROMPT_VERSION, model: result.model, usage: result.usage, reasoningLimited: result.reasoningLimited === true };
}

export function isIsoDate(value: string | null): value is string {
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.getTime()) && date.toISOString().slice(0, 10) === value;
}

export function clamp01(value: number): number {
  return Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : 0;
}

export function blankToNull(value: string | null): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}
