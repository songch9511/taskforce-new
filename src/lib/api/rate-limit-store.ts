import "server-only";

import { createHash } from "node:crypto";

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

/**
 * 웹 /login의 코드 확인 시도: 이메일 주소(해시)별로 10분(코드가 사는 시간)에 5번까지.
 * 가입 전에는 사용자 id가 없어 위 take_rate_limit(user_id 필수)을 못 쓴다 — 같은 방식의 DB 함수 take_login_code_attempt(20261201000000)를 쓴다.
 * 확인에 성공한 시도도 한 번으로 센다: 확인하기 전에 먼저 남겨야 동시에 여러 번 보내도 상한을 넘지 못한다.
 */
export const LOGIN_CODE_ATTEMPT_LIMIT: RateLimit = { max: 5, windowMs: 10 * 60_000 };

/** 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 한 번 남기고 null. 주소는 소문자로 맞춰 해시만 DB에 보낸다 (원본 주소는 남기지 않는다) */
export async function takeEmailCodeAttempt(admin: SupabaseClient, email: string, limit: RateLimit): Promise<Date | null> {
  const emailHash = createHash("sha256").update(email.trim().toLowerCase()).digest("hex");
  const { data } = await admin
    .rpc("take_login_code_attempt", { p_email_hash: emailHash, p_max: limit.max, p_window_seconds: Math.ceil(limit.windowMs / 1000) })
    .throwOnError();
  return data ? new Date(data as string) : null;
}
