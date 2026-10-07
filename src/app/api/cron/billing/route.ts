import { cronAuthorized, cronUnauthorized } from '@/lib/api/cron';
import { replayBillingWebhooks } from '@/lib/billing/webhook';
import { createAdminClient } from '@/lib/supabase/admin';
export const maxDuration=300;
export async function GET(request:Request){
 if(!cronAuthorized(request))return cronUnauthorized();
 try {
  const admin=createAdminClient();
  await admin.rpc("purge_billing_checkout_intents").throwOnError();
  const result=await replayBillingWebhooks(admin);
  return Response.json(result,{status:result.failed?503:200});
 }catch{return Response.json({error:'billing_reconciliation_unavailable'},{status:503});}
}
