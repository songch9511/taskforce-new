import "server-only";

import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import { actionNotesResponseSchema, type ActionNotesRequest, type ActionNotesResponse, type ActionProgressState, type ActionSummary, type EditActionRequest, type HandoffAssessment, type HandoffResponse } from "@/lib/api/contract";
import { readAll } from "@/lib/read-all";
import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";

import { changedActionIds, changedSinceSeen, type SeenEvent } from "./changed";
import { loadClaims, loadStoredRow, retryOnConflict, WriteConflictError, writeAction, writeProgress, type ActionWrite, type StoredRow } from "./db-store";
import { quoteContext } from "@/lib/pipeline/text";

import { buildHandoff, HANDOFF_LIMITS, type HandoffEvidence, type HandoffInput, type HandoffUserEdit } from "./handoff";
import { isNoop, progressPlan } from "./progress";
import { changeEvents, projectAction, type EventDraft, type UserEventType } from "./project";
import { rankNow, type RankInput } from "./rank";
import { actionRowValues, storedReasons, toPgVector } from "./rows";
import { confirmChanges, editChanges, userClaims, userCreatedAction, type UserChange } from "./user-claims";

// 사용자의 쓰기 (수정 · 삭제 · 확인 · 착수 · 작업 상태). 모두 service role로 쓰고 user_id로 범위를 좁힌다.
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

type UserWriteEvent = Exclude<UserEventType, "user_started" | "user_unstarted" | "user_reported_missing" | "user_created">;

/** 사용자가 바꾼 값 → 사용자 Claim · 다시 판정한 행 · 바뀐 필드마다 이벤트 (write_action에 넘길 쓰기) */
async function userChangeWrite(
  admin: SupabaseClient,
  userId: string,
  actionId: string,
  row: StoredRow,
  changes: (current: ReturnType<typeof projectAction>) => UserChange[],
  event: UserWriteEvent,
  options: { clearReasons?: boolean } = {},
): Promise<ActionWrite> {
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

  return {
    expectedVersion: row.version,
    action: actionRowValues(after),
    claims: added,
    evidence: { sourceId: null, quote: null },
    events,
    actor: "user",
  };
}

