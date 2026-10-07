import { billingEnabled, billingBudgets } from '@/lib/billing/state';
import { authenticateRequest } from "@/lib/api/auth";
import { aiSpendSummarySchema } from "@/lib/api/contract";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { createAdminClient } from "@/lib/supabase/admin";

export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  try {
    const { data, error } = await createAdminClient().rpc(billingEnabled() ? "billing_spend_summary" : "ai_spend_summary", { p_user_id: context.user.id, ...(billingEnabled() ? billingBudgets() : {}) });
    if (error) throw error;
    return Response.json(aiSpendSummarySchema.parse(data), { headers: { "Cache-Control": "no-store" } });
  } catch {
    return errorResponse(503, "ai_budget_unavailable", "Could not load your AI allowance.");
  }
}
