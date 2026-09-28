import { describe, expect, it } from "vitest";

import { weeklyCheckEnabled } from "@/lib/env";

import { isAnswerableWeek, weeklyCheckDue } from "./weekly-check";

// 2026-09-27(일) 12:00 KST. 이번 주 월요일은 2026-09-21
const now = new Date("2026-09-27T03:00:00Z");
const base = { enabled: true, firstSourceAt: "2026-09-18T00:00:00Z", answers: [], now };

describe("weeklyCheckDue", () => {
  it("첫 원문이 7일 이상 전이고 이번 주 답이 없으면 이번 주 월요일을 돌려준다", () => {
    expect(weeklyCheckDue(base)).toEqual({ week_start: "2026-09-21" });
  });

  it("꺼져 있거나 원문이 없거나 7일이 안 됐으면 묻지 않는다", () => {
    expect(weeklyCheckDue({ ...base, enabled: false })).toBeNull();
    expect(weeklyCheckDue({ ...base, firstSourceAt: null })).toBeNull();
    expect(weeklyCheckDue({ ...base, firstSourceAt: "2026-09-21T00:00:00Z" })).toBeNull();
  });

  it("이번 주에 답했으면(건너뛰기 포함) 묻지 않고, 지난주에 한 지난주 답은 상관없다", () => {
    expect(weeklyCheckDue({ ...base, answers: [{ week_start: "2026-09-21", answered_at: "2026-09-22T01:00:00Z" }] })).toBeNull();
    expect(weeklyCheckDue({ ...base, answers: [{ week_start: "2026-09-14", answered_at: "2026-09-15T01:00:00Z" }] })).toEqual({ week_start: "2026-09-21" });
  });

  it("주는 한국 시간 월요일에 바뀐다", () => {
    // 2026-09-27(일) 15:30 UTC = 2026-09-28(월) 00:30 KST
    const answers = [{ week_start: "2026-09-21", answered_at: "2026-09-22T01:00:00Z" }];
    expect(weeklyCheckDue({ ...base, now: new Date("2026-09-27T15:30:00Z"), answers })).toEqual({ week_start: "2026-09-28" });
  });

  it("월요일 자정을 넘겨 지난주 카드에 답했으면 이번 주 답으로 보고 다시 묻지 않는다", () => {
    const monday = new Date("2026-09-27T15:30:00Z"); // 2026-09-28(월) 00:30 KST
    // 월요일 00:01 KST(일요일 15:01 UTC)에 지난주(09-21) 질문에 답함
    const lateAnswer = [{ week_start: "2026-09-21", answered_at: "2026-09-27T15:01:00Z" }];
    expect(weeklyCheckDue({ ...base, now: monday, answers: lateAnswer })).toBeNull();
    // 일요일 23:59 KST(14:59 UTC)에 답했으면 지난주 답이므로 이번 주는 묻는다
    const inTime = [{ week_start: "2026-09-21", answered_at: "2026-09-27T14:59:00Z" }];
    expect(weeklyCheckDue({ ...base, now: monday, answers: inTime })).toEqual({ week_start: "2026-09-28" });
    // 이번 주에 한 답이어도 두 주 전 질문이면 이번 주 답이 아니다
    const older = [{ week_start: "2026-09-14", answered_at: "2026-09-27T15:01:00Z" }];
    expect(weeklyCheckDue({ ...base, now: monday, answers: older })).toEqual({ week_start: "2026-09-28" });
  });
});

describe("isAnswerableWeek", () => {
  it("이번 주와 바로 전 주만 받는다", () => {
    expect(isAnswerableWeek("2026-09-21", now)).toBe(true);
    expect(isAnswerableWeek("2026-09-14", now)).toBe(true);
    expect(isAnswerableWeek("2026-09-07", now)).toBe(false);
    expect(isAnswerableWeek("2026-09-28", now)).toBe(false);
    expect(isAnswerableWeek("2026-09-22", now)).toBe(false);
  });
});

describe("weeklyCheckEnabled", () => {
  it("기본은 켜짐, false · 0 · off면 꺼짐", () => {
    expect(weeklyCheckEnabled({})).toBe(true);
    expect(weeklyCheckEnabled({ WEEKLY_CHECK_ENABLED: "true" })).toBe(true);
    expect(weeklyCheckEnabled({ WEEKLY_CHECK_ENABLED: "false" })).toBe(false);
    expect(weeklyCheckEnabled({ WEEKLY_CHECK_ENABLED: " OFF " })).toBe(false);
    expect(weeklyCheckEnabled({ WEEKLY_CHECK_ENABLED: "0" })).toBe(false);
  });
});
