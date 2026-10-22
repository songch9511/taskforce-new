// 0.2.0 서버 기능 gate (구현 계획 7장). 모두 기본 꺼짐이고 개발 서버도 같다: env 값이 정확히 "true"일 때만 켠다
// (대소문자 · 앞뒤 공백 · "1"은 꺼짐. billing/state.ts billingEnabled와 같은 비교, 인자는 env.ts executionEnabled처럼 env를 받는다).
// 기존 EXECUTION_ENABLED(env.ts) · BILLING_ENABLED(billing/state.ts)는 여기로 옮기지 않는다.
// 읽는 코드는 gate마다 다르다 (A2는 계약 · 표 뼈대). BYOK_ENABLED는 결제 서버(billing/state.ts)가 읽는다. 켜는 순서 · 경계는 구현 계획 7장 "플래그 켜기 경계".

/**
 * CONVERSATIONS_V2_ENABLED: 대화 v2 · 저장 (끄면 v1 Ask만)
 * MEMORY_ENABLED: 기억 저장 · 묶음 포함 (끄면 저장 0 · 포함 0)
 * SOURCE_CHUNKS_ENABLED: 원문 조각 임베딩 · 조각 검색 (끄면 조각 0)
 * COORDINATOR_ENABLED: 코디네이터 사건 처리 (끄면 inbox_events 적재만)
 * AGENT_ADAPTER_CLAUDE_CODE_ENABLED: Claude Code dispatch · Your agents 행 (끄면 dispatch 0. DB의 execution_controls도 따로 막는다)
 * AGENT_ADAPTER_CODEX_ENABLED: Codex 대화 (D1d, OD-2). 끄면 Codex는 대상 목록에서 빠지고 대화 만들기 · 보내기 · 세션 route가 404, 전달 시작 0.
 *   에이전트 대화 route는 CONVERSATIONS_V2_ENABLED와 이 adapter gate가 모두 켜져야 열린다
 * BYOK_ENABLED: Lifetime 판매 · 사용자 OpenRouter 키 입력 · 사용. 끄면 Lifetime 판매 · 키 route가 닫히고, Lifetime 계정의 AI는 닫힌 쪽으로 멈춘다 (관리형 키로 새지 않는다 — DB가 byok_required로 거절). 결제(billing/state.ts planState)가 can_buy_lifetime을 정할 때 읽는다
 * REPORTS_V2_ENABLED: 일일 보고 · 조용한 시간 (끄면 기존 알림)
 * REVIEW_V2_ENABLED: Review · 복귀 요약 · 제안 · 결정만 읽기 경로 (끄면 /api/v2/review · /api/v2/review/decisions(결정만, Taskforce 행 쓰기 0) · return-summary · suggestions는 404, 새 쓰기 0. 제안 생산은 이 gate AND 코디네이터 결과를 쓰는 종류는 COORDINATOR_ENABLED)
 * RETURN_SUMMARY_ENABLED: 복귀 요약만 (GET /api/v2/return-summary · POST …/clear · POST …/baseline 세 경로). Review GET · 제안 생산 · 노출 · snooze · dismiss는 열지 않는다.
 *   복귀 요약 경로는 이 gate **또는** REVIEW_V2_ENABLED가 정확히 "true"이면 열린다(returnSummaryEnabled). REVIEW_V2_ENABLED는 여섯 경로 전부(와 결정만 읽기 경로)를 여는 상위 집합이다.
 *   그 뒤 켜는 REVIEW_V2_ENABLED를 끄고 이것만 남겨도 복귀 요약은 그대로 열려 있고 Review · 제안 경로만 404가 된다 (끄면 세 경로 모두 404, 인증 · DB 호출 없음, 새 쓰기 0).
 * EXTERNAL_SESSIONS_REPORT_ENABLED: Mac이 Taskforce 밖에서 시작한 Claude Code 세션의 **제목을 서버에 올리는** PUT /api/v2/external-sessions만 연다 (끄면 404, 인증 · DB 호출 없음, 저장 0).
 *   이 route는 CONVERSATIONS_V2_ENABLED · AGENT_ADAPTER_CLAUDE_CODE_ENABLED · 베타 명단도 함께 통과해야 한다. 처리방침(#169)이 "제목을 서버에 보낸다"고 게시되기 전에는 켜지 않는다.
 *   Mac 레일 목록 자체는 서버 없이 로컬에서 만든다: 이 gate를 끄면 올리기만 멈춘다. 구간 값만 받는 POST …/shown 지표는 이 gate를 보지 않는다.
 * AGENT_ATTACH_EXISTING_ENABLED: Taskforce 밖에서 시작한 Claude Code 세션을 Taskforce 세션으로 **이어받는** POST /api/v2/agent-sessions/attach만 연다 (끄면 403, 인증 · DB 호출 없음, 저장 0).
 *   이 route는 CONVERSATIONS_V2_ENABLED · 그 adapter 플래그(AGENT_ADAPTER_CLAUDE_CODE_ENABLED) · 베타 명단 · registry의 session.attach_existing(Claude Code만 true)도 함께 통과해야 한다.
 *   이 gate는 새로 이어받는 입구만 닫는다: 이미 이어받은 세션의 대화 · Stop은 다른 gate가 정한다.
 * CLAUDE_APP_CHATS_ENABLED: Mac이 Claude 데스크톱 세션으로 보낸 글과 그 뒤 답 글(도구 단계 이름 포함)을 **서버에 저장하는** 경로만 연다 (OA PR-D3s, 계약 25 · 26장):
 *   GET /api/v2/claude-app-chats/status · PUT /api/v2/claude-app-chats · DELETE /api/v2/claude-app-chats/{id} (끄면 404, 인증 · DB 호출 없음, 저장 0 — Mac은 404면 글을 서버로 보내지 않는다).
 *   이 route들은 CONVERSATIONS_V2_ENABLED · AGENT_ADAPTER_CLAUDE_CODE_ENABLED · 베타 명단도 함께 통과해야 한다. **기본 꺼짐이고 아래 넷이 모두 끝나기 전에는 켜지 않는다**:
 *   ① 마이그레이션 20261207000000 적용 ② PR-D3s · D3k Opus 보안 검토 ③ 처리방침 문장(25.8 + 26장 보존 문구) 게시 ④ 저장된 대화를 보고 지우는 화면(D3v) 병합.
 *   보내기 결과 지표 POST /api/v2/external-sessions/claude-app-sent는 이 gate를 보지 않는다 (글 0, 코드만). 저장된 대화는 사용자가 지우거나 계정을 지울 때까지 보관한다 (자동 삭제 없음).
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
  "EXTERNAL_SESSIONS_REPORT_ENABLED",
  "AGENT_ATTACH_EXISTING_ENABLED",
  "CLAUDE_APP_CHATS_ENABLED",
] as const;
export type ServerFlag = (typeof SERVER_FLAGS)[number];

export function flagEnabled(flag: ServerFlag, env: Record<string, string | undefined> = process.env): boolean {
  return env[flag] === "true";
}

/** 복귀 요약 세 경로(GET return-summary · POST clear · POST baseline)의 gate: 좁은 RETURN_SUMMARY_ENABLED 또는 상위 REVIEW_V2_ENABLED. Review · 제안 경로는 REVIEW_V2_ENABLED만 본다 */
export function returnSummaryEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return flagEnabled("RETURN_SUMMARY_ENABLED", env) || flagEnabled("REVIEW_V2_ENABLED", env);
}

/** Explicit deployment snapshot, independent of billing/notice state. A malformed entry closes the entire cohort. */
export function agentBetaUserAllowed(userId: string, env: Record<string, string | undefined> = process.env): boolean {
  if (!flagEnabled("CONVERSATIONS_V2_ENABLED", env)) return false;
  const raw = env.AGENT_BETA_USER_IDS;
  if (!raw) return false;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const ids = raw.split(",");
  if (userId.length !== 36 || !uuid.test(userId) || ids.some((id) => id.length !== 36 || !uuid.test(id))) return false;
  return ids.some((id) => id.toLowerCase() === userId.toLowerCase());
}
