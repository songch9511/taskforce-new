import { authenticateRequest } from "@/lib/api/auth";
import { handleChangeContextMember } from "@/lib/api/context-members";
import { changeContextMembership } from "@/lib/context/member-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 범위 멤버십 넣기 · 빼기 (S3b, ProjectLink "Set by you"). gate MEMORY_ENABLED가 꺼져 있으면 404. { op: "add" | "remove", member_kind: "action", member_id }.
// 200 { member, context_version } · 404 gate 꺼짐 · 남의/없는/보관된 범위 · 남의/없는 할 일 · 400 잘못된 본문(source · person 종류 포함). origin은 언제나 user, 멱등.
// 읽기는 앱이 RLS로 한다. AI를 부르지 않고 run · Action · 정책을 만들지 않는다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleChangeContextMember(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    change: ({ user }, change) => changeContextMembership(createAdminClient(), user.id, change),
  });
}
