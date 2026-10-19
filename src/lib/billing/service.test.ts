import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { billingStatusV2Schema, billingStatusSchema } from '../api/contract';
import { accountRow, fakeAdmin, fakeProvider, lsInvoice, lsOrder, lsSubscription, REF, stubBillingEnv, USER } from './testing';
import { BILLING_TERMS_VERSION } from './prices';
import { billingStatusV2, billingSummary, cancelBeforeDeletion, checkout, portal, portalV2, requestRefund, requireBillingAccess, resume } from './service';
vi.mock('server-only', () => ({}));
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const iso = (offset: number) => new Date(Date.now() + offset).toISOString();
beforeEach(() => stubBillingEnv());
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

const intentRow = (over: Record<string, unknown> = {}) => ({ id: REF, plan: 'pro', url: null, expires_at: '2026-10-19T01:00:00+00:00', with_trial: true, with_discount: true, ...over });
const claimRpc = (over: Record<string, unknown> = {}) => ({ billing_claim_checkout_v2: () => ({ data: intentRow(over) }), billing_checkout_url_v2: () => ({ data: true }) });
const checkoutReply = { attributes: { url: 'https://taskforce.lemonsqueezy.com/checkout/custom/opaque' } };
type CheckoutData = { attributes: Record<string, unknown> & { product_options: unknown; checkout_options: unknown; checkout_data: unknown; test_mode: boolean; expires_at: string }; relationships: { variant: { data: { id: string } }; store: { data: { id: string } } } };
const checkoutBody = (provider: ReturnType<typeof fakeProvider>) => (provider.called('POST', 'checkouts')[0].body as { data: CheckoutData }).data;

