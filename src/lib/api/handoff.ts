import { AiBudgetError } from "@/lib/ai/budget-error";
import { DeadlineExceededError } from "@/lib/ai/deadline";
import { HandoffGenerationError } from "@/lib/ai/handoff-error";
import { ConsentRequiredError } from "@/lib/consent/gate";

import type { HandoffResponse } from "./contract";
import { consentRequired } from "./consent";
import { handoffRequestSchema } from "./contract";
import { RateLimitedError, retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody } from "./respond";

export type HandoffHandlerDeps = {
  handoff: (assisted: boolean) => Promise<HandoffResponse>;
  onDeadlineExceeded?: (error: DeadlineExceededError) => void;
  now?: () => Date;
};

/** An absent body keeps the original deterministic contract. Any supplied body must opt into assisted mode exactly. */
export async function handleHandoff(request: Request, deps: HandoffHandlerDeps): Promise<Response> {
  let assisted = false;
  if (request.body !== null) {
    const body = await parseBody(request, handoffRequestSchema);
    if ("error" in body) return body.error;
    assisted = true;
  }

  try {
    return Response.json(await deps.handoff(assisted));
  } catch (error) {
    if (error instanceof Error && error.name === "ActionNotFoundError") return errorResponse(404, "not_found", "Action이 없습니다.");
    if (error instanceof ConsentRequiredError) return consentRequired();
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "AI 요청이 많아요. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, deps.now?.() ?? new Date())));
      return response;
    }
    if (error instanceof AiBudgetError) {
      return errorResponse(["ai_budget_exhausted", "billing_required"].includes(error.code) ? 403 : 503, error.code, error.userMessage);
    }
    if (error instanceof DeadlineExceededError) {
      deps.onDeadlineExceeded?.(error);
      return errorResponse(504, "ai_timeout", "AI 응답이 늦어졌어요. 다시 시도해 주세요.");
    }
    if (error instanceof HandoffGenerationError) {
      console.error(JSON.stringify({ event: "handoff_failed", stage: error.stage }));
      return errorResponse(503, "ai_unavailable", "AI가 실행 계획을 준비하지 못했어요. 다시 시도해 주세요.");
    }
    // Log the error class only; provider bodies, source text, and generated prompts stay private.
    console.error(JSON.stringify({ event: "handoff_failed", error: error instanceof Error ? error.name : "unknown" }));
    return errorResponse(500, "internal_error", "요청을 처리하지 못했어요.");
  }
}
