import { authenticateRequest } from "@/lib/api/auth";
import { handleGetReturnSummary } from "@/lib/api/review";
import { returnSummaryEnabled } from "@/lib/flags";
import { loadReturnSummary } from "@/lib/review/return-summary";
import { createAdminClient } from "@/lib/supabase/admin";

// 복귀 요약 (C3, ARCH25 · A40): 떠나 있던 동안 바뀐 것 · 필요한 결정 · 다음 행동을 기존 이벤트에서 계산한다. gate RETURN_SUMMARY_ENABLED 또는 REVIEW_V2_ENABLED가 모두 꺼져 있으면 404.
// 코디네이터 게이트(COORDINATOR_ENABLED)와 무관하다: 실제 원천 표를 읽는다. 아무것도 쓰지 않는다. 200 ReturnSummaryResponse · 401.
export async function GET(request: Request) {
  return handleGetReturnSummary(request, {
    enabled: () => returnSummaryEnabled(),
    authenticate: authenticateRequest,
    load: ({ user }, now) => loadReturnSummary(createAdminClient(), user.id, now),
  });
}
