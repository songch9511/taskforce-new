import { describe, expect, it } from "vitest";

import {
  exchangeGoogleCode,
  GOOGLE_AUTHORIZE_URL,
  googleAuthorizeUrl,
  GoogleOAuthError,
  grantedScopes,
  idTokenAccount,
  isInvalidGrant,
  missingScopes,
  refreshGoogleToken,
  revokeGoogleToken,
  type GoogleToken,
} from "./oauth";

// Google OAuth (docs/go-live/google-integration.md 2-3): 권한 주소 · code 교환 · id_token 읽기 · 받은 범위(G10) · 갱신 · 폐기.

const GMAIL_READONLY = "https://www.googleapis.com/auth/gmail.readonly";
const USERINFO_EMAIL = "https://www.googleapis.com/auth/userinfo.email";
const config = { clientId: "fake-client-id", clientSecret: "fake-client-secret", redirectUri: "https://api.example.dev/api/connectors/gmail/callback" };
const now = new Date("2026-09-29T00:00:00.000Z");

/** 서명 확인 없이 내용만 읽으므로 머리 · 서명 자리는 아무 값이나 */
const idToken = (claims: unknown) => ["e30", Buffer.from(JSON.stringify(claims)).toString("base64url"), "fake-signature"].join(".");

/** 부른 요청을 남기고 준비한 응답을 차례로 돌려주는 가짜 fetch */
function fakeFetch(...responses: Response[]) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return responses[calls.length - 1];
  }) as unknown as typeof fetch;
  const body = (index = 0) => new URLSearchParams(String(calls[index].init.body));
  return { fetchImpl, calls, body };
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe("googleAuthorizeUrl", () => {
  it("갱신 토큰(offline) · 매번 동의(consent) · 범위를 섞지 않음(include_granted_scopes=false) · state를 담는다", () => {
    const url = new URL(googleAuthorizeUrl(config, ["openid", "email", GMAIL_READONLY], "state-1"));
    expect(url.origin + url.pathname).toBe(GOOGLE_AUTHORIZE_URL);
    expect(Object.fromEntries(url.searchParams)).toEqual({
      client_id: "fake-client-id",
      redirect_uri: config.redirectUri,
      response_type: "code",
      scope: `openid email ${GMAIL_READONLY}`,
      access_type: "offline",
      prompt: "consent",
      include_granted_scopes: "false",
      state: "state-1",
    });
  });
});

describe("받은 범위 (G10)", () => {
  it("짧은 이름(email · profile)은 토큰 응답의 긴 이름으로 바꾸고 겹친 것은 하나로", () => {
    expect(grantedScopes(`openid  email ${USERINFO_EMAIL} ${GMAIL_READONLY}`)).toEqual(["openid", USERINFO_EMAIL, GMAIL_READONLY]);
    expect(grantedScopes("profile")).toEqual(["https://www.googleapis.com/auth/userinfo.profile"]);
    expect(grantedScopes("")).toEqual([]);
  });

  it("요청한 범위 중 받지 못한 것만 돌려준다 (짧은 이름으로 요청해도)", () => {
    const granted = grantedScopes(`openid ${USERINFO_EMAIL}`);
    expect(missingScopes(granted, ["openid", "email", GMAIL_READONLY])).toEqual([GMAIL_READONLY]);
    expect(missingScopes(grantedScopes(`openid ${USERINFO_EMAIL} ${GMAIL_READONLY}`), ["openid", "email", GMAIL_READONLY])).toEqual([]);
  });
});

