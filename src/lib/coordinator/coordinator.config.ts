// 코디네이터 1(0.2.0 C2)의 상한 · 기본값 (런타임 계약 12장, 아키텍처 7.1 · 10장). 값을 바꾸면 테스트를 함께 바꾼다.
// "제안" 표시는 문서에 값이 없어 이 PR이 정한 운영값이다 (D0에서 바꿀 수 있다). 사건을 나이만으로 만료 · 삭제 · 처리 성공 처리하는 값은 두지 않는다
// (docs/coordinator.md 열린 결정 D-1 · D-2).

/** 코디네이터 route(POST /api/cron/coordinator-advance)의 실행 한도 (초). route의 maxDuration은 리터럴이어야 해서 route에 따로 적고, 같은 값인지는 route 테스트가 본다 */
export const COORDINATOR_MAX_DURATION_S = 60;

/** lease 여유 (초): 살아 있는 함수의 lease는 만료되지 않는다. 실행기의 LEASE_MARGIN_S(30)와 같은 이유 */
export const COORDINATOR_LEASE_MARGIN_S = 30;

/** 집은 사건의 lease (초) = 실행 한도 + 여유. 마이그레이션 coordinator_claim의 p_lease_seconds로 넘긴다 */
export const COORDINATOR_LEASE_SECONDS = COORDINATOR_MAX_DURATION_S + COORDINATOR_LEASE_MARGIN_S;

/** 한 사건을 집는 시도 상한 (제안). 넘으면 죽은 사건(dead_at)으로 접고 그 사용자의 다음 사건을 본다. 처리된 것이 아니다 */
export const COORDINATOR_MAX_ATTEMPTS = 5;

/** 처리 실패 뒤 다시 집기까지의 지연 (초, 제안): 같은 sweep 안에서 바로 되풀이하지 않는다. sweep 주기(1분)와 같다 */
export const COORDINATOR_RETRY_DELAY_S = 60;

/** 한 번의 집기로 받는 사건 수 (제안): 사용자마다 머리 하나라서 서로 다른 사용자 수이기도 하다 */
export const CLAIM_BATCH = 10;

/** 호출(sweep · 자기 호출) 한 번이 처리하는 사건 수 상한 (제안). 쌓인 사건이 한 번에 몰려 모델 · DB를 때리지 않게 하는 batch 상한이다 */
export const MAX_EVENTS_PER_RUN = 50;

/** 호출 한 번의 시간 예산 (ms): 이 시간이 지나면 새 사건을 집지 않는다 (실행 한도 60초 − 여유). 시작한 사건은 끝낸다 */
export const RUN_TIME_BUDGET_MS = 40_000;

/** 긴급 창 (시간): 기한이 이 안이면 일일 묶음을 기다리지 않는다 (런타임 계약 6 · 12장). 기한 창 timer의 창이기도 하다 */
export const URGENT_WINDOW_HOURS = 24;

/** 기한 창 timer를 sweep 한 번에 새로 쌓는 수 상한 (제안) */
export const TIMER_ENQUEUE_LIMIT = 200;

/** 삼킨 적재의 회수 (제안): UTC 분이 이 수의 배수일 때만 돈다. 훑는 기간은 주기의 4배(sweep이 잠시 멈춰도 메운다) */
export const RECOVERY_EVERY_MINUTES = 30;
export const RECOVERY_LOOKBACK_SECONDS = 2 * 3600;
/** 회수가 종류마다 새로 쌓는 수 상한 (제안) */
export const RECOVERY_LIMIT = 200;

/** 영향 후보 수 상한 (제안). 넘으면 id 순으로 자르고 잘랐다고 결과에 남긴다 (모델 입력 · 결과 크기를 묶는다) */
export const MAX_CANDIDATES = 50;

/** 사건 하나에서 Jev 영향 판정 호출 상한 (제안): 후보 수와 이 값 중 작은 쪽. 후보가 없으면 0 */
export const MAX_JEV_CALLS_PER_EVENT = 8;

/** 사건 하나의 관리(생성) 모델 호출 상한: 확정 (아키텍처 7.1, DB model_calls ∈ {0, 1}) */
export const MANAGEMENT_CALLS_PER_EVENT = 1;
