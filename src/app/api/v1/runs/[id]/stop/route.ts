import { authenticateRequest } from "@/lib/api/auth";
import { handleStopRun } from "@/lib/api/runs";
import { executionEnabled } from "@/lib/env";
import { isExecutionActor, loadRunSummary, stopRun } from "@/lib/execution/store";
import { createAdminClient } from "@/lib/supabase/admin";

// run 멈추기: 다음 단계만 막는다. 이미 부르는 단계(calling)는 끝까지 결과를 받고, 남은 예약은 트리거가 해제한다 (EXECUTION 5 · 12장).
// 이미 끝난 run이면 그대로 200 { run }. 없거나 남의 run 404
type Params = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Params) {
  const { id } = await params;
  return handleStopRun(request, id, {
    enabled: () => executionEnabled(),
    authenticate: authenticateRequest,
    isActor: ({ user }) => isExecutionActor(createAdminClient(), user.id),
    stopRun: ({ user }, runId) => stopRun(createAdminClient(), user.id, runId),
    loadRun: ({ user }, runId) => loadRunSummary(createAdminClient(), user.id, runId),
  });
}
