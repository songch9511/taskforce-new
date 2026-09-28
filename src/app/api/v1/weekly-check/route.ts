import { authenticateRequest } from "@/lib/api/auth";
import { weeklyCheckRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { weeklyCheckEnabled } from "@/lib/env";
import { isAnswerableWeek } from "@/lib/metrics/weekly-check";
import { createAdminClient } from "@/lib/supabase/admin";

// 주간 질문 응답 (지표 5). 쓰기는 서버(service role)만 한다: 이번 주(또는 바로 전 주)만 받고, 같은 주에 다시 답하면 덮어쓴다.
export async function POST(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const body = await parseBody(request, weeklyCheckRequestSchema);
  if ("error" in body) return body.error;
  // 베타 뒤 질문을 끄면(WEEKLY_CHECK_ENABLED=false) 답도 받지 않는다 (/now도 묻지 않는다).
  if (!weeklyCheckEnabled()) return errorResponse(400, "invalid_request", "지금은 주간 질문을 받지 않습니다.");
  const now = new Date();
  if (!isAnswerableWeek(body.data.week_start, now)) return errorResponse(400, "invalid_request", "이번 주 질문에만 답할 수 있습니다.");

  // 다시 답하면 답과 answered_at을 덮어쓴다 (created_at은 첫 답 그대로).
  const { error } = await createAdminClient()
    .from("weekly_checks")
    .upsert(
      { user_id: context.user.id, week_start: body.data.week_start, answer: body.data.answer, answered_at: now.toISOString() },
      { onConflict: "user_id,week_start" },
    );
  if (error) {
    console.error("주간 질문 저장 실패:", error.message);
    return errorResponse(500, "internal_error", "응답을 저장하지 못했습니다.");
  }
  return new Response(null, { status: 204 });
}
