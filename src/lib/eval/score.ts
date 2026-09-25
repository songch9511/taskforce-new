import type { GoldenCase } from "./golden";

// 추출 결과를 골든셋 정답과 비교해 채점한다. 후보와 정답은 "인용 구절이 겹치는가"로 짝짓는다.
// 제목은 표현이 제각각이라 비교하지 않는다.

export type ScoredCandidate = {
  title: string;
  quote: string;
  owner: "me" | "unknown";
  due: string | null;
};

export type FalsePositiveKind = "NOT_MY_ACTION" | "INFO_ONLY" | "TENTATIVE" | "ALREADY_DONE" | "DUPLICATE" | "UNLABELED";

export type CaseScore = {
  caseId: string;
  truePositives: number;
  ownerCorrect: number;
  dueCorrect: number;
  falsePositives: { candidate: ScoredCandidate; kind: FalsePositiveKind }[];
  misses: { title: string; quote: string }[];
  fieldErrors: { title: string; field: "owner" | "due"; expected: string | null; actual: string | null }[];
  /** 원문에 없는 인용을 단 후보 (환각) */
  hallucinated: ScoredCandidate[];
};

export type Totals = {
  cases: number;
  truePositives: number;
  falsePositives: number;
  misses: number;
  ownerCorrect: number;
  dueCorrect: number;
  hallucinated: number;
  falsePositivesByKind: Record<FalsePositiveKind, number>;
  precision: number | null;
  recall: number | null;
  ownerAccuracy: number | null;
  dueAccuracy: number | null;
};

// 공백 · 문장부호 · 기호를 지우고 비교한다.
export function normalizeForMatch(text: string): string {
  return text.toLowerCase().replace(/[\s\p{P}\p{S}]/gu, "");
}

export function quoteInText(quote: string, text: string): boolean {
  const q = normalizeForMatch(quote);
  return q.length > 0 && normalizeForMatch(text).includes(q);
}

// 한쪽이 다른 쪽을 포함하거나, 가장 긴 공통 구간이 짧은 쪽의 60% 이상(최소 6자)이면 같은 구절로 본다.
export function quotesOverlap(a: string, b: string): boolean {
  const x = normalizeForMatch(a);
  const y = normalizeForMatch(b);
  if (!x || !y) return false;
  if (x.includes(y) || y.includes(x)) return true;
  const shorter = Math.min(x.length, y.length);
  return longestCommonSubstring(x, y) >= Math.max(6, Math.ceil(shorter * 0.6));
}

function longestCommonSubstring(a: string, b: string): number {
  let best = 0;
  let prev = new Array<number>(b.length + 1).fill(0);
  for (let i = 1; i <= a.length; i++) {
    const row = new Array<number>(b.length + 1).fill(0);
    for (let j = 1; j <= b.length; j++) {
      if (a[i - 1] === b[j - 1]) {
        row[j] = prev[j - 1] + 1;
        if (row[j] > best) best = row[j];
      }
    }
    prev = row;
  }
  return best;
}

export function scoreCase(golden: GoldenCase, candidates: ScoredCandidate[]): CaseScore {
  const sourceText = golden.sources.map((s) => s.text).join("\n");
  const matched = new Set<number>();
  const score: CaseScore = {
    caseId: golden.id,
    truePositives: 0,
    ownerCorrect: 0,
    dueCorrect: 0,
    falsePositives: [],
    misses: [],
    fieldErrors: [],
    hallucinated: [],
  };

  for (const candidate of candidates) {
    if (!quoteInText(candidate.quote, sourceText)) score.hallucinated.push(candidate);

    const hits = golden.expected_actions
      .map((action, index) => ({ action, index }))
      .filter(({ action }) => action.evidence.some((e) => quotesOverlap(e.quote, candidate.quote)));
    const free = hits.find(({ index }) => !matched.has(index));

    if (free) {
      matched.add(free.index);
      score.truePositives++;
      const expectedDue = free.action.due ?? null;
      if (free.action.owner === candidate.owner) {
        score.ownerCorrect++;
      } else {
        score.fieldErrors.push({ title: free.action.title, field: "owner", expected: free.action.owner, actual: candidate.owner });
      }
      if (expectedDue === candidate.due) {
        score.dueCorrect++;
      } else {
        score.fieldErrors.push({ title: free.action.title, field: "due", expected: expectedDue, actual: candidate.due });
      }
      continue;
    }

    if (hits.length > 0) {
      score.falsePositives.push({ candidate, kind: "DUPLICATE" });
      continue;
    }

    const trap = golden.must_not_extract.find((n) => quotesOverlap(n.quote, candidate.quote));
    score.falsePositives.push({ candidate, kind: trap ? trap.reason : "UNLABELED" });
  }

  golden.expected_actions.forEach((action, index) => {
    if (!matched.has(index)) score.misses.push({ title: action.title, quote: action.evidence[0].quote });
  });

  return score;
}

export function totals(scores: CaseScore[]): Totals {
  const byKind: Record<FalsePositiveKind, number> = {
    NOT_MY_ACTION: 0,
    INFO_ONLY: 0,
    TENTATIVE: 0,
    ALREADY_DONE: 0,
    DUPLICATE: 0,
    UNLABELED: 0,
  };
  let tp = 0;
  let fp = 0;
  let fn = 0;
  let owner = 0;
  let due = 0;
  let hallucinated = 0;
  for (const s of scores) {
    tp += s.truePositives;
    fp += s.falsePositives.length;
    fn += s.misses.length;
    owner += s.ownerCorrect;
    due += s.dueCorrect;
    hallucinated += s.hallucinated.length;
    for (const f of s.falsePositives) byKind[f.kind]++;
  }
  const ratio = (n: number, d: number) => (d === 0 ? null : n / d);
  return {
    cases: scores.length,
    truePositives: tp,
    falsePositives: fp,
    misses: fn,
    ownerCorrect: owner,
    dueCorrect: due,
    hallucinated,
    falsePositivesByKind: byKind,
    precision: ratio(tp, tp + fp),
    recall: ratio(tp, tp + fn),
    ownerAccuracy: ratio(owner, tp),
    dueAccuracy: ratio(due, tp),
  };
}
