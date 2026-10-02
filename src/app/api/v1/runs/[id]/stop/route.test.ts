import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getVerifiedClaims: vi.fn(),
  isExecutionActor: vi.fn(),
  stopRun: vi.fn(),
  loadRunSummary: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.getVerifiedClaims }));
vi.mock("@/lib/supabase/server", () => ({ createClient: vi.fn(async () => ({ cookie: true })) }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/execution/store", () => ({ isExecutionActor: mocks.isExecutionActor, stopRun: mocks.stopRun, loadRunSummary: mocks.loadRunSummary }));

import { POST } from "./route";

const USER_ID = "00000000-0000-4000-8000-00000000000a";
const RUN_ID = "22222222-2222-4222-8222-222222222222";
const run = (state: string) => ({ id: RUN_ID, action_id: RUN_ID, goal: "draft", state, hold_reason: null, outcome: null, budget_credits: null, created_at: "2026-10-02T00:00:00Z" });

const stop = (headers: Record<string, string> = { authorization: "Bearer app-token" }, id = RUN_ID) =>
  POST(new Request(`https://api.example.test/api/v1/runs/${id}/stop`, { method: "POST", headers }), { params: Promise.resolve({ id }) });

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("EXECUTION_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.getVerifiedClaims.mockResolvedValue({ data: { claims: { sub: USER_ID } }, error: null });
  mocks.isExecutionActor.mockResolvedValue(true);
  mocks.stopRun.mockResolvedValue("stopped");
  mocks.loadRunSummary.mockResolvedValue(run("stopped"));
});

afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v1/runs/:id/stop", () => {
  it("멈추고 200 { run }. 다시 눌러도(이미 끝난 run) 같은 200", async () => {
    const first = await stop();
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ run: run("stopped") });
    expect(mocks.stopRun).toHaveBeenCalledWith({ admin: true }, USER_ID, RUN_ID);
    const again = await stop();
    expect(again.status).toBe(200);
    expect(((await again.json()) as { run: { state: string } }).run.state).toBe("stopped");
  });

  it("쿠키로 다른 사이트에서 온 멈추기는 401 (CSRF)", async () => {
    expect((await stop({ "sec-fetch-site": "cross-site" })).status).toBe(401);
    expect(mocks.stopRun).not.toHaveBeenCalled();
    expect((await stop({ "sec-fetch-site": "same-origin" })).status).toBe(200);
  });

  it("플래그 꺼짐 · 허용 목록 밖 · 없거나 남의 run은 404", async () => {
    mocks.stopRun.mockResolvedValueOnce(null);
    expect((await stop()).status).toBe(404);
    mocks.isExecutionActor.mockResolvedValueOnce(false);
    expect((await stop()).status).toBe(404);
    vi.stubEnv("EXECUTION_ENABLED", "false");
    expect((await stop()).status).toBe(404);
  });
});
