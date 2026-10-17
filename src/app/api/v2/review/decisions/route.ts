import { authenticateRequest } from "@/lib/api/auth";
import { handleGetReviewDecisions } from "@/lib/api/review";
import { flagEnabled } from "@/lib/flags";
import { loadReviewDecisions } from "@/lib/review/review";
import { createAdminClient } from "@/lib/supabase/admin";

// 결정만 읽기 (OA R-dec, U3-21): GET /api/v2/review와 같은 결정 계산(순서 · version · 에이전트 ref)인데 Taskforce 행을 쓰지 않는다 — 제안 생산 · 노출 · 그날 묶음 소비 0 (공유 인증 계층의 쿠키 세션 갱신은 다른 경로와 같다).
// gate는 REVIEW_V2_ENABLED 하나다(꺼지면 404, 인증 · DB 0). 에이전트 입력은 loadReview처럼 openAgentAdapters()가 환경에서 정한다(adapter를 넘기지 않는다).
// 200 ReviewDecisionsResponse(결정 원천을 못 읽으면 sources.decisions unavailable) · 401 · 500. 쿠키 인증 GET은 CSRF 검사 대상이 아니다 — Taskforce 행을 쓰지 않으므로 문제없다.
export async function GET(request: Request) {
  return handleGetReviewDecisions(request, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED"),
    authenticate: authenticateRequest,
    load: ({ user }, now) => loadReviewDecisions(createAdminClient(), user.id, now),
  });
}
