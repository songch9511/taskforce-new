import { describe, expect, it } from "vitest";

import { isSignedOAuthState, newOAuthState, OAUTH_STATE_TTL_MS, signOAuthState, verifyOAuthState } from "./oauth-state";

const SECRET = "s".repeat(64);
const ALICE = "00000000-0000-4000-8000-00000000000a";
const BOB = "00000000-0000-4000-8000-00000000000b";
const NOW = new Date("2026-09-27T01:00:00Z");

const issue = (overrides: Partial<{ userId: string }> = {}) => newOAuthState({ userId: ALICE, provider: "notion", ...overrides }, SECRET, NOW);

/** 서명은 그대로 두고 내용(가운데 조각)만 바꾼다 */
function withPayload(state: string, change: (payload: Record<string, unknown>) => Record<string, unknown>): string {
  const [prefix, body, signature] = state.split(".");
  const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
  return [prefix, Buffer.from(JSON.stringify(change(payload))).toString("base64url"), signature].join(".");
}

describe("서명된 OAuth state", () => {
  it("정상: 서버가 만든 state는 내용 그대로 확인된다", () => {
    const { state, payload } = issue();
    expect(isSignedOAuthState(state)).toBe(true);
    expect(payload).toEqual({ userId: ALICE, provider: "notion", nonce: payload.nonce, exp: Math.floor((NOW.getTime() + OAUTH_STATE_TTL_MS) / 1000) });
    expect(payload.nonce.length).toBeGreaterThanOrEqual(32);
    expect(verifyOAuthState(state, SECRET, NOW)).toEqual({ ok: true, payload });
  });

  it("nonce는 매번 다르다", () => {
    expect(issue().payload.nonce).not.toBe(issue().payload.nonce);
  });

  it("변조: 사용자 id를 다른 사용자로 바꾸면 서명이 맞지 않는다", () => {
    const tampered = withPayload(issue().state, (p) => ({ ...p, userId: BOB }));
    expect(verifyOAuthState(tampered, SECRET, NOW)).toEqual({ ok: false, reason: "bad_signature" });
  });

  it("변조: 만료 시각을 늘리거나 서명 한 글자를 바꾸면 거부한다", () => {
    const { state } = issue();
    expect(verifyOAuthState(withPayload(state, (p) => ({ ...p, exp: (p.exp as number) + 3600 })), SECRET, NOW).ok).toBe(false);
    const signatureStart = state.lastIndexOf(".") + 1;
    const middle = signatureStart + 10;
    const flipped = state.slice(0, middle) + (state[middle] === "A" ? "B" : "A") + state.slice(middle + 1);
    expect(verifyOAuthState(flipped, SECRET, NOW)).toEqual({ ok: false, reason: "bad_signature" });
    // 마지막 글자의 남는 비트만 바꾼 비정규 서명(같은 바이트로 디코딩됨)도 거부한다.
    const last = state.at(-1)!;
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const sibling = alphabet[alphabet.indexOf(last) ^ 1];
    expect(verifyOAuthState(state.slice(0, -1) + sibling, SECRET, NOW)).toEqual({ ok: false, reason: "bad_signature" });
  });

  it("다른 키로 서명한 state는 거부한다", () => {
    const { payload } = issue();
    expect(verifyOAuthState(signOAuthState(payload, "x".repeat(64)), SECRET, NOW)).toEqual({ ok: false, reason: "bad_signature" });
  });

  it("만료: 10분이 지나면 거부한다", () => {
    const { state } = issue();
    expect(verifyOAuthState(state, SECRET, new Date(NOW.getTime() + OAUTH_STATE_TTL_MS - 1000)).ok).toBe(true);
    expect(verifyOAuthState(state, SECRET, new Date(NOW.getTime() + OAUTH_STATE_TTL_MS))).toEqual({ ok: false, reason: "expired" });
  });

  it("형식이 다른 값(쿠키 흐름의 state · 잘린 값 · 모르는 서비스)은 거부한다", () => {
    expect(isSignedOAuthState("abcDEF123")).toBe(false);
    expect(verifyOAuthState("abcDEF123", SECRET, NOW)).toEqual({ ok: false, reason: "malformed" });
    expect(verifyOAuthState("v1.onlytwo", SECRET, NOW)).toEqual({ ok: false, reason: "malformed" });
    const zoom = signOAuthState({ ...issue().payload, provider: "zoom" as never }, SECRET);
    expect(verifyOAuthState(zoom, SECRET, NOW)).toEqual({ ok: false, reason: "malformed" });
  });
});
