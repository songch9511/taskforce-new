// 사용자별 요청 횟수 제한 (순수 함수). 시도 기록은 DB에 두고(서버 인스턴스가 여러 개여도 같게 센다), 판단만 여기서 한다.

export type RateLimit = { max: number; windowMs: number };

/** 누락 신고: 한 번에 LLM · Jev · 임베딩을 부르므로 10분에 10번까지 */
export const MISSING_REPORT_LIMIT: RateLimit = { max: 10, windowMs: 10 * 60_000 };

/**
 * 최근 시도 시각(`attempts`)으로 지금 한 번 더 해도 되는지 본다. 한도에 찼으면 다시 할 수 있는 시각, 아니면 null.
 * 창(window) 밖의 시도는 세지 않는다.
 */
export function rateLimitedUntil(attempts: string[], now: Date, limit: RateLimit): Date | null {
  const since = now.getTime() - limit.windowMs;
  const recent = attempts
    .map((at) => Date.parse(at))
    .filter((t) => t > since)
    .sort((a, b) => a - b);
  if (recent.length < limit.max) return null;
  // 가장 오래된 시도들이 창 밖으로 나가 한도 아래로 내려가는 시각
  return new Date(recent[recent.length - limit.max] + limit.windowMs);
}

export class RateLimitedError extends Error {
  constructor(readonly retryAt: Date) {
    super("요청이 너무 많습니다. 잠시 뒤 다시 시도해 주세요.");
    this.name = "RateLimitedError";
  }
}
