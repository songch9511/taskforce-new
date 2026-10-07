import 'server-only';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { billingConfig, subscription, latestInvoice, provider, initialOrder } from './provider';
const eventSchema = z.object({ meta: z.object({ event_name: z.string().max(100), test_mode: z.boolean(), custom_data: z.object({ checkout_ref: z.string().uuid().optional() }).optional() }), data: z.object({ id: z.string().regex(/^\d+$/), type: z.string().max(50), attributes: z.object({ subscription_id: z.number().optional() }).passthrough() }) });
export function validSignature(raw: Buffer, signature: string | null, secret: string) {
    if (!signature || !/^[a-f\d]{64}$/i.test(signature))
        return false;
    return timingSafeEqual(createHmac('sha256', secret).update(raw).digest(), Buffer.from(signature, 'hex'));
}
export async function receiveWebhook(request: Request, admin: SupabaseClient) {
    const config = billingConfig();
    if (Number(request.headers.get('content-length') ?? 0) > 262144)
        return new Response(null, { status: 413 });
    const reader = request.body?.getReader();
    if (!reader)
        return new Response(null, { status: 400 });
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
        const chunk = await reader.read();
        if (chunk.done)
            break;
        size += chunk.value.length;
        if (size > 262144) {
            await reader.cancel();
            return new Response(null, { status: 413 });
        }
        chunks.push(chunk.value);
    }
    const raw = Buffer.concat(chunks);
    if (!validSignature(raw, request.headers.get('x-signature'), config.secret))
        return new Response(null, { status: 401 });
    const parsed = eventSchema.safeParse(JSON.parse(raw.toString('utf8')));
    if (!parsed.success || parsed.data.meta.test_mode !== config.test)
        return new Response(null, { status: 400 });
    const event = parsed.data;
    if (!event.meta.event_name.startsWith('subscription_') && event.meta.event_name !== 'order_refunded')
        return new Response(null, { status: 200 });
    const eventId=createHash('sha256').update(raw).digest('hex');
    // Persist only routing identifiers needed to repeat authoritative reads.
    // Never store webhook customer/card fields or the original JSON body.
    const sanitized={meta:{event_name:event.meta.event_name,test_mode:event.meta.test_mode,custom_data:event.meta.custom_data?{checkout_ref:event.meta.custom_data.checkout_ref}:undefined},data:{id:event.data.id,type:event.data.type,attributes:{subscription_id:event.data.attributes.subscription_id}}};
    await admin.from('billing_webhook_inbox').upsert({id:eventId,event:sanitized},{onConflict:'id',ignoreDuplicates:true}).throwOnError();
    const response=await reconcileWebhook(sanitized,admin,eventId);
    await admin.from('billing_webhook_inbox').update({processed_at:new Date().toISOString()}).eq('id',eventId).throwOnError();
    return response;
}

