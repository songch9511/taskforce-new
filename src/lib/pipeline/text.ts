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
 * "..."로 이은 인용의 조각 중 하나라도 텍스트에 있는가. quoteInText는 조각이 모두 순서대로 있어야 하지만, 이쪽은 하나면 된다.
 * 조각이 여러 곳(새 글 · 인용된 옛 메일)에 걸친 인용을 옛 메일에만 있는 것으로 잘못 버리지 않으려고 쓴다 (verify.ts).
 */
export function anyQuoteFragmentInText(quote: string, text: string): boolean {
  const haystack = normalizeForMatch(text);
  return quoteFragments(quote).some((fragment) => haystack.includes(fragment));
}

/**
 * 인용이 들어 있는 줄 번호들 (오름차순). "..."로 이은 인용은 조각마다 본다.
 * 조각이 한 줄 안에 있으면 그 조각이 나오는 줄을 모두(같은 구절이 여러 줄에 있으면 여러 개), 여러 줄에 걸치면 걸친 줄 모두.
 * 화자를 읽을 때 쓴다: 줄이 여럿이고 화자가 다르면 누가 말했는지 모른다.
 */
export function quoteLineIndexes(text: string, quote: string): number[] {
  const lines = text.split("\n");
  const normalized = lines.map(normalizeForMatch);
  const found = new Set<number>();
  for (const fragment of quoteFragments(quote)) {
    const within = normalized.flatMap((line, i) => (line.includes(fragment) ? [i] : []));
    if (within.length > 0) {
      within.forEach((i) => found.add(i));
      continue;
    }
    // 여러 줄에 걸친 조각: 정규화한 줄들을 이어 붙인 문자열에서 조각이 덮는 줄 모두 (화자가 다른 줄에 걸치면 알아야 한다)
    const at = normalized.join("").indexOf(fragment);
    if (at < 0) continue;
    const end = at + fragment.length;
    let offset = 0;
    for (let i = 0; i < lines.length; i++) {
      const next = offset + normalized[i].length;
      if (normalized[i].length > 0 && at < next && end > offset) found.add(i);
      offset = next;
    }
  }
  return [...found].sort((a, b) => a - b);
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

// ── 메일에 인용된 옛 메일 ──

// 메일 앱이 인용 앞에 붙이는 머리줄: "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <j@x.com> wrote:" (두 줄로 꺾인 것도), 한국어 Gmail "…님이 작성:".
// 글 속 문장("On Tuesday at 3pm the client wrote:")과 가르려고 날짜(숫자)와 메일 주소(@)가 모두 있는 줄만 받는다.
const ATTRIBUTION = /^(?:On\b.*\bwrote:|.*님이 작성:)$/i;
const isAttribution = (line: string) => line.length <= 300 && line.includes("@") && /\d/.test(line) && ATTRIBUTION.test(line);
// 주소가 다음 줄로 꺾인 머리줄의 첫 줄 ("On … Morgan Tate" + "<m@x.com> wrote:" · "wrote:"): 문장으로 끝나지 않고, 다음 줄이 짧은 꼬리일 때만 이어 본다
const isWrappedAttribution = (line: string, next: string) =>
  /^On\b/i.test(line) && !/[.!?]$/.test(line) && next.length <= 100 && !isAttribution(next) && isAttribution(`${line} ${next}`);
// Outlook 계열: "-----Original Message-----" · "-----원본 메시지-----"
const ORIGINAL_MESSAGE = /^\s*-{2,}\s*(?:Original Message|원본\s*메시지)\s*-{2,}\s*$/i;
// Outlook 계열의 머리 묶음: 빈 줄(또는 밑줄 구분선) 뒤에 보낸 사람 줄, 바로 이어서 다른 머리 줄 둘 이상 ("From: 10:00" + "To: 11:00" 같은 글과 가른다)
const FROM_HEADER = /^\s*(?:From|보낸\s*사람)\s*:/i;
const NEXT_HEADER = /^\s*(?:Sent|Date|To|Cc|Subject|보낸\s*(?:날짜|시간)|날짜|받는\s*사람|참조|제목)\s*:/i;
const SEPARATOR = /^\s*[_-]{5,}\s*$/;
// 전달한 메일("제목: Fwd: …" · "전달: …", 앞에 Re:가 붙어도): 전달된 내용은 이미 들어온 옛 메일이 아니라 새로 받은 글이다
const FORWARD_SUBJECT = /^제목:\s*(?:(?:re|답장|회신)\s*:\s*)*(?:fwd?|전달|전송)\s*:/i;

type LineKind = "blank" | "quoted" | "attribution" | "other";

/**
 * 메일 본문에서 이전 메일을 인용한 부분(옛 메일 이력)이 시작하는 위치 (글자 순서). 인용이 없으면 null.
 * 이 위치 뒤에만 있는 구절은 새 메일의 말이 아니라 옛 메일의 말이다: 옛 메일의 말은 그 메일이 들어올 때 이미 Claim이 됐고,
 * 새 메일의 시각으로 다시 뽑으면 이미 끝난 일이 새 할 일이 되고 늦춘 기한이 되돌아간다 (verify.ts, google-integration.md 2-6).
 * 찾는 모양 (가장 앞선 것):
 * - 끝까지 `>`로 시작하는 줄 · 위의 머리줄("On … wrote:" · "…님이 작성:") · 빈 줄뿐인 꼬리: 답장 아래에 옛 메일이 통째로 붙은 모양.
 * - 머리줄 바로 뒤에 `>` 없이 옛 메일이 이어지는 모양.
 * - `-----Original Message-----` · `-----원본 메시지-----`.
 * - 빈 줄 뒤에 `From:`/`보낸 사람:` 줄과 바로 이어지는 다른 머리 줄 둘 이상(`Sent:` · `To:` · `Subject:` …).
 * 머리줄은 날짜와 메일 주소가 있는 줄만 받는다. 전달한 메일("Fwd:" · "전달:" 제목)은 인용이 없는 것으로 본다.
 * 답장 위쪽의 새 글은 포함하지 않는다: "Sure, I'll send it by Monday."처럼 짧아도 인용 위에 있으면 그대로 남는다.
 * 인용 사이사이에 답을 적은 메일(인용 뒤에 새 글이 이어짐)은 끝에 인용 묶음이 따로 있을 때만 그 묶음부터, 없으면 null이다:
 * 애매하면 새 글로 본다 (인용으로 잘못 보면 진짜 약속을 조용히 버린다).
 */
export function quotedHistoryStart(text: string): number | null {
  const lines = text.split("\n");
  // 전달한 메일은 붙은 내용이 옛 메일 이력이 아니라 전달받은 글이다: 아무것도 인용으로 보지 않는다
  if (FORWARD_SUBJECT.test(lines[0].trim())) return null;
  const offsets: number[] = [];
  let offset = 0;
  for (const line of lines) {
    offsets.push(offset);
    offset += line.length + 1;
  }

  // 줄마다 종류. 두 줄로 꺾인 머리줄은 두 줄 모두 attribution
  const kinds: LineKind[] = lines.map((line) => (line.trim() === "" ? "blank" : /^\s*>/.test(line) ? "quoted" : "other"));
  const attributionStarts = new Set<number>();
  for (let i = 0; i < lines.length; i++) {
    if (kinds[i] !== "other") continue;
    const line = lines[i].trim();
    const span = isAttribution(line) ? 1 : i + 1 < lines.length && isWrappedAttribution(line, lines[i + 1].trim()) ? 2 : 0;
    if (span === 0) continue;
    attributionStarts.add(i);
    for (let k = i; k < i + span; k++) kinds[k] = "attribution";
    i += span - 1;
  }

  let start = Infinity;
  const consider = (index: number) => {
    start = Math.min(start, index);
  };

  // 끝까지 인용 · 머리줄 · 빈 줄뿐인 꼬리의 첫 줄
  for (let i = lines.length - 1; i >= 0 && kinds[i] !== "other"; i--) {
    if (kinds[i] !== "blank") consider(i);
  }

  for (let i = 0; i < lines.length; i++) {
    if (attributionStarts.has(i)) {
      // 머리줄 뒤에 인용 표시(>) 없이 글이 이어지면 옛 메일 본문이다
      let next = i + 1;
      while (next < lines.length && (kinds[next] === "attribution" || kinds[next] === "blank")) next++;
      if (next < lines.length && kinds[next] === "other") consider(i);
    }
    if (ORIGINAL_MESSAGE.test(lines[i])) consider(i);
    if (i > 0 && FROM_HEADER.test(lines[i]) && i + 2 < lines.length && NEXT_HEADER.test(lines[i + 1]) && NEXT_HEADER.test(lines[i + 2])) {
      if (lines[i - 1].trim() === "") consider(i);
      else if (SEPARATOR.test(lines[i - 1])) consider(i - 1);
    }
  }

  return Number.isFinite(start) ? offsets[start] : null;
}
