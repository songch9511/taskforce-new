import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), createSupabaseClient: vi.fn(), admin: vi.fn(), insert: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@supabase/supabase-js", async (original) => ({ ...(await original<typeof import("@supabase/supabase-js")>()), createClient: mocks.createSupabaseClient }));

import { POST } from "./route";

// 쿠키 CSRF · 인증 (OA PR-D3s). 거절되면 DB 클라이언트도 부르지 않는다.
const USER = "11111111-0000-4000-8000-000000000001";
const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];
const claims = () => vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
const post = (headers: Record<string, string>) =>
  new Request("https://api.example.test/api/v2/external-sessions/claude-app-sent", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify({ result: "not_sent", reason: "bypass" }) });

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", USER);
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.createSupabaseClient.mockReturnValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.insert.mockResolvedValue({ error: null });
  mocks.admin.mockReturnValue({ from: () => ({ insert: mocks.insert }), rpc: () => ({ throwOnError: () => Promise.resolve({ data: null, error: null }) }) });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST external-sessions/claude-app-sent: 쿠키 CSRF · 인증", () => {
  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 저장 0)", async () => {
    for (const headers of CROSS_SITE) expect((await POST(post(headers))).status, JSON.stringify(headers)).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키와 Bearer는 통과한다 (204)", async () => {
    expect((await POST(post({ "sec-fetch-site": "same-origin" }))).status).toBe(204);
    expect((await POST(post({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }))).status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledTimes(2);
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await POST(post({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(mocks.insert).not.toHaveBeenCalled();
  });
});
