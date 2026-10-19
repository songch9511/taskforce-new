import type { BillingErrorCodeV2 } from '@/lib/api/contract';
import { authenticateRequest, type ApiContext } from '@/lib/api/auth';
import { unauthorized } from '@/lib/api/respond';
// Shared shell of the /api/v2/billing routes. Errors carry a closed code and a fixed message only: never provider text,
// ids, emails or user input (logs and responses stay free of personal data).
const headers = { 'Cache-Control': 'no-store' };
export const billingJson = (body: unknown) => Response.json(body, { headers });
export function billingError(status: number, code: BillingErrorCodeV2, message: string): Response {
    return Response.json({ error: { code, message } }, { status, headers });
}
const UNAVAILABLE = 'Billing is temporarily unavailable.';
/** Not allowed right now (flag off, wrong state, pending checkout): 409. Anything else is an outage: 503. */
const REFUSALS = new Set(['billing_disabled', 'billing_subscription_exists', 'billing_checkout_pending', 'billing_not_configured', 'billing_subscription_missing', 'billing_portal_unavailable', 'billing_resume_unavailable', 'billing_refund_unavailable']);
export function billingFailure(error: unknown): Response {
    const message = error instanceof Error ? error.message : '';
    if (message === 'billing_terms_required')
        return billingError(409, 'billing_terms_required', 'Review the current terms and try again.');
    if (message === 'billing_refund_window_closed')
        return billingError(409, 'billing_refund_window_closed', 'The 3-day refund window has passed.');
    if (message === 'billing_refund_used')
        return billingError(409, 'billing_refund_used', 'The refund for this account was already used.');
    if (message === 'billing_refund_pending')
        return billingError(409, 'billing_refund_pending', 'A refund is already being processed.');
    if (REFUSALS.has(message))
        return billingError(409, 'billing_unavailable', 'This is not available for your account right now.');
    return billingError(503, 'billing_unavailable', UNAVAILABLE);
}
/** Authenticated handler. Cookie writes are CSRF-checked inside authenticateRequest. */
export async function withBillingUser(request: Request, run: (context: ApiContext) => Promise<Response>): Promise<Response> {
    const context = await authenticateRequest(request);
    if (!context)
        return unauthorized();
    try {
        return await run(context);
    }
    catch (error) {
        return billingFailure(error);
    }
}
