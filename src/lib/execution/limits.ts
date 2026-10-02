// 실행기 한도 (docs/EXECUTION.md 2 · 3 · 12장). 실행 route의 maxDuration은 리터럴이어야 해서 route에 따로 적고, 같은 값인지는 route 테스트가 본다
// (src/lib/ai/deadline.ts의 INTERACTIVE_MAX_DURATION_S와 같은 방식).

/** 단계 하나를 처리하는 route(POST /api/v1/runs의 after(), POST /api/cron/execution-advance)의 실행 한도 (초). Pro 기본 300초 */
export const EXECUTION_MAX_DURATION_S = 300;

/** lease = 실행 한도 + 여유. 살아 있는 함수의 lease는 만료되지 않는다 */
export const LEASE_MARGIN_S = 30;

/**
 * begin_call이 DB 시각으로 거는 lease (초). 마이그레이션 20261021000000 · 20261022000000의 begin_call에 330으로 적혀 있고,
 * 같은 값인지는 tests/db/execution-executor.test.ts가 본다
 */
export const LEASE_SECONDS = EXECUTION_MAX_DURATION_S + LEASE_MARGIN_S;

/**
 * run 하나의 단계 상한: 계획 → 초안 → 계획 → 초안. 초안 뒤에는 다음 계획 단계를 붙여 남은 조각을 다시 보는데,
 * 그 계획이 또 초안을 붙일 자리가 있을 때만 붙인다 (계획 단계로 끝나는 run은 없다)
 */
export const MAX_STEPS = 4;

/** 지금 쓰는 크레딧 요율 (credit_rates의 active, 1 크레딧 = $0.001). GET /api/v1/credits는 DB 값을 돌려준다 */
export const RATE_VERSION = "c3-v1";

/**
 * 초안 단계 하나의 예약 추정치 (크레딧). 정산은 확정 원가로 하고 예약을 넘지 않는다(남은 예약은 해제).
 * 상한 기반: 출력 한도(8,192토큰) × 시도 2번(형식 오류 · 시간 초과 다시 묻기, llm.ts) + 입력. glm-5.3-flash 실측은 초안 한 번 약 $0.001(1 크레딧)이라
 * 넉넉히 잡았다 (U2 PR5 eval). 작은 잔액으로 막히면(hold_reason='credit') 운영자 지급량으로 맞춘다
 */
export const DRAFT_ESTIMATE_CREDITS = 20;

/** sweep 한 번에 자기 호출로 깨우는 run 수 (sweep은 단계를 직접 돌리지 않는다) */
export const SWEEP_WAKE_LIMIT = 20;

/**
 * 막힌 run(hold_reason: 크레딧 · 실행 주체 · 스위치 · 도구)은 이 분마다만 깨운다 (UTC 분이 이 수의 배수일 때). 풀리기를 기다리는 run이
 * 매분 함수 호출을 쓰지 않게. 풀린 뒤 늦어도 이만큼 안에 이어 간다
 */
export const HELD_WAKE_EVERY_MINUTES = 5;

/** sweep 한 번에 receipt를 이어 쓰는 끝낸 초안 단계 수 (보조 안전망, receipt.ts writeMissingReceipts). 단계마다 읽기 몇 번 + RPC 한 번 */
export const SWEEP_RECEIPT_LIMIT = 20;

/** sweep 한 번에 generation 조회로 확정하는 미확정 원가 행 수 */
export const SWEEP_RECONCILE_LIMIT = 20;

/** sweep이 미확정 원가를 조회하는 기간 (시간). 지나면 운영자가 정한다 (U2 PR8 런북) */
export const RECONCILE_WINDOW_HOURS = 24;

/**
 * sweep 한 번에 남은 예약을 정리하는 끝난 run 수 (run마다 RPC 한 번). 원가가 미확정이라 예약을 둔 run도 목록에 남아(credit_open_ended_runs)
 * 자리를 차지하므로 깨우기보다 넉넉히 둔다
 */
export const SWEEP_RELEASE_LIMIT = 50;
