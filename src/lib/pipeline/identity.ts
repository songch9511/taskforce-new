// 원문 속에서 "누가 사용자인가"를 알아보는 데 쓰는 정보와 규칙.
// 메일 · 캘린더는 주소로 사용자를 확실히 찾을 수 있고, 받아쓰기 회의록은 이름 문자열뿐이라 별칭과 오타 후보가 필요하다.

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
    [participants?.from, ...(participants?.to ?? []), ...(participants?.cc ?? []), ...(participants?.attendees ?? [])]
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
