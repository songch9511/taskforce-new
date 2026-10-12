import { z } from "zod";

// 코디네이터의 사건 봉투 · 처리 결과 계약 (아키텍처 7.1, 런타임 계약 5장). SQL coordinator_event_types() · result_kind CHECK와 같아야 한다 (테스트가 견준다).

/** 사건 종류 (아키텍처 7.1 입구). 생산자가 붙은 것과 아직 없는 것은 inbox.ts PRODUCERS */
export const INBOX_EVENT_TYPES = [
  "user_message",
  "source_processed",
  "source_revised",
  "reply_observed",
  "agent_event",
  "dependency_changed",
  "memory_changed",
  "timer_due",
  "decision_made",
  "connection_changed",
  "bridge_unreachable",
] as const;
export type InboxEventType = (typeof INBOX_EVENT_TYPES)[number];

/** 처리 결과 종류 (DB result_kind). 성공 한 가지가 아니다: 영향 없음 · 기록 · 증거 있는 stale · 거절 · 판정 못함 · 아직 못 다룸 */
export const RESULT_KINDS = ["no_impact", "impact_recorded", "stale", "rejected", "not_judged", "not_handled"] as const;
export type ResultKind = (typeof RESULT_KINDS)[number];

/**
 * 결과의 근거 종류 (DB result_evidence, 글 없음). 나이(TTL)만으로 만든 근거는 없다 — stale은 DB로 확인한 사실(삭제 · 접근 상실 · 버전 불일치 · 이미 처리됨)뿐이다.
 *  stale: source_deleted · source_access_lost · parent_deleted(메시지 · 행동 · run · 범위가 사라짐) · version_mismatch · already_handled
 *  rejected: unknown_type · invalid_refs · no_owned_refs(가리킨 객체가 모두 남의 것이거나 없다)
 *  not_judged: model_call_unknown(예약만 남고 응답 없음 — 다시 부르지 않는다) · jev_budget_exhausted · ai_budget · consent_missing · model_error · model_output_rejected
 *  not_handled: type_not_connected(생산자가 아직 없는 종류)
 *  impact_recorded / no_impact: deterministic_only · jev_judged · management_judged
 */
export const EVIDENCE_KINDS = [
  "source_deleted",
  "source_access_lost",
  "parent_deleted",
  "version_mismatch",
  "already_handled",
  "unknown_type",
  "invalid_refs",
  "no_owned_refs",
  "model_call_unknown",
  "jev_budget_exhausted",
  "ai_budget",
  "consent_missing",
  "model_error",
  "model_output_rejected",
  "type_not_connected",
  "deterministic_only",
  "jev_judged",
  "management_judged",
] as const;
export type EvidenceKind = (typeof EVIDENCE_KINDS)[number];

const uuid = z.uuid();

/** refs · result_ids에 넣을 수 있는 값: id · 종류 토큰 · 작은 정수 · id 배열 (DB inbox_refs_valid와 같은 모양) */
const idList = z.array(uuid).max(100);
const token = z.string().regex(/^[a-z][a-z0-9_]{0,63}$/);
export const refsSchema = z.record(
  z.string().regex(/^[a-z][a-z0-9_]{0,40}$/),
  z.union([uuid, token, z.number().int().min(0).max(999_999_999), idList]),
);
export type Refs = z.infer<typeof refsSchema>;

/** 적재하는 사건 (생산자의 봉투). 원문 · 발화 글은 담지 않는다 — refs는 id · 종류뿐이다 */
export const envelopeSchema = z.object({
  user_id: uuid,
  type: z.enum(INBOX_EVENT_TYPES),
  dedup_key: z.string().min(1).max(300),
  refs: refsSchema,
});
export type InboxEnvelope = z.infer<typeof envelopeSchema>;

/** coordinator_claim이 돌려주는 집은 사건. claim_token을 가진 소비자만 끝낼 수 있다 */
export type ClaimedEvent = {
  event_id: string;
  user_id: string;
  type: string;
  dedup_key: string;
  refs: Record<string, unknown>;
  created_at: string;
  seq: number | string;
  claim_token: string;
  attempts: number;
  model_calls: number;
  jev_calls: number;
};

/** 영향 후보: 코드가 소유권 · 실제 관계로 고른 객체. 모델은 이 집합 안에서만 고르거나 걸러 낸다 */
export type CandidateKind = "action" | "context" | "run";
export type Candidate = { kind: CandidateKind; id: string; relation: string; certainty: "certain" | "uncertain" };

/** 처리 결과: 이대로 coordinator_finish에 쓴다 (종류 + 근거 종류 + id뿐) */
export type Outcome = {
  kind: ResultKind;
  evidence: EvidenceKind | null;
  ids: { action_ids?: string[]; context_ids?: string[]; run_ids?: string[]; dropped_refs?: number; truncated?: number };
};

export type FinishStatus = "finished" | "already_finished" | "lost_claim";
