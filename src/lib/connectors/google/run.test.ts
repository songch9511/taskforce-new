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

import { googleConnector, GOOGLE_SCOPES, grantedFeatures, syncGoogleConnection } from "./run";
import { DEFAULT_GOOGLE_SYNC, syncGoogleMeet, type GoogleSyncResult } from "./sync";
import { GoogleApiError } from "./token";

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
vi.mock("./sync", async (importOriginal) => ({ ...(await importOriginal<typeof import("./sync")>()), syncGoogleMeet: vi.fn() }));

// google 연결 · 동기화 · 토큰 폐기 (docs/go-live/google-integration.md 2-3 · 2-5 · 2-8, G10 부분 허용).
// 토큰 창구(POST /token · /revoke)와 Calendar API는 fetch로 흉내 내고, 동기화 본체(syncGoogleMeet)는 준비한 결과를 돌려준다.

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const CALENDAR_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events";
const CALENDAR = "https://www.googleapis.com/auth/calendar.events.owned.readonly";
const MEET = "https://www.googleapis.com/auth/meetings.space.readonly";
const USERINFO_EMAIL = "https://www.googleapis.com/auth/userinfo.email";
const REDIRECT_URI = "https://api.example.dev/api/connectors/google/callback";
const ALL_SCOPES = ["openid", USERINFO_EMAIL, CALENDAR, MEET];

const admin = {} as SupabaseClient;
const settings = { googleUserId: "google-sub-1", email: "me@company.dev", scopes: ALL_SCOPES };
const connection: Connection = { id: "g1", userId: "u1", provider: "google", settings, syncCursor: null };
const NOW = new Date("2026-10-05T12:00:00.000Z");
const CONNECTED_AT = new Date("2026-10-01T00:00:00.000Z");
const INGEST_DEPS = { ingestedIds: vi.fn(), insertSource: vi.fn(), process: vi.fn() };

const synced: GoogleSyncResult = {
  created: ["src-1"],
  scanned: 2,
  skipped: { alreadyIngested: 0 },
  cursor: { after: "2026-10-05T11:30:00.000Z", seen: {}, fails: {} },
  counts: { meet_transcripts: 1, meet_link_attached: 1 },
  rateLimited: false,
};

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
const idToken = (claims: unknown) => ["e30", Buffer.from(JSON.stringify(claims)).toString("base64url"), "fake-signature"].join(".");
const stored = (extra: object = {}) => ({ access_token: "old-access", refresh_token: "fake-refresh", expires_at: Date.now() + 10 * 60_000, scope: `${CALENDAR} ${MEET}`, ...extra });

/** 토큰 창구 · 폐기 · Calendar API를 흉내 내는 fetch */
function stubGoogle(handlers: { token?: () => Response; revoke?: () => Response; calendar?: (auth: string) => Response } = {}) {
  const calls: { url: string; body: Record<string, string>; auth?: string }[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init: RequestInit = {}) => {
      const auth = (init.headers as Record<string, string> | undefined)?.Authorization;
      calls.push({ url, body: Object.fromEntries(new URLSearchParams(init.body ? String(init.body) : "")), auth });
      if (url === TOKEN_URL) return handlers.token?.() ?? json({ error: "server_error" }, 500);
      if (url === REVOKE_URL) return handlers.revoke?.() ?? new Response("", { status: 200 });
      return handlers.calendar?.(auth ?? "") ?? json({ items: [] });
    }),
  );
  return {
    calls,
    revoked: () => calls.filter((c) => c.url === REVOKE_URL).map((c) => c.body.token),
    tokenRequests: () => calls.filter((c) => c.url === TOKEN_URL).map((c) => c.body),
    calendarCalls: () => calls.filter((c) => c.url.startsWith(CALENDAR_URL)),
  };
}

const grant = (extra: object = {}) =>
  json({
    access_token: "fake-access",
    expires_in: 3599,
    refresh_token: "fake-refresh",
    scope: ALL_SCOPES.join(" "),
    token_type: "Bearer",
    id_token: idToken({ sub: "google-sub-1", email: "Me@Company.dev", email_verified: true }),
    ...extra,
  });

