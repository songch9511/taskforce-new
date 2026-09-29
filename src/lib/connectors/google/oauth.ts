import { z } from "zod";

// Google OAuth: google(Calendar · Meet) · gmail 두 연결이 같이 쓴다 (docs/go-live/google-integration.md 2-3).
// 응답은 모두 zod로 확인한다. 토큰 · code · id_token은 로그에 남기지 않는다 (오류 코드만).

export const GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";

export type GoogleOAuthConfig = { clientId: string; clientSecret: string; redirectUri: string; fetch?: typeof fetch };

/** 토큰 창구(POST /token · /revoke)의 거절. code는 Google의 error 값 (예: invalid_grant · invalid_client) */
export class GoogleOAuthError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
  ) {
    super(message);
    this.name = "GoogleOAuthError";
  }
}

/**
 * 갱신 토큰을 더 쓸 수 없다: 테스트 상태의 7일 만료, 이용자가 Google 계정에서 접근을 거둠, 비밀번호 변경(Gmail 범위),
 * 6개월 미사용, 갱신 토큰 수 한도 초과. Google이 모두 같은 코드로 돌려주므로 가르지 않는다 (9장).
 */
export const isInvalidGrant = (error: unknown) => error instanceof GoogleOAuthError && error.code === "invalid_grant";

/** 짧은 이름으로 요청한 범위는 토큰 응답의 scope에 긴 이름으로 온다 */
const SCOPE_ALIASES: Record<string, string> = {
  email: "https://www.googleapis.com/auth/userinfo.email",
  profile: "https://www.googleapis.com/auth/userinfo.profile",
};
const canonicalScope = (scope: string) => SCOPE_ALIASES[scope] ?? scope;

/**
 * 권한 화면 주소. access_type=offline(갱신 토큰), prompt=consent(다시 연결할 때도 갱신 토큰을 받는다),
 * include_granted_scopes=false(같은 Google 계정이 다른 프로젝트 · 연결에 준 범위가 섞이지 않게).
 */
export function googleAuthorizeUrl(config: Pick<GoogleOAuthConfig, "clientId" | "redirectUri">, scopes: readonly string[], state: string): string {
  const url = new URL(GOOGLE_AUTHORIZE_URL);
  url.search = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    response_type: "code",
    scope: scopes.join(" "),
    access_type: "offline",
    prompt: "consent",
    include_granted_scopes: "false",
    state,
  }).toString();
  return url.toString();
}

/** 토큰 응답의 scope(공백 구분)를 긴 이름 목록으로 */
export function grantedScopes(scope: string): string[] {
  return [...new Set(scope.split(/\s+/).filter(Boolean).map(canonicalScope))];
}

/** 이용자가 권한 화면에서 체크를 빼 받지 못한 범위 (G10) */
export function missingScopes(granted: readonly string[], required: readonly string[]): string[] {
  return required.map(canonicalScope).filter((scope) => !granted.includes(scope));
}

const tokenResponseSchema = z.looseObject({
  access_token: z.string().min(1),
  expires_in: z.number().positive(),
  refresh_token: z.string().min(1).optional(),
  scope: z.string().optional(),
  id_token: z.string().optional(),
});

/** 저장하는 토큰 (암호화해 connection_secrets에). id_token은 저장하지 않는다. expires_at은 epoch ms */
export const googleTokenSchema = z.object({
  access_token: z.string().min(1),
  refresh_token: z.string().min(1).nullable(),
  expires_at: z.number(),
  scope: z.string(),
});
export type GoogleToken = z.infer<typeof googleTokenSchema>;

/** 연결한 Google 계정: sub는 연결 키, email은 표시 이름 · "원문 속 나" (확인된 주소만) */
export type GoogleAccount = { sub: string; email: string | null };

export type GoogleGrant = { token: GoogleToken; scopes: string[]; account: GoogleAccount | null };

async function errorCode(response: Response): Promise<string | undefined> {
  return response
    .json()
    .then((body: unknown) => {
      const error = (body as { error?: unknown } | null)?.error;
      return typeof error === "string" ? error : undefined;
    })
    .catch(() => undefined);
}

