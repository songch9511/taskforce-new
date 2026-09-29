import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { retryDeps, retryStalledSources } from "@/lib/sources/retry";
import { createAdminClient } from "@/lib/supabase/admin";

// 실패했거나 처리 도중 멈춘 글 원문 다시 처리 (Vercel Cron, 30분마다 · 동기화 cron과 겹치지 않게 7분 · 37분).
// Authorization: Bearer $CRON_SECRET 인 요청만 받는다. 한 원문은 첫 처리를 포함해 세 번까지 처리해 본다 (lib/sources/retry.ts).
export const maxDuration = 300;

// 한 건을 새로 시작하려면 남아 있어야 하는 시간: 추출 최악(90초 제한, 한 번 다시 시도) + 보통의 판정 · 병합.
// 상한은 아니다 (판정 · 임베딩도 시간 초과까지 가면 더 걸린다). 그래서 실행 한도에 끊기면 그 원문은 "처리 중"에 멈추고,
// 15분 뒤 다음 cron이 다시 처리한다 (이미 반영한 후보는 빼고 병합한다).
const ITEM_BUDGET_MS = 200_000;

export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  const started = Date.now();
  const result = await retryStalledSources(retryDeps(createAdminClient()), {
    now: new Date(started),
    // 응답할 시간을 남긴다
    deadline: started + (maxDuration - 20) * 1000,
    itemBudgetMs: ITEM_BUDGET_MS,
  });
  return Response.json(result);
}
