import { cancelBeforeDeletion, rollbackDeletion } from '@/lib/billing/service';
import { handleDeleteAccount } from "@/lib/api/account";
import { authenticateRequest } from "@/lib/api/auth";
import { appleSignInConfigFromEnv, revokeAppleSignIn } from "@/lib/apple/sign-in";
import { revokeConnectorTokens } from "@/lib/connectors/registry";
import { createAdminClient } from "@/lib/supabase/admin";

// 계정 삭제 (App Store 5.1.1(v)). auth 사용자를 지우면 사용자 테이블의 행이 모두 on delete cascade로 함께 지워진다
// (tests/db/account-deletion.test.ts). 지우기 전에 서비스 쪽 연동 토큰(폐기 API가 있는 것)과 Sign in with Apple 토큰을 폐기한다.
// 폐기는 최선을 다하되 실패해도 삭제는 계속한다 (둘을 동시에, 전체 20초 한도). 로그에는 토큰 · code 없이 이유만 남긴다.
export const maxDuration = 60;

export async function DELETE(request: Request) {
  const admin = createAdminClient();
  let deletionToken: string | null = null;
  return handleDeleteAccount(request, {
    authenticate: async (req) => (await authenticateRequest(req))?.user ?? null,
    beforeDelete: async (user) => { deletionToken = await cancelBeforeDeletion(admin, user.id); },
    revokeConnectorTokens: async (user) => {
      const { failed } = await revokeConnectorTokens(admin, user.id);
      if (failed > 0) console.error(`연동 토큰 ${failed}개를 폐기하지 못했습니다 (계정 삭제는 계속).`);
    },
    revokeAppleToken: async (user, authorizationCode) => {
      const { data } = await admin.auth.admin.getUserById(user.id);
      // 이 계정에 연결된 Apple 사용자 id. code로 받은 토큰이 이 사용자 것일 때만 폐기한다 (다른 Apple 계정의 토큰을 폐기하지 않게).
      const apple = (data.user?.identities ?? []).find((identity) => identity.provider === "apple");
      const appleSub = apple ? (typeof apple.identity_data?.sub === "string" ? apple.identity_data.sub : apple.id) : null;
      if (!appleSub && !authorizationCode) return;
      const result = await revokeAppleSignIn(appleSignInConfigFromEnv(), authorizationCode, appleSub);
      // Apple 로그인 사용자인데 code가 없거나 · 다른 계정의 code거나 · 키가 설정되지 않았으면 폐기하지 않는다: 이유만 남긴다.
      const reasons: Record<Exclude<typeof result, "revoked">, string> = {
        no_token: "토큰 없음",
        not_configured: "APPLE_* 설정 없음",
        no_identity: "Apple 가입 계정이 아님",
        mismatch: "code의 Apple 사용자가 이 계정과 다름",
      };
      if (result !== "revoked") console.warn(`Sign in with Apple 토큰 폐기를 건너뜀 (${reasons[result]})`);
    },
    deleteUser: async (userId) => {
      try {
        const { error } = await admin.auth.admin.deleteUser(userId);
        if (error && error.status !== 404) throw error;
      } catch(error) {
        if (deletionToken) await rollbackDeletion(admin, userId, deletionToken);
        throw error;
      }
    },
  });
}
