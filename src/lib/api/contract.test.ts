import { describe, expect, it } from "vitest";

import {
  createActionResponseSchema,
  createSourceRequestSchema,
  MAX_SOURCE_TEXT,
  missingReportRequestSchema,
  missingReportResponseSchema,
  nowResponseSchema,
  weeklyCheckRequestSchema,
} from "./contract";

describe("createSourceRequestSchema", () => {
  it("최소 요청은 종류와 원문", () => {
    expect(createSourceRequestSchema.parse({ kind: "meeting", text: "  금요일까지 보내드릴게요 " })).toEqual({
      kind: "meeting",
      text: "금요일까지 보내드릴게요",
    });
  });

  it("시점은 시간대가 붙은 ISO 형식만 받는다", () => {
    expect(createSourceRequestSchema.safeParse({ kind: "note", text: "a", occurred_at: "2026-09-22T10:00:00+09:00" }).success).toBe(true);
    expect(createSourceRequestSchema.safeParse({ kind: "note", text: "a", occurred_at: "2026-09-22 10:00" }).success).toBe(false);
  });

  it.each([
    [{ kind: "chat", text: "a" }],
    [{ kind: "note", text: "   " }],
    [{ kind: "note", text: "a".repeat(MAX_SOURCE_TEXT + 1) }],
    [{ kind: "note", text: "a", external_url: "not a url" }],
  ])("잘못된 요청은 거부한다 %#", (body) => {
    expect(createSourceRequestSchema.safeParse(body).success).toBe(false);
  });
});

describe("missingReportRequestSchema", () => {
  it("구절은 앞뒤 공백을 자르고 1~2000자", () => {
    expect(missingReportRequestSchema.parse({ quote: "  금요일까지 보내드릴게요 " })).toEqual({ quote: "금요일까지 보내드릴게요" });
    expect(missingReportRequestSchema.safeParse({ quote: "   " }).success).toBe(false);
    expect(missingReportRequestSchema.safeParse({ quote: "a".repeat(2001) }).success).toBe(false);
    expect(missingReportRequestSchema.safeParse({}).success).toBe(false);
  });
});

describe("missingReportResponseSchema", () => {
  const action = {
    id: "11111111-1111-4111-8111-111111111111",
    title: "제안서 발송",
    owner: "me",
    status: "open",
    due_date: "2026-09-26",
    counterpart: null,
    needs_confirmation: false,
    confirm_reasons: [],
    started_at: null,
    last_activity_at: "2026-09-22T01:00:00.123456+00:00",
  };

  it("created는 단계, already_tracked는 null", () => {
    expect(missingReportResponseSchema.safeParse({ status: "created", action, stage: "not_extracted" }).success).toBe(true);
    expect(missingReportResponseSchema.safeParse({ status: "already_tracked", action, stage: null }).success).toBe(true);
    expect(missingReportResponseSchema.safeParse({ status: "created", action, stage: "extract" }).success).toBe(false);
  });

  it("직접 추가 응답은 action과 status(created · already_tracked)", () => {
    expect(createActionResponseSchema.safeParse({ action, status: "created" }).success).toBe(true);
    expect(createActionResponseSchema.safeParse({ action, status: "already_tracked" }).success).toBe(true);
    expect(createActionResponseSchema.safeParse({ action }).success).toBe(false);
    expect(createActionResponseSchema.safeParse({ action, status: "duplicate" }).success).toBe(false);
  });
});

describe("weekly check", () => {
  it("요청은 날짜와 yes · no · skipped", () => {
    expect(weeklyCheckRequestSchema.safeParse({ week_start: "2026-09-21", answer: "skipped" }).success).toBe(true);
    expect(weeklyCheckRequestSchema.safeParse({ week_start: "2026-09-21", answer: "maybe" }).success).toBe(false);
    expect(weeklyCheckRequestSchema.safeParse({ week_start: "09/21", answer: "yes" }).success).toBe(false);
  });

  const noFailures = { count: 0, latest_at: null, reason: null };

  it("GET /now 응답에는 weekly_check가 항상 있다 (없으면 null)", () => {
    expect(nowResponseSchema.safeParse({ now: [], confirmations: [], weekly_check: null, failed_sources: noFailures }).success).toBe(true);
    expect(
      nowResponseSchema.safeParse({ now: [], confirmations: [], weekly_check: { week_start: "2026-09-21" }, failed_sources: noFailures }).success,
    ).toBe(true);
    expect(nowResponseSchema.safeParse({ now: [], confirmations: [], failed_sources: noFailures }).success).toBe(false);
  });
});

describe("GET /now failed_sources (W4)", () => {
  const response = (failed_sources: unknown) => nowResponseSchema.safeParse({ now: [], confirmations: [], weekly_check: null, failed_sources });

  it("실패 원문 수 · 마지막 실패 시각 · 까닭이 항상 있다. 까닭은 정해진 코드나 null(기록 전 실패)", () => {
    expect(response({ count: 2, latest_at: "2026-10-02T03:00:00.000Z", reason: "ai_quota" }).success).toBe(true);
    expect(response({ count: 1, latest_at: "2026-09-29T03:00:00.000Z", reason: null }).success).toBe(true);
    // DB의 timestamptz(오프셋 포함) 그대로
    expect(response({ count: 1, latest_at: "2026-10-02T03:00:00.123456+00:00", reason: "ai_timeout" }).success).toBe(true);
    expect(response({ count: 1, latest_at: "yesterday", reason: null }).success).toBe(false);
    expect(response({ count: 1, latest_at: null, reason: "rate_limited" }).success).toBe(false);
    expect(response({ count: -1, latest_at: null, reason: null }).success).toBe(false);
    expect(nowResponseSchema.safeParse({ now: [], confirmations: [], weekly_check: null }).success).toBe(false);
  });
});
