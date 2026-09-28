import { authenticateRequest } from "@/lib/api/auth";
import { consentRequired } from "@/lib/api/consent";
import { hasAiConsent } from "@/lib/api/profile-store";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { syncConnections } from "@/lib/connectors/registry";
import { createAdminClient } from "@/lib/supabase/admin";

// 지금 동기화: 로그인한 사용자의 연결만 바로 돌린다 (붙인 모든 연동). 외부 AI 처리 동의 전이면 409.
export const maxDuration = 300;

export async function POST(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  if (!(await hasAiConsent(context))) return consentRequired();

  const { outcomes } = await syncConnections(createAdminClient(), {
    userId: context.user.id,
    deadline: Date.now() + 240_000,
    minIntervalMs: 60_000,
  });
  if (outcomes.length > 0 && outcomes.every((o) => !o.ok && o.busy)) {
    return errorResponse(429, "rate_limited", "이미 동기화 중이거나 방금 동기화했습니다.");
  }
  return Response.json({
    connections: outcomes.map((o) =>
      o.ok
        ? { id: o.connectionId, ok: true, created: o.result.created.length, scanned: o.result.scanned, skipped: o.result.skipped }
        : { id: o.connectionId, ok: false, error: o.error },
    ),
  });
}
