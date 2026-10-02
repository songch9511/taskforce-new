import { fetchGeneration, generationConfigFromEnv } from "@/lib/ai/generation";
import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { executionEnabled } from "@/lib/env";
import { supabaseExecutionStore } from "@/lib/execution/store";
import { sweep } from "@/lib/execution/sweep";
import { wakeRun } from "@/lib/execution/wake";
import { createAdminClient } from "@/lib/supabase/admin";

// 실행 sweep (Vercel Cron 1분, vercel.json). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
// lease 만료 정리 · 미확정 원가 확정 · 끝난 run의 남은 예약 해제 · 이어 갈 run 깨우기(자기 호출). 단계를 직접 돌리지 않는다 (lib/execution/sweep.ts).
// 기능 플래그가 꺼져 있으면 아무것도 하지 않고 바로 끝난다. 로그에는 숫자만 남긴다.
// 조회 · 깨우기는 함께 보내고 각각 10초 한도라 60초면 넉넉하다.
export const maxDuration = 60;

export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  if (!executionEnabled()) return Response.json({ enabled: false });
  const result = await sweep({
    store: supabaseExecutionStore(createAdminClient()),
    lookupGeneration: (id) => fetchGeneration(generationConfigFromEnv(), id),
    wake: (runId) => wakeRun(runId),
  });
  console.info(JSON.stringify({ event: "execution_sweep", ...result }));
  return Response.json({ enabled: true, ...result });
}
