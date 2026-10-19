import { AiBudgetError } from "@/lib/ai/budget-error";
import { aiBudgetErrorResponse } from "@/lib/api/ai-budget";
import { authenticateRequest } from "@/lib/api/auth";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { aiAllowanceV1 } from "@/lib/billing/service";
import { createAdminClient } from "@/lib/supabase/admin";

// v1 stays for app builds that still show the old allowance line. The summary comes from the plan state (billing/service.ts aiAllowanceV1):
// the grandfathered beta keeps its legacy numbers, trial / paid windows are shown on the legacy 10-unit scale, nothing is invented on errors.
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  try {
    return Response.json(await aiAllowanceV1(createAdminClient(), context.user.id), { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof AiBudgetError) return aiBudgetErrorResponse(error);
    return errorResponse(503, "ai_budget_unavailable", "Could not load your AI allowance.");
  }
}
