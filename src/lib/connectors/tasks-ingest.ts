import { sameForClaims, type TaskSnapshot } from "@/lib/pipeline/structured";

import type { Connection } from "./types";

// 구조화된 할 일(Notion 할 일 DB 등)을 원문으로 저장하고 처리한다 (docs/INTEGRATIONS.md "Notion 할 일 DB").
// 글 원문(ingest.ts)과 달리 같은 항목의 새 버전도 넣는다. 대신 판정에 쓰는 값이 바뀐 버전만 넣는다.
//
// 규칙
// - 막 바뀐 항목은 기다린다 (settleMinutes, 회의록보다 짧게).
// - 처음 보는 항목은 내 열린 할 일만 넣는다: 남의 일 · 이미 끝난 일을 새 Action으로 만들지 않는다.
// - Action과 이어진 항목은 내 담당에서 빠졌거나 끝났어도 계속 넣는다 (담당 변경 · 완료를 반영해야 한다).
// - 판정에 쓰는 값(제목 · 담당 · 기한 · 상태)이 마지막으로 처리를 마친 버전과 같으면 넣지 않는다 (본문 편집 · 댓글 같은 잡음).
// - 처리를 마치지 못한 버전(실패 · 멈춤)이 다시 오면 그 원문을 다시 처리한다. 새 버전은 마지막으로 처리를 마친 버전과 비교하므로
//   실패한 버전의 변화(예: 완료)도 함께 반영된다.

export type TaskItem = {
  externalId: string;
  /** 같은 항목이 바뀌었는지 가르는 값 (예: last_edited_time) */
  externalVersion: string;
  snapshot: TaskSnapshot;
  /** 이 버전을 마지막으로 고친 사람이 사용자인가 */
  editedByUser: boolean;
  /** 마지막으로 고친 시각 (Claim의 발언 시점) */
  lastEditedAt: Date;
  externalUrl: string | null;
};

export type TaskState = {
  /**
   * 마지막으로 처리를 마친 버전 (비교 기준). 없으면 아직 반영된 적 없는 할 일.
   * snapshot이 null이면 보관 기간(90일)이 지나 원문(structured)이 비워진 버전 — 값을 비교할 수 없어 바뀐 것으로 본다.
   */
  done?: { version: string; snapshot: TaskSnapshot | null };
  /** 처리를 마치지 못한(실패했거나 멈춘) 가장 최근 버전. 같은 버전이 다시 오면 이 원문을 다시 처리한다 */
  retry?: { sourceId: string; version: string };
  /** 지금 처리 중인 버전이 있다 (다른 실행). 이번에는 건너뛴다 */
  inFlight?: boolean;
  /** Action과 이어져 있는가 (action_links) */
  linked: boolean;
};

export type TaskIngestDeps = {
  taskStates: (connection: Connection, externalIds: string[]) => Promise<Map<string, TaskState>>;
  /** 원문을 저장하고 id를 돌려준다. 동시에 같은 버전이 들어와 충돌하면 null */
  insertTaskSource: (connection: Connection, item: TaskItem) => Promise<string | null>;
  /** prev: Action과 이어진 항목의 직전 스냅샷 (없으면 처음 등장으로 처리) */
  processTask: (connection: Connection, sourceId: string, item: TaskItem, prev: TaskSnapshot | null) => Promise<void>;
  /**
   * 처리를 마치지 못한(실패했거나 멈춘) 최근 원문. 페이지가 다시 보이지 않아도(커서가 지나감) 저장한 스냅샷으로 다시 처리한다.
   * 너무 오래된 실패는 포기한다 (한 항목이 매번 실패해도 동기화를 붙잡지 않게).
   */
  pendingTasks: (connection: Connection) => Promise<PendingTask[]>;
};

export type PendingTask = { sourceId: string; item: TaskItem; prev: TaskSnapshot | null };

export type TaskIngestOptions = { now: Date; settleMinutes: number; maxItems: number; deadline?: number };

export const DEFAULT_TASK_INGEST: Omit<TaskIngestOptions, "now"> = { settleMinutes: 5, maxItems: 50 };

