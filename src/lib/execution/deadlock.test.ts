import { describe, expect, it, vi } from "vitest";

import { DEADLOCK_BASE_MS, DEADLOCK_RETRIES, isDeadlock, withDeadlockRetry } from "./deadlock";

const deadlock = () => Object.assign(new Error("deadlock detected"), { code: "40P01" });

describe("withDeadlockRetry", () => {
  it("40P01이면 다시 부르고, 성공하면 그 값을 돌려준다", async () => {
    const fn = vi.fn().mockRejectedValueOnce(deadlock()).mockRejectedValueOnce(deadlock()).mockResolvedValue("ok");
    const sleep = vi.fn(async () => {});
    expect(await withDeadlockRetry(fn, { sleep, random: () => 0.5 })).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(3);
    // 기다림은 두 배씩 (흩뜨림 0.5 + 0.5 = 1배)
    expect(sleep.mock.calls).toEqual([[DEADLOCK_BASE_MS], [DEADLOCK_BASE_MS * 2]]);
  });

  it("횟수가 정해져 있다: 처음 + DEADLOCK_RETRIES번 뒤에는 마지막 오류를 낸다", async () => {
    const fn = vi.fn().mockRejectedValue(deadlock());
    await expect(withDeadlockRetry(fn, { sleep: async () => {} })).rejects.toMatchObject({ code: "40P01" });
    expect(fn).toHaveBeenCalledTimes(DEADLOCK_RETRIES + 1);
  });

  it("기다리는 시간은 흩뜨린다 (0.5–1.5배)", async () => {
    const delays: number[] = [];
    const sleep = async (ms: number) => void delays.push(ms);
    await withDeadlockRetry(vi.fn().mockRejectedValueOnce(deadlock()).mockResolvedValue(1), { sleep, random: () => 0 });
    await withDeadlockRetry(vi.fn().mockRejectedValueOnce(deadlock()).mockResolvedValue(1), { sleep, random: () => 0.999 });
    expect(delays[0]).toBe(DEADLOCK_BASE_MS * 0.5);
    expect(delays[1]).toBeCloseTo(DEADLOCK_BASE_MS * 1.499);
  });

  it("교착이 아닌 오류는 다시 부르지 않는다 (다른 함수가 먼저 바꿈 · 제약 위반 등)", async () => {
    const fn = vi.fn().mockRejectedValue(Object.assign(new Error("duplicate key"), { code: "23505" }));
    await expect(withDeadlockRetry(fn, { sleep: async () => {} })).rejects.toThrow("duplicate key");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("isDeadlock은 supabase-js(PostgrestError) · pg 오류의 code만 본다", () => {
    expect(isDeadlock({ code: "40P01", message: "deadlock detected" })).toBe(true);
    expect(isDeadlock(new Error("deadlock detected"))).toBe(false);
    expect(isDeadlock(null)).toBe(false);
    expect(isDeadlock({ code: "40001" })).toBe(false);
  });
});
