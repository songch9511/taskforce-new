import "server-only";

import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { ActionSummary, EditActionRequest, HandoffResponse } from "@/lib/api/contract";

import { loadClaims, loadStoredRow, retryOnConflict, writeAction } from "./db-store";
import { quoteContext } from "@/lib/pipeline/text";

import { buildHandoff, HANDOFF_LIMITS, type HandoffEvidence, type HandoffInput, type HandoffUserEdit } from "./handoff";
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
  // 확인 요청에 "아니에요"로 답한 것이기도 하다: 남아 있던 확인 이유를 지운다.
  return applyUserChanges(admin, userId, actionId, () => [{ field: "status", value: "dropped" }], "user_deleted", { clearReasons: true });
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

/**
 * AI에게 넘기기: 사용자 권한(RLS)으로 Action · 근거 · 원문 정보를 읽어 문서를 만들고, 서버가 handoff_used 지표를 남긴다 (지표 2).
 * 원문 전체가 아니라 근거 인용만 담는다.
 */
export async function handoffAction(client: SupabaseClient, admin: SupabaseClient, userId: string, actionId: string): Promise<HandoffResponse> {
  const { data: action } = await client
    .from("actions")
    .select("title, owner, status, due_date, counterpart, confirm_reasons, resolution")
    .eq("id", actionId)
    .maybeSingle()
    .throwOnError();
  if (!action) throw new ActionNotFoundError();

  const [{ data: evidence, count: evidenceCount }, { data: edits }] = await Promise.all([
    // 최근 근거만 읽는다 (근거가 많아도 문서 · 요청 크기가 커지지 않게)
    client
      .from("evidence")
      .select("quote, role, source_id", { count: "exact" })
      .eq("action_id", actionId)
      .order("created_at", { ascending: false })
      .limit(HANDOFF_LIMITS.evidence)
      .throwOnError(),
    client.from("claims").select("field, value, occurred_at").eq("action_id", actionId).eq("origin", "user").throwOnError(),
  ]);
  const evidenceRows = (evidence ?? []) as { quote: string; role: HandoffEvidence["role"]; source_id: string }[];
  const sourceIds = [...new Set(evidenceRows.map((e) => e.source_id))];
  const { data: sources } = sourceIds.length
    ? await client.from("sources").select("id, kind, title, raw_text, occurred_at, external_url").in("id", sourceIds).throwOnError()
    : { data: [] };
  type SourceRow = { id: string; kind: string; title: string | null; raw_text: string; occurred_at: string; external_url: string | null };
  const sourceById = new Map(((sources ?? []) as SourceRow[]).map((s) => [s.id, s]));

  const input: HandoffInput = {
    action: action as HandoffInput["action"],
    evidence: evidenceRows.flatMap((e) => {
      const s = sourceById.get(e.source_id);
      if (!s) return [];
      const context = quoteContext(s.raw_text, e.quote, HANDOFF_LIMITS.contextLines, HANDOFF_LIMITS.quoteChars);
      return [{ quote: e.quote, context, role: e.role, source: { kind: s.kind, title: s.title, occurredAt: s.occurred_at, url: s.external_url } }];
    }),
    olderEvidence: Math.max(0, (evidenceCount ?? 0) - evidenceRows.length),
    userEdits: ((edits ?? []) as { field: HandoffUserEdit["field"]; value: string | null; occurred_at: string }[]).map((c) => ({
      field: c.field,
      value: c.value,
      occurredAt: c.occurred_at,
    })),
  };
  const markdown = buildHandoff(input);

  // 지표 2(착수 시간): app_opened → 첫 action_started / handoff_used
  await admin.from("metric_events").insert({ user_id: userId, type: "handoff_used", action_id: actionId }).throwOnError();
  return { action_id: actionId, title: input.action.title, markdown };
}
