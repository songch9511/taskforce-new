import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), createSupabaseClient: vi.fn(), admin: vi.fn(), loadAnswerTask: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@supabase/supabase-js", async (original) => ({ ...(await original<typeof import("@supabase/supabase-js")>()), createClient: mocks.createSupabaseClient }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/answers", async (original) => ({ ...(await original<typeof import("@/lib/agents/answers")>()), loadAnswerTask: mocks.loadAnswerTask }));

import { POST as answer } from "./[id]/answer/route";

// 인증 거부 · 쿠키 CSRF (OA D1d, R2). 질문 답은 쓰기라 같은 출처의 쿠키 요청만 받고, 거절되면 DB를 부르지 않는다.
const USER = "11111111-0000-4000-8000-000000000001";
const TASK = "7a7a7a7a-0000-4000-8000-000000000001";
const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];
const claims = () => vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
const request = (headers: Record<string, string>) =>
  new Request("https://api.example.test/api/v2/agent-tasks/x/answer", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify({ provider_request_id: "q-1", answers: { choice: "Yes" } }),
  });
const call = (headers: Record<string, string>) => answer(request(headers), { params: Promise.resolve({ id: TASK }) });

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.createSupabaseClient.mockReturnValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  mocks.loadAnswerTask.mockResolvedValue(null);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST answer: 쿠키 CSRF · 인증", () => {
  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, DB 0)", async () => {
    for (const headers of CROSS_SITE) expect((await call(headers)).status, JSON.stringify(headers)).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.loadAnswerTask).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다 (없는 작업이라 404)", async () => {
    expect((await call({ "sec-fetch-site": "same-origin" })).status).toBe(404);
    expect(mocks.loadAnswerTask).toHaveBeenCalledTimes(1);
  });

  it("Bearer는 쿠키 CSRF 검사 대상이 아니다", async () => {
    expect((await call({ authorization: "Bearer token-123", "sec-fetch-site": "cross-site" })).status).toBe(404);
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
  });

  it("로그인하지 않은 요청은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await call({ "sec-fetch-site": "same-origin" })).status).toBe(401);
    expect(mocks.loadAnswerTask).not.toHaveBeenCalled();
  });
});
