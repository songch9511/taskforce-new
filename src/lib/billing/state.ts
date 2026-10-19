import type { PlanState } from '@/lib/api/contract';
import { flagEnabled } from '@/lib/flags';
import { PAST_DUE_GRACE_DAYS, REFUND_WINDOW_HOURS } from './prices';
export type BillingAccount = {
    user_id: string;
    legacy_beta: boolean;
    notice_ends_at: string | null;
    trial_ends_at: string | null;
    subscription_id: string | null;
    customer_id: string | null;
    order_id: string | null;
    plan: 'monthly' | 'annual' | null;
    status: string;
    current_period_ends_at: string | null;
    deleting: boolean;
    first_subscription_at: string | null;
    lifetime_order_id: string | null;
    lifetime_status: 'active' | 'refunded' | 'fraudulent' | null;
    lifetime_paid_at: string | null;
    last_payment_at: string | null;
    last_invoice_id: string | null;
    refund_requested_at: string | null;
    self_refund_used_at: string | null;
};
export type BillingFlags = { billing: boolean; byok: boolean };
export type PlanInfo = {
    state: PlanState;
    plan: 'monthly' | 'annual' | 'lifetime' | null;
    /** AI and execution may start. Lifetime is true here; its calls still need the owner's own key. */
    ai: boolean;
    trial_ends_at: string | null;
    current_period_ends_at: string | null;
    cancel_at: string | null;
    notice_ends_at: string | null;
    can_checkout: boolean;
    can_buy_lifetime: boolean;
    with_trial: boolean;
    refund_until: string | null;
    refund_state: 'idle' | 'requested';
};
export const billingEnabled = () => process.env.BILLING_ENABLED === 'true';
export const billingFlags = (): BillingFlags => ({ billing: billingEnabled(), byok: flagEnabled('BYOK_ENABLED') });
const HOUR = 3_600_000;
const DAY = 86_400_000;
const LIVE_STATUSES = ['on_trial', 'active', 'past_due', 'payment_pending'];
export const isLiveSubscriptionStatus = (status: string) => LIVE_STATUSES.includes(status);
/** Mirrors billing_sub_ended() in 20261129000000_billing_pro_lifetime.sql: a replacement purchase is allowed. */
export function subscriptionEnded(account: BillingAccount, now: number): boolean {
    const periodEnd = account.current_period_ends_at ? Date.parse(account.current_period_ends_at) : -Infinity;
    return !account.subscription_id
        || ['expired', 'refunded', 'unpaid', 'paused'].includes(account.status)
        || (account.status === 'cancelled' && periodEnd <= now)
        || (account.status === 'payment_pending' && !account.current_period_ends_at);
}
/** Provider-created time of the payment a self-service refund would return, or null. Mirrors billing_claim_refund(). */
function refundablePayment(account: BillingAccount, now: number): number | null {
    const within = (value: string | null) => (value && Date.parse(value) > now - REFUND_WINDOW_HOURS * HOUR ? Date.parse(value) : null);
    if (account.lifetime_status === 'active' && account.lifetime_order_id) {
        const paid = within(account.lifetime_paid_at);
        if (paid !== null) return paid;
    }
    if (account.subscription_id && account.last_invoice_id && ['active', 'cancelled', 'past_due', 'payment_pending'].includes(account.status)) return within(account.last_payment_at);
    return null;
}
/**
 * Entitlement state, first matching row wins (contract 5.1). Mirrors billing_plan_kind() in SQL; a database test compares both.
 * Nothing here trusts a client or a success page: the account row is only ever written from provider data.
 */
