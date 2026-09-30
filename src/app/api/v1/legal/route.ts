import { authenticateRequest } from "@/lib/api/auth";
import { handleGetLegal } from "@/lib/api/legal";
import { createAdminClient } from "@/lib/supabase/admin";

// 처리방침 변경 안내 (처리방침 17장). 가입 시각은 JWT에 없어 auth 사용자를 읽는다 (서버 권한, 이 사용자 id로만).
export async function GET(request: Request) {
  return handleGetLegal(request, {
    authenticate: async (req) => (await authenticateRequest(req))?.user ?? null,
    accountCreatedAt: async (user) => {
      const { data, error } = await createAdminClient().auth.admin.getUserById(user.id);
      if (error || !data.user) throw error ?? new Error("사용자가 없습니다.");
      return new Date(data.user.created_at);
    },
  });
}
