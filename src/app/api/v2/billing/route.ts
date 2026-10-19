import { billingJson, withBillingUser } from '@/lib/billing/respond';
import { billingStatusV2 } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
// Plan & usage. With BILLING_ENABLED off this answers state "beta" with nothing for sale and reads no account row.
export async function GET(request: Request) {
    return withBillingUser(request, async ({ user }) => billingJson(await billingStatusV2(createAdminClient(), user.id)));
}
