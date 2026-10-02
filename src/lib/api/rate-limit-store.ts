import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { RateLimit } from "./rate-limit";

export type RateLimitKind = "ask" | "missing_report" | "connection_start" | "action_create" | "run_create";

/**
 * 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 한 번 남기고 null (모델 · 외부 서비스를 부르기 전에 부른다).
 * 세기와 남기기를 DB 함수 하나(take_rate_limit, 사용자 · 종류별 advisory lock)에서 해서 동시 요청도 한도를 넘지 못한다.
 */
export async function takeRateLimit(admin: SupabaseClient, userId: string, kind: RateLimitKind, limit: RateLimit): Promise<Date | null> {
  const { data } = await admin
    .rpc("take_rate_limit", { p_user_id: userId, p_kind: kind, p_max: limit.max, p_window_seconds: Math.ceil(limit.windowMs / 1000) })
    .throwOnError();
  return data ? new Date(data as string) : null;
}
