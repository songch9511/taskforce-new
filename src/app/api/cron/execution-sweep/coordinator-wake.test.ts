import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { reconcileAiSpend } from "@/lib/ai/budget";

const mocks = vi.hoisted(() => ({
  afterCallbacks: [] as (() => unknown)[],
  afterImpl: undefined as undefined | ((callback: () => unknown) => void),
  sweep: vi.fn(),
  wakeRun: vi.fn(),
  wakeCoordinator: vi.fn(),
}));

vi.mock("@/lib/ai/budget", () => ({ reconcileAiSpend: vi.fn() }));
vi.mock("server-only", () => ({}));
vi.mock("next/server", () => ({ after: (callback: () => unknown) => (mocks.afterImpl ? mocks.afterImpl(callback) : mocks.afterCallbacks.push(callback)) }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/execution/store", () => ({ supabaseExecutionStore: vi.fn(() => ({ store: true })) }));
vi.mock("@/lib/execution/sweep", () => ({ sweep: mocks.sweep }));
vi.mock("@/lib/execution/wake", () => ({ wakeRun: mocks.wakeRun }));
vi.mock("@/lib/coordinator/wake", () => ({ wakeCoordinator: mocks.wakeCoordinator }));

import { GET } from "./route";

// 0.2.0 C2: 1분 execution-sweep은 응답을 보낸 뒤 코디네이터를 깨우는 자기 호출 하나만 더한다. 기존 응답 · 실행 sweep 호출은 어느 경우에도 같다.
const AI_SPEND = { attempted: 3, settled: 1, deferred: 2, errors: 0 };
const RESULT = { expired: 1, reconciled: 0, released: 0, woken: 2, wake_failed: 0, errors: 0 };
const cron = () => GET(new Request("https://api.example.test/api/cron/execution-sweep", { headers: { authorization: "Bearer s3cret" } }));
const bodyOf = async (response: Response) => ({ status: response.status, body: await response.json() });

beforeEach(() => {
  vi.clearAllMocks();
  mocks.afterCallbacks.length = 0;
  mocks.afterImpl = undefined;
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.stubEnv("EXECUTION_ENABLED", "true");
  mocks.sweep.mockResolvedValue(RESULT);
  vi.mocked(reconcileAiSpend).mockResolvedValue(AI_SPEND);
  vi.spyOn(console, "info").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("execution-sweep × 코디네이터 깨우기", () => {
  it("COORDINATOR_ENABLED가 꺼져 있으면(기본) after()도 코디네이터 깨우기도 없다: 응답 · 호출은 예전과 같다", async () => {
    for (const flag of [undefined, "", "false", "1"]) {
      vi.unstubAllEnvs();
      vi.stubEnv("CRON_SECRET", "s3cret");
      vi.stubEnv("EXECUTION_ENABLED", "true");
      if (flag !== undefined) vi.stubEnv("COORDINATOR_ENABLED", flag);
      expect(await bodyOf(await cron())).toEqual({ status: 200, body: { enabled: true, ...RESULT } });
    }
    expect(mocks.afterCallbacks).toHaveLength(0);
    expect(mocks.wakeCoordinator).not.toHaveBeenCalled();
    expect(mocks.sweep).toHaveBeenCalledTimes(4);
  });

  it("켜져 있으면 응답을 보낸 뒤(after) 코디네이터를 한 번 깨운다. 실행 sweep의 응답은 켜졌을 때와 꺼졌을 때가 같다", async () => {
    const off = await bodyOf(await cron());
    vi.stubEnv("COORDINATOR_ENABLED", "true");
    const on = await bodyOf(await cron());
    expect(on).toEqual(off);
    expect(mocks.afterCallbacks).toHaveLength(1);
    expect(mocks.wakeCoordinator).not.toHaveBeenCalled(); // 응답이 먼저
    await mocks.afterCallbacks[0]();
    expect(mocks.wakeCoordinator).toHaveBeenCalledTimes(1);
  });

  it("실행 플래그가 꺼져 있어도(실행 sweep 생략) 코디네이터 깨우기는 독립으로 돈다. 공통 AI 원가 확인 실패(500)의 응답 의미도 그대로", async () => {
    vi.stubEnv("COORDINATOR_ENABLED", "true");
    vi.stubEnv("EXECUTION_ENABLED", "");
    expect(await bodyOf(await cron())).toEqual({ status: 200, body: { enabled: false } });
    expect(mocks.sweep).not.toHaveBeenCalled();
    vi.mocked(reconcileAiSpend).mockResolvedValue({ attempted: 0, settled: 0, deferred: 0, errors: 1 });
    const failed = await cron();
    expect(failed.status).toBe(500);
    expect(await failed.json()).toEqual({ error: "AI spend reconciliation could not start" });
    expect(mocks.afterCallbacks).toHaveLength(2);
  });

  it("after()를 쓸 수 없거나 깨우기가 실패해도 이 sweep은 영향을 받지 않는다 (코디네이터 실패를 가둔다)", async () => {
    vi.stubEnv("COORDINATOR_ENABLED", "true");
    mocks.afterImpl = () => {
      throw new Error("`after` was called outside a request scope");
    };
    expect(await bodyOf(await cron())).toEqual({ status: 200, body: { enabled: true, ...RESULT } });
    expect(vi.mocked(console.error).mock.calls.flat().join("\n")).toContain("coordinator_wake_schedule_failed");
    expect(mocks.sweep).toHaveBeenCalledTimes(1);
  });

  it("CRON_SECRET이 다르면 코디네이터도 깨우지 않는다 (401이 먼저)", async () => {
    vi.stubEnv("COORDINATOR_ENABLED", "true");
    const response = await GET(new Request("https://api.example.test/api/cron/execution-sweep", { headers: { authorization: "Bearer wrong!" } }));
    expect(response.status).toBe(401);
    expect(mocks.afterCallbacks).toHaveLength(0);
  });
});
