import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { notifyReconnect } from "@/lib/notify/service";

import { claimConnection, loadToken, markBackfilled, recordNotionHealth, recordSync, saveToken } from "../store";
import type { Connection } from "../types";

import { NotionError, type NotionClient, type NotionToken } from "./api";
import { syncNotionConnection } from "./run";
import { syncNotion, type NotionSyncResult } from "./sync";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/notify/service", () => ({ notifyReconnect: vi.fn() }));
vi.mock("../store", () => ({
  claimConnection: vi.fn(),
  ingestDeps: vi.fn(() => ({})),
  loadToken: vi.fn(),
  markBackfilled: vi.fn(),
  recordNotionHealth: vi.fn(),
  recordSync: vi.fn(),
  saveConnection: vi.fn(),
  saveToken: vi.fn(),
  taskDeps: vi.fn(() => ({})),
}));
// Notion 호출은 가짜 클라이언트(쓴 토큰만 담음)로 바꾸고, 토큰 갱신(POST /v1/oauth/token)만 fetch로 흉내 낸다
vi.mock("./api", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./api")>()),
  notionClient: (accessToken: string) => ({ accessToken }) as unknown as NotionClient,
}));
vi.mock("./data-sources", () => ({ notionCoverage: vi.fn() }));
vi.mock("./sync", () => ({ DEFAULT_NOTION_SYNC: {}, syncNotion: vi.fn() }));

// 동기화 실패를 연결 상태로 남기는 규칙: 갱신 토큰이 거절되면 다시 연결 필요(reauth), 잠깐 문제면 error.

const admin = {} as SupabaseClient;
const connection: Connection = { id: "c1", userId: "u1", provider: "notion", settings: {}, syncCursor: null };
const synced = { cursor: { since: "2026-09-29T00:00:00.000Z" }, backfilled: [] } as unknown as NotionSyncResult;
const token = (access: string, refresh: string | null): NotionToken => ({
  access_token: access,
  refresh_token: refresh,
  bot_id: "bot",
  workspace_id: "ws",
  workspace_name: "WS",
});
const tokenEndpoint = (status: number, body: unknown) =>
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => new Response(JSON.stringify(body), { status })),
  );
/** recordSync에 넘기는 값: 동기화를 시작한 시각(claimedAt)과 함께 */
const recorded = (update: object) => ({ ...update, claimedAt: expect.any(Date) });
const invalidGrant = { object: "error", status: 400, code: "invalid_grant", message: "Invalid refresh token." };
const usedTokens = () => vi.mocked(syncNotion).mock.calls.map(([, client]) => (client as unknown as { accessToken: string }).accessToken);

/** 동기화를 돌리며 기다림(동시 갱신 확인)은 바로 넘긴다 */
async function sync() {
  vi.useFakeTimers({ toFake: ["setTimeout"] });
  const outcome = syncNotionConnection(admin, connection);
  await vi.runAllTimersAsync();
  return outcome;
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(loadToken).mockReset();
  vi.stubEnv("NOTION_CLIENT_ID", "cid");
  vi.stubEnv("NOTION_CLIENT_SECRET", "secret");
  vi.stubEnv("NOTION_REDIRECT_URI", "https://api.example.dev/cb");
  vi.mocked(claimConnection).mockResolvedValue(true);
  vi.mocked(recordSync).mockResolvedValue(false);
  vi.mocked(notifyReconnect).mockResolvedValue(1);
  vi.mocked(recordNotionHealth).mockResolvedValue();
  vi.mocked(markBackfilled).mockResolvedValue();
  vi.mocked(saveToken).mockResolvedValue();
  // 만료된 액세스 토큰("expired…")은 401, 그 밖의 토큰으로는 동기화된다
  vi.mocked(syncNotion).mockImplementation(async (_connection, client) => {
    if ((client as unknown as { accessToken: string }).accessToken.startsWith("expired")) {
      throw new NotionError("Notion API 요청 실패 (401 unauthorized)", 401, "unauthorized");
    }
    return synced;
  });
});