describe("idTokenAccount", () => {
  it("sub와 확인된 주소(소문자)를 읽는다", () => {
    expect(idTokenAccount(idToken({ sub: "google-sub-1", email: " Me@Company.dev ", email_verified: true }))).toEqual({
      sub: "google-sub-1",
      email: "me@company.dev",
    });
  });

  it("email_verified가 false(불리언 · 글자)면 주소를 쓰지 않는다. 없으면 확인된 것으로 본다", () => {
    expect(idTokenAccount(idToken({ sub: "s", email: "me@x.dev", email_verified: false }))).toEqual({ sub: "s", email: null });
    expect(idTokenAccount(idToken({ sub: "s", email: "me@x.dev", email_verified: "false" }))).toEqual({ sub: "s", email: null });
    expect(idTokenAccount(idToken({ sub: "s", email: "me@x.dev" }))).toEqual({ sub: "s", email: "me@x.dev" });
  });

  it("주소가 없으면 email null (openid만 받음)", () => {
    expect(idTokenAccount(idToken({ sub: "s" }))).toEqual({ sub: "s", email: null });
  });

  it("sub가 없거나 · 내용이 JSON이 아니거나 · 점이 없으면 null", () => {
    expect(idTokenAccount(idToken({ email: "me@x.dev" }))).toBeNull();
    expect(idTokenAccount(`e30.${Buffer.from("not json").toString("base64url")}.sig`)).toBeNull();
    expect(idTokenAccount("no-dots")).toBeNull();
  });
});

describe("exchangeGoogleCode", () => {
  it("code를 토큰으로 바꾼다: 만료 시각은 epoch ms, 범위 목록, id_token의 계정", async () => {
    const { fetchImpl, calls, body } = fakeFetch(
      json({
        access_token: "fake-access",
        expires_in: 3599,
        refresh_token: "fake-refresh",
        scope: `openid ${USERINFO_EMAIL} ${GMAIL_READONLY}`,
        token_type: "Bearer",
        id_token: idToken({ sub: "google-sub-1", email: "me@company.dev", email_verified: true }),
      }),
    );
    const grant = await exchangeGoogleCode({ ...config, fetch: fetchImpl }, "code-1", now);

    expect(calls[0].url).toBe("https://oauth2.googleapis.com/token");
    expect(calls[0].init.method).toBe("POST");
    expect(Object.fromEntries(body())).toEqual({
      client_id: "fake-client-id",
      client_secret: "fake-client-secret",
      grant_type: "authorization_code",
      code: "code-1",
      redirect_uri: config.redirectUri,
    });
    expect(grant).toEqual({
      token: { access_token: "fake-access", refresh_token: "fake-refresh", expires_at: now.getTime() + 3_599_000, scope: `openid ${USERINFO_EMAIL} ${GMAIL_READONLY}` },
      scopes: ["openid", USERINFO_EMAIL, GMAIL_READONLY],
      account: { sub: "google-sub-1", email: "me@company.dev" },
    });
  });

  it("id_token이 없으면(openid 빠짐) account는 null, 갱신 토큰이 없으면 null", async () => {
    const { fetchImpl } = fakeFetch(json({ access_token: "fake-access", expires_in: 3600, scope: GMAIL_READONLY }));
    const grant = await exchangeGoogleCode({ ...config, fetch: fetchImpl }, "code-1", now);
    expect(grant.account).toBeNull();
    expect(grant.token.refresh_token).toBeNull();
  });

  it("토큰 창구가 거절하면 상태 · 오류 코드를 담은 GoogleOAuthError", async () => {
    const { fetchImpl } = fakeFetch(json({ error: "invalid_grant", error_description: "Bad Request" }, 400));
    const error = await exchangeGoogleCode({ ...config, fetch: fetchImpl }, "used-code", now).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(GoogleOAuthError);
    expect(error).toMatchObject({ status: 400, code: "invalid_grant" });
    expect((error as Error).message).not.toContain("used-code");
  });

  it("응답 형식이 다르면 502 GoogleOAuthError", async () => {
    const { fetchImpl } = fakeFetch(json({ token_type: "Bearer" }));
    await expect(exchangeGoogleCode({ ...config, fetch: fetchImpl }, "c", now)).rejects.toMatchObject({ name: "GoogleOAuthError", status: 502 });
  });
});

