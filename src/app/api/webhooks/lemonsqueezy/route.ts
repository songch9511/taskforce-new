import { receiveWebhook } from '@/lib/billing/webhook';
import { createAdminClient } from '@/lib/supabase/admin';
export const runtime = 'nodejs';
// Each delivery re-reads the provider and applies one database call: give it a minute instead of the platform default.
export const maxDuration = 60;
export async function POST(request: Request) { try {
    return await receiveWebhook(request, createAdminClient());
}
catch {
    return new Response(null, { status: 503 });
} }
