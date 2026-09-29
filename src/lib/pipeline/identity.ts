// 원문 속에서 "누가 사용자인가"를 알아보는 데 쓰는 정보와 규칙.
// 메일 · 캘린더는 주소로 사용자를 확실히 찾을 수 있고, 받아쓰기 회의록은 이름 문자열뿐이라 별칭과 오타 후보가 필요하다.

import { quoteLineIndexes } from "./text";

export type Person = { name?: string; email?: string };

export type Participants = {
  from?: Person;
  to?: Person[];
  cc?: Person[];
  attendees?: Person[];
};

export type UserIdentity = {
  /** 원문에서 사용자를 부르는 기본 이름 */
  name: string;
  /** 다른 호칭 · 영문 이름 · 받아쓰기가 자주 틀리는 이름 */
  aliases: string[];
  emails: string[];
};

export type UserPosition = "sender" | "sole_recipient" | "recipient" | "cc_only" | "attendee" | "unknown";

const normalizeEmail = (email: string) => email.trim().toLowerCase();
const normalizeName = (name: string) => name.replace(/\s+/g, "").toLowerCase();

/** 원문의 관련자 모두: 보낸 사람 · 받는 사람 · 참조 · 참석자 (빈 칸은 undefined) */
const everyone = (participants: Participants | undefined): (Person | undefined)[] => [
  participants?.from,
  ...(participants?.to ?? []),
  ...(participants?.cc ?? []),
  ...(participants?.attendees ?? []),
];

/** 사용자를 가리키는 이름 형태: 이름, 별칭, 세 글자 한글 이름의 성을 뺀 부분 */
export function userNameForms(identity: UserIdentity): string[] {
  const forms = new Set<string>();
  for (const raw of [identity.name, ...identity.aliases]) {
    const name = normalizeName(raw);
    if (!name) continue;
    forms.add(name);
    if (/^[가-힣]{3}$/.test(name)) forms.add(name.slice(1));
  }
  return [...forms];
}

export function isUser(person: Person | undefined, identity: UserIdentity): boolean {
  if (!person) return false;
  const emails = identity.emails.map(normalizeEmail);
  if (person.email && emails.includes(normalizeEmail(person.email))) return true;
  return person.name ? userNameForms(identity).includes(normalizeName(person.name)) : false;
}

/** 메일이면 보낸 사람 / 받는 사람 / 참조 중 어디에 있는지, 회의면 참석자인지 */
export function userPosition(identity: UserIdentity, participants: Participants | undefined): UserPosition {
  if (!participants) return "unknown";
  if (isUser(participants.from, identity)) return "sender";
  const to = participants.to ?? [];
  if (to.some((p) => isUser(p, identity))) return to.length === 1 ? "sole_recipient" : "recipient";
  if ((participants.cc ?? []).some((p) => isUser(p, identity))) return "cc_only";
  if ((participants.attendees ?? []).some((p) => isUser(p, identity))) return "attendee";
  return "unknown";
}

// "도연님", "태오:", "준서 -" 처럼 사람 이름으로 쓰인 한글 2~4자
const NAME_LIKE = /(?<![가-힣])([가-힣]{2,4}?)(?=\s*(?:님|씨|:|\s[-–]\s))/g;

/**
 * 사용자 이름과 한 글자만 다른 이름을 찾는다 (받아쓰기 오류 후보. 예: 도윤 → 도연).
 * 관련자 목록에 있는 다른 사람의 이름은 제외한다. 확정이 아니라 "확인이 필요한 이름"이다.
 */
export function findNameVariants(text: string, identity: UserIdentity, participants?: Participants): string[] {
  const forms = userNameForms(identity);
  const others = new Set(
    everyone(participants)
      .filter((p): p is Person => Boolean(p?.name) && !isUser(p, identity))
      .flatMap((p) => {
        const name = normalizeName(p.name!);
        return /^[가-힣]{3}$/.test(name) ? [name, name.slice(1)] : [name];
      }),
  );

  const variants = new Set<string>();
  for (const match of text.matchAll(NAME_LIKE)) {
    const token = normalizeName(match[1]);
    if (forms.includes(token) || others.has(token)) continue;
    if (forms.some((form) => oneSyllableApart(form, token))) variants.add(match[1]);
  }
  return [...variants];
}