describe('checkout', () => {
    it('opens Pro with both variants, the card trial and the one-time first-month code, and nothing the client could choose', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc());
        const provider = fakeProvider({ 'POST checkouts': checkoutReply });
        const url = await checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION);
        expect(url).toBe('https://taskforce.lemonsqueezy.com/checkout/custom/opaque');
        expect(f.rpcNamed('billing_claim_checkout_v2')).toEqual([{ p_user_id: USER, p_plan: 'pro', p_terms_version: BILLING_TERMS_VERSION }]);
        const data = checkoutBody(provider);
        expect(data.attributes.product_options).toEqual({ enabled_variants: [2, 3] });
        expect(data.relationships.variant.data.id).toBe('2');
        expect(data.relationships.store.data.id).toBe('1');
        expect(data.attributes.checkout_options).toEqual({ skip_trial: false, subscription_preview: true, discount: false });
        expect(data.attributes.checkout_data).toEqual({ custom: { checkout_ref: REF }, discount_code: 'FIRSTMONTH' });
        expect(data.attributes.test_mode).toBe(true);
        expect(data.attributes.expires_at).toBe('2026-10-19T01:00:00+00:00');
        const wire = JSON.stringify(provider.calls[0].body);
        for (const forbidden of ['redirect_url', 'custom_price', 'email', 'billing_address']) expect(wire).not.toContain(forbidden);
        expect(f.rpcNamed('billing_checkout_url_v2')).toEqual([{ p_user_id: USER, p_intent_id: REF, p_url: url }]);
    });
    it('a restart (second Pro checkout) skips the trial and carries no code', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'expired', first_subscription_at: iso(-30 * DAY) })] }, claimRpc({ with_trial: false, with_discount: false }));
        const provider = fakeProvider({ 'POST checkouts': checkoutReply });
        await checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION);
        const data = checkoutBody(provider);
        expect((data.attributes.checkout_options as { skip_trial: boolean }).skip_trial).toBe(true);
        expect(data.attributes.checkout_data).toEqual({ custom: { checkout_ref: REF } });
        expect(JSON.stringify(provider.calls[0].body)).not.toContain('FIRSTMONTH');
    });
    it('Lifetime opens one variant with no trial and no code', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc({ plan: 'lifetime', with_trial: false, with_discount: false }));
        const provider = fakeProvider({ 'POST checkouts': checkoutReply });
        await checkout(f.admin, USER, 'lifetime', BILLING_TERMS_VERSION);
        const data = checkoutBody(provider);
        expect(data.attributes.product_options).toEqual({ enabled_variants: [4] });
        expect(data.relationships.variant.data.id).toBe('4');
        expect(data.attributes.checkout_options).toEqual({ discount: false });
        expect(data.attributes.checkout_data).toEqual({ custom: { checkout_ref: REF } });
    });
    it('returns an already issued checkout without asking the provider again', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc({ url: 'https://taskforce.lemonsqueezy.com/checkout/existing' }));
        const provider = fakeProvider({});
        expect(await checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION)).toBe('https://taskforce.lemonsqueezy.com/checkout/existing');
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('refuses everything while billing is off, with no database or provider call', async () => {
        vi.stubEnv('BILLING_ENABLED', 'false');
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc());
        const provider = fakeProvider({});
        await expect(checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow('billing_disabled');
        expect(f.rpcCalls).toEqual([]);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('sells Lifetime only while BYOK is enabled', async () => {
        vi.stubEnv('BYOK_ENABLED', 'false');
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc());
        const provider = fakeProvider({});
        await expect(checkout(f.admin, USER, 'lifetime', BILLING_TERMS_VERSION)).rejects.toThrow('billing_disabled');
        expect(f.rpcCalls).toEqual([]);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('requires the current terms version before touching anything', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc());
        const provider = fakeProvider({});
        for (const terms of ['2026-10-08', '', 'x']) await expect(checkout(f.admin, USER, 'pro', terms)).rejects.toThrow('billing_terms_required');
        expect(f.rpcCalls).toEqual([]);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('does not start a checkout for an account that cannot buy', async () => {
        const live = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'active', current_period_ends_at: iso(DAY) })] }, claimRpc());
        const provider = fakeProvider({});
        await expect(checkout(live.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow('billing_subscription_exists');
        await expect(checkout(live.admin, USER, 'lifetime', BILLING_TERMS_VERSION)).rejects.toThrow('billing_subscription_exists');
        const owner = fakeAdmin({ billing_accounts: [accountRow({ lifetime_status: 'active', lifetime_order_id: 'o' })] }, claimRpc());
        await expect(checkout(owner.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow('billing_subscription_exists');
        expect([...live.rpcCalls, ...owner.rpcCalls]).toEqual([]);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('fails closed when the first-month code or the Lifetime variant is not configured, before any claim', async () => {
        vi.stubEnv('LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE', '');
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc());
        const provider = fakeProvider({});
        await expect(checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow('billing_not_configured');
        vi.stubEnv('LEMONSQUEEZY_LIFETIME_VARIANT_ID', '');
        await expect(checkout(f.admin, USER, 'lifetime', BILLING_TERMS_VERSION)).rejects.toThrow('billing_not_configured');
        expect(f.rpcCalls).toEqual([]);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('reads only the new variant env names: the retired $9.99 ids are ignored', async () => {
        for (const name of ['LEMONSQUEEZY_PRO_MONTHLY_VARIANT_ID', 'LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID']) vi.stubEnv(name, '');
        vi.stubEnv('LEMONSQUEEZY_MONTHLY_VARIANT_ID', '2');
        vi.stubEnv('LEMONSQUEEZY_ANNUAL_VARIANT_ID', '3');
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, claimRpc());
        await expect(checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow('billing_not_configured');
    });
    it('a concurrent claim stops before the provider request', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow()] }, { billing_claim_checkout_v2: () => ({ error: { message: 'billing_checkout_pending' } }) });
        const provider = fakeProvider({});
        await expect(checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow('billing_checkout_pending');
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('frees the pending claim when the provider fails or answers with a foreign address', async () => {
        for (const reply of [new Response('x', { status: 500 }), { attributes: { url: 'https://evil.example.com/checkout' } }]) {
            const f = fakeAdmin({ billing_accounts: [accountRow()], billing_checkout_intents: [{ id: REF, user_id: USER, url: null, consumed_at: null }] }, claimRpc());
            fakeProvider({ 'POST checkouts': reply });
            await expect(checkout(f.admin, USER, 'pro', BILLING_TERMS_VERSION)).rejects.toThrow();
            expect(f.tables.get('billing_checkout_intents')![0].consumed_at).toEqual(expect.any(String));
            expect(f.rpcNamed('billing_checkout_url_v2')).toEqual([]);
        }
    });
});

describe('portal', () => {
    const owner = () => fakeAdmin({ billing_accounts: [accountRow({ subscription_id: '123', status: 'active' })] });
    it('v2 manage opens the customer portal and leaves a portal event', async () => {
        const f = owner();
        fakeProvider({ 'GET subscriptions/123': lsSubscription() });
        expect(await portalV2(f.admin, USER, 'manage')).toBe('https://taskforce.lemonsqueezy.com/billing?signature=b');
        expect(f.rpcNamed('billing_record_event')).toEqual([{ p_user_id: USER, p_type: 'billing_portal_opened', p_props: { target: 'manage' } }]);
    });
    it('v2 payment opens the update-payment-method link', async () => {
        const f = owner();
        fakeProvider({ 'GET subscriptions/123': lsSubscription() });
        expect(await portalV2(f.admin, USER, 'payment')).toBe('https://taskforce.lemonsqueezy.com/subscription/123/payment-details?signature=a');
        expect(f.rpcNamed('billing_record_event')[0]).toMatchObject({ p_props: { target: 'payment' } });
    });
    it('v2 refuses a missing link, a foreign host, no subscription and a disabled flag', async () => {
        const f = owner();
        fakeProvider({ 'GET subscriptions/123': lsSubscription({ urls: { customer_portal: 'https://taskforce.lemonsqueezy.com/billing?s=1' } }) });
        await expect(portalV2(f.admin, USER, 'payment')).rejects.toThrow('billing_portal_unavailable');
        fakeProvider({ 'GET subscriptions/123': lsSubscription({ urls: { customer_portal: 'https://evil.example.com/billing' } }) });
        await expect(portalV2(f.admin, USER, 'manage')).rejects.toThrow('billing_invalid_url');
        await expect(portalV2(fakeAdmin({ billing_accounts: [accountRow()] }).admin, USER, 'manage')).rejects.toThrow('billing_subscription_missing');
        vi.stubEnv('BILLING_ENABLED', 'false');
        const provider = fakeProvider({});
        await expect(portalV2(f.admin, USER, 'manage')).rejects.toThrow('billing_disabled');
        expect(provider.fetchMock).not.toHaveBeenCalled();
        expect(f.rpcNamed('billing_record_event')).toEqual([]);
    });
    it('v1 keeps opening the portal of any subscription (old app builds)', async () => {
        const f = owner();
        fakeProvider({ 'GET subscriptions/123': lsSubscription() });
        expect(await portal(f.admin, USER)).toBe('https://taskforce.lemonsqueezy.com/billing?signature=b');
    });
});

describe('resume', () => {
    it('asks the provider to un-cancel, queues a re-read and leaves the entitlement to the confirmation', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: '123', status: 'cancelled', current_period_ends_at: iso(5 * DAY) })] });
        const provider = fakeProvider({ 'PATCH subscriptions/123': lsSubscription() });
        expect(await resume(f.admin, USER)).toEqual({ requested: true });
        expect(provider.calls).toEqual([{ method: 'PATCH', path: 'subscriptions/123', body: { data: { type: 'subscriptions', id: '123', attributes: { cancelled: false } } } }]);
        expect(f.writes.filter(w => w.table === 'billing_webhook_inbox')).toHaveLength(1);
        expect(f.tables.get('billing_webhook_inbox')![0].event).toMatchObject({ meta: { event_name: 'taskforce_reconcile' }, data: { id: '123', type: 'subscriptions' } });
        expect(f.writes.some(w => w.table === 'billing_accounts' && w.op === 'update')).toBe(false);
        expect(f.rpcNamed('billing_apply_subscription_v2')).toEqual([]);
    });
    it.each([
        ['active', { subscription_id: '123', status: 'active', current_period_ends_at: iso(DAY) }],
        ['period over', { subscription_id: '123', status: 'cancelled', current_period_ends_at: iso(-DAY) }],
        ['no subscription', {}],
    ])('does nothing for %s', async (_label, over) => {
        const f = fakeAdmin({ billing_accounts: [accountRow(over)] });
        const provider = fakeProvider({});
        await expect(resume(f.admin, USER)).rejects.toThrow('billing_resume_unavailable');
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('is closed while billing is off', async () => {
        vi.stubEnv('BILLING_ENABLED', 'false');
        const provider = fakeProvider({});
        await expect(resume(fakeAdmin().admin, USER)).rejects.toThrow('billing_disabled');
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
});

describe('refund request', () => {
    const KEY = 'refund-requested:22222222-2222-4222-8222-222222222222:1760000000.123456';
    const subscriptionClaim = { kind: 'subscription', subscription_id: '123', invoice_id: '44', plan: 'monthly', claim_key: KEY };
    const rpcs = (claim: unknown = subscriptionClaim) => ({ billing_claim_refund: () => ({ data: claim }) });
    const refundRoutes = (over: Record<string, unknown> = {}) => ({
        'GET subscription-invoices/44': lsInvoice({ created_at: iso(-HOUR) }), 'POST subscription-invoices/44/refund': lsInvoice({ refunded: true }), 'DELETE subscriptions/123': lsSubscription({ status: 'cancelled' }), ...over,
    });
    it('refunds the latest paid invoice, stops renewal, queues a re-read and records the request under the claim key; the plan keeps running until confirmed', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: '123', status: 'active' })] }, rpcs());
        const provider = fakeProvider(refundRoutes());
        expect(await requestRefund(f.admin, USER)).toEqual({ requested: true });
        expect(provider.calls.map(call => `${call.method} ${call.path}`)).toEqual(['GET subscription-invoices/44', 'POST subscription-invoices/44/refund', 'DELETE subscriptions/123']);
        expect(provider.calls[1].body).toEqual({ data: { type: 'subscription-invoices', id: '44' } });
        expect(f.tables.get('billing_webhook_inbox')).toHaveLength(1);
        expect(f.rpcNamed('billing_record_event')).toEqual([{ p_user_id: USER, p_type: 'billing_refund_requested', p_props: { plan: 'monthly' }, p_dedupe_id: KEY }]);
        expect(f.rpcNamed('billing_apply_subscription_v2')).toEqual([]);
        expect(f.rpcNamed('billing_release_refund')).toEqual([]);
        expect(f.writes.some(w => w.table === 'billing_accounts')).toBe(false);
    });
    it('refunds a Lifetime order', async () => {
        const f = fakeAdmin({}, rpcs({ kind: 'lifetime', order_id: '900', claim_key: KEY }));
        const provider = fakeProvider({ 'GET orders/900': lsOrder({ created_at: iso(-HOUR) }), 'POST orders/900/refund': lsOrder({ refunded: true }) });
        await requestRefund(f.admin, USER);
        expect(provider.calls.map(call => `${call.method} ${call.path}`)).toEqual(['GET orders/900', 'POST orders/900/refund']);
        expect(f.rpcNamed('billing_record_event')).toEqual([{ p_user_id: USER, p_type: 'billing_refund_requested', p_props: { plan: 'lifetime' }, p_dedupe_id: KEY }]);
        expect(f.tables.get('billing_webhook_inbox')![0].event).toMatchObject({ data: { id: '900', type: 'orders' } });
    });
    it('uses the provider clock: a payment older than 72 hours or not paid is refused BEFORE the refund call and gives the claim and the use back', async () => {
        for (const invoice of [lsInvoice({ created_at: iso(-73 * HOUR) }), lsInvoice({ status: 'pending', created_at: iso(-HOUR) }), lsInvoice({ status: 'void', created_at: iso(-HOUR) })]) {
            const f = fakeAdmin({}, rpcs());
            const provider = fakeProvider({ 'GET subscription-invoices/44': invoice });
            await expect(requestRefund(f.admin, USER)).rejects.toThrow('billing_refund_window_closed');
            expect(provider.called('POST', '')).toEqual([]);
            expect(f.rpcNamed('billing_release_refund')).toEqual([{ p_user_id: USER, p_clear_used: true }]);
            expect(f.rpcNamed('billing_record_event')).toEqual([]);
        }
        const f = fakeAdmin({}, rpcs({ kind: 'lifetime', order_id: '900', claim_key: KEY }));
        fakeProvider({ 'GET orders/900': lsOrder({ created_at: iso(-80 * HOUR) }) });
        await expect(requestRefund(f.admin, USER)).rejects.toThrow('billing_refund_window_closed');
        expect(f.rpcNamed('billing_release_refund')).toEqual([{ p_user_id: USER, p_clear_used: true }]);
    });
    it('a failed look-up before the refund call also gives everything back: nothing was sent', async () => {
        const f = fakeAdmin({}, rpcs());
        const provider = fakeProvider({ 'GET subscription-invoices/44': new Response('down', { status: 503 }) });
        await expect(requestRefund(f.admin, USER)).rejects.toThrow('billing_provider_unavailable');
        expect(provider.called('POST', '')).toEqual([]);
        expect(f.rpcNamed('billing_release_refund')).toEqual([{ p_user_id: USER, p_clear_used: true }]);
    });
    it('an invoice that is already refunded keeps the claim and the use, sends nothing and asks for a re-read', async () => {
        for (const invoice of [lsInvoice({ refunded: true, created_at: iso(-HOUR) }), lsInvoice({ status: 'refunded', created_at: iso(-HOUR) })]) {
            const f = fakeAdmin({}, rpcs());
            const provider = fakeProvider({ 'GET subscription-invoices/44': invoice });
            await expect(requestRefund(f.admin, USER)).rejects.toThrow('billing_refund_pending');
            expect(provider.called('POST', '')).toEqual([]);
            expect(f.rpcNamed('billing_release_refund')).toEqual([]);
            expect(f.tables.get('billing_webhook_inbox')).toHaveLength(1);
        }
    });
    it.each([
        ['an error answer', () => new Response('no', { status: 422 })],
        ['a server error', () => new Response('boom', { status: 502 })],
        ['a lost connection', () => { throw new Error('socket hang up'); }],
        ['a timeout', () => { throw new DOMException('The operation was aborted due to timeout', 'TimeoutError'); }],
    ])('%s on the refund call is an unknown outcome: the claim AND the use stay, a re-read settles it, nothing is cancelled or recorded', async (_label, reply) => {
        const f = fakeAdmin({}, rpcs());
        const provider = fakeProvider(refundRoutes({ 'POST subscription-invoices/44/refund': reply }));
        await expect(requestRefund(f.admin, USER)).rejects.toThrow();
        expect(f.rpcNamed('billing_release_refund')).toEqual([]);
        expect(provider.called('DELETE', '')).toEqual([]);
        expect(f.rpcNamed('billing_record_event')).toEqual([]);
        expect(f.tables.get('billing_webhook_inbox')).toHaveLength(1);
        expect(f.tables.get('billing_webhook_inbox')![0].event).toMatchObject({ meta: { event_name: 'taskforce_reconcile' }, data: { id: '123', type: 'subscriptions' } });
    });
    it('the same holds for a Lifetime order refund call that fails', async () => {
        const f = fakeAdmin({}, rpcs({ kind: 'lifetime', order_id: '900', claim_key: KEY }));
        fakeProvider({ 'GET orders/900': lsOrder({ created_at: iso(-HOUR) }), 'POST orders/900/refund': new Response('x', { status: 500 }) });
        await expect(requestRefund(f.admin, USER)).rejects.toThrow();
        expect(f.rpcNamed('billing_release_refund')).toEqual([]);
        expect(f.tables.get('billing_webhook_inbox')![0].event).toMatchObject({ data: { id: '900', type: 'orders' } });
    });
    it('keeps the claim once money moved even if the follow-ups fail (the re-read and the confirmation repair them)', async () => {
        const f = fakeAdmin({}, { ...rpcs(), billing_record_event: () => ({ error: { message: 'down' } }) });
        fakeProvider(refundRoutes({ 'DELETE subscriptions/123': new Response('x', { status: 500 }) }));
        const errors = vi.spyOn(console, 'error').mockImplementation(() => undefined);
        expect(await requestRefund(f.admin, USER)).toEqual({ requested: true });
        expect(f.rpcNamed('billing_release_refund')).toEqual([]);
        expect(f.tables.get('billing_webhook_inbox')).toHaveLength(1);
        expect(errors.mock.calls.flat().join(' ')).not.toMatch(/buyer|@|123|44/);
        errors.mockRestore();
    });
    it.each([
        ['billing_refund_used', 'billing_refund_used'], ['billing_refund_pending', 'billing_refund_pending'],
        ['billing_refund_window_closed', 'billing_refund_window_closed'], ['billing_refund_unavailable', 'billing_refund_unavailable'], ['connection reset', 'billing_unavailable'],
    ])('maps the database refusal %s', async (message, expected) => {
        const f = fakeAdmin({}, { billing_claim_refund: () => ({ error: { message } }) });
        const provider = fakeProvider({});
        await expect(requestRefund(f.admin, USER)).rejects.toThrow(expected);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
    it('is closed while billing is off', async () => {
        vi.stubEnv('BILLING_ENABLED', 'false');
        const f = fakeAdmin({}, rpcs());
        await expect(requestRefund(f.admin, USER)).rejects.toThrow('billing_disabled');
        expect(f.rpcCalls).toEqual([]);
    });
});

