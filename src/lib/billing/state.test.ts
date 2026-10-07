import { describe, it, expect } from 'vitest';
import { billingState, type BillingAccount } from './state';
const now = Date.parse('2026-10-08T00:00:00Z');
const past = '2026-09-01T00:00:00Z';
const future = '2026-11-01T00:00:00Z';
const base: BillingAccount = { user_id: 'alice', legacy_beta: false, notice_ends_at: null, onboarding_started_at: past, trial_ends_at: null, subscription_id: null, customer_id: null, plan: null, status: 'none', current_period_ends_at: null, deleting: false };
describe('billing entitlement', () => {
    it('bounds onboarding and requires future trial or paid period', () => {
        expect(billingState(base, now).can_use_ai).toBe(false);
        expect(billingState({ ...base, onboarding_started_at: new Date(now).toISOString() }, now).can_use_ai).toBe(true);
        expect(billingState({ ...base, trial_ends_at: future }, now).can_use_ai).toBe(true);
        expect(billingState({ ...base, trial_ends_at: past }, now).can_use_ai).toBe(false);
    });
    it.each(['active', 'cancelled'])('%s grants only through paid-through', status => {
        expect(billingState({ ...base, status, current_period_ends_at: future }, now).can_use_ai).toBe(true);
        expect(billingState({ ...base, status, current_period_ends_at: past }, now).can_use_ai).toBe(false);
    });
    it.each(['past_due', 'unpaid', 'paused', 'expired', 'refunded', 'on_trial'])('%s never uses retry dates as paid entitlement', status => {
        expect(billingState({ ...base, status, current_period_ends_at: future }, now).can_use_ai).toBe(false);
    });
    it('preserves legacy free consent/notice and disables deleting accounts', () => {
        expect(billingState({ ...base, legacy_beta: true }, now).can_use_ai).toBe(true);
        expect(billingState({ ...base, legacy_beta: true, notice_ends_at: past }, now).can_use_ai).toBe(false);
        expect(billingState({ ...base, legacy_beta: true, deleting: true }, now).can_use_ai).toBe(false);
    });
});

it('reading billing before connecting does not consume the onboarding window', () => {
    expect(billingState({ ...base, onboarding_started_at: null }, now)).toMatchObject({ status: 'trial_pending', can_use_ai: true });
});

it('uses a dedicated actionable error for expired billing access',async()=>{
 const {AiBudgetError}=await import('../ai/budget-error');
 expect(new AiBudgetError('subscription_required').code).toBe('billing_required');
 expect(new AiBudgetError('billing_required').userMessage).toContain('Account → Subscription');
});
