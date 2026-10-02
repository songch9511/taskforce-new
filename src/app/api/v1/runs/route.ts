import { after } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { RUN_CREATE_LIMIT } from "@/lib/api/rate-limit";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { handleCreateRun } from "@/lib/api/runs";
import { executionEnabled } from "@/lib/env";
import { actionIsOpen, createRun, executionGloballyBlocked, isExecutionActor, loadRunSummary } from "@/lib/execution/store";
import { advanceAndWake } from "@/lib/execution/wake";
import { createAdminClient } from "@/lib/supabase/admin";

// 내장 초안 run 만들기 (U2, docs/EXECUTION.md): 열린 내 Action에 run과 첫 계획 단계를 만들고 202 { run }.
// 첫 단계(계획)는 응답 뒤 after()에서 돈다. 다음 단계는 자기 호출(/api/cron/execution-advance)로, 놓치면 1분 sweep이 이어 간다.
// 실행 한도 = lease(330초, begin_call) - 여유 30초. 리터럴이어야 해서 limits.ts EXECUTION_MAX_DURATION_S와 같은지 route.test.ts가 본다.
export const maxDuration = 300;

export async function POST(request: Request) {
  return handleCreateRun(request, {
    enabled: () => executionEnabled(),
    authenticate: authenticateRequest,
    isActor: ({ user }) => isExecutionActor(createAdminClient(), user.id),
    globallyBlocked: () => executionGloballyBlocked(createAdminClient()),
    hasConsent: hasAiConsent,
    actionOpen: ({ supabase }, actionId) => actionIsOpen(supabase, actionId),
    rateLimit: ({ user }) => takeRateLimit(createAdminClient(), user.id, "run_create", RUN_CREATE_LIMIT),
    createRun: ({ user }, run) =>
      createRun(createAdminClient(), user.id, { actionId: run.action_id, goal: run.goal, request: run.request, budgetCredits: run.budget_credits ?? null }),
    loadRun: ({ user }, runId) => loadRunSummary(createAdminClient(), user.id, runId),
    schedule: (runId) => after(() => advanceAndWake(runId)),
  });
}