// 대화 원문의 화자 표: "이름: 말" 또는 "[이름] 말"
const SPEAKER_LABEL = /^\s*(?:\[([^\]\n]{1,30})\]|([^:\n[\]]{1,30}?)\s*:)\s*\S/;
// 대괄호만 있는 머리줄 ("[DM · 김대표]", "[#launch]")
const HEADER_LINE = /^\s*\[[^\]\n]*\]\s*$/;
// 이름표 자리에 오지만 사람이 아닌 머리글 (공백 없이 소문자로 비교)
const NOT_SPEAKERS = new Set(["참고", "제목", "보낸사람", "받는사람", "날짜", "일시", "장소", "링크", "메모", "비고", "요약", "결론", "안건", "참석", "참석자", "담당", "일정", "시간", "목적", "배경", "액션", "할일", "q", "a", "re", "fw", "fwd", "to", "from", "cc", "subject", "date", "note", "todo", "action"]);

function speakerLabel(line: string): string | null {
  const match = line.match(SPEAKER_LABEL);
  const label = (match?.[1] ?? match?.[2])?.trim();
  // "10:30 …", "https://…"는 이름표가 아니다
  if (!label || !/\p{L}/u.test(label) || /^https?$/i.test(label)) return null;
  return label;
}

/** 관련자 목록에 없는 이름표를 화자로 믿을 때의 모양: 숫자 · @ · 글머리 없이 두 단어 이하, 머리글 단어가 아님 */
function nameLike(label: string): boolean {
  return !/[\d@]/.test(label) && !/^[-*•·]/.test(label) && label.split(/\s+/).length <= 2 && !NOT_SPEAKERS.has(normalizeName(label));
}

/** 그 줄이 속한 메시지의 첫 줄(화자 표가 있는 줄). 이름표 없이 이어지는 줄이면 위로 올라가고, 빈 줄 · 머리줄에서 멈춘다. */
function messageStart(lines: string[], index: number): number | null {
  for (let i = index; i >= 0; i--) {
    if (speakerLabel(lines[i])) return i;
    if (i < index && (lines[i].trim() === "" || HEADER_LINE.test(lines[i]))) return null;
  }
  return null;
}

/**
 * 인용을 말한 사람의 이름 (원문의 이름표 그대로). 모르면 null.
 * 인용이 걸친 줄(같은 구절이 여러 줄에 있으면 그 줄 모두)의 화자가 하나로 정해질 때만 돌려준다. 화자를 잘못 알려 주면
 * 진실 판정이 요청한 쪽의 말로 보고 확인 없이 반영할 수 있어서(규칙 0), 애매하면 모른다고 한다.
 * "제목: …" 같은 머리글을 화자로 읽지 않게, 사용자 · 관련자의 이름이거나 원문에서 두 번 이상 화자 표로 쓰인 사람 이름 모양만 받는다.
 */
export function quoteSpeaker(text: string, quote: string, identity: UserIdentity, participants?: Participants): string | null {
  const lines = text.split("\n");
  const indexes = quoteLineIndexes(text, quote);
  if (indexes.length === 0) return null;
  const labels = new Set<string>();
  for (const index of indexes) {
    const start = messageStart(lines, index);
    const label = start === null ? null : speakerLabel(lines[start]);
    if (!label) return null;
    labels.add(label);
  }
  if (labels.size !== 1) return null;
  const [label] = labels;
  if (isUser({ name: label }, identity)) return label;
  const known = everyone(participants);
  if (known.some((p) => p?.name && normalizeName(p.name) === normalizeName(label))) return label;
  const uses = lines.filter((line) => speakerLabel(line) === label).length;
  return uses >= 2 && nameLike(label) ? label : null;
}

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// 영문 이름만 적은 별칭("Daniel") 뒤에 와도 성이 아닌 단어. 이 밖의 영문 단어가 이어지면 다른 사람의 성으로 본다 ("@Daniel Kim")
const NOT_SURNAMES = new Set(["can", "could", "would", "will", "please", "pls", "are", "is", "do", "does", "did", "thanks", "thank", "hi", "hey", "i", "we", "you", "the", "this", "that", "just", "fyi", "quick", "any", "when", "what", "how", "where", "why", "let", "lets", "sorry", "also", "and", "or", "re"]);

