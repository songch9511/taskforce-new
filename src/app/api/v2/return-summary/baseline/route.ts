import { authenticateRequest } from "@/lib/api/auth";
import { handleInitializeReturnSummaryBaseline } from "@/lib/api/review";
import { flagEnabled } from "@/lib/flags";
import { initializeReturnSummaryBaseline } from "@/lib/review/return-summary";
import { createAdminClient } from "@/lib/supabase/admin";

// 복귀 요약 첫 정상 표시 기준점 확정 (C3 A–D 후속 C): GET이 준 init_token을 앱이 그 응답을 정상으로 표시했을 때만 보낸다. gate REVIEW_V2_ENABLED가 꺼져 있으면 404.
// 200 { status, applied } (initialized | already_initialized) · 409 conflict(조회 뒤 범위가 달라짐) · 400 잘못된 토큰 · 401 · 쿠키 CSRF는 authenticateRequest.
// 읽음 표시일 뿐이다: 미열람 Action 변화 · 미결정 · Claim · 승인 · 정책은 건드리지 않는다.
export async function POST(request: Request) {
  return handleInitializeReturnSummaryBaseline(request, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED"),
    authenticate: authenticateRequest,
    initialize: ({ user }, token) => initializeReturnSummaryBaseline(createAdminClient(), user.id, token),
  });
}
