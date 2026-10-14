// 롤백된 경합을 같은 호출로 다시 한다 (검토 반영 9-2). 다시 해도 되는 오류는 SQL이 통째로 롤백한 경합뿐이다:
// 40001(직렬화 실패 — 예: start_agent_turn_auto가 잠금 대상이 바뀐 것을 보고 물러남) · 40P01(교착 — DB가 한쪽을 중단함) · 55P03(NOWAIT 잠금 경합).
// 최대 2번 다시 = 모두 3번 시도. 그래도 안 되면 던지고, handler가 409 busy_retry로 답한다 (500 아님). 다른 오류는 다시 하지 않는다.
const CONFLICT_CODES: readonly string[] = ["40001", "40P01", "55P03"];
const MAX_ATTEMPTS = 3;

export async function retryOnConflict<T>(call: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await call();
    } catch (error) {
      const code = typeof error === "object" && error !== null && "code" in error ? (error as { code?: unknown }).code : undefined;
      if (attempt >= MAX_ATTEMPTS || typeof code !== "string" || !CONFLICT_CODES.includes(code)) throw error;
    }
  }
}