export function planState(account: BillingAccount, now: number, flags: BillingFlags): PlanInfo {
    const future = (value: string | null) => !!value && Date.parse(value) > now;
    const refundable = refundablePayment(account, now);
    const refundOpen = flags.billing && !account.deleting && !account.self_refund_used_at && !account.refund_requested_at;
    const info = (state: PlanState, ai: boolean, extra: Partial<PlanInfo> = {}): PlanInfo => {
        const checkoutOpen = state === 'none' || (state === 'lapsed' && subscriptionEnded(account, now)) || (state === 'beta' && !!account.notice_ends_at);
        const sellable = flags.billing && !account.deleting;
        return {
            state, ai, plan: null, trial_ends_at: null, current_period_ends_at: null, cancel_at: null, notice_ends_at: null,
            can_checkout: sellable && checkoutOpen,
            can_buy_lifetime: sellable && flags.byok && (state === 'cancelled' || checkoutOpen),
            with_trial: sellable && checkoutOpen && !account.first_subscription_at,
            refund_until: refundOpen && refundable !== null ? new Date(refundable + REFUND_WINDOW_HOURS * HOUR).toISOString() : null,
            refund_state: flags.billing && !account.deleting && account.refund_requested_at ? 'requested' : 'idle',
            ...extra,
        };
    };
    // Flag off: everyone is the free beta of today (the old safeguards still apply), nothing is sold.
    if (!flags.billing) return info('beta', true);
    if (account.deleting) return info('lapsed', false);
    if (account.lifetime_status === 'active') return info('lifetime', true, { plan: 'lifetime' });
    if (account.status === 'on_trial' && future(account.trial_ends_at)) return info('trial', true, { plan: account.plan, trial_ends_at: account.trial_ends_at });
    if (account.status === 'active' && future(account.current_period_ends_at)) return info('pro', true, { plan: account.plan, current_period_ends_at: account.current_period_ends_at });
    if (account.status === 'cancelled' && future(account.current_period_ends_at))
        return info('cancelled', true, { plan: account.plan, current_period_ends_at: account.current_period_ends_at, cancel_at: account.current_period_ends_at });
    if (['past_due', 'payment_pending'].includes(account.status) && account.current_period_ends_at && now < Date.parse(account.current_period_ends_at) + PAST_DUE_GRACE_DAYS * DAY)
        return info('past_due', true, { plan: account.plan, current_period_ends_at: account.current_period_ends_at });
    if (account.legacy_beta && (!account.notice_ends_at || future(account.notice_ends_at))) return info('beta', true, { notice_ends_at: account.notice_ends_at });
    if (account.subscription_id || account.lifetime_status) return info('lapsed', false);
    return info('none', false);
}
/**
 * Contract v1 is frozen (contract-v1-freeze.test.ts): same keys, `can_checkout` always false, status in the old vocabulary.
 * The two price numbers are literals required by the frozen schema; no screen shows them any more.
 */
export function billingV1View(account: BillingAccount, info: PlanInfo) {
    const status = account.deleting ? 'deleting'
        : info.state === 'lifetime' || info.state === 'pro' ? 'active'
        : info.state === 'trial' ? 'trialing'
        : info.state === 'beta' ? 'legacy_beta'
        : info.state === 'cancelled' || info.state === 'past_due' ? info.state
        : account.subscription_id && account.status !== 'payment_pending' ? account.status : 'expired';
    return {
        status, plan: info.plan === 'lifetime' ? null : info.plan, trial_ends_at: info.trial_ends_at, current_period_ends_at: info.current_period_ends_at,
        can_use_ai: info.ai, can_checkout: false as const, monthly_price_usd: 9.99 as const, annual_price_usd: 101.9 as const,
    };
}
/**
 * Hidden fair-use window per account (Q2): set by the operator in the production environment, never shown to the user. SQL rejects
 * more than 100. The repository is public, so the code carries no value: an unset or invalid cap stops the paid path instead of
 * falling back to a number that would then be readable by everyone.
 */
export function billingBudgets() {
    const read = (name: string) => {
        const raw = process.env[name];
        return raw === undefined || raw.trim() === '' ? Number.NaN : Number(raw);
    };
    const monthly = read('BILLING_MONTHLY_AI_BUDGET_USD');
    const trial = read('BILLING_TRIAL_AI_BUDGET_USD');
    if (![monthly, trial].every(value => Number.isFinite(value) && value > 0 && value <= 100))
        throw new Error('billing_invalid_budget');
    return { p_monthly_cap: monthly, p_trial_cap: trial };
}
