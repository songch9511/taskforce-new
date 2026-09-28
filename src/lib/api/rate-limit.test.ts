import { describe, expect, it } from "vitest";

import { ACTION_CREATE_LIMIT, ASK_LIMIT, CONNECTION_START_LIMIT, MISSING_REPORT_LIMIT, retryAfterSeconds } from "./rate-limit";

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

describe("한도", () => {
  it("누락 신고 10분 10번 · 물어보기 10분 20번 · 연결 시작 10분 10번 · 직접 추가 10분 30번", () => {
    expect(MISSING_REPORT_LIMIT).toEqual({ max: 10, windowMs: 600_000 });
    expect(ASK_LIMIT).toEqual({ max: 20, windowMs: 600_000 });
    expect(CONNECTION_START_LIMIT).toEqual({ max: 10, windowMs: 600_000 });
    expect(ACTION_CREATE_LIMIT).toEqual({ max: 30, windowMs: 600_000 });
  });
});
