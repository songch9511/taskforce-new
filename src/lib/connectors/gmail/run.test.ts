import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";
import { notifyReconnect } from "@/lib/notify/service";

import {
  claimConnection,
  connectedAt,
  disconnectConnection,
  ingestDeps,
  loadIdentity,
  loadToken,
  otherConnections,
  recordSync,
  saveConnection,
  saveToken,
  updateConnectionSettings,
} from "../store";
import type { Connection } from "../types";

import { gmailConnector, syncGmailConnection } from "./run";
import { DEFAULT_GMAIL_SYNC, syncGmail, type GmailSyncResult } from "./sync";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/notify/service", () => ({ notifyReconnect: vi.fn() }));
vi.mock("../store", () => ({
  claimConnection: vi.fn(),
  connectedAt: vi.fn(),
  disconnectConnection: vi.fn(),
  ingestDeps: vi.fn(),
  loadIdentity: vi.fn(),
  loadToken: vi.fn(),
  otherConnections: vi.fn(),
  recordSync: vi.fn(),
  saveConnection: vi.fn(),
  saveToken: vi.fn(),
  updateConnectionSettings: vi.fn(),
}));
vi.mock("./sync", async (importOriginal) => ({ ...(await importOriginal<typeof import("./sync")>()), syncGmail: vi.fn() }));

// Gmail 연결 · 동기화 · 토큰 폐기 (docs/go-live/google-integration.md 2-3 · 2-6 · 2-8).
// 토큰 창구(POST /token · /revoke)와 Gmail API는 fetch로 흉내 내고, 동기화 본체(syncGmail)는 Gmail을 한 번 부른 뒤 준비한 결과를 돌려준다.

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const GMAIL_READONLY = "https://www.googleapis.com/auth/gmail.readonly";
const USERINFO_EMAIL = "https://www.googleapis.com/auth/userinfo.email";
const REDIRECT_URI = "https://api.example.dev/api/connectors/gmail/callback";

const admin = {} as SupabaseClient;
const settings = { googleUserId: "google-sub-1", email: "me@company.dev", scopes: ["openid", USERINFO_EMAIL, GMAIL_READONLY] };
const connection: Connection = { id: "c1", userId: "u1", provider: "gmail", settings, syncCursor: null };
const NOW = new Date("2026-09-29T12:00:00.000Z");
const CONNECTED_AT = new Date("2026-09-28T00:00:00.000Z");
const INGEST_DEPS = { ingestedIds: vi.fn(), insertSource: vi.fn(), process: vi.fn() };

const synced: GmailSyncResult = {
  created: ["src-1"],
  scanned: 3,
  skipped: { alreadyIngested: 0, category: 2 },
  cursor: { after: "2026-09-29T12:00:00.000Z", seen: { m1: 1 } },
  decisions: { inbound: 1, category: 2 },
  rateLimited: false,
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
const idToken = (claims: unknown) => ["e30", Buffer.from(JSON.stringify(claims)).toString("base64url"), "fake-signature"].join(".");
const stored = (extra: object = {}) => ({ access_token: "old-access", refresh_token: "fake-refresh", expires_at: Date.now() + 10 * 60_000, scope: GMAIL_READONLY, ...extra });

/** 토큰 창구 · 폐기 · Gmail API를 흉내 내는 fetch. Gmail은 valid 토큰에만 200 */
function stubGoogle(handlers: { token?: () => Response; revoke?: () => Response; gmail?: (auth: string) => Response } = {}) {
  const calls: { url: string; body: Record<string, string>; auth?: string }[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init: RequestInit = {}) => {
      const auth = (init.headers as Record<string, string> | undefined)?.Authorization;
      calls.push({ url, body: Object.fromEntries(new URLSearchParams(init.body ? String(init.body) : "")), auth });
      if (url === TOKEN_URL) return handlers.token?.() ?? json({ error: "server_error" }, 500);
      if (url === REVOKE_URL) return handlers.revoke?.() ?? new Response("", { status: 200 });
      return handlers.gmail?.(auth ?? "") ?? json({ messages: [] });
    }),
  );
  return {
    calls,
    revoked: () => calls.filter((c) => c.url === REVOKE_URL).map((c) => c.body.token),
    tokenRequests: () => calls.filter((c) => c.url === TOKEN_URL).map((c) => c.body),
  };
}

