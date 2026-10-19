import type { SupabaseClient } from "@supabase/supabase-js";

import { billingEnabled, billingFlags, planState, type BillingAccount } from "@/lib/billing/state";

/**
 * 이 계정이 에이전트 실행을 시작해도 되는가 (결제 계약 22장). 시작의 공통 경계(startPinnedAgentMessage)가 쓴다:
 * 수동 시작 · 자동 시작 · 다시 전달 · bridge 계기가 모두 그곳을 지난다.
 * - 결제가 꺼져 있으면(모두 베타) 아무것도 읽지 않고 통과한다: 동작이 바뀌지 않는다.
 * - 판정은 AI 호출 문(requireBillingAccess)과 같은 planState다: 체험 · Pro · 취소했지만 기간이 남음 · 결제 실패 유예 · Lifetime · 공지 전 베타만 통과한다.
 * - 읽기만 한다(계정 행을 만들지 않는다). 기록이 없으면 산 적 없는 계정이라 막는다. 읽지 못하면 던진다 — 시작도, 막힌 것으로 표시도 하지 않고 다음 계기가 다시 시도한다
 */
export async function agentRunsAllowed(admin: SupabaseClient, userId: string): Promise<boolean> {
  if (!billingEnabled()) return true;
  const { data } = await admin.from("billing_accounts").select("*").eq("user_id", userId).maybeSingle().throwOnError();
  if (!data) return false;
  return planState(data as BillingAccount, Date.now(), billingFlags()).ai;
}
