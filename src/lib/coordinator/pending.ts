import "server-only";

import { createHash } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import { URGENT_WINDOW_HOURS } from "./coordinator.config";

// 결정 대기 목록 pending_decisions (런타임 계약 6장, A39): 서버가 그때그때 계산하는 값이다. 표도 사용자 API도 없다.
//  - 읽기 · 계산은 해결 · 승인 · Action 완료가 아니다: 이 모듈은 아무것도 쓰지 않는다 (loadPendingDecisions는 읽기 전용 SQL 함수 하나만 부른다).
//  - 같은 (action_id, kind)는 한 묶음이다. 긴급(기한이 긴급 창 안이거나 다른 작업을 막음)은 일일 묶음을 기다리지 않는다.
//  - 항목 version(승인 대상의 단계 version · run outcome · Action version · 질문 id)이 바뀌면 다른 기기에서 처리된 것이라 목록에서 사라지고,
//    옛 version으로 행동하면 stale이다 (matchPendingVersion).
//  - 실제 원천은 coordinator_pending_inputs가 준다: 승인 대기 단계 · run needs_input / review_failed · Action 확인 요청.
//    에이전트 질문 · 열린 제안 · 긴급 창의 막힌 의존은 원천 표가 아직 없어 입력 타입 + fixture로만 있다 (FutureInputs, 연결되지 않았다).

export const PENDING_KINDS = ["approval", "review_failed", "run_input", "confirm", "agent_question", "suggestion", "blocked_dependency"] as const;
export type PendingKind = (typeof PENDING_KINDS)[number];
/** 지금 실제 원천이 있는 종류 */
export const CONNECTED_PENDING_KINDS: readonly PendingKind[] = ["approval", "review_failed", "run_input", "confirm"];

/** 계산의 입력 행 (SQL coordinator_pending_inputs와 FutureInputs의 공통 모양) */
export type PendingInput = {
  kind: PendingKind;
  action_id: string;
  run_id: string | null;
  step_id: string | null;
  question_id?: string | null;
  /** 처리되면 바뀌는 식별: 승인 hash · question id · proposal id에 해당 (런타임 계약 6장) */
  version: string;
  created_at: string | Date;
  due_at: string | Date | null;
  /** 이 결정이 다른 작업을 막는다 (의존의 상대 Action이 기다림). 지금 의존 표가 없어 SQL 원천은 늘 false */
  blocks_other_work?: boolean;
};

/** 아직 연결되지 않은 원천: 호출하는 쪽(fixture)이 직접 넣는다 */
export type FutureInputs = { agentQuestions?: PendingInput[]; openSuggestions?: PendingInput[]; blockedDependencies?: PendingInput[] };

export type PendingItem = {
  id: string;
  kind: PendingKind;
  actionId: string;
  runId: string | null;
  stepId: string | null;
  questionId: string | null;
  version: string;
  urgent: boolean;
  urgentReason: "due_window" | "blocks_other_work" | null;
  createdAt: string;
};

export type PendingGroup = {
  /** `${actionId}:${kind}` — 같은 업무의 같은 종류는 한 묶음 */
  key: string;
  actionId: string;
  kind: PendingKind;
  urgent: boolean;
  /** 묶음 version: 항목 version이 하나라도 바뀌거나 빠지면 달라진다 */
  version: string;
  createdAt: string;
  items: PendingItem[];
};

const KIND_ORDER = new Map(PENDING_KINDS.map((k, i) => [k, i]));
const iso = (value: string | Date) => new Date(value).toISOString();
const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** 긴급: 기한이 지금부터 긴급 창(24시간) 안이거나 이미 지났다, 또는 다른 작업을 막는다 */
export function urgency(input: Pick<PendingInput, "due_at" | "blocks_other_work">, now: Date): { urgent: boolean; reason: PendingItem["urgentReason"] } {
  if (input.blocks_other_work) return { urgent: true, reason: "blocks_other_work" };
  if (input.due_at && new Date(input.due_at).getTime() <= now.getTime() + URGENT_WINDOW_HOURS * 3_600_000) return { urgent: true, reason: "due_window" };
  return { urgent: false, reason: null };
}

const itemId = (input: PendingInput) => `${input.kind}:${input.step_id ?? input.question_id ?? input.run_id ?? input.action_id}`;

