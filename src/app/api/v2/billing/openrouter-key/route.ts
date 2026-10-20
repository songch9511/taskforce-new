import { billingOpenRouterKeyRequestV2Schema } from '@/lib/api/contract';
import { retryAfterSeconds } from '@/lib/api/rate-limit';
import { errorResponse, parseBody } from '@/lib/api/respond';
import { billingError, billingJson, withBillingUser } from '@/lib/billing/respond';
import { removeOpenRouterKey, saveOpenRouterKey } from '@/lib/billing/service';
import { flagEnabled } from '@/lib/flags';
import { createAdminClient } from '@/lib/supabase/admin';

// Lifetime owner's own OpenRouter key (BYOK). The key arrives only in this PUT body; it is checked with OpenRouter, sealed and stored, and never
// comes back: the answer is the state, the errors carry fixed text, and nothing here logs a request. PUT with BYOK_ENABLED off: 404 before anything else (DELETE is never gated).
const closed = () => errorResponse(404, 'not_found', 'Not found.');
// one provider read (10 s) after the database calls
export const maxDuration = 30;

export async function PUT(request: Request) {
    if (!flagEnabled('BYOK_ENABLED'))
        return closed();
    return withBillingUser(request, async ({ user }) => {
        const body = await parseBody(request, billingOpenRouterKeyRequestV2Schema);
        if ('error' in body)
            return body.error;
        const result = await saveOpenRouterKey(createAdminClient(), user.id, body.data.key);
        if (result.ok)
            return billingJson({ ai_key: 'connected' });
        switch (result.reason) {
            case 'invalid':
                return billingError(422, 'ai_key_invalid', "This key doesn't work.");
            case 'management':
                return billingError(422, 'ai_key_management', 'Use a regular API key.');
            case 'not_entitled':
                return billingError(409, 'billing_unavailable', 'This is not available for your account right now.');
            case 'rate_limited': {
                const response = billingError(429, 'rate_limited', 'Please try again later.');
                response.headers.set('Retry-After', String(retryAfterSeconds(result.retryAt, new Date())));
                return response;
            }
            default:
                return billingError(503, 'billing_unavailable', 'Could not check the key right now.');
        }
    });
}

// Not gated by BYOK_ENABLED: a stored key can always be removed (privacy). It still needs a login and, for cookies, a same-site write.
export async function DELETE(request: Request) {
    return withBillingUser(request, async ({ user }) => {
        await removeOpenRouterKey(createAdminClient(), user.id);
        return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
    });
}
