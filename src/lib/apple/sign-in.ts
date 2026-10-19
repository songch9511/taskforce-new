import { createPrivateKey, sign, type KeyObject } from "node:crypto";

import { z } from "zod";

// Sign in with Apple 토큰 폐기 (App Store 5.1.1(v): 계정을 지울 때 Apple REST API로 토큰을 폐기해야 한다).
// Supabase는 앱의 ID 토큰 로그인에서 Apple 토큰을 받지 않으므로, 앱이 삭제 직전에 받은 authorization code를
// 토큰으로 바꾼 뒤(POST /auth/token) 폐기한다(POST /auth/revoke). code · 토큰 · client secret은 로그에 남기지 않는다.
// code는 앱이 보낸 값이라, 바꿔 받은 id_token의 sub가 지우는 계정의 Apple 사용자와 같을 때만 폐기한다
// (다른 Apple 계정의 code로 그 계정의 토큰을 폐기하지 못하게).

const APPLE_AUTH = "https://appleid.apple.com";

/**
 * clientId: 앱 번들 id(앱 안 로그인의 client). servicesId: Mac의 Apple 웹 로그인 Services ID (없으면 web 폐기를 건너뛴다).
 * webReturnUrl: 그 Services ID에 등록한 Return URL (`https://<서버>/api/v1/apple/return`). 웹 authorize가 보낸 `redirect_uri`와 같은 값을 code 교환에도 보내야 한다 (Apple 요구)
 */
export type AppleSignInConfig = { teamId: string; keyId: string; key: KeyObject; clientId: string; servicesId?: string; webReturnUrl?: string };
/** 폐기할 code를 받은 client: app = 번들 id(iPhone 앱 안 로그인), web = Services ID(Mac 브라우저 창 로그인) */
export type AppleClientKind = "app" | "web";
export type AppleFetch = typeof fetch;

/** APPLE_TEAM_ID · APPLE_KEY_ID · APPLE_PRIVATE_KEY(.p8, 줄바꿈은 \n) · APPLE_CLIENT_ID(비우면 번들 id) · APPLE_SERVICES_ID · APPLE_WEB_RETURN_URL(선택, 둘 다 있어야 web 폐기). 없으면 null (폐기를 건너뛴다) */
export function appleSignInConfigFromEnv(env: Record<string, string | undefined> = process.env): AppleSignInConfig | null {
  const { APPLE_TEAM_ID: teamId, APPLE_KEY_ID: keyId, APPLE_PRIVATE_KEY: pem } = env;
  if (!teamId || !keyId || !pem) return null;
  return {
    teamId,
    keyId,
    key: createPrivateKey(pem.replace(/\\n/g, "\n")),
    clientId: env.APPLE_CLIENT_ID || "dev.taskforcelabs.taskforce",
    servicesId: env.APPLE_SERVICES_ID || undefined,
    webReturnUrl: env.APPLE_WEB_RETURN_URL || undefined,
  };
}

/** Services ID에 등록한 중계 주소 모양인지: https · 도메인(IP · localhost 아님) · 경로 `/api/v1/apple/return` · 쿼리 · 해시 · 사용자 정보 없음 */
export function isAppleWebReturnUrl(value: string | undefined): value is string {
  if (!value) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  const host = url.hostname.toLowerCase();
  const isDomain = host.includes(".") && /[a-z]/.test(host) && host !== "localhost" && !host.endsWith(".localhost") && !host.includes(":");
  return url.protocol === "https:" && isDomain && url.pathname === "/api/v1/apple/return" && !url.search && !url.hash && !url.username && !url.password;
}

const base64url = (input: Buffer | string) => Buffer.from(input).toString("base64url");

/** client secret (ES256 JWT). Apple은 최대 6개월까지 받지만, 부를 때마다 5분짜리로 만든다. clientId: sub로 넣을 client (기본 번들 id) */
export function appleClientSecret(config: AppleSignInConfig, now = new Date(), clientId = config.clientId): string {
  const iat = Math.floor(now.getTime() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat, exp: iat + 300, aud: APPLE_AUTH, sub: clientId }));
  const signature = sign("sha256", Buffer.from(`${header}.${claims}`), { key: config.key, dsaEncoding: "ieee-p1363" });
  return `${header}.${claims}.${base64url(signature)}`;
}

export class AppleAuthError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "AppleAuthError";
  }
}

const tokenResponseSchema = z.object({ access_token: z.string().optional(), refresh_token: z.string().optional(), id_token: z.string().optional() });

/**
 * Apple이 토큰 엔드포인트에서 직접 준 id_token의 sub · aud (TLS로 Apple에서 받은 응답이라 서명은 다시 확인하지 않는다).
 * 형식이 다르면 null.
 */
