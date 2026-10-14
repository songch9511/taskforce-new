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

/**
 * goal별 단계 상한 (런타임 계약 4장). draft는 위 MAX_STEPS 그대로다. 나머지는 값만 정해 둔 것이다: 이 goal을 실행하는 코드는 아직 없고
 * (실행기는 types.ts EXECUTABLE_GOALS의 goal만 돌린다), 이 상한을 읽는 곳도 draft의 MAX_STEPS뿐이다. 값을 바꾸려면 상수와 테스트를 함께 바꾼다.
 * agent = dispatch 1 + 메시지 왕복 ≤ 3×2 + 검토 ≤ 2 + 계획 단계. 상한은 비용 · 무한 반복 방지
 */
export const MAX_STEPS_BY_GOAL = { draft: MAX_STEPS, agent: 12, send: 4, followup: 3 } as const;

// 동시성 한도 (런타임 계약 4장). 외부 작업은 agents/turns.ts가 세며 나머지 입구는 C2 · 뒤 게이트웨이 단계가 맡는다.
/** ① 실행 동시성: 사용자당 동시에 calling인 비용 단계(모델 · 에이전트 호출) */
export const MAX_CONCURRENT_COST_STEPS = 3;
/** ② 살아 있는 외부 작업: 실행 중이거나 실행 가능성이 남은 원격 작업 (dispatched · accepted · running, 실행 여부가 불명인 unreachable) */
export const MAX_LIVE_EXTERNAL_TASKS = 5;
/** ③ 대기 보관: 승인 · 질문 · 회신을 기다리는 run은 ①을 차지하지 않고, 이만큼(일) 지나면 정리를 제안한다 */
export const WAITING_RUN_RETENTION_DAYS = 30;
/** 한 Action의 열린 run: intent가 다를 때만 이만큼까지 */
export const MAX_OPEN_RUNS_PER_ACTION = 2;

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

export const BRIDGE_HEARTBEAT_SECONDS = 30;
export const BRIDGE_UNREACHABLE_AFTER_SECONDS = 90;
export const BRIDGE_LONG_POLL_MAX_SECONDS = 25;
export const BRIDGE_LONG_POLL_RECHECK_MS = 2000;
export const BRIDGE_EVENTS_MAX = 100;
export const BRIDGE_EVENTS_MAX_BYTES = 1_000_000;
export const BRIDGE_KICK_LIMIT = 5;
export const BRIDGE_REDELIVERY_LIMIT = 50;
export const BRIDGE_COMMAND_RETENTION_DAYS = 30;

export const PATH_LEASE_IDLE_MINUTES = 30;
export const PATH_LEASE_TARGETS_MAX = 20;
export const PATH_LEASE_WAITERS_MAX = 20;
export const PATH_LEASE_RETENTION_DAYS = 30;
export const PATH_LEASE_SWEEP_LIMIT = 500;
export const TOOL_DECISION_LOCK_TIMEOUT_MS = 250;
export const TOOL_DECISION_MAX_BYTES = 65_536;
export const BRIDGE_DECIDE_PER_MINUTE = 600;
