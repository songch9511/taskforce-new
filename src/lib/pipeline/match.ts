import type { Decide } from "./judge";
import { cosine } from "@/lib/ai/embed";
import { kstDate } from "@/lib/ai/prompts/extract";
import { MATCH_PROMPT_VERSION, RELATION_QUESTION, targetQuestion } from "@/lib/ai/prompts/match";

import type { CandidateSignal } from "./extract";
import type { UserIdentity } from "./identity";
import { quoteContext } from "./text";

// 매칭 (Phase 2): 새 후보가 기존 열린 Action의 새 일인지, 같은 일의 반복 · 변경 · 완료 · 취소인지 정한다.
// 임베딩으로 비슷한 Action을 최대 5개 추리고, 관계는 Jev(choice)에게 확률로 묻는다.

export type OpenAction = {
  id: string;
  title: string;
  counterpart: string | null;
  due: string | null;
  /** 가장 최근 근거 인용 */
  latestQuote: string | null;
  embedding: number[] | null;
};

export type MatchRelation = "new" | "duplicate" | "update" | "complete" | "cancel" | "unmatched";

export type MatchResult = {
  relation: MatchRelation;
  actionId: string | null;
  /** 관계와 대상 확률 중 작은 값 */
  confidence: number;
  /** 확신이 낮으면 병합을 사용자에게 확인받는다 */
  needsConfirmation: boolean;
  shortlist: string[];
  promptVersion: string;
  cost?: number;
};

export const MATCH_THRESHOLDS = {
  /** 이보다 덜 비슷한 Action은 후보에서 뺀다 */
  minSimilarity: 0.3,
  shortlistSize: 5,
  /** 이 미만이면 병합을 확인받는다 */
  confirmBelow: 0.6,
} as const;

export function shortlistActions(vector: number[], actions: OpenAction[], options = MATCH_THRESHOLDS): OpenAction[] {
  return actions
    .filter((a) => a.embedding)
    .map((a) => ({ action: a, score: cosine(vector, a.embedding!) }))
    .filter((s) => s.score >= options.minSimilarity)
    .sort((a, b) => b.score - a.score)
    .slice(0, options.shortlistSize)
    .map((s) => s.action);
}

export type MatchCandidate = { title: string; quote: string; due_text: string | null; due: string | null; signal: CandidateSignal };
export type MatchSource = { text: string; kind: string; occurredAt: Date };

const RELATION_MAP: Record<string, MatchRelation> = {
  new: "new",
  same_restated: "duplicate",
  same_changed: "update",
  same_done: "complete",
  same_cancelled: "cancel",
};

export function buildMatchRequest(candidate: MatchCandidate, source: MatchSource, identity: UserIdentity, shortlist: OpenAction[]) {
  const existing = shortlist.map((a, i) => ({
    key: `t${i + 1}`,
    label: [a.title, a.counterpart && `상대 ${a.counterpart}`, a.due && `기한 ${a.due}`].filter(Boolean).join(" · "),
    latest_quote: a.latestQuote,
  }));
  return {
    state: {
      user: { name: identity.name, aliases: identity.aliases },
      candidate: { title: candidate.title, quote: candidate.quote, due_text: candidate.due_text, due: candidate.due },
      context: quoteContext(source.text, candidate.quote) ?? candidate.quote,
      source: { kind: source.kind, occurred_at: kstDate(source.occurredAt).iso },
      existing: existing.map(({ key, label, latest_quote }) => ({ key, task: label, latest_quote })),
    },
    questions: { relation: RELATION_QUESTION, target: targetQuestion(existing) },
  };
}

/** Jev 답을 관계로 바꾼다. 새 약속이 아니면서 기존 Action과 이어지지 않는 변화 발언은 버린다(unmatched). */
export function decideMatch(
  answers: Record<string, { type: string; choice?: string; probabilities?: Record<string, number> }>,
  shortlist: OpenAction[],
  signal: CandidateSignal,
): Omit<MatchResult, "shortlist" | "promptVersion" | "cost"> {
  const relation = answers.relation;
  const target = answers.target;
  const relationKey = relation?.choice ?? "new";
  const targetKey = target?.choice ?? "none";
  const index = targetKey.startsWith("t") ? Number(targetKey.slice(1)) - 1 : -1;
  const action = shortlist[index];
  const mapped = RELATION_MAP[relationKey] ?? "new";

  if (mapped === "new" || !action) {
    const relationless = signal === "commitment" ? "new" : "unmatched";
    const p = relation?.probabilities?.new ?? 1;
    return { relation: relationless, actionId: null, confidence: p, needsConfirmation: false };
  }

  const confidence = Math.min(relation?.probabilities?.[relationKey] ?? 0, target?.probabilities?.[targetKey] ?? 0);
  return { relation: mapped, actionId: action.id, confidence, needsConfirmation: confidence < MATCH_THRESHOLDS.confirmBelow };
}

export async function matchCandidate(
  candidate: MatchCandidate,
  source: MatchSource,
  identity: UserIdentity,
  shortlist: OpenAction[],
  decide: Decide,
): Promise<MatchResult> {
  const base = { shortlist: shortlist.map((a) => a.id), promptVersion: MATCH_PROMPT_VERSION };
  // 비슷한 Action이 없으면 묻지 않는다.
  if (shortlist.length === 0) {
    return { ...base, relation: candidate.signal === "commitment" ? "new" : "unmatched", actionId: null, confidence: 1, needsConfirmation: false };
  }
  const response = await decide(buildMatchRequest(candidate, source, identity, shortlist));
  return { ...base, ...decideMatch(response.answers, shortlist, candidate.signal), cost: response.usage?.cost };
}
