import { authenticateRequest } from '@/lib/api/auth';
import { unauthorized } from '@/lib/api/respond';
import { billingSummary } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
export async function GET(request: Request) {
    const context = await authenticateRequest(request);
    if (!context)
        return unauthorized();
    try {
        const state = await billingSummary(createAdminClient(), context.user.id);
        return Response.json(state, { headers: { 'Cache-Control': 'no-store' } });
    }
    catch {
        return Response.json({ error: { code: 'billing_unavailable', message: 'Billing is temporarily unavailable.' } }, { status: 503 });
    }
}
