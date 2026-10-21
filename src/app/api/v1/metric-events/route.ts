import { authenticateRequest } from "@/lib/api/auth";
import { metricEventRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { createAdminClient } from "@/lib/supabase/admin";

// 앱이 알리는 지표 (app_opened · external_sessions_shown). action_started · handoff_used는 해당 API(start · handoff)가 서버에서 남긴다.
// external_sessions_shown (OA 외부 세션 PR1): 앱의 열 권한(type · action_id)을 넓히지 않으려고 route가 구간 enum을 검증한 뒤 서버 권한으로 남긴다.
// 하루 한 번(UTC 날짜별 부분 unique 인덱스)이라 두 번째부터는 23505를 중복으로 보고 조용히 넘긴다. 값은 구간 문자열뿐이다 (글 · 수 0).
export async function POST(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const body = await parseBody(request, metricEventRequestSchema);
  if ("error" in body) return body.error;

  if (body.data.type === "external_sessions_shown") {
    const { error } = await createAdminClient()
      .from("metric_events")
      .insert({ user_id: context.user.id, type: "external_sessions_shown", props: body.data.props });
    if (error && error.code !== "23505") return errorResponse(500, "internal_error", "이벤트를 남기지 못했습니다.");
    return new Response(null, { status: 204 });
  }

  const { error } = await context.supabase.from("metric_events").insert({ type: body.data.type, action_id: body.data.action_id ?? null });
  if (error) return errorResponse(error.code === "23503" ? 400 : 500, error.code === "23503" ? "invalid_request" : "internal_error", "이벤트를 남기지 못했습니다.");
  return new Response(null, { status: 204 });
}
