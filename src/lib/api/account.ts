import type { DeleteAccountResponse } from "./contract";
import { errorResponse, unauthorized } from "./respond";

// DELETE /api/v1/account 처리. 인증 · 삭제를 인자로 받아 Route Handler 밖에서 테스트한다.

export type DeleteAccountDeps<User extends { id: string }> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** auth 사용자를 지운다. 사용자 테이블은 모두 auth.users에 on delete cascade로 걸려 있어 함께 지워진다. */
  deleteUser: (userId: string) => Promise<void>;
};

export async function handleDeleteAccount<User extends { id: string }>(
  request: Request,
  deps: DeleteAccountDeps<User>,
): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  try {
    await deps.deleteUser(user.id);
  } catch (error) {
    console.error("계정 삭제 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "계정을 삭제하지 못했습니다.");
  }
  return Response.json({ deleted: true } satisfies DeleteAccountResponse);
}
