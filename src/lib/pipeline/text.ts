// 원문 대조용 문자열 도구. 공백 · 문장부호 · 기호 차이는 무시한다.

export function normalizeForMatch(text: string): string {
  return text.toLowerCase().replace(/[\s\p{P}\p{S}]/gu, "");
}

// 모델이 떨어진 두 구절을 "..."로 이어 인용하기도 한다. 조각마다 원문에 순서대로 있으면 실재하는 인용으로 본다.
function quoteFragments(quote: string): string[] {
  return quote
    .split(/\.{2,}|…/)
    .map(normalizeForMatch)
    .filter((fragment) => fragment.length > 0);
}

export function quoteInText(quote: string, text: string): boolean {
  const fragments = quoteFragments(quote);
  if (fragments.length === 0) return false;
  const haystack = normalizeForMatch(text);
  let from = 0;
  for (const fragment of fragments) {
    const at = haystack.indexOf(fragment, from);
    if (at < 0) return false;
    from = at + fragment.length;
  }
  return true;
}

/** 기본으로 인용 하나가 걸칠 수 있다고 보는 줄 수 (시작 줄에서 끝 줄까지의 거리) */
const QUOTE_SPAN_LINES = 10;

/**
 * 인용이 들어 있는 줄 앞뒤로 `radius`줄을 잘라 돌려준다. Judge에는 원문 전체가 아니라 이 구간만 보낸다.
 * 인용을 못 찾으면 null.
 * @param maxSpan 인용이 걸칠 수 있는 줄 수 (기본 10). 누락 신고처럼 사용자가 긴 범위를 고를 수 있으면 늘린다.
 */
export function quoteContext(text: string, quote: string, radius = 4, maxChars = 1500, maxSpan = QUOTE_SPAN_LINES): string | null {
  // 조각으로 나뉜 인용은 첫 조각 주변을 보여준다.
  const q = quoteFragments(quote)[0];
  if (!q) return null;
  const lines = text.split("\n");
  const normalized = lines.map(normalizeForMatch);
  const around = (start: number, end: number) => {
    const context = lines.slice(Math.max(0, start - radius), Math.min(lines.length, end + radius + 1)).join("\n");
    return context.length > maxChars ? aroundQuote(context, q, maxChars) : context;
  };

  // 인용이 여러 줄에 걸칠 수 있다. 인용이 끝나는 줄을 먼저 찾고, 그 줄에서 거꾸로 가장 가까운 시작 줄을 찾는다.
  const span = Math.min(maxSpan, QUOTE_SPAN_LINES);
  for (let end = 0; end < lines.length; end++) {
    for (let start = end; start >= Math.max(0, end - span); start--) {
      if (normalized.slice(start, end + 1).join("").includes(q)) return around(start, end);
    }
  }
  if (maxSpan <= QUOTE_SPAN_LINES) return null;

  // 더 긴 인용: 줄을 이어 붙인 문자열에서 첫 위치를 찾아, 그 첫 글자와 끝 글자가 들어 있는 줄로 되돌린다.
  // (위의 줄 단위 탐색을 긴 범위로 돌리면 원문 길이의 제곱보다 느려진다)
  const offsets: number[] = [];
  let offset = 0;
  for (const line of normalized) {
    offsets.push(offset);
    offset += line.length;
  }
  const at = normalized.join("").indexOf(q);
  if (at < 0) return null;
  const lineOf = (pos: number) => normalized.findIndex((line, i) => offsets[i] <= pos && pos < offsets[i] + line.length);
  const start = lineOf(at);
  const end = lineOf(at + q.length - 1);
  return end - start <= maxSpan ? around(start, end) : null;
}

/** 정규화한 문자열과, 그 글자마다 원래 문자열에서의 시작 · 끝 위치 (글자 하나가 정규화로 여러 글자가 될 수 있다) */
function normalizedWithOffsets(text: string): { normalized: string; start: number[]; end: number[] } {
  const start: number[] = [];
  const end: number[] = [];
  let normalized = "";
  for (let i = 0; i < text.length; ) {
    const ch = String.fromCodePoint(text.codePointAt(i)!);
    const n = normalizeForMatch(ch);
    for (let k = 0; k < n.length; k++) {
      start.push(i);
      end.push(i + ch.length);
    }
    normalized += n;
    i += ch.length;
  }
  return { normalized, start, end };
}

/**
 * 인용이 원문에 이어진 한 덩어리로 있으면 그 원문 구간(첫 글자 ~ 마지막 글자, 원문 그대로)을 돌려준다. 없으면 null.
 * 공백 · 문장부호 · 기호 · 대소문자 차이는 무시하지만, 떨어진 구절을 "..."로 이어 붙인 인용은 받지 않는다 (quoteInText와 다른 점).
 * 돌려주는 quote는 모델이 쓴 문자열이 아니라 원문에서 잘라 낸 것이라, 화면에 그대로 보여도 원문과 한 글자도 다르지 않다.
 * 같은 구절이 여러 번 나오면 첫 번째.
 */
export function findQuoteSpan(text: string, quote: string): { start: number; end: number; quote: string } | null {
  const needle = normalizeForMatch(quote);
  if (needle.length === 0 || !normalizeForMatch(text).includes(needle)) return null;
  const { normalized, start, end } = normalizedWithOffsets(text);
  const at = normalized.indexOf(needle);
  if (at < 0) return null;
  const from = start[at];
  const to = end[at + needle.length - 1];
  return { start: from, end: to, quote: text.slice(from, to) };
}

/**
 * 긴 대목(예: 줄바꿈 없는 긴 문단)을 자를 때 인용이 잘려 나가지 않게 인용 위치를 기준으로 자른다.
 * 앞쪽(누가 무엇을 요청했는지)을 조금 더 남긴다: 인용이 앞에서 1/3 지점에 오게.
 */
function aroundQuote(context: string, normalizedQuote: string, maxChars: number): string {
  // 정규화한 문자열의 위치 → 원래 문자열의 위치
  const { normalized, start: original } = normalizedWithOffsets(context);
  const at = normalized.indexOf(normalizedQuote);
  const quoteStart = at < 0 ? 0 : original[at];
  const start = Math.max(0, Math.min(quoteStart - Math.floor(maxChars / 3), context.length - maxChars));
  const end = Math.min(context.length, start + maxChars);
  return `${start > 0 ? "…" : ""}${context.slice(start, end)}${end < context.length ? "…" : ""}`;
}
