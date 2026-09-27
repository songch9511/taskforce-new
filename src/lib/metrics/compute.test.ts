import { describe, expect, it } from "vitest";

import { kstWeek, missed, misjudgment, retention, timeToStart, type ActionEventRow, type MetricEventRow } from "./compute";

const period = { from: new Date("2026-09-21T00:00:00Z"), to: new Date("2026-09-28T00:00:00Z") };

const ev = (actionId: string, type: string, at: string, over: Partial<ActionEventRow> = {}): ActionEventRow => ({
  actionId,
  userId: "u1",
  type,
  actor: type.startsWith("user_") ? "user" : "ai",
  before: null,
  after: null,
  at,
  sourceKind: type.startsWith("user_") ? null : "meeting",
  ...over,
});
const created = (id: string, at = "2026-09-22T01:00:00Z", kind = "meeting") => ev(id, "created", at, { sourceKind: kind });

describe("misjudgment (지표 1)", () => {
  it("AI가 만든 Action 중 사용자가 고치거나 지운 비율, 필드별", () => {
    const m = misjudgment(
      [
        created("a"),
        ev("a", "user_edited", "2026-09-23T00:00:00Z", { before: { due: "2026-09-26" }, after: { due: "2026-09-29" } }),
        created("b"),
        ev("b", "user_deleted", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "dropped" } }),
        created("c"),
        created("d"),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 4, corrected: 2, rate: 0.5 });
    expect(m.byField).toMatchObject({ due: 1, deleted: 1, title: 0 });
  });

  it("완료로 바꾼 것 · 자기가 완료한 것을 되돌린 것은 오판이 아니다. AI가 끝냈다고 본 일을 다시 여는 것은 오판이다", () => {
    const m = misjudgment(
      [
        created("done"),
        ev("done", "user_edited", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        ev("done", "user_edited", "2026-09-23T01:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
        created("reopen"),
        ev("reopen", "completed", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        ev("reopen", "user_edited", "2026-09-24T00:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 2, corrected: 1, byField: { status: 1 }, byStage: { extract: 0, update: 1 } });
  });

  it("단계: 처음 만들 때 정한 값을 고치면 추출, 나중 원문으로 바뀐 값을 고치면 매칭 · 갱신", () => {
    const m = misjudgment(
      [
        created("x"),
        ev("x", "user_edited", "2026-09-23T00:00:00Z", { before: { title: "a" }, after: { title: "b" } }),
        created("y"),
        ev("y", "due_changed", "2026-09-23T00:00:00Z", { before: { due: "2026-09-26" }, after: { due: "2026-09-29" } }),
        ev("y", "user_edited", "2026-09-24T00:00:00Z", { before: { due: "2026-09-29" }, after: { due: "2026-09-26" } }),
      ],
      period,
    );
    expect(m.byStage).toEqual({ extract: 1, update: 1 });
  });

  it("할 일 DB에서 가져온 것 · 기간 밖에 만든 것은 세지 않고, 확인은 오판이 아니다", () => {
    const m = misjudgment(
      [
        created("t", "2026-09-22T01:00:00Z", "task"),
        ev("t", "user_deleted", "2026-09-23T00:00:00Z"),
        created("old", "2026-09-01T00:00:00Z"),
        ev("old", "user_deleted", "2026-09-23T00:00:00Z"),
        created("ok"),
        ev("ok", "user_confirmed", "2026-09-23T00:00:00Z"),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 1, imported: 1, corrected: 0, rate: 0, confirmed: 1 });
  });

  it("만들 때 바로 반영한 것과 확인 요청으로 물은 것을 나눈다 (구분 전 이벤트는 unknown)", () => {
    const m = misjudgment(
      [
        ev("auto", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: false } }),
        ev("auto", "user_edited", "2026-09-23T00:00:00Z", { after: { due: "2026-09-29" } }),
        ev("asked", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: true } }),
        ev("asked", "user_deleted", "2026-09-23T00:00:00Z"),
        created("old"),
      ],
      period,
    );
    expect(m.byConfirmation).toEqual({ auto: { created: 1, corrected: 1 }, asked: { created: 1, corrected: 1 }, unknown: { created: 1, corrected: 0 } });
  });

  it("AI 생성이 없으면 비율은 없음", () => {
    expect(misjudgment([], period).rate).toBeNull();
  });
});

