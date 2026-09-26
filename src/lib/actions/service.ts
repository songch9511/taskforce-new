import "server-only";

import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { ActionSummary, EditActionRequest } from "@/lib/api/contract";

import { loadClaims, loadStoredRow, retryOnConflict, writeAction } from "./db-store";
import { changeEvents, projectAction, type EventDraft, type UserEventType } from "./project";
import { rankNow, type RankInput } from "./rank";
import { actionRowValues, storedReasons } from "./rows";
import { confirmChanges, editChanges, userClaims, type UserChange } from "./user-claims";

// 사용자의 쓰기 (수정 · 삭제 · 확인 · 착수). 모두 service role로 쓰고 user_id로 범위를 좁힌다.
// 사용자가 바꾼 값도 Claim(origin: user)으로 남기고, 바뀐 필드마다 이벤트를 남긴다 (지표 1: AI 오판율).

export class ActionNotFoundError extends Error {
  constructor() {
    super("Action이 없습니다.");
    this.name = "ActionNotFoundError";
  }
}

export const SUMMARY_COLUMNS = "id, title, owner, status, due_date, counterpart, needs_confirmation, confirm_reasons, started_at, last_activity_at";

async function summary(admin: SupabaseClient, userId: string, actionId: string): Promise<ActionSummary> {
  const { data } = await admin.from("actions").select(SUMMARY_COLUMNS).eq("user_id", userId).eq("id", actionId).single().throwOnError();
  return data as ActionSummary;
}

async function applyUserChanges(
  admin: SupabaseClient,
  userId: string,
  actionId: string,
  changes: (current: ReturnType<typeof projectAction>) => UserChange[],
  event: Exclude<UserEventType, "user_started">,
  options: { clearReasons?: boolean } = {},
): Promise<ActionSummary> {
  await retryOnConflict(async () => {
    const row = await loadStoredRow(admin, userId, actionId);
    if (!row) throw new ActionNotFoundError();
    const claims = await loadClaims(admin, userId, actionId);
    const kept = storedReasons(row.confirm_reasons);
    const before = projectAction(row.title, claims, kept);
    const added = userClaims(changes(before), new Date(), randomUUID);
    const after = projectAction(row.title, [...claims, ...added], options.clearReasons ? [] : kept);

    // 필드별로 무엇이 바뀌었는지 남긴다. 확인은 바뀐 게 없어도 한 번 남긴다.
    const events: EventDraft[] =
      event === "user_confirmed"
        ? [{ type: "user_confirmed", before: { confirm_reasons: before.confirm_reasons }, after: { confirm_reasons: after.confirm_reasons }, rule: "user" }]
        : changeEvents(before, after, "updated").map((e) => ({ ...e, type: event, rule: "user" }));

    const written = await writeAction(admin, userId, actionId, {
      expectedVersion: row.version,
      action: actionRowValues(after),
      claims: added,
      evidence: { sourceId: null, quote: null },
      events,
      actor: "user",
    });
    return written ? true : null;
  });
  return summary(admin, userId, actionId);
}

export function editAction(admin: SupabaseClient, userId: string, actionId: string, edit: EditActionRequest) {
  return applyUserChanges(admin, userId, actionId, () => editChanges(edit), "user_edited");
}

/** 삭제는 실제로 지우지 않고 취소(dropped)로 둔다. 근거와 이력은 남는다. */
export function deleteAction(admin: SupabaseClient, userId: string, actionId: string) {
  return applyUserChanges(admin, userId, actionId, () => [{ field: "status", value: "dropped" }], "user_deleted");
}

export function confirmAction(admin: SupabaseClient, userId: string, actionId: string) {
  return applyUserChanges(admin, userId, actionId, confirmChanges, "user_confirmed", { clearReasons: true });
}

/** 착수: 시각 · 이벤트 · 지표를 DB 함수 start_action이 한 트랜잭션으로 쓴다. 열린 Action만. */
export async function startAction(admin: SupabaseClient, userId: string, actionId: string): Promise<ActionSummary> {
  const { error } = await admin.rpc("start_action", { p_user_id: userId, p_action_id: actionId });
  if (error?.code === "P0002") throw new ActionNotFoundError();
  if (error) throw error;
  return summary(admin, userId, actionId);
}

/** 지금 할 일: 사용자 권한(RLS)으로 읽고 서버가 순서를 정한다. */
export async function nowList(client: SupabaseClient, now = new Date()) {
  const { data } = await client.from("actions").select(SUMMARY_COLUMNS).eq("status", "open").throwOnError();
  return rankNow((data ?? []) as (ActionSummary & RankInput)[], now);
}