describe('access gate', () => {
    it('does not read an account while billing is off', async () => {
        vi.stubEnv('BILLING_ENABLED', 'false');
        const from = vi.fn();
        expect(await requireBillingAccess({ from } as unknown as SupabaseClient, USER)).toBeNull();
        expect(from).not.toHaveBeenCalled();
    });
    it('lets paying, trialing, cancelled-inside-period, past_due-inside-grace, Lifetime and beta accounts through', async () => {
        for (const over of [
            { status: 'active', current_period_ends_at: iso(DAY) }, { status: 'on_trial', trial_ends_at: iso(DAY) }, { status: 'cancelled', current_period_ends_at: iso(DAY) },
            { status: 'past_due', current_period_ends_at: iso(-3 * DAY) }, { lifetime_status: 'active' }, { legacy_beta: true },
        ]) expect((await requireBillingAccess(fakeAdmin({ billing_accounts: [accountRow(over)] }).admin, USER))?.ai).toBe(true);
    });
    it('closes new accounts, ended plans and deleting accounts with billing_required', async () => {
        for (const over of [{}, { status: 'expired', subscription_id: 's' }, { status: 'active', current_period_ends_at: iso(-1) }, { status: 'past_due', current_period_ends_at: iso(-17 * DAY) }, { deleting: true, status: 'active', current_period_ends_at: iso(DAY) }])
            await expect(requireBillingAccess(fakeAdmin({ billing_accounts: [accountRow(over)] }).admin, USER), JSON.stringify(over)).rejects.toMatchObject({ code: 'billing_required' });
    });
    it('creates the row of an account it has never seen, so a new signup is not entitled', async () => {
        const f = fakeAdmin();
        await expect(requireBillingAccess(f.admin, USER)).rejects.toMatchObject({ code: 'billing_required' });
        expect(f.tables.get('billing_accounts')).toHaveLength(1);
    });
});