describe("timeToStart (지표 2)", () => {
  const me = (type: string, at: string, userId = "u1"): MetricEventRow => ({ userId, type, actionId: null, at });

  it("열고 한 시간 안의 첫 착수까지 걸린 시간, 다시 열면 새로 센다", () => {
    const m = timeToStart(
      [
        me("app_opened", "2026-09-22T00:00:00Z"),
        me("action_started", "2026-09-22T00:10:00Z"),
        me("handoff_used", "2026-09-22T00:12:00Z"),
        me("app_opened", "2026-09-22T05:00:00Z"),
        me("app_opened", "2026-09-22T09:00:00Z"),
        me("handoff_used", "2026-09-22T09:30:00Z"),
        me("app_opened", "2026-09-23T00:00:00Z", "u2"),
        me("action_started", "2026-09-23T03:00:00Z", "u2"), // 한 시간이 지나 착수로 보지 않는다
      ],
      period,
    );
    expect(m).toEqual({ opens: 4, startedRate: 0.5, medianMinutes: 20 });
  });

  it("연 적이 없으면 비율 · 시간은 없음", () => {
    expect(timeToStart([], period)).toEqual({ opens: 0, startedRate: null, medianMinutes: null });
  });
});

describe("retention (지표 3)", () => {
  it("한국 시간 월요일 기준 주", () => {
    expect(kstWeek("2026-09-27T14:59:00Z")).toBe("2026-09-21"); // 일요일 23:59 KST
    expect(kstWeek("2026-09-27T15:00:00Z")).toBe("2026-09-28"); // 월요일 00:00 KST
  });

  it("첫 활동 주 기준 N주 뒤 활동 비율 (아직 오지 않은 주는 분모에서 뺀다)", () => {
    const opened = (userId: string, at: string) => ({ userId, at });
    const r = retention(
      [opened("u1", "2026-09-08T01:00:00Z"), opened("u1", "2026-09-22T01:00:00Z"), opened("u2", "2026-09-15T01:00:00Z"), opened("u2", "2026-09-16T01:00:00Z")],
      new Date("2026-09-29T00:00:00Z"), // 9/28 주가 진행 중 → 마지막으로 끝난 주는 9/21
      2,
    );
    expect(r.cohortSize).toBe(2);
    expect(r.weeklyActive).toEqual([
      { week: "2026-09-07", users: 1 },
      { week: "2026-09-14", users: 1 },
      { week: "2026-09-21", users: 1 },
    ]);
    // 1주 뒤: u1(9/14 활동 없음) · u2(9/21 활동 없음) → 0 / 2. 2주 뒤: u1만 대상(9/21 활동) → 1 / 1
    expect(r.retention).toEqual([1, 0, 1]);
  });

  it("진행 중인 주는 N주 뒤 판단에 쓰지 않는다 (기간으로 잘린 활동이 아니라 처음 활동부터 본다)", () => {
    const r = retention([{ userId: "u1", at: "2026-09-08T01:00:00Z" }, { userId: "u2", at: "2026-09-15T01:00:00Z" }], new Date("2026-09-23T00:00:00Z"), 1);
    // 이번 주(9/21) 진행 중 → 1주 뒤는 u1(9/14)만 대상, 활동 없음
    expect(r.retention).toEqual([1, 0]);
  });
});

describe("missed (지표 4)", () => {
  it("누락 신고 기능 전에는 측정 전", () => {
    const m = misjudgment([created("a")], period);
    expect(missed([], m, period, false)).toEqual({ reported: 0, rate: null, available: false });
    expect(missed([ev("r", "user_reported_missing", "2026-09-23T00:00:00Z")], m, period, true)).toEqual({ reported: 1, rate: 0.5, available: true });
  });
});
