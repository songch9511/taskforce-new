import type { ActionProgressState } from "@/lib/api/contract";

import type { ActionStatus } from "./project";

// 작업 상태 (할 일 · 진행 중 · 완료)는 status와 started_at에서 나온다 (순수 함수).
// 할 일 = 열림 + 착수 전, 진행 중 = 열림 + 착수, 완료 = done. 취소(dropped)는 작업 상태가 없다.

export type ProgressRow = { status: Exclude<ActionStatus, "dropped">; started_at: string | null };

/**
 * 목표 상태로 가려면 무엇을 바꿔야 하나.
 * status: 사용자 Claim으로 바꿀 상태 (null이면 그대로). started: true 착수 · false 착수 되돌리기 · null 그대로.
 * 둘 다 null이면 이미 그 상태다 (아무것도 쓰지 않는다).
 */
export type ProgressPlan = { status: "open" | "done" | null; started: boolean | null };

export function progressPlan(row: ProgressRow, target: ActionProgressState): ProgressPlan {
  // 완료: 착수 시각은 그대로 둔다 (PATCH status done과 같다)
  if (target === "done") return { status: row.status === "done" ? null : "done", started: null };
  // 할 일 · 진행 중은 열린 Action이다. 완료였으면 먼저 다시 연다.
  const status = row.status === "done" ? "open" : null;
  if (target === "to_do") return { status, started: row.started_at ? false : null };
  // 완료 전에 착수했었으면 다시 열기만 해도 진행 중이다 (처음 착수 시각을 지킨다)
  return { status, started: row.started_at ? null : true };
}

export const isNoop = (plan: ProgressPlan) => plan.status === null && plan.started === null;