describe("refreshGoogleToken", () => {
  const stored: GoogleToken = { access_token: "old-access", refresh_token: "fake-refresh", expires_at: 0, scope: GMAIL_READONLY };

  it("갱신 토큰으로 새 액세스 토큰을 받는다. 응답에 갱신 토큰 · 범위가 없으면 저장된 값을 그대로 쓴다", async () => {
    const { fetchImpl, body } = fakeFetch(json({ access_token: "new-access", expires_in: 3599 }));
    const next = await refreshGoogleToken({ ...config, fetch: fetchImpl }, stored, now);
    expect(Object.fromEntries(body())).toMatchObject({ grant_type: "refresh_token", refresh_token: "fake-refresh", client_id: "fake-client-id" });
    expect(next).toEqual({ access_token: "new-access", refresh_token: "fake-refresh", expires_at: now.getTime() + 3_599_000, scope: GMAIL_READONLY });
  });

  it("응답에 새 갱신 토큰 · 범위가 오면 그것을 쓴다", async () => {
    const { fetchImpl } = fakeFetch(json({ access_token: "new-access", expires_in: 60, refresh_token: "rotated", scope: "openid" }));
    const next = await refreshGoogleToken({ ...config, fetch: fetchImpl }, stored, now);
    expect(next).toMatchObject({ refresh_token: "rotated", scope: "openid" });
  });

  it("갱신 토큰이 없으면 부르지 않고 invalid_grant로 던진다 (다시 연결해야 한다)", async () => {
    const { fetchImpl, calls } = fakeFetch();
    const error = await refreshGoogleToken({ ...config, fetch: fetchImpl }, { ...stored, refresh_token: null }, now).catch((e: unknown) => e);
    expect(isInvalidGrant(error)).toBe(true);
    expect(calls).toEqual([]);
  });

  it("400 invalid_grant는 isInvalidGrant, 401 invalid_client는 아니다", async () => {
    const expired = await refreshGoogleToken({ ...config, fetch: fakeFetch(json({ error: "invalid_grant" }, 400)).fetchImpl }, stored, now).catch((e: unknown) => e);
    expect(isInvalidGrant(expired)).toBe(true);
    const client = await refreshGoogleToken({ ...config, fetch: fakeFetch(json({ error: "invalid_client" }, 401)).fetchImpl }, stored, now).catch((e: unknown) => e);
    expect(client).toMatchObject({ status: 401, code: "invalid_client" });
    expect(isInvalidGrant(client)).toBe(false);
  });

  it("isInvalidGrant는 GoogleOAuthError만 본다", () => {
    expect(isInvalidGrant(new Error("invalid_grant"))).toBe(false);
    expect(isInvalidGrant(new GoogleOAuthError("x", 400, "invalid_grant"))).toBe(true);
  });
});

describe("revokeGoogleToken", () => {
  it("POST /revoke에 token을 담아 보낸다", async () => {
    const { fetchImpl, calls, body } = fakeFetch(new Response("{}", { status: 200 }));
    await revokeGoogleToken("fake-refresh", { fetch: fetchImpl });
    expect(calls[0].url).toBe("https://oauth2.googleapis.com/revoke");
    expect(calls[0].init.method).toBe("POST");
    expect(Object.fromEntries(body())).toEqual({ token: "fake-refresh" });
  });

  it("이미 폐기 · 만료된 토큰(400 invalid_token)은 성공으로 본다", async () => {
    await expect(revokeGoogleToken("gone", { fetch: fakeFetch(json({ error: "invalid_token" }, 400)).fetchImpl })).resolves.toBeUndefined();
  });

  it("그 밖의 거절 · 서버 오류는 던진다", async () => {
    await expect(revokeGoogleToken("t", { fetch: fakeFetch(json({ error: "invalid_request" }, 400)).fetchImpl })).rejects.toMatchObject({
      status: 400,
      code: "invalid_request",
    });
    await expect(revokeGoogleToken("t", { fetch: fakeFetch(new Response("oops", { status: 503 })).fetchImpl })).rejects.toMatchObject({
      name: "GoogleOAuthError",
      status: 503,
    });
  });
});