/**
 * 입력 행 → 묶음 목록 (순수). 안정 순서: 긴급 묶음이 먼저, 그다음 오래 기다린 묶음, 같으면 종류 · action id · 묶음 키.
 * 같은 item id가 두 번 오면 하나만 남긴다 (한 항목은 version 하나: 사전순으로 큰 쪽 — 입력 순서와 무관한 결정적 규칙).
 * 실제 대기 항목은 하나도 버리지 않는다 (개수 상한 없음): 상한으로 잘린 항목은 호출한 쪽에서 "처리돼 사라진 것"(matchPendingVersion의 gone)과 구별되지 않는다.
 * 입력 순서는 결과에 영향이 없다.
 */
export function computePendingDecisions(input: { rows: PendingInput[]; future?: FutureInputs; now: Date }): PendingGroup[] {
  const all = [...input.rows, ...(input.future?.agentQuestions ?? []), ...(input.future?.openSuggestions ?? []), ...(input.future?.blockedDependencies ?? [])];
  const items = new Map<string, PendingItem>();
  for (const row of all) {
    const u = urgency(row, input.now);
    const item: PendingItem = {
      id: itemId(row),
      kind: row.kind,
      actionId: row.action_id,
      runId: row.run_id,
      stepId: row.step_id,
      questionId: row.question_id ?? null,
      version: row.version,
      urgent: u.urgent,
      urgentReason: u.reason,
      createdAt: iso(row.created_at),
    };
    const previous = items.get(item.id);
    if (!previous || cmp(item.version, previous.version) > 0) items.set(item.id, item);
  }
  const kept = [...items.values()].sort((a, b) => cmp(a.createdAt, b.createdAt) || cmp(a.id, b.id));

  const groups = new Map<string, PendingGroup>();
  for (const item of kept) {
    const key = `${item.actionId}:${item.kind}`;
    const group = groups.get(key) ?? { key, actionId: item.actionId, kind: item.kind, urgent: false, version: "", createdAt: item.createdAt, items: [] };
    group.items.push(item);
    group.urgent ||= item.urgent;
    if (cmp(item.createdAt, group.createdAt) < 0) group.createdAt = item.createdAt;
    groups.set(key, group);
  }
  for (const group of groups.values()) {
    group.items.sort((a, b) => cmp(a.createdAt, b.createdAt) || cmp(a.id, b.id));
    group.version = createHash("sha256").update(group.items.map((i) => `${i.id}@${i.version}`).join("|")).digest("hex").slice(0, 16);
  }
  return [...groups.values()].sort(
    (a, b) =>
      Number(b.urgent) - Number(a.urgent) ||
      cmp(a.createdAt, b.createdAt) ||
      (KIND_ORDER.get(a.kind) ?? 99) - (KIND_ORDER.get(b.kind) ?? 99) ||
      cmp(a.actionId, b.actionId) ||
      cmp(a.key, b.key),
  );
}

/**
 * 다른 기기 / 다른 시점에 본 항목의 현재 상태 (C10): 지금 목록에 같은 id의 같은 version이 있으면 current, id는 있는데 version이 달라졌으면 stale
 * (그 사이 계획 · 확인 대상이 바뀌었다 — 옛 version으로 행동하지 않는다), id가 없으면 gone(처리 · 삭제되어 목록에서 빠졌다).
 */
export function matchPendingVersion(current: PendingGroup[], seen: { itemId: string; version: string }): "current" | "stale" | "gone" {
  for (const group of current) {
    const item = group.items.find((i) => i.id === seen.itemId);
    if (item) return item.version === seen.version ? "current" : "stale";
  }
  return "gone";
}

/** 사용자 한 명의 결정 대기 목록. 읽기만 한다 (SQL coordinator_pending_inputs는 stable). 소유권은 SQL이 user_id로 모든 조인에서 확인한다 */
export async function loadPendingDecisions(admin: SupabaseClient, userId: string, now: Date = new Date(), future?: FutureInputs): Promise<PendingGroup[]> {
  const { data } = await admin.rpc("coordinator_pending_inputs", { p_user_id: userId }).throwOnError();
  return computePendingDecisions({ rows: ((data ?? []) as PendingInput[]).map((r) => ({ ...r, blocks_other_work: false })), future, now });
}
