import { authenticateRequest } from "@/lib/api/auth";
import { handleCreateConversation } from "@/lib/api/conversations";
import { createConversation } from "@/lib/conversation/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 대화 만들기 (대화 v2, 구현 계획 B2). gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404 (v1 Ask만 있다).
// 201 { conversation } 새로 만듦 · 200 같은 id의 내 대화가 이미 있음(멱등) · 409 남이 쓴 id. 모델을 부르지 않는다.
// 읽기(대화 목록 · 메시지)는 앱이 Supabase에서 직접 한다 (RLS, conversations · conversation_messages select).
export async function POST(request: Request) {
  return handleCreateConversation(request, {
    enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED"),
    authenticate: authenticateRequest,
    create: ({ user }, input) => createConversation(createAdminClient(), user.id, { id: input.id, title: input.title, contextId: input.context_id ?? null }),
  });
}
