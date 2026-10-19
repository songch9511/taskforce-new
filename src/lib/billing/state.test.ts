import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, it, expect, afterEach, vi } from 'vitest';
import { billingStatusSchema } from '../api/contract';
import { billingBudgets, billingV1View, planState, subscriptionEnded, type BillingAccount, type BillingFlags } from './state';
const NOW = Date.parse('2026-10-19T12:00:00Z');
const iso = (offsetMs: number) => new Date(NOW + offsetMs).toISOString();
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const base: BillingAccount = {
    user_id: 'alice', legacy_beta: false, notice_ends_at: null, trial_ends_at: null, subscription_id: null, customer_id: null, order_id: null, plan: null,
    status: 'none', current_period_ends_at: null, deleting: false, first_subscription_at: null, lifetime_order_id: null, lifetime_status: null, lifetime_paid_at: null,
    last_payment_at: null, last_invoice_id: null, refund_requested_at: null, self_refund_used_at: null,
};
const on: BillingFlags = { billing: true, byok: true };
const state = (account: Partial<BillingAccount>, flags: BillingFlags = on) => planState({ ...base, ...account }, NOW, flags);
afterEach(() => vi.unstubAllEnvs());

describe('entitlement table (contract 5.1), first matching row wins', () => {
    it.each<[string, Partial<BillingAccount>, string, boolean]>([
        ['billing off: everyone is beta', { status: 'expired', subscription_id: 's' }, 'beta', true],
        ['deleting', { deleting: true, status: 'active', current_period_ends_at: iso(DAY) }, 'lapsed', false],
        ['deleting beats an active lifetime', { deleting: true, lifetime_status: 'active' }, 'lapsed', false],
        ['lifetime', { lifetime_status: 'active', lifetime_order_id: 'o' }, 'lifetime', true],
        ['lifetime beats a live pro', { lifetime_status: 'active', status: 'active', current_period_ends_at: iso(DAY) }, 'lifetime', true],
        ['trial', { status: 'on_trial', subscription_id: 's', trial_ends_at: iso(DAY) }, 'trial', true],
        ['trial over', { status: 'on_trial', subscription_id: 's', trial_ends_at: iso(-1) }, 'lapsed', false],
        ['pro', { status: 'active', subscription_id: 's', current_period_ends_at: iso(DAY) }, 'pro', true],
        ['pro period over', { status: 'active', subscription_id: 's', current_period_ends_at: iso(-1) }, 'lapsed', false],
        ['cancelled inside its period', { status: 'cancelled', subscription_id: 's', current_period_ends_at: iso(DAY) }, 'cancelled', true],
        ['cancelled after its period', { status: 'cancelled', subscription_id: 's', current_period_ends_at: iso(-1) }, 'lapsed', false],
        ['past_due inside the 16-day cap', { status: 'past_due', subscription_id: 's', current_period_ends_at: iso(-15 * DAY) }, 'past_due', true],
        ['payment_pending inside the cap', { status: 'payment_pending', subscription_id: 's', current_period_ends_at: iso(-DAY) }, 'past_due', true],
        ['past_due beyond the cap', { status: 'past_due', subscription_id: 's', current_period_ends_at: iso(-16 * DAY - 1) }, 'lapsed', false],
        ['past_due that never had a paid period', { status: 'past_due', subscription_id: 's' }, 'lapsed', false],
        ['beta', { legacy_beta: true }, 'beta', true],
        ['beta with a future notice', { legacy_beta: true, notice_ends_at: iso(DAY) }, 'beta', true],
        ['beta after the notice', { legacy_beta: true, notice_ends_at: iso(-1) }, 'none', false],
        ['beta after the notice, past plan', { legacy_beta: true, notice_ends_at: iso(-1), subscription_id: 's', status: 'expired' }, 'lapsed', false],
        ['a paying beta account is a pro', { legacy_beta: true, status: 'active', subscription_id: 's', current_period_ends_at: iso(DAY) }, 'pro', true],
        ['expired', { status: 'expired', subscription_id: 's' }, 'lapsed', false],
        ['refunded', { status: 'refunded', subscription_id: 's' }, 'lapsed', false],
        ['refunded lifetime', { lifetime_status: 'refunded' }, 'lapsed', false],
        ['no record', {}, 'none', false],
    ])('%s', (label, account, expected, ai) => {
        const result = state(account, label.startsWith('billing off') ? { billing: false, byok: true } : on);
        expect(result.state).toBe(expected);
        expect(result.ai).toBe(ai);
    });
    it('the paid period ends exactly at its end time and the grace at 16 days after it', () => {
        const sub = { subscription_id: 's' };
        expect(state({ ...sub, status: 'active', current_period_ends_at: iso(1) }).state).toBe('pro');
        expect(state({ ...sub, status: 'active', current_period_ends_at: iso(0) }).state).toBe('lapsed');
        expect(state({ ...sub, status: 'past_due', current_period_ends_at: iso(-16 * DAY + 1) }).state).toBe('past_due');
        expect(state({ ...sub, status: 'past_due', current_period_ends_at: iso(-16 * DAY) }).state).toBe('lapsed');
        expect(state({ ...sub, status: 'on_trial', trial_ends_at: iso(0) }).state).toBe('lapsed');
    });
    it('exposes the plan, trial end, period end and cancel date the screens need', () => {
        expect(state({ status: 'on_trial', plan: 'monthly', trial_ends_at: iso(DAY) })).toMatchObject({ state: 'trial', plan: 'monthly', trial_ends_at: iso(DAY), current_period_ends_at: null });
        expect(state({ status: 'active', plan: 'annual', current_period_ends_at: iso(DAY) })).toMatchObject({ plan: 'annual', current_period_ends_at: iso(DAY), cancel_at: null });
        expect(state({ status: 'cancelled', plan: 'monthly', current_period_ends_at: iso(DAY) })).toMatchObject({ cancel_at: iso(DAY) });
        expect(state({ lifetime_status: 'active' }).plan).toBe('lifetime');
        expect(state({ legacy_beta: true, notice_ends_at: iso(DAY) }).notice_ends_at).toBe(iso(DAY));
        expect(state({ status: 'expired', subscription_id: 's' }).plan).toBeNull();
    });
});

