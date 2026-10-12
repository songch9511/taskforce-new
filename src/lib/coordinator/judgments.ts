import { AiBudgetError } from "@/lib/ai/budget-error";
import { ConsentRequiredError } from "@/lib/consent/gate";

import { MAX_JEV_CALLS_PER_EVENT } from "./coordinator.config";
import { candidateKey } from "./impact";
import type { ModelPlan } from "./routing";
import type { CoordinatorStore } from "./store";
import type { Candidate, ClaimedEvent, EvidenceKind } from "./types";

// 모델 판정 (J4 영향 · 관리 모델). 이 모듈의 규칙:
//  - 호출 전에 DB에 예산을 먼저 잡는다 (store.reserve*): 예약이 없으면 부르지 않는다. 예약만 남고 응답이 없으면(프로세스 종료 · 응답 유실) 다시 부르지 않는다 → "판정 못함".
//  - 관리(생성) 모델은 사건당 최대 1회 (DB model_calls ∈ {0, 1}). Jev는 후보 수 · MAX_JEV_CALLS_PER_EVENT까지, 따로 센다.
//  - 모델 출력은 후보 집합 안에서만 받는다: 후보 밖 객체가 하나라도 있으면 출력 전체를 버린다 (부분 신뢰 없음). 모델은 객체를 만들거나 바꾸지 못한다.
//  - 포트는 주입된다. 일일 AI 원가(budgetFetch)와 동의(withConsentGate)는 포트를 만드는 쪽의 몫이고, 여기서는 그 오류(AiBudgetError · ConsentRequiredError)를 "판정 못함"으로 닫는다.
//  - 지금 운영 배선(sweep.ts)은 포트를 주지 않는다: 현재 데이터에는 이 판정의 결과를 쓰는 곳이 없다 (사건은 결과만 기록한다. 소비자는 C3 제안 · D1 게이트웨이). 호출 경로는 fake로만 시험한다.

export type JudgeRequest = { eventType: string; candidates: Candidate[] };

/** Jev noul로 후보마다 "영향 있는가"를 묻는 포트 (J4). 영향 있다고 본 후보의 키(kind:id)를 돌려준다. 후보마다 Jev 호출 하나 */
export type ImpactJudge = (request: JudgeRequest) => Promise<{ affected: string[] }>;

/** 관리(생성) 모델 포트: 후보 안에서 영향받는 것을 고르고 까닭 코드 하나를 돌려준다 (글 없음). 사건당 한 번 */
export type ManagementJudge = (request: JudgeRequest) => Promise<{ affected: string[]; reason_code: string }>;

export type JudgmentPorts = { jev?: ImpactJudge; management?: ManagementJudge };

export type JudgmentResult =
  // remaining: 판정 뒤에도 영향이 남은(또는 판정하지 않아 배제하지 못한) 불확실한 후보. 확실한 후보는 부르는 쪽이 따로 합친다
  | { kind: "judged"; remaining: Candidate[]; evidence: Extract<EvidenceKind, "jev_judged" | "management_judged"> }
  | { kind: "not_judged"; evidence: Extract<EvidenceKind, "model_call_unknown" | "jev_budget_exhausted" | "ai_budget" | "consent_missing" | "model_error" | "model_output_rejected"> };

/** 모델이 돌려준 키가 모두 보낸 후보 안에 있을 때만 그 후보들을, 하나라도 밖이면 null (출력 전체를 버린다) */
export function restrictToCandidates(sent: Candidate[], returned: unknown): Candidate[] | null {
  if (!Array.isArray(returned) || returned.some((k) => typeof k !== "string")) return null;
  const byKey = new Map(sent.map((c) => [candidateKey(c), c]));
  const picked: Candidate[] = [];
  for (const key of new Set(returned as string[])) {
    const candidate = byKey.get(key);
    if (!candidate) return null;
    picked.push(candidate);
  }
  return picked;
}

function failureEvidence(error: unknown): "ai_budget" | "consent_missing" | "model_error" {
  if (error instanceof AiBudgetError) return "ai_budget";
  if (error instanceof ConsentRequiredError) return "consent_missing";
  return "model_error";
}

/**
 * 계획(routing.ts planModelWork)대로 모델 판정을 한다. 포트를 부르기 전에 항상 예약이 먼저다.
 * 불확실한 후보를 차례로 좁힌다: Jev가 "영향 없음"으로 본 후보는 빠지고, 관리 모델은 남은 후보 중에서 고른다.
 * 모델이 보지 못한 불확실한 후보(상한 밖)는 배제하지 못했으므로 남는다. 하나라도 판정에 실패하면 not_judged다 (일부만 믿지 않는다).
 */
export async function runJudgments(args: {
  store: CoordinatorStore;
  event: ClaimedEvent;
  eventType: string;
  plan: ModelPlan;
  uncertain: Candidate[];
  ports: JudgmentPorts;
}): Promise<JudgmentResult | null> {
  const { store, event, eventType, plan, ports } = args;
  let remaining = args.uncertain;
  let evidence: "jev_judged" | "management_judged" | null = null;

  // 1) Jev 영향 판정: 후보마다 한 번 (예약은 전부 또는 0). 후보가 없으면 예약도 호출도 없다
  if (plan.jev.length > 0 && ports.jev) {
    if (!(await store.reserveJevCalls(event, plan.jev.length, MAX_JEV_CALLS_PER_EVENT))) return { kind: "not_judged", evidence: "jev_budget_exhausted" };
    try {
      const out = await ports.jev({ eventType, candidates: plan.jev });
      const picked = restrictToCandidates(plan.jev, out?.affected);
      if (!picked) return { kind: "not_judged", evidence: "model_output_rejected" };
      const examined = new Set(plan.jev.map(candidateKey));
      const affected = new Set(picked.map(candidateKey));
      remaining = remaining.filter((c) => !examined.has(candidateKey(c)) || affected.has(candidateKey(c)));
      evidence = "jev_judged";
    } catch (error) {
      return { kind: "not_judged", evidence: failureEvidence(error) };
    }
  }

  // 2) 관리(생성) 모델: 사건당 한 번. 이미 예약됐으면(이 사건을 앞서 집은 시도가 부르다 멈췄다) 다시 부르지 않는다
  if (plan.management && ports.management && remaining.length > 0) {
    if (event.model_calls >= 1 || !(await store.reserveModelCall(event))) return { kind: "not_judged", evidence: "model_call_unknown" };
    try {
      const out = await ports.management({ eventType, candidates: remaining });
      const picked = restrictToCandidates(remaining, out?.affected);
      if (!picked || typeof out?.reason_code !== "string" || !/^[a-z][a-z0-9_]{0,63}$/.test(out.reason_code)) return { kind: "not_judged", evidence: "model_output_rejected" };
      remaining = picked;
      evidence = "management_judged";
    } catch (error) {
      return { kind: "not_judged", evidence: failureEvidence(error) };
    }
  }
  return evidence ? { kind: "judged", remaining, evidence } : null;
}
