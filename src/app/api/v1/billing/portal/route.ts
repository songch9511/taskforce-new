import { authenticateRequest } from '@/lib/api/auth';
import { unauthorized } from '@/lib/api/respond';
import { portal } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
export async function POST(request: Request) {
    const context = await authenticateRequest(request);
    if (!context)
        return unauthorized();
    try {
        return Response.json({ url: await portal(createAdminClient(), context.user.id) }, { headers: { 'Cache-Control': 'no-store' } });
    }
    catch {
        return Response.json({ error: { code: 'billing_unavailable', message: 'Subscription management is temporarily unavailable.' } }, { status: 503 });
    }
}
