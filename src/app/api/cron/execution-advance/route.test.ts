import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ afterCallbacks: [] as (() => unknown)[], advanceAndWake: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("next/server", () => ({ after: (callback: () => unknown) => mocks.afterCallbacks.push(callback) }));
vi.mock("@/lib/execution/wake", () => ({ advanceAndWake: mocks.advanceAndWake }));

import { EXECUTION_MAX_DURATION_S, LEASE_MARGIN_S, LEASE_SECONDS } from "@/lib/execution/limits";

import { maxDuration, POST } from "./route";

const RUN_ID = "22222222-2222-4222-8222-222222222222";
const call = (body: unknown = { run_id: RUN_ID }, authorization = "Bearer s3cret") =>
  POST(new Request("https://api.example.test/api/cron/execution-advance", { method: "POST", headers: { authorization }, body: JSON.stringify(body) }));

beforeEach(() => {
  vi.clearAllMocks();
  mocks.afterCallbacks.length = 0;
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.stubEnv("EXECUTION_ENABLED", "true");
});

afterEach(() => vi.unstubAllEnvs());

describe("POST /api/cron/execution-advance (자기 호출)", () => {
  it("실행 한도는 lease(330초)보다 여유만큼 짧다", () => {
    expect(maxDuration).toBe(EXECUTION_MAX_DURATION_S);
    expect(maxDuration).toBe(LEASE_SECONDS - LEASE_MARGIN_S);
  });

  it("바로 202로 답하고 단계 하나는 after()에서 돈다", async () => {
    const response = await call();
    expect(response.status).toBe(202);
    expect(mocks.advanceAndWake).not.toHaveBeenCalled();
    await mocks.afterCallbacks[0]();
    expect(mocks.advanceAndWake).toHaveBeenCalledWith(RUN_ID);
  });

  it("CRON_SECRET이 다르면 401, 플래그가 꺼져 있으면 404, run id가 UUID가 아니면 400. 어느 쪽도 단계를 돌지 않는다", async () => {
    expect((await call({ run_id: RUN_ID }, "Bearer wrong!")).status).toBe(401);
    expect((await call({ run_id: "x" })).status).toBe(400);
    vi.stubEnv("EXECUTION_ENABLED", "false");
    expect((await call()).status).toBe(404);
    expect(mocks.afterCallbacks).toHaveLength(0);
  });
});
