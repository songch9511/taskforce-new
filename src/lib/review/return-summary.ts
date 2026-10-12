import "server-only";

import { createHash } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { CHANGE_EVENT_TYPES, changesAfterSeen } from "@/lib/actions/changed";
import type { ActionProgressState, PendingDecisionKind, ReturnSummaryChange, ReturnSummaryItem, ReturnSummaryResponse } from "@/lib/api/contract";
import { loadPendingDecisions, PENDING_KINDS, type PendingGroup } from "@/lib/coordinator/pending";

import { decodeCursor, encodeCursor, isDigest, isMicroTimestamp } from "./cursor";
import { RESULT_READY_OUTCOMES, RETURN_SUMMARY_MAX_WORKS } from "./review.config";

// 복귀 요약 (런타임 계약 1장 "복귀 요약", V04 · ARCH25 · A40): 떠나 있던 동안 바뀐 것 · 필요한 결정 · 다음 행동을 **기존 이벤트에서 그때그때 계산**한다.
//  - 새 영구 원문 · 요약 저장소가 없다. 쓰는 것은 Clear 위치(시각 하나)뿐이다. 응답에는 id · 토큰 · 시각 · 지금 제목만 있고 원문 글 · 옛 제목 · 변경 전후 값이 없다.
//  - 변화의 의미는 changed.ts와 같다: 사용자 자기 수정 · 본 것 이전 변화는 변화가 아니다 (changesAfterSeen). 이미 읽은 변화를 다시 올리지 않는다.
//  - inbox_events(C2)는 읽지 않는다: 적재 실패 누락이 있어 완전성 · 신선도의 근거가 못 된다. 실제 원천 표를 읽는다.
//  - 어떤 원천이든 읽기에 실패하면 그 부분은 "unavailable"이지 비어 있는 것이 아니다. 잘리면 truncated + 커서 없음. empty는 모든 원천을 읽었고 잘리지 않았을 때만 참이다.
//  - 읽기와 Clear 어느 쪽도 Action · Claim · 근거 · run · 승인 · 정책을 바꾸지 않는다 (읽음은 결정이 아니다).

// ─── SQL return_summary_scan 응답 (외부 응답처럼 zod로 검증한다) ────────────────────

const scanChangeSchema = z.object({
  source: z.enum(["action_event", "run", "message"]),
  kind: z.string().regex(/^[a-z][a-z0-9_]{0,63}$/),
  at: z.string().refine(isMicroTimestamp),
  detail: z.string().regex(/^[a-z][a-z0-9_]{0,63}$/).nullable(),
  source_state: z.enum(["available", "deleted", "access_lost", "text_expired"]).nullable(),
});

const scanWorkSchema = z.object({
  action_id: z.uuid(),
  title: z.string(),
  status: z.enum(["open", "done", "dropped"]),
  started: z.boolean(),
  last_user_at: z.string().refine(isMicroTimestamp).nullable(),
  changes: z.array(scanChangeSchema),
});

export const scanResultSchema = z.object({
  since: z.string().refine(isMicroTimestamp).nullable(),
  horizon: z.string().refine(isMicroTimestamp),
  digest: z.string().refine(isDigest),
  truncated: z.boolean(),
  works: z.array(scanWorkSchema),
});
export type ScanResult = z.infer<typeof scanResultSchema>;
export type ScanWork = z.infer<typeof scanWorkSchema>;

// ─── 읽기 ────────────────────────────────────────────────

/** 후보 사건을 한 스냅샷에서 읽는다 (아무것도 쓰지 않는다). horizon을 정하면 그 시각까지(시험 · 재현), 아니면 DB 시각 */
export async function scanReturnSummary(admin: SupabaseClient, userId: string, horizon?: string): Promise<ScanResult> {
  const args: Record<string, unknown> = { p_user_id: userId, p_change_types: [...CHANGE_EVENT_TYPES], p_limit: RETURN_SUMMARY_MAX_WORKS };
  if (horizon !== undefined) args.p_now = horizon;
  const { data } = await admin.rpc("return_summary_scan", args).throwOnError();
  return scanResultSchema.parse(data);
}

// ─── 계산 (순수) ─────────────────────────────────────────

const PENDING_ORDER = new Map<string, number>(PENDING_KINDS.map((kind, index) => [kind, index]));
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

function progressState(work: { status: ScanWork["status"]; started: boolean }): ActionProgressState | null {
  if (work.status === "done") return "done";
  if (work.status === "dropped") return null;
  return work.started ? "in_progress" : "to_do";
}

/** 줄의 version: 변화 · 결정 · version이 하나라도 바뀌면 달라진다 */
function itemVersion(changes: readonly ReturnSummaryChange[], decisions: readonly { id: string; version: string }[]): string {
  const body = JSON.stringify({ c: changes.map((c) => [c.source, c.kind, c.at, c.detail, c.source_state]), d: decisions.map((d) => [d.id, d.version]) });
  return createHash("sha256").update(body).digest("hex").slice(0, 16);
}

