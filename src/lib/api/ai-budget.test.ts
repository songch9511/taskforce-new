import { afterEach, expect, it, vi } from "vitest";

import { AiBudgetError } from "@/lib/ai/budget-error";

import { aiBudgetErrorResponse } from "./ai-budget";
import { apiErrorSchema } from "./contract";

afterEach(() => vi.useRealTimers());

it.each(["ai_user_daily_budget_exhausted", "ai_global_daily_budget_exhausted"])("returns a daily pause with next UTC midnight for %s", async (code) => {
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-10-07T15:05:00Z"));
  const response = aiBudgetErrorResponse(new AiBudgetError(code));
  expect(response.status).toBe(429);
  expect(response.headers.get("Retry-After")).toBe("Thu, 08 Oct 2026 00:00:00 GMT");
  expect(apiErrorSchema.parse(await response.json()).error.code).toBe(code);
});

it.each(["ai_budget_exhausted", "ai_global_budget_exhausted"])("does not promise a reset for cumulative %s", async (code) => {
  const response = aiBudgetErrorResponse(new AiBudgetError(code));
  expect(response.status).toBe(403);
  expect(response.headers.has("Retry-After")).toBe(false);
  expect(apiErrorSchema.parse(await response.json()).error.code).toBe(code);
});

it("keeps unverified pricing distinct from exhausted allowance", async () => {
  const response = aiBudgetErrorResponse(new AiBudgetError("ai_price_bound_unavailable"));
  expect(response.status).toBe(503);
  expect(response.headers.has("Retry-After")).toBe(false);
  expect(apiErrorSchema.parse(await response.json()).error.code).toBe("ai_pricing_unavailable");
});
