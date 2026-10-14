import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { ACTION_CREATE_LIMIT, ASK_LIMIT, BRIDGE_REGISTER_LIMIT, CONNECTION_START_LIMIT, MISSING_REPORT_LIMIT, RateLimitedError, retryAfterSeconds, takeBridgeRegistrationLimit, takeBridgeRequestLimit, takeBridgeDecisionPreflightLimit } from "./rate-limit";

// 세기 · 기록 자체는 DB 함수(take_rate_limit)가 한다: tests/db/rate-limits.test.ts

describe("retryAfterSeconds", () => {
  const now = new Date("2026-09-27T03:00:00Z");

  it("다시 할 수 있는 시각까지 남은 초를 올림한다", () => {
    expect(retryAfterSeconds(new Date(now.getTime() + 300_000), now)).toBe(300);
    expect(retryAfterSeconds(new Date(now.getTime() + 1_200), now)).toBe(2);
  });

  it("이미 지났거나 바로면 1초", () => {
    expect(retryAfterSeconds(now, now)).toBe(1);
    expect(retryAfterSeconds(new Date(now.getTime() - 5_000), now)).toBe(1);
  });
});

describe("bridge registration limit", () => {
  it("uses the existing atomic limiter for 20 registrations per hour", async () => {
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: null }) }));
    expect(BRIDGE_REGISTER_LIMIT).toEqual({ max: 20, windowMs: 3_600_000 });
    await takeBridgeRegistrationLimit({ rpc } as unknown as SupabaseClient, "user");
    expect(rpc).toHaveBeenCalledExactlyOnceWith("take_rate_limit", { p_user_id: "user", p_kind: "bridge_register", p_max: 20, p_window_seconds: 3600 });
  });
  it("preserves the database retry time and database failures", async () => {
    const retryAt = new Date("2026-10-14T03:00:00Z");
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: retryAt.toISOString() }) }));
    await expect(takeBridgeRegistrationLimit({ rpc } as unknown as SupabaseClient, "user")).rejects.toEqual(new RateLimitedError(retryAt));
    const failure = new Error("database unavailable");
    const failed = { rpc: () => ({ throwOnError: async () => { throw failure; } }) } as unknown as SupabaseClient;
    await expect(takeBridgeRegistrationLimit(failed, "user")).rejects.toBe(failure);
  });
});

describe("한도", () => {
  it("누락 신고 10분 10번 · 물어보기 10분 20번 · 연결 시작 10분 10번 · 직접 추가 10분 30번", () => {
    expect(MISSING_REPORT_LIMIT).toEqual({ max: 10, windowMs: 600_000 });
    expect(ASK_LIMIT).toEqual({ max: 20, windowMs: 600_000 });
    expect(CONNECTION_START_LIMIT).toEqual({ max: 10, windowMs: 600_000 });
    expect(ACTION_CREATE_LIMIT).toEqual({ max: 30, windowMs: 600_000 });
  });
});

describe("per-device bridge request limits", () => {
  it.each([["bridge_events", 120], ["bridge_ack", 240], ["bridge_poll", 90], ["bridge_decide", 600]] as const)("limits %s to %s per minute", async (kind, max) => {
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: null }) }));
    await takeBridgeRequestLimit({ rpc } as unknown as SupabaseClient, "user", "bridge", kind);
    expect(rpc).toHaveBeenCalledExactlyOnceWith("take_rate_limit", { p_user_id: "user", p_bridge_id: "bridge", p_kind: kind, p_max: max, p_window_seconds: 60 });
  });
  it("preserves retry timestamp and database errors", async () => {
    const retry = "2026-10-14T03:00:00Z";
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: retry }) }));
    await expect(takeBridgeRequestLimit({ rpc } as unknown as SupabaseClient, "user", "bridge", "bridge_events")).rejects.toEqual(new RateLimitedError(new Date(retry)));
    const error = new Error("unavailable");
    const failed = { rpc: () => ({ throwOnError: async () => { throw error; } }) } as unknown as SupabaseClient;
    await expect(takeBridgeRequestLimit(failed, "user", "bridge", "bridge_poll")).rejects.toBe(error);
  });
});

it("decision preflight limits locally per user/device and renews after a minute", () => {
  const now = 2000000000000;
  for (let n = 0; n < 600; n++) expect(takeBridgeDecisionPreflightLimit("preflight-user", "device", now)).toBeNull();
  expect(takeBridgeDecisionPreflightLimit("preflight-user", "device", now + 1)).toEqual(new Date(now + 60000));
  expect(takeBridgeDecisionPreflightLimit("other-user", "device", now + 1)).toBeNull();
  expect(takeBridgeDecisionPreflightLimit("preflight-user", "other-device", now + 1)).toBeNull();
  expect(takeBridgeDecisionPreflightLimit("preflight-user", "device", now + 60000)).toBeNull();
});