describe('what can be sold', () => {
    const sale = (account: Partial<BillingAccount>, flags = on) => { const s = state(account, flags); return [s.can_checkout, s.can_buy_lifetime, s.with_trial]; };
    it('a new account can start Pro with the trial and buy Lifetime', () => {
        expect(sale({})).toEqual([true, true, true]);
    });
    it('the trial is offered once: an account that ever had a subscription restarts without it', () => {
        expect(sale({ status: 'expired', subscription_id: 's', first_subscription_at: iso(-DAY) })).toEqual([true, true, false]);
    });
    it('Lifetime needs the BYOK flag', () => {
        expect(sale({}, { billing: true, byok: false })).toEqual([true, false, true]);
    });
    it('nothing is sold while billing is off or the account is being deleted', () => {
        expect(sale({}, { billing: false, byok: true })).toEqual([false, false, false]);
        expect(sale({ deleting: true })).toEqual([false, false, false]);
    });
    it('a live Pro sells nothing; a cancelled Pro may buy Lifetime but not another Pro', () => {
        for (const live of [{ status: 'on_trial', trial_ends_at: iso(DAY) }, { status: 'active', current_period_ends_at: iso(DAY) }, { status: 'past_due', current_period_ends_at: iso(-DAY) }])
            expect(sale({ ...live, subscription_id: 's' })).toEqual([false, false, false]);
        expect(sale({ status: 'cancelled', subscription_id: 's', current_period_ends_at: iso(DAY), first_subscription_at: iso(-DAY) })).toEqual([false, true, false]);
    });
    it('an owner of Lifetime sells nothing', () => {
        expect(sale({ lifetime_status: 'active' })).toEqual([false, false, false]);
    });
    it('a beta account sees the sale only after its notice is set', () => {
        expect(sale({ legacy_beta: true })).toEqual([false, false, false]);
        expect(sale({ legacy_beta: true, notice_ends_at: iso(DAY) })).toEqual([true, true, true]);
    });
    it('a lapsed account restarts only once its old subscription can no longer bill', () => {
        expect(sale({ status: 'active', subscription_id: 's', current_period_ends_at: iso(-DAY), first_subscription_at: iso(-30 * DAY) })).toEqual([false, false, false]);
        expect(sale({ status: 'past_due', subscription_id: 's', current_period_ends_at: iso(-20 * DAY), first_subscription_at: iso(-60 * DAY) })).toEqual([false, false, false]);
        expect(sale({ status: 'expired', subscription_id: 's', first_subscription_at: iso(-60 * DAY) })).toEqual([true, true, false]);
        expect(sale({ lifetime_status: 'refunded', lifetime_order_id: 'o' })).toEqual([true, true, true]);
    });
    it('subscriptionEnded matches the database helper', () => {
        const ended = (account: Partial<BillingAccount>) => subscriptionEnded({ ...base, ...account }, NOW);
        expect(ended({})).toBe(true);
        for (const status of ['expired', 'refunded', 'unpaid', 'paused']) expect(ended({ subscription_id: 's', status })).toBe(true);
        expect(ended({ subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(-1) })).toBe(true);
        expect(ended({ subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(1) })).toBe(false);
        expect(ended({ subscription_id: 's', status: 'cancelled' })).toBe(true);
        expect(ended({ subscription_id: 's', status: 'payment_pending' })).toBe(true);
        expect(ended({ subscription_id: 's', status: 'payment_pending', current_period_ends_at: iso(-DAY) })).toBe(false);
        for (const status of ['active', 'on_trial', 'past_due']) expect(ended({ subscription_id: 's', status })).toBe(false);
    });
});

