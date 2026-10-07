import { deleteAccountRequestSchema, type DeleteAccountResponse } from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// DELETE /api/v1/account 처리. 인증 · 토큰 폐기 · 삭제를 인자로 받아 Route Handler 밖에서 테스트한다.
// 순서: 연동 토큰 폐기(서비스 쪽)와 Sign in with Apple 토큰 폐기를 동시에 → auth 사용자 삭제.
// 폐기는 지우기 전에 시작해야 한다 (지우면 암호화된 연동 토큰도 함께 사라진다). 폐기가 실패해도 삭제는 계속하고,
// 폐기 전체가 시간 한도(20초)를 넘기면 기다리지 않고 지운다 (외부 서비스가 느려도 삭제 요청이 실행 시간 한도에 걸리지 않게).

/** 폐기 전체를 기다리는 최대 시간 */
export const REVOCATION_TIMEOUT_MS = 20_000;

export type DeleteAccountDeps<User extends { id: string }> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** Billing cancellation is required before revoking connections or deleting identity. */
  beforeDelete?: (user: User) => Promise<void>;
  /** 연동 토큰을 서비스 쪽에서도 폐기한다 (폐기 API가 있는 서비스만) */
  revokeConnectorTokens?: (user: User) => Promise<void>;
  /** Sign in with Apple 토큰 폐기. 앱이 보낸 authorization code가 있으면 그것으로 토큰을 받아 폐기한다 */
  revokeAppleToken?: (user: User, authorizationCode: string | undefined) => Promise<void>;
  /** auth 사용자를 지운다. 사용자 테이블은 모두 auth.users에 on delete cascade로 걸려 있어 함께 지워진다. */
  deleteUser: (userId: string) => Promise<void>;
  revocationTimeoutMs?: number;
};

export async function handleDeleteAccount<User extends { id: string }>(
  request: Request,
  deps: DeleteAccountDeps<User>,
): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, deleteAccountRequestSchema);
  if ("error" in body) return body.error;

  try {
    await deps.beforeDelete?.(user);
  } catch (error) {
    if (error instanceof Error && error.message === "billing_deletion_busy") return errorResponse(409, "conflict", "Account deletion is already in progress. Please wait and retry.");
    return errorResponse(503, "internal_error", "Subscription cancellation could not be confirmed. Your account has not been deleted; please retry.");
  }

  // 폐기 실패는 로그(오류 메시지만, 토큰 · code 없이)에만 남기고 삭제를 계속한다.
  const bestEffort = async (label: string, task: (() => Promise<void>) | undefined) => {
    if (!task) return;
    try {
      await task();
    } catch (error) {
      console.error(`${label} 실패 (계정 삭제는 계속):`, error instanceof Error ? error.message : error);
    }
  };
  const revocations = Promise.all([
    bestEffort("연동 토큰 폐기", deps.revokeConnectorTokens && (() => deps.revokeConnectorTokens!(user))),
    bestEffort("Apple 토큰 폐기", deps.revokeAppleToken && (() => deps.revokeAppleToken!(user, body.data.apple_authorization_code))),
  ]).then(() => "done" as const);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<"timeout">((resolve) => {
    timer = setTimeout(() => resolve("timeout"), deps.revocationTimeoutMs ?? REVOCATION_TIMEOUT_MS);
  });
  if ((await Promise.race([revocations, timeout])) === "timeout") console.error("토큰 폐기가 시간 한도를 넘겨 기다리지 않고 계정을 지웁니다.");
  clearTimeout(timer);

  try {
    await deps.deleteUser(user.id);
  } catch (error) {
    console.error("계정 삭제 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "계정을 삭제하지 못했습니다.");
  }
  return Response.json({ deleted: true } satisfies DeleteAccountResponse);
}
