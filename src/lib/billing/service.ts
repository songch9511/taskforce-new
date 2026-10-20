import { AiBudgetError } from '@/lib/ai/budget-error';
import { AI_KEY_LIMIT, checkKeyFormat, deleteUserKey, putUserKey, userKeyEncryptionKey, userKeyStatus, UserKeyError, verifyOpenRouterKey } from '@/lib/ai/user-key';
import { aiSpendSummarySchema, billingStatusV2Schema, type BillingStatusV2 } from '@/lib/api/contract';
import 'server-only';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { BILLING_TERMS_VERSION, REFUND_WINDOW_HOURS, billingPrices } from './prices';
import { billingEnabled, billingFlags, billingBudgets, billingV1View, planState, type BillingAccount, type PlanInfo } from './state';
import { billingConfig, cancelSubscription, invoiceOf, order, provider, refundInvoice, refundOrder, resumeSubscription, safeProviderUrl, subscription } from './provider';
import { enqueueReconcile } from './webhook';
export async function accountFor(admin: SupabaseClient, userId: string): Promise<BillingAccount> {
    await admin.from('billing_accounts').upsert({ user_id: userId }, { onConflict: 'user_id', ignoreDuplicates: true }).throwOnError();
    const { data } = await admin.from('billing_accounts').select('*').eq('user_id', userId).single().throwOnError();
    return data as BillingAccount;
}
/** With billing off nothing is read or sold: every account is the free beta of today. */
const blankAccount = (userId: string): BillingAccount => ({
    user_id: userId, legacy_beta: false, notice_ends_at: null, trial_ends_at: null, subscription_id: null, customer_id: null, order_id: null, plan: null, status: 'none',
    current_period_ends_at: null, deleting: false, first_subscription_at: null, lifetime_order_id: null, lifetime_status: null, lifetime_paid_at: null,
    last_payment_at: null, last_invoice_id: null, refund_requested_at: null, self_refund_used_at: null,
});
/** Throws billing_required when the account may not start AI or execution. Returns the state for callers that route on it. */
export async function requireBillingAccess(admin: SupabaseClient, userId: string): Promise<PlanInfo | null> {
    if (!billingEnabled())
        return null;
    const info = planState(await accountFor(admin, userId), Date.now(), billingFlags());
    if (!info.ai)
        throw new AiBudgetError('billing_required');
    return info;
}
/**
 * Pro (one subscription with a monthly and a yearly variant) or Lifetime. The server alone decides plan, price, variants,
 * trial, first-month code, terms version and return page: the client sends only which plan and which terms it showed.
 */
