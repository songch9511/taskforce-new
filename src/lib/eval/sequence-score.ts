import type { GoldenCase } from "./golden";
import { labelQuotesOverlap } from "./score";

// 시퀀스 채점 (Phase 2): 여러 원문을 순서대로 처리한 뒤 남은 Action이 정답과 맞는지 본다.
// Action과 정답은 근거 인용이 겹치는지로 짝짓는다. 한 정답에 Action이 여럿이면 병합 실패(split),
// Action 하나가 정답 여럿을 덮으면 잘못 합친 것(over-merge)이다.

export type FinalAction = {
  id: string;
  title: string;
  quotes: string[];
  due: string | null;
  status: string | null;
  owner: string | null;
  /** 앱에서 확인 요청으로 보일 이유 (projectAction의 confirm_reasons). 비었으면 확인 없이 반영된 Action */
  confirmReasons?: string[];
};

export type SequenceScore = {
  caseId: string;
  expected: number;
  /** Action 하나와 짝지어지고 기한 · 상태 · 담당이 모두 맞은 정답 수 */
  correct: number;
  splits: { title: string; actions: number }[];
  overMerged: { title: string }[];
  misses: { title: string }[];
  /** pending: 확인 요청으로 남음 (자동 반영이 아님). 취소(dropped)된 오탐은 사용자에게 보이지 않으므로 자동 반영으로 세지 않는다 */
  extras: { title: string; kind: string; pending: boolean; dropped: boolean }[];
  fieldErrors: { title: string; field: "due" | "status" | "owner"; expected: string | null; actual: string | null }[];
  /** 확인 요청이 남은 열린 Action (정답과 짝지어진 것 · 오탐 모두, 확인 요청인 오탐은 extras에도 들어 있다). 정답이 맞아도 확인 요청이 남으면 사용자가 한 번 더 눌러야 한다 */
  pendingReview: { title: string; reasons: string[] }[];
};

export function scoreSequence(golden: GoldenCase, finals: FinalAction[]): SequenceScore {
  const score: SequenceScore = {
    caseId: golden.id,
    expected: golden.expected_actions.length,
    correct: 0,
    splits: [],
    overMerged: [],
    misses: [],
    extras: [],
    fieldErrors: [],
    pendingReview: [],
  };
  const pending = (action: FinalAction) => (action.confirmReasons?.length ?? 0) > 0;
  const matchesOf = (quotes: string[]) => (action: FinalAction) => action.quotes.some((q) => quotes.some((e) => labelQuotesOverlap(e, q)));

  const claimed = new Map<string, number>();
  const matchedPerExpected = golden.expected_actions.map((expected) => {
    const matches = finals.filter(matchesOf(expected.evidence.map((e) => e.quote)));
    for (const m of matches) claimed.set(m.id, (claimed.get(m.id) ?? 0) + 1);
    return { expected, matches };
  });

  for (const { expected, matches } of matchedPerExpected) {
    if (matches.length === 0) {
      score.misses.push({ title: expected.title });
      continue;
    }
    if (matches.length > 1) {
      score.splits.push({ title: expected.title, actions: matches.length });
      continue;
    }
    const [action] = matches;
    if ((claimed.get(action.id) ?? 0) > 1) {
      score.overMerged.push({ title: expected.title });
      continue;
    }
    const checks: { field: "due" | "status" | "owner"; expected: string | null; actual: string | null }[] = [
      { field: "due", expected: expected.due ?? null, actual: action.due },
      { field: "status", expected: expected.status, actual: action.status },
      { field: "owner", expected: expected.owner, actual: action.owner },
    ];
    const wrong = checks.filter((c) => c.expected !== c.actual);
    score.fieldErrors.push(...wrong.map((w) => ({ title: expected.title, ...w })));
    if (wrong.length === 0) score.correct++;
  }

  for (const action of finals) {
    if (claimed.has(action.id)) continue;
    const trap = golden.must_not_extract.find((t) => action.quotes.some((q) => labelQuotesOverlap(t.quote, q)));
    score.extras.push({ title: action.title, kind: trap?.reason ?? "UNLABELED", pending: pending(action), dropped: action.status === "dropped" });
  }
  for (const action of finals) {
    if (pending(action) && action.status !== "done" && action.status !== "dropped") {
      score.pendingReview.push({ title: action.title, reasons: action.confirmReasons! });
    }
  }
  return score;
}

export function sequenceTotals(scores: SequenceScore[]) {
  const sum = (pick: (s: SequenceScore) => number) => scores.reduce((n, s) => n + pick(s), 0);
  const expected = sum((s) => s.expected);
  const correct = sum((s) => s.correct);
  return {
    cases: scores.length,
    expected,
    correct,
    /** 병합 정확도: 정답 Action이 정확히 하나로, 맞는 기한 · 상태 · 담당으로 남은 비율 */
    accuracy: expected ? correct / expected : null,
    splits: sum((s) => s.splits.length),
    overMerged: sum((s) => s.overMerged.length),
    misses: sum((s) => s.misses.length),
    extras: sum((s) => s.extras.length),
    /** 오탐 중 확인 없이 반영된 것 (함정 자동 반영) */
    extrasAuto: sum((s) => s.extras.filter((x) => !x.pending && !x.dropped).length),
    fieldErrors: sum((s) => s.fieldErrors.length),
    pendingReview: sum((s) => s.pendingReview.length),
  };
}