const grant = (extra: object = {}) =>
  json({
    access_token: "fake-access",
    expires_in: 3599,
    refresh_token: "fake-refresh",
    scope: `openid ${USERINFO_EMAIL} ${GMAIL_READONLY}`,
    token_type: "Bearer",
    id_token: idToken({ sub: "google-sub-1", email: "Me@Company.dev", email_verified: true }),
    ...extra,
  });

beforeEach(() => {
  vi.resetAllMocks();
  vi.stubEnv("GMAIL_CLIENT_ID", "fake-gmail-client-id");
  vi.stubEnv("GMAIL_CLIENT_SECRET", "fake-gmail-client-secret");
  vi.stubEnv("GMAIL_REDIRECT_URI", REDIRECT_URI);
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.mocked(claimConnection).mockResolvedValue(true);
  vi.mocked(connectedAt).mockResolvedValue(CONNECTED_AT);
  vi.mocked(disconnectConnection).mockResolvedValue(true);
  vi.mocked(ingestDeps).mockReturnValue(INGEST_DEPS);
  vi.mocked(loadIdentity).mockResolvedValue({ name: "Me", aliases: [], emails: ["login@example.com", "me@company.dev"] });
  vi.mocked(loadToken).mockResolvedValue(stored());
  vi.mocked(otherConnections).mockResolvedValue([]);
  vi.mocked(recordSync).mockResolvedValue(false);
  vi.mocked(notifyReconnect).mockResolvedValue(1);
  vi.mocked(saveConnection).mockResolvedValue("conn-new");
  vi.mocked(saveToken).mockResolvedValue();
  vi.mocked(updateConnectionSettings).mockResolvedValue();
  // 동기화 본체는 Gmail 목록을 한 번 부른다 (토큰 읽기 · 갱신이 이때 일어난다)
  vi.mocked(syncGmail).mockImplementation(async (_connection, client) => {
    await client.listMessages("after:1 before:2");
    return synced;
  });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("gmailConnector.authorizeUrl", () => {
  it("offline · consent · include_granted_scopes=false, 범위는 openid email gmail.readonly", () => {
    const url = new URL(gmailConnector.authorizeUrl("state-1"));
    expect(url.origin + url.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(url.searchParams.get("client_id")).toBe("fake-gmail-client-id");
    expect(url.searchParams.get("redirect_uri")).toBe(REDIRECT_URI);
    expect(url.searchParams.get("scope")).toBe(`openid email ${GMAIL_READONLY}`);
    expect(url.searchParams.get("access_type")).toBe("offline");
    expect(url.searchParams.get("prompt")).toBe("consent");
    expect(url.searchParams.get("include_granted_scopes")).toBe("false");
    expect(url.searchParams.get("state")).toBe("state-1");
  });

  it("설정이 빠지면 던진다", () => {
    vi.stubEnv("GMAIL_CLIENT_SECRET", "");
    expect(() => gmailConnector.authorizeUrl("s")).toThrow(/GMAIL_CLIENT_SECRET/);
  });
});

describe("gmailConnector.connect", () => {
  it("code를 바꿔 sub를 연결 키, 주소를 표시 이름으로 저장한다. 토큰에 id_token은 넣지 않는다", async () => {
    const google = stubGoogle({ token: () => grant() });

    expect(await gmailConnector.connect(admin, "u1", "code-1")).toBe("connected");

    expect(google.tokenRequests()).toEqual([
      expect.objectContaining({ grant_type: "authorization_code", code: "code-1", redirect_uri: REDIRECT_URI, client_id: "fake-gmail-client-id" }),
    ]);
    expect(saveConnection).toHaveBeenCalledWith(admin, {
      userId: "u1",
      provider: "gmail",
      externalAccountId: "google-sub-1",
      displayName: "me@company.dev",
      token: { access_token: "fake-access", refresh_token: "fake-refresh", expires_at: expect.any(Number), scope: `openid ${USERINFO_EMAIL} ${GMAIL_READONLY}` },
    });
    const { token } = vi.mocked(saveConnection).mock.calls[0][1] as { token: object };
    expect(Object.keys(token).sort()).toEqual(["access_token", "expires_at", "refresh_token", "scope"]);
    expect(google.revoked()).toEqual([]);
  });

  it("저장한 뒤 설정에 계정 · 범위를 남긴다 (통계 등 나머지 값은 그대로)", async () => {
    stubGoogle({ token: () => grant() });
    await gmailConnector.connect(admin, "u1", "code-1");

    expect(updateConnectionSettings).toHaveBeenCalledWith(admin, { id: "conn-new", userId: "u1" }, expect.any(Function));
    const update = vi.mocked(updateConnectionSettings).mock.calls[0][2];
    const stats = { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 4 } };
    expect(update({ stats })).toEqual({ stats, googleUserId: "google-sub-1", email: "me@company.dev", scopes: ["openid", USERINFO_EMAIL, GMAIL_READONLY] });
    expect(vi.mocked(saveConnection).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(updateConnectionSettings).mock.invocationCallOrder[0]);
  });

  it("Gmail 범위를 빼고 허용했으면 연결하지 않고 받은 토큰(갱신 토큰)을 폐기한다: missing_scope", async () => {
    const google = stubGoogle({ token: () => grant({ scope: `openid ${USERINFO_EMAIL}` }) });

    expect(await gmailConnector.connect(admin, "u1", "code-1")).toBe("missing_scope");
    expect(google.revoked()).toEqual(["fake-refresh"]);
    expect(saveConnection).not.toHaveBeenCalled();
    expect(updateConnectionSettings).not.toHaveBeenCalled();
  });

  it("id_token이 없으면(openid 빠짐, 연결 키 없음) missing_scope. 갱신 토큰이 없으면 액세스 토큰을 폐기한다", async () => {
    const google = stubGoogle({ token: () => grant({ id_token: undefined, refresh_token: undefined }) });

    expect(await gmailConnector.connect(admin, "u1", "code-1")).toBe("missing_scope");
    expect(google.revoked()).toEqual(["fake-access"]);
    expect(saveConnection).not.toHaveBeenCalled();
  });

  it("범위 부족으로 폐기하다 실패해도 missing_scope를 돌려준다", async () => {
    stubGoogle({ token: () => grant({ scope: "openid" }), revoke: () => new Response("", { status: 503 }) });
    expect(await gmailConnector.connect(admin, "u1", "code-1")).toBe("missing_scope");
  });

  it("다른 Google 계정으로 연결하면 같은 서비스의 옛 연결은 토큰을 폐기하고 끊는다", async () => {
    const google = stubGoogle({ token: () => grant() });
    vi.mocked(otherConnections).mockResolvedValue([{ id: "conn-old", token: stored({ access_token: "old-access", refresh_token: "old-refresh" }) }]);

    expect(await gmailConnector.connect(admin, "u1", "code-1")).toBe("connected");
    expect(otherConnections).toHaveBeenCalledWith(admin, "u1", "gmail", "conn-new");
    expect(google.revoked()).toEqual(["old-refresh"]);
    expect(disconnectConnection).toHaveBeenCalledWith(admin, "u1", "conn-old");
    expect(vi.mocked(saveConnection).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(disconnectConnection).mock.invocationCallOrder[0]);
  });

  it("옛 연결의 폐기 · 끊기가 실패해도 새 연결은 그대로 connected. 로그에 토큰을 남기지 않는다", async () => {
    stubGoogle({ token: () => grant(), revoke: () => new Response("", { status: 500 }) });
    vi.mocked(otherConnections).mockResolvedValue([
      { id: "conn-old", token: stored({ refresh_token: "old-refresh" }) },
      { id: "conn-undecryptable", token: null },
    ]);
    vi.mocked(disconnectConnection).mockRejectedValue(new Error("rpc failed"));

    expect(await gmailConnector.connect(admin, "u1", "code-1")).toBe("connected");
    // 풀지 못한 토큰은 폐기하지 않고 끊기만 시도한다
    expect(disconnectConnection).toHaveBeenCalledTimes(2);
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toMatch(/old-refresh|fake-refresh|fake-access/);
  });

  it("code 교환이 실패하면 던진다 (연결 틀이 error로 돌려보낸다)", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
    await expect(gmailConnector.connect(admin, "u1", "used-code")).rejects.toMatchObject({ name: "GoogleOAuthError", code: "invalid_grant" });
    expect(saveConnection).not.toHaveBeenCalled();
  });
});

describe("syncGmailConnection", () => {
  it("동기화하고 커서를 남긴다. 거르기에 사용자 주소 · 회사 도메인, 넣기에 연결 시각(알림 기준)을 넘긴다", async () => {
    stubGoogle();
    const outcome = await syncGmailConnection(admin, connection, { now: NOW, deadline: 123 });

    expect(outcome).toEqual({ connectionId: "c1", ok: true, result: synced });
    expect(ingestDeps).toHaveBeenCalledWith(admin, { notifyFrom: CONNECTED_AT });
    expect(syncGmail).toHaveBeenCalledWith(
      connection,
      expect.anything(),
      INGEST_DEPS,
      { filter: { userEmails: ["login@example.com", "me@company.dev"], companyDomain: "company.dev" }, accountEmail: "me@company.dev" },
      { now: NOW, deadline: 123, ...DEFAULT_GMAIL_SYNC },
    );
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: null });
  });

  it("이유별 개수와 넣은 수를 통계에 더한다", async () => {
    stubGoogle();
    await syncGmailConnection(admin, connection, { now: NOW });

    expect(updateConnectionSettings).toHaveBeenCalledWith(admin, connection, expect.any(Function));
    const update = vi.mocked(updateConnectionSettings).mock.calls[0][2];
    expect(update({ email: "me@company.dev" })).toEqual({
      email: "me@company.dev",
      stats: { since: NOW.toISOString(), counts: { inbound: 1, category: 2, ingested: 1 } },
    });
  });

  it("통계를 쓰지 못해도 동기화는 성공으로 남긴다", async () => {
    stubGoogle();
    vi.mocked(updateConnectionSettings).mockRejectedValue(new Error("db down"));
    const outcome = await syncGmailConnection(admin, connection, { now: NOW });
    expect(outcome.ok).toBe(true);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: null });
  });

  it("공용 메일로 연결했으면 회사 도메인 없이, 설정을 읽을 수 없으면 주소 없이 거른다", async () => {
    stubGoogle();
    await syncGmailConnection(admin, { ...connection, settings: { ...settings, email: "me@gmail.com" } }, { now: NOW });
    expect(vi.mocked(syncGmail).mock.calls[0][3]).toMatchObject({ filter: { companyDomain: null }, accountEmail: "me@gmail.com" });

    await syncGmailConnection(admin, { ...connection, settings: {} }, { now: NOW });
    expect(vi.mocked(syncGmail).mock.calls[1][3]).toMatchObject({ filter: { companyDomain: null }, accountEmail: null });
  });

  it("속도 제한(429)으로 멈췄으면 커서를 옮기고 한도 안내를 error로 남긴다", async () => {
    stubGoogle();
    vi.mocked(syncGmail).mockResolvedValue({ ...synced, rateLimited: true });
    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(outcome.ok).toBe(true);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: expect.stringMatching(/한도/) });
  });

  it("이미 동기화 중이면(claim 실패) 부르지 않고 busy", async () => {
    vi.mocked(claimConnection).mockResolvedValue(false);
    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(outcome).toEqual({ connectionId: "c1", ok: false, error: "이미 동기화 중입니다.", revoked: false, busy: true });
    expect(syncGmail).not.toHaveBeenCalled();
    expect(recordSync).not.toHaveBeenCalled();
  });

  it("만료된 토큰의 갱신이 400 invalid_grant면 다시 연결 필요(reauth)로 남긴다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant", error_description: "Token has been expired or revoked." }, 400) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));

    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: expect.any(Date), error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(outcome).toEqual({ connectionId: "c1", ok: false, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", revoked: false });
    expect(saveToken).not.toHaveBeenCalled();
  });

  it("reauth로 바꾼 동기화(recordSync가 true)에서만 재연결 알림 한 번", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    vi.mocked(recordSync).mockResolvedValue(true);

    await syncGmailConnection(admin, connection, { now: NOW });

    expect(notifyReconnect).toHaveBeenCalledTimes(1);
    expect(notifyReconnect).toHaveBeenCalledWith(admin, "u1", "gmail");
  });

  it("이미 reauth였거나 그 사이 다시 연결해 recordSync가 false면 알림을 보내지 않는다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    vi.mocked(recordSync).mockResolvedValue(false);

    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(outcome.ok).toBe(false);
    expect(notifyReconnect).not.toHaveBeenCalled();
  });

  it("알림이 실패해도 동기화 결과는 그대로 reauth다 (오류 로그만)", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    vi.mocked(recordSync).mockResolvedValue(true);
    vi.mocked(notifyReconnect).mockRejectedValue(new Error("APNs down"));

    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(outcome).toEqual({ connectionId: "c1", ok: false, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", revoked: false });
    expect(console.error).toHaveBeenCalledWith("Gmail 재연결 알림 실패 (c1):", "APNs down");
  });

  it("reauth가 아닌 실패(설정 문제 · API 오류)와 성공한 동기화는 알림을 보내지 않는다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_client" }, 401) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    await syncGmailConnection(admin, connection, { now: NOW });

    vi.mocked(loadToken).mockResolvedValue(stored());
    stubGoogle();
    await syncGmailConnection(admin, connection, { now: NOW });

    expect(notifyReconnect).not.toHaveBeenCalled();
  });

  it("갱신 토큰 없이 만료됐어도 reauth", async () => {
    const google = stubGoogle();
    vi.mocked(loadToken).mockResolvedValue(stored({ refresh_token: null, expires_at: Date.now() - 1_000 }));

    await syncGmailConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, expect.objectContaining({ reauth: true }));
    expect(google.tokenRequests()).toEqual([]);
  });

  it("토큰 창구가 401 invalid_client면(우리 쪽 설정) error로만 남긴다: reauth · revoked가 아니다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_client", error_description: "The OAuth client was not found." }, 401) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));

    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "Google 토큰 요청 실패 (invalid_client)" });
    expect(outcome).toEqual({ connectionId: "c1", ok: false, error: "Google 토큰 요청 실패 (invalid_client)", revoked: false });
  });

  it("API가 401이면 한 번 갱신해 저장하고 이어 간다", async () => {
    const google = stubGoogle({
      token: () => json({ access_token: "new-access", expires_in: 3599 }),
      gmail: (auth) => (auth === "Bearer new-access" ? json({ messages: [] }) : json({}, 401)),
    });

    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(outcome.ok).toBe(true);
    expect(saveToken).toHaveBeenCalledWith(admin, "c1", expect.objectContaining({ access_token: "new-access", refresh_token: "fake-refresh" }));
    expect(google.calls.filter((c) => c.url.startsWith("https://gmail.googleapis.com")).map((c) => c.auth)).toEqual(["Bearer old-access", "Bearer new-access"]);
  });

  it("Gmail API 오류(403 범위 부족)는 그 연결만 error", async () => {
    stubGoogle({ gmail: () => json({ error: { errors: [{ reason: "insufficientPermissions" }] } }, 403) });
    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "Gmail 요청 실패 (403)" });
    expect(outcome).toMatchObject({ ok: false, revoked: false });
  });

  it("동기화 도중 외부 AI 처리 동의를 철회했으면 잠금만 풀고(커서 · 오류 없이) 동의 문구를 돌려준다", async () => {
    stubGoogle();
    vi.mocked(syncGmail).mockRejectedValue(new ConsentRequiredError());

    const outcome = await syncGmailConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW });
    expect(outcome).toEqual({ connectionId: "c1", ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false });
  });

  it("그 밖의 오류는 일반 문구로 남긴다", async () => {
    stubGoogle();
    vi.mocked(syncGmail).mockRejectedValue(new Error("sources insert failed: raw text here"));
    const outcome = await syncGmailConnection(admin, connection, { now: NOW });
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "동기화 중 오류가 발생했습니다." });
    expect(outcome).toMatchObject({ ok: false, error: "동기화 중 오류가 발생했습니다." });
  });
});