async function tokenRequest(config: GoogleOAuthConfig, body: Record<string, string>) {
  const response = await (config.fetch ?? fetch)(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: config.clientId, client_secret: config.clientSecret, ...body }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) {
    const code = await errorCode(response);
    throw new GoogleOAuthError(`Google 토큰 요청 실패 (${response.status}${code ? ` ${code}` : ""})`, response.status, code);
  }
  const parsed = tokenResponseSchema.safeParse(await response.json().catch(() => null));
  if (!parsed.success) throw new GoogleOAuthError("Google 토큰 응답 형식이 예상과 다릅니다", 502);
  return parsed.data;
}

const idTokenClaimsSchema = z.looseObject({
  sub: z.string().min(1),
  email: z.string().optional(),
  email_verified: z.union([z.boolean(), z.string()]).optional(),
});

/**
 * id_token에서 sub · email을 읽는다. 토큰 창구에서 TLS로 직접 받은 것이라 서명은 확인하지 않는다 (OpenID Connect 문서, 9장).
 * 확인되지 않은 주소는 쓰지 않는다. 읽을 수 없으면 null.
 */
export function idTokenAccount(idToken: string): GoogleAccount | null {
  const payload = idToken.split(".")[1];
  if (!payload) return null;
  let claims: unknown;
  try {
    claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
  } catch {
    return null;
  }
  const parsed = idTokenClaimsSchema.safeParse(claims);
  if (!parsed.success) return null;
  const { sub, email, email_verified: verified } = parsed.data;
  const usable = email && verified !== false && verified !== "false";
  return { sub, email: usable ? email.trim().toLowerCase() : null };
}

/** callback의 code를 토큰으로. openid가 빠져 id_token이 없으면 account는 null */
export async function exchangeGoogleCode(config: GoogleOAuthConfig, code: string, now = new Date()): Promise<GoogleGrant> {
  const response = await tokenRequest(config, { grant_type: "authorization_code", code, redirect_uri: config.redirectUri });
  const scope = response.scope ?? "";
  return {
    token: {
      access_token: response.access_token,
      refresh_token: response.refresh_token ?? null,
      expires_at: now.getTime() + response.expires_in * 1000,
      scope,
    },
    scopes: grantedScopes(scope),
    account: response.id_token ? idTokenAccount(response.id_token) : null,
  };
}

/**
 * 액세스 토큰을 새로 받는다. Google은 갱신 토큰을 바꾸지 않는다 (응답에 오면 그것을 쓴다).
 * 갱신 토큰이 없으면 갱신할 수 없으므로 invalid_grant와 같게 본다 (다시 연결해야 한다).
 */
export async function refreshGoogleToken(config: GoogleOAuthConfig, token: GoogleToken, now = new Date()): Promise<GoogleToken> {
  if (!token.refresh_token) throw new GoogleOAuthError("Google 갱신 토큰이 없습니다", 400, "invalid_grant");
  const response = await tokenRequest(config, { grant_type: "refresh_token", refresh_token: token.refresh_token });
  return {
    access_token: response.access_token,
    refresh_token: response.refresh_token ?? token.refresh_token,
    expires_at: now.getTime() + response.expires_in * 1000,
    scope: response.scope ?? token.scope,
  };
}

/**
 * 토큰을 폐기한다 (연결 끊기 · 계정 삭제 · 범위가 빠진 연결). 갱신 토큰을 폐기하면 그 프로젝트에 준 허용 전체가 거둬진다 (9장).
 * 이미 폐기 · 만료된 토큰(400 invalid_token)은 성공으로 본다. 그 밖의 거절 · 서버 오류는 던진다.
 */
export async function revokeGoogleToken(token: string, options: { fetch?: typeof fetch } = {}): Promise<void> {
  const response = await (options.fetch ?? fetch)(REVOKE_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token }),
    signal: AbortSignal.timeout(10_000),
  });
  if (response.ok) return;
  const code = await errorCode(response);
  if (response.status === 400 && code === "invalid_token") return;
  throw new GoogleOAuthError(`Google 토큰 폐기 실패 (${response.status}${code ? ` ${code}` : ""})`, response.status, code);
}