/** `after`가 `name`으로 시작하면 그 길이 (대소문자 · 단어 사이 공백 무시, 뒤에 님 · 씨는 붙어도 된다). 다른 글자로 이어지면("@지호연", "@daniel.kim") null */
function nameAt(after: string, name: string): number | null {
  const words = name.trim().split(/\s+/).map(escapeRegExp).join("\\s+");
  const match = after.match(new RegExp(`^(?:${words})(?:님|씨)?(?![\\p{L}\\p{N}])(?![._-][\\p{L}\\p{N}])`, "iu"));
  return match ? match[0].length : null;
}

/**
 * 한 줄이 사용자를 @이름으로 부르는가. "@" 뒤를 사용자 이름 · 별칭 · 성을 뺀 이름과 관련자 이름 중 **가장 긴 이름**으로 읽는다:
 * 관련자에 "Daniel Kim"이 있으면 "@Daniel Kim"은 별칭이 "Daniel"인 사용자가 아니다. 관련자 목록이 없어도,
 * 이름만 적은 영문 별칭 뒤에 다른 영문 단어가 이어지면 다른 사람의 성으로 보고 사용자로 읽지 않는다.
 * 메일 주소("a@daniel.kr")는 언급이 아니다. 애매하면 사용자가 아니라고 본다 (틀리면 남의 요청이 내 확인 요청으로 뜬다).
 */
function mentionsUser(line: string, identity: UserIdentity, participants?: Participants): boolean {
  // userNameForms와 달리 원래 글자(공백 · 대소문자 그대로)를 쓴다: nameAt이 원문과 맞춰 보며 둘을 직접 무시한다.
  // 그래서 "김 도윤"처럼 띄어 쓴 이름은 성을 뺀 형태를 만들지 않는다 (userNameForms는 공백을 지운 뒤 만든다).
  const userForms = [identity.name, ...identity.aliases].flatMap((raw) => {
    const name = raw.trim();
    if (!name) return [];
    return /^[가-힣]{3}$/.test(name) ? [name, name.slice(1)] : [name];
  });
  if (userForms.length === 0) return false;
  const others = everyone(participants)
    .filter((p): p is Person => Boolean(p?.name?.trim()) && !isUser(p!, identity))
    .map((p) => p.name!.trim());
  const names = [...userForms.map((name) => ({ name, me: true })), ...others.map((name) => ({ name, me: false }))].sort(
    (a, b) => normalizeName(b.name).length - normalizeName(a.name).length,
  );

  for (const at of line.matchAll(/(?<![\p{L}\p{N}._%+-])@\s?/gu)) {
    const after = line.slice(at.index! + at[0].length);
    const hit = names.map((n) => ({ ...n, length: nameAt(after, n.name) })).find((n) => n.length !== null);
    if (!hit?.me) continue;
    if (/^[a-z]+$/i.test(hit.name)) {
      const next = after.slice(hit.length!).match(/^\s+([a-z]+)\b/i);
      if (next && !NOT_SURNAMES.has(next[1].toLowerCase())) continue;
    }
    return true;
  }
  return false;
}

/**
 * 인용 줄의 이름표(quoteSpeaker)와 그 일을 요청한 사람을 비교해 화자 역할을 정한다. 확실하지 않으면 null (Jev 답을 쓴다).
 * - 이름표가 사용자(이름 · 별칭 · 성을 뺀 이름)면 me. 단 요청자와 같은 이름이면 모른다.
 * - 요청한 사람과 같은 사람이면 counterpart ("김민수" = "김민수 대표" = "김민수님").
 * - 둘 다 전체 이름이고 분명히 다르면 third_party: 대화 상대라도 요청자가 아니면 남의 허락을 전하는 사람이라,
 *   요청자의 말로 보면 규칙 0 · 3을 건너뛴다. "김대표" · "민수" · 영문 이름처럼 비교할 수 없는 모양이면 null.
 * 누가 말했는지는 원문의 이름표가 정하는 사실이라(원칙 5) Jev의 추측보다 앞선다.
 */
