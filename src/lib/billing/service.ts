import { inBillingSync } from './sync-context';
import { AiBudgetError } from '@/lib/ai/budget-error';
import { aiSpendSummarySchema } from '@/lib/api/contract';
import 'server-only';
import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { billingEnabled, billingState, billingBudgets, type BillingAccount } from './state';
import { billingConfig, provider, safeProviderUrl, subscription } from './provider';
export async function accountFor(admin: SupabaseClient, userId: string): Promise<BillingAccount> {
    await admin.from('billing_accounts').upsert({ user_id: userId }, { onConflict: 'user_id', ignoreDuplicates: true }).throwOnError();
    const { data } = await admin.from('billing_accounts').select('*').eq('user_id', userId).single().throwOnError();
    return data as BillingAccount;
}
export async function requireBillingAccess(admin: SupabaseClient, userId: string) {
    if (!billingEnabled())
        return;
    await accountFor(admin, userId);
    await admin.from('billing_accounts').update({onboarding_started_at:new Date().toISOString()}).eq('user_id',userId).is('onboarding_started_at',null).throwOnError();
    const account=await accountFor(admin,userId);
    const initialSync=inBillingSync(userId)&&!account.deleting&&!account.trial_ends_at&&!account.subscription_id;
    if (!billingState(account).can_use_ai && !initialSync)
        throw new AiBudgetError('billing_required');
}
export async function startTrial(admin: SupabaseClient, userId: string) {
    if (!billingEnabled())
        return;
    const { error } = await admin.rpc('billing_start_trial', { p_user_id: userId });
    if (error)
        throw new Error('billing_unavailable');
}
export async function checkout(admin: SupabaseClient, userId: string, plan: 'monthly' | 'annual', termsVersion: '2026-10-08') {
    if (!billingEnabled())
        throw new Error('billing_disabled');
    const config = billingConfig();
    const account = await accountFor(admin, userId);
    if (!billingState(account).can_checkout)
        throw new Error('billing_subscription_exists');
    // Account row lock serializes creation with deletion and webhook reconciliation.
    const claim = await admin.rpc('billing_claim_checkout', { p_user_id: userId, p_plan: plan, p_terms_version: termsVersion });
    if (claim.error)
        throw new Error('billing_checkout_pending');
    const intent = z.object({ id: z.string().uuid(), url: z.string().nullable(), expires_at: z.string() }).parse(claim.data);
    if (intent.url)
        return safeProviderUrl(intent.url);
    const expires = intent.expires_at;
    const variant = config.variants[plan];
    // Never accept prices, identity, return URLs, or variants from the client.
    const result = z.object({ data: z.object({ attributes: z.object({ url: z.string().url() }) }) }).parse(await provider('checkouts', 'POST', { data: { type: 'checkouts', attributes: { product_options: { enabled_variants: [Number(variant)], redirect_url: 'https://api.taskforcelabs.dev/billing?checkout=complete' }, checkout_options: { skip_trial: true, subscription_preview: true }, checkout_data: { custom: { checkout_ref: intent.id } }, expires_at: expires, test_mode: config.test }, relationships: { store: { data: { type: 'stores', id: config.store } }, variant: { data: { type: 'variants', id: variant } } } } }));
    const url = safeProviderUrl(result.data.attributes.url);
    await admin.from('billing_checkout_intents').update({ url }).eq('id', intent.id).eq('user_id', userId).throwOnError();
    return url;
}
export async function portal(admin: SupabaseClient, userId: string) {
    const account = await accountFor(admin, userId);
    if (!account.subscription_id)
        throw new Error('billing_subscription_missing');
    return safeProviderUrl((await subscription(account.subscription_id)).attributes.urls.customer_portal);
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

export async function mayRetryInitialSync(admin:SupabaseClient,userId:string) {
    if(!billingEnabled())return false;
    const account=await accountFor(admin,userId);
    return !account.deleting && !account.legacy_beta && !account.subscription_id && !account.trial_ends_at && !billingState(account).can_use_ai;
}
export async function requireSyncBillingAccess(admin:SupabaseClient,userId:string) {
    if(await mayRetryInitialSync(admin,userId))return;
    await requireBillingAccess(admin,userId);
}
export async function billingSummary(admin: SupabaseClient, userId: string) {
    const account = await accountFor(admin, userId);
    const state = billingState(account);
    let allowance = null;
    if (state.can_use_ai) {
        const { data, error } = await admin.rpc(billingEnabled() ? 'billing_spend_summary' : 'ai_spend_summary', { p_user_id: userId, ...(billingEnabled() ? billingBudgets() : {}) });
        if (error)
            throw new Error('billing_unavailable');
        allowance = aiSpendSummarySchema.parse(data);
    }
    const paid = ['active', 'cancelled'].includes(state.status);
    const now = new Date();
    return { ...state, can_use_ai: billingEnabled() ? state.can_use_ai : true, can_checkout: billingEnabled() && state.can_checkout, ai_allowance: allowance, allowance_resets_at: paid ? new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString() : null };
}
