import { authenticateRequest } from "@/lib/api/auth";
import { handleMoveContextMember } from "@/lib/api/context-members";
import { changeContextMembership } from "@/lib/context/member-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 범위 멤버십 옮기기 (S3b, ProjectLink "바꾸기 A → B" · Undo). 경로의 범위가 도착이다. gate MEMORY_ENABLED가 꺼져 있으면 404.
// { member_kind: "action", member_id, from_context_id }. 한 트랜잭션: from에서 빼고(removed_at) 도착 범위에 넣는다(origin user). 두 범위가 모두 내 active 범위일 때만 쓴다.
// 200 { member, removed, context_version, from_context_version } · 404 · 400(같은 범위 포함). 멱등.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleMoveContextMember(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    change: ({ user }, change) => changeContextMembership(createAdminClient(), user.id, change),
  });
}
