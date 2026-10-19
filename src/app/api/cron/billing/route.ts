import { cronAuthorized, cronUnauthorized } from '@/lib/api/cron';
import { replayBillingWebhooks, sweepBillingAccounts } from '@/lib/billing/webhook';
import { createAdminClient } from '@/lib/supabase/admin';
export const maxDuration=300;
export async function GET(request:Request){
 if(!cronAuthorized(request))return cronUnauthorized();
 try {
  const started=Date.now();
  const admin=createAdminClient();
  await admin.rpc("purge_billing_checkout_intents").throwOnError();
  const replay=await replayBillingWebhooks(admin);
  // One time budget for the whole run (maxDuration 300): the sweep only uses what the replay left.
  const sweep=await sweepBillingAccounts(admin,{deadline:started+270_000});
  return Response.json({...replay,swept:sweep.swept,sweep_failed:sweep.failed},{status:replay.failed||sweep.failed?503:200});
 }catch{return Response.json({error:'billing_reconciliation_unavailable'},{status:503});}
}
