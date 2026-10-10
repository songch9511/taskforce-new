import { describe, expect, it } from "vitest";

import { DAILY_REPORT_URL, dailyReportBody, dailyReportPayload, isEmptyReport } from "./payload";

// 일일 보고 알림 내용: 짧은 상태(숫자 + 고정 낱말) + deep link만 (D06).

const zero = { review: 0, overdue: 0, due_today: 0, in_progress: 0 };

describe("dailyReportBody", () => {
  it("0이 아닌 숫자만 정해진 순서로 잇는다", () => {
    expect(dailyReportBody({ review: 2, overdue: 1, due_today: 3, in_progress: 1 })).toBe("2 to review · 1 overdue · 3 due today · 1 in progress");
    expect(dailyReportBody({ ...zero, due_today: 1 })).toBe("1 due today");
    expect(dailyReportBody({ ...zero, review: 4, in_progress: 2 })).toBe("4 to review · 2 in progress");
  });

  it("음수 · 소수 · NaN은 0으로 본다 (숫자 말고는 본문에 들어가지 않는다)", () => {
    expect(dailyReportBody({ review: -1, overdue: 1.5, due_today: Number.NaN, in_progress: 2 })).toBe("2 in progress");
  });
});

describe("isEmptyReport", () => {
  it("모두 0이면 보낼 것이 없다", () => {
    expect(isEmptyReport(zero)).toBe(true);
    expect(isEmptyReport({ ...zero, overdue: 1 })).toBe(false);
  });
});

describe("dailyReportPayload", () => {
  it("상태 · deep link · kind만 싣는다 (action id · 제목 없음)", () => {
    expect(dailyReportPayload({ review: 1, overdue: 0, due_today: 2, in_progress: 0 }, { respectFocus: true })).toEqual({
      aps: {
        alert: { title: "Daily report", body: "1 to review · 2 due today" },
        sound: "default",
        "thread-id": "reports",
        "interruption-level": "active",
      },
      kind: "daily_report",
      url: "taskforce://work",
    });
    expect(DAILY_REPORT_URL).toBe("taskforce://work");
  });

  it("Respect Focus가 켜져 있으면 집중 모드를 뚫는 수준(time-sensitive · critical)을 쓰지 않는다. 끄면 time-sensitive를 요청한다", () => {
    const on = dailyReportPayload({ ...zero, review: 1 }, { respectFocus: true });
    const off = dailyReportPayload({ ...zero, review: 1 }, { respectFocus: false });
    expect(on.aps["interruption-level"]).toBe("active");
    expect(off.aps["interruption-level"]).toBe("time-sensitive");
    for (const payload of [on, off]) expect(JSON.stringify(payload)).not.toContain("critical");
  });
});
