import type { ReviewDecisionGroup, Suggestion } from "@/lib/api/contract";
import { suggestionKindSchema } from "@/lib/api/contract";
import type { PendingGroup } from "@/lib/coordinator/pending";

// 서버 내부 값 → API 응답 모양 (순수 함수). 응답에는 id · 토큰 · 시각만 있고 글이 없다.

/** 묶음 → 응답. 에이전트 종류(D4b-s)의 ref(agent · result · conflict)는 그 항목에만 옮긴다 — C2 종류에는 키 자체가 없어 JSON이 그대로다 */
export function pendingGroupDto(group: PendingGroup): ReviewDecisionGroup {
  return {
    key: group.key,
    action_id: group.actionId,
    kind: group.kind,
    urgent: group.urgent,
    version: group.version,
    created_at: group.createdAt,
    items: group.items.map((item) => ({
      id: item.id,
      kind: item.kind,
      action_id: item.actionId,
      run_id: item.runId,
      step_id: item.stepId,
      question_id: item.questionId,
      version: item.version,
      urgent: item.urgent,
      urgent_reason: item.urgentReason,
      created_at: item.createdAt,
      ...(item.agent ? { agent: item.agent } : {}),
      ...(item.result ? { result: item.result } : {}),
      ...(item.conflict ? { conflict: item.conflict } : {}),
    })),
  };
}

/** suggestions 표의 한 행(supabase-js / PostgREST가 돌려주는 모양) */
export type SuggestionRow = Record<string, unknown>;

const iso = (value: unknown): string | null => {
  if (value === null || value === undefined) return null;
  const date = new Date(value as string);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
};

/** date 열은 PostgREST가 "YYYY-MM-DD"로 준다 (시험 대역은 ISO 시각으로 줘서 앞 10자만 쓴다) */
const dayOf = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const day = value.slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(day) ? day : null;
};

/** 모르는 kind(이 코드보다 새 서버가 쓴 제안)는 null: 지어서 보여 주지 않는다 */
export function suggestionDto(row: SuggestionRow): Suggestion | null {
  const kind = suggestionKindSchema.safeParse(row.kind);
  if (!kind.success) return null;
  return {
    id: row.id as string,
    kind: kind.data,
    action_id: row.action_id as string,
    run_id: (row.run_id as string | null) ?? null,
    urgent: row.urgent === true,
    state: row.state as Suggestion["state"],
    version: Number(row.version),
    snooze_until: iso(row.snooze_until),
    offered_on: dayOf(row.batch_day),
    created_at: iso(row.created_at) ?? "",
    shown_at: iso(row.shown_at),
  };
}
