import { billingResumeRequestV2Schema } from '@/lib/api/contract';
import { parseBody } from '@/lib/api/respond';
import { billingJson, withBillingUser } from '@/lib/billing/respond';
import { resume } from '@/lib/billing/service';
import { createAdminClient } from '@/lib/supabase/admin';
// Restart a cancelled Pro while its paid period lasts. Requested only: the plan changes when the provider confirms.
// provider call (15 s timeout each) after the database call: more than the default budget of a plain route.
export const maxDuration = 60;
export async function POST(request: Request) {
    return withBillingUser(request, async ({ user }) => {
        const body = await parseBody(request, billingResumeRequestV2Schema);
        if ('error' in body)
            return body.error;
        return billingJson(await resume(createAdminClient(), user.id));
    });
}