describe("gmailConnector.revokeToken", () => {
  it("갱신 토큰이 있으면 그것을 폐기한다 (허용 전체가 거둬진다)", async () => {
    const google = stubGoogle();
    await gmailConnector.revokeToken!(stored({ access_token: "a-token", refresh_token: "r-token" }));
    expect(google.revoked()).toEqual(["r-token"]);
  });

  it("갱신 토큰이 없으면 액세스 토큰을 폐기한다", async () => {
    const google = stubGoogle();
    await gmailConnector.revokeToken!(stored({ access_token: "a-token", refresh_token: null }));
    expect(google.revoked()).toEqual(["a-token"]);
  });

  it("이미 폐기된 토큰(400 invalid_token)은 성공으로 본다", async () => {
    stubGoogle({ revoke: () => json({ error: "invalid_token", error_description: "Token expired or revoked" }, 400) });
    await expect(gmailConnector.revokeToken!(stored())).resolves.toBeUndefined();
  });

  it("서버 오류(500)면 던진다 (끊기는 부르는 쪽이 계속한다)", async () => {
    stubGoogle({ revoke: () => new Response("", { status: 500 }) });
    await expect(gmailConnector.revokeToken!(stored())).rejects.toMatchObject({ name: "GoogleOAuthError", status: 500 });
  });

  it("토큰 모양이 다르면 부르지 않는다", async () => {
    const google = stubGoogle();
    await gmailConnector.revokeToken!({ xoxp: "not-google" });
    expect(google.calls).toEqual([]);
  });
});
