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

/**
 * 인용이 들어 있는 줄 앞뒤로 `radius`줄을 잘라 돌려준다. Judge에는 원문 전체가 아니라 이 구간만 보낸다.
 * 인용을 못 찾으면 null.
 */
export function quoteContext(text: string, quote: string, radius = 4, maxChars = 1500): string | null {
  // 조각으로 나뉜 인용은 첫 조각 주변을 보여준다.
  const q = quoteFragments(quote)[0];
  if (!q) return null;
  const lines = text.split("\n");
  const normalized = lines.map(normalizeForMatch);

  // 인용이 여러 줄에 걸칠 수 있다. 인용이 끝나는 줄을 먼저 찾고, 그 줄에서 거꾸로 가장 가까운 시작 줄을 찾는다.
  for (let end = 0; end < lines.length; end++) {
    for (let start = end; start >= Math.max(0, end - 10); start--) {
      if (normalized.slice(start, end + 1).join("").includes(q)) {
        const context = lines.slice(Math.max(0, start - radius), Math.min(lines.length, end + radius + 1)).join("\n");
        return context.length > maxChars ? context.slice(0, maxChars) : context;
      }
    }
  }
  return null;
}