beforeEach(() => {
  vi.resetAllMocks();
  vi.stubEnv("GOOGLE_CLIENT_ID", "fake-google-client-id");
  vi.stubEnv("GOOGLE_CLIENT_SECRET", "fake-google-client-secret");
  vi.stubEnv("GOOGLE_REDIRECT_URI", REDIRECT_URI);
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.mocked(claimConnection).mockResolvedValue(true);
  vi.mocked(connectedAt).mockResolvedValue(CONNECTED_AT);
  vi.mocked(disconnectConnection).mockResolvedValue(true);
  vi.mocked(ingestDeps).mockReturnValue(INGEST_DEPS);
  vi.mocked(loadIdentity).mockResolvedValue({ name: "송창훈", aliases: ["Daniel Song"], emails: ["login@example.com", "me@company.dev"] });
  vi.mocked(loadToken).mockResolvedValue(stored());
  vi.mocked(otherConnections).mockResolvedValue([]);
  // recordSync는 이 호출이 연결을 reauth로 바꿨는지 돌려준다 (PR 4a). 기본은 바꾸지 않음
  vi.mocked(recordSync).mockResolvedValue(false);
  vi.mocked(notifyReconnect).mockResolvedValue(1);
  vi.mocked(saveConnection).mockResolvedValue("conn-new");
  vi.mocked(saveToken).mockResolvedValue();
  vi.mocked(updateConnectionSettings).mockResolvedValue();
  vi.mocked(syncGoogleMeet).mockResolvedValue(synced);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("googleConnector.authorizeUrl", () => {
  it("offline · consent · include_granted_scopes=false, 범위는 openid email Calendar Meet", () => {
    const url = new URL(googleConnector.authorizeUrl("state-1"));
    expect(url.origin + url.pathname).toBe("https://accounts.google.com/o/oauth2/v2/auth");
    expect(url.searchParams.get("client_id")).toBe("fake-google-client-id");
    expect(url.searchParams.get("redirect_uri")).toBe(REDIRECT_URI);
    expect(url.searchParams.get("scope")).toBe(`openid email ${CALENDAR} ${MEET}`);
    expect(url.searchParams.get("access_type")).toBe("offline");
    expect(url.searchParams.get("prompt")).toBe("consent");
    expect(url.searchParams.get("include_granted_scopes")).toBe("false");
    expect(url.searchParams.get("state")).toBe("state-1");
  });

  it("범위는 google-verification.md 1장 A와 같다: profile 범위를 더하지 않는다 (G5 대안은 dev 확인 뒤)", () => {
    expect([...GOOGLE_SCOPES]).toEqual(["openid", "email", CALENDAR, MEET]);
  });

  it("설정이 빠지면 던진다", () => {
    vi.stubEnv("GOOGLE_CLIENT_SECRET", "");
    expect(() => googleConnector.authorizeUrl("s")).toThrow(/GOOGLE_CLIENT_SECRET/);
  });
});

describe("grantedFeatures (G10)", () => {
  it("허용한 범위로 Calendar · Meet을 가른다", () => {
    expect(grantedFeatures(ALL_SCOPES)).toEqual({ calendar: true, meet: true });
    expect(grantedFeatures(["openid", CALENDAR])).toEqual({ calendar: true, meet: false });
    expect(grantedFeatures(["openid", MEET])).toEqual({ calendar: false, meet: true });
    expect(grantedFeatures(["openid", USERINFO_EMAIL])).toEqual({ calendar: false, meet: false });
    expect(grantedFeatures([])).toEqual({ calendar: false, meet: false });
  });
});

describe("googleConnector.connect", () => {
  it("모두 허용하면 connected. code를 바꿔 sub를 연결 키, 주소를 표시 이름으로 저장하고 id_token은 저장하지 않는다", async () => {
    const google = stubGoogle({ token: () => grant() });

    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("connected");

    expect(google.tokenRequests()).toEqual([
      expect.objectContaining({ grant_type: "authorization_code", code: "code-1", redirect_uri: REDIRECT_URI, client_id: "fake-google-client-id" }),
    ]);
    expect(saveConnection).toHaveBeenCalledWith(admin, {
      userId: "u1",
      provider: "google",
      externalAccountId: "google-sub-1",
      displayName: "me@company.dev",
      token: { access_token: "fake-access", refresh_token: "fake-refresh", expires_at: expect.any(Number), scope: ALL_SCOPES.join(" ") },
    });
    const { token } = vi.mocked(saveConnection).mock.calls[0][1] as { token: object };
    expect(Object.keys(token).sort()).toEqual(["access_token", "expires_at", "refresh_token", "scope"]);
    expect(google.revoked()).toEqual([]);
  });

  it("저장한 뒤 설정에 계정 · 받은 범위를 남긴다 (통계 등 나머지 값은 그대로)", async () => {
    stubGoogle({ token: () => grant() });
    await googleConnector.connect(admin, "u1", "code-1");

    expect(updateConnectionSettings).toHaveBeenCalledWith(admin, { id: "conn-new", userId: "u1" }, expect.any(Function));
    const update = vi.mocked(updateConnectionSettings).mock.calls[0][2];
    const stats = { since: "2026-09-01T00:00:00.000Z", counts: { meet_transcripts: 4 } };
    expect(update({ stats })).toEqual({ stats, googleUserId: "google-sub-1", email: "me@company.dev", scopes: ALL_SCOPES });
    expect(vi.mocked(saveConnection).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(updateConnectionSettings).mock.invocationCallOrder[0]);
  });

  it("Calendar만 허용했으면 connected_partial: 연결하고 받은 범위만 남긴다 (토큰은 폐기하지 않는다)", async () => {
    const google = stubGoogle({ token: () => grant({ scope: `openid ${USERINFO_EMAIL} ${CALENDAR}` }) });

    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("connected_partial");

    expect(saveConnection).toHaveBeenCalled();
    const update = vi.mocked(updateConnectionSettings).mock.calls[0][2];
    expect(update({})).toMatchObject({ scopes: ["openid", USERINFO_EMAIL, CALENDAR] });
    expect(google.revoked()).toEqual([]);
  });

  it("Meet만 허용했어도 connected_partial", async () => {
    stubGoogle({ token: () => grant({ scope: `openid ${USERINFO_EMAIL} ${MEET}` }) });
    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("connected_partial");
    expect(vi.mocked(updateConnectionSettings).mock.calls[0][2]({})).toMatchObject({ scopes: ["openid", USERINFO_EMAIL, MEET] });
  });

  it("둘 다 빼고 허용했으면 연결하지 않고 받은 토큰(갱신 토큰)을 폐기한다: missing_scope", async () => {
    const google = stubGoogle({ token: () => grant({ scope: `openid ${USERINFO_EMAIL}` }) });

    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("missing_scope");
    expect(google.revoked()).toEqual(["fake-refresh"]);
    expect(saveConnection).not.toHaveBeenCalled();
    expect(updateConnectionSettings).not.toHaveBeenCalled();
  });

  it("id_token이 없으면(openid 빠짐, 연결 키 없음) missing_scope. 갱신 토큰이 없으면 액세스 토큰을 폐기한다", async () => {
    const google = stubGoogle({ token: () => grant({ id_token: undefined, refresh_token: undefined }) });

    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("missing_scope");
    expect(google.revoked()).toEqual(["fake-access"]);
    expect(saveConnection).not.toHaveBeenCalled();
  });

  it("범위 부족으로 폐기하다 실패해도 missing_scope를 돌려준다", async () => {
    stubGoogle({ token: () => grant({ scope: "openid" }), revoke: () => new Response("", { status: 503 }) });
    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("missing_scope");
  });

  it("다시 연결하면 그때 허용한 범위로 바뀐다 (Calendar만이었다가 둘 다)", async () => {
    stubGoogle({ token: () => grant() });
    await googleConnector.connect(admin, "u1", "code-1");
    const update = vi.mocked(updateConnectionSettings).mock.calls[0][2];
    expect(update({ googleUserId: "google-sub-1", email: "me@company.dev", scopes: ["openid", CALENDAR] })).toMatchObject({ scopes: ALL_SCOPES });
  });

  it("다른 Google 계정으로 연결하면 같은 서비스(google)의 옛 연결은 토큰을 폐기하고 끊는다", async () => {
    const google = stubGoogle({ token: () => grant() });
    vi.mocked(otherConnections).mockResolvedValue([{ id: "conn-old", token: stored({ access_token: "old-access", refresh_token: "old-refresh" }) }]);

    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("connected");
    expect(otherConnections).toHaveBeenCalledWith(admin, "u1", "google", "conn-new");
    expect(google.revoked()).toEqual(["old-refresh"]);
    expect(disconnectConnection).toHaveBeenCalledWith(admin, "u1", "conn-old");
  });

  it("옛 연결의 폐기 · 끊기가 실패해도 새 연결은 그대로 connected. 로그에 토큰을 남기지 않는다", async () => {
    stubGoogle({ token: () => grant(), revoke: () => new Response("", { status: 500 }) });
    vi.mocked(otherConnections).mockResolvedValue([{ id: "conn-old", token: stored({ refresh_token: "old-refresh" }) }]);
    vi.mocked(disconnectConnection).mockRejectedValue(new Error("rpc failed"));

    expect(await googleConnector.connect(admin, "u1", "code-1")).toBe("connected");
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toMatch(/old-refresh|fake-refresh|fake-access/);
  });

  it("code 교환이 실패하면 던진다 (연결 틀이 error로 돌려보낸다)", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
    await expect(googleConnector.connect(admin, "u1", "used-code")).rejects.toMatchObject({ name: "GoogleOAuthError", code: "invalid_grant" });
    expect(saveConnection).not.toHaveBeenCalled();
  });
});

describe("syncGoogleConnection", () => {
  it("Meet 전사를 동기화하고 커서를 남긴다. 사용자는 프로필 이름 · 연결한 주소 · sub, 넣기에 연결 시각(알림 기준)을 넘긴다", async () => {
    stubGoogle();
    const outcome = await syncGoogleConnection(admin, connection, { now: NOW, deadline: 123 });

    expect(outcome).toEqual({ connectionId: "g1", ok: true, result: synced });
    expect(ingestDeps).toHaveBeenCalledWith(admin, { notifyFrom: CONNECTED_AT });
    expect(syncGoogleMeet).toHaveBeenCalledWith(
      connection,
      expect.objectContaining({ meet: true, calendar: expect.anything(), meetApi: expect.anything(), me: { name: "송창훈", aliases: ["Daniel Song"], email: "me@company.dev", sub: "google-sub-1" } }),
      INGEST_DEPS,
      { now: NOW, deadline: 123, ...DEFAULT_GOOGLE_SYNC },
    );
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: null });
  });

  it("전사 수 · 일정 잇기 결과를 통계에 더한다 (글자 · 주소 없이)", async () => {
    stubGoogle();
    await syncGoogleConnection(admin, connection, { now: NOW });

    expect(updateConnectionSettings).toHaveBeenCalledWith(admin, connection, expect.any(Function));
    const update = vi.mocked(updateConnectionSettings).mock.calls[0][2];
    expect(update({ email: "me@company.dev" })).toEqual({
      email: "me@company.dev",
      stats: { since: NOW.toISOString(), counts: { meet_transcripts: 1, meet_link_attached: 1 } },
    });
    expect(vi.mocked(recordSync).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(updateConnectionSettings).mock.invocationCallOrder[0]);
  });

  it("통계를 쓰지 못해도 동기화는 성공으로 남긴다", async () => {
    stubGoogle();
    vi.mocked(updateConnectionSettings).mockRejectedValue(new Error("db down"));
    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });
    expect(outcome.ok).toBe(true);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: null });
  });

  it("Meet만 허용한 연결(G10)은 Calendar 클라이언트 없이 동기화한다", async () => {
    stubGoogle();
    await syncGoogleConnection(admin, { ...connection, settings: { ...settings, scopes: ["openid", USERINFO_EMAIL, MEET] } }, { now: NOW });
    expect(vi.mocked(syncGoogleMeet).mock.calls[0][1]).toMatchObject({ meet: true, calendar: null });
  });

  it("Calendar만 허용한 연결(G10)은 전사를 가져오지 않고 토큰만 확인한다: 커서를 쓰지 않는다", async () => {
    const google = stubGoogle();
    const outcome = await syncGoogleConnection(admin, { ...connection, settings: { ...settings, scopes: ["openid", USERINFO_EMAIL, CALENDAR] } }, { now: NOW });

    expect(syncGoogleMeet).not.toHaveBeenCalled();
    expect(google.calendarCalls()).toHaveLength(1);
    expect(new URL(google.calendarCalls()[0].url).searchParams.get("maxResults")).toBe("1");
    expect(recordSync).toHaveBeenCalledWith(admin, expect.objectContaining({ id: "g1" }), { claimedAt: NOW });
    expect(outcome).toEqual({ connectionId: "g1", ok: true, result: { created: [], scanned: 0, skipped: {} } });
  });

  it("Calendar만 허용한 연결도 갱신 토큰이 만료됐으면 reauth로 알린다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    const outcome = await syncGoogleConnection(admin, { ...connection, settings: { ...settings, scopes: ["openid", CALENDAR] } }, { now: NOW });

    expect(syncGoogleMeet).not.toHaveBeenCalled();
    expect(outcome).toMatchObject({ ok: false, error: "Google 연결이 만료됐습니다. 다시 연결해 주세요." });
    expect(recordSync).toHaveBeenCalledWith(admin, expect.anything(), { claimedAt: NOW, error: "Google 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
  });

  it("설정을 읽을 수 없으면 아무 기능도 허용하지 않은 것으로 본다 (Google을 부르지 않는다). 조용히 성공하지 않게 로그를 남긴다 (설정 내용 없이)", async () => {
    const google = stubGoogle();
    const outcome = await syncGoogleConnection(admin, { ...connection, settings: { scopes: "secret-looking-value" } }, { now: NOW });
    expect(outcome.ok).toBe(true);
    expect(google.calls).toEqual([]);
    expect(syncGoogleMeet).not.toHaveBeenCalled();
    expect(console.error).toHaveBeenCalledWith(expect.stringContaining("설정을 읽지 못해"));
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("secret-looking-value");
  });

  it("속도 제한(429)으로 멈췄으면 커서를 옮기고 한도 안내를 error로 남긴다", async () => {
    stubGoogle();
    vi.mocked(syncGoogleMeet).mockResolvedValue({ ...synced, rateLimited: true });
    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });

    expect(outcome.ok).toBe(true);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: expect.stringMatching(/한도/) });
  });

  it("이미 동기화 중이면(claim 실패) 부르지 않고 busy", async () => {
    vi.mocked(claimConnection).mockResolvedValue(false);
    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });

    expect(outcome).toEqual({ connectionId: "g1", ok: false, error: "이미 동기화 중입니다.", revoked: false, busy: true });
    expect(syncGoogleMeet).not.toHaveBeenCalled();
    expect(recordSync).not.toHaveBeenCalled();
  });

  it("만료된 토큰의 갱신이 400 invalid_grant면 다시 연결 필요(reauth)로 남긴다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_grant", error_description: "Token has been expired or revoked." }, 400) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    vi.mocked(syncGoogleMeet).mockImplementation(async (_c, input) => {
      await input.meetApi.listTranscripts("conferenceRecords/x");
      return synced;
    });

    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "Google 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(outcome).toEqual({ connectionId: "g1", ok: false, error: "Google 연결이 만료됐습니다. 다시 연결해 주세요.", revoked: false });
    expect(saveToken).not.toHaveBeenCalled();
  });

  describe("재연결 알림 (G9, PR 4a와 같은 두 줄)", () => {
    /** 갱신 토큰이 거절되는 동기화 (Meet 요청에서 토큰을 읽는다) */
    function expiredSync(scopes: string[] = ALL_SCOPES) {
      stubGoogle({ token: () => json({ error: "invalid_grant" }, 400) });
      vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
      vi.mocked(syncGoogleMeet).mockImplementation(async (_c, input) => {
        await input.meetApi.listTranscripts("conferenceRecords/x");
        return synced;
      });
      return syncGoogleConnection(admin, { ...connection, settings: { ...settings, scopes } }, { now: NOW });
    }

    it("reauth로 바꾼 동기화(recordSync가 true)에서만 알림 한 번: 서비스는 google", async () => {
      vi.mocked(recordSync).mockResolvedValue(true);
      await expiredSync();
      expect(notifyReconnect).toHaveBeenCalledTimes(1);
      expect(notifyReconnect).toHaveBeenCalledWith(admin, "u1", "google");
    });

    it("Calendar만 허용한 연결의 reauth도 같다 (토큰 확인 요청에서 잡힌다)", async () => {
      vi.mocked(recordSync).mockResolvedValue(true);
      await expiredSync(["openid", CALENDAR]);
      expect(syncGoogleMeet).not.toHaveBeenCalled();
      expect(notifyReconnect).toHaveBeenCalledWith(admin, "u1", "google");
    });

    it("이미 reauth였거나 그 사이 다시 연결해 recordSync가 false면 알림을 보내지 않는다", async () => {
      vi.mocked(recordSync).mockResolvedValue(false);
      const outcome = await expiredSync();
      expect(outcome.ok).toBe(false);
      expect(notifyReconnect).not.toHaveBeenCalled();
    });

    it("알림이 실패해도 동기화 결과는 그대로 reauth다 (오류 로그만, 토큰 없이)", async () => {
      vi.mocked(recordSync).mockResolvedValue(true);
      vi.mocked(notifyReconnect).mockRejectedValue(new Error("APNs down"));
      const outcome = await expiredSync();
      expect(outcome).toEqual({ connectionId: "g1", ok: false, error: "Google 연결이 만료됐습니다. 다시 연결해 주세요.", revoked: false });
      expect(console.error).toHaveBeenCalledWith("Google 재연결 알림 실패 (g1):", "APNs down");
    });

    it("reauth가 아닌 실패(설정 문제 · API 오류)와 성공한 동기화는 recordSync가 true를 돌려주는 상황에서도 알림을 보내지 않는다", async () => {
      // true여도 알림이 안 가는 것은 reauth 분기에서만 부르기 때문이다 (기본 목(false)이면 이 검사는 아무것도 증명하지 못한다)
      vi.mocked(recordSync).mockResolvedValue(true);

      stubGoogle({ token: () => json({ error: "invalid_client" }, 401) });
      vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
      vi.mocked(syncGoogleMeet).mockImplementation(async (_c, input) => {
        await input.meetApi.listTranscripts("conferenceRecords/x");
        return synced;
      });
      await syncGoogleConnection(admin, connection, { now: NOW });
      expect(recordSync).toHaveBeenLastCalledWith(admin, connection, { claimedAt: NOW, error: "Google 토큰 요청 실패 (invalid_client)" });

      vi.mocked(syncGoogleMeet).mockRejectedValue(new GoogleApiError("Meet 요청 실패 (403)", 403, "PERMISSION_DENIED"));
      await syncGoogleConnection(admin, connection, { now: NOW });
      expect(recordSync).toHaveBeenLastCalledWith(admin, connection, { claimedAt: NOW, error: "Google 요청 실패 (403)" });

      vi.mocked(syncGoogleMeet).mockResolvedValue(synced);
      stubGoogle();
      vi.mocked(loadToken).mockResolvedValue(stored());
      await syncGoogleConnection(admin, connection, { now: NOW });
      expect(recordSync).toHaveBeenLastCalledWith(admin, connection, { claimedAt: NOW, cursor: synced.cursor, error: null });

      expect(recordSync).toHaveBeenCalledTimes(3);
      expect(notifyReconnect).not.toHaveBeenCalled();
    });
  });

  it("토큰 창구가 401 invalid_client면(우리 쪽 설정) error로만 남긴다: reauth · revoked가 아니다", async () => {
    stubGoogle({ token: () => json({ error: "invalid_client" }, 401) });
    vi.mocked(loadToken).mockResolvedValue(stored({ expires_at: Date.now() - 1_000 }));
    vi.mocked(syncGoogleMeet).mockImplementation(async (_c, input) => {
      await input.meetApi.listTranscripts("conferenceRecords/x");
      return synced;
    });

    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "Google 토큰 요청 실패 (invalid_client)" });
    expect(outcome).toEqual({ connectionId: "g1", ok: false, error: "Google 토큰 요청 실패 (invalid_client)", revoked: false });
  });

  it("Meet API 오류(403 범위 부족)는 그 연결만 error", async () => {
    stubGoogle();
    vi.mocked(syncGoogleMeet).mockRejectedValue(new GoogleApiError("Meet 요청 실패 (403 PERMISSION_DENIED)", 403, "PERMISSION_DENIED"));

    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "Google 요청 실패 (403)" });
    expect(outcome).toMatchObject({ ok: false, revoked: false });
  });

  it("동기화 도중 외부 AI 처리 동의를 철회했으면 잠금만 풀고(커서 · 오류 없이) 동의 문구를 돌려준다", async () => {
    stubGoogle();
    vi.mocked(syncGoogleMeet).mockRejectedValue(new ConsentRequiredError());

    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });

    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW });
    expect(outcome).toEqual({ connectionId: "g1", ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false });
  });

  it("그 밖의 오류는 일반 문구로 남기고, 본문을 로그에 남기지 않는다", async () => {
    stubGoogle();
    vi.mocked(syncGoogleMeet).mockRejectedValue(new Error("sources insert failed"));
    const outcome = await syncGoogleConnection(admin, connection, { now: NOW });
    expect(recordSync).toHaveBeenCalledWith(admin, connection, { claimedAt: NOW, error: "동기화 중 오류가 발생했습니다." });
    expect(outcome).toMatchObject({ ok: false, error: "동기화 중 오류가 발생했습니다." });
  });
});

