import { authenticateRequest } from "@/lib/api/auth";
import { handleUpdateConversation } from "@/lib/api/conversations";
import { setConversationContext } from "@/lib/conversation/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 대화 범위 바꾸기 (B3, ProjectLink "Set by you"). gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404. { context_id: uuid | null }(null = All work).
// 200 { conversation } · 404 없는/남의 대화 · 내 active 범위가 아닌 대상 · 400 범위 기능(MEMORY_ENABLED)이 꺼져 있음. 멤버십 · 기억 쓰기 없음(자동 범위 추정은 S3b). 모델을 부르지 않는다.
export async function PATCH(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleUpdateConversation(request, id, {
    enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED"),
    authenticate: authenticateRequest,
    update: ({ user }, conversationId, contextId) => setConversationContext(createAdminClient(), user.id, conversationId, contextId),
  });
}
