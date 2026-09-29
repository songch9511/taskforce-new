import { resolveDueText } from "./dates";
import type { ActionCandidate } from "./extract";
import { anyQuoteFragmentInText, quotedHistoryStart, quoteInText } from "./text";

// ② 기계적 검증 (docs/TRUTH_RULES.md 1장). LLM 없이 싸고 확실한 것부터 거른다.
// - 인용이 원문에 없으면 환각이므로 버린다.
// - 메일이면, 인용이 이전 메일을 인용한 부분(quotedHistoryStart 뒤)에만 있는 후보도 버린다. 그것은 옛 메일의 말이라
//   그 메일이 들어올 때 이미 Claim이 됐다. 새 메일의 시각으로 다시 뽑으면 이미 끝난 일이 새 할 일이 되고 늦춘 기한이 되돌아간다.
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
  dropped: { candidate: ActionCandidate; reason: "QUOTE_NOT_FOUND" | "QUOTED_HISTORY" }[];
};

/**
 * @param source.kind 원문 종류. "email"일 때만 인용된 옛 메일 규칙을 쓴다 (없으면 쓰지 않는다: 사용자가 직접 고른 구절 등)
 */
export function verifyCandidates(candidates: ActionCandidate[], source: { text: string; occurredAt: Date; kind?: string }): VerifyResult {
  const result: VerifyResult = { kept: [], dropped: [] };
  const historyAt = source.kind === "email" ? quotedHistoryStart(source.text) : null;
  const newText = historyAt === null ? source.text : source.text.slice(0, historyAt);

  for (const candidate of candidates) {
    if (!quoteInText(candidate.quote, source.text)) {
      result.dropped.push({ candidate, reason: "QUOTE_NOT_FOUND" });
      continue;
    }
    // "..."로 이은 인용은 조각 중 하나라도 새 글에 있으면 남긴다 (새 글과 인용에 걸친 인용을 옛 메일의 말로 잘못 버리지 않게)
    if (!anyQuoteFragmentInText(candidate.quote, newText)) {
      result.dropped.push({ candidate, reason: "QUOTED_HISTORY" });
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
