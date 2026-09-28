import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

import { z } from "zod";

import { connectProviderSchema, type ConnectProvider } from "@/lib/api/contract";

// 앱의 OAuth 연결에 쓰는 서명된 state (docs/GO_LIVE.md 1장).
// 앱이 띄운 브라우저(ASWebAuthenticationSession)에는 로그인 쿠키도 Authorization 헤더도 없어서, callback은 시작한 사용자를 state로 안다.
// 그래서 state는 서버만 만들 수 있어야 하고(HMAC-SHA256), 짧게 살며(10분), 한 번만 쓴다(nonce는 oauth_nonces에서 지운다).
// state만으로는 연결하지 않는다: 권한 화면을 누른 사람이 시작한 사람과 같다는 보장이 없어서, callback은 완료 대기(handoff)만 만들고
// 연결은 시작한 사용자가 로그인한 앱에서 POST /api/v1/connections/{provider}/complete로 마친다 (callback.ts).
// 형식: v1.<base64url(JSON payload)>.<base64url(HMAC)>. state · 서명 값은 로그에 남기지 않는다.

export type OAuthStatePayload = {
  userId: string;
  provider: ConnectProvider;
  nonce: string;
  /** 만료 시각 (unix 초) */
  exp: number;
};

const PREFIX = "v1";
export const OAUTH_STATE_TTL_MS = 10 * 60_000;

const payloadSchema = z.object({
  userId: z.uuid(),
  provider: connectProviderSchema,
  nonce: z.string().min(16).max(100),
  exp: z.number().int().positive(),
});

const sign = (body: string, secret: string) => createHmac("sha256", secret).update(`${PREFIX}.${body}`).digest();

export function signOAuthState(payload: OAuthStatePayload, secret: string): string {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  return `${PREFIX}.${body}.${sign(body, secret).toString("base64url")}`;
}

/** 새 state와 그 내용. nonce는 부르는 쪽이 oauth_nonces에 저장한다 (callback에서 한 번만 쓴다). */
export function newOAuthState(
  input: { userId: string; provider: ConnectProvider },
  secret: string,
  now = new Date(),
  nonce = randomBytes(24).toString("base64url"),
): { state: string; payload: OAuthStatePayload } {
  const payload: OAuthStatePayload = { ...input, nonce, exp: Math.floor((now.getTime() + OAUTH_STATE_TTL_MS) / 1000) };
  return { state: signOAuthState(payload, secret), payload };
}

/** 쿠키 흐름(웹 /lab)의 임의 문자열 state와 구분한다. 서명 흐름인지만 보고, 믿을 수 있는지는 verifyOAuthState가 정한다. */
export function isSignedOAuthState(state: string): boolean {
  return state.startsWith(`${PREFIX}.`) && state.split(".").length === 3;
}

export type OAuthStateCheck =
  | { ok: true; payload: OAuthStatePayload }
  | { ok: false; reason: "malformed" | "bad_signature" | "expired" };

/** 서명(timing-safe 비교) → 형식 → 만료 순서로 확인한다. 서명이 맞지 않으면 내용을 읽지 않는다. */
export function verifyOAuthState(state: string, secret: string, now = new Date()): OAuthStateCheck {
  if (!isSignedOAuthState(state)) return { ok: false, reason: "malformed" };
  const [, body, signature] = state.split(".");
  const expected = sign(body, secret);
  const given = Buffer.from(signature, "base64url");
  // base64url의 마지막 글자는 쓰지 않는 비트를 품어 서로 다른 문자열이 같은 바이트가 될 수 있다. 서명은 정규형 하나만 받는다.
  if (given.toString("base64url") !== signature) return { ok: false, reason: "bad_signature" };
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return { ok: false, reason: "bad_signature" };

  let json: unknown;
  try {
    json = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  } catch {
    return { ok: false, reason: "malformed" };
  }
  const parsed = payloadSchema.safeParse(json);
  if (!parsed.success) return { ok: false, reason: "malformed" };
  if (parsed.data.exp * 1000 <= now.getTime()) return { ok: false, reason: "expired" };
  return { ok: true, payload: parsed.data };
}
