import type { AiBudgetError } from "@/lib/ai/budget-error";

import { errorResponse } from "./respond";

/** Daily pauses can retry; cumulative limits need an operator decision. */
export function aiBudgetErrorResponse(error: AiBudgetError): Response {
  const retryAt = error.retryAt;
  const status = retryAt ? 429 : ["ai_budget_exhausted", "ai_global_budget_exhausted", "billing_required"].includes(error.code) ? 403 : 503;
  const response = errorResponse(status, error.code, error.userMessage);
  if (retryAt) response.headers.set("Retry-After", new Date(retryAt).toUTCString());
  return response;
}
