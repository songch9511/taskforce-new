import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { ConsentCheck } from "./gate";

// 동의 확인의 DB 쪽. service role로 읽고 user_id로 좁힌다 (사용자 세션이 없는 동기화 · after()에서도 쓴다).

/** 외부 AI 처리에 지금 동의한 상태인가 (profiles.ai_consent_at) */
export async function hasConsentFor(admin: SupabaseClient, userId: string): Promise<boolean> {
  const { data } = await admin.from("profiles").select("ai_consent_at").eq("user_id", userId).maybeSingle().throwOnError();
  return Boolean((data as { ai_consent_at: string | null } | null)?.ai_consent_at);
}

/** withConsentGate에 넘길 확인 함수: 모델을 부르기 직전마다 다시 읽는다 */
export const consentCheck =
  (admin: SupabaseClient, userId: string): ConsentCheck =>
  () =>
    hasConsentFor(admin, userId);
