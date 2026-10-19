import { generateKeyPairSync, verify } from "node:crypto";

import { describe, expect, it } from "vitest";

import { AppleAuthError, appleClientSecret, appleIdTokenClaims, appleSignInConfigFromEnv, revokeAppleSignIn, type AppleSignInConfig } from "./sign-in";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const SERVICES_ID = "dev.taskforcelabs.taskforce.signin";
const WEB_RETURN_URL = "https://api.taskforcelabs.dev/api/v1/apple/return";
const config: AppleSignInConfig = { teamId: "TEAM123456", keyId: "KEY1234567", key: privateKey, clientId: "dev.taskforcelabs.taskforce", servicesId: SERVICES_ID, webReturnUrl: WEB_RETURN_URL };
const NOW = new Date("2026-09-27T01:00:00Z");

type Call = { url: string; form: Record<string, string> };

function fakeFetch(responses: { status?: number; body?: unknown }[]) {
  const calls: Call[] = [];
  let i = 0;
  const fetch = (async (url: string, init: RequestInit) => {
    calls.push({ url, form: Object.fromEntries(new URLSearchParams(init.body as string)) });
    const r = responses[Math.min(i++, responses.length - 1)];
    return new Response(r.body === undefined ? "" : JSON.stringify(r.body), { status: r.status ?? 200 });
  }) as typeof globalThis.fetch;
  return { fetch, calls };
}

const decode = (part: string) => JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
const SUB = "001234.abcdef.0123";
/** Apple 토큰 응답의 id_token 모양 (서명은 보지 않는다) */
const idToken = (claims: Record<string, unknown>) =>
  ["e30", Buffer.from(JSON.stringify(claims)).toString("base64url"), "sig"].join(".");
const ID_TOKEN = idToken({ iss: "https://appleid.apple.com", aud: "dev.taskforcelabs.taskforce", sub: SUB });

describe("appleClientSecret", () => {
  it("ES256 JWT: kid · iss · aud · sub · 5분 만료, 공개 키로 서명이 확인된다", () => {
    const jwt = appleClientSecret(config, NOW);
    const [header, claims, signature] = jwt.split(".");
    expect(decode(header)).toEqual({ alg: "ES256", kid: "KEY1234567" });
    const iat = Math.floor(NOW.getTime() / 1000);
    expect(decode(claims)).toEqual({ iss: "TEAM123456", iat, exp: iat + 300, aud: "https://appleid.apple.com", sub: "dev.taskforcelabs.taskforce" });
    const ok = verify("sha256", Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url"));
    expect(ok).toBe(true);
  });
});

describe("revokeAppleSignIn", () => {
  it("code를 토큰으로 바꾼 뒤 refresh token을 폐기한다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { access_token: "at", refresh_token: "rt", id_token: ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW })).toBe("revoked");
    expect(calls.map((c) => c.url)).toEqual(["https://appleid.apple.com/auth/token", "https://appleid.apple.com/auth/revoke"]);
    expect(calls[0].form).toMatchObject({ client_id: "dev.taskforcelabs.taskforce", code: "auth-code", grant_type: "authorization_code" });
    expect(calls[0].form.client_secret.split(".")).toHaveLength(3);
    expect(calls[1].form).toMatchObject({ client_id: "dev.taskforcelabs.taskforce", token: "rt", token_type_hint: "refresh_token" });
  });

  it("refresh token이 없으면 access token을 폐기한다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { access_token: "at", id_token: ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW })).toBe("revoked");
    expect(calls[1].form).toMatchObject({ token: "at", token_type_hint: "access_token" });
  });

  it("aud가 배열이어도 client id가 있으면 폐기한다", async () => {
    const { fetch } = fakeFetch([
      { body: { refresh_token: "rt", id_token: idToken({ aud: ["dev.taskforcelabs.taskforce", "other.app"], sub: SUB }) } },
      { body: undefined },
    ]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW })).toBe("revoked");
  });

  it("설정이 없거나, Apple로 가입한 계정이 아니거나, code가 없으면 Apple을 부르지 않는다", async () => {
    const { fetch, calls } = fakeFetch([{ body: {} }]);
    expect(await revokeAppleSignIn(null, "auth-code", SUB, { fetch })).toBe("not_configured");
    expect(await revokeAppleSignIn(config, "auth-code", null, { fetch })).toBe("no_identity");
    expect(await revokeAppleSignIn(config, undefined, SUB, { fetch })).toBe("no_token");
    expect(calls).toEqual([]);
  });

  it("code로 받은 토큰이 다른 Apple 사용자 것이거나 확인할 수 없으면 폐기하지 않는다", async () => {
    for (const body of [
      { refresh_token: "rt", id_token: idToken({ aud: "dev.taskforcelabs.taskforce", sub: "someone-else" }) },
      { refresh_token: "rt", id_token: idToken({ aud: "other.app", sub: SUB }) },
      { refresh_token: "rt", id_token: idToken({ sub: SUB }) }, // aud가 없음
      { refresh_token: "rt" },
      { refresh_token: "rt", id_token: "not-a-jwt" },
    ]) {
      const { fetch, calls } = fakeFetch([{ body }, { body: undefined }]);
      expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW })).toBe("mismatch");
      expect(calls.map((c) => c.url)).toEqual(["https://appleid.apple.com/auth/token"]);
    }
  });

  it("Apple이 거절하면 AppleAuthError (메시지에 code · 토큰이 없다)", async () => {
    const exchange = fakeFetch([{ status: 400, body: { error: "invalid_grant" } }]);
    const error = await revokeAppleSignIn(config, "secret-code", SUB, { fetch: exchange.fetch, now: NOW }).catch((e) => e);
    expect(error).toBeInstanceOf(AppleAuthError);
    expect(error.message).toBe("Apple 토큰 교환 실패 (400)");
    const revoke = fakeFetch([{ body: { refresh_token: "rt", id_token: ID_TOKEN } }, { status: 500 }]);
    await expect(revokeAppleSignIn(config, "c", SUB, { fetch: revoke.fetch, now: NOW })).rejects.toThrow("Apple 토큰 폐기 실패 (500)");
  });
});

