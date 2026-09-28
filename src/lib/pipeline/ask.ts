import { z } from "zod";

import { answerLanguage, ASK_PROMPT_VERSION, ASK_SYSTEM_PROMPT, buildAskUserPrompt, type AskPromptAction, type AskPromptSource } from "@/lib/ai/prompts/ask";
import type { AskCitation } from "@/lib/api/contract";

import type { CompleteJson } from "./extract";
import { findQuoteSpan, normalizeForMatch, quoteContext } from "./text";

// 물어보기 (POST /api/v1/ask): 질문 → 임베딩 → 가까운 Action과 근거 원문(retrieve) → LLM 구조화 출력 → 인용 기계 검증.
// DB와 분리된 순수 함수라 API · eval · 테스트에서 같은 코드를 쓴다. 질문 · 답은 로그에 남기지 않는다.
// 원칙 2: 모든 인용은 원문에 실제로 있어야 한다. 돌려주는 인용은 모델이 쓴 문자열이 아니라 원문에서 잘라 낸 구간이다.
// 검증된 인용이 하나도 없으면 답하지 않고 "모른다"로 둔다.

export type AskAction = {
  id: string;
  title: string;
  status: "open" | "done" | "dropped";
  owner: "me" | "other" | "unknown";
  due_date: string | null;
  counterpart: string | null;
  /** 이 Action의 근거 구절 (evidence · claims), 최근 것부터 */
  quotes: { sourceId: string; quote: string }[];
};

export type AskSource = {
  id: string;
  title: string | null;
  kind: string;
  occurredAt: Date | null;
  externalUrl: string | null;
  /**
   * 원문 전체 (인용 검증용). 모델에는 근거 구절 앞뒤만 보낸다.
   * null: 보관 기간(90일)이 지나 글이 지워졌다. 이때는 저장된 근거 구절(evidence · Claim)만 보내고 그 안에서 인용을 확인한다.
   */
  text: string | null;
};

export type AskContext = { actions: AskAction[]; sources: AskSource[] };

export type AskDeps = {
  embed: (texts: string[]) => Promise<number[][]>;
  /** 질문 임베딩과 가까운 Action과 그 근거 원문 (DB에서는 pgvector, eval에서는 케이스의 Action) */
  retrieve: (vector: number[]) => Promise<AskContext>;
  complete: CompleteJson;
};

export type AskResult = {
  answer: string;
  unknown: boolean;
  citations: AskCitation[];
  /** 로그 · eval용 숫자. 질문 · 답 · 인용은 담지 않는다 */
  summary: { actions: number; sources: number; citations: number; dropped: number; model: string | null; promptVersion: string; cost: number };
};

// 모델에게 주는 응답 스키마. 번호(A1 · S1)로 가리키게 해서 id를 지어내지 못하게 한다.
export const askModelResponseSchema = z.object({
  unknown: z.boolean(),
  answer: z.string(),
  citations: z.array(z.object({ source: z.string(), action: z.string().nullable(), quote: z.string() })),
});
export type AskModelResponse = z.infer<typeof askModelResponseSchema>;

/** 답에 담는 인용 수 상한 */
const MAX_CITATIONS = 5;
/** Action 하나에서 모델에 보내는 근거 구절 수 */
const QUOTES_PER_ACTION = 4;
/** 원문 하나에서 보내는 발췌 길이 상한 (글자) */
const EXCERPT_CHARS = 700;
const SOURCE_CHARS = 2400;
/** 이보다 짧은 인용은 무엇이든 맞아 버려서 근거로 치지 않는다 (공백 · 문장부호 뺀 글자 수) */
const MIN_QUOTE_CHARS = 4;

/** 근거를 찾지 못했을 때의 답. 질문이 한국어면 한국어, 아니면 영어 */
export function notFoundAnswer(question: string): string {
  return answerLanguage(question) === "한국어" ? "연결된 원문에서 찾지 못했어요." : "I couldn't find that in your sources.";
}

type Aliased = { actions: Map<string, AskAction>; sources: Map<string, AskSource>; prompt: { actions: AskPromptAction[]; sources: AskPromptSource[] } };

/** Action · 원문에 번호를 붙이고, 원문마다 근거 구절 앞뒤 발췌를 만든다. */
function aliasContext(context: AskContext): Aliased {
  const sourceById = new Map(context.sources.map((s) => [s.id, s]));
  const sourceAlias = new Map<string, string>();
  const quotesBySource = new Map<string, string[]>();
  const actions = new Map<string, AskAction>();
  const promptActions: AskPromptAction[] = [];

  context.actions.forEach((action, i) => {
    const alias = `A${i + 1}`;
    actions.set(alias, action);
    const quotes = action.quotes.filter((q) => sourceById.has(q.sourceId)).slice(0, QUOTES_PER_ACTION);
    for (const q of quotes) {
      if (!sourceAlias.has(q.sourceId)) sourceAlias.set(q.sourceId, `S${sourceAlias.size + 1}`);
      quotesBySource.set(q.sourceId, [...(quotesBySource.get(q.sourceId) ?? []), q.quote]);
    }
    promptActions.push({
      alias,
      title: action.title,
      status: action.status,
      owner: action.owner,
      due: action.due_date,
      counterpart: action.counterpart,
      quotes: quotes.map((q) => ({ source: sourceAlias.get(q.sourceId)!, quote: q.quote })),
    });
  });

  const sources = new Map<string, AskSource>();
  const promptSources: AskPromptSource[] = [];
  for (const [sourceId, alias] of sourceAlias) {
    const source = sourceById.get(sourceId)!;
    sources.set(alias, source);
    const excerpts: string[] = [];
    let length = 0;
    for (const quote of quotesBySource.get(sourceId) ?? []) {
      // 원문이 지워졌으면 저장된 근거 구절 자체가 발췌다.
      const excerpt = source.text === null ? quote : (quoteContext(source.text, quote, 2, EXCERPT_CHARS) ?? findQuoteSpan(source.text, quote)?.quote ?? null);
      if (!excerpt || excerpts.some((e) => e.includes(excerpt) || excerpt.includes(e))) continue;
      if (length + excerpt.length > SOURCE_CHARS) break;
      excerpts.push(excerpt);
      length += excerpt.length;
    }
    if (excerpts.length === 0 && source.text) excerpts.push(source.text.slice(0, EXCERPT_CHARS));
    promptSources.push({ alias, kind: source.kind, title: source.title, occurredAt: source.occurredAt, excerpts });
  }
  return { actions, sources, prompt: { actions: promptActions, sources: promptSources } };
}

