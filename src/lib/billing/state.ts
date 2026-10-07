export type BillingAccount = {
    user_id: string;
    legacy_beta: boolean;
    notice_ends_at: string | null;
    onboarding_started_at: string | null;
    trial_ends_at: string | null;
    subscription_id: string | null;
    customer_id: string | null;
    plan: 'monthly' | 'annual' | null;
    status: string;
    current_period_ends_at: string | null;
    deleting: boolean;
};
export const billingEnabled = () => process.env.BILLING_ENABLED === 'true';
export function billingState(account: BillingAccount, now = Date.now()) {
    const future = (value: string | null) => !!value && Date.parse(value) > now;
    const paid = ['active', 'cancelled'].includes(account.status) && future(account.current_period_ends_at);
    const legacy = account.legacy_beta && (!account.notice_ends_at || future(account.notice_ends_at));
    const trial = !account.subscription_id && future(account.trial_ends_at);
    const onboarding = !account.subscription_id && !account.trial_ends_at && (!account.onboarding_started_at || Date.parse(account.onboarding_started_at) + 86400000 > now);
    return {
        status: account.deleting ? 'deleting' : paid ? account.status : legacy ? 'legacy_beta' : trial ? 'trialing' : onboarding ? 'trial_pending' : account.subscription_id && !['active', 'cancelled'].includes(account.status) ? account.status : 'expired',
        plan: account.plan, trial_ends_at: account.trial_ends_at, current_period_ends_at: account.current_period_ends_at,
        can_use_ai: !account.deleting && (paid || legacy || trial || onboarding),
        can_checkout: !account.deleting && (!account.subscription_id || account.status === 'expired'),
        monthly_price_usd: 9.99, annual_price_usd: 101.9,
    };
}
export function billingBudgets() {
    const monthly = Number(process.env.BILLING_MONTHLY_AI_BUDGET_USD ?? '3');
    const trial = Number(process.env.BILLING_TRIAL_AI_BUDGET_USD ?? '1');
    if (![monthly, trial].every(value => Number.isFinite(value) && value > 0 && value <= 10))
        throw new Error('billing_invalid_budget');
    return { p_monthly_cap: monthly, p_trial_cap: trial };
}
