import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), createSupabaseClient: vi.fn(), admin: vi.fn(), rpc: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@supabase/supabase-js", async (original) => ({ ...(await original<typeof import("@supabase/supabase-js")>()), createClient: mocks.createSupabaseClient }));

import { DELETE } from "./[id]/route";
import { PUT } from "./route";
import { GET } from "./status/route";

// 인증 두 길 · 쿠키 CSRF (OA PR-D3s, 계약 25.3 · 25.11). 쿠키로 인증하는 쓰기(PUT · DELETE)는 같은 출처만. 거절되면 DB 클라이언트도 부르지 않는다.
const USER = "11111111-0000-4000-8000-000000000001";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const CHAT = "c0c0c0c0-0000-4000-8000-000000000001";
const BODY = { bridge_id: BRIDGE, session_ref: "a".repeat(64), title: null, messages: [{ mac_ref: "b".repeat(64), role: "user", body: "x", truncated: false, said_at: "2026-10-22T09:00:00Z" }] };
const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];
const claims = () => vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
const put = (headers: Record<string, string>) =>
  new Request("https://api.example.test/api/v2/claude-app-chats", { method: "PUT", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(BODY) });
const del = (headers: Record<string, string>) => new Request(`https://api.example.test/api/v2/claude-app-chats/${CHAT}`, { method: "DELETE", headers });
const status = (headers: Record<string, string>) => new Request("https://api.example.test/api/v2/claude-app-chats/status", { method: "GET", headers });
const ctx = { params: Promise.resolve({ id: CHAT }) };

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
  vi.stubEnv("CLAUDE_APP_CHATS_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", USER);
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.createSupabaseClient.mockReturnValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  // 함수가 돌았다는 것만 보이면 된다: 저장은 ok, 지우기는 deleted
  mocks.rpc.mockImplementation((name: string) => ({
    throwOnError: () =>
      Promise.resolve({ data: name === "take_rate_limit" ? null : name === "save_claude_app_chat" ? { status: "ok", chat_id: CHAT, saved: 1, existing: 0, orphan: 0 } : { status: "deleted" }, error: null }),
  }));
  mocks.admin.mockReturnValue({ rpc: mocks.rpc });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("PUT claude-app-chats: 쿠키 CSRF · 인증", () => {
  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 저장 0)", async () => {
    for (const headers of CROSS_SITE) expect((await PUT(put(headers))).status, JSON.stringify(headers)).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다 (속도 제한 확인 뒤 저장)", async () => {
    expect((await PUT(put({ "sec-fetch-site": "same-origin" }))).status).toBe(200);
    expect(mocks.rpc.mock.calls.map((call) => call[0])).toEqual(["take_rate_limit", "save_claude_app_chat"]);
  });

  it("Bearer는 쿠키 CSRF 검사 대상이 아니다", async () => {
    expect((await PUT(put({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }))).status).toBe(200);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await PUT(put({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});

describe("DELETE claude-app-chats/{id}: 쿠키 CSRF · 인증", () => {
  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 삭제 0)", async () => {
    for (const headers of CROSS_SITE) expect((await DELETE(del(headers), ctx)).status, JSON.stringify(headers)).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키와 Bearer는 통과한다 (204)", async () => {
    expect((await DELETE(del({ "sec-fetch-site": "same-origin" }), ctx)).status).toBe(204);
    expect((await DELETE(del({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }), ctx)).status).toBe(204);
    expect(mocks.rpc).toHaveBeenCalledTimes(2);
  });
});

describe("GET claude-app-chats/status: 인증", () => {
  it("로그인하지 않은 요청은 401이다 (읽기라 CSRF 대상은 아니다)", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await GET(status({}))).status).toBe(401);
  });

  it("쿠키와 Bearer 모두 읽는다 (200)", async () => {
    expect((await GET(status({ "sec-fetch-site": "same-origin" }))).status).toBe(200);
    expect((await GET(status({ authorization: "Bearer token-123" }))).status).toBe(200);
    expect(mocks.admin).not.toHaveBeenCalled();
  });
});
