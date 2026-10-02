import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ getVerifiedClaims: vi.fn(), isExecutionActor: vi.fn(), loadCredits: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.getVerifiedClaims }));
vi.mock("@/lib/supabase/server", () => ({ createClient: vi.fn(async () => ({ cookie: true })) }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/execution/store", () => ({ isExecutionActor: mocks.isExecutionActor, loadCredits: mocks.loadCredits }));

import { GET } from "./route";

const USER_ID = "00000000-0000-4000-8000-00000000000a";
const get = (headers: Record<string, string> = { authorization: "Bearer app-token" }) => GET(new Request("https://api.example.test/api/v1/credits", { headers }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("EXECUTION_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.getVerifiedClaims.mockResolvedValue({ data: { claims: { sub: USER_ID } }, error: null });
  mocks.isExecutionActor.mockResolvedValue(true);
  mocks.loadCredits.mockResolvedValue({ available: 80, reserved: 20, rate_version: "c3-v1" });
});

afterEach(() => vi.unstubAllEnvs());

describe("GET /api/v1/credits", () => {
  it("내 합계만 (Bearer · 쿠키 모두, 읽기라 CSRF 확인은 없다)", async () => {
    const response = await get();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ available: 80, reserved: 20, rate_version: "c3-v1" });
    expect(mocks.loadCredits).toHaveBeenCalledWith({ admin: true }, USER_ID);
    expect((await get({ "sec-fetch-site": "same-origin" })).status).toBe(200);
  });

  it("플래그 꺼짐 · 허용 목록 밖 404, 로그인 전 401", async () => {
    mocks.isExecutionActor.mockResolvedValueOnce(false);
    expect((await get()).status).toBe(404);
    mocks.getVerifiedClaims.mockResolvedValueOnce({ data: null, error: new Error("invalid") });
    expect((await get()).status).toBe(401);
    vi.stubEnv("EXECUTION_ENABLED", "");
    expect((await get()).status).toBe(404);
    expect(mocks.loadCredits).not.toHaveBeenCalled();
  });
});