/** 모델이 번호를 "[S1]" · "s1" · "S 1"처럼 적어도 같은 번호로 읽는다 (구절 검증은 그대로 엄격하다) */
function aliasOf(value: string | null, prefix: "A" | "S"): string | null {
  const match = value?.match(new RegExp(`${prefix}\\s*(\\d+)`, "i"));
  return match ? `${prefix}${Number(match[1])}` : null;
}

/** 인용을 찾을 곳: 원문 전체, 원문이 지워졌으면 그 원문에서 저장해 둔 근거 구절들 */
function quoteHaystacks(source: AskSource, actions: Iterable<AskAction>): string[] {
  if (source.text !== null) return [source.text];
  return [...actions].flatMap((a) => a.quotes.filter((q) => q.sourceId === source.id).map((q) => q.quote));
}

/**
 * 모델이 낸 인용을 원문과 대조한다: 모르는 원문 번호 · 원문에 이어진 한 덩어리로 없는 구절("..."로 이은 조각 포함) · 너무 짧은 구절은 버린다.
 * 남긴 인용의 quote는 원문에서 잘라 낸 구간이다 (모델의 문자열을 그대로 쓰지 않는다).
 * 할 일 번호는 그 할 일의 근거 원문일 때만 남기고, 아니면 null로 둔다. 같은 원문의 같은 구절은 하나로 합친다.
 */
export function verifyCitations(raw: AskModelResponse["citations"], aliased: Pick<Aliased, "actions" | "sources">): { citations: AskCitation[]; dropped: number } {
  const citations: AskCitation[] = [];
  const seen = new Set<string>();
  let dropped = 0;
  for (const c of raw) {
    const sourceAlias = aliasOf(c.source, "S");
    const source = sourceAlias ? aliased.sources.get(sourceAlias) : undefined;
    const span = source ? quoteHaystacks(source, aliased.actions.values()).map((text) => findQuoteSpan(text, c.quote)).find((s) => s !== null) : undefined;
    if (!source || !span || normalizeForMatch(span.quote).length < MIN_QUOTE_CHARS) {
      dropped++;
      continue;
    }
    const key = `${source.id}:${normalizeForMatch(span.quote)}`;
    if (seen.has(key) || citations.length >= MAX_CITATIONS) continue;
    seen.add(key);
    const actionAlias = aliasOf(c.action, "A");
    const action = actionAlias ? aliased.actions.get(actionAlias) : undefined;
    citations.push({
      action_id: action && action.quotes.some((q) => q.sourceId === source.id) ? action.id : null,
      source_id: source.id,
      source_title: source.title,
      source_kind: source.kind,
      occurred_at: source.occurredAt?.toISOString() ?? null,
      external_url: source.externalUrl,
      quote: span.quote,
    });
  }
  return { citations, dropped };
}

export async function answerQuestion(question: string, deps: AskDeps, now = new Date()): Promise<AskResult> {
  const [vector] = await deps.embed([question]);
  const context = await deps.retrieve(vector);
  const aliased = aliasContext(context);
  const base = { actions: aliased.actions.size, sources: aliased.sources.size, promptVersion: ASK_PROMPT_VERSION };
  const unknown = (extra: Partial<AskResult["summary"]> = {}): AskResult => ({
    answer: notFoundAnswer(question),
    unknown: true,
    citations: [],
    summary: { ...base, citations: 0, dropped: 0, model: null, cost: 0, ...extra },
  });

  // 찾을 할 일이 없으면 모델을 부르지 않는다.
  if (aliased.actions.size === 0 || aliased.sources.size === 0) return unknown();

  const result = await deps.complete({
    system: ASK_SYSTEM_PROMPT,
    user: buildAskUserPrompt({ question, now, ...aliased.prompt }),
    schemaName: "ask_answer",
    schema: askModelResponseSchema,
    maxTokens: 2048,
  });
  const { citations, dropped } = verifyCitations(result.data.citations, aliased);
  const answer = result.data.answer.trim();
  const usage = { model: result.model, cost: result.usage?.cost ?? 0, dropped };

  // 모델이 모른다고 했거나, 검증된 근거가 하나도 없으면 답하지 않는다 (근거 없는 답은 버그다).
  if (result.data.unknown || citations.length === 0 || answer.length === 0) return unknown(usage);
  return { answer, unknown: false, citations, summary: { ...base, ...usage, citations: citations.length } };
}
