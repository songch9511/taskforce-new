import { authenticateRequest } from "@/lib/api/auth";
import { handleClearReturnSummary } from "@/lib/api/review";
import { flagEnabled } from "@/lib/flags";
import { clearReturnSummary } from "@/lib/review/return-summary";
import { createAdminClient } from "@/lib/supabase/admin";

// 복귀 요약 Clear (C3): 조회가 낸 커서의 범위를 읽음 처리한다 — 읽음일 뿐 해결 · 승인 · 완료 · 거절이 아니다. gate REVIEW_V2_ENABLED가 꺼져 있으면 404.
// 200 { cleared_through, applied } · 409 conflict(조회 뒤 범위가 달라짐: 다시 조회) · 400 잘못된 커서 · 401 · 쿠키 CSRF는 authenticateRequest.
export async function POST(request: Request) {
  return handleClearReturnSummary(request, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED"),
    authenticate: authenticateRequest,
    clear: ({ user }, cursor) => clearReturnSummary(createAdminClient(), user.id, cursor),
  });
}
