import { emailDomain, firstEmail } from "./mime";

// Gmail에서 거르는 메일 (G7, docs/go-live/google-integration.md 2-6 거르기). 머리글 · 라벨만 보는 순수 함수다.
// 거른 메일은 본문을 받지 않고 저장하지 않는다 (처리방침 3장 Gmail). 위에서부터 처음 맞는 규칙으로 정한다.

/** 버린 이유 (연결 설정 stats에 개수만 남긴다) */
export type GmailDropReason = "excluded_label" | "auto_submitted" | "category" | "bulk" | "mailing_list" | "no_reply" | "calendar";
/** 남긴 이유: sent = 사용자가 보낸 메일, inbound = 거를 규칙에 걸리지 않은 받은 메일 */
export type GmailKeepReason = "sent" | "inbound";

export type GmailDecision = { keep: true; reason: GmailKeepReason } | { keep: false; reason: GmailDropReason };

export type GmailFilterContext = {
  /** 사용자의 주소 (연결한 Google 주소 · 프로필 이메일 · 로그인 주소), 소문자 */
  userEmails: string[];
  /** 사용자 회사 도메인 (연결한 주소의 도메인, 공용 메일이면 null). 이 도메인의 그룹 메일은 남긴다 */
  companyDomain: string | null;
};

/** 회사 도메인으로 보지 않는 공용 메일 도메인 */
const PUBLIC_DOMAINS = new Set([
  "gmail.com",
  "googlemail.com",
  "naver.com",
  "daum.net",
  "hanmail.net",
  "kakao.com",
  "nate.com",
  "outlook.com",
  "hotmail.com",
  "live.com",
  "msn.com",
  "yahoo.com",
  "yahoo.co.kr",
  "icloud.com",
  "me.com",
  "mac.com",
  "aol.com",
  "proton.me",
  "protonmail.com",
]);

export function companyDomain(accountEmail: string | null): string | null {
  if (!accountEmail?.includes("@")) return null;
  const domain = emailDomain(accountEmail);
  return PUBLIC_DOMAINS.has(domain) ? null : domain;
}

/** ① 목록에서 빼는 라벨 (목록 검색어로도 빼지만, 라벨로 한 번 더 본다) */
const EXCLUDED_LABELS = ["DRAFT", "SPAM", "TRASH", "CHAT"];
/** ④ Gmail 탭 분류 (프로모션 · 소셜) */
const DROPPED_CATEGORIES = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"];
/**
 * ⑦ 보내는 사람의 주소 앞부분: no-reply 낱말로 시작하거나 구분자 뒤에 있음(workspace-noreply@ · notify-noreply@, dev 메일함에서 확인),
 * 또는 알림 · 반송 주소로 시작
 */
const NO_REPLY = /(?:^|[-_.+])(?:no[-_.]?reply|do[-_.]?not[-_.]?reply)|^(?:notification|mailer-daemon|postmaster|bounce)/i;
/** ⑧ Google Calendar가 보내는 초대 · 알림 */
const CALENDAR_SENDER = "calendar-notification@google.com";

const inDomain = (domain: string, company: string) => domain === company || domain.endsWith(`.${company}`);

/** List-Id(`이름 <목록.도메인>`)가 회사 도메인의 목록인가 (Google 그룹 `<team.회사.dev>`) */
function listInDomain(listId: string | undefined, company: string): boolean {
  const id = (listId?.match(/<([^<>]+)>/)?.[1] ?? listId ?? "").trim().toLowerCase();
  return id !== "" && inDomain(id, company);
}

export function filterMessage(message: { labelIds: string[]; headers: Record<string, string> }, context: GmailFilterContext): GmailDecision {
  const { labelIds, headers } = message;
  const from = firstEmail(headers.from);

  // ① 임시 보관 · 스팸 · 휴지통 · 채팅
  if (labelIds.some((l) => EXCLUDED_LABELS.includes(l))) return { keep: false, reason: "excluded_label" };
  // ② 자동 발송 (부재 중 자동 답장 · 시스템 알림). 사용자가 보낸 것도 버린다
  const autoSubmitted = headers["auto-submitted"]?.split(";")[0].trim().toLowerCase();
  if (autoSubmitted && autoSubmitted !== "no") return { keep: false, reason: "auto_submitted" };
  // ③ 사용자가 보낸 메일 (보내는 주소 별칭은 SENT 라벨로 안다)은 늘 남긴다
  if (labelIds.includes("SENT") || (from !== null && context.userEmails.includes(from))) return { keep: true, reason: "sent" };
  // ④ 프로모션 · 소셜 탭
  if (labelIds.some((l) => DROPPED_CATEGORIES.includes(l))) return { keep: false, reason: "category" };
  // ⑤ 대량 발송
  const precedence = headers.precedence?.trim().toLowerCase();
  if (precedence === "bulk" || precedence === "junk") return { keep: false, reason: "bulk" };
  // ⑥ 수신 거부 · 메일링 리스트 머리글. 같은 회사 도메인의 그룹 메일(보낸 주소나 목록 id가 회사 도메인)은 남긴다
  if (headers["list-unsubscribe"] !== undefined || headers["list-id"] !== undefined) {
    const company = context.companyDomain;
    const internal = company !== null && ((from !== null && inDomain(emailDomain(from), company)) || listInDomain(headers["list-id"], company));
    if (!internal) return { keep: false, reason: "mailing_list" };
  }
  // ⑦ no-reply류 보낸 주소
  if (from !== null && NO_REPLY.test(from.slice(0, from.lastIndexOf("@")))) return { keep: false, reason: "no_reply" };
  // ⑧ 일정 초대 · 알림
  const calendar =
    headers["content-type"]?.toLowerCase().includes("text/calendar") ||
    headers["content-class"]?.toLowerCase().includes("calendarmessage") ||
    from === CALENDAR_SENDER ||
    firstEmail(headers.sender) === CALENDAR_SENDER;
  if (calendar) return { keep: false, reason: "calendar" };
  // ⑨ 나머지
  return { keep: true, reason: "inbound" };
}
