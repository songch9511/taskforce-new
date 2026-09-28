import { consentRequestSchema } from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// 외부 AI 처리 동의 (App Store 5.1.2(i)). 동의 전에는 서버가 원문을 외부 AI(LLM · Jev · 임베딩)로 보내지 않는다.
// POST · DELETE /api/v1/consent 처리. 인증 · 저장을 인자로 받아 Route Handler 밖에서 테스트한다.

export const CONSENT_REQUIRED_MESSAGE = "외부 AI 처리 동의가 필요해요.";

/** 동의 전에 원문을 외부 AI로 보내야 하는 요청(연결 시작 · 동기화 · 원문 보내기 · 물어보기)의 응답. 앱은 이걸 보고 동의 화면을 먼저 띄운다. */
export const consentRequired = () => errorResponse(409, "conflict", CONSENT_REQUIRED_MESSAGE);

export type ConsentDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** 동의 시각을 적는다. null이면 철회 */
  save: (user: User, consentedAt: Date | null) => Promise<void>;
  now?: () => Date;
};

async function saveConsent<User>(user: User, at: Date | null, deps: ConsentDeps<User>): Promise<Response> {
  try {
    await deps.save(user, at);
  } catch (error) {
    console.error("동의 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "동의를 저장하지 못했습니다.");
  }
  return new Response(null, { status: 204 });
}

export async function handleGiveConsent<User>(request: Request, deps: ConsentDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, consentRequestSchema);
  if ("error" in body) return body.error;
  return saveConsent(user, deps.now?.() ?? new Date(), deps);
}

export async function handleWithdrawConsent<User>(request: Request, deps: ConsentDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  return saveConsent(user, null, deps);
}
