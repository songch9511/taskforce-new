// 바뀜 점 (U1, 순수 함수): 사용자가 마지막으로 본 뒤 사용자가 아닌 주체가 바꾼 할 일.
// GET /api/v1/now가 항목마다 changed로 내려주고, POST /api/v1/actions/:id/seen은 지금 바뀜일 때만 user_seen을 남긴다.
// 사용자 결정(2026-10-03): AI · 다른 사람(원문) · 실행기가 바꾼 것만 센다. 사용자 자신의 수정은 바뀜이 아니다.

import type { AiEventType } from "./project";

export type SeenEvent = {
  action_id: string;
  type: string;
  actor: "ai" | "user" | "agent";
  created_at: string;
};

/**
 * 바뀜으로 치는 이벤트 종류. 주체(actor)가 user가 아닐 때만 센다.
 * - due_changed · scope_changed · owner_changed: 원문으로 기한 · 내용 · 담당이 바뀜 (할 일 DB에서 옮겨 온 값 포함)
 * - merged: 같은 할 일이 다른 원문에서 다시 언급됨, 또는 원문 때문에 확인 요청이 생기거나 풀림 (project.ts withConfirmationChange)
 * - completed · dropped · reopened: 원문의 완료 · 취소 · 다시 열림 신호
 * - artifact_created: 실행 receipt (실행기가 초안을 만듦, actor agent)
 * 치지 않는 것: created(AI가 새로 만든 할 일은 바뀐 것이 아니라 새 할 일), 사용자 이벤트(user_*), 여기 없는 종류(새 종류는 여기 더해야 센다).
 */
export const CHANGE_EVENT_TYPES: ReadonlySet<string> = new Set<string>([
  "due_changed",
  "scope_changed",
  "owner_changed",
  "merged",
  "completed",
  "dropped",
  "reopened",
  "artifact_created",
] satisfies (AiEventType | "artifact_created")[]);

const isChange = (event: SeenEvent) => event.actor !== "user" && CHANGE_EVENT_TYPES.has(event.type);

/**
 * 사용자가 이 할 일을 본 시점: user_seen, 그리고 사용자가 직접 한 쓰기(수정 · 삭제 · 확인 · 착수 · 직접 추가 · 누락 신고 등 actor user).
 * 직접 손댄 할 일은 그때 본 것이다: 확인 요청을 확정하거나 기한을 고친 뒤에도 그 전 AI 변경으로 점이 남지 않는다.
 */
const isSeen = (event: SeenEvent) => event.actor === "user";

/**
 * 한 할 일의 이벤트 → 마지막으로 본 뒤 바뀜이 있나. 본 적이 없으면 처음부터 본다(AI가 만든 뒤 바뀐 적이 있으면 바뀜).
 * 시각이 같으면 본 것으로 본다. 한 트랜잭션에서 남긴 이벤트는 시각이 같아 앞뒤를 가를 수 없다
 * (지금은 AI 변경과 사용자 이벤트를 한 트랜잭션에 쓰는 곳이 없다. 받은 순서와 상관없이 같은 답이 나오게 정해 둔다).
 * 시각은 밀리초까지 본다(DB의 마이크로초는 버린다): 같은 밀리초 안의 변경은 본 것으로 친다.
 */
export function changedSinceSeen(events: readonly SeenEvent[]): boolean {
  let seen = -Infinity;
  let changed = -Infinity;
  for (const event of events) {
    const at = Date.parse(event.created_at);
    if (isSeen(event)) seen = Math.max(seen, at);
    else if (isChange(event)) changed = Math.max(changed, at);
  }
  return changed > seen;
}

/** 여러 할 일의 이벤트 → 바뀐 할 일 id */
export function changedActionIds(events: readonly SeenEvent[]): Set<string> {
  const byAction = new Map<string, SeenEvent[]>();
  for (const event of events) {
    const list = byAction.get(event.action_id);
    if (list) list.push(event);
    else byAction.set(event.action_id, [event]);
  }
  return new Set([...byAction].filter(([, list]) => changedSinceSeen(list)).map(([id]) => id));
}
