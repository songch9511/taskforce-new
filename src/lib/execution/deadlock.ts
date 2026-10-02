// Postgres 교착(40P01) 다시 시도. 드물게 Postgres가 교착을 감지해 한쪽 트랜잭션을 되돌린다 (docs/EXECUTION.md 12장: 멈추기 vs 같은 run의 재시도 begin_call).
// 되돌려진 트랜잭션은 아무것도 commit하지 않았으므로 같은 RPC를 다시 부르는 것이 안전하다 (단계 · 원장은 그대로다).
// 실행기의 RPC는 모두 이것으로 감싼다 (store.ts). 횟수는 정해 두고(bounded), 기다리는 시간은 흩뜨린다(jitter): 같은 둘이 다시 부딪히지 않게.

/** 처음 시도 뒤 다시 시도하는 횟수 */
export const DEADLOCK_RETRIES = 3;
/** 첫 다시 시도 전 기다리는 시간의 기준 (ms). 다시 시도마다 두 배, 0.5–1.5배로 흩뜨린다 */
export const DEADLOCK_BASE_MS = 50;

/** Postgres SQLSTATE 40P01 (deadlock_detected). supabase-js(PostgrestError) · pg 오류 모두 code에 담긴다 */
export function isDeadlock(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { code?: unknown }).code === "40P01";
}

export type DeadlockRetryOptions = {
  retries?: number;
  baseMs?: number;
  sleep?: (ms: number) => Promise<void>;
  random?: () => number;
};

export async function withDeadlockRetry<T>(fn: () => Promise<T>, options: DeadlockRetryOptions = {}): Promise<T> {
  const retries = options.retries ?? DEADLOCK_RETRIES;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const random = options.random ?? Math.random;
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (error) {
      if (!isDeadlock(error) || attempt >= retries) throw error;
      await sleep((options.baseMs ?? DEADLOCK_BASE_MS) * 2 ** attempt * (0.5 + random()));
    }
  }
}
