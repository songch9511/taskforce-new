import { describe, expect, it } from "vitest";

import { MAX_JEV_CALLS_PER_EVENT } from "./coordinator.config";
import { DECISION_CASES, DECISION_ROUTING, planModelWork, routeDecision } from "./routing";
import type { Candidate } from "./types";

const cand = (n: number, certainty: Candidate["certainty"]): Candidate => ({ kind: "action", id: `aaaaaaaa-0000-4000-8000-${String(n).padStart(12, "0")}`, relation: "x", certainty });

describe("결정 라우팅 표 (런타임 계약 6장 · 아키텍처 7.7)", () => {
  it("모든 상황에 결정자가 있고 표와 목록이 같다", () => {
    expect(Object.keys(DECISION_ROUTING).sort()).toEqual([...DECISION_CASES].sort());
  });

  it("사용자만 결정하는 것: 방향 · 새 약속 · 정책 밖 지출 · 새 수신자 · 권한 확장 · Manual 승인 · inferred 확정 · 병합 · 멤버십(user)", () => {
    for (const c of [
      "direction_or_taste", "external_commitment", "spend_outside_policy", "new_recipient_or_target", "permission_expansion", "change_outside_allowed_scope",
      "irreversible_not_yet_allowed", "provider_requires_human", "approval_callback_manual_or_outside_rules", "manual_external_change",
      "infer_memory_confirm", "context_merge", "membership_by_user", "agent_question_not_in_memory", "first_agent_ambiguous", "requirement_change_new_commitment",
    ] as const) {
      expect(routeDecision(c), c).toBe("user");
    }
  });

  it("코디네이터가 위임 범위 안에서 결정하는 것: 사실로 답할 수 있는 질문 · 내부 순서 · 수정 왕복 · Auto 규칙 안 · explicit 기억 적용 · 자동 멤버십", () => {
    for (const c of [
      "answerable_from_facts_or_preferences", "internal_execution_order", "revision_loop_within_cap", "in_scope_followup", "approval_callback_inside_auto_rules",
      "auto_external_change_inside_rules", "apply_explicit_memory", "auto_membership", "agent_question_answerable_from_memory", "first_agent_specified_or_unique",
    ] as const) {
      expect(routeDecision(c), c).toBe("coordinator");
    }
  });

  it("표의 입력에는 범위 · 기억 · version · 권한 정보가 없다 (ARCH06/07, I04 · I14): 상황 이름만 받는 순수 조회다", () => {
    expect(routeDecision.length).toBe(1);
    expect(JSON.stringify(DECISION_ROUTING)).not.toMatch(/context_id|context_version|work_context|memory_id/);
  });
});

describe("모델 계획: 호출 0이 기본이다", () => {
  const ports = { jev: true, management: true };

  it("후보가 없으면 둘 다 없다 (사건은 있어도)", () => {
    for (const type of ["source_revised", "reply_observed", "agent_event", "memory_changed", "timer_due", "user_message", "decision_made", "source_processed"] as const) {
      expect(planModelWork(type, [], ports)).toEqual({ jev: [], management: false });
    }
  });

  it("후보가 모두 확실하면 판정할 것이 없다 → 호출 0", () => {
    expect(planModelWork("source_revised", [cand(1, "certain"), cand(2, "certain")], ports)).toEqual({ jev: [], management: false });
  });

  it("포트가 없으면(지금 운영 배선) 불확실한 후보가 있어도 호출 0", () => {
    expect(planModelWork("source_revised", [cand(1, "uncertain")], { jev: false, management: false })).toEqual({ jev: [], management: false });
  });

  it("Jev는 자료 변화 종류의 불확실한 후보만, 후보 수와 상한 중 작은 쪽까지", () => {
    const many = Array.from({ length: MAX_JEV_CALLS_PER_EVENT + 5 }, (_, i) => cand(i + 1, "uncertain"));
    expect(planModelWork("source_revised", many, ports).jev).toHaveLength(MAX_JEV_CALLS_PER_EVENT);
    expect(planModelWork("source_revised", [cand(1, "uncertain"), cand(2, "uncertain")], ports).jev).toHaveLength(2);
    // 자료가 바뀐 사건이 아니면 불확실한 후보가 있어도 Jev 0 (후보가 코드로 확정되는 종류)
    for (const type of ["memory_changed", "timer_due", "user_message", "decision_made", "source_processed"] as const) {
      expect(planModelWork(type, many, ports), type).toEqual({ jev: [], management: false });
    }
  });

  it("관리(생성) 모델은 상대 · 에이전트 입력 종류에서만, 불확실한 후보가 있을 때만 (이 종류들은 지금 생산자가 없다)", () => {
    expect(planModelWork("reply_observed", [cand(1, "uncertain")], ports).management).toBe(true);
    expect(planModelWork("agent_event", [cand(1, "uncertain")], ports).management).toBe(true);
    expect(planModelWork("dependency_changed", [cand(1, "uncertain")], ports).management).toBe(true);
    expect(planModelWork("source_revised", [cand(1, "uncertain")], ports).management).toBe(false);
    expect(planModelWork("agent_event", [cand(1, "certain")], ports).management).toBe(false);
    expect(planModelWork("agent_event", [cand(1, "uncertain")], { jev: true, management: false }).management).toBe(false);
  });
});
