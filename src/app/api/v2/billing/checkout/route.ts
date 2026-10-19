import { billingCheckoutRequestV2Schema } from '@/lib/api/contract';
import { parseBody } from '@/lib/api/respond';
import { billingJson, withBillingUser } from '@/lib/billing/respond';
import { checkout } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
// Pro (3-day card trial, monthly or yearly picked at the provider) or Lifetime. 409 when it cannot be sold to this account.
// provider call (15 s timeout each) after the database call: more than the default budget of a plain route.
export const maxDuration = 60;
export async function POST(request: Request) {
    return withBillingUser(request, async ({ user }) => {
        const body = await parseBody(request, billingCheckoutRequestV2Schema);
        if ('error' in body)
            return body.error;
        return billingJson({ url: await checkout(createAdminClient(), user.id, body.data.plan, body.data.terms_version) });
    });
}
