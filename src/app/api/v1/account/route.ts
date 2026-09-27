import { handleDeleteAccount } from "@/lib/api/account";
import { authenticateRequest } from "@/lib/api/auth";
import { createAdminClient } from "@/lib/supabase/admin";

// 계정 삭제 (App Store 5.1.1(v)). auth 사용자를 지우면 사용자 테이블의 행이 모두 on delete cascade로 함께 지워진다
// (tests/db/account-deletion.test.ts). 외부 연동 토큰은 connection_secrets에서 함께 지워진다 (제공자 쪽 권한 해제는 하지 않는다).
export async function DELETE(request: Request) {
  return handleDeleteAccount(request, {
    authenticate: async (req) => (await authenticateRequest(req))?.user ?? null,
    deleteUser: async (userId) => {
      const { error } = await createAdminClient().auth.admin.deleteUser(userId);
      // 이미 지워진 계정 (앞선 요청의 응답만 못 받은 재시도): 성공으로 본다
      if (error && error.status !== 404) throw error;
    },
  });
}
