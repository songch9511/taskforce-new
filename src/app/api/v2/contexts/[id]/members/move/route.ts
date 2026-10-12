import { authenticateRequest } from "@/lib/api/auth";
import { handleMoveContextMember } from "@/lib/api/context-members";
import { changeContextMembership } from "@/lib/context/member-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 범위 멤버십 옮기기 (S3b, ProjectLink "바꾸기 A → B" · Undo). 경로의 범위가 도착이다. gate MEMORY_ENABLED가 꺼져 있으면 404.
// { member_kind: "action", member_id, from_context_id, expected_context_version(도착), expected_from_context_version(출발) } — 조건 필드 둘 다 필수.
// 한 트랜잭션: from에서 빼고(removed_at) 도착 범위에 넣는다(origin user). 두 범위가 모두 내 active 범위일 때만 쓰고, 다른 범위의 멤버십은 건드리지 않는다(전체 교체 아님).
// 조건부 쓰기: 두 version 중 하나라도 지금과 다르면 쓰기 0 + 409 conflict (응답을 잃은 성공의 재전송도 409: 앱은 409를 성공으로 보지 않고 다시 읽는다).
// 200 { member, from_member, context_version, from_context_version, change: { added, removed } } · 404 · 400(같은 범위 · 조건 없음 포함) · 409 conflict.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleMoveContextMember(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    change: ({ user }, change) => changeContextMembership(createAdminClient(), user.id, change),
  });
}