export async function checkout(admin: SupabaseClient, userId: string, plan: 'pro' | 'lifetime', termsVersion: string) {
    if (!billingEnabled())
        throw new Error('billing_disabled');
    if (termsVersion !== BILLING_TERMS_VERSION)
        throw new Error('billing_terms_required');
    const flags = billingFlags();
    if (plan === 'lifetime' && !flags.byok)
        throw new Error('billing_disabled');
    const config = billingConfig();
    const info = planState(await accountFor(admin, userId), Date.now(), flags);
    if (!(plan === 'pro' ? info.can_checkout : info.can_buy_lifetime))
        throw new Error('billing_subscription_exists');
    if ((plan === 'lifetime' && !config.variants.lifetime) || (plan === 'pro' && info.with_trial && !config.discountCode))
        throw new Error('billing_not_configured');
    // Account row lock serializes creation with deletion and webhook reconciliation.
    const claim = await admin.rpc('billing_claim_checkout_v2', { p_user_id: userId, p_plan: plan, p_terms_version: termsVersion });
    if (claim.error)
        throw new Error(claim.error.message.includes('billing_terms_required') ? 'billing_terms_required' : 'billing_checkout_pending');
    const intent = z.object({ id: z.string().uuid(), url: z.string().nullable(), expires_at: z.string(), with_trial: z.boolean(), with_discount: z.boolean() }).parse(claim.data);
    if (intent.url)
        return safeProviderUrl(intent.url);
    const variants = plan === 'pro' ? [config.variants.monthly, config.variants.annual] : [config.variants.lifetime as string];
    // Never accept prices, identity, variants, codes or return URLs from the client. No redirect_url: the provider's own completion page is shown.
    const attributes = {
        product_options: { enabled_variants: variants.map(Number) },
        checkout_options: plan === 'pro' ? { skip_trial: !intent.with_trial, subscription_preview: true, discount: false } : { discount: false },
        checkout_data: { custom: { checkout_ref: intent.id }, ...(intent.with_discount ? { discount_code: config.discountCode } : {}) },
        expires_at: intent.expires_at, test_mode: config.test,
    };
    let url: string;
    try {
        const result = z.object({ data: z.object({ attributes: z.object({ url: z.string().url() }) }) }).parse(await provider('checkouts', 'POST', { data: { type: 'checkouts', attributes, relationships: { store: { data: { type: 'stores', id: config.store } }, variant: { data: { type: 'variants', id: variants[0] } } } } }));
        url = safeProviderUrl(result.data.attributes.url);
    }
    catch (error) {
        // Free the pending claim so a transient provider failure does not lock the buyer out for the whole hour.
        await admin.from('billing_checkout_intents').update({ consumed_at: new Date().toISOString() }).eq('id', intent.id).eq('user_id', userId).is('url', null).then(() => undefined, () => undefined);
        throw error;
    }
    const stored = await admin.rpc('billing_checkout_url_v2', { p_user_id: userId, p_intent_id: intent.id, p_url: url });
    if (stored.error)
        throw new Error('billing_unavailable');
    return url;
}
/** v1 portal: opens the customer portal of whatever subscription the account has (old app builds). */
export async function portal(admin: SupabaseClient, userId: string) {
    const account = await accountFor(admin, userId);
    if (!account.subscription_id)
        throw new Error('billing_subscription_missing');
    return safeProviderUrl((await subscription(account.subscription_id)).attributes.urls.customer_portal);
}
/** v2 portal: manage = customer portal, payment = update payment method. Both are 24-hour signed provider links. */
export async function portalV2(admin: SupabaseClient, userId: string, target: 'manage' | 'payment') {
    if (!billingEnabled())
        throw new Error('billing_disabled');
    const account = await accountFor(admin, userId);
    if (!account.subscription_id)
        throw new Error('billing_subscription_missing');
    const urls = (await subscription(account.subscription_id)).attributes.urls;
    const raw = target === 'manage' ? urls.customer_portal : urls.update_payment_method;
    if (!raw)
        throw new Error('billing_portal_unavailable');
    const url = safeProviderUrl(raw);
    await admin.rpc('billing_record_event', { p_user_id: userId, p_type: 'billing_portal_opened', p_props: { target } }).throwOnError();
    return url;
}
/** Undo a cancellation while the paid period lasts. The entitlement changes when the provider confirms, never on this call. */
export async function resume(admin: SupabaseClient, userId: string) {
    if (!billingEnabled())
        throw new Error('billing_disabled');
    const account = await accountFor(admin, userId);
    if (planState(account, Date.now(), billingFlags()).state !== 'cancelled' || !account.subscription_id)
        throw new Error('billing_resume_unavailable');
    await resumeSubscription(account.subscription_id);
    await enqueueReconcile(admin, 'subscriptions', account.subscription_id);
    return { requested: true as const };
}
export type OpenRouterKeyResult =
    | { ok: true }
    | { ok: false; reason: 'invalid' | 'management' | 'unavailable' | 'not_entitled' }
    | { ok: false; reason: 'rate_limited'; retryAt: Date };
/**
 * Lifetime owner's own OpenRouter key (BYOK, contract 6.5). Checked with OpenRouter before anything is stored: an unverifiable key is never kept.
 * Only a Lifetime account may hold one (a key nobody can use is a secret we should not keep). The attempt count is taken before the outbound
 * call so the server cannot be used as a key-checking tool. The key lives in this call and in the sealed row; it is in no result, error or log.
 */
