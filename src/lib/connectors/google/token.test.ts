import { describe, expect, it, vi } from "vitest";

import { GoogleOAuthError, type GoogleToken } from "./oauth";
import { googleAccess, googleErrorReason, GoogleReauthError } from "./token";

// 저장된 Google 토큰으로 API 부르기 (docs/go-live/google-integration.md 2-3 갱신 · invalid_grant · API 오류).

const NOW = Date.parse("2026-09-29T00:00:00.000Z");
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const API = "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=x";

const stored = (extra: Partial<GoogleToken> = {}): GoogleToken => ({
  access_token: "old-access",
  refresh_token: "fake-refresh",
  expires_at: NOW + 10 * 60_000,
  scope: "https://www.googleapis.com/auth/gmail.readonly",
  ...extra,
});

/**
 * 토큰 창구와 API를 흉내 낸다. API는 valid에 든 액세스 토큰에만 200, 그 밖에는 401.
 * 토큰 창구는 refresh 응답을 준다 (기본: new-access).
 */
function fakeGoogle(options: { valid?: string[]; refresh?: () => Response } = {}) {
  const valid = options.valid ?? ["new-access"];
  const apiCalls: string[] = [];
  let refreshCalls = 0;
  const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
    if (url === TOKEN_URL) {
      refreshCalls++;
      return options.refresh?.() ?? new Response(JSON.stringify({ access_token: "new-access", expires_in: 3599 }));
    }
    const auth = (init.headers as Record<string, string>).Authorization;
    apiCalls.push(auth);
    return valid.some((token) => auth === `Bearer ${token}`) ? new Response(JSON.stringify({ ok: true })) : new Response("{}", { status: 401 });
  });
  return { fetchImpl: fetchImpl as unknown as typeof fetch, apiCalls, refreshCalls: () => refreshCalls };
}

function tokenStore(token: unknown) {
  return { load: vi.fn(async () => token), save: vi.fn<(token: GoogleToken) => Promise<void>>(async () => {}) };
}

const config = (fetchImpl: typeof fetch) => ({ clientId: "fake-client-id", clientSecret: "fake-client-secret", redirectUri: "https://api.example.dev/cb", fetch: fetchImpl });

