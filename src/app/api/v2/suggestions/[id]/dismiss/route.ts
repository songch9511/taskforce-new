import { authenticateRequest } from "@/lib/api/auth";
import { handleDismissSuggestion } from "@/lib/api/review";
import { flagEnabled } from "@/lib/flags";
import { dismissSuggestion } from "@/lib/review/suggestions";
import { createAdminClient } from "@/lib/supabase/admin";

// 제안 거절 (C3): this = 이 계기만, topic = 같은 종류 + 주제의 새 계기도 다시 제안하지 않는다. gate REVIEW_V2_ENABLED가 꺼져 있으면 404.
// 200 { suggestion } · 400 · 404 · 409 conflict(옛 version · 이미 처리됨). 제안 거절은 Action · run · 정책을 건드리지 않는다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleDismissSuggestion(request, id, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED"),
    authenticate: authenticateRequest,
    dismiss: ({ user }, suggestionId, version, scope, now) => dismissSuggestion(createAdminClient(), user.id, suggestionId, version, scope, now),
  });
}