describe('status v2', () => {
    it('answers beta with nothing for sale and no account read while billing is off', async () => {
        vi.stubEnv('BILLING_ENABLED', 'false');
        const from = vi.fn();
        const rpc = vi.fn();
        const status = await billingStatusV2({ from, rpc } as unknown as SupabaseClient, USER);
        expect(status).toMatchObject({ state: 'beta', can_use_ai: true, can_checkout: false, can_buy_lifetime: false, with_trial: false, refund_until: null, ai_usage_this_month: null });
        expect(from).not.toHaveBeenCalled();
        expect(rpc).not.toHaveBeenCalled();
        expect(status.prices).toEqual({ pro_monthly: '$12.99', pro_first_month: '$6.99', pro_yearly: '$119.88', lifetime: '$229' });
    });
    it('shows a new account the sale: trial, first month, Lifetime, and the terms to echo', async () => {
        const status = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow()] }).admin, USER);
        expect(status).toMatchObject({ state: 'none', can_checkout: true, can_buy_lifetime: true, with_trial: true, terms_version: BILLING_TERMS_VERSION, ai_key: null, fair_use_paused_until: null });
        expect(billingStatusV2Schema.parse(status)).toEqual(status);
    });
    it('a Pro reports reference token usage for this UTC month, the refund window and no cap', async () => {
        const paidAt = Date.now() - HOUR;
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'active', plan: 'monthly', current_period_ends_at: iso(20 * DAY), last_invoice_id: 'inv', last_payment_at: new Date(paidAt).toISOString() })] }, {
            billing_usage_tokens: () => ({ data: { prompt_tokens: 1200, completion_tokens: 300 } }),
            billing_spend_summary_v2: () => ({ data: { cap_usd: 10, confirmed_usd: 3, reserved_usd: 0, pending_count: 0, remaining_usd: 7, status: 'available' } }),
        });
        const status = await billingStatusV2(f.admin, USER);
        expect(status).toMatchObject({ state: 'pro', plan: 'monthly', can_checkout: false, can_buy_lifetime: false, fair_use_paused_until: null });
        expect(status.ai_usage_this_month).toMatchObject({ prompt_tokens: 1200, completion_tokens: 300, total_tokens: 1500 });
        expect(status.ai_usage_this_month!.since).toMatch(/^\d{4}-\d{2}-01T00:00:00\.000Z$/);
        expect(Date.parse(status.refund_until!)).toBe(paidAt + 72 * HOUR);
        expect(JSON.stringify(status)).not.toMatch(/cap_usd|remaining_usd|confirmed_usd/);
        expect(f.rpcNamed('billing_spend_summary_v2')).toEqual([{ p_user_id: USER, p_monthly_cap: 25, p_trial_cap: 4 }]);
    });
    it('reports when the hidden fair-use window paused AI, as a date and nothing else', async () => {
        const exhausted = { billing_usage_tokens: () => ({ data: { prompt_tokens: 0, completion_tokens: 0 } }), billing_spend_summary_v2: () => ({ data: { status: 'exhausted', cap_usd: 10, remaining_usd: 0 } }) };
        const pro = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'active', plan: 'annual', current_period_ends_at: iso(20 * DAY), last_payment_at: iso(-DAY) })] }, exhausted).admin, USER);
        const next = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() + 1, 1)).toISOString();
        expect(pro.fair_use_paused_until).toBe(next);
        const trialEnd = iso(2 * DAY);
        const trial = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'on_trial', plan: 'monthly', trial_ends_at: trialEnd })] }, exhausted).admin, USER);
        expect(trial.fair_use_paused_until).toBe(trialEnd);
    });
    it('the pause date follows the cost window that was really used: a trial cancelled before any payment is paused until its trial ends, not until next month', async () => {
        const exhausted = { billing_usage_tokens: () => ({ data: { prompt_tokens: 0, completion_tokens: 0 } }), billing_spend_summary_v2: () => ({ data: { status: 'exhausted', cap_usd: 4, remaining_usd: 0 } }) };
        const trialEnd = iso(2 * DAY);
        const cancelled = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'cancelled', plan: 'monthly', trial_ends_at: trialEnd, current_period_ends_at: trialEnd, last_payment_at: null })] }, exhausted).admin, USER);
        expect(cancelled.state).toBe('cancelled');
        expect(cancelled.fair_use_paused_until).toBe(trialEnd);
        const paidThenCancelled = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'cancelled', plan: 'monthly', trial_ends_at: iso(-20 * DAY), current_period_ends_at: iso(5 * DAY), last_payment_at: iso(-10 * DAY) })] }, exhausted).admin, USER);
        expect(paidThenCancelled.fair_use_paused_until).toBe(new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() + 1, 1)).toISOString());
    });
    it('a failing summary does not hide the plan; a failing usage read does', async () => {
        const account = accountRow({ subscription_id: 's', status: 'active', plan: 'monthly', current_period_ends_at: iso(20 * DAY) });
        const usage = { billing_usage_tokens: () => ({ data: { prompt_tokens: 1, completion_tokens: 1 } }) };
        expect((await billingStatusV2(fakeAdmin({ billing_accounts: [account] }, { ...usage, billing_spend_summary_v2: () => ({ error: { message: 'subscription_required' } }) }).admin, USER)).state).toBe('pro');
        await expect(billingStatusV2(fakeAdmin({ billing_accounts: [account] }, { billing_usage_tokens: () => ({ error: { message: 'down' } }) }).admin, USER)).rejects.toThrow('billing_unavailable');
    });
    it('Lifetime has no managed usage and reports a missing key until the BYOK change stores one', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-80 * HOUR) })] });
        const status = await billingStatusV2(f.admin, USER);
        expect(status).toMatchObject({ state: 'lifetime', plan: 'lifetime', ai_key: 'missing', ai_usage_this_month: null, can_buy_lifetime: false });
        expect(f.rpcCalls).toEqual([]);
    });
    it('a beta account with a scheduled notice can buy; one without sees nothing for sale', async () => {
        const without = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow({ legacy_beta: true })] }).admin, USER);
        expect(without).toMatchObject({ state: 'beta', can_checkout: false, notice_ends_at: null });
        const notice = iso(40 * DAY);
        const noticed = await billingStatusV2(fakeAdmin({ billing_accounts: [accountRow({ legacy_beta: true, notice_ends_at: notice })] }).admin, USER);
        expect(noticed).toMatchObject({ state: 'beta', can_checkout: true, notice_ends_at: notice });
    });
});

