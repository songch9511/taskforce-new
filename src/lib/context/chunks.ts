import { EMBEDDING_DIMENSIONS } from "@/lib/ai/embed";
import { ConsentRequiredError } from "@/lib/consent/gate";
import { flagEnabled } from "@/lib/flags";

import { isSlackDerived } from "./retrieve";

// 원문 조각 (source_chunks, 아키텍처 6.2): 원문을 1–2k자 조각으로 나눠 임베딩한다. 나누기는 순수 함수, 임베딩 · 저장은 주입한 deps로.
// - SOURCE_CHUNKS_ENABLED가 꺼져 있으면 아무것도 부르지 않는다 (임베딩 0 · 쓰기 0).
// - 임베딩은 외부 AI 처리 동의가 있을 때만: deps.embed는 withConsentGate로 감싼 함수를 넘긴다 (store.ts). 동의가 없으면 쓰지 않고 no_consent.
// - Slack 원문은 조각으로 만들지 않는다: Slack 글자를 묶음 · 검색으로 밖에 내보내지 않는 규칙(Slack D3, 실행 자료와 같은 기준)을 조각에서도 지키고,
//   지울 사본을 늘리지 않는다.
// - 저장은 replace_source_chunks 한 번 (같은 문서의 옛 revision 조각까지 한 트랜잭션에서 바꾼다. 지운 원문이면 purged, 더 새 revision이 있으면 stale).

export const CHUNK_MIN_CHARS = 1000;
export const CHUNK_MAX_CHARS = 2000;
/** 원문 하나의 조각 상한 (약 40만 자). 넘는 뒷부분은 조각으로 만들지 않는다: 임베딩 요청 · RPC 크기를 묶어 두려고 */
export const MAX_CHUNKS_PER_SOURCE = 200;
/** 임베딩 요청 한 번에 보내는 조각 수 */
export const EMBED_BATCH = 64;

const BREAKS: RegExp[] = [/\n\s*\n/g, /\n/g, /[.!?。！？](?=\s)/g, /\s/g];

/** text[lo, hi] 안에서 가장 뒤의 자연스러운 끊는 자리 (문단 → 줄 → 문장 → 공백 순). 없으면 hi */
function cutWithin(text: string, lo: number, hi: number): number {
  for (const pattern of BREAKS) {
    let best = -1;
    for (const match of text.slice(0, hi).matchAll(pattern)) {
      const end = match.index + match[0].length;
      if (end >= lo && end <= hi) best = end;
    }
    if (best > 0) return best;
  }
  // 대리 쌍(이모지 등) 가운데를 자르지 않는다 (앞으로 당길 수 없으면 쌍 뒤에서)
  const code = text.charCodeAt(hi - 1);
  if (code < 0xd800 || code > 0xdbff) return hi;
  return hi - 1 > 0 ? hi - 1 : hi + 1;
}

/**
 * 원문을 조각으로 나눈다. 마지막 두 조각을 빼면 모두 min–max자 (문단 · 줄 · 문장 · 공백 경계에서). 끝에 짧은 조각만 남지 않도록
 * 남은 길이가 max + min보다 짧으면 둘로 고르게 나눈다. 전체가 max 이하면 한 조각. 빈 글은 조각 없음.
 */
export function chunkText(text: string, options: { min?: number; max?: number } = {}): string[] {
  const min = options.min ?? CHUNK_MIN_CHARS;
  const max = options.max ?? CHUNK_MAX_CHARS;
  let rest = text.replace(/\r\n?/g, "\n").trim();
  const chunks: string[] = [];
  while (rest.length > max) {
    // 끝에 짧은 조각만 남지 않게: 남은 길이가 max + min보다 짧으면 가운데 근처(± min/4)에서 나눈다
    const balanced = rest.length < max + min;
    const half = Math.ceil(rest.length / 2);
    const lo = balanced ? Math.max(1, rest.length - max, half - Math.floor(min / 4)) : min;
    const hi = balanced ? Math.max(lo, Math.min(max, half + Math.floor(min / 4))) : max;
    const cut = cutWithin(rest, lo, hi);
    const chunk = rest.slice(0, cut).trim();
    if (chunk) chunks.push(chunk);
    rest = rest.slice(cut).trim();
  }
  if (rest) chunks.push(rest);
  return chunks;
}

export type ChunkSource = {
  userId: string;
  sourceId: string;
  text: string;
  /** 연결의 서비스 (connections.provider). 직접 붙여 넣은 원문은 null */
  provider: string | null;
  externalUrl: string | null;
};

export type ChunkIndexDeps = {
  /** 동의 확인을 거친 임베딩 (withConsentGate). 동의가 없으면 ConsentRequiredError */
  embed: (texts: string[]) => Promise<number[][]>;
  /** replace_source_chunks */
  replace: (userId: string, sourceId: string, chunks: { text: string; embedding: number[] }[]) => Promise<{ status: string; chunks: number }>;
};

export type ChunkIndexResult = {
  /** failed: 임베딩 · 저장이 실패했다 (수집 경로는 던지지 않고 이것으로 남긴다, store.ts indexSourceAfterIngest) */
  status: "gate_off" | "slack" | "empty" | "no_consent" | "replaced" | "unchanged" | "purged" | "stale" | "failed";
  chunks: number;
};

/** 원문 하나의 조각을 만들어 저장한다. gate · Slack · 빈 글 · 동의를 먼저 보고, 하나라도 걸리면 임베딩도 저장도 하지 않는다 */
export async function indexSourceChunks(
  deps: ChunkIndexDeps,
  source: ChunkSource,
  env: Record<string, string | undefined> = process.env,
): Promise<ChunkIndexResult> {
  if (!flagEnabled("SOURCE_CHUNKS_ENABLED", env)) return { status: "gate_off", chunks: 0 };
  if (isSlackDerived({ provider: source.provider, purgeReason: null, externalUrl: source.externalUrl })) return { status: "slack", chunks: 0 };
  const texts = chunkText(source.text).slice(0, MAX_CHUNKS_PER_SOURCE);
  if (texts.length === 0) return { status: "empty", chunks: 0 };
  const vectors: number[][] = [];
  try {
    for (let i = 0; i < texts.length; i += EMBED_BATCH) vectors.push(...(await deps.embed(texts.slice(i, i + EMBED_BATCH))));
  } catch (error) {
    if (error instanceof ConsentRequiredError) return { status: "no_consent", chunks: 0 };
    throw error;
  }
  if (vectors.length !== texts.length || vectors.some((v) => v.length !== EMBEDDING_DIMENSIONS)) {
    throw new Error(`조각 임베딩 개수나 차원이 다릅니다 (기대 ${EMBEDDING_DIMENSIONS}차원)`);
  }
  const result = await deps.replace(
    source.userId,
    source.sourceId,
    texts.map((text, i) => ({ text, embedding: vectors[i] })),
  );
  return { status: result.status as ChunkIndexResult["status"], chunks: result.chunks };
}