describe('refund window shown to the buyer', () => {
    const paid = { subscription_id: 's', status: 'active', plan: 'monthly' as const, last_invoice_id: 'inv', current_period_ends_at: iso(30 * DAY) };
    it('is 72 hours from the provider payment time and only for a payment that can be refunded', () => {
        expect(state({ ...paid, last_payment_at: iso(-HOUR) }).refund_until).toBe(iso(71 * HOUR));
        expect(state({ ...paid, last_payment_at: iso(-72 * HOUR) }).refund_until).toBeNull();
        expect(state({ ...paid, last_payment_at: iso(-HOUR), last_invoice_id: null }).refund_until).toBeNull();
        expect(state({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-2 * HOUR) }).refund_until).toBe(iso(70 * HOUR));
        expect(state({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-80 * HOUR) }).refund_until).toBeNull();
    });
    it('closes after the one self-service refund and while one is being processed', () => {
        expect(state({ ...paid, last_payment_at: iso(-HOUR), self_refund_used_at: iso(-DAY) }).refund_until).toBeNull();
        const asked = state({ ...paid, last_payment_at: iso(-HOUR), refund_requested_at: iso(-60_000), self_refund_used_at: iso(-60_000) });
        expect(asked.refund_until).toBeNull();
        expect(asked.refund_state).toBe('requested');
        expect(state({ ...paid, last_payment_at: iso(-HOUR) }).refund_state).toBe('idle');
    });
    it('is never offered with billing off or for a deleting account', () => {
        expect(state({ ...paid, last_payment_at: iso(-HOUR) }, { billing: false, byok: true }).refund_until).toBeNull();
        expect(state({ ...paid, last_payment_at: iso(-HOUR), deleting: true }).refund_until).toBeNull();
    });
});

describe('v1 view stays inside the frozen contract', () => {
    const view = (account: Partial<BillingAccount>, flags = on) => { const merged = { ...base, ...account }; return billingV1View(merged, planState(merged, NOW, flags)); };
    it.each<[string, Partial<BillingAccount>, string, string | null, boolean]>([
        ['lifetime is active with no plan', { lifetime_status: 'active' }, 'active', null, true],
        ['trial', { status: 'on_trial', plan: 'monthly', subscription_id: 's', trial_ends_at: iso(DAY) }, 'trialing', 'monthly', true],
        ['pro', { status: 'active', plan: 'annual', subscription_id: 's', current_period_ends_at: iso(DAY) }, 'active', 'annual', true],
        ['cancelled', { status: 'cancelled', plan: 'monthly', subscription_id: 's', current_period_ends_at: iso(DAY) }, 'cancelled', 'monthly', true],
        ['past_due keeps working', { status: 'past_due', plan: 'monthly', subscription_id: 's', current_period_ends_at: iso(-DAY) }, 'past_due', 'monthly', true],
        ['beta', { legacy_beta: true }, 'legacy_beta', null, true],
        ['no plan', {}, 'expired', null, false],
        ['refunded plan keeps its provider status word', { status: 'refunded', subscription_id: 's' }, 'refunded', null, false],
        ['an unconfirmed first payment reads as expired', { status: 'payment_pending', subscription_id: 's' }, 'expired', null, false],
        ['deleting', { deleting: true }, 'deleting', null, false],
    ])('%s', (_label, account, status, plan, ai) => {
        const result = view(account);
        expect(result).toMatchObject({ status, plan, can_use_ai: ai, can_checkout: false });
        // the frozen schema accepts the whole response
        expect(billingStatusSchema.parse({ ...result, ai_allowance: null, allowance_resets_at: null })).toBeTruthy();
    });
    it('can_checkout is false for every state: the retired plan can no longer be bought', () => {
        expect(view({}).can_checkout).toBe(false);
        expect(view({ status: 'expired', subscription_id: 's' }).can_checkout).toBe(false);
    });
    it('billing off: everyone is legacy_beta with AI on', () => {
        expect(view({ status: 'expired', subscription_id: 's' }, { billing: false, byok: false })).toMatchObject({ status: 'legacy_beta', can_use_ai: true, can_checkout: false });
    });
});