describe('status v1', () => {
    it('keeps the frozen shape; the retired plan is never for sale and paid accounts show no allowance', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'active', plan: 'monthly', current_period_ends_at: iso(DAY) })] });
        const result = await billingSummary(f.admin, USER);
        expect(billingStatusSchema.parse(result)).toEqual(result);
        expect(result).toMatchObject({ status: 'active', plan: 'monthly', can_use_ai: true, can_checkout: false, ai_allowance: null, allowance_resets_at: null });
        expect(f.rpcCalls).toEqual([]);
    });
    it('billing off: the grandfathered beta allowance is still reported, no account row is read', async () => {
        vi.stubEnv('BILLING_ENABLED', 'false');
        const allowance = { cap_usd: 10, confirmed_usd: 1, reserved_usd: 0, pending_count: 0, remaining_usd: 9, status: 'available' };
        const f = fakeAdmin({}, { ai_spend_summary: () => ({ data: allowance }) });
        const result = await billingSummary(f.admin, USER);
        expect(result).toMatchObject({ status: 'legacy_beta', can_use_ai: true, can_checkout: false, ai_allowance: allowance });
        expect(f.tables.get('billing_accounts')).toBeUndefined();
    });
    it('a lapsed account is closed and has no allowance', async () => {
        const result = await billingSummary(fakeAdmin({ billing_accounts: [accountRow({ subscription_id: 's', status: 'expired' })] }).admin, USER);
        expect(result).toMatchObject({ status: 'expired', can_use_ai: false, can_checkout: false, ai_allowance: null });
    });
});

