import { agentBetaUserAllowed, flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

import { authenticateRequest, type ApiContext } from "./auth";
import { projectSessionsOpenedRequestSchema, subagentQuestionRedirectedRequestSchema, subagentRowOpenedRequestSchema, subagentTurnUsedRequestSchema } from "./contract";
import { parseCappedBody } from "./external-sessions";
import { errorResponse, unauthorized } from "./respond";

// 하위 에이전트 트리 지표 네 종류 route 처리 (T3s, 마이그레이션 20261209000000): 앱이 v2 route로 알리면 route가 서버 권한으로 metric_events에 남긴다 (앱은 이 종류를 직접 넣지 못한다).
// 모양 · 문 · 시험 방식은 claude_app_session_opened(external-sessions.ts handleClaudeAppSessionOpened)와 같다. 인증 · gate · 저장을 인자로 받아 Route Handler 밖에서 테스트한다.
//   · 열기 둘 (project_sessions_opened · subagent_row_opened): 본문은 빈 객체뿐, 사용자별 UTC 날짜마다 한 번 (부분 unique 인덱스, 두 번째는 23505를 조용히 넘긴다)
//   · T2 둘 (subagent_turn_used · subagent_question_redirected): 본문은 턴 id(agent_task_id) 하나뿐, 턴마다 한 번. 서버가 그 id가 **이 사용자의 Claude Code 턴**인지 같은 요청 안에서 확인한다
// gate: CONVERSATIONS_V2_ENABLED ∧ AGENT_ADAPTER_CLAUDE_CODE_ENABLED가 꺼져 있으면 인증 · DB 전에 404, 베타 명단 밖 사용자도 404 (에이전트 대화와 같은 문). 응답은 늘 204 (같은 단위의 두 번째도).
// 턴 id · 사용자 id는 로그 · 오류 응답에 담지 않는다 (이벤트 이름 · 오류 이름 · code만). 요청 값은 어느 응답에도 되돌리지 않는다.

/** 지표 본문은 빈 객체 또는 턴 id 하나뿐이다 */
const MAX_BODY_BYTES = 1024;
const NOT_FOUND = "없는 경로입니다.";
/** T2 둘의 확인 기준: 턴이 속한 세션의 연결 adapter (agent_tasks에는 adapter 칸이 없다) */
const CLAUDE_CODE_ADAPTER = "agent:claude-code";

// 종류마다 이름과 본문 스키마를 한 곳에 둔다. type 글자는 이 파일이 남기는 지표의 집이다 (tests/metrics/agent-event-registry.test.ts R2가 이 파일에서 type을 찾는다).
export const PROJECT_SESSIONS_OPENED = { type: "project_sessions_opened", schema: projectSessionsOpenedRequestSchema } as const;
export const SUBAGENT_ROW_OPENED = { type: "subagent_row_opened", schema: subagentRowOpenedRequestSchema } as const;
export const SUBAGENT_TURN_USED = { type: "subagent_turn_used", schema: subagentTurnUsedRequestSchema } as const;
export const SUBAGENT_QUESTION_REDIRECTED = { type: "subagent_question_redirected", schema: subagentQuestionRedirectedRequestSchema } as const;

export type AgentTreeDayMetric = typeof PROJECT_SESSIONS_OPENED | typeof SUBAGENT_ROW_OPENED;
export type AgentTreeTurnMetric = typeof SUBAGENT_TURN_USED | typeof SUBAGENT_QUESTION_REDIRECTED;

type AppUser = { user: { id: string } };

export type AgentTreeMetricsDeps<User extends AppUser> = {
  /** gate (대화 v2 ∧ Claude Code adapter). 꺼져 있으면 인증 · DB 전에 404 */
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  betaAllowed: (userId: string) => boolean;
  /** 열기 지표: 같은 날(UTC) 두 번째는 "duplicate" (서버가 조용히 넘긴다) */
  recordDay: (user: User, type: AgentTreeDayMetric["type"]) => Promise<"recorded" | "duplicate">;
  /** T2 지표: 이 사용자의 Claude Code 턴이 아니면 "not_found" (없음 · 남의 것 · Codex를 구별하지 않는다), 같은 턴 두 번째는 "duplicate". 턴 id는 소문자 uuid다 */
  recordTurn: (user: User, type: AgentTreeTurnMetric["type"], agentTaskId: string) => Promise<"recorded" | "duplicate" | "not_found">;
};

function codeOf(error: unknown): string | undefined {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  return typeof code === "string" ? code : undefined;
}

function logFailure(type: string, error: unknown) {
  console.error(JSON.stringify({ event: `${type}_failed`, error: error instanceof Error ? error.name : "unknown", ...(codeOf(error) ? { code: codeOf(error) } : {}) }));
}

/** 네 route가 같은 문: gate → 인증 401 → 베타 명단 404. 통과하면 사용자, 아니면 그대로 돌려줄 응답 */
async function admit<User extends AppUser>(request: Request, deps: AgentTreeMetricsDeps<User>): Promise<{ user: User } | { error: Response }> {
  if (!deps.enabled()) return { error: errorResponse(404, "not_found", NOT_FOUND) };
  const user = await deps.authenticate(request);
  if (!user) return { error: unauthorized() };
  if (!deps.betaAllowed(user.user.id)) return { error: errorResponse(404, "not_found", NOT_FOUND) };
  return { user };
}

/**
 * POST /api/v2/agent-tree/project-sessions-opened · subagent-opened: 열린 날의 지표. 본문은 빈 객체뿐이다(칸이 하나라도 있으면 400).
 * 응답은 늘 204 (같은 날 두 번째도)
 */
export async function handleAgentTreeDayMetric<User extends AppUser>(request: Request, metric: AgentTreeDayMetric, deps: AgentTreeMetricsDeps<User>): Promise<Response> {
  const admitted = await admit(request, deps);
  if ("error" in admitted) return admitted.error;
  const body = await parseCappedBody(request, metric.schema, MAX_BODY_BYTES);
  if ("error" in body) return body.error;
  try {
    await deps.recordDay(admitted.user, metric.type);
    return new Response(null, { status: 204 });
  } catch (error) {
    logFailure(metric.type, error);
    return errorResponse(500, "internal_error", "이벤트를 남기지 못했습니다.");
  }
}

/**
 * POST /api/v2/agent-tree/turn-used · question-redirected: 턴 하나의 지표. 본문은 { agent_task_id } 하나뿐이다.
 * 그 id가 이 사용자의 Claude Code 턴이 아니면 404 (남의 턴 id로 세지 못한다). 응답은 같은 턴 두 번째도 204
 */
export async function handleAgentTreeTurnMetric<User extends AppUser>(request: Request, metric: AgentTreeTurnMetric, deps: AgentTreeMetricsDeps<User>): Promise<Response> {
  const admitted = await admit(request, deps);
  if ("error" in admitted) return admitted.error;
  const body = await parseCappedBody(request, metric.schema, MAX_BODY_BYTES);
  if ("error" in body) return body.error;
  try {
    // uuid는 대소문자를 가리지 않는다: 같은 턴을 대소문자로 두 번 세지 못하게 소문자로 맞춘다 (DB 검사도 소문자만 받는다)
    const outcome = await deps.recordTurn(admitted.user, metric.type, body.data.agent_task_id.toLowerCase());
    if (outcome === "not_found") return errorResponse(404, "not_found", "턴을 찾지 못했습니다.");
    return new Response(null, { status: 204 });
  } catch (error) {
    logFailure(metric.type, error);
    return errorResponse(500, "internal_error", "이벤트를 남기지 못했습니다.");
  }
}

/** 이 id가 이 사용자의 agent_tasks 행이고, 그 세션의 연결 adapter가 Claude Code인가. 세 단계 모두 user_id가 맞아야 한다. 사용자 글(질문 · 메시지)은 읽지 않는다 */
async function isClaudeCodeTurn(userId: string, agentTaskId: string): Promise<boolean> {
  const admin = createAdminClient();
  const { data: task } = await admin.from("agent_tasks").select("agent_session_id").eq("user_id", userId).eq("id", agentTaskId).maybeSingle().throwOnError();
  if (!task) return false;
  const { data: session } = await admin.from("agent_sessions").select("connection_id").eq("user_id", userId).eq("id", task.agent_session_id).maybeSingle().throwOnError();
  if (!session) return false;
  const { data: connection } = await admin.from("agent_connections").select("adapter").eq("user_id", userId).eq("id", session.connection_id).maybeSingle().throwOnError();
  return connection?.adapter === CLAUDE_CODE_ADAPTER;
}

/** 앱의 열 권한(type · action_id)을 넓히지 않으려고 값을 검증한 뒤 서버 권한으로 남긴다. 같은 단위의 두 번째는 23505 (20261209000000의 부분 unique 인덱스) */
async function insertMetric(userId: string, type: string, props: Record<string, string>): Promise<"recorded" | "duplicate"> {
  const { error } = await createAdminClient().from("metric_events").insert({ user_id: userId, type, props });
  if (error?.code === "23505") return "duplicate";
  if (error) throw error;
  return "recorded";
}

export const realAgentTreeMetricsDeps = (): AgentTreeMetricsDeps<ApiContext> => ({
  enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED") && flagEnabled("AGENT_ADAPTER_CLAUDE_CODE_ENABLED"),
  authenticate: authenticateRequest,
  betaAllowed: agentBetaUserAllowed,
  // 종류만 (props 0). 하루 한 번(UTC 날짜별 부분 unique 인덱스)
  recordDay: ({ user }, type) => insertMetric(user.id, type, {}),
  // props는 턴 id 하나뿐이다 (DB 전용 check가 키 · 소문자 uuid 글자를 강제한다). 확인과 insert는 같은 요청 안에서 한다
  recordTurn: async ({ user }, type, agentTaskId) => {
    if (!(await isClaudeCodeTurn(user.id, agentTaskId))) return "not_found";
    return insertMetric(user.id, type, { agent_task_id: agentTaskId });
  },
});
