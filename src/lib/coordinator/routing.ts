import { MAX_JEV_CALLS_PER_EVENT } from "./coordinator.config";
import type { Candidate, InboxEventType } from "./types";

// 라우팅 (순수). 두 가지다.
//  1) 결정 라우팅 표 (런타임 계약 6장 · 아키텍처 7.7): 누가 결정하나 — 사용자만 / 코디네이터가 위임 범위 안에서.
//  2) 모델 계획: 사건 하나에 모델을 부르는가 (사건 없음 · 후보 없음 · 결정적 처리 → 호출 0).
// 이 표는 "누가 결정하는가"를 말할 뿐이다. 코디네이터가 위임 범위 안이라고 해서 이 PR이 무엇을 실행하지는 않는다 (실행은 D1 · E1, 정책은 begin_call).
// 범위(work_contexts) · 기억 · version은 이 표의 입력이 아니다 (ARCH06/07, I04 · I14): 여기엔 권한 · 정책 · 승인 입력이 없다.

export type Decider = "user" | "coordinator";

/** 결정 상황. 이름은 런타임 계약 6장 표의 행 / 아키텍처 7.7의 추가 행이다 */
export const DECISION_CASES = [
  // 사용자만 결정 (런타임 계약 6장 왼쪽)
  "direction_or_taste", // 둘 다 기준을 충족하는 안 중 방향 · 취향 선택
  "external_commitment", // 외부와의 새 약속 (상대에게 말할 기한 · 금액 · 범위)
  "spend_outside_policy", // 정책 · standing 예산 밖 지출
  "new_recipient_or_target", // 새 수신자 · 대상
  "permission_expansion", // 권한 확장
  "change_outside_allowed_scope", // 허용 범위 밖 변경
  "irreversible_not_yet_allowed", // 아직 허용되지 않은 비가역 변경
  "provider_requires_human", // 해당 provider가 명시적으로 사람 확인을 요구하는 동작
  "approval_callback_manual_or_outside_rules", // 공식 승인 콜백 중 Manual이거나 정책 규칙 밖
  "manual_external_change", // 정책이 Manual인 모든 외부 변경
  "infer_memory_confirm", // inferred 기억 · 선호를 explicit로 확정 (7.7)
  "context_merge", // 두 work_context 병합 (7.7)
  "membership_by_user", // 멤버십 변경(user) (7.7)
  "agent_question_not_in_memory", // 에이전트 질문 중 기억에 없는 취향 · 방향 (7.7)
  "first_agent_ambiguous", // 첫 에이전트 · 세션 선택: 미지정이고 후보가 둘 이상이고 비용 차이가 큼 (7.7)
  "requirement_change_new_commitment", // 상대의 요구 변경이 새 약속 · 범위를 바꿈 (시나리오 ②, ARCH14)
  // 코디네이터가 위임 범위 안에서 결정 (런타임 계약 6장 오른쪽)
  "answerable_from_facts_or_preferences", // 확인된 사실(T1) · 이 run 대화(T2) · 범위의 명시 선호로 답할 수 있는 질문
  "internal_execution_order", // 내부 실행 순서 (외부 기한은 건드리지 않음)
  "revision_loop_within_cap", // 수정 왕복 (횟수 상한 안)
  "in_scope_followup", // 허용 범위 안의 수정 · 검토 · 후속 연락
  "approval_callback_inside_auto_rules", // 공식 승인 콜백 중 Auto/Full 규칙 안 (기존 정책 적용)
  "auto_external_change_inside_rules", // Auto/Full 규칙 안 외부 변경
  "apply_explicit_memory", // explicit 기억 · 선호를 acceptance · 묶음에 적용 (7.7)
  "auto_membership", // 자동 멤버십(auto) · 후보(inferred) 추가 (7.7)
  "agent_question_answerable_from_memory", // 기억(explicit · observed)에 답이 있는 질문 (7.7)
  "first_agent_specified_or_unique", // 사용자가 지정했거나 후보가 하나 (7.7)
] as const;
export type DecisionCase = (typeof DECISION_CASES)[number];

export const DECISION_ROUTING: Record<DecisionCase, Decider> = {
  direction_or_taste: "user",
  external_commitment: "user",
  spend_outside_policy: "user",
  new_recipient_or_target: "user",
  permission_expansion: "user",
  change_outside_allowed_scope: "user",
  irreversible_not_yet_allowed: "user",
  provider_requires_human: "user",
  approval_callback_manual_or_outside_rules: "user",
  manual_external_change: "user",
  infer_memory_confirm: "user",
  context_merge: "user",
  membership_by_user: "user",
  agent_question_not_in_memory: "user",
  first_agent_ambiguous: "user",
  requirement_change_new_commitment: "user",
  answerable_from_facts_or_preferences: "coordinator",
  internal_execution_order: "coordinator",
  revision_loop_within_cap: "coordinator",
  in_scope_followup: "coordinator",
  approval_callback_inside_auto_rules: "coordinator",
  auto_external_change_inside_rules: "coordinator",
  apply_explicit_memory: "coordinator",
  auto_membership: "coordinator",
  agent_question_answerable_from_memory: "coordinator",
  first_agent_specified_or_unique: "coordinator",
};

export const routeDecision = (decisionCase: DecisionCase): Decider => DECISION_ROUTING[decisionCase];

// ───────────────────────── 모델 계획 ─────────────────────────

/** J4 영향 판정(Jev noul)을 후보마다 하는 사건 종류: 자료가 바뀐 사건 (아키텍처 7.3). 나머지 종류는 후보가 코드로 확정된다 */
const JEV_IMPACT_TYPES: ReadonlySet<InboxEventType> = new Set(["source_revised", "reply_observed"]);

/** 관리(생성) 모델이 한 번 필요할 수 있는 사건 종류: 상대 · 에이전트의 입력이 acceptance를 흔드는 것. 이 종류는 지금 생산자가 없다 (PRODUCERS) */
const MANAGEMENT_TYPES: ReadonlySet<InboxEventType> = new Set(["reply_observed", "agent_event", "dependency_changed"]);

export type ModelPlan = {
  /** Jev로 영향을 판정할 후보 (불확실한 후보만, 상한까지). 비어 있으면 Jev 0회 */
  jev: Candidate[];
  /** 관리(생성) 모델을 사건당 최대 1회 부를 수 있는가 */
  management: boolean;
};

/**
 * 사건 하나의 모델 계획. 호출 0이 기본이다:
 *  - 후보가 없으면 둘 다 없다. 확실한 후보(certain)는 판정 없이 그대로 영향이다.
 *  - Jev는 자료 변화 종류의 불확실한 후보만, min(후보 수, MAX_JEV_CALLS_PER_EVENT)까지.
 *  - 관리 모델은 MANAGEMENT_TYPES이고 불확실한 후보가 있을 때만, 사건당 한 번.
 * 포트가 없으면(지금 운영 배선) 계획은 비지만 불확실한 후보는 "판정 없이 기록"으로 남는다 (coordinate.ts).
 */
export function planModelWork(type: InboxEventType, candidates: Candidate[], ports: { jev: boolean; management: boolean }): ModelPlan {
  const uncertain = candidates.filter((c) => c.certainty === "uncertain");
  if (uncertain.length === 0) return { jev: [], management: false };
  return {
    jev: ports.jev && JEV_IMPACT_TYPES.has(type) ? uncertain.slice(0, MAX_JEV_CALLS_PER_EVENT) : [],
    management: ports.management && MANAGEMENT_TYPES.has(type),
  };
}
