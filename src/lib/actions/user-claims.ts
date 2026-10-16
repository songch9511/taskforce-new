import type { EditActionRequest } from "@/lib/api/contract";
import type { Claim, ClaimField } from "@/lib/pipeline/resolve";

import type { ActionWrite, StoredRow } from "./db-store";
import { changeEvents, projectAction, type EventDraft, type ProjectedAction, type UserEventType } from "./project";
import { actionRowValues, storedReasons } from "./rows";

// 사용자가 앱에서 고친 값 → Claim (origin: user). 원문이 없고, 판정에서 그 시점까지의 발언보다 우선한다.

export type UserChange = { field: ClaimField; value: string | null };

export function editChanges(edit: EditActionRequest): UserChange[] {
  return [
    ...(edit.title !== undefined ? [{ field: "scope" as const, value: edit.title }] : []),
    ...(edit.due_date !== undefined ? [{ field: "due" as const, value: edit.due_date }] : []),
    ...(edit.status !== undefined ? [{ field: "status" as const, value: edit.status }] : []),
    ...(edit.owner !== undefined ? [{ field: "owner" as const, value: edit.owner }] : []),
  ];
}

/**
 * "확인" 한 번 탭: 지금 보이는 값을 사용자가 맞다고 한 것으로 남긴다.
 * 확인이 필요한 필드는 현재 값을 사용자 Claim으로 다시 적는다. 담당을 아직 모르면 "나" (확인 큐는 내 할 일인지 묻는다).
 */
export function confirmChanges(current: ProjectedAction): UserChange[] {
  const changes: UserChange[] = [];
  if (current.owner === "unknown") changes.push({ field: "owner", value: "me" });
  else if (current.resolution.owner.needsConfirmation) changes.push({ field: "owner", value: current.resolution.owner.value });
  for (const field of ["due", "scope", "status"] as const) {
    if (current.resolution[field].needsConfirmation) changes.push({ field, value: current.resolution[field].value });
  }
  return changes;
}

export function userClaims(changes: UserChange[], now: Date, newId: () => string): Claim[] {
  return changes.map(({ field, value }) => ({
    id: newId(),
    field,
    value,
    occurredAt: now,
    speakerRole: "me",
    certainty: "firm",
    directness: "first_hand",
    audience: "shared",
    channel: "note",
    origin: "user",
  }));
}

/** 사용자가 바꾼 값을 쓰는 이벤트 종류 (착수 · 누락 신고 · 직접 추가는 다른 쓰기다) */
export type UserWriteEvent = Exclude<UserEventType, "user_started" | "user_unstarted" | "user_reported_missing" | "user_created">;

export type UserChangeOptions = {
  clearReasons?: boolean;
  /** 병합으로 사라지는 쪽(user_merged): 각 이벤트의 after에 남는 쪽 Action id를 싣는다 (D4c-2) */
  into?: string;
  /** 병합 Undo: 다시 여는 이벤트(after.status open)의 before에 그때 병합된 남는 쪽 id를 싣는다 (AC3 6.1, D4c-2) */
  undoneInto?: string;
};

/**
 * 사용자가 바꾼 값 → 사용자 Claim · 다시 판정한 행 · 바뀐 필드마다 이벤트 (write_action에 넘길 쓰기). DB 없는 순수 함수다:
 * service.ts userChangeWrite(읽은 행 · Claim으로 쓰기)와 삭제 · 병합 확인(대화 카드)이 같은 계획을 쓴다 — 확인이 삭제 경로와 같은 쓰기가 되게.
 * 조건은 읽은 version(row.version)이고, 어긋나면 write_action이 쓰지 않는다.
 */
export function userChangePlan(
  row: StoredRow,
  claims: Claim[],
  changes: (current: ProjectedAction) => UserChange[],
  event: UserWriteEvent,
  options: UserChangeOptions,
  now: Date,
  newId: () => string,
): ActionWrite {
  const kept = storedReasons(row.confirm_reasons);
  const before = projectAction(row.title, claims, kept);
  const added = userClaims(changes(before), now, newId);
  const after = projectAction(row.title, [...claims, ...added], options.clearReasons ? [] : kept);

  // 필드별로 무엇이 바뀌었는지 남긴다. 확인은 바뀐 게 없어도 한 번 남긴다.
  const events: EventDraft[] =
    event === "user_confirmed"
      ? [{ type: "user_confirmed", before: { confirm_reasons: before.confirm_reasons }, after: { confirm_reasons: after.confirm_reasons }, rule: "user" }]
      : changeEvents(before, after, "updated").map((e) => ({
          ...e,
          type: event,
          rule: "user",
          ...(options.into ? { after: { ...e.after, into: options.into } } : {}),
          ...(options.undoneInto && (e.after as { status?: string } | null)?.status === "open" ? { before: { ...e.before, into: options.undoneInto } } : {}),
        }));

  return {
    expectedVersion: row.version,
    action: actionRowValues(after),
    claims: added,
    evidence: { sourceId: null, quote: null },
    events,
    actor: "user",
  };
}

/**
 * 직접 추가 (POST /api/v1/actions): 사용자가 적은 제목 · 기한과, 사용자가 추가했으니 담당은 나 · 상태는 열림.
 * 값은 모두 사용자 Claim에서 판정한다 (원칙 5). 사용자 Claim만 있으니 확인 요청은 생기지 않는다.
 * AI가 만든 것이 아니므로 created 대신 user_created 하나를 남긴다 (지표 1의 분모에 넣지 않고 지표 4로 센다).
 * after에는 created와 같은 값에 관련 원문(source_id, 없으면 null)을 더한다.
 */
export function userCreatedAction(input: { title: string; dueDate: string | null; sourceId: string | null }, now: Date, newId: () => string) {
  const changes: UserChange[] = [
    { field: "scope", value: input.title },
    { field: "owner", value: "me" },
    { field: "status", value: "open" },
    ...(input.dueDate ? [{ field: "due" as const, value: input.dueDate }] : []),
  ];
  const claims = userClaims(changes, now, newId);
  const projected = projectAction(input.title, claims);
  const [created] = changeEvents(null, projected, "created");
  const event: EventDraft = { ...created, type: "user_created", after: { ...created.after, source_id: input.sourceId }, rule: "user" };
  return { claims, projected, event };
}
