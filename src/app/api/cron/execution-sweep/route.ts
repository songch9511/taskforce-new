import { after } from "next/server";

import { reconcileAiSpend } from "@/lib/ai/budget";
import { fetchGeneration, generationConfigFromEnv } from "@/lib/ai/generation";
import { expireAgentMessagesQuietly } from "@/lib/agents/messages";
import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { sweepBridge } from "@/lib/bridge/sweep";
import { wakeCoordinator } from "@/lib/coordinator/wake";
import { executionEnabled } from "@/lib/env";
import { supabaseExecutionStore } from "@/lib/execution/store";
import { sweep } from "@/lib/execution/sweep";
import { wakeRun } from "@/lib/execution/wake";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 실행 sweep (Vercel Cron 1분, vercel.json). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
// lease 만료 정리 · 미확정 원가 확정 · 끝난 run의 남은 예약 해제 · 이어 갈 run 깨우기(자기 호출) · 빠진 receipt 이어 쓰기. 단계를 직접 돌리지 않는다 (lib/execution/sweep.ts).
// 공통 AI 원가 확인은 실행 플래그와 무관하다. 실행 플래그는 기존 execution sweep만 제어한다.
// 조회 · 깨우기는 함께 보내고 각각 10초 한도라 60초면 넉넉하다.
export const maxDuration = 60;

// 코디네이터 1분 회수 (0.2.0 C2): 응답을 보낸 뒤 코디네이터를 깨우는 자기 호출 하나만 한다 (COORDINATOR_ENABLED가 꺼져 있으면 아무것도 하지 않는다).
// 처리는 받는 쪽(POST /api/cron/coordinator-advance)의 별도 함수에서 돈다: 이 sweep의 시간 · 응답 · 실패 의미를 바꾸지 않는다. 깨우기 실패는 가둔다(wakeCoordinator는 던지지 않는다).
function scheduleCoordinatorWake() {
  if (!flagEnabled("COORDINATOR_ENABLED")) return;
  try {
    after(() => wakeCoordinator());
  } catch (error) {
    console.error(JSON.stringify({ event: "coordinator_wake_schedule_failed", error: error instanceof Error ? error.name : "unknown" }));
  }
}

export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  scheduleCoordinatorWake();
  const admin = createAdminClient();
  await sweepBridge(admin).then((result) => console.info(JSON.stringify({ event: "bridge_sweep", ...result }))).catch(() => console.error(JSON.stringify({ event: "bridge_sweep_failed" })));
  // 에이전트 대기 메시지 만료 (OA D1d): 실행 플래그와 무관하게 돌고, 실패는 가둔다 (응답 불변)
  await expireAgentMessagesQuietly(admin);
  const aiSpend = await reconcileAiSpend(admin);
  // Listing/configuration failures previously aborted the route: retain HTTP 500 for those.
  if (aiSpend.errors > 0 && aiSpend.attempted === 0) {
    console.error(JSON.stringify({ event: "execution_sweep", ai_spend: aiSpend }));
    return Response.json({ error: "AI spend reconciliation could not start" }, { status: 500 });
  }
  if (!executionEnabled()) {
    (aiSpend.errors > 0 ? console.error : console.info)(JSON.stringify({ event: "execution_sweep", enabled: false, ai_spend: aiSpend }));
    return Response.json({ enabled: false });
  }
  const result = await sweep({
    store: supabaseExecutionStore(admin),
    lookupGeneration: (id) => fetchGeneration(generationConfigFromEnv(), id),
    wake: (runId) => wakeRun(runId),
  });
  // 실패한 단계가 있으면 오류 로그로 (cron 응답은 그대로 200: 다음 분에 다시 돈다)
  (result.errors > 0 || aiSpend.errors > 0 ? console.error : console.info)(JSON.stringify({ event: "execution_sweep", ...result, ai_spend: aiSpend }));
  return Response.json({ enabled: true, ...result });
}
