import { z } from "zod";

import { buildMissingUserPrompt, MISSING_PROMPT_VERSION, MISSING_SYSTEM_PROMPT } from "@/lib/ai/prompts/missing";
import { JUDGE_PROMPT_VERSION } from "@/lib/ai/prompts/judge";

import { blankToNull, clamp01, isIsoDate, type ActionCandidate, type ExtractInput } from "./extract";
import { judgeCandidate, type Decide, type JudgeDecision } from "./judge";
import { MATCH_THRESHOLDS } from "./match";
import type { ActionStore } from "./merge";
import type { JudgedCandidate, PipelineDeps } from "./run";
import { normalizeForMatch, quoteContext } from "./text";
import { verifyCandidates } from "./verify";

// 빠진 할 일 신고 (Phase A1, 지표 4). 사용자가 원문 구절을 골라 "여기 내 할 일이 있다"고 알려주면
// 그 구절 하나를 후보로 만들어 보통 파이프라인과 같은 병합(mergeJudged)으로 보낸다. DB와 분리된 순수 함수 + 주입 deps.
// - 할 일인지는 다시 묻지 않는다: 인용은 사용자가 고른 구절, 담당은 나, 신호는 commitment로 고정하고 Jev 결정은 auto로 둔다.
//   Jev는 Claim 속성(누가 · 얼마나 확정 · 직접 · 공유)을 얻는 데만 쓴다.
// - 기한은 verifyCandidates가 코드로 다시 계산한다.
// - classifyMiss는 원래 처리에서 어느 단계가 이 할 일을 놓쳤는지 가른다 (지표 4를 단계별로 본다).

export const MISS_STAGES = ["processing_failed", "not_extracted", "quoted_history", "judge_rejected", "merge_absorbed"] as const;

/** judge_logs.jev_answers.dropped: 연결 메일의 인용된 옛 메일에만 있어 기계 검증이 버린 후보 (pipeline/run.ts droppedQuotedHistory) */
export const QUOTED_HISTORY_DROP = "QUOTED_HISTORY";
/**
 * processing_failed: 원문 처리가 끝나지 않음(실패 · 아직 처리 중)
 * not_extracted:     겹치는 후보가 없음 (추출기가 못 뽑았거나, 뽑았지만 인용 검증에서 탈락)
 * quoted_history:    겹치는 후보가 연결 메일의 인용된 옛 메일에만 있어 기계 검증이 버림 (앱 응답에는 not_extracted로 보인다, process.ts)
 * judge_rejected:    겹치는 후보를 Jev가 기각
 * merge_absorbed:    겹치는 후보가 통과했지만 병합에서 다른 Action에 합쳐지거나 버려짐
 */
export type MissStage = (typeof MISS_STAGES)[number];

/** 두 인용이 같은 대목인지 볼 때의 글자 쌍(bigram) 유사도 기준 */
export const MISS_OVERLAP_THRESHOLD = 0.6;
/** 한쪽이 다른 쪽에 들어 있으면 겹친다고 보는 최소 길이 (정규화한 글자 수). 짧은 말("네")이 우연히 들어 있는 것은 뺀다 */
const MIN_CONTAINED_LENGTH = 4;

function bigrams(text: string): Map<string, number> {
  const counts = new Map<string, number>();
  const chars = [...text];
  for (let i = 0; i < chars.length - 1; i++) {
    const pair = chars[i] + chars[i + 1];
    counts.set(pair, (counts.get(pair) ?? 0) + 1);
  }
  return counts;
}

/**
 * 공백 · 문장부호를 무시하고, 한쪽이 다른 쪽에 들어 있거나 글자 쌍이 많이 겹치면 같은 대목으로 본다.
 * 누락 신고 전용: 사용자가 고른 구절을 판정 기록 · 근거 인용과 비교한다. eval 채점은 eval/score.ts labelQuotesOverlap을 쓴다.
 */
export function reportedQuoteOverlaps(a: string, b: string): boolean {
  const x = normalizeForMatch(a);
  const y = normalizeForMatch(b);
  if (!x || !y) return false;
  if (x === y) return true;
  const [shorter, longer] = x.length <= y.length ? [x, y] : [y, x];
  if ([...shorter].length >= MIN_CONTAINED_LENGTH && longer.includes(shorter)) return true;

  const bx = bigrams(x);
  const by = bigrams(y);
  let shared = 0;
  let total = 0;
  for (const count of bx.values()) total += count;
  for (const count of by.values()) total += count;
  for (const [pair, count] of bx) shared += Math.min(count, by.get(pair) ?? 0);
  return total > 0 && (2 * shared) / total >= MISS_OVERLAP_THRESHOLD;
}