export async function reconcileWebhook(event:z.infer<typeof eventSchema>,admin:SupabaseClient,eventId:string){
    const config=billingConfig();
    if(event.meta.test_mode!==config.test)throw new Error('billing_mode_mismatch');
    let id = event.data.type === 'subscriptions' ? event.data.id : String(event.data.attributes.subscription_id ?? '');
    if (event.meta.event_name === 'order_refunded') {
        const { data } = await admin.from('billing_accounts').select('subscription_id').eq('order_id', event.data.id).maybeSingle().throwOnError();
        if (!data?.subscription_id)
            throw new Error('billing_order_not_reconciled');
        id = data.subscription_id;
    }
    let current = await subscription(id);
    const existing = await admin.from("billing_accounts").select("user_id,subscription_id,status,deleting").eq("subscription_id", id).maybeSingle().throwOnError();
    const ref = event.meta.custom_data?.checkout_ref;
    let userId: string | undefined;
    if (ref) {
        const { data } = await admin.from('billing_checkout_intents').select('user_id').eq('id', ref).maybeSingle().throwOnError();
        // A pseudonymous intent survives deletion only to stop late provider renewals.
        if (data && !data.user_id) {
            if (!['cancelled', 'expired'].includes(current.attributes.status))
                await provider(`subscriptions/${id}`, 'DELETE');
            const cancelled = await subscription(id);
            if (!['cancelled', 'expired'].includes(cancelled.attributes.status))
                throw new Error('billing_cancellation_unconfirmed');
            return new Response(null, { status: 200 });
        }
        userId = data?.user_id;
    }
    if (!userId) {
        const { data } = await admin.from('billing_accounts').select('user_id').eq('subscription_id', id).maybeSingle().throwOnError();
        userId = data?.user_id;
    }
    if (!userId)
        throw new Error('billing_unknown_subscription');
    const account = existing.data ?? (await admin.from('billing_accounts').select('user_id,subscription_id,status,deleting').eq('user_id', userId).maybeSingle().throwOnError()).data;
    if (account?.subscription_id && account.subscription_id !== id && account.status !== 'expired') {
        if (['cancelled', 'expired'].includes(current.attributes.status))
            return new Response(null, { status: 200 });
        if (!['cancelled', 'expired'].includes(current.attributes.status))
            await provider(`subscriptions/${id}`, 'DELETE');
        // Do not overwrite the paid subscription with a duplicate purchase.
        throw new Error('billing_duplicate_purchase_cancelled_review_refund');
    }
    if (account?.deleting && !['cancelled', 'expired'].includes(current.attributes.status)) {
        await provider(`subscriptions/${id}`, 'DELETE');
        current = await subscription(id);
    }
    const attrs = current.attributes;
    const invoice = await latestInvoice(id);
    const invoiceAttrs = invoice.attributes;
    const order = invoiceAttrs.billing_reason === 'initial' ? await initialOrder(attrs.order_id) : null;
    const refunded = invoiceAttrs.refunded || invoiceAttrs.status === 'refunded' || !!order?.refunded;
    const paid = ["paid", "partial_refund"].includes(invoiceAttrs.status) && !refunded;
    const status = paid ? attrs.status : refunded ? "refunded" : "payment_pending";
    const updatedAt = new Date(Math.max(Date.parse(attrs.updated_at), Date.parse(invoiceAttrs.updated_at), order ? Date.parse(order.updated_at) : 0)).toISOString();
    const plan = String(attrs.variant_id) === config.variants.monthly ? 'monthly' : 'annual';
    const { error } = await admin.rpc('billing_apply_subscription', { p_user_id: userId, p_event_id: eventId, p_intent_id: ref ?? null, p_subscription_id: id, p_customer_id: String(attrs.customer_id), p_plan: plan, p_status: status, p_ends_at: !paid ? null : attrs.status === 'cancelled' ? attrs.ends_at : attrs.status === 'active' ? attrs.renews_at : null, p_updated_at: updatedAt });
    if (error)
        throw new Error('billing_reconciliation_failed');
    await admin.from('billing_accounts').update({ order_id: String(attrs.order_id) }).eq('user_id', userId).eq('subscription_id', id).throwOnError();
    return new Response(null, { status: 200 });
}

export async function replayBillingWebhooks(admin:SupabaseClient) {
    const deadline=Date.now()+240_000;
    const {data}=await admin.from('billing_webhook_inbox').select('id,event').is('processed_at',null).gt('created_at',new Date(Date.now()-7*86400_000).toISOString()).lte('next_attempt_at',new Date().toISOString()).order('next_attempt_at',{ascending:true}).limit(5).throwOnError();
    let processed=0,failed=0;
    for(const item of data??[]){
        if(Date.now()>deadline)break;
        try {
            await reconcileWebhook(eventSchema.parse(item.event),admin,item.id);
            await admin.from('billing_webhook_inbox').update({processed_at:new Date().toISOString()}).eq('id',item.id).throwOnError();
            processed++;
        } catch {
            failed++;
            await admin.from('billing_webhook_inbox').update({next_attempt_at:new Date(Date.now()+3600_000).toISOString()}).eq('id',item.id).throwOnError();
        }
    }
    return {processed,failed};
}