/** 결정 대기가 있는데 복귀 요약 변화에는 없는 작업의 최소 정보 (제목 · 상태) */
export type ActionBasics = { id: string; title: string; status: ScanWork["status"]; started: boolean };

export function buildReturnSummaryItems(input: {
  works: readonly ScanWork[];
  /** null = 결정 대기를 읽지 못함 (결정 정보 없이 변화만) */
  pending: readonly PendingGroup[] | null;
  /** 변화는 없지만 결정 대기가 있는 작업의 제목 · 상태 */
  basics: ReadonlyMap<string, ActionBasics>;
}): ReturnSummaryItem[] {
  const pendingByAction = new Map<string, PendingGroup[]>();
  for (const group of input.pending ?? []) {
    const list = pendingByAction.get(group.actionId);
    if (list) list.push(group);
    else pendingByAction.set(group.actionId, [group]);
  }

  const rows = new Map<string, { title: string; status: ScanWork["status"]; started: boolean; changes: ReturnSummaryChange[] }>();
  for (const work of input.works) {
    // action_event 변화는 changed.ts와 같은 뜻으로 거른다 (사용자의 마지막 손길 이후만). run · 메시지 변화는 SQL이 읽음 기준(Clear 위치 · last_read_at)으로 이미 걸렀다
    const unreadEvents = changesAfterSeen(
      work.changes.filter((c) => c.source === "action_event").map((change) => ({ change, created_at: change.at })),
      work.last_user_at,
    ).map((entry) => entry.change);
    const changes = [...unreadEvents, ...work.changes.filter((c) => c.source !== "action_event")].sort(
      (a, b) => cmp(a.at, b.at) || cmp(a.source, b.source) || cmp(a.kind, b.kind),
    );
    if (changes.length === 0 && !pendingByAction.has(work.action_id)) continue;
    rows.set(work.action_id, { title: work.title, status: work.status, started: work.started, changes });
  }
  for (const actionId of pendingByAction.keys()) {
    if (rows.has(actionId)) continue;
    const basics = input.basics.get(actionId);
    // 이름을 댈 수 없는 작업(방금 지워짐 등)은 줄로 만들지 않는다: 존재를 지어내지 않는다
    if (basics) rows.set(actionId, { title: basics.title, status: basics.status, started: basics.started, changes: [] });
  }

  const entries: { item: ReturnSummaryItem; latest: string }[] = [];
  for (const [actionId, row] of rows) {
    const groups = (pendingByAction.get(actionId) ?? []).slice().sort((a, b) => (PENDING_ORDER.get(a.kind) ?? 99) - (PENDING_ORDER.get(b.kind) ?? 99));
    const decisions = groups.flatMap((g) => g.items.map((i) => ({ id: i.id, kind: i.kind as PendingDecisionKind, version: i.version, urgent: i.urgent })));
    const decisionKinds = [...new Set(groups.map((g) => g.kind as PendingDecisionKind))];
    const resultReady = row.changes.some((c) => c.source === "run" && c.kind === "done" && c.detail !== null && RESULT_READY_OUTCOMES.has(c.detail));
    entries.push({
      item: {
        action_id: actionId,
        title: row.title,
        status: row.status,
        state: progressState(row),
        needs_answer: decisions.length > 0,
        urgent: groups.some((g) => g.urgent),
        decisions,
        changes: row.changes,
        next: decisions.length > 0 ? { kind: "answer", decision_kinds: decisionKinds } : { kind: resultReady ? "review_result" : "open", decision_kinds: [] },
        version: itemVersion(row.changes, decisions),
      },
      latest: row.changes.reduce((max, c) => (c.at > max ? c.at : max), ""),
    });
  }
  // 답할 결정이 있는 것 먼저(긴급이 맨 앞), 그다음 가장 최근 변화 순. 같으면 id (입력 순서와 무관한 안정 순서)
  entries.sort(
    (a, b) =>
      Number(b.item.needs_answer) - Number(a.item.needs_answer) ||
      Number(b.item.urgent) - Number(a.item.urgent) ||
      cmp(b.latest, a.latest) ||
      cmp(a.item.action_id, b.item.action_id),
  );
  return entries.map((entry) => entry.item);
}

/** 읽은 결과 → 응답. 어떤 원천이든 못 읽었으면 complete · empty를 주장하지 않는다 */
export function composeReturnSummary(input: {
  now: Date;
  userId: string;
  scan: ScanResult | null;
  pending: readonly PendingGroup[] | null;
  basics: ReadonlyMap<string, ActionBasics>;
}): ReturnSummaryResponse {
  const { scan, pending } = input;
  const items = buildReturnSummaryItems({ works: scan?.works ?? [], pending, basics: input.basics });
  const changes: ReturnSummaryResponse["sources"]["changes"] = !scan ? "unavailable" : scan.truncated ? "truncated" : "ok";
  const decisions: ReturnSummaryResponse["sources"]["decisions"] = pending ? "ok" : "unavailable";
  const complete = changes === "ok" && decisions === "ok";
  return {
    generated_at: input.now.toISOString(),
    since: scan?.since ?? null,
    baseline: !scan ? "unknown" : scan.since ? "cleared" : "never_cleared",
    // 잘렸거나 변화 원천을 읽지 못했으면 읽음 처리할 범위를 정할 수 없다
    cursor: scan && !scan.truncated ? encodeCursor({ userId: input.userId, since: scan.since, horizon: scan.horizon, digest: scan.digest }) : null,
    complete,
    empty: complete && items.length === 0,
    sources: { changes, decisions },
    items,
  };
}

