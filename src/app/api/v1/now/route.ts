import type { SupabaseClient } from "@supabase/supabase-js";

import { nowList } from "@/lib/actions/service";
import { authenticateRequest } from "@/lib/api/auth";
import type { NowResponse } from "@/lib/api/contract";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { weeklyCheckEnabled } from "@/lib/env";
import { previousKstWeek, weeklyCheckDue } from "@/lib/metrics/weekly-check";

// 지금 할 일 순서와 확인 요청 목록, 이번 주에 물을 주간 질문. 순서 계산은 서버에만 둔다 (앱에 같은 로직을 두지 않는다).
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  try {
    const now = new Date();
    const [ranked, weekly] = await Promise.all([nowList(context.supabase, now), weeklyCheck(context.supabase, now)]);
    return Response.json({ ...ranked, weekly_check: weekly } satisfies NowResponse);
  } catch (error) {
    console.error("지금 할 일 조회 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "목록을 불러오지 못했습니다.");
  }
}

/** 주간 질문은 곁가지다: 못 읽으면 묻지 않고 목록은 그대로 돌려준다. */
async function weeklyCheck(client: SupabaseClient, now: Date): Promise<NowResponse["weekly_check"]> {
  if (!weeklyCheckEnabled()) return null;
  try {
    // 이번 주 답, 그리고 이번 주 들어 답한 지난주 답(월요일 새벽에 지난주 카드에 답한 경우)만 보면 된다.
    const [{ data: first }, { data: answers }] = await Promise.all([
      client.from("sources").select("created_at").order("created_at").limit(1).maybeSingle().throwOnError(),
      client.from("weekly_checks").select("week_start, answered_at").gte("week_start", previousKstWeek(now)).throwOnError(),
    ]);
    return weeklyCheckDue({
      enabled: true,
      firstSourceAt: (first?.created_at as string | undefined) ?? null,
      answers: (answers ?? []) as { week_start: string; answered_at: string }[],
      now,
    });
  } catch (error) {
    console.error("주간 질문 조회 실패:", error instanceof Error ? error.message : error);
    return null;
  }
}
