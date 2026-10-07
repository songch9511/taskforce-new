import { aiBudgetErrorResponse } from "@/lib/api/ai-budget";
import { AiBudgetError } from "@/lib/ai/budget-error";
import { ConsentRequiredError } from "@/lib/consent/gate";

import { consentRequired } from "./consent";
import { askRequestSchema, type AskResponse } from "./contract";
import { retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody, unauthorized } from "./respond";

// POST /api/v1/ask 처리. 인증 · 동의 확인 · 횟수 제한 · 답 만들기를 인자로 받아 Route Handler 밖에서 테스트한다.
// 질문 · 답은 로그에 남기지 않는다 (오류 메시지만).

export type AskHandlerDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 남기고 null */
  rateLimit: (user: User) => Promise<Date | null>;
  answer: (user: User, question: string) => Promise<AskResponse>;
  now?: () => Date;
};

export async function handleAsk<User>(request: Request, deps: AskHandlerDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, askRequestSchema);
  if ("error" in body) return body.error;
  // 질문과 할 일 · 원문 발췌를 외부 AI로 보내므로 동의가 먼저다.
  if (!(await deps.hasConsent(user))) return consentRequired();

  try {
    const retryAt = await deps.rateLimit(user);
    if (retryAt) {
      const response = errorResponse(429, "rate_limited", "질문이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, deps.now?.() ?? new Date())));
      return response;
    }
    return Response.json((await deps.answer(user, body.data.question)) satisfies AskResponse);
  } catch (error) {
    if (error instanceof AiBudgetError) return aiBudgetErrorResponse(error);
    // 답을 만드는 도중에 동의를 철회함 (모델 호출 직전 확인, lib/consent)
    if (error instanceof ConsentRequiredError) return consentRequired();
    console.error("물어보기 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "답을 만들지 못했습니다.");
  }
}
