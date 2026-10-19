import { billingRefundRequestV2Schema } from '@/lib/api/contract';
import { parseBody } from '@/lib/api/respond';
import { billingJson, withBillingUser } from '@/lib/billing/respond';
import { requestRefund } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
// Self-service refund of the latest payment within 3 days, once per account. Requested only: the plan ends when the provider confirms.
// up to three provider calls (15 s timeout each) after the database call: more than the default budget of a plain route.
export const maxDuration = 60;
export async function POST(request: Request) {
    return withBillingUser(request, async ({ user }) => {
        const body = await parseBody(request, billingRefundRequestV2Schema);
        if ('error' in body)
            return body.error;
        return billingJson(await requestRefund(createAdminClient(), user.id));
    });
}