export type MissLog = { quote: string; decision: JudgeDecision; /** 판정 전에 기계 검증이 버린 후보면 그 이유 */ dropped?: typeof QUOTED_HISTORY_DROP };

/**
 * 신고한 구절이 원래 처리의 어느 단계에서 빠졌는지 (순수 함수).
 * 겹치는 후보가 여럿이면 가장 멀리 간 단계를 쓴다: 통과한 후보가 있으면 merge_absorbed, Jev가 기각한 것이 있으면 judge_rejected,
 * 기계 검증이 인용된 옛 메일 속이라 버린 것뿐이면 quoted_history.
 */
export function classifyMiss(input: { processingStatus: string; logs: MissLog[]; quote: string }): MissStage {
  if (input.processingStatus !== "done") return "processing_failed";
  const overlapping = input.logs.filter((log) => reportedQuoteOverlaps(log.quote, input.quote));
  if (overlapping.length === 0) return "not_extracted";
  if (overlapping.some((log) => log.decision !== "reject")) return "merge_absorbed";
  return overlapping.some((log) => !log.dropped) ? "judge_rejected" : "quoted_history";
}

// 모델에게 주는 응답 스키마: 후보 하나. 인용 · 담당 · 신호는 코드가 정하므로 묻지 않는다.
export const missingResponseSchema = z.object({
  title: z.string(),
  counterpart: z.string().nullable(),
  due_text: z.string().nullable(),
  due: z.string().nullable().describe("YYYY-MM-DD"),
  due_confidence: z.number().nullable(),
});

export type MissingInput = ExtractInput & {
  /** 사용자가 고른 구절 (원문에 있는지는 호출하는 쪽이 먼저 확인한다) */
  quote: string;
};

export type MissingResult = {
  judged: JudgedCandidate;
  summary: {
    models: { missing: string; judge: string };
    promptVersions: { missing: string; judge: string };
    cost: number;
  };
};

export class QuoteNotInSourceError extends Error {
  constructor() {
    super("원문에 없는 구절입니다.");
    this.name = "QuoteNotInSourceError";
  }
}

/** 제목을 못 받았을 때 구절 앞부분을 제목으로 쓴다 */
const FALLBACK_TITLE_CHARS = 100;

export async function extractMissing(input: MissingInput, deps: PipelineDeps): Promise<MissingResult> {
  const quote = input.quote.trim();
  // 구절이 길어도 잘리지 않게 문맥 한도를 늘린다. 사용자는 여러 줄을 고를 수 있으므로, 원문에 있는 구절이면 몇 줄에 걸쳐도 찾는다.
  const context = quoteContext(input.text, quote, 4, Math.max(1500, quote.length + 1000), Infinity);
  if (!context) throw new QuoteNotInSourceError();

  const result = await deps.complete({
    system: MISSING_SYSTEM_PROMPT,
    user: buildMissingUserPrompt({ identity: input.identity, participants: input.participants, kind: input.kind, occurredAt: input.occurredAt, quote, context }),
    schemaName: "missing_action",
    schema: missingResponseSchema,
  });

  const due = isIsoDate(result.data.due) ? result.data.due : null;
  const candidate: ActionCandidate = {
    signal: "commitment",
    title: result.data.title.trim() || [...quote].slice(0, FALLBACK_TITLE_CHARS).join(""),
    quote,
    owner: "me",
    owner_confidence: 1,
    counterpart: blankToNull(result.data.counterpart),
    due_text: blankToNull(result.data.due_text),
    due,
    due_confidence: due === null || result.data.due_confidence === null ? null : clamp01(result.data.due_confidence),
    rationale: "사용자가 빠진 할 일로 신고한 구절",
  };

  const [verified] = verifyCandidates([candidate], { text: input.text, occurredAt: input.occurredAt }).kept;
  if (!verified) throw new QuoteNotInSourceError();

  const source = { text: input.text, kind: input.kind, occurredAt: input.occurredAt, participants: input.participants };
  const judge = await judgeCandidate(verified, source, input.identity, deps.decide);

  return {
    // 사용자가 할 일이라고 했으므로 결정은 auto. Claim 속성(judge.signals)은 Jev 답을 그대로 쓴다.
    judged: { candidate: verified, judge: { ...judge, decision: "auto", reasons: [], rule: undefined } },
    summary: {
      models: { missing: result.model, judge: judge.model },
      promptVersions: { missing: MISSING_PROMPT_VERSION, judge: JUDGE_PROMPT_VERSION },
      cost: (result.usage?.cost ?? 0) + (judge.cost ?? 0),
    },
  };
}

