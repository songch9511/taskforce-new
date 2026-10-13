// 0.2.0 서버 기능 gate (구현 계획 7장). 모두 기본 꺼짐이고 개발 서버도 같다: env 값이 정확히 "true"일 때만 켠다
// (대소문자 · 앞뒤 공백 · "1"은 꺼짐. billing/state.ts billingEnabled와 같은 비교, 인자는 env.ts executionEnabled처럼 env를 받는다).
// 기존 EXECUTION_ENABLED(env.ts) · BILLING_ENABLED(billing/state.ts)는 여기로 옮기지 않는다.
// 아직 이 gate를 읽는 코드는 없다 (A2는 계약 · 표 뼈대). 켜는 순서 · 경계는 구현 계획 7장 "플래그 켜기 경계".

/**
 * CONVERSATIONS_V2_ENABLED: 대화 v2 · 저장 (끄면 v1 Ask만)
 * MEMORY_ENABLED: 기억 저장 · 묶음 포함 (끄면 저장 0 · 포함 0)
 * SOURCE_CHUNKS_ENABLED: 원문 조각 임베딩 · 조각 검색 (끄면 조각 0)
 * COORDINATOR_ENABLED: 코디네이터 사건 처리 (끄면 inbox_events 적재만)
 * AGENT_ADAPTER_CLAUDE_CODE_ENABLED: Claude Code dispatch · Your agents 행 (끄면 dispatch 0. DB의 execution_controls도 따로 막는다)
 * AGENT_ADAPTER_CODEX_ENABLED: Codex 대화 (D1d, OD-2). 끄면 Codex는 대상 목록에서 빠지고 대화 만들기 · 보내기 · 세션 route가 404, 전달 시작 0.
 *   에이전트 대화 route는 CONVERSATIONS_V2_ENABLED와 이 adapter gate가 모두 켜져야 열린다
 * BYOK_ENABLED: 사용자 OpenRouter 키 입력 · 사용 (끄면 모든 계정 관리형 키)
 * REPORTS_V2_ENABLED: 일일 보고 · 조용한 시간 (끄면 기존 알림)
 * REVIEW_V2_ENABLED: Review · 복귀 요약 · 제안 (끄면 /api/v2/review · return-summary · suggestions는 404, 새 쓰기 0. 제안 생산은 이 gate AND 코디네이터 결과를 쓰는 종류는 COORDINATOR_ENABLED)
 * RETURN_SUMMARY_ENABLED: 복귀 요약만 (GET /api/v2/return-summary · POST …/clear · POST …/baseline 세 경로). Review GET · 제안 생산 · 노출 · snooze · dismiss는 열지 않는다.
 *   복귀 요약 경로는 이 gate **또는** REVIEW_V2_ENABLED가 정확히 "true"이면 열린다(returnSummaryEnabled). REVIEW_V2_ENABLED는 여섯 경로 전부를 여는 상위 집합이다.
 *   그 뒤 켜는 REVIEW_V2_ENABLED를 끄고 이것만 남겨도 복귀 요약은 그대로 열려 있고 Review · 제안 경로만 404가 된다 (끄면 세 경로 모두 404, 인증 · DB 호출 없음, 새 쓰기 0).
 */
export const SERVER_FLAGS = [
  "CONVERSATIONS_V2_ENABLED",
  "MEMORY_ENABLED",
  "SOURCE_CHUNKS_ENABLED",
  "COORDINATOR_ENABLED",
  "AGENT_ADAPTER_CLAUDE_CODE_ENABLED",
  "AGENT_ADAPTER_CODEX_ENABLED",
  "BYOK_ENABLED",
  "REPORTS_V2_ENABLED",
  "REVIEW_V2_ENABLED",
  "RETURN_SUMMARY_ENABLED",
] as const;
export type ServerFlag = (typeof SERVER_FLAGS)[number];

export function flagEnabled(flag: ServerFlag, env: Record<string, string | undefined> = process.env): boolean {
  return env[flag] === "true";
}

/** 복귀 요약 세 경로(GET return-summary · POST clear · POST baseline)의 gate: 좁은 RETURN_SUMMARY_ENABLED 또는 상위 REVIEW_V2_ENABLED. Review · 제안 경로는 REVIEW_V2_ENABLED만 본다 */
export function returnSummaryEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return flagEnabled("RETURN_SUMMARY_ENABLED", env) || flagEnabled("REVIEW_V2_ENABLED", env);
}
