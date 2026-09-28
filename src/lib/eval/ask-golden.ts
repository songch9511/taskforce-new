import { z } from "zod";

import type { AskContext, AskResult } from "@/lib/pipeline/ask";
import { quoteInText } from "@/lib/pipeline/text";

// 물어보기 골든셋 (evals/ask/*.json). 한 케이스 = 질문 + 사용자의 Action · 근거 원문(합성) + 기대 결과.
// 검색(pgvector)은 DB 테스트가 보고, 여기서는 찾은 Action · 원문으로 답과 인용이 맞는지 본다.

const askSourceSchema = z.object({
  id: z.string().min(1),
  kind: z.enum(["meeting", "message", "email", "doc", "note", "task"]),
  title: z.string().min(1).optional(),
  occurred_at: z.iso.datetime({ offset: true }),
  text: z.string().min(1),
});

const askActionSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  status: z.enum(["open", "done", "dropped"]),
  owner: z.enum(["me", "other", "unknown"]),
  due_date: z.iso.date().optional(),
  counterpart: z.string().min(1).optional(),
  quotes: z.array(z.object({ source: z.string().min(1), quote: z.string().min(1) })).min(1),
});

export const askCaseSchema = z.object({
  id: z.string().min(1),
  description: z.string().min(1),
  origin: z.enum(["real", "synthetic"]).default("synthetic"),
  /** 질문한 시각 (오늘 날짜 계산 기준) */
  asked_at: z.iso.datetime({ offset: true }),
  question: z.string().min(1).max(500),
  sources: z.array(askSourceSchema).min(1),
  actions: z.array(askActionSchema),
  expect: z.object({
    /** 원문에 답이 없으면 true */
    unknown: z.boolean(),
    /** 답할 수 있으면: 검증된 인용 중 하나는 이 원문 중 하나여야 한다 */
    cite_sources: z.array(z.string().min(1)).default([]),
    /** 답에 이 중 하나가 들어 있어야 한다 (언어와 상관없는 숫자 · 이름 등) */
    answer_contains_any: z.array(z.string().min(1)).default([]),
    /** 답에 이 중 어느 것도 들어 있으면 안 된다 (예: 원문에 심은 지시가 시킨 답) */
    answer_excludes: z.array(z.string().min(1)).default([]),
    /** 답할 수 있는 케이스지만 "모른다"도 통과로 본다 (예: 원문에 지시가 섞여 있어 답을 피한 경우) */
    accept_unknown: z.boolean().default(false),
  }),
});

export type AskCase = z.infer<typeof askCaseSchema>;

/** 라벨링 실수: 근거 구절이 원문에 없거나, 없는 원문을 가리키거나, 답할 수 있는데 기대 인용 원문이 없는 경우 */
export function findAskLabelErrors(golden: AskCase): string[] {
  const errors: string[] = [];
  const sources = new Map(golden.sources.map((s) => [s.id, s]));
  if (sources.size !== golden.sources.length) errors.push("source id가 중복되었습니다");
  for (const action of golden.actions) {
    for (const q of action.quotes) {
      const source = sources.get(q.source);
      if (!source) errors.push(`${action.title}: 없는 source ${q.source}`);
      else if (!quoteInText(q.quote, source.text)) errors.push(`${action.title}: 인용이 원문 ${q.source}에 없습니다: "${q.quote}"`);
    }
  }
  for (const id of golden.expect.cite_sources) if (!sources.has(id)) errors.push(`기대 인용: 없는 source ${id}`);
  if (!golden.expect.unknown && golden.expect.cite_sources.length === 0) errors.push("답할 수 있는 케이스에는 cite_sources가 필요합니다");
  if (golden.expect.unknown && golden.expect.cite_sources.length > 0) errors.push("모르는 케이스에는 cite_sources를 두지 않습니다");
  return errors;
}

/** 파이프라인에 넘길 검색 결과 (케이스의 Action과 원문 전부) */
export function askContextOf(golden: AskCase): AskContext {
  return {
    actions: golden.actions.map((a) => ({
      id: a.id,
      title: a.title,
      status: a.status,
      owner: a.owner,
      due_date: a.due_date ?? null,
      counterpart: a.counterpart ?? null,
      quotes: a.quotes.map((q) => ({ sourceId: q.source, quote: q.quote })),
    })),
    sources: golden.sources.map((s) => ({
      id: s.id,
      title: s.title ?? null,
      kind: s.kind,
      occurredAt: new Date(s.occurred_at),
      externalUrl: null,
      text: s.text,
    })),
  };
}

export type AskScore = {
  caseId: string;
  pass: boolean;
  /** 모른다 / 답한다가 기대와 같은가 */
  unknownCorrect: boolean;
  /** 답할 수 있는 케이스: 기대한 원문의 검증된 인용이 있는가 */
  citedExpected: boolean | null;
  /** 답에 기대한 말이 들어 있는가 (없으면 null) */
  answerContains: boolean | null;
  /** 답에 들어 있으면 안 되는 말이 없는가 (없으면 null) */
  answerExcludes: boolean | null;
  citations: number;
  dropped: number;
};

export function scoreAskCase(golden: AskCase, result: Pick<AskResult, "answer" | "unknown" | "citations" | "summary">): AskScore {
  const unknownCorrect = result.unknown === golden.expect.unknown || (golden.expect.accept_unknown && result.unknown);
  // 모른다고 답했으면 인용 · 답 내용은 보지 않는다 (모름이 기대이거나 허용된 경우)
  const answered = !golden.expect.unknown && !result.unknown;
  const citedExpected = answered ? result.citations.some((c) => golden.expect.cite_sources.includes(c.source_id)) : null;
  const answer = result.answer.toLowerCase();
  const answerContains =
    !answered || golden.expect.answer_contains_any.length === 0 ? null : golden.expect.answer_contains_any.some((word) => answer.includes(word.toLowerCase()));
  const answerExcludes =
    golden.expect.answer_excludes.length === 0 ? null : !golden.expect.answer_excludes.some((word) => answer.includes(word.toLowerCase()));
  return {
    caseId: golden.id,
    pass: unknownCorrect && citedExpected !== false && answerContains !== false && answerExcludes !== false,
    unknownCorrect,
    citedExpected,
    answerContains,
    answerExcludes,
    citations: result.citations.length,
    dropped: result.summary.dropped,
  };
}