// ─── 읽기 + 계산 ──────────────────────────────────────────

async function loadActionBasics(admin: SupabaseClient, userId: string, ids: string[]): Promise<Map<string, ActionBasics>> {
  const basics = new Map<string, ActionBasics>();
  for (let i = 0; i < ids.length; i += 100) {
    const { data } = await admin.from("actions").select("id, title, status, started_at").eq("user_id", userId).in("id", ids.slice(i, i + 100)).throwOnError();
    for (const row of (data ?? []) as { id: string; title: string; status: ScanWork["status"]; started_at: string | null }[]) {
      basics.set(row.id, { id: row.id, title: row.title, status: row.status, started: row.started_at !== null });
    }
  }
  return basics;
}

const failureName = (reason: unknown) => (reason instanceof Error ? reason.name : "unknown");

/**
 * 복귀 요약을 계산한다. 변화(스냅샷 하나)와 결정 대기(C2 계산)를 따로 읽고, 어느 쪽이든 실패하면 그 부분을 unavailable로 표시한다 —
 * 비어 있다고 말하지 않는다. 결정 대기는 C2 게이트(COORDINATOR_ENABLED)와 무관하게 실제 원천(SQL coordinator_pending_inputs)에서 계산한다.
 */
export async function loadReturnSummary(admin: SupabaseClient, userId: string, now: Date, options: { horizon?: string } = {}): Promise<ReturnSummaryResponse> {
  const [scanned, decided] = await Promise.allSettled([scanReturnSummary(admin, userId, options.horizon), loadPendingDecisions(admin, userId, now)]);
  if (scanned.status === "rejected") console.error(JSON.stringify({ event: "return_summary_scan_failed", error: failureName(scanned.reason) }));
  if (decided.status === "rejected") console.error(JSON.stringify({ event: "return_summary_pending_failed", error: failureName(decided.reason) }));
  const scan = scanned.status === "fulfilled" ? scanned.value : null;
  let pending: PendingGroup[] | null = decided.status === "fulfilled" ? decided.value : null;

  let basics = new Map<string, ActionBasics>();
  if (pending) {
    const known = new Set((scan?.works ?? []).map((w) => w.action_id));
    const unknown = [...new Set(pending.map((g) => g.actionId))].filter((id) => !known.has(id));
    try {
      if (unknown.length > 0) basics = await loadActionBasics(admin, userId, unknown);
    } catch (error) {
      // 결정이 있는 작업의 이름을 읽지 못했다: 그 결정들을 빼고 "없다"고 하지 않는다
      console.error(JSON.stringify({ event: "return_summary_basics_failed", error: failureName(error) }));
      pending = null;
    }
  }
  return composeReturnSummary({ now, userId, scan, pending, basics });
}

// ─── Clear ───────────────────────────────────────────────

export type ClearOutcome = { status: "cleared"; applied: boolean; clearedThrough: string } | { status: "stale" | "invalid" };

/**
 * 조회가 낸 커서의 범위까지 읽음 처리한다 (읽음일 뿐: 해결 · 승인 · 완료 · 거절이 아니다). 기존 seen 함수(now()를 찍는다)를 쓰지 않는다.
 * 커서가 지금도 같은 사건들을 가리킬 때만 위치를 옮긴다 — 조회 뒤에 생긴 사건은 남고, 늦게 들어온 사건이 있으면 stale(아무것도 쓰지 않음).
 */
export async function clearReturnSummary(admin: SupabaseClient, userId: string, rawCursor: string, horizonNow?: string): Promise<ClearOutcome> {
  const cursor = decodeCursor(rawCursor, userId);
  if (!cursor) return { status: "invalid" };
  const args: Record<string, unknown> = {
    p_user_id: userId,
    p_change_types: [...CHANGE_EVENT_TYPES],
    p_since: cursor.since,
    p_horizon: cursor.horizon,
    p_digest: cursor.digest,
  };
  if (horizonNow !== undefined) args.p_now = horizonNow;
  const { data } = await admin.rpc("return_summary_clear", args).throwOnError();
  const result = z
    .object({ status: z.enum(["cleared", "stale", "invalid"]), applied: z.boolean().optional(), cleared_through: z.string().refine(isMicroTimestamp).optional() })
    .parse(data);
  if (result.status !== "cleared") return { status: result.status };
  if (result.applied === undefined || !result.cleared_through) throw new Error("return_summary_clear: 응답 모양이 틀림");
  return { status: "cleared", applied: result.applied, clearedThrough: result.cleared_through };
}
