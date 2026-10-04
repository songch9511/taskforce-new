import type { CreditsResponse } from "@/lib/api/contract";

import type { StepState } from "./types";

// GET /api/v1/credits의 Usage & Credits(S3) 필드를 원장 행에서 센다. 읽기(store.ts loadCreditDetails · 테스트)와 나눈 순수 함수라
// DB 모양 그대로 시험한다(tests/db/execution-credit-details.test.ts). 원장 · 단계 · run은 클라이언트가 읽지 못해(revoke all) 서버가 숫자만 준다.
// 열린 예약 = reserve 행은 있고 같은 단계의 settle · release 행이 없는 것 (원장 키가 단계마다 하나라 단계로 짝짓는다, EXECUTION 12장).

/** 계정 행의 합계 (store.ts loadCredits) */
export type CreditTotals = Pick<CreditsResponse, "available" | "reserved" | "rate_version">;
/** 원장 행에서 세는 것 (store.ts loadCreditDetails) */
export type CreditDetails = Pick<CreditsResponse, "running_runs" | "settling" | "used">;

export type CreditLedgerRow = { kind: "reserve" | "settle" | "release"; credits: number; run_id: string; step_id: string; created_at: string };
export type CreditStepRow = { id: string; state: StepState };
export type CreditRunRow = { id: string; action_id: string };

export type OpenReservation = { step_id: string; run_id: string; credits: number };

/** 아직 정산 · 해제하지 않은 예약 (원장 순서) */
export function openReservations(ledger: CreditLedgerRow[]): OpenReservation[] {
  const closed = new Set(ledger.filter((l) => l.kind !== "reserve").map((l) => l.step_id));
  return ledger.filter((l) => l.kind === "reserve" && !closed.has(l.step_id)).map((l) => ({ step_id: l.step_id, run_id: l.run_id, credits: l.credits }));
}

/**
 * - running_runs: 열린 예약이 끝내지 않은(called가 아닌) 단계에 있는 run 수. 보통 prepared(다시 준비) · calling이고, 멈춘 run이라도 부르던 단계가
 *   남았으면 든다(끝날 때까지 예약을 쥔다). 그래서 reserved - settling.reserved > 0이면 running_runs > 0이다
 * - settling: 열린 예약이 끝낸(called) 단계에 있다 = 원가가 확정되지 않아 정산을 미뤘다(A46, credit_settle_step의 unconfirmed 뿐이다)
 * - used: since 이후의 settle 합계. 시각은 밀리초까지 비교한다(since는 밀리초 단위라 DB의 마이크로초 비교와 결과가 같다)
 */
export function creditDetailsFromRows(
  rows: { ledger: CreditLedgerRow[]; steps: CreditStepRow[]; runs: CreditRunRow[] },
  since: Date,
): CreditDetails {
  const stepState = new Map(rows.steps.map((s) => [s.id, s.state]));
  const actionOf = new Map(rows.runs.map((r) => [r.id, r.action_id]));
  const running = new Set<string>();
  const settling = { steps: 0, reserved: 0, action_ids: [] as string[] };
  for (const r of openReservations(rows.ledger)) {
    const state = stepState.get(r.step_id);
    if (state !== "called") {
      running.add(r.run_id);
      continue;
    }
    settling.steps += 1;
    settling.reserved += r.credits;
    const actionId = actionOf.get(r.run_id);
    if (actionId && !settling.action_ids.includes(actionId)) settling.action_ids.push(actionId);
  }
  const from = since.getTime();
  const used = rows.ledger.filter((l) => l.kind === "settle" && Date.parse(l.created_at) >= from).reduce((sum, l) => sum + l.credits, 0);
  return { running_runs: running.size, settling, used: { credits: used, since: since.toISOString() } };
}