/**
 * 병합용 Decide. 신고는 "이 구절은 내 할 일"이라는 사용자의 말이므로 매칭 답을 두 가지로 고친다. 다른 판정(Jev 후보 검증)은 그대로 둔다.
 * - 기존 열린 Action의 완료 · 취소로 보더라도 그 Action을 끝내지 않고 같은 일을 다시 말한 것(same_restated → duplicate)으로 합친다.
 * - 같은 일이라는 확신이 낮으면(병합 확인이 필요한 수준) 새 일로 본다: 애매한 병합 확인 요청 뒤에 신고가 묻히지 않게 한다.
 *   확실한 반복 · 변경만 이미 있는 할 일(already_tracked)이 된다.
 */
export function reportMatchDecide(decide: Decide): Decide {
  return async (request) => {
    const response = await decide(request);
    const relation = response.answers.relation;
    if (relation?.type !== "choice" || relation.choice === "new") return response;

    const p = relation.probabilities;
    const ends = relation.choice === "same_done" || relation.choice === "same_cancelled";
    const choice = ends ? "same_restated" : relation.choice;
    const probabilities = ends ? { ...p, same_restated: Math.min(1, (p.same_restated ?? 0) + (p.same_done ?? 0) + (p.same_cancelled ?? 0)) } : p;
    // matchCandidate와 같은 확신도: 관계 확률과 대상 확률 중 작은 값
    const target = response.answers.target;
    const targetP = target?.type === "choice" ? (target.probabilities[target.choice] ?? 0) : 0;
    const confident = Math.min(probabilities[choice] ?? 0, targetP) >= MATCH_THRESHOLDS.confirmBelow;
    return {
      ...response,
      answers: { ...response.answers, relation: { ...relation, choice: confident ? choice : "new", probabilities } },
    };
  };
}

/**
 * 신고 흐름의 저장소: 매칭 후보에서 다른 사람 담당 Action을 뺀다. 사용자가 "내 할 일"이라고 했는데 동료의 Action에 합치면
 * 지금 할 일(/now)에 보이지 않기 때문이다. 만들기 · 더하기는 그대로 넘긴다.
 */
export function reportStore(store: ActionStore): ActionStore {
  return {
    shortlist: async (vector) => (await store.shortlist(vector)).filter((action) => action.owner !== "other"),
    create: (action) => store.create(action),
    append: (actionId, update) => store.append(actionId, update),
  };
}

export type SourceEvidence = { actionId: string; quote: string | null; owner: "me" | "other" | "unknown" };

/**
 * 이 원문에서 이미 Action의 근거로 쓰인 구절 중 신고한 구절과 겹치는 것 (순수 함수). 있으면 그 Action을 돌려주고
 * 추출 · 병합을 하지 않는다: 사용자가 이미 끝냈거나 지운 Action이어도 새로 만들지 않고(상세에서 다시 열 수 있다) 누락으로 세지 않는다.
 * 다른 사람 담당 Action은 빼고 본다 (reportStore와 같은 이유).
 */
export function trackedByEvidence(evidence: SourceEvidence[], quote: string): string | null {
  return evidence.find((e) => e.owner !== "other" && e.quote !== null && reportedQuoteOverlaps(e.quote, quote))?.actionId ?? null;
}

/**
 * 원문을 다시 처리할 때 병합할 후보 (순수 함수): 이 원문에서 이미 근거로 쓰인 구절과 겹치는 후보는 뺀다 (lib/sources/process.ts).
 * 누락 신고와 같은 겹침 기준을 쓰고, 담당과 상관없이 본다 (다른 사람 담당 Action의 근거도 두 번 붙이지 않는다).
 * 한 구절이 다른 구절을 품으면 겹친다고 보므로, 긴 근거 구절(직접 추가 때 고른 문단 등) 안의 다른 후보도 빠진다.
 * 다시 처리할 때만 쓰고, 근거가 두 번 붙는 것보다 낫다고 보고 받아들인다.
 */
export function unappliedCandidates<T extends { candidate: { quote: string } }>(judged: T[], appliedQuotes: string[]): T[] {
  return judged.filter(({ candidate }) => !appliedQuotes.some((quote) => reportedQuoteOverlaps(quote, candidate.quote)));
}
