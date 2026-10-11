import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ afterCallbacks: [] as (() => unknown)[], advanceCoordinator: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("next/server", () => ({ after: (callback: () => unknown) => mocks.afterCallbacks.push(callback) }));
vi.mock("@/lib/coordinator/wake", () => ({ advanceCoordinator: mocks.advanceCoordinator }));

import { COORDINATOR_LEASE_MARGIN_S, COORDINATOR_LEASE_SECONDS, COORDINATOR_MAX_DURATION_S } from "@/lib/coordinator/coordinator.config";

import { maxDuration, POST } from "./route";

const call = (authorization = "Bearer s3cret") => POST(new Request("https://api.example.test/api/cron/coordinator-advance", { method: "POST", headers: { authorization }, body: "{}" }));

beforeEach(() => {
  vi.clearAllMocks();
  mocks.afterCallbacks.length = 0;
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.stubEnv("COORDINATOR_ENABLED", "true");
});
afterEach(() => vi.unstubAllEnvs());

describe("POST /api/cron/coordinator-advance (자기 호출)", () => {
  it("실행 한도는 lease보다 여유만큼 짧다 (살아 있는 함수의 lease는 만료되지 않는다)", () => {
    expect(maxDuration).toBe(COORDINATOR_MAX_DURATION_S);
    expect(maxDuration).toBe(COORDINATOR_LEASE_SECONDS - COORDINATOR_LEASE_MARGIN_S);
  });

  it("바로 202로 답하고 처리는 after()에서 돈다", async () => {
    const response = await call();
    expect(response.status).toBe(202);
    expect(mocks.advanceCoordinator).not.toHaveBeenCalled();
    await mocks.afterCallbacks[0]();
    expect(mocks.advanceCoordinator).toHaveBeenCalledTimes(1);
  });

  it("CRON_SECRET이 다르면 401, 플래그가 꺼져 있으면(기본) 404. 어느 쪽도 처리를 돌지 않는다", async () => {
    expect((await call("Bearer wrong!")).status).toBe(401);
    for (const flag of ["", "false", "1", "TRUE"]) {
      vi.stubEnv("COORDINATOR_ENABLED", flag);
      expect((await call()).status).toBe(404);
    }
    vi.unstubAllEnvs();
    vi.stubEnv("CRON_SECRET", "s3cret");
    expect((await call()).status).toBe(404); // 환경변수가 없으면 꺼져 있다
    expect(mocks.afterCallbacks).toHaveLength(0);
    expect(mocks.advanceCoordinator).not.toHaveBeenCalled();
  });
});
