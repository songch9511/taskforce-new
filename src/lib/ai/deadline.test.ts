import { afterEach, describe, expect, it, vi } from "vitest";

import { DeadlineExceededError, INTERACTIVE_MAX_DURATION_S, interactiveDeadline, logDeadlineExceeded, remainingMs, RESPONSE_MARGIN_MS } from "./deadline";

describe("사용자가 기다리는 요청의 마감", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("마감은 요청 시작 + 실행 한도 − 응답 여유(8초)", () => {
    expect(RESPONSE_MARGIN_MS).toBe(8_000);
    expect(interactiveDeadline(INTERACTIVE_MAX_DURATION_S, 1_000)).toBe(1_000 + 60_000 - 8_000);
  });

  it("남은 시간: 마감이 없으면 끝이 없다", () => {
    expect(remainingMs(10_000, 4_000)).toBe(6_000);
    expect(remainingMs(undefined, 4_000)).toBe(Infinity);
  });

  it("마감 실패는 셀 수 있게 한 줄 JSON으로 남기고, 사용자 글은 담지 않는다", () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    logDeadlineExceeded("missing", new DeadlineExceededError("jev", "응답 시간 초과 (10초)"), 1_000, 53_500);
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.parse(log.mock.calls[0][0] as string)).toEqual({ event: "deadline_exceeded", route: "missing", stage: "jev", elapsed_ms: 52_500 });
  });
});
