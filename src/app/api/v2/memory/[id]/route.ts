import { authenticateRequest } from "@/lib/api/auth";
import { handleEditMemory } from "@/lib/api/memory";
import { editMemoryItem } from "@/lib/context/memory-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 기억 정정 (B3). gate MEMORY_ENABLED가 꺼져 있으면 404. 같은 사실 · 같은 범위의 새 explicit 행 + 옛 행 정정된 이력(범위는 바꾸지 않는다). 읽기는 앱이 RLS로 한다.
// 200 { item } 새 지금 행 · 404 · 409 conflict · 409 confirm_unavailable(Slack에서 온 후보를 글자 그대로 정정: 확인의 우회) · 400 잘못된 본문.
export async function PATCH(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleEditMemory(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    edit: ({ user }, memoryId, body) => editMemoryItem(createAdminClient(), user.id, memoryId, body),
  });
}