describe('hidden fair-use caps', () => {
    it('are taken from the environment only and accept the operator range up to 100', () => {
        vi.stubEnv('BILLING_MONTHLY_AI_BUDGET_USD', '100');
        vi.stubEnv('BILLING_TRIAL_AI_BUDGET_USD', '5');
        expect(billingBudgets()).toEqual({ p_monthly_cap: 100, p_trial_cap: 5 });
    });
    it('the code carries no default: an unset cap is a configuration error, never a silent value (the repository is public)', () => {
        expect(() => billingBudgets()).toThrow('billing_invalid_budget');
        vi.stubEnv('BILLING_MONTHLY_AI_BUDGET_USD', '30');
        expect(() => billingBudgets()).toThrow('billing_invalid_budget');
        vi.unstubAllEnvs();
        vi.stubEnv('BILLING_TRIAL_AI_BUDGET_USD', '3');
        expect(() => billingBudgets()).toThrow('billing_invalid_budget');
    });
    it.each(['0', '-1', 'abc', '100.01', ''])('rejects %j', value => {
        vi.stubEnv('BILLING_MONTHLY_AI_BUDGET_USD', value);
        vi.stubEnv('BILLING_TRIAL_AI_BUDGET_USD', '3');
        expect(() => billingBudgets()).toThrow('billing_invalid_budget');
    });
    it('the public repository carries no cap value: the example file leaves both empty and no document names a number next to them', () => {
        const read = (file: string) => readFileSync(path.join(process.cwd(), file), 'utf8');
        const env = read('.env.example');
        expect(env).toMatch(/^BILLING_MONTHLY_AI_BUDGET_USD=$/m);
        expect(env).toMatch(/^BILLING_TRIAL_AI_BUDGET_USD=$/m);
        for (const file of ['docs/go-live/billing-launch.md', 'docs/go-live/runbook.md']) {
            const lines = read(file).split('\n').filter(line => /BILLING_(MONTHLY|TRIAL)_AI_BUDGET_USD/.test(line));
            expect(lines.length, file).toBeGreaterThan(0);
            for (const line of lines) expect(line, file).not.toMatch(/(시작|→|=|비움)\s*`?\d/);
        }
    });
    it('the trial cap is validated the same way', () => {
        vi.stubEnv('BILLING_MONTHLY_AI_BUDGET_USD', '30');
        vi.stubEnv('BILLING_TRIAL_AI_BUDGET_USD', '101');
        expect(() => billingBudgets()).toThrow('billing_invalid_budget');
    });
});

it('reports billing_required for every closed state, including a Lifetime without a usable key', async () => {
    const { AiBudgetError } = await import('../ai/budget-error');
    for (const reason of ['billing_required', 'subscription_required', 'byok_required', 'ai_key_missing', 'ai_key_revoked'])
        expect(new AiBudgetError(reason).code).toBe('billing_required');
});

it('tells the user the approved sentence: plan ended (N12), or the key is missing (N13)', async () => {
    const { AiBudgetError } = await import('../ai/budget-error');
    for (const reason of ['billing_required', 'subscription_required'])
        expect(new AiBudgetError(reason).userMessage).toBe('Your plan has ended. Restart Pro in Settings → Account → Plan & usage.');
    for (const reason of ['byok_required', 'ai_key_missing', 'ai_key_revoked'])
        expect(new AiBudgetError(reason).userMessage).toBe('Add your OpenRouter key in Settings → Account → Plan & usage.');
    // the retired screen name never appears again
    for (const reason of ['billing_required', 'byok_required']) expect(new AiBudgetError(reason).userMessage).not.toMatch(/Subscription/);
});
