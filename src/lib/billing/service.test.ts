import { afterEach, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { checkout } from './service';
vi.mock('server-only',()=>({}));
afterEach(()=>{vi.unstubAllEnvs();vi.unstubAllGlobals();});
function fixture() {
 for(const [key,value] of Object.entries({BILLING_ENABLED:'true',LEMONSQUEEZY_API_KEY:'test',LEMONSQUEEZY_WEBHOOK_SECRET:'0123456789abcdef',LEMONSQUEEZY_STORE_ID:'1',LEMONSQUEEZY_MONTHLY_VARIANT_ID:'2',LEMONSQUEEZY_ANNUAL_VARIANT_ID:'3',LEMONSQUEEZY_TEST_MODE:'true'}))vi.stubEnv(key,value);
 const account={user_id:'alice',legacy_beta:false,notice_ends_at:null,onboarding_started_at:null,trial_ends_at:null,subscription_id:null,customer_id:null,plan:null,status:'none',current_period_ends_at:null,deleting:false};
 const chain={upsert:()=>chain,select:()=>chain,eq:()=>chain,single:()=>chain,update:()=>chain,throwOnError:async()=>({data:account})};
 const rpc=vi.fn(async()=>({data:{id:'11111111-1111-4111-8111-111111111111',url:null,expires_at:'2026-10-09T00:00:00Z'},error:null}));
 const fetchMock=vi.fn(async()=>Response.json({data:{attributes:{url:'https://store.lemonsqueezy.com/checkout/opaque'}}}));
 vi.stubGlobal('fetch',fetchMock);
 return {admin:{from:()=>chain,rpc} as unknown as SupabaseClient,rpc,fetchMock,account};
}
it('creates fixed-price server-issued account checkout with no client identity or redirect input',async()=>{
 const f=fixture();await checkout(f.admin,'alice','annual','2026-10-08');
 expect(f.rpc).toHaveBeenCalledWith('billing_claim_checkout',{p_user_id:'alice',p_plan:'annual',p_terms_version:'2026-10-08'});
 const calls=f.fetchMock.mock.calls as unknown as [string,RequestInit][];
 const body=JSON.parse(calls[0][1].body as string);
 expect(body.data.relationships.variant.data.id).toBe('3');
 expect(body.data.attributes.product_options.enabled_variants).toEqual([3]);
 expect(body.data.attributes.checkout_options.skip_trial).toBe(true);
 expect(body.data.attributes.checkout_data.custom).toEqual({checkout_ref:'11111111-1111-4111-8111-111111111111'});
 expect(body.data.attributes.test_mode).toBe(true);
});
it('blocks concurrent checkout claims before sending another provider request',async()=>{
 const f=fixture();f.rpc.mockResolvedValue({data:null,error:{message:'billing_checkout_pending'}} as never);
 await expect(checkout(f.admin,'alice','monthly','2026-10-08')).rejects.toThrow('billing_checkout_pending');
 expect(f.fetchMock).not.toHaveBeenCalled();
});
it('does not create provider purchases while launch flag is disabled',async()=>{
 const f=fixture();vi.stubEnv('BILLING_ENABLED','false');
 await expect(checkout(f.admin,'alice','monthly','2026-10-08')).rejects.toThrow('billing_disabled');
 expect(f.fetchMock).not.toHaveBeenCalled();
});

it('rolls back its deletion lock when a checkout is still pending',async()=>{
 const {cancelBeforeDeletion}=await import('./service');
 const updates:unknown[]=[];const filters:unknown[]=[];
 const from=(table:string)=>{
  const chain={select:()=>chain,eq:(key:string,value:unknown)=>{filters.push([key,value]);return chain;},is:()=>chain,gt:()=>chain,single:()=>chain,maybeSingle:async()=>({data:{subscription_id:null},error:null}),update:(value:unknown)=>{updates.push(value);return chain;},throwOnError:async()=>({data:table==='billing_checkout_intents'?[{id:'pending'}]:{subscription_id:null}})};return chain;
 };
 await expect(cancelBeforeDeletion({from} as unknown as SupabaseClient,'alice')).rejects.toThrow('billing_checkout_pending');
 expect(updates).toEqual([expect.objectContaining({deleting:true,deleting_token:expect.any(String)}),{deleting:false,deleting_token:null}]);
 expect(filters).toContainEqual(['deleting_token',(updates[0] as {deleting_token:string}).deleting_token]);
});

it('does not roll back another deletion operation when its atomic claim is busy',async()=>{
 const {cancelBeforeDeletion}=await import('./service');
 const updates:unknown[]=[];let mutation=false;
 const chain={select:()=>chain,eq:()=>chain,update:(value:unknown)=>{mutation=true;updates.push(value);return chain;},maybeSingle:async()=>({data:mutation?null:{subscription_id:null},error:null})};
 await expect(cancelBeforeDeletion({from:()=>chain} as unknown as SupabaseClient,'alice')).rejects.toThrow('billing_deletion_busy');
 expect(updates).toEqual([expect.objectContaining({deleting:true})]);
});