describe("revokeAppleSignIn — Mac 웹 재확인 (client = web)", () => {
  const WEB_ID_TOKEN = idToken({ iss: "https://appleid.apple.com", aud: SERVICES_ID, sub: SUB });

  it("client secret의 sub · 교환 · 폐기의 client_id · aud 확인이 모두 Services ID다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { refresh_token: "rt", id_token: WEB_ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW, client: "web" })).toBe("revoked");
    expect(calls[0].form).toMatchObject({ client_id: SERVICES_ID, code: "auth-code", grant_type: "authorization_code" });
    expect(decode(calls[0].form.client_secret.split(".")[1])).toMatchObject({ iss: "TEAM123456", sub: SERVICES_ID });
    expect(calls[1].form).toMatchObject({ client_id: SERVICES_ID, token: "rt", token_type_hint: "refresh_token" });
    expect(decode(calls[1].form.client_secret.split(".")[1])).toMatchObject({ sub: SERVICES_ID });
  });

  it("web인데 토큰의 aud가 번들 id면(서로 바뀐 code) 폐기하지 않는다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { refresh_token: "rt", id_token: ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW, client: "web" })).toBe("mismatch");
    expect(calls.map((c) => c.url)).toEqual(["https://appleid.apple.com/auth/token"]);
  });

  it("app(기본)인데 토큰의 aud가 Services ID면 폐기하지 않는다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { refresh_token: "rt", id_token: WEB_ID_TOKEN } }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW })).toBe("mismatch");
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW, client: "app" })).toBe("mismatch");
    expect(calls.map((c) => c.url)).toEqual(["https://appleid.apple.com/auth/token", "https://appleid.apple.com/auth/token"]);
    expect(calls.every((c) => c.form.client_id === "dev.taskforcelabs.taskforce")).toBe(true);
  });

  it("Services ID가 설정되지 않았으면 not_configured: Apple을 부르지 않는다", async () => {
    const { fetch, calls } = fakeFetch([{ body: {} }]);
    const withoutServicesId: AppleSignInConfig = { ...config, servicesId: undefined };
    expect(await revokeAppleSignIn(withoutServicesId, "auth-code", SUB, { fetch, client: "web" })).toBe("not_configured");
    expect(await revokeAppleSignIn({ ...config, servicesId: "" }, "auth-code", SUB, { fetch, client: "web" })).toBe("not_configured");
    expect(calls).toEqual([]);
  });

  // 검토 1 P2: 웹 authorize는 `redirect_uri`를 보냈으니 /auth/token 교환도 같은 값을 보내야 한다 (Apple 요구). 서버 설정의 return URL만 쓴다
  it("web 교환(/auth/token)에 서버 설정의 redirect_uri를 넣고, 폐기(/auth/revoke)에는 넣지 않는다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { refresh_token: "rt", id_token: WEB_ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW, client: "web" })).toBe("revoked");
    expect(calls[0].form.redirect_uri).toBe(WEB_RETURN_URL);
    expect(calls[1].form.redirect_uri).toBeUndefined();
  });

  it("app 교환은 redirect_uri를 넣지 않는다 (앱 안 로그인의 code는 그대로)", async () => {
    const { fetch, calls } = fakeFetch([{ body: { refresh_token: "rt", id_token: ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn(config, "auth-code", SUB, { fetch, now: NOW })).toBe("revoked");
    expect("redirect_uri" in calls[0].form).toBe(false);
  });

  it("web인데 return URL 설정이 없으면 not_configured: Apple을 부르지 않는다", async () => {
    const { fetch, calls } = fakeFetch([{ body: {} }]);
    expect(await revokeAppleSignIn({ ...config, webReturnUrl: undefined }, "auth-code", SUB, { fetch, client: "web" })).toBe("not_configured");
    expect(await revokeAppleSignIn({ ...config, webReturnUrl: "" }, "auth-code", SUB, { fetch, client: "web" })).toBe("not_configured");
    expect(calls).toEqual([]);
  });

  it("return URL이 등록한 중계 주소 모양이 아니면(https · /api/v1/apple/return · 도메인) 거절한다", async () => {
    for (const bad of [
      "http://api.taskforcelabs.dev/api/v1/apple/return",
      "https://api.taskforcelabs.dev/api/v1/apple/other",
      "https://api.taskforcelabs.dev/api/v1/apple/return/",
      "https://api.taskforcelabs.dev/api/v1/apple/return?x=1",
      "https://api.taskforcelabs.dev/api/v1/apple/return#f",
      "https://user:pw@api.taskforcelabs.dev/api/v1/apple/return",
      "https://127.0.0.1/api/v1/apple/return",
      "https://localhost/api/v1/apple/return",
      "taskforce://auth/apple",
      "not a url",
    ]) {
      const { fetch, calls } = fakeFetch([{ body: {} }]);
      expect(await revokeAppleSignIn({ ...config, webReturnUrl: bad }, "auth-code", SUB, { fetch, client: "web" }), bad).toBe("not_configured");
      expect(calls, bad).toEqual([]);
    }
  });

  it("Services ID가 없어도 app 폐기는 그대로 된다", async () => {
    const { fetch } = fakeFetch([{ body: { refresh_token: "rt", id_token: ID_TOKEN } }, { body: undefined }]);
    expect(await revokeAppleSignIn({ ...config, servicesId: undefined }, "auth-code", SUB, { fetch, now: NOW })).toBe("revoked");
  });
});

describe("appleIdTokenClaims", () => {
  it("sub · aud를 읽고, 형식이 다르면 null", () => {
    expect(appleIdTokenClaims(ID_TOKEN)).toEqual({ sub: SUB, aud: "dev.taskforcelabs.taskforce" });
    expect(appleIdTokenClaims(undefined)).toBeNull();
    expect(appleIdTokenClaims("a.%%%.c")).toBeNull();
    expect(appleIdTokenClaims(idToken({ aud: "x" }))).toBeNull();
  });
});

describe("appleSignInConfigFromEnv", () => {
  it("값이 모두 있어야 켜지고, client id 기본값은 번들 id", () => {
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString().replace(/\n/g, "\\n");
    const parsed = appleSignInConfigFromEnv({ APPLE_TEAM_ID: "T", APPLE_KEY_ID: "K", APPLE_PRIVATE_KEY: pem });
    expect(parsed).toMatchObject({ teamId: "T", keyId: "K", clientId: "dev.taskforcelabs.taskforce" });
    expect(appleSignInConfigFromEnv({ APPLE_TEAM_ID: "T", APPLE_KEY_ID: "K" })).toBeNull();
  });

  it("APPLE_WEB_RETURN_URL도 선택: 있으면 읽고, 비우면 없음", () => {
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString().replace(/\n/g, "\\n");
    const base = { APPLE_TEAM_ID: "T", APPLE_KEY_ID: "K", APPLE_PRIVATE_KEY: pem };
    expect(appleSignInConfigFromEnv({ ...base, APPLE_WEB_RETURN_URL: WEB_RETURN_URL })?.webReturnUrl).toBe(WEB_RETURN_URL);
    expect(appleSignInConfigFromEnv({ ...base, APPLE_WEB_RETURN_URL: "" })?.webReturnUrl).toBeUndefined();
    expect(appleSignInConfigFromEnv(base)?.webReturnUrl).toBeUndefined();
  });

  it("APPLE_SERVICES_ID는 선택: 있으면 읽고, 비우면 없음", () => {
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString().replace(/\n/g, "\\n");
    const base = { APPLE_TEAM_ID: "T", APPLE_KEY_ID: "K", APPLE_PRIVATE_KEY: pem };
    expect(appleSignInConfigFromEnv({ ...base, APPLE_SERVICES_ID: SERVICES_ID })?.servicesId).toBe(SERVICES_ID);
    expect(appleSignInConfigFromEnv({ ...base, APPLE_SERVICES_ID: "" })?.servicesId).toBeUndefined();
    expect(appleSignInConfigFromEnv(base)?.servicesId).toBeUndefined();
  });
});
