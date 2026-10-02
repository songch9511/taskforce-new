import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  afterCallbacks: [] as (() => unknown)[],
  getVerifiedClaims: vi.fn(),
  isExecutionActor: vi.fn(),
  executionGloballyBlocked: vi.fn(),
  actionIsOpen: vi.fn(),
  createRun: vi.fn(),
  loadRunSummary: vi.fn(),
  advanceAndWake: vi.fn(),
  hasAiConsent: vi.fn(),
  takeRateLimit: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("next/server", () => ({ after: (callback: () => unknown) => mocks.afterCallbacks.push(callback) }));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.getVerifiedClaims }));
vi.mock("@/lib/supabase/server", () => ({ createClient: vi.fn(async () => ({ cookie: true })) }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/execution/store", () => ({
  isExecutionActor: mocks.isExecutionActor,
  executionGloballyBlocked: mocks.executionGloballyBlocked,
  actionIsOpen: mocks.actionIsOpen,
  createRun: mocks.createRun,
  loadRunSummary: mocks.loadRunSummary,
}));
vi.mock("@/lib/execution/wake", () => ({ advanceAndWake: mocks.advanceAndWake }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: mocks.hasAiConsent }));
vi.mock("@/lib/api/rate-limit-store", () => ({ takeRateLimit: mocks.takeRateLimit }));

import { RUN_CREATE_LIMIT } from "@/lib/api/rate-limit";
import { EXECUTION_MAX_DURATION_S, LEASE_MARGIN_S, LEASE_SECONDS } from "@/lib/execution/limits";

import { maxDuration, POST } from "./route";

const USER_ID = "00000000-0000-4000-8000-00000000000a";
const ACTION_ID = "11111111-1111-4111-8111-111111111111";
const RUN_ID = "22222222-2222-4222-8222-222222222222";
const RUN = { id: RUN_ID, action_id: ACTION_ID, goal: "draft", state: "queued", hold_reason: null, outcome: null, budget_credits: null, created_at: "2026-10-02T00:00:00Z" };

const post = (headers: Record<string, string> = { authorization: "Bearer app-token" }) =>
  POST(
    new Request("https://api.example.test/api/v1/runs", {
      method: "POST",
      headers: { "content-type": "application/json", ...headers },
      body: JSON.stringify({ action_id: ACTION_ID, goal: "draft", request: "견적 회신 메일 초안 써 줘" }),
    }),
  );

beforeEach(() => {
  vi.clearAllMocks();
  mocks.afterCallbacks.length = 0;
  vi.stubEnv("EXECUTION_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.getVerifiedClaims.mockResolvedValue({ data: { claims: { sub: USER_ID, email: "doyun@example.test" } }, error: null });
  mocks.isExecutionActor.mockResolvedValue(true);
  mocks.executionGloballyBlocked.mockResolvedValue(false);
  mocks.actionIsOpen.mockResolvedValue(true);
  mocks.hasAiConsent.mockResolvedValue(true);
  mocks.takeRateLimit.mockResolvedValue(null);
  mocks.createRun.mockResolvedValue(RUN_ID);
  mocks.loadRunSummary.mockResolvedValue(RUN);
});

afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v1/runs", () => {
  it("실행 한도는 lease(begin_call 330초)보다 여유만큼 짧다 (리터럴이라 같은 값인지 여기서 본다)", () => {
    expect(maxDuration).toBe(EXECUTION_MAX_DURATION_S);
    expect(maxDuration).toBe(LEASE_SECONDS - LEASE_MARGIN_S);
  });

  it("Bearer(앱): 202 { run }, 첫 단계는 응답 뒤 after()에서 돈다. Bearer는 쿠키 CSRF 확인을 하지 않는다", async () => {
    const response = await post({ authorization: "Bearer app-token", "sec-fetch-site": "cross-site" });
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ run: RUN });
    expect(mocks.takeRateLimit).toHaveBeenCalledWith({ admin: true }, USER_ID, "run_create", RUN_CREATE_LIMIT);
    expect(mocks.createRun).toHaveBeenCalledWith({ admin: true }, USER_ID, { actionId: ACTION_ID, goal: "draft", request: "견적 회신 메일 초안 써 줘", budgetCredits: null });
    expect(mocks.advanceAndWake).not.toHaveBeenCalled();
    expect(mocks.afterCallbacks).toHaveLength(1);
    await mocks.afterCallbacks[0]();
    expect(mocks.advanceAndWake).toHaveBeenCalledWith(RUN_ID);
  });

  it("쿠키(웹): 같은 출처면 받고, 다른 사이트에서 온 쓰기는 로그인하지 않은 것으로 본다 (CSRF, 401)", async () => {
    expect((await post({ "sec-fetch-site": "same-origin" })).status).toBe(202);
    vi.clearAllMocks();
    mocks.afterCallbacks.length = 0;
    const crossSite = await post({ "sec-fetch-site": "cross-site" });
    expect(crossSite.status).toBe(401);
    expect(mocks.getVerifiedClaims).not.toHaveBeenCalled();
    expect(mocks.createRun).not.toHaveBeenCalled();
    expect(mocks.afterCallbacks).toHaveLength(0);
  });

  it("기능 플래그가 꺼져 있으면(기본) 404, 인증 · DB를 보지 않는다", async () => {
    vi.stubEnv("EXECUTION_ENABLED", "");
    const response = await post();
    expect(response.status).toBe(404);
    expect(mocks.getVerifiedClaims).not.toHaveBeenCalled();
    expect(mocks.isExecutionActor).not.toHaveBeenCalled();
  });

  it("운영자(실행 주체 허용 목록) 밖이면 404, 동의 전 409, 한도 429", async () => {
    mocks.isExecutionActor.mockResolvedValueOnce(false);
    expect((await post()).status).toBe(404);
    mocks.hasAiConsent.mockResolvedValueOnce(false);
    expect((await post()).status).toBe(409);
    mocks.takeRateLimit.mockResolvedValueOnce(new Date(Date.now() + 60_000));
    const limited = await post();
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBeTruthy();
    expect(mocks.createRun).not.toHaveBeenCalled();
  });
});
