import { authenticateRequest } from "@/lib/api/auth";
import { handleSnoozeSuggestion } from "@/lib/api/review";
import { flagEnabled } from "@/lib/flags";
import { SNOOZE_MAX_DAYS } from "@/lib/review/review.config";
import { snoozeSuggestion } from "@/lib/review/suggestions";
import { createAdminClient } from "@/lib/supabase/admin";

// 제안 snooze (C3): 사용자가 고른 시점까지 숨긴다. gate REVIEW_V2_ENABLED가 꺼져 있으면 404. 200 { suggestion } · 400 · 404 · 409 conflict(옛 version · 이미 처리됨).
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleSnoozeSuggestion(request, id, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED"),
    authenticate: authenticateRequest,
    maxDays: SNOOZE_MAX_DAYS,
    snooze: ({ user }, suggestionId, version, until, now) => snoozeSuggestion(createAdminClient(), user.id, suggestionId, version, until, now),
  });
}