describe("syncNotionConnection: 토큰 갱신이 실패하면", () => {
  it("갱신 토큰이 거절되면(invalid_grant) 다시 연결 필요(reauth)로 남긴다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(400, invalidGrant);

    const outcome = await sync();

    expect(outcome.ok).toBe(false);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({
      error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.",
      revoked: false,
      reauth: true,
    }));
    expect(saveToken).not.toHaveBeenCalled();
    // 처음 읽기 + 동시 갱신 확인 두 번 (바로 한 번, 기다렸다 한 번)
    expect(loadToken).toHaveBeenCalledTimes(3);
  });

  it("reauth로 바꾼 동기화(recordSync가 true)에서만 재연결 알림 한 번, 알림이 실패해도 결과는 그대로", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(400, invalidGrant);
    vi.mocked(recordSync).mockResolvedValue(true);
    vi.mocked(notifyReconnect).mockRejectedValue(new Error("APNs down"));
    vi.spyOn(console, "error").mockImplementation(() => {});

    const outcome = await sync();

    expect(notifyReconnect).toHaveBeenCalledTimes(1);
    expect(notifyReconnect).toHaveBeenCalledWith(admin, "u1", "notion");
    expect(outcome).toEqual({ connectionId: "c1", ok: false, error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", revoked: false });
  });

  it("이미 reauth였거나 그 사이 다시 연결해 recordSync가 false면 알림을 보내지 않는다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(400, invalidGrant);
    vi.mocked(recordSync).mockResolvedValue(false);

    await sync();

    expect(notifyReconnect).not.toHaveBeenCalled();
  });

  it("같은 순간에 겹쳐 먼저 갱신한 쪽이 아직 저장하지 못했으면, 기다렸다 다시 읽은 새 토큰으로 이어 간다", async () => {
    vi.mocked(loadToken)
      .mockResolvedValueOnce(token("expired", "r1"))
      .mockResolvedValueOnce(token("expired", "r1"))
      .mockResolvedValueOnce(token("fresh", "r2"));
    tokenEndpoint(400, invalidGrant);

    const outcome = await sync();

    expect(outcome.ok).toBe(true);
    expect(usedTokens()).toEqual(["expired", "fresh"]);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({ cursor: synced.cursor }));
  });

  it("invalid_grant가 아닌 거절(400)은 다시 연결 필요로 보지 않는다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(400, { object: "error", status: 400, code: "invalid_request", message: "bad request" });

    await sync();

    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({ error: "Notion 요청 실패 (400)", revoked: false, reauth: false }));
  });

  it("다른 요청이 먼저 갱신해 저장했으면(갱신 토큰이 바뀜) 저장된 새 토큰으로 이어 가고 연결은 그대로 둔다", async () => {
    vi.mocked(loadToken).mockResolvedValueOnce(token("expired", "r1")).mockResolvedValueOnce(token("fresh", "r2"));
    tokenEndpoint(400, invalidGrant);

    const outcome = await sync();

    expect(outcome.ok).toBe(true);
    expect(usedTokens()).toEqual(["expired", "fresh"]);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({ cursor: synced.cursor }));
  });

  it("갱신 요청이 서버 오류면 잠깐 문제로 보고 error로 남긴다 (다음 동기화가 다시 시도한다)", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(503, {});

    await sync();

    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({ error: "Notion 요청 실패 (503)", revoked: false, reauth: false }));
  });

  it("갱신 요청 자체가 401이면(우리 쪽 client id · secret 문제일 수 있다) 권한이 끊긴 것으로 보지 않고 error로 남긴다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(401, { object: "error", status: 401, code: "unauthorized", message: "API token is invalid." });

    await sync();

    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({ error: "Notion 요청 실패 (401)", revoked: false, reauth: false }));
    expect(usedTokens()).toEqual(["expired"]);
    expect(saveToken).not.toHaveBeenCalled();
  });

  it("갱신한 토큰으로도 401이면 권한이 끊긴 것(revoked)으로 남긴다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(200, token("expired-too", "r2"));

    await sync();

    expect(usedTokens()).toEqual(["expired", "expired-too"]);
    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({
      error: "Notion 연결 권한이 끊겼습니다. 다시 연결해 주세요.",
      revoked: true,
      reauth: false,
    }));
  });

  it("끊긴 것(revoked)이나 일시적 오류는 recordSync가 true를 돌려주는 상황에서도 재연결 알림 대상이 아니다 (reauth일 때만)", async () => {
    vi.mocked(recordSync).mockResolvedValue(true);
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(200, token("expired-too", "r2"));
    await sync();
    expect(recordSync).toHaveBeenLastCalledWith(admin, connection, recorded({ error: "Notion 연결 권한이 끊겼습니다. 다시 연결해 주세요.", revoked: true, reauth: false }));

    vi.mocked(syncNotion).mockRejectedValue(new NotionError("Notion API 요청 실패 (503)", 503, "service_unavailable"));
    vi.mocked(loadToken).mockResolvedValue(token("fresh", "r1"));
    await sync();
    expect(recordSync).toHaveBeenLastCalledWith(admin, connection, recorded({ error: "Notion 요청 실패 (503)", revoked: false, reauth: false }));

    expect(notifyReconnect).not.toHaveBeenCalled();
  });

  it("갱신 토큰 없이 401이면 권한이 끊긴 것(revoked)으로 남긴다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", null));

    await sync();

    expect(recordSync).toHaveBeenCalledWith(admin, connection, recorded({
      error: "Notion 연결 권한이 끊겼습니다. 다시 연결해 주세요.",
      revoked: true,
      reauth: false,
    }));
  });

  it("갱신에 성공하면 새 토큰을 저장하고 이어 간다", async () => {
    vi.mocked(loadToken).mockResolvedValue(token("expired", "r1"));
    tokenEndpoint(200, token("fresh", "r2"));

    const outcome = await sync();

    expect(outcome.ok).toBe(true);
    expect(saveToken).toHaveBeenCalledWith(admin, "c1", token("fresh", "r2"));
    expect(usedTokens()).toEqual(["expired", "fresh"]);
  });
});
