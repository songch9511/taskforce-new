import { authenticateRequest } from "@/lib/api/auth";
import { handleChangeContextMember } from "@/lib/api/context-members";
import { changeContextMembership } from "@/lib/context/member-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 범위 멤버십 넣기 · 빼기 (S3b, ProjectLink "Set by you"). gate MEMORY_ENABLED가 꺼져 있으면 404.
// { op: "add" | "remove", member_kind: "action", member_id, expected_context_version } — 조건 필드 필수. origin은 언제나 user.
// 조건부 쓰기: 요청이 본 범위 version이 지금과 다르면 쓰기 0 + 409 conflict (응답을 잃은 성공의 재전송도 409: 앱은 409를 성공으로 보지 않고 다시 읽는다).
// 200 { member, context_version, change: { added, removed } } (change = 확인된 멤버가 실제로 바뀐 범위 + 쓰기 직후 version, Undo의 입력) ·
// 404 gate 꺼짐 · 남의/없는/보관된 범위 · 남의/없는 할 일 · 400 잘못된 본문(조건 없음 · source · person 종류 포함) · 409 conflict.
// 읽기는 앱이 RLS로 한다. AI를 부르지 않고 run · Action · 정책을 만들지 않는다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleChangeContextMember(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    change: ({ user }, change) => changeContextMembership(createAdminClient(), user.id, change),
  });
}