describe("googleConnector.revokeToken", () => {
  it("갱신 토큰이 있으면 그것을 폐기한다 (허용 전체가 거둬진다)", async () => {
    const google = stubGoogle();
    await googleConnector.revokeToken!(stored({ access_token: "a-token", refresh_token: "r-token" }));
    expect(google.revoked()).toEqual(["r-token"]);
  });

  it("갱신 토큰이 없으면 액세스 토큰을 폐기하고, 이미 폐기된 토큰(400 invalid_token)은 성공으로 본다", async () => {
    const google = stubGoogle({ revoke: () => json({ error: "invalid_token" }, 400) });
    await expect(googleConnector.revokeToken!(stored({ access_token: "a-token", refresh_token: null }))).resolves.toBeUndefined();
    expect(google.revoked()).toEqual(["a-token"]);
  });

  it("서버 오류(500)면 던지고, 토큰 모양이 다르면 부르지 않는다", async () => {
    stubGoogle({ revoke: () => new Response("", { status: 500 }) });
    await expect(googleConnector.revokeToken!(stored())).rejects.toMatchObject({ name: "GoogleOAuthError", status: 500 });
    const google = stubGoogle();
    await googleConnector.revokeToken!({ xoxp: "not-google" });
    expect(google.calls).toEqual([]);
  });
});
