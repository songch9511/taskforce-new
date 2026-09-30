import { needsAccountCreatedAt, PRIVACY_POLICY, privacyPolicyStatus, type PrivacyPolicy } from "@/lib/legal/policy";

import type { LegalResponse } from "./contract";
import { errorResponse, unauthorized } from "./respond";

// GET /api/v1/legal 처리. 인증 · 가입 시각 읽기를 인자로 받아 Route Handler 밖에서 테스트한다.
// 읽기만 한다: 안내를 봤는지는 앱이 기기에 적는다 (contract.ts `legalResponseSchema`).

export type LegalDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** 계정을 만든 시각 (auth.users.created_at). 안내가 가입 시각에 달렸을 때만 부른다 */
  accountCreatedAt: (user: User) => Promise<Date>;
  policy?: PrivacyPolicy;
  now?: () => Date;
};

export async function handleGetLegal<User>(request: Request, deps: LegalDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const policy = deps.policy ?? PRIVACY_POLICY;
  const now = deps.now?.() ?? new Date();
  let createdAt: Date | null = null;
  if (needsAccountCreatedAt(policy, now)) {
    try {
      createdAt = await deps.accountCreatedAt(user);
      if (Number.isNaN(createdAt.getTime())) throw new Error("가입 시각 형식이 아닙니다.");
    } catch (error) {
      console.error("가입 시각 조회 실패:", error instanceof Error ? error.message : error);
      return errorResponse(500, "internal_error", "처리방침 안내를 불러오지 못했습니다.");
    }
  }
  return Response.json({ privacy: privacyPolicyStatus(policy, createdAt, now) } satisfies LegalResponse);
}
