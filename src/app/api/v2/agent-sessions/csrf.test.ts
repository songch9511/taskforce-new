import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), createSupabaseClient: vi.fn(), admin: vi.fn(), loadSessionAdapter: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@supabase/supabase-js", async (original) => ({ ...(await original<typeof import("@supabase/supabase-js")>()), createClient: mocks.createSupabaseClient }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/sessions", async (original) => ({ ...(await original<typeof import("@/lib/agents/sessions")>()), loadSessionAdapter: mocks.loadSessionAdapter }));

import { POST as openExternal } from "./[id]/open-external/route";
import { POST as resumeHere } from "./[id]/resume-here/route";
import { PATCH as rename } from "./[id]/route";
import { POST as stop } from "./[id]/stop/route";

// 인증 거부 · 쿠키 CSRF (OA D1d, R2). 거절되면 쓰기도 DB 클라이언트도 부르지 않는다.
const USER = "11111111-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const params = { params: Promise.resolve({ id: SESSION }) };

const ROUTES: [string, string, (request: Request) => Promise<Response>, unknown][] = [
  ["PATCH session", "PATCH", (request) => rename(request, params), { display_name: "Pricing" }],
  ["POST stop", "POST", (request) => stop(request, params), {}],
  ["POST open-external", "POST", (request) => openExternal(request, params), {}],
  ["POST resume-here", "POST", (request) => resumeHere(request, params), { confirmed_terminal_closed: true }],
];
const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];
const claims = () => vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.createSupabaseClient.mockReturnValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  mocks.loadSessionAdapter.mockResolvedValue(null);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe.each(ROUTES)("%s: 쿠키 CSRF · 인증", (name, method, call, payload) => {
  const request = (headers: Record<string, string>) =>
    new Request("https://api.example.test/api/v2/x", { method, headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(payload) });

  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 쓰기 0 · DB 클라이언트 0)", async () => {
    for (const headers of CROSS_SITE) expect((await call(request(headers))).status, `${name} ${JSON.stringify(headers)}`).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.loadSessionAdapter).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다 (handler가 돈다: 없는 세션이라 404)", async () => {
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(404);
    expect(mocks.loadSessionAdapter).toHaveBeenCalledTimes(1);
  });

  it("Bearer는 쿠키 CSRF 검사 대상이 아니다", async () => {
    expect((await call(request({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }))).status).toBe(404);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(mocks.loadSessionAdapter).not.toHaveBeenCalled();
  });
});