export type TaskIngestResult = {
  created: string[];
  /** 막 바뀌었거나 상한 · 시간 한도에 걸려 다음에 다시 볼 항목의 외부 id */
  deferred: string[];
  /** conflict: 같은 버전이 이미 저장돼 있어 넣지 못함 (동시 실행 등) */
  skipped: { settling: number; unchanged: number; notMine: number; overLimit: number; conflict: number };
  /** 처리를 마치지 못했던 버전을 다시 처리한 수 */
  retried: number;
};

/** 처음 보는 할 일 중 새 Action으로 만들 것: 내 담당이고 아직 열려 있다 */
export const isNewOpenTaskForMe = (s: TaskSnapshot) => s.owner === "me" && s.status === "open";

export async function ingestTaskItems(
  connection: Connection,
  items: TaskItem[],
  deps: TaskIngestDeps,
  options: TaskIngestOptions,
): Promise<TaskIngestResult> {
  const result: TaskIngestResult = { created: [], deferred: [], skipped: { settling: 0, unchanged: 0, notMine: 0, overLimit: 0, conflict: 0 }, retried: 0 };
  const settledBefore = options.now.getTime() - options.settleMinutes * 60_000;

  const settled = items.filter((item) => {
    if (item.lastEditedAt.getTime() <= settledBefore) return true;
    result.skipped.settling++;
    result.deferred.push(item.externalId);
    return false;
  });

  const states = await deps.taskStates(connection, settled.map((item) => item.externalId));
  const fresh = settled.filter((item) => {
    const state = states.get(item.externalId);
    if (state?.inFlight) {
      result.deferred.push(item.externalId);
      return false;
    }
    if (state?.retry?.version === item.externalVersion) return true;
    if (state?.done && (state.done.version === item.externalVersion || (state.done.snapshot && sameForClaims(state.done.snapshot, item.snapshot)))) {
      result.skipped.unchanged++;
      return false;
    }
    if (!state?.linked && !isNewOpenTaskForMe(item.snapshot)) {
      result.skipped.notMine++;
      return false;
    }
    return true;
  });

  // 오래된 변경부터 순서대로 (같은 할 일의 변화가 시간순으로 쌓이도록)
  fresh.sort((a, b) => a.lastEditedAt.getTime() - b.lastEditedAt.getTime());
  const batch = fresh.slice(0, options.maxItems);
  for (const item of fresh.slice(options.maxItems)) {
    result.skipped.overLimit++;
    result.deferred.push(item.externalId);
  }

  // 같은 사용자의 병합은 어차피 한 번에 하나씩이라(process.ts) 차례로 처리한다.
  for (const item of batch) {
    if (options.deadline && Date.now() > options.deadline) {
      result.deferred.push(item.externalId);
      continue;
    }
    const state = states.get(item.externalId);
    const retry = state?.retry?.version === item.externalVersion ? state.retry : undefined;
    const sourceId = retry?.sourceId ?? (await deps.insertTaskSource(connection, item));
    if (!sourceId) {
      // 넣지 못한 항목은 다음에 다시 본다: 처음 훑기를 끝났다고 표시하면 이 할 일은 수정되기 전까지 다시 보이지 않는다.
      result.skipped.conflict++;
      result.deferred.push(item.externalId);
      continue;
    }
    await deps.processTask(connection, sourceId, item, state?.linked ? (state.done?.snapshot ?? null) : null);
    if (retry) result.retried++;
    else result.created.push(sourceId);
  }

  // 이번에 보지 못한 항목 중 처리를 마치지 못한 것을 다시 처리한다.
  const seen = new Set(items.map((item) => item.externalId));
  for (const pending of await deps.pendingTasks(connection)) {
    if (seen.has(pending.item.externalId)) continue;
    if (options.deadline && Date.now() > options.deadline) break;
    seen.add(pending.item.externalId);
    await deps.processTask(connection, pending.sourceId, pending.item, pending.prev);
    result.retried++;
  }
  return result;
}
