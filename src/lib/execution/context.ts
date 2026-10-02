import { kstDate } from "@/lib/ai/prompts/extract";
import type { Participants, Person } from "@/lib/pipeline/identity";
import { findQuoteSpan, quoteContext } from "@/lib/pipeline/text";

// 실행(계획 · 초안)에 넘길 자료: Action 하나와 그 근거 원문 발췌. DB와 분리된 순수 함수라 실행기 · eval · 테스트에서 같은 코드를 쓴다.
// Slack에서 온 원문은 인용 · 본문 · 제목 · 관련자를 하나도 넣지 않는다: 초안은 사용자가 밖으로 보내는 글이 되므로, Slack 글자가 초안을 거쳐
// Slack 밖으로 나가지 않게 한다 (Slack 개발자 정책 docs/go-live/slack-integration.md D3, 계획의 위험 "보낸 메일의 Slack 글자").
// Action의 제목 · 상대 · 기한은 넣는다: Slack 연결을 끊어도 남기는 값이다(purge_slack_sources는 Action을 지우지 않는다, D3).
// 실행 receipt(kind execution, U2 PR7)도 넣지 않는다: 원문이 아니라 앞선 실행의 기록이고, 그 글(초안 제목)은 모델이 쓴 것이다.
// 원문 전체는 보내지 않고 근거 구절 앞뒤만 보낸다 (물어보기 pipeline/ask.ts와 같은 방식).

export type ExecutionAction = {
  title: string;
  status: "open" | "done" | "dropped";
  owner: "me" | "other" | "unknown";
  due_date: string | null;
  counterpart: string | null;
};

export type ExecutionSource = {
  id: string;
  kind: string;
  title: string | null;
  occurredAt: Date | null;
  /** 원문을 가져온 연결의 서비스 (connections.provider). 직접 붙여 넣은 원문은 null */
  provider: string | null;
  /** 글이 지워진 이유 (sources.raw_text_purge_reason). disconnected는 Slack 연결을 끊어 지운 원문이다 */
  purgeReason: "retention" | "disconnected" | null;
  /** 원문 전체. 보관 기간이 지나 지워졌으면 null 또는 빈 글(sources.raw_text는 빈 문자열로 지운다): 저장된 근거 구절만 쓴다 */
  text: string | null;
  participants?: Participants | null;
  /** 원문 링크 (sources.external_url). Slack 메시지 링크면 연결 정보가 없어도 Slack 원문으로 본다 */
  externalUrl?: string | null;
};

/** Action의 근거 구절 (evidence · Claim의 인용) */
export type ExecutionEvidence = { sourceId: string; quote: string };

export type ExecutionContextInput = { action: ExecutionAction; sources: ExecutionSource[]; evidence: ExecutionEvidence[] };

/** 모델에 보내는 자료. 원문은 번호(S1 …)로만 가리키고 내부 id는 넣지 않는다 */
export type ExecutionMaterial = {
  action: { title: string; status: string; owner: string; due: string | null; counterpart: string | null };
  sources: { id: string; kind: string; title: string | null; date: string | null; people: string[]; excerpts: string[] }[];
};

export type ExecutionContext = {
  material: ExecutionMaterial;
  /** 넣지 않은 수: Slack 원문의 근거, 실행 receipt의 근거, 원문을 찾을 수 없는 근거, 원문 수 상한을 넘은 원문. 로그 · eval용 숫자 */
  excluded: { slack: number; receipts: number; missing: number; overSources: number };
};

/** 원문 하나에서 보내는 발췌 길이 상한 (글자) */
const EXCERPT_CHARS = 700;
const SOURCE_CHARS = 2400;
/** 보내는 원문 수 상한 (근거가 많은 Action도 프롬프트가 커지지 않게, 근거 순서대로) */
const MAX_SOURCES = 6;

/**
 * Slack에서 온 원문인가: 연결이 Slack이거나, Slack 연결을 끊어 글을 지운 원문이거나(연결 행이 지워져 provider가 null일 수 있다),
 * 링크가 Slack 메시지다(연결 행이 다른 길로 지워져 provider · 지운 이유가 모두 비어도 막는다).
 */
export function isSlackSource(source: Pick<ExecutionSource, "provider" | "purgeReason" | "externalUrl">): boolean {
  return source.provider === "slack" || source.purgeReason === "disconnected" || isSlackUrl(source.externalUrl);
}

function isSlackUrl(url: string | null | undefined): boolean {
  if (!url) return false;
  try {
    const host = new URL(url).hostname.toLowerCase();
    return host === "slack.com" || host.endsWith(".slack.com");
  } catch {
    return false;
  }
}

function personLabel(person: Person): string | null {
  if (person.name && person.email) return `${person.name} <${person.email}>`;
  return person.name ?? person.email ?? null;
}

function peopleOf(participants: Participants | null | undefined): string[] {
  if (!participants) return [];
  const all = [participants.from, ...(participants.to ?? []), ...(participants.cc ?? []), ...(participants.attendees ?? [])];
  const labels = all.filter((p): p is Person => Boolean(p)).map(personLabel).filter((label): label is string => label !== null);
  return [...new Set(labels)];
}

export function buildExecutionContext(input: ExecutionContextInput): ExecutionContext {
  const sourceById = new Map(input.sources.map((s) => [s.id, s]));
  const quotesBySource = new Map<string, string[]>();
  let slack = 0;
  let receipts = 0;
  let missing = 0;
  for (const e of input.evidence) {
    const source = sourceById.get(e.sourceId);
    if (!source) {
      missing++;
      continue;
    }
    if (isSlackSource(source)) {
      slack++;
      continue;
    }
    if (source.kind === "execution") {
      receipts++;
      continue;
    }
    quotesBySource.set(e.sourceId, [...(quotesBySource.get(e.sourceId) ?? []), e.quote]);
  }

  const sources: ExecutionMaterial["sources"] = [];
  let overSources = 0;
  for (const [sourceId, quotes] of quotesBySource) {
    if (sources.length >= MAX_SOURCES) {
      overSources++;
      continue;
    }
    const source = sourceById.get(sourceId)!;
    const text = source.text || null;
    const excerpts: string[] = [];
    let length = 0;
    for (const quote of quotes) {
      // 원문이 지워졌으면 저장된 근거 구절 자체가 발췌다.
      const excerpt = text === null ? quote : (quoteContext(text, quote, 2, EXCERPT_CHARS) ?? findQuoteSpan(text, quote)?.quote ?? null);
      if (!excerpt || excerpts.some((x) => x.includes(excerpt) || excerpt.includes(x))) continue;
      if (length + excerpt.length > SOURCE_CHARS) break;
      excerpts.push(excerpt);
      length += excerpt.length;
    }
    if (excerpts.length === 0) {
      missing += quotes.length;
      continue;
    }
    sources.push({
      id: `S${sources.length + 1}`,
      kind: source.kind,
      title: source.title,
      date: source.occurredAt ? kstDate(source.occurredAt).iso : null,
      people: peopleOf(source.participants),
      excerpts,
    });
  }

  const a = input.action;
  return {
    material: {
      action: { title: a.title, status: a.status, owner: a.owner, due: a.due_date, counterpart: a.counterpart },
      sources,
    },
    excluded: { slack, receipts, missing, overSources },
  };
}
