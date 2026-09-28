import { authenticateRequest } from "@/lib/api/auth";
import { handleConnectionRequest } from "@/lib/api/connections";
import { createAdminClient } from "@/lib/supabase/admin";

// 2단계 연동 "원해요" (POST { provider } → 204). 사용자 · 서비스마다 하나만 남긴다 (다시 눌러도 그대로). 쓰기는 서버만 한다.
export async function POST(request: Request) {
  return handleConnectionRequest(request, {
    authenticate: authenticateRequest,
    save: async ({ user }, provider) => {
      await createAdminClient()
        .from("connection_requests")
        .upsert({ user_id: user.id, provider }, { onConflict: "user_id,provider", ignoreDuplicates: true })
        .throwOnError();
    },
  });
}