export async function saveOpenRouterKey(admin: SupabaseClient, userId: string, raw: string, send: typeof fetch = fetch): Promise<OpenRouterKeyResult> {
    if (!billingEnabled())
        return { ok: false, reason: 'not_entitled' };
    if (planState(await accountFor(admin, userId), Date.now(), billingFlags()).state !== 'lifetime')
        return { ok: false, reason: 'not_entitled' };
    const format = checkKeyFormat(raw);
    if (!format.ok)
        return { ok: false, reason: 'invalid' };
    // A server that cannot seal must not spend the user's attempt or send their key anywhere: fail before the outbound call.
    userKeyEncryptionKey();
    const taken = await admin.rpc('take_rate_limit', { p_user_id: userId, p_kind: 'ai_key', p_max: AI_KEY_LIMIT.max, p_window_seconds: AI_KEY_LIMIT.windowMs / 1000 });
    if (taken.error)
        throw new Error('billing_unavailable');
    if (taken.data)
        return { ok: false, reason: 'rate_limited', retryAt: new Date(String(taken.data)) };
    const verdict = await verifyOpenRouterKey(format.key, send);
    if (verdict !== 'ok')
        return { ok: false, reason: verdict };
    try {
        await putUserKey(admin, userId, format.key);
    }
    catch (error) {
        // The database re-checks the entitlement under the account lock (a refund can land while OpenRouter was being asked).
        if (error instanceof UserKeyError && error.code === 'byok_not_entitled')
            return { ok: false, reason: 'not_entitled' };
        throw error;
    }
    return { ok: true };
}
/** Removes the stored key (and writes the event). Nothing to remove is not an error. */
export async function removeOpenRouterKey(admin: SupabaseClient, userId: string): Promise<void> {
    await deleteUserKey(admin, userId);
}
const bestEffort = (step: Promise<unknown>) => step.then(() => undefined, () => { console.error('billing follow-up failed'); });
const withinRefundWindow = (createdAt: string) => Date.now() - Date.parse(createdAt) <= REFUND_WINDOW_HOURS * 3_600_000;
/**
 * Self-service refund of the latest payment, once per account. The window is checked again against the provider's own
 * timestamps. Asking changes nothing: the plan ends only when the provider reports the refund (webhook or the queued re-read).
 *
 * Only a refusal BEFORE the refund call gives the claim and the use back. Once the call is sent its outcome may be unknown
 * (error answer, lost connection, timeout while the money moved): the claim and the use then stay, and a re-read of the
 * provider's own object settles it (confirmed refund -> the sweep closes the claim; no refund -> the sweep releases the claim
 * and keeps the use).
 */
