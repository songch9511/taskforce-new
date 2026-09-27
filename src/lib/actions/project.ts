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
export type UserEventType = "user_edited" | "user_deleted" | "user_confirmed" | "user_started";

export type EventDraft = {
  type: AiEventType | UserEventType;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  /** 적용된 판정 규칙 (예: "rule0+rule4") */
  rule: string | null;
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
    return [{ type: "created", before: null, after: { title: after.title, due: after.due_date, owner: after.owner, status: after.status }, rule: null }];
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
