import { authenticateRequest } from "@/lib/api/auth";
import { handleCredits } from "@/lib/api/runs";
import { executionEnabled } from "@/lib/env";
import { executionGloballyBlocked, isExecutionActor, loadCreditDetails, loadCredits } from "@/lib/execution/store";
import { createAdminClient } from "@/lib/supabase/admin";

// 내 크레딧 합계 { available, reserved, rate_version } + Usage & Credits(S3) 숫자 { running_runs, settling, used, accepting_runs, draft_estimate_credits }.
// 원장 · 계정은 클라이언트가 읽지 못해(revoke all) 서버가 합계만 준다 (EXECUTION 12장). ?since=는 used를 셀 시작 시각 (contract.ts)
export async function GET(request: Request) {
  return handleCredits(request, {
    enabled: () => executionEnabled(),
    authenticate: authenticateRequest,
    isActor: ({ user }) => isExecutionActor(createAdminClient(), user.id),
    credits: ({ user }) => loadCredits(createAdminClient(), user.id),
    details: ({ user }, since) => loadCreditDetails(createAdminClient(), user.id, since),
    globallyBlocked: () => executionGloballyBlocked(createAdminClient()),
  });
}
