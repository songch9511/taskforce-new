import { z } from "zod";

import { agentBetaUserAllowed, flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

import { authenticateRequest, type ApiContext } from "./auth";
import {
  externalSessionReportRequestSchema,
  externalSessionsShownRequestSchema,
  type ExternalSessionReportRequest,
  type ExternalSessionReportResponse,
  type ExternalSessionsShownRequest,
} from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// 외부 세션 목록 route 처리 (OA 외부 세션 PR1, 계약 16장): Mac이 Taskforce 밖에서 시작한 Claude Code 세션의 제목 · 상태 · 마지막 활동 시각 · 불투명 id를 알린다.
// 스냅샷 교체다 (SQL 함수 report_external_sessions, 20261203000000). 인증 · gate · 저장을 인자로 받아 Route Handler 밖에서 테스트한다 (agent-conversations.ts와 같은 방식).
// gate: CONVERSATIONS_V2_ENABLED ∧ AGENT_ADAPTER_CLAUDE_CODE_ENABLED가 꺼져 있으면 인증 · DB 전에 404, 베타 명단 밖 사용자도 404 (에이전트 대화와 같은 문).
// 제목은 사용자 글에 가깝다: 로그 · 오류 메시지에 담지 않는다 (이벤트 이름 · 오류 이름 · 코드만). 요청 값은 어느 응답에도 되돌리지 않는다.

/** Mac이 보고를 멈춘 행을 지우는 기간 (매일 도는 /api/cron/retention → purge_external_sessions). 목록은 7일 창이라 두 배로 둔다 */
export const EXTERNAL_SESSION_RETENTION_DAYS = 14;

/** 본문 상한: 50개 × (제목 200자가 모두 \uXXXX로 이스케이프돼도 1.2 KB + 나머지) < 128 KiB. 이보다 크면 읽지 않고 거절한다 */
const MAX_BODY_BYTES = 128 * 1024;

type AppUser = { user: { id: string } };

export type ExternalSessionReportOutcome = ({ status: "ok" } & ExternalSessionReportResponse) | { status: "not_found" };

export type ExternalSessionsDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  betaAllowed: (userId: string) => boolean;
  report: (user: User, input: ExternalSessionReportRequest) => Promise<ExternalSessionReportOutcome>;
  /** 지표 external_sessions_shown: 같은 날 두 번째는 "duplicate" (서버가 조용히 넘긴다) */
  recordShown: (user: User, input: ExternalSessionsShownRequest) => Promise<"recorded" | "duplicate">;
};

const NOT_FOUND = "없는 경로입니다.";

function codeOf(error: unknown): string | undefined {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  return typeof code === "string" ? code : undefined;
}

/** PUT /api/v2/external-sessions: 이 Mac의 목록을 스냅샷으로 교체한다. 남의 bridge · 해제된 bridge · 모르는 bridge는 모두 404 (존재를 알리지 않는다) */
export async function handleReportExternalSessions<User extends AppUser>(request: Request, deps: ExternalSessionsDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!deps.betaAllowed(user.user.id)) return errorResponse(404, "not_found", NOT_FOUND);
  const length = Number(request.headers.get("content-length"));
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) return errorResponse(400, "invalid_request", "본문이 너무 큽니다.");
  const body = await parseBody(request, externalSessionReportRequestSchema);
  if ("error" in body) return body.error;
  try {
    const outcome = await deps.report(user, body.data);
    if (outcome.status === "not_found") return errorResponse(404, "not_found", "이 Mac을 찾지 못했습니다.");
    return Response.json({ kept: outcome.kept, removed: outcome.removed } satisfies ExternalSessionReportResponse);
  } catch (error) {
    console.error(JSON.stringify({ event: "external_sessions_report_failed", error: error instanceof Error ? error.name : "unknown", ...(codeOf(error) ? { code: codeOf(error) } : {}) }));
    return errorResponse(500, "internal_error", "목록을 저장하지 못했습니다.");
  }
}

/** POST /api/v2/external-sessions/shown: 레일 목록이 행 1개 이상으로 보인 날의 지표. 구간 값만 받고 응답은 늘 204 (같은 날 두 번째도) */
export async function handleExternalSessionsShown<User extends AppUser>(request: Request, deps: ExternalSessionsDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!deps.betaAllowed(user.user.id)) return errorResponse(404, "not_found", NOT_FOUND);
  const body = await parseBody(request, externalSessionsShownRequestSchema);
  if ("error" in body) return body.error;
  try {
    await deps.recordShown(user, body.data);
    return new Response(null, { status: 204 });
  } catch (error) {
    console.error(JSON.stringify({ event: "external_sessions_shown_failed", error: error instanceof Error ? error.name : "unknown", ...(codeOf(error) ? { code: codeOf(error) } : {}) }));
    return errorResponse(500, "internal_error", "이벤트를 남기지 못했습니다.");
  }
}

const rpcResultSchema = z.union([z.strictObject({ status: z.literal("ok"), kept: z.number().int().min(0), removed: z.number().int().min(0) }), z.strictObject({ status: z.literal("not_found") })]);

export const realExternalSessionsDeps = (): ExternalSessionsDeps<ApiContext> => ({
  enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED") && flagEnabled("AGENT_ADAPTER_CLAUDE_CODE_ENABLED"),
  authenticate: authenticateRequest,
  betaAllowed: agentBetaUserAllowed,
  report: async ({ user }, input) => {
    const { data, error } = await createAdminClient().rpc("report_external_sessions", { p_user_id: user.id, p_bridge_id: input.bridge_id, p_sessions: input.sessions });
    if (error) throw error;
    return rpcResultSchema.parse(data);
  },
  // 앱의 열 권한(type · action_id)을 넓히지 않으려고 구간 값을 검증한 뒤 서버 권한으로 남긴다. 하루 한 번(UTC 날짜별 부분 unique 인덱스): 두 번째는 23505
  recordShown: async ({ user }, input) => {
    const { error } = await createAdminClient().from("metric_events").insert({ user_id: user.id, type: "external_sessions_shown", props: input });
    if (error?.code === "23505") return "duplicate";
    if (error) throw error;
    return "recorded";
  },
});
