import 'server-only';
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { type BillingAccount, subscriptionEnded } from './state';
import { billingConfig, subscription, latestInvoice, cancelSubscription, initialOrder, order, variantPlan } from './provider';
const eventSchema = z.object({ meta: z.object({ event_name: z.string().max(100), test_mode: z.boolean(), custom_data: z.object({ checkout_ref: z.string().uuid().optional() }).optional() }), data: z.object({ id: z.string().regex(/^\d+$/), type: z.string().max(50), attributes: z.object({ subscription_id: z.number().optional() }).passthrough() }) });
type BillingEvent = z.infer<typeof eventSchema>;
type BillingConfig = ReturnType<typeof billingConfig>;
// The thirteen provider events that can change an entitlement. customer_updated, license_key_* and affiliate_activated
// are acknowledged and dropped. taskforce_reconcile / taskforce_sweep are ours: never accepted from the network.
const HANDLED_EVENTS = new Set(['order_created', 'order_refunded', 'subscription_created', 'subscription_updated', 'subscription_cancelled', 'subscription_resumed', 'subscription_expired', 'subscription_paused', 'subscription_unpaused', 'subscription_payment_success', 'subscription_payment_failed', 'subscription_payment_recovered', 'subscription_payment_refunded']);
const ok = () => new Response(null, { status: 200 });
const outcomeSchema = z.enum(['applied', 'replay', 'rejected', 'rejected_known']);
const isTerminal = (status: string) => ['cancelled', 'expired'].includes(status);
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
    if (!HANDLED_EVENTS.has(event.meta.event_name))
        return ok();
    const eventId=createHash('sha256').update(raw).digest('hex');
    // Persist only routing identifiers needed to repeat authoritative reads.
    // Never store webhook customer/card fields or the original JSON body.
    const sanitized={meta:{event_name:event.meta.event_name,test_mode:event.meta.test_mode,custom_data:event.meta.custom_data?{checkout_ref:event.meta.custom_data.checkout_ref}:undefined},data:{id:event.data.id,type:event.data.type,attributes:{subscription_id:event.data.attributes.subscription_id}}};
    await admin.from('billing_webhook_inbox').upsert({id:eventId,event:sanitized},{onConflict:'id',ignoreDuplicates:true}).throwOnError();
    const response=await reconcileWebhook(sanitized,admin,eventId);
    await admin.from('billing_webhook_inbox').update({processed_at:new Date().toISOString()}).eq('id',eventId).throwOnError();
    return response;
}

/**
 * Ask the cron to re-read a provider object a few minutes from now. Used after a refund or resume request, because the
 * provider's own delivery is not guaranteed to follow an API call (contract 5.3). Carries ids only.
 */
export async function enqueueReconcile(admin: SupabaseClient, type: 'subscriptions' | 'orders', id: string) {
    const config = billingConfig();
    const event = { meta: { event_name: 'taskforce_reconcile', test_mode: config.test }, data: { id, type, attributes: {} } };
    await admin.from('billing_webhook_inbox').insert({ id: `reconcile-${type}-${id}-${crypto.randomUUID()}`, event, next_attempt_at: new Date(Date.now() + 120_000).toISOString() }).throwOnError();
}

/**
 * The provider object is the truth: the event only says which object to read again. The database function applies the
 * result in one transaction together with the delivery digest and the metric events.
 */
export async function reconcileWebhook(event:BillingEvent,admin:SupabaseClient,eventId:string){
    const config=billingConfig();
    if(event.meta.test_mode!==config.test)throw new Error('billing_mode_mismatch');
    if(event.data.type==='orders')return reconcileOrder(event,admin,eventId,config);
    const id = event.data.type === 'subscriptions' ? event.data.id : String(event.data.attributes.subscription_id ?? '');
    return reconcileSubscription(admin,eventId,config,id,event.meta.custom_data?.checkout_ref);
}

