// 0.2.0 서버 기능 gate (구현 계획 7장). 모두 기본 꺼짐이고 개발 서버도 같다: env 값이 정확히 "true"일 때만 켠다
// (대소문자 · 앞뒤 공백 · "1"은 꺼짐. billing/state.ts billingEnabled와 같은 비교, 인자는 env.ts executionEnabled처럼 env를 받는다).
// 기존 EXECUTION_ENABLED(env.ts) · BILLING_ENABLED(billing/state.ts)는 여기로 옮기지 않는다.
// REPORTS_V2_ENABLED는 H1(보고 설정 route · cron/reports)이 읽는다. 나머지는 아직 읽는 코드가 없다 (A2는 계약 · 표 뼈대).
// 켜는 순서 · 경계는 구현 계획 7장 "플래그 켜기 경계".

/**
 * CONVERSATIONS_V2_ENABLED: 대화 v2 · 저장 (끄면 v1 Ask만)
 * MEMORY_ENABLED: 기억 저장 · 묶음 포함 (끄면 저장 0 · 포함 0)
 * SOURCE_CHUNKS_ENABLED: 원문 조각 임베딩 · 조각 검색 (끄면 조각 0)
 * COORDINATOR_ENABLED: 코디네이터 사건 처리 (끄면 inbox_events 적재만)
 * AGENT_ADAPTER_CLAUDE_CODE_ENABLED: Claude Code dispatch · Your agents 행 (끄면 dispatch 0. DB의 execution_controls도 따로 막는다)
 * BYOK_ENABLED: 사용자 OpenRouter 키 입력 · 사용 (끄면 모든 계정 관리형 키)
 * REPORTS_V2_ENABLED: 일일 보고 · 조용한 시간 (끄면 기존 알림만, 보고 설정 route 404 · cron/reports는 아무것도 하지 않는다)
 */
export const SERVER_FLAGS = [
  "CONVERSATIONS_V2_ENABLED",
  "MEMORY_ENABLED",
  "SOURCE_CHUNKS_ENABLED",
  "COORDINATOR_ENABLED",
  "AGENT_ADAPTER_CLAUDE_CODE_ENABLED",
  "BYOK_ENABLED",
  "REPORTS_V2_ENABLED",
] as const;
export type ServerFlag = (typeof SERVER_FLAGS)[number];

export function flagEnabled(flag: ServerFlag, env: Record<string, string | undefined> = process.env): boolean {
  return env[flag] === "true";
}
