import { resolveDueText } from "./dates";
import type { ActionCandidate } from "./extract";
import { quoteInText } from "./text";

// ② 기계적 검증 (docs/TRUTH_RULES.md 1장). LLM 없이 싸고 확실한 것부터 거른다.
// - 인용이 원문에 없으면 환각이므로 버린다.
// - 기한 표현을 코드로 다시 계산해, 모델이 낸 날짜와 다르면 코드 값으로 바꾼다.

export type DueCheck =
  | "none" //       기한 표현이 없음
  | "match" //      코드 계산과 모델 값이 같음
  | "corrected" //  모델 값이 달라 코드 값으로 바꿈
  | "unresolved"; // 코드가 모르는 표현이라 모델 값을 그대로 둠

export type VerifiedCandidate = ActionCandidate & {
  due_check: DueCheck;
  /** 코드로 바꾸기 전 모델이 낸 날짜 */
  model_due: string | null;
};

export type VerifyResult = {
  kept: VerifiedCandidate[];
  dropped: { candidate: ActionCandidate; reason: "QUOTE_NOT_FOUND" }[];
};

export function verifyCandidates(candidates: ActionCandidate[], source: { text: string; occurredAt: Date }): VerifyResult {
  const result: VerifyResult = { kept: [], dropped: [] };

  for (const candidate of candidates) {
    if (!quoteInText(candidate.quote, source.text)) {
      result.dropped.push({ candidate, reason: "QUOTE_NOT_FOUND" });
      continue;
    }
    result.kept.push(checkDue(candidate, source.occurredAt));
  }
  return result;
}

function checkDue(candidate: ActionCandidate, occurredAt: Date): VerifiedCandidate {
  const base = { ...candidate, model_due: candidate.due };
  if (!candidate.due_text) return { ...base, due_check: candidate.due ? "unresolved" : "none" };

  const computed = resolveDueText(candidate.due_text, occurredAt);
  if (computed === null) return { ...base, due_check: "unresolved" };
  if (computed === candidate.due) return { ...base, due_check: "match" };
  return { ...base, due: computed, due_check: "corrected" };
}
