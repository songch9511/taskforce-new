import { describe, expect, it } from "vitest";

import type { ActionProgressState } from "@/lib/api/contract";

import { isNoop, progressPlan, type ProgressRow } from "./progress";

const STARTED = "2026-09-28T01:00:00.000Z";
const toDo: ProgressRow = { status: "open", started_at: null };
const inProgress: ProgressRow = { status: "open", started_at: STARTED };
const doneStarted: ProgressRow = { status: "done", started_at: STARTED };
const doneNeverStarted: ProgressRow = { status: "done", started_at: null };

/** 계획을 적용한 뒤의 작업 상태 (착수는 새 시각, 되돌리기는 null) */
function apply(row: ProgressRow, target: ActionProgressState): ActionProgressState {
  const plan = progressPlan(row, target);
  const status = plan.status ?? row.status;
  const started = plan.started === null ? row.started_at : plan.started ? (row.started_at ?? "now") : null;
  return status === "done" ? "done" : started ? "in_progress" : "to_do";
}

describe("progressPlan", () => {
  it("어느 상태에서든 목표 상태로 간다", () => {
    for (const row of [toDo, inProgress, doneStarted, doneNeverStarted]) {
      for (const target of ["to_do", "in_progress", "done"] as const) expect(apply(row, target)).toBe(target);
    }
  });

  it("이미 그 상태면 아무것도 바꾸지 않는다", () => {
    expect(isNoop(progressPlan(toDo, "to_do"))).toBe(true);
    expect(isNoop(progressPlan(inProgress, "in_progress"))).toBe(true);
    expect(isNoop(progressPlan(doneStarted, "done"))).toBe(true);
    expect(isNoop(progressPlan(doneNeverStarted, "done"))).toBe(true);
  });

  it("진행 중 → 할 일: 착수만 되돌린다", () => {
    expect(progressPlan(inProgress, "to_do")).toEqual({ status: null, started: false });
  });

  it("할 일 → 진행 중: 착수만 한다", () => {
    expect(progressPlan(toDo, "in_progress")).toEqual({ status: null, started: true });
  });

  it("완료 → 할 일: 다시 열고, 착수했었으면 되돌린다", () => {
    expect(progressPlan(doneStarted, "to_do")).toEqual({ status: "open", started: false });
    expect(progressPlan(doneNeverStarted, "to_do")).toEqual({ status: "open", started: null });
  });

  it("완료 → 진행 중: 다시 열고, 착수 전이었으면 착수한다 (착수했었으면 처음 착수 시각을 지킨다)", () => {
    expect(progressPlan(doneNeverStarted, "in_progress")).toEqual({ status: "open", started: true });
    expect(progressPlan(doneStarted, "in_progress")).toEqual({ status: "open", started: null });
  });

  it("완료: 착수 시각은 그대로 둔다", () => {
    expect(progressPlan(toDo, "done")).toEqual({ status: "done", started: null });
    expect(progressPlan(inProgress, "done")).toEqual({ status: "done", started: null });
  });
});
