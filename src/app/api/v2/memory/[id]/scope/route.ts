import { authenticateRequest } from "@/lib/api/auth";
import { handleMoveMemory } from "@/lib/api/memory";
import { moveMemoryItem } from "@/lib/context/memory-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 기억 범위 옮기기 (B3). gate MEMORY_ENABLED가 꺼져 있으면 404. explicit 항목만: 새 explicit 행(value.moved_from) + 옛 행 잊음, 한 트랜잭션. 정정(superseded)과 다르다.
// 200 { item } 새 행 · 404 없는/남의 기억 · 내 active 범위가 아닌 대상 · 409 conflict · 409 scope_unavailable(observed · inferred · 할 일/상대/에이전트 범위: 정책 보류). 실행 권한에 닿지 않는다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleMoveMemory(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    move: ({ user }, memoryId, body) => moveMemoryItem(createAdminClient(), user.id, memoryId, body),
  });
}
