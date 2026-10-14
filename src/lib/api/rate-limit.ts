// 사용자별 요청 횟수 제한. 세기와 시도 기록은 DB 함수 take_rate_limit이 한 트랜잭션에서 한다
// (서버 인스턴스가 여러 개이거나 요청이 동시에 와도 한도를 넘지 않는다, rate-limit-store.ts).

export type RateLimit = { max: number; windowMs: number };

/** 누락 신고: 한 번에 LLM · Jev · 임베딩을 부르므로 10분에 10번까지 */
export const MISSING_REPORT_LIMIT: RateLimit = { max: 10, windowMs: 10 * 60_000 };

/** 물어보기: 한 번에 임베딩 + LLM을 부르므로 10분에 20번까지 */
export const ASK_LIMIT: RateLimit = { max: 20, windowMs: 10 * 60_000 };

/** 연결 시작: 시작할 때마다 서명된 state · nonce를 만들므로 10분에 10번까지 */
export const CONNECTION_START_LIMIT: RateLimit = { max: 10, windowMs: 10 * 60_000 };

/** 직접 추가: 모델은 부르지 않지만(동의했으면 임베딩 하나) Action을 쓰므로 10분에 30번까지 */
export const ACTION_CREATE_LIMIT: RateLimit = { max: 30, windowMs: 10 * 60_000 };

/** run 만들기 (POST /api/v1/runs): run 하나가 모델을 여러 번 부르고 크레딧을 예약하므로 10분에 10번까지 */
export const RUN_CREATE_LIMIT: RateLimit = { max: 10, windowMs: 10 * 60_000 };

/** 429의 Retry-After 헤더 값 (초, 최소 1) */
export function retryAfterSeconds(retryAt: Date, now: Date): number {
  return Math.max(1, Math.ceil((retryAt.getTime() - now.getTime()) / 1000));
}

export class RateLimitedError extends Error {
  constructor(readonly retryAt: Date) {
    super("요청이 너무 많습니다. 잠시 뒤 다시 시도해 주세요.");
    this.name = "RateLimitedError";
  }
}

/** Registration rotates the device credential. */
export const BRIDGE_REGISTER_LIMIT: RateLimit = { max: 20, windowMs: 60 * 60_000 };
export async function takeBridgeRegistrationLimit(admin: import("@supabase/supabase-js").SupabaseClient, userId: string): Promise<void> {
  const { data } = await admin.rpc("take_rate_limit", { p_user_id: userId, p_kind: "bridge_register", p_max: BRIDGE_REGISTER_LIMIT.max, p_window_seconds: BRIDGE_REGISTER_LIMIT.windowMs / 1000 }).throwOnError();
  if (data) throw new RateLimitedError(new Date(String(data)));
}

const BRIDGE_REQUEST_LIMITS = { bridge_events: 120, bridge_ack: 240, bridge_poll: 90 } as const;
export async function takeBridgeRequestLimit(
  admin: import("@supabase/supabase-js").SupabaseClient,
  userId: string,
  bridgeId: string,
  kind: keyof typeof BRIDGE_REQUEST_LIMITS,
): Promise<void> {
  const { data } = await admin.rpc("take_rate_limit", {
    p_user_id: userId, p_bridge_id: bridgeId, p_kind: kind, p_max: BRIDGE_REQUEST_LIMITS[kind], p_window_seconds: 60,
  }).throwOnError();
  if (data) throw new RateLimitedError(new Date(String(data)));
}
