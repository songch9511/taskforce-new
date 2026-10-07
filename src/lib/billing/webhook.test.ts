import { createHmac } from 'node:crypto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { validSignature, receiveWebhook, replayBillingWebhooks } from './webhook';
import type { SupabaseClient } from '@supabase/supabase-js';
vi.mock('server-only', () => ({}));
const secret = '0123456789abcdef0123456789abcdef';
function env() { vi.stubEnv('LEMONSQUEEZY_API_KEY', 'test'); vi.stubEnv('LEMONSQUEEZY_WEBHOOK_SECRET', secret); vi.stubEnv('LEMONSQUEEZY_STORE_ID', '1'); vi.stubEnv('LEMONSQUEEZY_MONTHLY_VARIANT_ID', '2'); vi.stubEnv('LEMONSQUEEZY_ANNUAL_VARIANT_ID', '3'); vi.stubEnv('LEMONSQUEEZY_TEST_MODE', 'true'); }
afterEach(() => vi.unstubAllEnvs());
describe('webhook authenticity and bounds', () => {
    it('requires exact raw bytes, correct hex length and shared secret', () => {
        const raw = Buffer.from('{"a":1}');
        const signature = createHmac('sha256', secret).update(raw).digest('hex');
        expect(validSignature(raw, signature, secret)).toBe(true);
        expect(validSignature(Buffer.from('{ "a":1}'), signature, secret)).toBe(false);
        for (const value of [null, '', 'ff', 'g'.repeat(64), 'f'.repeat(64)])
            expect(validSignature(raw, value, secret)).toBe(false);
    });
    it('caps streaming body independently of content-length', async () => {
        env();
        const response = await receiveWebhook(new Request('https://example.test', { method: 'POST', body: 'a'.repeat(262145) }), {} as SupabaseClient);
        expect(response.status).toBe(413);
    });
    it('rejects forged signature before JSON or database access', async () => {
        env();
        const response = await receiveWebhook(new Request('https://example.test', { method: 'POST', body: 'not json' }), {} as SupabaseClient);
        expect(response.status).toBe(401);
    });
    it('rejects signed wrong-mode deliveries', async () => {
        env();
        const raw = JSON.stringify({ meta: { event_name: 'subscription_created', test_mode: false }, data: { id: '12', type: 'subscriptions', attributes: {} } });
        const response = await receiveWebhook(new Request('https://example.test', { method: 'POST', body: raw, headers: { 'x-signature': createHmac('sha256', secret).update(raw).digest('hex') } }), {} as SupabaseClient);
        expect(response.status).toBe(400);
    });
});