export function appleIdTokenClaims(idToken: string | undefined): { sub: string; aud: string | string[] | undefined } | null {
  const payload = idToken?.split(".")[1];
  if (!payload) return null;
  try {
    const claims = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as { sub?: unknown; aud?: unknown };
    if (typeof claims.sub !== "string" || claims.sub.length === 0) return null;
    return { sub: claims.sub, aud: claims.aud as string | string[] | undefined };
  } catch {
    return null;
  }
}

async function post(path: string, form: Record<string, string>, doFetch: AppleFetch): Promise<Response> {
  return doFetch(`${APPLE_AUTH}${path}`, {
    signal: AbortSignal.timeout(10_000),
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form).toString(),
  });
}

/**
 * mismatch: code로 받은 토큰이 지우는 계정의 Apple 사용자 것이 아님(또는 확인할 수 없음) → 폐기하지 않음. no_identity: Apple로 가입한 계정이 아님.
 * not_configured: 키 설정이 없거나, web인데 APPLE_SERVICES_ID가 없음
 */
export type AppleRevokeResult = "revoked" | "no_token" | "not_configured" | "no_identity" | "mismatch";

/**
 * 앱이 보낸 authorization code로 Apple 토큰을 받아 폐기한다. refresh token이 있으면 그것을, 없으면 access token을 폐기한다.
 * expectedSub: 지우는 계정에 연결된 Apple 사용자 id (Supabase identity의 sub). 없으면(Apple 가입이 아님) 부르지 않는다.
 * 바꿔 받은 id_token의 sub(와 aud)가 맞지 않으면 폐기하지 않고 mismatch.
 * options.client: code를 받은 client. app(기본)은 번들 id, web은 Services ID로 client secret(sub) · 교환 · 폐기 · aud 확인을 한다.
 * web 교환에는 `redirect_uri`(서버 설정 `webReturnUrl`)를 함께 보낸다.
 * 설정이 없거나 code가 없으면 부르지 않고 이유만 돌려준다. Apple이 거절하면 AppleAuthError (부르는 쪽이 로그만 남기고 삭제를 계속한다).
 */
export async function revokeAppleSignIn(
  config: AppleSignInConfig | null,
  authorizationCode: string | undefined,
  expectedSub: string | null,
  options: { fetch?: AppleFetch; now?: Date; client?: AppleClientKind } = {},
): Promise<AppleRevokeResult> {
  if (!config) return "not_configured";
  const web = options.client === "web";
  const clientId = web ? config.servicesId : config.clientId;
  if (!clientId) return "not_configured";
  // web 교환에는 authorize가 보낸 것과 같은 redirect_uri가 필요하다: 서버 설정의 return URL만 쓰고, 없거나 중계 주소 모양이 아니면 Apple을 부르지 않는다
  const redirectUri = web ? config.webReturnUrl : undefined;
  if (web && !isAppleWebReturnUrl(redirectUri)) return "not_configured";
  if (!expectedSub) return "no_identity";
  if (!authorizationCode) return "no_token";
  const doFetch = options.fetch ?? fetch;
  const client = { client_id: clientId, client_secret: appleClientSecret(config, options.now, clientId) };

  const exchanged = await post("/auth/token", { ...client, code: authorizationCode, grant_type: "authorization_code", ...(redirectUri ? { redirect_uri: redirectUri } : {}) }, doFetch);
  if (!exchanged.ok) throw new AppleAuthError(`Apple 토큰 교환 실패 (${exchanged.status})`, exchanged.status);
  const tokens = tokenResponseSchema.safeParse(await exchanged.json());
  const claims = appleIdTokenClaims(tokens.data?.id_token);
  // aud가 없으면(형식이 다르거나 값이 빠짐) 이 앱 것인지 확인할 수 없으니 폐기하지 않는다.
  const audOk = claims?.aud !== undefined && (claims.aud === clientId || (Array.isArray(claims.aud) && claims.aud.includes(clientId)));
  if (!claims || claims.sub !== expectedSub || !audOk) return "mismatch";
  const token = tokens.data?.refresh_token
    ? { token: tokens.data.refresh_token, token_type_hint: "refresh_token" }
    : tokens.data?.access_token
      ? { token: tokens.data.access_token, token_type_hint: "access_token" }
      : null;
  if (!token) return "no_token";

  const revoked = await post("/auth/revoke", { ...client, ...token }, doFetch);
  if (!revoked.ok) throw new AppleAuthError(`Apple 토큰 폐기 실패 (${revoked.status})`, revoked.status);
  return "revoked";
}