export async function requestRefund(admin: SupabaseClient, userId: string) {
    if (!billingEnabled())
        throw new Error('billing_disabled');
    const claim = await admin.rpc('billing_claim_refund', { p_user_id: userId });
    if (claim.error)
        throw new Error(['billing_refund_used', 'billing_refund_pending', 'billing_refund_window_closed', 'billing_refund_unavailable'].find(code => claim.error.message.includes(code)) ?? 'billing_unavailable');
    const target = z.discriminatedUnion('kind', [
        z.object({ kind: z.literal('subscription'), subscription_id: z.string(), invoice_id: z.string(), plan: z.enum(['monthly', 'annual']), claim_key: z.string().min(1) }),
        z.object({ kind: z.literal('lifetime'), order_id: z.string(), claim_key: z.string().min(1) }),
    ]).parse(claim.data);
    const reread = target.kind === 'subscription' ? () => enqueueReconcile(admin, 'subscriptions', target.subscription_id) : () => enqueueReconcile(admin, 'orders', target.order_id);
    let posted = false;
    try {
        // Reads first: nothing has been sent yet, so any failure in here is a clean refusal.
        const current = target.kind === 'subscription' ? (await invoiceOf(target.subscription_id, target.invoice_id)).attributes : (await order(target.order_id)).attributes;
        if (current.refunded || current.status === 'refunded') {
            // Money already moved (an earlier unknown attempt, or the dashboard): keep the claim, let the re-read confirm it.
            await bestEffort(reread());
            throw new Error('billing_refund_pending');
        }
        if (current.status !== 'paid' || !withinRefundWindow(current.created_at))
            throw new Error('billing_refund_window_closed');
        posted = true;
        if (target.kind === 'subscription')
            await refundInvoice(target.invoice_id);
        else
            await refundOrder(target.order_id);
    }
    catch (error) {
        if (!posted) {
            // Nothing was sent. Pending (already refunded) keeps the claim; every other refusal gives the claim and the use back.
            if (!(error instanceof Error && error.message === 'billing_refund_pending'))
                await bestEffort(Promise.resolve(admin.rpc('billing_release_refund', { p_user_id: userId, p_clear_used: true }).throwOnError()));
        }
        else {
            // Unknown outcome: keep the claim and the use, ask the provider again.
            await bestEffort(reread());
        }
        throw error;
    }
    // Stop the next renewal. A failure here is repaired by the re-read (a refunded plan is cancelled there too).
    if (target.kind === 'subscription')
        await bestEffort(cancelSubscription(target.subscription_id));
    await bestEffort(reread());
    await bestEffort(Promise.resolve(admin.rpc('billing_record_event', { p_user_id: userId, p_type: 'billing_refund_requested', p_props: { plan: target.kind === 'lifetime' ? 'lifetime' : target.plan }, p_dedupe_id: target.claim_key }).throwOnError()));
    return { requested: true as const };
}
export async function rollbackDeletion(admin: SupabaseClient, userId: string, token: string) {
    await admin.from('billing_accounts').update({deleting:false,deleting_token:null}).eq('user_id',userId).eq('deleting_token',token).throwOnError();
}
export async function cancelBeforeDeletion(admin: SupabaseClient, userId: string): Promise<string | null> {
    const { data, error } = await admin.from('billing_accounts').select('*').eq('user_id', userId).maybeSingle();
    if (error) throw new Error('billing_unavailable');
    if (!data) return null;
    const token=crypto.randomUUID();
    let claimed=false;
    try {
        const locked=await admin.from('billing_accounts').update({deleting:true,deleting_token:token}).eq('user_id',userId).eq('deleting',false).select('subscription_id').maybeSingle();
        if(locked.error)throw new Error('billing_unavailable');
        if(!locked.data)throw new Error('billing_deletion_busy');
        claimed=true;
        const pending=await admin.from('billing_checkout_intents').select('id').eq('user_id',userId).is('consumed_at',null).gt('expires_at',new Date().toISOString()).throwOnError();
        if(pending.data?.length)throw new Error('billing_checkout_pending');
        if(locked.data.subscription_id){
            const current=await subscription(locked.data.subscription_id);
            if(!['cancelled','expired'].includes(current.attributes.status))await provider(`subscriptions/${current.id}`,'DELETE');
            const confirmed=await subscription(current.id);
            if(!['cancelled','expired'].includes(confirmed.attributes.status))throw new Error('billing_cancellation_unconfirmed');
        }
        return token;
    } catch(error) {
        if(claimed)await rollbackDeletion(admin,userId,token);
        throw error;
    }
}
const utcMonthStart = (now: number, monthsAhead = 0) => new Date(Date.UTC(new Date(now).getUTCFullYear(), new Date(now).getUTCMonth() + monthsAhead, 1)).toISOString();
/** v1 status (frozen shape): same keys as before, new states mapped into the old vocabulary, never sells. */
export async function billingSummary(admin: SupabaseClient, userId: string) {
    const flags = billingFlags();
    const account = flags.billing ? await accountFor(admin, userId) : blankAccount(userId);
    const info = planState(account, Date.now(), flags);
    // Only the grandfathered beta still has a visible allowance; paid and trial accounts have a hidden fair-use window.
    let allowance = null;
    if (info.state === 'beta' && info.ai) {
        const { data, error } = await admin.rpc('ai_spend_summary', { p_user_id: userId });
        if (error)
            throw new Error('billing_unavailable');
        allowance = aiSpendSummarySchema.parse(data);
    }
    return { ...billingV1View(account, info), ai_allowance: allowance, allowance_resets_at: null };
}
const windowSummarySchema = z.object({
    cap_usd: z.number().finite().positive(), confirmed_usd: z.number().finite().nonnegative(), reserved_usd: z.number().finite().nonnegative(),
    pending_count: z.number().int().nonnegative(), remaining_usd: z.number().finite().nonnegative(), status: z.enum(['available', 'exhausted', 'provider_bound_violation']),
});
/**
 * GET /api/v1/ai-budget for app builds that still draw the old "AI allowance" line. The v1 shape stays (cap 10, nothing above 10)
 * and no state that can still use AI is an error. A paid or trial window is shown on that legacy 10-unit scale, so the operator's
 * hidden cap never leaves the server; Lifetime has no managed spend at all; a plan that ended is billing_required (403), not an outage.
 */
