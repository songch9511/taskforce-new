import type { EditActionRequest } from "@/lib/api/contract";
import type { Claim, ClaimField } from "@/lib/pipeline/resolve";

import { changeEvents, projectAction, type EventDraft, type ProjectedAction } from "./project";

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