async function accountOf(admin: SupabaseClient, column: 'user_id' | 'subscription_id' | 'lifetime_order_id' | 'order_id', value: string) {
    const { data } = await admin.from('billing_accounts').select('*').eq(column, value).maybeSingle().throwOnError();
    return (data ?? null) as BillingAccount | null;
}
async function recordEvent(admin: SupabaseClient, userId: string, type: string, props: Record<string, unknown>, dedupeId: string) {
    await admin.rpc('billing_record_event', { p_user_id: userId, p_type: type, p_props: props, p_dedupe_id: dedupeId }).throwOnError();
}
/** Lifetime wins (BL-07): the Pro that arrives next to it is cancelled at the provider, not refunded. */
/** The durable record that a cancel of this subscription was ours (written before the provider is asked). */
async function ownSystemCancel(admin: SupabaseClient, subscriptionId: string) {
    const { data } = await admin.from('billing_webhook_events').select('id').eq('id', `syscancel:${subscriptionId}`).maybeSingle().throwOnError();
    return !!data;
}
async function cancelAsOverlap(admin: SupabaseClient, userId: string, subscriptionId: string) {
    const marker = `syscancel:${subscriptionId}`;
    const key = `overlap:${subscriptionId}`;
    const current = await subscription(subscriptionId);
    if (isTerminal(current.attributes.status)) {
        // Cancelled earlier by us whose event never got written (the marker says it was ours): write it now. A Pro the customer ended
        // themselves has no marker and is not claimed as a system cancel.
        if (await ownSystemCancel(admin, subscriptionId))
            await recordEvent(admin, userId, 'billing_subscription_cancelled', { by: 'system' }, key);
        return;
    }
    // Durable intent first (survives a failed cancel and a failed write), the event only once the provider confirmed the cancel; the
    // event key is the subscription, so a retried delivery counts it once.
    await admin.from('billing_webhook_events').upsert({ id: marker, user_id: userId }, { onConflict: 'id', ignoreDuplicates: true }).throwOnError();
    await cancelAndConfirm(subscriptionId);
    await recordEvent(admin, userId, 'billing_subscription_cancelled', { by: 'system' }, key);
}
/** Cancel at the provider (idempotent) and read it back: a cancellation that is not confirmed is a failure to retry. */
async function cancelAndConfirm(subscriptionId: string) {
    await cancelSubscription(subscriptionId);
    if (!isTerminal((await subscription(subscriptionId)).attributes.status))
        throw new Error('billing_cancellation_unconfirmed');
}

async function reconcileSubscription(admin:SupabaseClient,eventId:string,config:BillingConfig,id:string,ref:string|undefined){
    let current = await subscription(id);
    const existing = await accountOf(admin, 'subscription_id', id);
    let userId: string | undefined = existing?.user_id;
    // A subscription that is already bound is judged by what was stored when it was bound: the reference it happens to arrive with is
    // ignored (contract ch.23), so a delivery, a sweep or a queued re-read can never turn a customer into a violation.
    if (ref && !existing) {
        const { data } = await admin.from('billing_checkout_intents').select('user_id').eq('id', ref).maybeSingle().throwOnError();
        // A pseudonymous intent survives deletion only to stop late provider renewals.
        if (data && !data.user_id) {
            if (!isTerminal(current.attributes.status))
                await cancelAndConfirm(id);
            return ok();
        }
        userId = data?.user_id;
    }
    if (!userId)
        throw new Error('billing_unknown_subscription');
    const account = existing ?? await accountOf(admin, 'user_id', userId);
    // Lifetime wins. A live Pro is cancelled; a Pro that is already over is left to the normal record unless the cancel was ours and its
    // event is still owed (the retry of a delivery whose cancel went through but whose event write failed).
    if (account?.lifetime_status === 'active' && (!isTerminal(current.attributes.status) || await ownSystemCancel(admin, id))) {
        await cancelAsOverlap(admin, userId, id);
        return ok();
    }
    if (account?.subscription_id && account.subscription_id !== id && !subscriptionEnded(account, Date.now())) {
        if (isTerminal(current.attributes.status))
            return ok();
        // Record first (once per subscription), then cancel: a cancel that fails is retried and the record is never lost.
        await recordEvent(admin, userId, 'billing_duplicate_purchase', { plan: variantPlan(config, current.attributes.variant_id) }, `duplicate:${id}`);
        await cancelSubscription(id);
        // Do not overwrite the paid subscription with a duplicate purchase.
        throw new Error('billing_duplicate_purchase_cancelled_review_refund');
    }
    if (account?.deleting && !isTerminal(current.attributes.status)) {
        await cancelSubscription(id);
        current = await subscription(id);
    }
    const attrs = current.attributes;
    const plan = variantPlan(config, attrs.variant_id);
    if (plan !== 'monthly' && plan !== 'annual')
        throw new Error('billing_subscription_mismatch');
    const resolved = await resolveSubscription(attrs, id, account?.subscription_id === id ? account : null);
    const applied = await admin.rpc('billing_apply_subscription_v2', {
        p_user_id: userId, p_event_id: eventId, p_intent_id: existing ? null : (ref ?? null), p_subscription_id: id, p_customer_id: String(attrs.customer_id),
        p_status: resolved.status, p_ends_at: resolved.endsAt, p_updated_at: resolved.updatedAt, p_trial_ends_at: attrs.trial_ends_at ?? null,
        p_payment_at: resolved.paymentAt, p_invoice_id: resolved.invoiceId, p_order_id: String(attrs.order_id), p_variant_plan: plan, p_discounted: resolved.discounted,
    });
    const outcome = outcomeSchema.safeParse(applied.data);
    if (applied.error || !outcome.success)
        throw new Error('billing_reconciliation_failed');
    // The database refused to attach this purchase to the account (trial or first-month code the intent never offered, unusable
    // intent) and wrote the review event. The subscription is cancelled at the provider; the first delivery surfaces it for a human,
    // later deliveries (and the retry of this one) only make sure it stays cancelled.
    if (outcome.data === 'rejected' || outcome.data === 'rejected_known') {
        if (!isTerminal((await subscription(id)).attributes.status))
            await cancelAndConfirm(id);
        if (outcome.data === 'rejected')
            throw new Error('billing_purchase_rejected_review');
        return ok();
    }
    // A refunded plan must also stop billing: the refund itself does not cancel the provider subscription.
    if (resolved.status === 'refunded' && !isTerminal(attrs.status))
        await cancelAndConfirm(id);
    return ok();
}

