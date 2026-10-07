import { afterEach, expect, it, vi } from "vitest";
import { AiBudgetError } from "./budget-error";
afterEach(()=>vi.useRealTimers());
it.each(["ai_user_daily_budget_exhausted","ai_global_daily_budget_exhausted"])("%s is safe and retries at UTC midnight",code=>{
  vi.useFakeTimers(); vi.setSystemTime(new Date("2026-10-07T23:59:59Z"));
  const error=new AiBudgetError(code);
  expect(error.code).toBe(code);
  expect(error.retryAt).toBe("2026-10-08T00:00:00.000Z");
  expect(error.userMessage).toContain("daily");
});
it("shared total exhaustion has no automatic reset; unknown errors remain closed",()=>{
  expect(new AiBudgetError("ai_global_budget_exhausted").retryAt).toBeUndefined();
  expect(new AiBudgetError("secret-db-detail").code).toBe("ai_budget_unavailable");
  expect(new AiBudgetError("secret-db-detail").userMessage).not.toContain("secret");
});
