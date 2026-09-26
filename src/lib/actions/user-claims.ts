import type { EditActionRequest } from "@/lib/api/contract";
import type { Claim, ClaimField } from "@/lib/pipeline/resolve";

import type { ProjectedAction } from "./project";

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
