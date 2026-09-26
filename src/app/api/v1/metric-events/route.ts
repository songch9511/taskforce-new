import { authenticateRequest } from "@/lib/api/auth";
import { metricEventRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";

// 지표 이벤트 (app_opened · handoff_used). action_started는 POST /actions/:id/start가 남긴다.
export async function POST(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const body = await parseBody(request, metricEventRequestSchema);
  if ("error" in body) return body.error;

  const { error } = await context.supabase.from("metric_events").insert({ type: body.data.type, action_id: body.data.action_id ?? null });
  if (error) return errorResponse(error.code === "23503" ? 400 : 500, error.code === "23503" ? "invalid_request" : "internal_error", "이벤트를 남기지 못했습니다.");
  return new Response(null, { status: 204 });
}
