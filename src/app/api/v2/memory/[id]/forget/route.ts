import { authenticateRequest } from "@/lib/api/auth";
import { handleForgetMemory } from "@/lib/api/memory";
import { forgetMemoryItem } from "@/lib/context/memory-writes";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 기억 잊기 (B3). gate MEMORY_ENABLED가 꺼져 있으면 404. revoked_at(되돌릴 수 없음) + 범위 기억이면 범위 version +1. 이미 잊은 항목에 다시 보내면 200(멱등).
// 200 { item } · 404 · 409 conflict(version · 이미 정정). 이미 보낸 묶음은 회수하지 않는다. AI를 부르지 않는다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleForgetMemory(request, id, {
    enabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    forget: ({ user }, memoryId, body) => forgetMemoryItem(createAdminClient(), user.id, memoryId, body.expected_version),
  });
}
