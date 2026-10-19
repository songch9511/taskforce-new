import { billingPortalRequestV2Schema } from '@/lib/api/contract';
import { parseBody } from '@/lib/api/respond';
import { billingJson, withBillingUser } from '@/lib/billing/respond';
import { portalV2 } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
// Signed 24-hour provider link: manage the subscription or update the payment method. The app opens it in the browser.
// provider read (15 s timeout each) after the database call: more than the default budget of a plain route.
export const maxDuration = 60;
export async function POST(request: Request) {
    return withBillingUser(request, async ({ user }) => {
        const body = await parseBody(request, billingPortalRequestV2Schema);
        if ('error' in body)
            return body.error;
        return billingJson({ url: await portalV2(createAdminClient(), user.id, body.data.target) });
    });
}
