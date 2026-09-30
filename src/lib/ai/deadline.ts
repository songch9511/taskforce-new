// 사용자가 기다리는 요청(빠진 할 일 신고 · 물어보기)의 시간 예산. 모델 호출(LLM · Jev · 임베딩)을 실행 한도 안에 끝낸다.
// 요청을 받자마자 마감(interactiveDeadline)을 정하고, 각 호출 설정의 deadline으로 넘긴다 (llm.ts · jev.ts · embed.ts).
// 배경 처리(원문 처리 · 동기화 · 재처리 cron · eval 추출)는 마감이 없고 호출마다 제 시간 한도만 쓴다.

/**
 * 사용자가 기다리는 요청의 실행 한도 (초). 앱도 이만큼 기다린다 (Kit/APIClient.swift, URLRequest 기본 60초).
 * Route Handler의 maxDuration은 리터럴이어야 해서 route에 따로 적고, 같은 값인지는 route 테스트가 본다.
 */
export const INTERACTIVE_MAX_DURATION_S = 60;

/** 마지막 모델 호출 뒤 DB 쓰기 · 응답, 앱 쪽 네트워크 · 콜드 스타트에 남기는 시간: 모델 호출은 실행 한도보다 이만큼 먼저 끝낸다 */
export const RESPONSE_MARGIN_MS = 8_000;

/** Jev · 임베딩: 마감까지 이보다 적게 남으면 (다시) 부르지 않는다. LLM은 llm.ts LLM_MIN_ATTEMPT_MS */
export const MIN_REQUEST_MS = 1_000;

/** 실행 한도가 maxDurationSeconds초인 요청에서 모델 호출을 끝낼 시각 (epoch ms). 요청을 받자마자 잰다 */
export function interactiveDeadline(maxDurationSeconds: number, start = Date.now()): number {
  return start + maxDurationSeconds * 1000 - RESPONSE_MARGIN_MS;
}

/** 마감까지 남은 시간 (ms). 마감이 없으면 Infinity */
export function remainingMs(deadline: number | undefined, now = Date.now()): number {
  return deadline === undefined ? Infinity : deadline - now;
}

/** 마감 안에 끝내지 못했다: 남은 시간이 없어 부르지 않았거나, 마감에 맞춰 줄인 시간 한도를 넘겼다 */
export class DeadlineExceededError extends Error {
  constructor(
    readonly stage: "llm" | "jev" | "embed" | "lock",
    detail: string,
  ) {
    super(`마감 안에 끝내지 못했습니다 (${stage}: ${detail})`);
    this.name = "DeadlineExceededError";
  }
}

/** 마감 실패를 셀 수 있게 한 줄 JSON으로 남긴다. 사용자 글(원문 · 구절 · 질문)은 담지 않는다 */
export function logDeadlineExceeded(route: "missing" | "ask", error: DeadlineExceededError, startedAt: number, now = Date.now()): void {
  console.error(JSON.stringify({ event: "deadline_exceeded", route, stage: error.stage, elapsed_ms: now - startedAt }));
}
