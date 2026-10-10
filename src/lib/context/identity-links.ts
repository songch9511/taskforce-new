// 서비스별 "나" (identity_links, 아키텍처 5.5)의 순수 규칙. loadIdentity(src/lib/connectors/store.ts)가 MEMORY_ENABLED일 때 합친다.
// pipeline/identity.ts의 isUser 규칙은 바꾸지 않는다: 여기서는 "나"의 주소 목록만 정한다.
// - "나"로 치는 링크: verified_via가 oauth(연결 결과) · profile(사용자가 적음) · user_confirmed(사용자가 확인)이고 공용 계정이 아닌 것.
// - inferred(자료에서 본 후보)는 확인 전까지 "나"가 아니다. shared_account(팀 공용 메일함 등)는 확인했어도 "나"의 발언이 아니다.
// - 공용 계정으로 표시한 주소는 연결 설정에서 온 주소(google · gmail settings.email)에서도 뺀다. 프로필 · 로그인 주소는 사용자가 정한 값이라 빼지 않는다.
//   추정(inferred) 링크의 공용 표시는 확인 전이라 보지 않는다 (확인된 주소를 추정으로 빼지 않게).
// - 로그인 계정(Sign in with Apple · Google)은 연결이 아니어서 링크로 쓰지 않는다: loadIdentity가 로그인 주소를 그대로 "나"로 본다.

export type IdentityVerifiedVia = "oauth" | "profile" | "user_confirmed" | "inferred";

export type IdentityLinkRow = {
  provider: string;
  account_ref: string;
  email: string | null;
  verified_via: IdentityVerifiedVia;
  shared_account: boolean;
};

const normalizeEmail = (email: string) => email.trim().toLowerCase();

/** 이 링크가 "나"인가 */
export function countsAsMe(link: Pick<IdentityLinkRow, "verified_via" | "shared_account">): boolean {
  return !link.shared_account && (link.verified_via === "oauth" || link.verified_via === "profile" || link.verified_via === "user_confirmed");
}

/**
 * "나"의 주소: 프로필 · 로그인 주소(base) + 연결 설정의 주소(공용으로 표시한 것 빼고) + "나"로 치는 링크의 주소. 소문자, 겹치면 하나.
 * 추정 · 공용 링크는 더하지 않는다.
 */
export function identityEmails(base: readonly string[], connectionEmails: readonly string[], links: readonly IdentityLinkRow[]): string[] {
  const shared = new Set(links.filter((l) => l.shared_account && l.verified_via !== "inferred" && l.email).map((l) => normalizeEmail(l.email!)));
  const linked = links.filter(countsAsMe).flatMap((l) => (l.email ? [normalizeEmail(l.email)] : []));
  return [...new Set([...base, ...connectionEmails.filter((email) => !shared.has(normalizeEmail(email))), ...linked])];
}

/**
 * 연결을 맺을 때 남길 oauth 링크 (saveConnection의 입력으로). 서비스 user id가 연결 결과에 있는 것만:
 * Slack은 "팀:사용자", Google · Gmail은 계정 sub(+ 주소). Notion 연결 id는 워크스페이스라 사람 계정이 아니다: 링크를 쓰지 않는다
 * (Notion user id는 동기화가 알아내는 settings.notionUserId, B2 이후).
 */
export function oauthIdentityFromConnection(input: { provider: string; externalAccountId: string; displayName: string | null }): {
  provider: string;
  accountRef: string;
  email: string | null;
} | null {
  if (input.provider === "slack") return { provider: "slack", accountRef: input.externalAccountId, email: null };
  if (input.provider === "google" || input.provider === "gmail") {
    const email = input.displayName && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.displayName.trim()) ? normalizeEmail(input.displayName) : null;
    return { provider: input.provider, accountRef: input.externalAccountId, email };
  }
  return null;
}