describe('authoritative subscription reconciliation', () => {
 const ref='11111111-1111-4111-8111-111111111111';
 const user='22222222-2222-4222-8222-222222222222';
 const updated='2026-10-08T00:00:00.000Z';
 function fixture(invoiceStatus='paid', subscriptionStatus='active') {
  env();
  const rpc=vi.fn(async()=>({error:null}));
  const inbox=new Map<string,{id:string;event:unknown;processed_at?:string}>();
  const from=vi.fn((table:string)=>{
   const result={data:table==='billing_checkout_intents'?{user_id:user}:{user_id:user,subscription_id:'123',status:'active',deleting:false}};
   let id='';let reading=false;
   const chain={select:()=>{reading=true;return chain;},eq:(_key:string,value:string)=>{id=value;return chain;},is:()=>chain,gt:()=>chain,lte:()=>chain,order:()=>chain,limit:()=>chain,upsert:(row:{id:string;event:unknown})=>{if(table==='billing_webhook_inbox'&&!inbox.has(row.id))inbox.set(row.id,row);return chain;},update:(value:{processed_at?:string})=>{if(table==='billing_webhook_inbox')queueMicrotask(()=>{const row=inbox.get(id);if(row)Object.assign(row,value);});return chain;},maybeSingle:()=>chain,throwOnError:async()=>table==='billing_webhook_inbox'&&reading?{data:[...inbox.values()].filter(row=>!row.processed_at)}:result};return chain;
  });
  const fetchMock=vi.fn(async (url:unknown)=>{
   const path=String(url);
   if(path.includes('subscription-invoices'))return Response.json({data:[{id:'44',attributes:{subscription_id:123,store_id:1,test_mode:true,status:invoiceStatus,refunded:invoiceStatus==='refunded',billing_reason:'renewal',created_at:updated,updated_at:updated}}]});
   return Response.json({data:{id:'123',type:'subscriptions',attributes:{store_id:1,order_id:5,variant_id:2,customer_id:77,test_mode:true,status:subscriptionStatus,renews_at:'2026-11-08T00:00:00.000Z',ends_at:subscriptionStatus==='cancelled'?'2026-11-08T00:00:00.000Z':null,updated_at:updated,urls:{customer_portal:'https://app.lemonsqueezy.com/my-orders/123'}}}});
  });
  vi.stubGlobal('fetch',fetchMock);
  const request=(name='subscription_payment_success')=>{
   const raw=JSON.stringify({meta:{event_name:name,test_mode:true,custom_data:{checkout_ref:ref}},data:{id:'44',type:'subscription-invoices',attributes:{subscription_id:123}}});
   return new Request('https://example.test',{method:'POST',body:raw,headers:{'x-signature':createHmac('sha256',secret).update(raw).digest('hex')}});
  };
  return {rpc,fetchMock,inbox,admin:{from,rpc} as unknown as SupabaseClient,request};
 }
 afterEach(()=>vi.unstubAllGlobals());
 it('durably retains sanitized routing metadata and retries after provider outage',async()=>{
  const f=fixture();f.fetchMock.mockResolvedValueOnce(new Response(null,{status:503}));
  await expect(receiveWebhook(f.request(),f.admin)).rejects.toThrow('billing_provider_unavailable');
  expect(f.inbox.size).toBe(1);expect([...f.inbox.values()][0].processed_at).toBeUndefined();
  expect(JSON.stringify([...f.inbox.values()][0].event)).not.toMatch(/email|card|user_name/);
  expect(await replayBillingWebhooks(f.admin)).toEqual({processed:1,failed:0});
  expect([...f.inbox.values()][0].processed_at).toBeDefined();
 });
 it('uses invoice subscription_id and grants only confirmed paid period',async()=>{
  const f=fixture();expect((await receiveWebhook(f.request(),f.admin)).status).toBe(200);
  expect(f.fetchMock.mock.calls[0][0]).toBe('https://api.lemonsqueezy.com/v1/subscriptions/123');
  expect(f.rpc).toHaveBeenCalledWith('billing_apply_subscription',expect.objectContaining({p_user_id:user,p_subscription_id:'123',p_status:'active',p_ends_at:'2026-11-08T00:00:00.000Z'}));
 });
 it.each(['pending','void','refunded'])('does not grant current %s invoice even when subscription says active',async status=>{
  const f=fixture(status);await receiveWebhook(f.request(),f.admin);
  expect(f.rpc).toHaveBeenCalledWith('billing_apply_subscription',expect.objectContaining({p_status:status==='refunded'?'refunded':'payment_pending',p_ends_at:null}));
 });
 it('old refund event reconciles newest paid invoice instead of revoking',async()=>{
  const f=fixture('paid');await receiveWebhook(f.request('subscription_payment_refunded'),f.admin);
  expect(f.rpc).toHaveBeenCalledWith('billing_apply_subscription',expect.objectContaining({p_status:'active'}));
 });
 it('uses cancelled ends_at, never past_due retry dates',async()=>{
  const cancelled=fixture('paid','cancelled');await receiveWebhook(cancelled.request(),cancelled.admin);
  expect(cancelled.rpc).toHaveBeenCalledWith('billing_apply_subscription',expect.objectContaining({p_status:'cancelled',p_ends_at:'2026-11-08T00:00:00.000Z'}));
  const late=fixture('paid','past_due');await receiveWebhook(late.request(),late.admin);
  expect(late.rpc).toHaveBeenCalledWith('billing_apply_subscription',expect.objectContaining({p_status:'past_due',p_ends_at:null}));
 });
});