export async function aiAllowanceV1(admin: SupabaseClient, userId: string) {
    const read = async (name: string, args: Record<string, unknown>) => {
        const { data, error } = await admin.rpc(name, args);
        if (error)
            throw new Error('billing_unavailable');
        return data;
    };
    const legacy = async () => aiSpendSummarySchema.parse(await read('ai_spend_summary', { p_user_id: userId }));
    if (!billingEnabled())
        return legacy();
    const info = planState(await accountFor(admin, userId), Date.now(), billingFlags());
    if (info.state === 'beta')
        return legacy();
    if (info.state === 'lifetime')
        return aiSpendSummarySchema.parse({ cap_usd: 10, confirmed_usd: 0, reserved_usd: 0, pending_count: 0, remaining_usd: 10, status: 'available' });
    if (!['trial', 'pro', 'cancelled', 'past_due'].includes(info.state))
        throw new AiBudgetError('billing_required');
    const window = windowSummarySchema.parse(await read('billing_spend_summary_v2', { p_user_id: userId, ...billingBudgets() }));
    // Whole units on the legacy 10-unit scale: what was used rounds up, what is left rounds down, so no fraction can be used to work
    // back to the hidden cap (the first rounding only removes floating-point noise before the whole-unit step).
    const units = (usd: number) => Math.round(Math.min(10, usd * (10 / window.cap_usd)) * 1e6) / 1e6;
    return aiSpendSummarySchema.parse({
        cap_usd: 10, confirmed_usd: Math.ceil(units(window.confirmed_usd)), reserved_usd: Math.ceil(units(window.reserved_usd)), pending_count: window.pending_count,
        remaining_usd: Math.floor(units(window.remaining_usd)), status: window.status,
    });
}
/** v2 status. `fair_use_paused_until` is the only trace of the hidden cap; the cap itself never leaves the server. */
export async function billingStatusV2(admin: SupabaseClient, userId: string): Promise<BillingStatusV2> {
    const flags = billingFlags();
    const now = Date.now();
    const account = flags.billing ? await accountFor(admin, userId) : blankAccount(userId);
    const info = planState(account, now, flags);
    let usage: BillingStatusV2['ai_usage_this_month'] = null;
    let pausedUntil: string | null = null;
    if (flags.billing && ['trial', 'pro', 'cancelled', 'past_due'].includes(info.state)) {
        const since = utcMonthStart(now);
        const tokens = await admin.rpc('billing_usage_tokens', { p_user_id: userId, p_since: since });
        if (tokens.error)
            throw new Error('billing_unavailable');
        const counted = z.object({ prompt_tokens: z.number().int().nonnegative(), completion_tokens: z.number().int().nonnegative() }).parse(tokens.data);
        usage = { since, ...counted, total_tokens: counted.prompt_tokens + counted.completion_tokens };
        // Display only: a failure here must not hide the plan.
        const summary = await admin.rpc('billing_spend_summary_v2', { p_user_id: userId, ...billingBudgets() });
        if (!summary.error && z.object({ status: z.string() }).safeParse(summary.data).data?.status === 'exhausted')
            // The window is the trial's while no payment has happened (also for a plan cancelled inside its trial); a paid account's is the UTC month.
            pausedUntil = info.state === 'trial' || !account.last_payment_at ? (account.trial_ends_at ?? info.current_period_ends_at) : utcMonthStart(now, 1);
    }
    // Only a Lifetime account has a key to report; the sealed value is never read for this.
    const key = info.state === 'lifetime' ? await userKeyStatus(admin, userId).catch(() => { throw new Error('billing_unavailable'); }) : null;
    return billingStatusV2Schema.parse({
        state: info.state, plan: info.plan, trial_ends_at: info.trial_ends_at, current_period_ends_at: info.current_period_ends_at, cancel_at: info.cancel_at,
        notice_ends_at: info.notice_ends_at, refund_until: info.refund_until, refund_state: info.refund_state, can_use_ai: info.ai, can_checkout: info.can_checkout,
        can_buy_lifetime: info.can_buy_lifetime, with_trial: info.with_trial, terms_version: BILLING_TERMS_VERSION, prices: billingPrices(),
        ai_usage_this_month: usage, fair_use_paused_until: pausedUntil,
        ai_key: key?.ai_key ?? null, ai_key_spend_error_at: key?.spend_error_at ?? null,
    });
}
