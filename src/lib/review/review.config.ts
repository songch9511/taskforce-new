import { URGENT_WINDOW_HOURS } from "@/lib/coordinator/coordinator.config";

// 0.2.0 C3 (Review · 복귀 요약 · 제안)의 상수 (런타임 계약 12장). 모두 값 + 이유다. 바꾸면 테스트를 함께 바꾼다.
// "제안"은 문서에 값이 있는 실험값, "기술 한도"는 제품 결정이 아니라 입력 · 응답 크기를 묶는 값이다.

/** 비긴급 제안: 하루 한 묶음 · 3개 (기획안 3.3 실험값, 런타임 계약 12장 `suggestions.config.ts`). 제안에만 적용한다 — C2 결정 대기 목록(pending)에는 상한이 없다 */
export const SUGGESTION_DAILY_BATCH_SIZE = 3;

/** 긴급 창 (시간): 기한이 이 안이면 긴급 제안(`due_window`)이다. C2의 긴급 창과 같은 값을 쓴다 (런타임 계약 12장 "긴급 창") */
export const SUGGESTION_URGENT_WINDOW_HOURS = URGENT_WINDOW_HOURS;

/**
 * snooze로 고를 수 있는 가장 먼 시점 (일). 기술 한도다: 오타 · 잘못된 입력(몇 천 년 뒤)을 막을 뿐 만료 정책이 아니다 —
 * 이 값은 제안을 만료시키지 않고, 사용자가 고른 시점이 없으면 어떤 snooze도 없다.
 */
export const SNOOZE_MAX_DAYS = 366;

/** 복귀 요약 한 번에 내려가는 작업 수 상한 (기술 한도). 넘으면 잘렸다고 알리고 Clear 커서를 내지 않는다 (일부를 전체처럼 읽음 처리하지 않는다) */
export const RETURN_SUMMARY_MAX_WORKS = 300;

/** 응답에 내리는 복귀 요약 변화 토큰의 결과 준비 종류: 이 outcome으로 끝난 run만 "결과를 볼 차례"(Next: review_result)다 */
export const RESULT_READY_OUTCOMES: ReadonlySet<string> = new Set(["draft_ready", "agent_done"]);
