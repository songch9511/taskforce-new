import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { billingConfig, cancelSubscription, latestInvoice, order, refundInvoice, refundOrder, resumeSubscription, safeProviderUrl, subscription, variantPlan } from './provider';
import { fakeProvider, lsInvoice, lsOrder, lsSubscription, stubBillingEnv } from './testing';
vi.mock('server-only', () => ({}));
beforeEach(() => stubBillingEnv());
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });
describe('configuration', () => {
    it('reads the new variant names and keeps Lifetime and the first-month code optional', () => {
        const config = billingConfig();
        expect(config).toMatchObject({ store: '1', variants: { monthly: '2', annual: '3', lifetime: '4' }, discountCode: 'FIRSTMONTH', test: true });
        vi.stubEnv('LEMONSQUEEZY_LIFETIME_VARIANT_ID', '');
        vi.stubEnv('LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE', '');
        expect(billingConfig()).toMatchObject({ variants: { monthly: '2', annual: '3', lifetime: null }, discountCode: null });
    });
    it.each(['LEMONSQUEEZY_API_KEY', 'LEMONSQUEEZY_WEBHOOK_SECRET', 'LEMONSQUEEZY_STORE_ID', 'LEMONSQUEEZY_PRO_MONTHLY_VARIANT_ID', 'LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID', 'LEMONSQUEEZY_TEST_MODE'])('fails without %s', name => {
        vi.stubEnv(name, '');
        expect(() => billingConfig()).toThrow('billing_not_configured');
    });
    it('rejects malformed ids, codes and modes', () => {
        for (const [name, value] of [['LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID', 'abc'], ['LEMONSQUEEZY_LIFETIME_VARIANT_ID', '4x'], ['LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE', 'bad code!'], ['LEMONSQUEEZY_TEST_MODE', 'yes']]) {
            vi.stubEnv(name, value);
            expect(() => billingConfig(), name).toThrow('billing_not_configured');
            stubBillingEnv();
        }
    });
    it('classifies only its own variants', () => {
        const config = billingConfig();
        expect(['2', 3, '4', '9', 5].map(id => variantPlan(config, id))).toEqual(['monthly', 'annual', 'lifetime', null, null]);
        vi.stubEnv('LEMONSQUEEZY_LIFETIME_VARIANT_ID', '');
        expect(variantPlan(billingConfig(), '4')).toBeNull();
    });
});
describe('provider objects', () => {
    it('parses the documented subscription shape, trial and payment-method link included', async () => {
        fakeProvider({ 'GET subscriptions/123': lsSubscription({ status: 'on_trial', trial_ends_at: '2026-10-22T00:00:00.000000Z' }) });
        const data = await subscription('123');
        expect(data.attributes).toMatchObject({ status: 'on_trial', trial_ends_at: '2026-10-22T00:00:00.000000Z' });
        expect(data.attributes.urls.update_payment_method).toContain('payment-details');
    });
    it('refuses another store, test mode, the Lifetime variant and a path-shaped id', async () => {
        for (const over of [{ store_id: 3 }, { test_mode: false }, { variant_id: 4 }, { variant_id: 12 }]) {
            fakeProvider({ 'GET subscriptions/123': lsSubscription(over) });
            await expect(subscription('123')).rejects.toThrow('billing_subscription_mismatch');
        }
        await expect(subscription('123/../orders')).rejects.toThrow('billing_invalid_subscription');
    });
    it('returns null for a subscription without invoices and the newest otherwise', async () => {
        fakeProvider({ 'GET subscription-invoices?filter': [] });
        expect(await latestInvoice('123')).toBeNull();
        fakeProvider({ 'GET subscription-invoices?filter': [lsInvoice()] });
        expect((await latestInvoice('123'))?.id).toBe('44');
        fakeProvider({ 'GET subscription-invoices?filter': [lsInvoice({ store_id: 9 })] });
        await expect(latestInvoice('123')).rejects.toThrow('billing_invoice_mismatch');
    });
    it('parses an order with its first item variant and refuses another store or mode', async () => {
        fakeProvider({ 'GET orders/900': lsOrder() });
        expect((await order('900')).attributes.first_order_item.variant_id).toBe(4);
        for (const over of [{ store_id: 3 }, { test_mode: false }]) {
            fakeProvider({ 'GET orders/900': lsOrder(over) });
            await expect(order('900')).rejects.toThrow('billing_order_mismatch');
        }
    });
    it('sends the documented request bodies for refund, cancel and resume', async () => {
        const provider = fakeProvider({ 'POST subscription-invoices/44/refund': lsInvoice(), 'POST orders/900/refund': lsOrder(), 'DELETE subscriptions/123': lsSubscription(), 'PATCH subscriptions/123': lsSubscription() });
        await refundInvoice('44');
        await refundOrder('900');
        await cancelSubscription('123');
        await resumeSubscription('123');
        expect(provider.calls).toEqual([
            { method: 'POST', path: 'subscription-invoices/44/refund', body: { data: { type: 'subscription-invoices', id: '44' } } },
            { method: 'POST', path: 'orders/900/refund', body: { data: { type: 'orders', id: '900' } } },
            { method: 'DELETE', path: 'subscriptions/123', body: undefined },
            { method: 'PATCH', path: 'subscriptions/123', body: { data: { type: 'subscriptions', id: '123', attributes: { cancelled: false } } } },
        ]);
    });
    it('never builds a provider path from a non-numeric id', async () => {
        const provider = fakeProvider({});
        for (const call of [() => refundInvoice('44/x'), () => refundOrder('9?x=1'), () => cancelSubscription('../1'), () => resumeSubscription('a'), () => order('1/2')])
            await expect(Promise.resolve().then(call)).rejects.toThrow('billing_invalid_id');
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('only ever opens https lemonsqueezy.com addresses', () => {
        expect(safeProviderUrl('https://taskforce.lemonsqueezy.com/billing?x=1')).toBe('https://taskforce.lemonsqueezy.com/billing?x=1');
        for (const bad of ['http://taskforce.lemonsqueezy.com/x', 'https://lemonsqueezy.com.evil.test/x', 'https://evil.test/lemonsqueezy.com', 'https://u:p@taskforce.lemonsqueezy.com/x', 'javascript:alert(1)'])
            expect(() => safeProviderUrl(bad), bad).toThrow();
    });
});
