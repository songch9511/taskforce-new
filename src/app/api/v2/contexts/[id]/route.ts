import { authenticateRequest } from "@/lib/api/auth";
import { handleUpdateWorkContext } from "@/lib/api/contexts";
import { updateContext } from "@/lib/context/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 프로젝트 이름 · 아이콘 · 상태 변경 (D4c-1s). 조건부 SQL 쓰기 뒤 409면 앱은 다시 읽는다.
export async function PATCH(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleUpdateWorkContext(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    update: ({ user }, contextId, expectedVersion, changes) => updateContext(createAdminClient(), user.id, contextId, expectedVersion, changes),
  });
}