/**
 * Subscription object + newest invoice -> the status and paid-through time we may store. Time is granted only for a
 * payment the provider confirms; a free trial is judged from the subscription alone (it has no invoice yet).
 */
async function resolveSubscription(attrs: Awaited<ReturnType<typeof subscription>>['attributes'], id: string, known: BillingAccount | null) {
    if (attrs.status === 'on_trial')
        return { status: 'on_trial', endsAt: null, updatedAt: attrs.updated_at, paymentAt: null, invoiceId: null, discounted: false };
    const invoice = await latestInvoice(id);
    if (!invoice) {
        // Only a trial can end without an invoice: cancelled in the trial keeps the trial's remaining time, nothing more.
        if (attrs.status === 'active')
            throw new Error('billing_payment_unconfirmed');
        const trialEnd = known?.trial_ends_at ? Date.parse(known.trial_ends_at) : null;
        const cancelEnd = attrs.status === 'cancelled' && attrs.ends_at && trialEnd !== null ? new Date(Math.min(Date.parse(attrs.ends_at), trialEnd)).toISOString() : null;
        return { status: attrs.status, endsAt: cancelEnd, updatedAt: attrs.updated_at, paymentAt: null, invoiceId: null, discounted: false };
    }
    const invoiceAttrs = invoice.attributes;
    const initial = invoiceAttrs.billing_reason === 'initial' ? await initialOrder(attrs.order_id) : null;
    const refunded = invoiceAttrs.refunded || invoiceAttrs.status === 'refunded' || !!initial?.refunded;
    const paid = ["paid", "partial_refund"].includes(invoiceAttrs.status) && !refunded;
    const status = refunded ? 'refunded' : ['expired', 'unpaid', 'paused', 'past_due'].includes(attrs.status) ? attrs.status : paid ? attrs.status : 'payment_pending';
    const updatedAt = new Date(Math.max(Date.parse(attrs.updated_at), Date.parse(invoiceAttrs.updated_at), initial ? Date.parse(initial.updated_at) : 0)).toISOString();
    return {
        status, updatedAt, paymentAt: paid ? invoiceAttrs.created_at : null, invoiceId: invoice.id, discounted: paid && invoiceAttrs.discount_total > 0,
        endsAt: !paid ? null : attrs.status === 'cancelled' ? attrs.ends_at : attrs.status === 'active' ? attrs.renews_at : null,
    };
}

