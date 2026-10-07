import { receiveWebhook } from '@/lib/billing/webhook';
import { createAdminClient } from '@/lib/supabase/admin';
export const runtime = 'nodejs';
export async function POST(request: Request) { try {
    return await receiveWebhook(request, createAdminClient());
}
catch {
    return new Response(null, { status: 503 });
} }
