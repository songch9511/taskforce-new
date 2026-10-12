import { authenticateRequest } from "@/lib/api/auth";
import { handleGetReview } from "@/lib/api/review";
import { flagEnabled } from "@/lib/flags";
import { loadReview } from "@/lib/review/review";
import { createAdminClient } from "@/lib/supabase/admin";

// Review (C3, 구현 계획 7장): C2 결정 대기 계산 + 열린 제안. gate REVIEW_V2_ENABLED가 꺼져 있으면 404 (인증 · DB를 부르지 않는다, 새 쓰기 0).
// 200 ReviewResponse(일부를 못 읽으면 그 부분 unavailable) · 401. 읽기는 결정을 해결하지 않고, 제안을 보는 것은 Action · run을 만들지 않는다.
// 코디네이터 결과를 쓰는 제안 종류는 COORDINATOR_ENABLED도 켜져 있을 때만 읽는다.
export async function GET(request: Request) {
  return handleGetReview(request, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED"),
    authenticate: authenticateRequest,
    load: ({ user }, now) => loadReview(createAdminClient(), user.id, now, { coordinatorEnabled: flagEnabled("COORDINATOR_ENABLED") }),
  });
}