async function reconcileOrder(event:BillingEvent,admin:SupabaseClient,eventId:string,config:BillingConfig){
    const orderId = event.data.id;
    const attrs = (await order(orderId)).attributes;
    const plan = variantPlan(config, attrs.first_order_item.variant_id);
    // Something else sold in the same store.
    if (plan === null)
        return ok();
    if (plan !== 'lifetime') {
        // The subscription events own a Pro entitlement; only a refund-type look-up goes back through the account.
        if (event.meta.event_name === 'order_created')
            return ok();
        const account = await accountOf(admin, 'order_id', orderId);
        if (!account?.subscription_id)
            throw new Error('billing_order_not_reconciled');
        return reconcileSubscription(admin, eventId, config, account.subscription_id, undefined);
    }
    const refunded = attrs.refunded || ['refunded', 'fraudulent'].includes(attrs.status);
    const owner = await accountOf(admin, 'lifetime_order_id', orderId);
    const ref = event.meta.custom_data?.checkout_ref;
    // A refunded order we never granted and cannot tie to an intent needs no change. With an intent, the refund may have overtaken
    // the paid delivery: the database binds the order to the intent's account and stores the final state.
    if (refunded && !owner && !ref)
        return ok();
    let userId = owner?.user_id;
    if (!userId && ref) {
        const { data } = await admin.from('billing_checkout_intents').select('user_id').eq('id', ref).maybeSingle().throwOnError();
        // A paid order of a deleted account cannot be bound to anyone: surface it for a human to refund.
        if (data && !data.user_id)
            throw new Error('billing_orphan_lifetime_order');
        userId = data?.user_id;
    }
    if (!userId)
        throw new Error('billing_unknown_order');
    if (!refunded && !['paid', 'partial_refund'].includes(attrs.status))
        throw new Error('billing_payment_unconfirmed');
    const status = refunded ? (attrs.status === 'fraudulent' ? 'fraudulent' : 'refunded') : 'active';
    const applied = await admin.rpc('billing_apply_lifetime', {
        p_user_id: userId, p_event_id: eventId, p_intent_id: ref ?? null, p_order_id: orderId, p_customer_id: String(attrs.customer_id),
        p_status: status, p_paid_at: attrs.created_at, p_updated_at: attrs.updated_at,
    });
    if (applied.error)
        throw new Error('billing_reconciliation_failed');
    // The database kept the first order and flagged this one; a human decides about the refund.
    if (applied.data === 'duplicate')
        throw new Error('billing_duplicate_purchase_review_refund');
    if (status === 'active' && applied.data !== 'stale') {
        const mine = await accountOf(admin, 'user_id', userId);
        if (mine?.subscription_id && !subscriptionEnded(mine, Date.now()))
            await cancelAsOverlap(admin, userId, mine.subscription_id);
    }
    return ok();
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

/**
 * Daily re-read of accounts whose provider state can change without a delivery we saw, plus refund claims that never
 * resolved (released so the buyer can ask again). The batch is claimed and stamped in one statement (billing_sweep_claim).
 */
export async function sweepBillingAccounts(admin: SupabaseClient, { limit = 20, deadline = Date.now() + 200_000 }: { limit?: number; deadline?: number } = {}) {
    const { data } = await admin.rpc('billing_sweep_claim', { p_limit: limit }).throwOnError();
    const rows = z.array(z.object({ user_id: z.string().uuid(), subscription_id: z.string().nullable(), lifetime_order_id: z.string().nullable(), refund_stale: z.boolean().nullable() })).parse(data ?? []);
    const config = billingConfig();
    let swept = 0, failed = 0;
    for (const row of rows) {
        // A row the deadline cuts off is never marked done: its claim lease runs out and it is a candidate again.
        if (Date.now() > deadline)
            break;
        try {
            if (row.subscription_id)
                await reconcileSubscription(admin, `sweep-${crypto.randomUUID()}`, config, row.subscription_id, undefined);
            if (row.lifetime_order_id)
                await reconcileWebhook({ meta: { event_name: 'taskforce_sweep', test_mode: config.test }, data: { id: row.lifetime_order_id, type: 'orders', attributes: {} } }, admin, `sweep-${crypto.randomUUID()}`);
            // The re-read above settled the claim if the provider refunded (the claim is gone). A claim that is still open after an hour never
            // turned into a refund: give it back, but the one self-service use stays spent (the refund call may have been sent).
            if (row.refund_stale)
                await admin.rpc('billing_release_refund', { p_user_id: row.user_id, p_clear_used: false }).throwOnError();
            await admin.rpc('billing_sweep_done', { p_user_id: row.user_id, p_ok: true }).throwOnError();
            swept++;
        } catch {
            failed++;
            // A failed account backs off for an hour (the database moves its lease); a lost stamp only means an earlier retry.
            await Promise.resolve(admin.rpc('billing_sweep_done', { p_user_id: row.user_id, p_ok: false })).catch(() => undefined);
        }
    }
    return { swept, failed };
}