async function applyUserChanges(
  admin: SupabaseClient,
  userId: string,
  actionId: string,
  changes: (current: ReturnType<typeof projectAction>) => UserChange[],
  event: UserWriteEvent,
  options: { clearReasons?: boolean } = {},
): Promise<ActionSummary> {
  await retryOnConflict(async () => {
    const row = await loadStoredRow(admin, userId, actionId);
    if (!row) throw new ActionNotFoundError();
    const written = await writeAction(admin, userId, actionId, await userChangeWrite(admin, userId, actionId, row, changes, event, options));
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

export type NewUserAction = {
  title: string;
  dueDate: string | null;
  /** 관련 원문과 그 구절 (사용자 권한으로 본인 원문인지 · 구절이 원문에 있는지 먼저 확인한다) */
  source: { id: string; quote: string } | null;
  /** 매칭용 임베딩 (외부 AI 처리 동의 전이면 null, api/create-action.ts) */
  embedding: number[] | null;
};

/**
 * 직접 추가 (POST /api/v1/actions): Action 행 · 사용자 Claim · 근거(원문을 골랐을 때만, created) · user_created 이벤트를
 * 한 트랜잭션(write_action)으로 쓴다. 매칭 없이 새 Action을 만든다 (앱이 먼저 찾아보고 없을 때만 추가한다).
 */
export async function createUserAction(admin: SupabaseClient, userId: string, input: NewUserAction): Promise<ActionSummary> {
  const id = randomUUID();
  const { claims, projected, event } = userCreatedAction({ title: input.title, dueDate: input.dueDate, sourceId: input.source?.id ?? null }, new Date(), randomUUID);
  await writeAction(admin, userId, id, {
    expectedVersion: null,
    action: { ...actionRowValues(projected), counterpart: null, embedding: input.embedding ? toPgVector(input.embedding) : null },
    claims,
    evidence: input.source ? { sourceId: input.source.id, quote: input.source.quote, role: "created" } : { sourceId: null, quote: null },
    events: [event],
    actor: "user",
  });
  return summary(admin, userId, id);
}

/** 착수: 시각 · 이벤트 · 지표를 DB 함수 start_action이 한 트랜잭션으로 쓴다. 열린 Action만. */
export async function startAction(admin: SupabaseClient, userId: string, actionId: string): Promise<ActionSummary> {
  const { error } = await admin.rpc("start_action", { p_user_id: userId, p_action_id: actionId });
  if (error?.code === "P0002") throw new ActionNotFoundError();
  if (error) throw error;
  return summary(admin, userId, actionId);
}

/**
 * 작업 상태 (POST /api/v1/actions/:id/progress): 할 일 · 진행 중 · 완료.
 * 상태(열림 · 완료)는 PATCH status와 같은 사용자 Claim · user_edited 이벤트로, 착수 시각은 start_action(user_started · action_started)
 * 또는 user_unstarted로 바꾼다. 둘을 DB 함수 set_action_progress가 한 트랜잭션으로 써서 "다시 열렸지만 착수는 안 된" 반쪽 상태가 남지 않는다.
 * 이미 그 상태면 아무것도 쓰지 않는다. 취소된(dropped) Action은 작업 상태가 없으므로 없는 것으로 본다.
 */
export async function setActionProgress(admin: SupabaseClient, userId: string, actionId: string, target: ActionProgressState): Promise<ActionSummary> {
  await retryOnConflict(async () => {
    const row = await loadStoredRow(admin, userId, actionId);
    if (!row || row.status === "dropped") throw new ActionNotFoundError();
    const plan = progressPlan({ status: row.status, started_at: row.started_at }, target);
    if (isNoop(plan)) return true;
    const status = plan.status;
    const statusWrite = status ? await userChangeWrite(admin, userId, actionId, row, () => [{ field: "status", value: status }], "user_edited") : null;
    const written = await writeProgress(admin, userId, actionId, row.version, statusWrite, plan.started).catch((error) => {
      // 그 사이 없어졌거나 착수할 수 없는 상태가 됨 (start_action과 같은 P0002)
      throw error?.code === "P0002" ? new ActionNotFoundError() : error;
    });
    return written ? true : null;
  });
  return summary(admin, userId, actionId);
}

/**
 * 지금 할 일: 사용자 권한(RLS)으로 읽고 서버가 순서를 정한다. 항목마다 바뀜(changed, changed.ts)을 붙인다.
 * 바뀜은 순서에 끼어들지 않는다 (rankNow가 정한 순서 · 점수 그대로, 필드 하나를 더할 뿐).
 */
export async function nowList(client: SupabaseClient, now = new Date()) {
  const { data } = await client.from("actions").select(SUMMARY_COLUMNS).eq("status", "open").throwOnError();
  const ranked = rankNow((data ?? []) as (ActionSummary & RankInput)[], now);
  const changed = await changedAmong(client, [...ranked.now, ...ranked.confirmations].map((a) => a.id));
  const mark = <T extends { id: string }>(action: T) => ({ ...action, changed: changed.has(action.id) });
  return { now: ranked.now.map(mark), confirmations: ranked.confirmations.map(mark) };
}

/** /now에서 바뀜 판정용 이벤트 읽기를 기다리는 최대 시간. 넘으면 읽기를 멈추고 모두 바뀌지 않은 것으로 둔다 (목록이 늦어지지 않게) */
export const CHANGED_READ_TIMEOUT_MS = 2_000;

/**
 * 이 Action들의 이벤트 중 바뀜 판정에 쓰는 열만 (사용자 권한, RLS). id는 100개씩 나눠(요청 주소 길이) 1000행씩 끝까지 읽는다.
 * signal이 멈추면 읽기를 끊고 오류를 낸다.
 */
async function loadSeenEvents(client: SupabaseClient, actionIds: string[], signal?: AbortSignal): Promise<SeenEvent[]> {
  const chunks: string[][] = [];
  for (let i = 0; i < actionIds.length; i += 100) chunks.push(actionIds.slice(i, i + 100));
  const lists = await Promise.all(
    chunks.map((ids) =>
      readAll<SeenEvent>((from, to) => {
        const query = client.from("action_events").select("action_id, type, actor, created_at").in("action_id", ids).order("created_at").order("id");
        return (signal ? query.abortSignal(signal) : query).range(from, to);
      }),
    ),
  );
  return lists.flat();
}

/**
 * 바뀜은 곁가지다: 이벤트를 못 읽거나 CHANGED_READ_TIMEOUT_MS 안에 다 읽지 못하면 모두 바뀌지 않은 것으로 두고
 * 목록은 그대로 돌려준다 (failed_sources와 같다).
 */
async function changedAmong(client: SupabaseClient, actionIds: string[]): Promise<Set<string>> {
  if (actionIds.length === 0) return new Set();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CHANGED_READ_TIMEOUT_MS);
  try {
    return changedActionIds(await loadSeenEvents(client, actionIds, controller.signal));
  } catch (error) {
    const message = controller.signal.aborted ? `${CHANGED_READ_TIMEOUT_MS}ms 안에 읽지 못함` : error instanceof Error ? error.message : error;
    console.error("바뀜 조회 실패:", message);
    return new Set();
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 본 것 표시 (POST /api/v1/actions/:id/seen): 사용자 권한(RLS)으로 Action과 이벤트를 읽어, 지금 /now에 바뀜으로 보일 할 일일 때만
 * user_seen(actor user) 한 줄을 남긴다 (service role). 바뀌지 않았으면(이미 봤거나 바뀐 것이 없음 · 지금 할 일 목록에 없는 할 일)
 * 쓰지 않는다: 화살표로 지나가거나 다시 보내도 이벤트가 쌓이지 않는다. actions 행은 고치지 않는다(순서 · 활동 시각 · Realtime 그대로).
 * 없거나 남의 Action이면 ActionNotFoundError. 남겼으면 true.
 */
export async function markActionSeen(client: SupabaseClient, admin: SupabaseClient, userId: string, actionId: string): Promise<boolean> {
  const { data: action } = await client.from("actions").select("status, owner").eq("id", actionId).maybeSingle().throwOnError();
  if (!action) throw new ActionNotFoundError();
  // /now에 오는 할 일만 바뀜이 있다 (열림 + 다른 사람 일이 아님, rank.ts rankNow)
  if (action.status !== "open" || action.owner === "other") return false;
  if (!changedSinceSeen(await loadSeenEvents(client, [actionId]))) return false;
  await admin.from("action_events").insert({ user_id: userId, action_id: actionId, type: "user_seen", actor: "user" }).throwOnError();
  return true;
}

/**
 * Save user-authored Markdown without changing judged Action fields. Ownership is checked with the user's RLS client;
 * the service-role RPC then locks the row and compares the independent notes revision before saving and emitting an event.
 */
export async function saveActionNotes(
  client: SupabaseClient,
  admin: SupabaseClient,
  userId: string,
  actionId: string,
  input: ActionNotesRequest,
): Promise<ActionNotesResponse> {
  const { data: action } = await client.from("actions").select("id").eq("id", actionId).maybeSingle().throwOnError();
  if (!action) throw new ActionNotFoundError();

  const { data } = await admin.rpc("save_action_notes", {
    p_user_id: userId,
    p_action_id: actionId,
    p_markdown: input.markdown,
    p_expected_revision: input.expected_revision,
  }).throwOnError();
  const row = (Array.isArray(data) ? data[0] : data) as { status?: unknown; action_id?: unknown; markdown?: unknown; revision?: unknown } | null;
  if (!row || row.status === "not_found") throw new ActionNotFoundError();
  if (row.status === "conflict") throw new WriteConflictError();
  const parsed = actionNotesResponseSchema.safeParse({ action_id: row.action_id, markdown: row.markdown, revision: row.revision });
  if (!parsed.success) throw new Error("Action notes save returned an invalid response");
  return parsed.data;
}

/**
 * AI에게 넘기기: 사용자 권한(RLS)으로 Action · 근거 · 원문 정보를 읽어 문서를 만들고, 서버가 handoff_used 지표를 남긴다 (지표 2).
 * 원문 전체가 아니라 근거 인용만 담는다.
 */
export async function handoffAction(
  client: SupabaseClient,
  admin: SupabaseClient,
  userId: string,
  actionId: string,
  assist?: (deterministicMarkdown: string) => Promise<{ markdown: string; assessment: HandoffAssessment }>,
): Promise<HandoffResponse> {
  const { data: action } = await client
    .from("actions")
    .select("title, owner, status, due_date, counterpart, confirm_reasons, resolution, notes_markdown")
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
  // Slack 연결을 끊어 지운 인용 자리 표시는 옮기지 않는다 (근거가 아니다)
  const evidenceRows = ((evidence ?? []) as { quote: string; role: HandoffEvidence["role"]; source_id: string }[]).filter(
    (e) => e.quote !== SLACK_DISCONNECTED_QUOTE,
  );
  const sourceIds = [...new Set(evidenceRows.map((e) => e.source_id))];
  const { data: sources } = sourceIds.length
    ? await client.from("sources").select("id, kind, title, raw_text, raw_text_purged_at, occurred_at, external_url").in("id", sourceIds).throwOnError()
    : { data: [] };
  type SourceRow = {
    id: string;
    kind: string;
    title: string | null;
    raw_text: string;
    raw_text_purged_at: string | null;
    occurred_at: string;
    external_url: string | null;
  };
  const sourceById = new Map(((sources ?? []) as SourceRow[]).map((s) => [s.id, s]));

  const input: HandoffInput = {
    action: action as HandoffInput["action"],
    userNotesMarkdown: action.notes_markdown,
    evidence: evidenceRows.flatMap((e) => {
      const s = sourceById.get(e.source_id);
      if (!s) return [];
      // 보관 기간(90일)이 지나 원문 글이 지워졌으면 앞뒤 줄 없이 저장된 근거 인용만 옮긴다.
      const context = s.raw_text_purged_at ? null : quoteContext(s.raw_text, e.quote, HANDOFF_LIMITS.contextLines, HANDOFF_LIMITS.quoteChars);
      return [{ quote: e.quote, context, role: e.role, source: { kind: s.kind, title: s.title, occurredAt: s.occurred_at, url: s.external_url } }];
    }),
    olderEvidence: Math.max(0, (evidenceCount ?? 0) - evidenceRows.length),
    userEdits: ((edits ?? []) as { field: HandoffUserEdit["field"]; value: string | null; occurred_at: string }[]).map((c) => ({
      field: c.field,
      value: c.value,
      occurredAt: c.occurred_at,
    })),
  };
  const deterministicMarkdown = buildHandoff(input);
  // Assisted generation receives only the bounded deterministic document, never raw source rows.
  const generated = assist ? await assist(deterministicMarkdown) : undefined;

  // Successful legacy handoffs and completed assisted drafts both count; failed generation does not.
  await admin.from("metric_events").insert({ user_id: userId, type: "handoff_used", action_id: actionId }).throwOnError();
  return {
    action_id: actionId,
    title: input.action.title,
    markdown: generated?.markdown ?? deterministicMarkdown,
    ...(generated ? { assessment: generated.assessment } : {}),
  };
}