describe('account deletion', () => {
    it('rolls back its deletion lock when a checkout is still pending',async()=>{
     const updates:unknown[]=[];const filters:unknown[]=[];
     const from=(table:string)=>{
      const chain={select:()=>chain,eq:(key:string,value:unknown)=>{filters.push([key,value]);return chain;},is:()=>chain,gt:()=>chain,single:()=>chain,maybeSingle:async()=>({data:{subscription_id:null},error:null}),update:(value:unknown)=>{updates.push(value);return chain;},throwOnError:async()=>({data:table==='billing_checkout_intents'?[{id:'pending'}]:{subscription_id:null}})};return chain;
     };
     await expect(cancelBeforeDeletion({from} as unknown as SupabaseClient,'alice')).rejects.toThrow('billing_checkout_pending');
     expect(updates).toEqual([expect.objectContaining({deleting:true,deleting_token:expect.any(String)}),{deleting:false,deleting_token:null}]);
     expect(filters).toContainEqual(['deleting_token',(updates[0] as {deleting_token:string}).deleting_token]);
    });
    it('does not roll back another deletion operation when its atomic claim is busy',async()=>{
     const updates:unknown[]=[];let mutation=false;
     const chain={select:()=>chain,eq:()=>chain,update:(value:unknown)=>{mutation=true;updates.push(value);return chain;},maybeSingle:async()=>({data:mutation?null:{subscription_id:null},error:null})};
     await expect(cancelBeforeDeletion({from:()=>chain} as unknown as SupabaseClient,'alice')).rejects.toThrow('billing_deletion_busy');
     expect(updates).toEqual([expect.objectContaining({deleting:true})]);
    });
});
