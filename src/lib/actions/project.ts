import type { EvidenceRole } from "@/lib/pipeline/merge";
import { resolveAction, TRACKER_REASON, USER_REASON, type Claim, type ClaimField, type Resolution } from "@/lib/pipeline/resolve";

// Claim들을 판정해 actions 행에 저장할 값을 만들고, 바뀐 필드마다 ActionEvent를 만든다 (순수 함수).
// actions 행은 계산 결과를 캐시한 것일 뿐이고, 진실의 원천은 claims다.

export type ActionOwner = "me" | "other" | "unknown";
export type ActionStatus = "open" | "done" | "dropped";

export type FieldResolution = Pick<Resolution, "value" | "reason" | "rules" | "pending" | "risks" | "needsConfirmation">;

export type ProjectedAction = {
  title: string;
  owner: ActionOwner;
  due_date: string | null;
  /** 기한 날의 끝 (한국 시간 23:59:59) */
  due_at: string | null;
  status: ActionStatus;
  needs_confirmation: boolean;
  confirm_reasons: string[];
  resolution: Record<ClaimField, FieldResolution>;
};

const FIELD_LABELS: Record<ClaimField, string> = { due: "기한", scope: "내용", owner: "담당", status: "상태" };

function toOwner(value: string | null): ActionOwner {
  if (value === "me") return "me";
  if (value === null || value === "unknown") return "unknown";
  return "other";
}

/**
 * @param storedReasons 판정 · 병합 단계에서 남긴 확인 이유 (예: "판정 확인: NOT_MY_ACTION", "병합 확인 (55%)")
 */
export function projectAction(fallbackTitle: string, claims: Claim[], storedReasons: string[] = []): ProjectedAction {
  const state = resolveAction(claims);
  const owner = toOwner(state.owner.value);
  const derived = [
    ...(owner === "unknown" ? ["담당 확인"] : []),
    ...(Object.keys(FIELD_LABELS) as ClaimField[]).filter((f) => state[f].needsConfirmation).map((f) => `${FIELD_LABELS[f]} 확인`),
  ];
  const reasons = [...new Set([...storedReasons, ...derived])];
  const due = state.due.value;

  return {
    title: state.scope.value ?? fallbackTitle,
    owner,
    due_date: due,
    due_at: due ? `${due}T23:59:59+09:00` : null,
    status: (state.status.value as ActionStatus | null) ?? "open",
    needs_confirmation: reasons.length > 0,
    confirm_reasons: reasons,
    resolution: Object.fromEntries(
      (Object.keys(FIELD_LABELS) as ClaimField[]).map((f) => {
        const { value, reason, rules, pending, risks, needsConfirmation } = state[f];
        return [f, { value, reason, rules, pending, risks, needsConfirmation }];
      }),
    ) as Record<ClaimField, FieldResolution>,
  };
}

export type AiEventType = "created" | "due_changed" | "scope_changed" | "owner_changed" | "merged" | "completed" | "dropped" | "reopened";
// user_unstarted: 착수를 되돌림 (진행 중 → 할 일, before · after: { started_at }). DB 함수 set_action_progress만 남긴다.
export type UserEventType = "user_edited" | "user_deleted" | "user_confirmed" | "user_started" | "user_unstarted" | "user_reported_missing" | "user_created";

export type EventDraft = {
  type: AiEventType | UserEventType;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  /** 적용된 판정 규칙 (예: "rule0+rule4") */
  rule: string | null;
  /** 이 이벤트만 쓰기 전체와 다른 주체일 때 (예: AI가 만든 Action에 붙는 사용자의 누락 신고) */
  actor?: "ai" | "user";
};

const ruleText = (r: FieldResolution) =>
  r.reason === USER_REASON
    ? "user"
    : r.reason === TRACKER_REASON
      ? "tracker"
      : r.rules.length
        ? r.rules.map((n) => `rule${n}`).join("+")
        : null;

/** 저장된 값(before)과 새 판정(after)을 비교해 AI가 바꾼 것마다 이벤트를 만든다. */
export function changeEvents(before: ProjectedAction | null, after: ProjectedAction, evidenceRole: EvidenceRole): EventDraft[] {
  if (!before) {
    // needs_confirmation: 만들 때 확인 요청이었는지. 지표 1에서 자동 반영이 틀린 것과 물어본 것에 "아니에요"한 것을 나눈다.
    const values = { title: after.title, due: after.due_date, owner: after.owner, status: after.status, needs_confirmation: after.needs_confirmation };
    return [{ type: "created", before: null, after: values, rule: null }];
  }
  const events: EventDraft[] = [];
  if (before.due_date !== after.due_date) {
    events.push({ type: "due_changed", before: { due: before.due_date }, after: { due: after.due_date }, rule: ruleText(after.resolution.due) });
  }
  if (before.title !== after.title) {
    events.push({ type: "scope_changed", before: { title: before.title }, after: { title: after.title }, rule: ruleText(after.resolution.scope) });
  }
  if (before.owner !== after.owner) {
    events.push({ type: "owner_changed", before: { owner: before.owner }, after: { owner: after.owner }, rule: ruleText(after.resolution.owner) });
  }
  if (before.status !== after.status) {
    const type = after.status === "done" ? "completed" : after.status === "dropped" ? "dropped" : "reopened";
    events.push({ type, before: { status: before.status }, after: { status: after.status }, rule: ruleText(after.resolution.status) });
  }
  if (events.length === 0 && evidenceRole === "duplicate") {
    events.push({ type: "merged", before: null, after: null, rule: null });
  }
  return events;
}

/**
 * AI가 붙인 원문 때문에 확인 요청 이유가 늘거나 줄면 그 전후를 이벤트에 남긴다.
 * 새 이벤트 종류를 만들지 않고 { needs_confirmation, confirm_reasons }를 그 쓰기의 이벤트 before · after에 얹는다.
 * 값이 바뀐 이벤트(기한 변경 · 완료 등)가 있으면 그 첫 이벤트에 얹어 앱의 변경 이력에 줄이 늘지 않게 하고(이력은 필요한 키만 읽는다),
 * 바뀐 값이 없는 반복이면 그 merged 이벤트에, 이벤트가 하나도 없으면 merged 하나를 만들어 싣는다.
 * 지표 1이 이런 Action을 "만들 때 물었다"가 아니라 "AI가 물음을 풀어 반영했다"(자동)로 세게 한다 (metrics/compute.ts misjudgment).
 * 사용자가 확인해서 푼 것(user_confirmed)은 여기서 다루지 않는다. AI가 붙이는 경로(SupabaseActionStore.append)만 부른다.
 */
export function withConfirmationChange(events: EventDraft[], before: ProjectedAction, after: ProjectedAction): EventDraft[] {
  const reasonsChanged =
    before.confirm_reasons.length !== after.confirm_reasons.length || before.confirm_reasons.some((reason) => !after.confirm_reasons.includes(reason));
  if (before.needs_confirmation === after.needs_confirmation && !reasonsChanged) return events;
  const change = {
    before: { needs_confirmation: before.needs_confirmation, confirm_reasons: before.confirm_reasons },
    after: { needs_confirmation: after.needs_confirmation, confirm_reasons: after.confirm_reasons },
  };
  if (events.length === 0) return [{ type: "merged", ...change, rule: null }];
  const [first, ...rest] = events;
  return [{ ...first, before: { ...first.before, ...change.before }, after: { ...first.after, ...change.after } }, ...rest];
}
