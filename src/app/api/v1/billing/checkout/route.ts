import { billingCheckoutRequestSchema } from '@/lib/api/contract';
import { authenticateRequest } from '@/lib/api/auth';
import { unauthorized, parseBody } from '@/lib/api/respond';
import { checkout } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
export async function POST(request: Request) {
    const context = await authenticateRequest(request);
    if (!context)
        return unauthorized();
    const body = await parseBody(request, billingCheckoutRequestSchema);
    if ('error' in body)
        return body.error;
    try {
        return Response.json({ url: await checkout(createAdminClient(), context.user.id, body.data.plan, body.data.terms_version) }, { headers: { 'Cache-Control': 'no-store' } });
    }
    catch {
        return Response.json({ error: { code: 'billing_unavailable', message: 'Checkout unavailable. An existing checkout or subscription may already be open.' } }, { status: 409 });
    }
}
