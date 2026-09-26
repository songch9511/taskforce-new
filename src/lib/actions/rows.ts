import type { SourceKind } from "@/lib/pipeline/extract";
import type { Claim } from "@/lib/pipeline/resolve";

import type { ProjectedAction } from "./project";

// DB 행 ↔ 도메인 값 변환 (순수 함수, 서버 · 테스트 공용)

export type ClaimRow = {
  id: string;
  field: Claim["field"];
  value: string | null;
  occurred_at: string;
  speaker_role: Claim["speakerRole"];
  certainty: Claim["certainty"];
  directness: Claim["directness"];
  audience: Claim["audience"];
  origin: "source" | "user";
  channel: SourceKind | null;
};

export const CLAIM_COLUMNS = "id, field, value, occurred_at, speaker_role, certainty, directness, audience, origin, channel";

export function claimFromRow(row: ClaimRow): Claim {
  return {
    id: row.id,
    field: row.field,
    value: row.value,
    occurredAt: new Date(row.occurred_at),
    speakerRole: row.speaker_role,
    certainty: row.certainty,
    directness: row.directness,
    audience: row.audience,
    channel: row.channel ?? "note",
    origin: row.origin,
  };
}

export function claimToRow(claim: Claim, userId: string, actionId: string, evidence: { sourceId: string | null; quote: string | null }) {
  return {
    id: claim.id,
    user_id: userId,
    action_id: actionId,
    source_id: evidence.sourceId,
    field: claim.field,
    value: claim.value,
    quote: evidence.quote,
    occurred_at: claim.occurredAt.toISOString(),
    speaker_role: claim.speakerRole,
    certainty: claim.certainty,
    directness: claim.directness,
    audience: claim.audience,
    origin: claim.origin ?? "source",
    channel: claim.channel,
  };
}

/** 판정에서 파생된 이유(다시 계산된다)와 판정 · 병합 단계가 남긴 이유(저장해 둬야 한다)를 가른다. */
const DERIVED_REASONS = new Set(["담당 확인", "기한 확인", "내용 확인", "상태 확인"]);
export const storedReasons = (reasons: string[]) => reasons.filter((r) => !DERIVED_REASONS.has(r));

export const toPgVector = (v: number[]) => `[${v.join(",")}]`;

export function actionRowValues(p: ProjectedAction) {
  return {
    title: p.title,
    owner: p.owner,
    due_date: p.due_date,
    due_at: p.due_at,
    status: p.status,
    needs_confirmation: p.needs_confirmation,
    confirm_reasons: p.confirm_reasons,
    resolution: p.resolution,
  };
}