export function speakerRole(speaker: string, requester: string | null | undefined, identity: UserIdentity): "me" | "counterpart" | "third_party" | null {
  const hasRequester = Boolean(requester?.trim());
  if (isUser({ name: speaker }, identity)) return hasRequester && samePerson(requester!, speaker) ? null : "me";
  if (!hasRequester) return null;
  if (samePerson(requester!, speaker)) return "counterpart";
  return fullName(speaker) && fullName(requester!) && script(speaker) === script(requester!) ? "third_party" : null;
}

const TITLE = /(대표|팀장|실장|이사|부장|과장|차장|매니저|님|씨)+$/;
const bareName = (name: string) => normalizeName(name).replace(/(님|씨)$/, "");
const script = (name: string) => (/[가-힣]/.test(name) ? "hangul" : "latin");

/** 사람을 가려낼 수 있는 이름: 한글 3~4자(직함으로 끝나지 않음) 또는 두 단어 이상의 영문 이름 */
function fullName(name: string): boolean {
  const bare = bareName(name);
  if (/(대표|팀장|실장|이사|부장|과장|차장|매니저)$/.test(bare)) return false;
  return /^[가-힣]{3,4}$/.test(bare) || /^[a-z]+(\s+[a-z]+)+$/i.test(name.trim());
}

/** 같은 사람: 호칭(님 · 씨)을 뗀 이름이 같거나, 전체 이름 뒤에 직함만 붙은 것 ("김민수 대표") */
function samePerson(a: string, b: string): boolean {
  const [x, y] = [bareName(a), bareName(b)];
  if (x === y) return true;
  const [shorter, longer] = x.length <= y.length ? [x, y] : [y, x];
  const rest = longer.slice(shorter.length);
  return fullName(shorter) && longer.startsWith(shorter) && rest.length > 0 && rest.replace(TITLE, "") === "";
}

/** 인용이 속한 메시지가 사용자를 @이름으로 직접 부르는가 (Slack 언급 · "@지호 이거 될까요?"). 여러 줄 메시지면 첫 줄부터 본다 */
export function addressedToUser(text: string, quote: string, identity: UserIdentity, participants?: Participants): boolean {
  const lines = text.split("\n");
  const checked = new Set<number>();
  for (const index of quoteLineIndexes(text, quote)) {
    const start = messageStart(lines, index) ?? index;
    for (let i = start; i <= index; i++) checked.add(i);
  }
  return [...checked].some((i) => mentionsUser(lines[i], identity, participants));
}

function oneSyllableApart(a: string, b: string): boolean {
  if (a.length !== b.length || a.length < 2 || !/^[가-힣]+$/.test(a) || !/^[가-힣]+$/.test(b)) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) diff++;
  return diff === 1;
}

const POSITION_LABELS: Record<UserPosition, string> = {
  sender: "보낸 사람",
  sole_recipient: "받는 사람 (혼자)",
  recipient: "받는 사람 (여러 명 중 하나)",
  cc_only: "참조로만 받음",
  attendee: "참석자",
  unknown: "알 수 없음",
};

const formatPerson = (p: Person) => [p.name, p.email && `<${p.email}>`].filter(Boolean).join(" ");

/** 추출 프롬프트에 넣을 "사용자와 관련자" 설명 */
export function describeIdentity(identity: UserIdentity, participants: Participants | undefined, variants: string[]): string {
  const lines = [
    `사용자 이름: ${identity.name}`,
    `사용자의 다른 이름: ${identity.aliases.length ? identity.aliases.join(", ") : "없음"}`,
  ];
  if (participants) {
    if (participants.from) lines.push(`보낸 사람: ${formatPerson(participants.from)}`);
    if (participants.to?.length) lines.push(`받는 사람: ${participants.to.map(formatPerson).join(", ")}`);
    if (participants.cc?.length) lines.push(`참조: ${participants.cc.map(formatPerson).join(", ")}`);
    if (participants.attendees?.length) lines.push(`참석자: ${participants.attendees.map(formatPerson).join(", ")}`);
  }
  lines.push(`사용자의 위치: ${POSITION_LABELS[userPosition(identity, participants)]}`);
  if (variants.length > 0) {
    lines.push(`이름 주의: 원문의 ${variants.map((v) => `'${v}'`).join(", ")}은(는) 사용자 이름을 잘못 받아쓴 것일 수 있습니다.`);
  }
  return lines.join("\n");
}
