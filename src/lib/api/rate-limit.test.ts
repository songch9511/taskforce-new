import { describe, expect, it } from "vitest";

import { MISSING_REPORT_LIMIT, rateLimitedUntil } from "./rate-limit";

const now = new Date("2026-09-27T03:00:00Z");
const minutesAgo = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();
const limit = { max: 3, windowMs: 10 * 60_000 };

describe("rateLimitedUntil", () => {
  it("창 안의 시도가 한도보다 적으면 허용한다", () => {
    expect(rateLimitedUntil([], now, limit)).toBeNull();
    expect(rateLimitedUntil([minutesAgo(1), minutesAgo(2)], now, limit)).toBeNull();
  });

  it("창 밖의 시도는 세지 않는다", () => {
    expect(rateLimitedUntil([minutesAgo(1), minutesAgo(2), minutesAgo(10), minutesAgo(30)], now, limit)).toBeNull();
  });

  it("한도에 찼으면 가장 오래된 시도가 창 밖으로 나가는 시각을 돌려준다 (순서와 상관없이)", () => {
    expect(rateLimitedUntil([minutesAgo(1), minutesAgo(7), minutesAgo(4)], now, limit)).toEqual(new Date(now.getTime() + 3 * 60_000));
    // 한도를 넘게 쌓여 있으면 한도 아래로 내려갈 때까지
    expect(rateLimitedUntil([minutesAgo(1), minutesAgo(2), minutesAgo(3), minutesAgo(9)], now, limit)).toEqual(new Date(now.getTime() + 7 * 60_000));
  });

  it("누락 신고는 10분에 10번까지", () => {
    const nine = Array.from({ length: 9 }, (_, i) => minutesAgo(i));
    expect(rateLimitedUntil(nine, now, MISSING_REPORT_LIMIT)).toBeNull();
    expect(rateLimitedUntil([...nine, minutesAgo(9.5)], now, MISSING_REPORT_LIMIT)).not.toBeNull();
  });
});
