import { openAgentAdapters } from "@/lib/agents/registry";
import { resolvePathConflict } from "@/lib/agents/path-leases";
import { authenticateRequest } from "@/lib/api/auth";
import { handleResolvePathConflict } from "@/lib/api/path-conflicts";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 경로 충돌 해소 (OA D4b-s, 계약 3.9): 같은 경로를 쓴 두 세션 중 한쪽을 남긴다. { keep: "holder" | "later", conflict_version }.
// gate: REVIEW_V2_ENABLED ∧ 켜진 adapter가 하나라도 있을 때(Review가 충돌을 보이는 조건과 같다) — 아니면 404 (인증 · DB 0). 200 { status: "resolved" } · 409 conflict(옛 version · 이미 해소) · 404 · 400 · 401.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleResolvePathConflict(request, id, {
    enabled: () => flagEnabled("REVIEW_V2_ENABLED") && openAgentAdapters().length > 0,
    authenticate: authenticateRequest,
    resolve: ({ user }, input) => resolvePathConflict(createAdminClient(), { userId: user.id, ...input }),
  });
}