describe("googleAccess", () => {
  it("만료까지 여유가 있으면 저장된 토큰을 그대로 붙여 부르고 갱신하지 않는다", async () => {
    const google = fakeGoogle({ valid: ["old-access"] });
    const store = tokenStore(stored());
    const access = googleAccess(store, config(google.fetchImpl), { now: () => NOW });

    const response = await access.get(API);
    await access.get(API);

    expect(response.status).toBe(200);
    expect(google.apiCalls).toEqual(["Bearer old-access", "Bearer old-access"]);
    expect(google.refreshCalls()).toBe(0);
    expect(store.save).not.toHaveBeenCalled();
    // 토큰은 한 번만 읽는다
    expect(store.load).toHaveBeenCalledTimes(1);
  });

  it("만료 60초 전이면 먼저 갱신해 저장하고 새 토큰으로 부른다", async () => {
    const google = fakeGoogle();
    const store = tokenStore(stored({ expires_at: NOW + 60_000 }));
    const access = googleAccess(store, config(google.fetchImpl), { now: () => NOW });

    expect((await access.get(API)).status).toBe(200);
    expect(google.apiCalls).toEqual(["Bearer new-access"]);
    expect(store.save).toHaveBeenCalledWith({
      access_token: "new-access",
      refresh_token: "fake-refresh",
      expires_at: NOW + 3_599_000,
      scope: "https://www.googleapis.com/auth/gmail.readonly",
    });
  });

  it("만료 61초 전이면 아직 갱신하지 않는다", async () => {
    const google = fakeGoogle({ valid: ["old-access"] });
    const access = googleAccess(tokenStore(stored({ expires_at: NOW + 61_000 })), config(google.fetchImpl), { now: () => NOW });
    await access.get(API);
    expect(google.refreshCalls()).toBe(0);
  });

  it("API가 401이면 한 번 갱신해 저장하고 다시 부른다. 다음 요청은 새 토큰으로 바로", async () => {
    const google = fakeGoogle();
    const store = tokenStore(stored());
    const access = googleAccess(store, config(google.fetchImpl), { now: () => NOW });

    expect((await access.get(API)).status).toBe(200);
    await access.get(API);

    expect(google.apiCalls).toEqual(["Bearer old-access", "Bearer new-access", "Bearer new-access"]);
    expect(google.refreshCalls()).toBe(1);
    expect(store.save).toHaveBeenCalledTimes(1);
  });

  it("갱신한 토큰으로도 401이면 그 응답을 돌려준다 (다시 갱신하며 돌지 않는다)", async () => {
    const google = fakeGoogle({ valid: [] });
    const access = googleAccess(tokenStore(stored()), config(google.fetchImpl), { now: () => NOW });

    expect((await access.get(API)).status).toBe(401);
    expect(google.apiCalls).toEqual(["Bearer old-access", "Bearer new-access"]);
    expect(google.refreshCalls()).toBe(1);
  });

  it("같은 토큰으로 동시에 401을 받은 요청들은 갱신 하나를 함께 기다린다", async () => {
    const google = fakeGoogle();
    const store = tokenStore(stored());
    const access = googleAccess(store, config(google.fetchImpl), { now: () => NOW });

    const responses = await Promise.all([access.get(API), access.get(API), access.get(API)]);

    expect(responses.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(google.refreshCalls()).toBe(1);
    expect(store.save).toHaveBeenCalledTimes(1);
    expect(google.apiCalls.filter((a) => a === "Bearer new-access")).toHaveLength(3);
  });

  it("갱신이 400 invalid_grant면 GoogleReauthError (저장하지 않는다)", async () => {
    const google = fakeGoogle({ refresh: () => new Response(JSON.stringify({ error: "invalid_grant", error_description: "Token has been expired or revoked." }), { status: 400 }) });
    const store = tokenStore(stored({ expires_at: NOW - 1 }));
    const access = googleAccess(store, config(google.fetchImpl), { now: () => NOW });

    await expect(access.get(API)).rejects.toBeInstanceOf(GoogleReauthError);
    expect(store.save).not.toHaveBeenCalled();
    expect(google.apiCalls).toEqual([]);
  });

  it("401 뒤 갱신이 invalid_grant여도 GoogleReauthError", async () => {
    const google = fakeGoogle({ refresh: () => new Response(JSON.stringify({ error: "invalid_grant" }), { status: 400 }) });
    const access = googleAccess(tokenStore(stored()), config(google.fetchImpl), { now: () => NOW });
    await expect(access.get(API)).rejects.toBeInstanceOf(GoogleReauthError);
  });

  it("갱신 토큰 없이 만료됐으면 토큰 창구를 부르지 않고 GoogleReauthError", async () => {
    const google = fakeGoogle();
    const access = googleAccess(tokenStore(stored({ refresh_token: null, expires_at: NOW - 1 })), config(google.fetchImpl), { now: () => NOW });
    await expect(access.get(API)).rejects.toBeInstanceOf(GoogleReauthError);
    expect(google.refreshCalls()).toBe(0);
  });

  it("invalid_grant가 아닌 토큰 창구 오류(401 invalid_client)는 다시 연결로 보지 않고 그대로 던진다", async () => {
    const google = fakeGoogle({ refresh: () => new Response(JSON.stringify({ error: "invalid_client" }), { status: 401 }) });
    const error = await googleAccess(tokenStore(stored({ expires_at: NOW })), config(google.fetchImpl), { now: () => NOW })
      .get(API)
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(GoogleOAuthError);
    expect(error).not.toBeInstanceOf(GoogleReauthError);
    expect(error).toMatchObject({ status: 401, code: "invalid_client" });
  });

  it("저장된 토큰 형식이 다르면 부르지 않고 던진다", async () => {
    const google = fakeGoogle();
    const access = googleAccess(tokenStore({ access_token: "x" }), config(google.fetchImpl), { now: () => NOW });
    await expect(access.get(API)).rejects.toThrow(/형식/);
    expect(google.apiCalls).toEqual([]);
  });
});

describe("googleErrorReason", () => {
  const response = (body: string) => new Response(body, { status: 403 });

  it("errors[0].reason을 먼저, 없으면 status", async () => {
    expect(await googleErrorReason(response(JSON.stringify({ error: { status: "RESOURCE_EXHAUSTED", errors: [{ reason: "rateLimitExceeded" }] } })))).toBe(
      "rateLimitExceeded",
    );
    expect(await googleErrorReason(response(JSON.stringify({ error: { status: "PERMISSION_DENIED" } })))).toBe("PERMISSION_DENIED");
  });

  it("JSON이 아니거나 모양이 다르면 undefined", async () => {
    expect(await googleErrorReason(response("<html>"))).toBeUndefined();
    expect(await googleErrorReason(response(JSON.stringify({ error: "invalid_grant" })))).toBeUndefined();
  });
});
