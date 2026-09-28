import { describe, expect, it } from "vitest";

import { daysUntil, rankNow, type RankInput } from "./rank";

// 2025-09-24 수요일 10시 (한국 시간)
const now = new Date("2025-09-24T10:00:00+09:00");
const action = (id: string, over: Partial<RankInput> = {}): RankInput => ({
  id,
  title: id,
  owner: "me",
  status: "open",
  due_date: null,
  counterpart: null,
  needs_confirmation: false,
  started_at: null,
  last_activity_at: "2025-09-24T00:00:00Z",
  ...over,
});

describe("daysUntil", () => {
  it("한국 시간 날짜로 센다", () => {
    expect(daysUntil("2025-09-24", now)).toBe(0);
    expect(daysUntil("2025-09-26", now)).toBe(2);
    expect(daysUntil("2025-09-22", now)).toBe(-2);
    // UTC로는 9/23 밤이지만 한국 시간으로는 9/24
    expect(daysUntil("2025-09-24", new Date("2025-09-23T16:00:00Z"))).toBe(0);
  });
});

describe("rankNow", () => {
  it("지난 기한 > 오늘 > 곧 > 먼 기한 순, 상대가 있는 일을 먼저", () => {
    const { now: list } = rankNow(
      [
        action("far", { due_date: "2025-10-20" }),
        action("soon-mine", { due_date: "2025-09-26" }),
        action("soon-external", { due_date: "2025-09-26", counterpart: "김대표" }),
        action("today", { due_date: "2025-09-24" }),
        action("overdue", { due_date: "2025-09-22" }),
      ],
      now,
    );
    expect(list.map((a) => a.id)).toEqual(["overdue", "today", "soon-external", "soon-mine", "far"]);
    expect(list[0].reasons).toEqual(["overdue"]);
    expect(list[2].reasons).toEqual(["due_soon", "external"]);
  });

  it("오래 방치한 기한 없는 일은 올라온다", () => {
    const { now: list } = rankNow(
      [action("fresh"), action("stale", { last_activity_at: "2025-09-10T00:00:00Z" })],
      now,
    );
    expect(list.map((a) => a.id)).toEqual(["stale", "fresh"]);
    expect(list[0].reasons).toContain("neglected");
  });

  it("확인 요청은 따로, 끝났거나 남에게 넘어간 일은 뺀다", () => {
    const result = rankNow(
      [
        action("ask", { needs_confirmation: true }),
        action("done", { status: "done" }),
        action("theirs", { owner: "other" }),
        action("unknown-owner", { owner: "unknown", needs_confirmation: true }),
        action("mine"),
      ],
      now,
    );
    expect(result.now.map((a) => a.id)).toEqual(["mine"]);
    expect(result.confirmations.map((a) => a.id).sort()).toEqual(["ask", "unknown-owner"]);
  });
});
