import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { GenerationLookup } from "@/lib/ai/generation";

import { RECONCILE_WINDOW_HOURS, SWEEP_RECONCILE_LIMIT, SWEEP_RELEASE_LIMIT, SWEEP_WAKE_LIMIT } from "./limits";
import { sweep, type SweepDeps } from "./sweep";
import type { ExecutionStore } from "./types";

// sweep의 순서 · 한도 · 실패 격리 (가짜 store). 실제 SQL과의 흐름은 tests/db/execution-executor.test.ts가 본다.

const NOW = new Date("2026-10-02T00:00:00Z");
const found = (costUsd: number): GenerationLookup => ({
  status: "found",
  generation: { id: "g", model: "m", costUsd, provider: null, promptTokens: null, completionTokens: null, reasoningTokens: null, cancelled: null, createdAt: "" },
});

function deps(overrides: Partial<ExecutionStore> = {}, extra: Partial<SweepDeps> = {}) {
  const order: string[] = [];
  const store = {
    sweepExpire: vi.fn(async () => (order.push("expire"), 2)),
    unconfirmedUsage: vi.fn(async () => (order.push("unconfirmed"), [
      { id: 1, generation_id: "gen-1" },
      { id: 2, generation_id: "gen-2" },
      { id: 3, generation_id: "gen-3" },
    ])),
    reconcileUsage: vi.fn(async (id: number) => (order.push(`reconcile:${id}`), true)),
    openEndedCreditRuns: vi.fn(async () => (order.push("open-ended"), ["r1", "r2"])),
    releaseRunCredits: vi.fn(async (runId: string) => (order.push(`release:${runId}`), 1)),
    wakeableRuns: vi.fn(async () => (order.push("wakeable"), ["r3", "r4"])),
    ...overrides,
  } as unknown as ExecutionStore;
  const lookupGeneration = vi.fn(async (id: string) => (id === "gen-2" ? ({ status: "pending" } as const) : found(0.001)));
  const wake = vi.fn(async (runId: string) => runId !== "r4");
  return { order, store, lookupGeneration, wake, value: { store, lookupGeneration, wake, now: () => NOW, ...extra } satisfies SweepDeps };
}

beforeEach(() => vi.spyOn(console, "error").mockImplementation(() => {}));
afterEach(() => vi.restoreAllMocks());

describe("sweep", () => {
  it("① lease 만료 → ② 미확정 원가 확정(행마다 RPC 한 번) → ③ 끝난 run의 예약(run마다 RPC 한 번) → ④ 깨우기. 단계를 직접 돌리지 않는다", async () => {
    const d = deps();
    expect(await sweep(d.value)).toEqual({ expired: 2, reconciled: 2, released: 2, woken: 1, wake_failed: 1, errors: 0 });
    expect(d.order).toEqual(["expire", "unconfirmed", "reconcile:1", "reconcile:3", "open-ended", "release:r1", "release:r2", "wakeable"]);
    expect(d.store.reconcileUsage).toHaveBeenCalledWith(1, 0.001);
    expect(d.store.unconfirmedUsage).toHaveBeenCalledWith(SWEEP_RECONCILE_LIMIT, new Date(NOW.getTime() - RECONCILE_WINDOW_HOURS * 3_600_000));
    expect(d.store.openEndedCreditRuns).toHaveBeenCalledWith(SWEEP_RELEASE_LIMIT);
    expect(d.store.wakeableRuns).toHaveBeenCalledWith(SWEEP_WAKE_LIMIT);
    expect(d.wake.mock.calls).toEqual([["r3"], ["r4"]]);
  });

  it("generation 조회가 실패한 행은 건너뛰고 다음 sweep에 다시 본다", async () => {
    const d = deps();
    d.lookupGeneration.mockRejectedValueOnce(new Error("generation 조회 실패 (500)"));
    expect((await sweep(d.value)).reconciled).toBe(1);
    expect(d.store.reconcileUsage).toHaveBeenCalledTimes(1);
    expect(d.store.reconcileUsage).toHaveBeenCalledWith(3, 0.001);
  });

  it("한 단계가 실패해도 다음 단계는 한다 (실패 수만 센다, 로그에 숫자 · 단계 이름만)", async () => {
    const d = deps({
      sweepExpire: vi.fn(async () => {
        throw new Error("connection reset");
      }),
      releaseRunCredits: vi.fn(async () => {
        throw Object.assign(new Error("deadlock detected"), { code: "40P01" });
      }),
    });
    const result = await sweep(d.value);
    expect(result).toMatchObject({ expired: 0, reconciled: 2, released: 0, woken: 1, errors: 2 });
    expect(d.wake).toHaveBeenCalledTimes(2);
  });
});
