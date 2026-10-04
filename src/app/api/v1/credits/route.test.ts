import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getVerifiedClaims: vi.fn(),
  isExecutionActor: vi.fn(),
  loadCredits: vi.fn(),
  loadCreditDetails: vi.fn(),
  executionGloballyBlocked: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.getVerifiedClaims }));
vi.mock("@/lib/supabase/server", () => ({ createClient: vi.fn(async () => ({ cookie: true })) }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/execution/store", () => ({
  isExecutionActor: mocks.isExecutionActor,
  loadCredits: mocks.loadCredits,
  loadCreditDetails: mocks.loadCreditDetails,
  executionGloballyBlocked: mocks.executionGloballyBlocked,
}));

import { GET } from "./route";

const USER_ID = "00000000-0000-4000-8000-00000000000a";
const ACTION_ID = "11111111-1111-4111-8111-111111111111";
const DETAILS = { running_runs: 1, settling: { steps: 1, reserved: 20, action_ids: [ACTION_ID] }, used: { credits: 3, since: "2026-10-01T00:00:00.000Z" } };
const get = (headers: Record<string, string> = { authorization: "Bearer app-token" }, query = "") =>
  GET(new Request(`https://api.example.test/api/v1/credits${query}`, { headers }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("EXECUTION_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.getVerifiedClaims.mockResolvedValue({ data: { claims: { sub: USER_ID } }, error: null });
  mocks.isExecutionActor.mockResolvedValue(true);
  mocks.loadCredits.mockResolvedValue({ available: 80, reserved: 20, rate_version: "c3-v1" });
  mocks.loadCreditDetails.mockResolvedValue(DETAILS);
  mocks.executionGloballyBlocked.mockResolvedValue(false);
});

afterEach(() => vi.unstubAllEnvs());

describe("GET /api/v1/credits", () => {
  it("내 합계만 (Bearer · 쿠키 모두, 읽기라 CSRF 확인은 없다)", async () => {
    const response = await get();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ available: 80, reserved: 20, rate_version: "c3-v1", ...DETAILS, accepting_runs: true, draft_estimate_credits: 20 });
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

  it("S3 숫자는 since와 함께 서버(admin)가 원장에서 센다. 전체 스위치가 막혔으면 accepting_runs false, since가 틀리면 400", async () => {
    vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-10-15T03:00:00Z") }); // since는 지금부터 1년 안만 받는다
    onTestFinished(() => {
      vi.useRealTimers();
    });
    mocks.executionGloballyBlocked.mockResolvedValueOnce(true);
    const response = await get(undefined, `?since=${encodeURIComponent("2026-10-01T00:00:00+09:00")}`);
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ accepting_runs: false });
    expect(mocks.loadCreditDetails).toHaveBeenCalledWith({ admin: true }, USER_ID, new Date("2026-09-30T15:00:00Z"));
    expect(mocks.executionGloballyBlocked).toHaveBeenCalledWith({ admin: true });

    mocks.loadCreditDetails.mockClear();
    expect((await get(undefined, "?since=2026-10-01")).status).toBe(400);
    expect(mocks.loadCreditDetails).not.toHaveBeenCalled();
  });
});
