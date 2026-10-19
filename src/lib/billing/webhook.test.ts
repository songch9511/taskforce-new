import { createHmac } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import { validSignature, receiveWebhook, replayBillingWebhooks, sweepBillingAccounts } from './webhook';
import { accountRow, fakeAdmin, fakeProvider, lsInvoice, lsOrder, lsSubscription, REF, stubBillingEnv, USER, type Row } from './testing';
vi.mock('server-only', () => ({}));
const secret = '0123456789abcdef0123456789abcdef';
const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const iso = (offset: number) => new Date(Date.now() + offset).toISOString();
beforeEach(() => stubBillingEnv());
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

const sign = (raw: string) => createHmac('sha256', secret).update(raw).digest('hex');
const post = (body: unknown) => {
    const raw = JSON.stringify(body);
    return new Request('https://example.test', { method: 'POST', body: raw, headers: { 'x-signature': sign(raw) } });
};
const meta = (name: string, ref: string | null = REF) => ({ event_name: name, test_mode: true, custom_data: ref ? { checkout_ref: ref } : undefined });
const subscriptionEvent = (name: string, ref: string | null = REF) => ({ meta: meta(name, ref), data: { id: '123', type: 'subscriptions', attributes: { user_email: 'buyer@example.com', card_last_four: '4242' } } });
const invoiceEvent = (name: string) => ({ meta: meta(name), data: { id: '44', type: 'subscription-invoices', attributes: { subscription_id: 123, user_email: 'buyer@example.com' } } });
const orderEvent = (name: string, id = '900') => ({ meta: meta(name), data: { id, type: 'orders', attributes: { user_email: 'buyer@example.com', user_name: 'Buyer Name' } } });

describe('webhook authenticity and bounds', () => {
    it('requires exact raw bytes, correct hex length and shared secret', () => {
        const raw = Buffer.from('{"a":1}');
        const signature = createHmac('sha256', secret).update(raw).digest('hex');
        expect(validSignature(raw, signature, secret)).toBe(true);
        expect(validSignature(Buffer.from('{ "a":1}'), signature, secret)).toBe(false);
        for (const value of [null, '', 'ff', 'g'.repeat(64), 'f'.repeat(64)])
            expect(validSignature(raw, value, secret)).toBe(false);
    });
    it('caps streaming body independently of content-length', async () => {
        const response = await receiveWebhook(new Request('https://example.test', { method: 'POST', body: 'a'.repeat(262145) }), {} as SupabaseClient);
        expect(response.status).toBe(413);
    });
    it('rejects forged signature before JSON or database access', async () => {
        const response = await receiveWebhook(new Request('https://example.test', { method: 'POST', body: 'not json' }), {} as SupabaseClient);
        expect(response.status).toBe(401);
    });
    it('rejects signed wrong-mode deliveries', async () => {
        const raw = JSON.stringify({ meta: { event_name: 'subscription_created', test_mode: false }, data: { id: '12', type: 'subscriptions', attributes: {} } });
        const response = await receiveWebhook(new Request('https://example.test', { method: 'POST', body: raw, headers: { 'x-signature': sign(raw) } }), {} as SupabaseClient);
        expect(response.status).toBe(400);
    });
    it.each(['customer_updated', 'license_key_created', 'license_key_updated', 'affiliate_activated', 'subscription_made_up', 'order_updated', 'taskforce_reconcile', 'taskforce_sweep'])('acknowledges and drops %s without any database or provider access', async name => {
        const provider = fakeProvider({});
        const f = fakeAdmin();
        const response = await receiveWebhook(post({ meta: meta(name), data: { id: '1', type: 'customers', attributes: {} } }), f.admin);
        expect(response.status).toBe(200);
        expect(f.writes).toEqual([]);
        expect(f.rpcCalls).toEqual([]);
        expect(provider.fetchMock).not.toHaveBeenCalled();
    });
});

/** A subscription world: account row + intent, provider routes that follow a cancel. */
function world(opts: { account?: Row | null; subscription?: Row; invoice?: Row | null; order?: Row; rpcs?: Record<string, (args: Record<string, unknown>) => { data?: unknown; error?: { message: string } | null }>; intents?: Row[]; deleteFails?: boolean } = {}) {
    let cancelled = false;
    const f = fakeAdmin({
        billing_accounts: opts.account === null ? [] : [accountRow({ subscription_id: '123', status: 'active', ...opts.account })],
        billing_checkout_intents: opts.intents ?? [{ id: REF, user_id: USER }],
    }, { billing_apply_subscription_v2: () => ({ data: 'applied' }), billing_record_event: () => ({ data: true }), ...opts.rpcs });
    const provider = fakeProvider({
        'GET subscriptions/123': () => lsSubscription({ ...opts.subscription, ...(cancelled ? { status: 'cancelled', ends_at: iso(5 * DAY) } : {}) }),
        'DELETE subscriptions/123': () => { if (opts.deleteFails) return new Response('down', { status: 500 }); cancelled = true; return lsSubscription({ status: 'cancelled', ends_at: iso(5 * DAY) }); },
        'GET subscription-invoices?filter': () => (opts.invoice === null ? [] : [opts.invoice ?? lsInvoice()]),
        'GET orders/5': () => lsOrder({ ...opts.order }, '5', 2),
    });
    return { ...f, provider, applied: () => f.rpcNamed('billing_apply_subscription_v2') };
}

describe('subscription reconciliation reads the provider and applies one database call', () => {
    it('tells the database whether the paid invoice carried a discount (the first-month code is checked there, against the intent)', async () => {
        for (const [invoice, expected] of [[lsInvoice({ discount_total: 500 }), true], [lsInvoice({ discount_total: 0 }), false], [lsInvoice({ status: 'refunded', refunded: true, discount_total: 500 }), false], [lsInvoice({ status: 'pending', discount_total: 500 }), false]] as const) {
            const w = world({ invoice });
            await receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin);
            expect(w.applied()[0]).toMatchObject({ p_discounted: expected });
        }
    });
    it('an invoice without the discount field counts as undiscounted', async () => {
        const invoice = lsInvoice();
        delete (invoice.attributes as Row).discount_total;
        const w = world({ invoice });
        await receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_discounted: false });
    });
    it('a purchase the database rejects (trial, discount or intent not offered) is cancelled at the provider, confirmed, and sent to review; the database wrote the review event', async () => {
        const w = world({ account: { subscription_id: null, status: 'none' }, subscription: { status: 'on_trial', trial_ends_at: iso(3 * DAY) }, rpcs: { billing_apply_subscription_v2: () => ({ data: 'rejected' }) } });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).rejects.toThrow('billing_purchase_rejected_review');
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(w.rpcNamed('billing_record_event')).toEqual([]);
        expect(w.tables.get('billing_webhook_inbox')![0].processed_at).toBeNull();
    });
    it('a rejected purchase whose cancel failed is cancelled again on the retry and then acknowledged', async () => {
        const first = world({ account: { subscription_id: null, status: 'none' }, subscription: { status: 'on_trial', trial_ends_at: iso(3 * DAY) }, rpcs: { billing_apply_subscription_v2: () => ({ data: 'rejected' }) }, deleteFails: true });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), first.admin)).rejects.toThrow();
        const retry = world({ account: { subscription_id: null, status: 'none' }, subscription: { status: 'on_trial', trial_ends_at: iso(3 * DAY) }, rpcs: { billing_apply_subscription_v2: () => ({ data: 'rejected_known' }) } });
        expect((await receiveWebhook(post(subscriptionEvent('subscription_created')), retry.admin)).status).toBe(200);
        expect(retry.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
    });
    it('a later delivery of a rejected subscription is acknowledged and never cancels what is already over', async () => {
        const live = world({ account: { subscription_id: null, status: 'none' }, rpcs: { billing_apply_subscription_v2: () => ({ data: 'rejected_known' }) } });
        expect((await receiveWebhook(post(subscriptionEvent('subscription_updated')), live.admin)).status).toBe(200);
        expect(live.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        const over = world({ account: { subscription_id: null, status: 'none' }, subscription: { status: 'expired', ends_at: iso(-DAY) }, rpcs: { billing_apply_subscription_v2: () => ({ data: 'rejected_known' }) } });
        expect((await receiveWebhook(post(subscriptionEvent('subscription_expired')), over.admin)).status).toBe(200);
        expect(over.provider.called('DELETE', '')).toEqual([]);
    });
    it('a database answer that is not one of the four known outcomes is a failed reconciliation', async () => {
        for (const data of [null, 'maybe']) {
            const w = world({ rpcs: { billing_apply_subscription_v2: () => ({ data }) } });
            await expect(receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin)).rejects.toThrow('billing_reconciliation_failed');
        }
    });
    it('a free trial is judged from the subscription alone: no invoice is read, nothing is paid-through', async () => {
        const w = world({ account: { subscription_id: null, status: 'none' }, subscription: { status: 'on_trial', trial_ends_at: iso(3 * DAY) } });
        expect((await receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).status).toBe(200);
        expect(w.provider.called('GET', 'subscription-invoices')).toEqual([]);
        expect(w.applied()).toEqual([expect.objectContaining({ p_user_id: USER, p_intent_id: REF, p_subscription_id: '123', p_customer_id: '77', p_status: 'on_trial', p_ends_at: null, p_payment_at: null, p_invoice_id: null, p_order_id: '5', p_variant_plan: 'monthly', p_trial_ends_at: expect.any(String) })]);
    });
    it('grants only a confirmed paid period: renews_at of the active subscription, with the invoice time as the payment time', async () => {
        const w = world();
        await receiveWebhook(post(invoiceEvent('subscription_payment_success')), w.admin);
        expect(w.provider.calls[0]).toMatchObject({ method: 'GET', path: 'subscriptions/123' });
        expect(w.applied()).toEqual([expect.objectContaining({ p_status: 'active', p_ends_at: '2026-11-19T00:00:00.000000Z', p_payment_at: expect.stringContaining('2026-10-19'), p_invoice_id: '44' })]);
    });
    it('the yearly variant is plan annual', async () => {
        const w = world({ subscription: { variant_id: 3 } });
        await receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_variant_plan: 'annual' });
    });
    it.each(['pending', 'void'])('does not grant a %s invoice even when the subscription says active', async status => {
        const w = world({ invoice: lsInvoice({ status }) });
        await receiveWebhook(post(invoiceEvent('subscription_payment_success')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'payment_pending', p_ends_at: null, p_payment_at: null });
    });
    it('a refunded invoice ends the plan and also stops the provider subscription from billing again', async () => {
        const w = world({ invoice: lsInvoice({ status: 'refunded', refunded: true }) });
        await receiveWebhook(post(invoiceEvent('subscription_payment_refunded')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'refunded', p_ends_at: null, p_payment_at: null });
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
    });
    it('a refunded plan whose subscription is already cancelled is not cancelled again', async () => {
        const w = world({ subscription: { status: 'cancelled', ends_at: iso(DAY) }, invoice: lsInvoice({ status: 'refunded', refunded: true }) });
        await receiveWebhook(post(invoiceEvent('subscription_payment_refunded')), w.admin);
        expect(w.provider.called('DELETE', '')).toEqual([]);
    });
    it('a refunded initial order ends the plan even when the invoice still looks paid', async () => {
        const w = world({ invoice: lsInvoice({ billing_reason: 'initial' }), order: { refunded: true, status: 'refunded' } });
        await receiveWebhook(post(invoiceEvent('subscription_payment_success')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'refunded' });
    });
    it('an old refund event reconciles the newest paid invoice instead of revoking', async () => {
        const w = world();
        await receiveWebhook(post(invoiceEvent('subscription_payment_refunded')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'active' });
        expect(w.provider.called('DELETE', '')).toEqual([]);
    });
    it('a cancelled plan runs to ends_at, a past_due plan never gets a provider retry date as time', async () => {
        const cancelled = world({ subscription: { status: 'cancelled', ends_at: '2026-11-08T00:00:00.000000Z' } });
        await receiveWebhook(post(subscriptionEvent('subscription_cancelled')), cancelled.admin);
        expect(cancelled.applied()[0]).toMatchObject({ p_status: 'cancelled', p_ends_at: '2026-11-08T00:00:00.000000Z' });
        const late = world({ subscription: { status: 'past_due', renews_at: iso(30 * DAY) } });
        await receiveWebhook(post(subscriptionEvent('subscription_payment_failed')), late.admin);
        expect(late.applied()[0]).toMatchObject({ p_status: 'past_due', p_ends_at: null });
        const pending = world({ subscription: { status: 'past_due' }, invoice: lsInvoice({ status: 'pending' }) });
        await receiveWebhook(post(subscriptionEvent('subscription_payment_failed')), pending.admin);
        expect(pending.applied()[0]).toMatchObject({ p_status: 'past_due', p_ends_at: null });
    });
    it.each(['expired', 'unpaid', 'paused'])('passes %s through with no time', async status => {
        const w = world({ subscription: { status, ends_at: status === 'expired' ? iso(-DAY) : null } });
        await receiveWebhook(post(subscriptionEvent(status === 'paused' ? 'subscription_paused' : 'subscription_expired')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: status, p_ends_at: null });
    });
    it.each(['subscription_resumed', 'subscription_unpaused'])('%s re-reads the subscription like every other event', async name => {
        const w = world();
        await receiveWebhook(post(subscriptionEvent(name)), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'active' });
    });
    it('a cancellation inside the trial keeps no more than the trial that was granted', async () => {
        const trialEnd = iso(2 * DAY);
        const w = world({ account: { status: 'on_trial', trial_ends_at: trialEnd }, subscription: { status: 'cancelled', ends_at: iso(30 * DAY) }, invoice: null });
        await receiveWebhook(post(subscriptionEvent('subscription_cancelled')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'cancelled', p_ends_at: new Date(Date.parse(trialEnd)).toISOString(), p_payment_at: null });
    });
    it('a cancelled subscription we never saw in its trial grants nothing', async () => {
        const w = world({ subscription: { status: 'cancelled', ends_at: iso(2 * DAY) }, invoice: null });
        await receiveWebhook(post(subscriptionEvent('subscription_cancelled')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'cancelled', p_ends_at: null });
    });
    it('an active subscription without any invoice is never trusted', async () => {
        const w = world({ invoice: null });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin)).rejects.toThrow('billing_payment_unconfirmed');
        expect(w.applied()).toEqual([]);
    });
    it('rejects a variant or store that is not ours before anything is applied', async () => {
        for (const over of [{ variant_id: 99 }, { store_id: 2 }, { test_mode: false }, { variant_id: 4 }]) {
            const w = world({ subscription: over });
            await expect(receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin)).rejects.toThrow('billing_subscription_mismatch');
            expect(w.applied()).toEqual([]);
        }
    });
    it('rejects an invoice of another subscription', async () => {
        const w = world({ invoice: lsInvoice({ subscription_id: 999 }) });
        await expect(receiveWebhook(post(invoiceEvent('subscription_payment_success')), w.admin)).rejects.toThrow('billing_invoice_mismatch');
    });
    it('a database refusal is a failed reconciliation (retried), never a silent success', async () => {
        const w = world({ rpcs: { billing_apply_subscription_v2: () => ({ error: { message: 'billing_duplicate_subscription' } }) } });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin)).rejects.toThrow('billing_reconciliation_failed');
        expect(w.tables.get('billing_webhook_inbox')![0].processed_at).toBeNull();
    });
    it('an unknown subscription without a checkout reference cannot be bound to anyone', async () => {
        const w = world({ account: null });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created', null)), w.admin)).rejects.toThrow('billing_unknown_subscription');
        expect(w.applied()).toEqual([]);
    });
    it('a later event of a known subscription is bound by the account, not by the payload', async () => {
        const w = world();
        await receiveWebhook(post(subscriptionEvent('subscription_updated', null)), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_user_id: USER, p_intent_id: null });
    });
    it('an already bound subscription ignores the reference it arrives with (contract ch.23): the stored account decides, and the intent is not even read', async () => {
        const other = '33333333-3333-4333-8333-333333333333';
        const w = world({ intents: [{ id: REF, user_id: other }] });
        await receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin);
        expect(w.applied()).toEqual([expect.objectContaining({ p_user_id: USER, p_intent_id: null })]);
        const pseudonymous = world({ intents: [{ id: REF, user_id: null }] });
        await receiveWebhook(post(subscriptionEvent('subscription_updated')), pseudonymous.admin);
        expect(pseudonymous.provider.called('DELETE', '')).toEqual([]); // a bound customer is never cancelled because of a reference
        expect(pseudonymous.applied()).toHaveLength(1);
    });
    it('another account\'s intent cannot move a subscription: the intent decides the account, the database rejects the mismatch', async () => {
        const other = '33333333-3333-4333-8333-333333333333';
        const w = world({ account: { user_id: other, subscription_id: null, status: 'none' }, intents: [{ id: REF, user_id: USER }], rpcs: { billing_apply_subscription_v2: () => ({ error: { message: 'billing_intent_missing' } }) } });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).rejects.toThrow('billing_reconciliation_failed');
    });
    it('cancels a purchase whose account was deleted, once confirmed, and acknowledges it', async () => {
        const w = world({ account: null, intents: [{ id: REF, user_id: null }] });
        expect((await receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).status).toBe(200);
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(w.applied()).toEqual([]);
    });
    it('cancels a live subscription of an account that is being deleted', async () => {
        const w = world({ account: { deleting: true } });
        await receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin);
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(w.applied()[0]).toMatchObject({ p_status: 'cancelled' });
    });
});

describe('overlaps and duplicates', () => {
    const second = { subscription_id: 'other-sub', status: 'active', current_period_ends_at: iso(10 * DAY) };
    it('a second live subscription is cancelled at the provider, flagged for review and never applied', async () => {
        const w = world({ account: second });
        // the account's own subscription is "other-sub": event 123 is the duplicate
        w.tables.get('billing_accounts')![0].subscription_id = 'other-sub';
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).rejects.toThrow('billing_duplicate_purchase_cancelled_review_refund');
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(w.applied()).toEqual([]);
        expect(w.rpcNamed('billing_record_event')).toEqual([expect.objectContaining({ p_user_id: USER, p_type: 'billing_duplicate_purchase', p_props: { plan: 'monthly' }, p_dedupe_id: 'duplicate:123' })]);
    });
    it('the duplicate is recorded BEFORE the cancel: a cancel that fails still leaves the review event, and the retry counts it once', async () => {
        const w = world({ account: second, deleteFails: true });
        w.tables.get('billing_accounts')![0].subscription_id = 'other-sub';
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).rejects.toThrow();
        expect(w.rpcNamed('billing_record_event')).toEqual([expect.objectContaining({ p_type: 'billing_duplicate_purchase', p_dedupe_id: 'duplicate:123' })]);
    });
    it('a late event of an already cancelled duplicate is acknowledged without touching anything', async () => {
        const w = world({ account: second, subscription: { status: 'expired', ends_at: iso(-DAY) } });
        w.tables.get('billing_accounts')![0].subscription_id = 'other-sub';
        expect((await receiveWebhook(post(subscriptionEvent('subscription_expired')), w.admin)).status).toBe(200);
        expect(w.provider.called('DELETE', '')).toEqual([]);
        expect(w.applied()).toEqual([]);
        expect(w.rpcNamed('billing_record_event')).toEqual([]);
    });
    it('a replacement is applied once the previous subscription has ended', async () => {
        const w = world({ account: { subscription_id: 'old-sub', status: 'expired' } });
        await receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin);
        expect(w.applied()).toHaveLength(1);
    });
    const lifetimeNeighbour = { subscription_id: null, status: 'none', lifetime_status: 'active', lifetime_order_id: '900' };
    it('Lifetime wins over a Pro that arrives next to it: the Pro is cancelled at the provider, not refunded, and only then recorded as a system cancel', async () => {
        let cancelsSeenByTheRecord = -1;
        const w = world({ account: lifetimeNeighbour, subscription: { status: 'on_trial', trial_ends_at: iso(DAY) }, rpcs: { billing_record_event: () => { cancelsSeenByTheRecord = w.provider.called('DELETE', 'subscriptions/123').length; return { data: true }; } } });
        expect((await receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).status).toBe(200);
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(w.provider.called('POST', '')).toEqual([]);
        expect(w.applied()).toEqual([]);
        expect(w.rpcNamed('billing_record_event')).toEqual([expect.objectContaining({ p_type: 'billing_subscription_cancelled', p_props: { by: 'system' }, p_dedupe_id: 'overlap:123' })]);
        expect(cancelsSeenByTheRecord).toBe(1); // the cancel was confirmed before the event was written
    });
    it('a cancel that fails is not counted as a cancel: no event, a durable marker, and the delivery stays unprocessed for the retry', async () => {
        const w = world({ account: lifetimeNeighbour, subscription: { status: 'on_trial', trial_ends_at: iso(DAY) }, deleteFails: true });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).rejects.toThrow();
        expect(w.rpcNamed('billing_record_event')).toEqual([]);
        expect(w.tables.get('billing_webhook_events')).toEqual([expect.objectContaining({ id: 'syscancel:123', user_id: USER })]);
        expect(w.tables.get('billing_webhook_inbox')![0].processed_at).toBeNull();
    });
    it('the cancel went through but writing the event failed: the retry sees a terminal subscription with our marker and writes the event (once, by its key)', async () => {
        let failRecord = true;
        const written: unknown[] = [];
        const w = world({ account: lifetimeNeighbour, subscription: { status: 'on_trial', trial_ends_at: iso(DAY) }, rpcs: { billing_record_event: args => { if (failRecord) return { error: { message: 'down' } }; written.push(args); return { data: true }; } } });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_created')), w.admin)).rejects.toThrow();
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(written).toEqual([]);
        failRecord = false;
        expect(await replayBillingWebhooks(w.admin)).toEqual({ processed: 1, failed: 0 });
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1); // not cancelled twice
        expect(written).toEqual([expect.objectContaining({ p_type: 'billing_subscription_cancelled', p_props: { by: 'system' }, p_dedupe_id: 'overlap:123' })]);
        expect(w.applied()).toEqual([]); // the cancelled Pro is not recorded onto the Lifetime account
    });
    it('a Pro the customer cancelled themselves is not claimed as a system cancel: terminal without our marker records nothing', async () => {
        const ended = world({ account: lifetimeNeighbour, subscription: { status: 'cancelled', ends_at: iso(DAY) } });
        await receiveWebhook(post(subscriptionEvent('subscription_cancelled')), ended.admin);
        expect(ended.provider.called('DELETE', '')).toEqual([]);
        expect(ended.rpcNamed('billing_record_event')).toEqual([]);
    });
    it('an already ended Pro next to Lifetime is simply recorded', async () => {
        const w = world({ account: { lifetime_status: 'active', lifetime_order_id: '900', status: 'cancelled' }, subscription: { status: 'cancelled', ends_at: iso(DAY) } });
        await receiveWebhook(post(subscriptionEvent('subscription_cancelled')), w.admin);
        expect(w.provider.called('DELETE', '')).toEqual([]);
        expect(w.applied()).toHaveLength(1);
    });
});

describe('lifetime orders', () => {
    const lifetimeWorld = (opts: { order?: Row; account?: Row | null; rpcs?: Record<string, (args: Record<string, unknown>) => { data?: unknown; error?: { message: string } | null }>; intents?: Row[]; variant?: number; deleteFails?: boolean } = {}) => {
        let cancelled = false;
        const f = fakeAdmin({
            billing_accounts: opts.account === null ? [] : [accountRow({ ...opts.account })],
            billing_checkout_intents: opts.intents ?? [{ id: REF, user_id: USER }],
        }, { billing_apply_lifetime: () => ({ data: 'applied' }), billing_record_event: () => ({ data: true }), ...opts.rpcs });
        const provider = fakeProvider({
            'GET orders/900': () => lsOrder({ ...opts.order }, '900', opts.variant ?? 4),
            'GET subscriptions/123': () => lsSubscription(cancelled ? { status: 'cancelled', ends_at: iso(DAY) } : {}),
            'DELETE subscriptions/123': () => { if (opts.deleteFails) return new Response('down', { status: 500 }); cancelled = true; return lsSubscription({ status: 'cancelled' }); },
        });
        return { ...f, provider, applied: () => f.rpcNamed('billing_apply_lifetime') };
    };
    it('a paid Lifetime order opens the entitlement for the account bound by the checkout reference', async () => {
        const w = lifetimeWorld();
        expect((await receiveWebhook(post(orderEvent('order_created')), w.admin)).status).toBe(200);
        expect(w.applied()).toEqual([{ p_user_id: USER, p_event_id: expect.any(String), p_intent_id: REF, p_order_id: '900', p_customer_id: '77', p_status: 'active', p_paid_at: '2026-10-19T00:00:00.000000Z', p_updated_at: '2026-10-19T00:00:00.000000Z' }]);
        expect(w.provider.called('DELETE', '')).toEqual([]);
    });
    it('opening Lifetime cancels a live Pro of the same account, once, without a refund', async () => {
        const w = lifetimeWorld({ account: { subscription_id: '123', status: 'active', current_period_ends_at: iso(10 * DAY) } });
        await receiveWebhook(post(orderEvent('order_created')), w.admin);
        expect(w.provider.called('DELETE', 'subscriptions/123')).toHaveLength(1);
        expect(w.provider.called('POST', '')).toEqual([]);
        expect(w.rpcNamed('billing_record_event')).toEqual([expect.objectContaining({ p_type: 'billing_subscription_cancelled', p_props: { by: 'system' } })]);
    });
    it('opening Lifetime next to a Pro the customer has just ended themselves does not claim that cancel as the system\'s', async () => {
        const w = lifetimeWorld({ account: { subscription_id: '123', status: 'active', current_period_ends_at: iso(10 * DAY) } });
        fakeProvider({
            'GET orders/900': () => lsOrder({}, '900', 4),
            'GET subscriptions/123': () => lsSubscription({ status: 'cancelled', ends_at: iso(DAY) }),
        });
        await receiveWebhook(post(orderEvent('order_created')), w.admin);
        expect(w.rpcNamed('billing_record_event')).toEqual([]);
    });
    it('does not open anything for an unpaid order, and asks for another delivery', async () => {
        for (const status of ['pending', 'failed', 'void']) {
            const w = lifetimeWorld({ order: { status } });
            await expect(receiveWebhook(post(orderEvent('order_created')), w.admin)).rejects.toThrow('billing_payment_unconfirmed');
            expect(w.applied()).toEqual([]);
        }
    });
    it('a refunded order of the owner ends the entitlement', async () => {
        const owner = lifetimeWorld({ account: { lifetime_status: 'active', lifetime_order_id: '900' }, order: { refunded: true, status: 'refunded' } });
        await receiveWebhook(post(orderEvent('order_refunded')), owner.admin);
        expect(owner.applied()).toEqual([expect.objectContaining({ p_status: 'refunded', p_order_id: '900', p_user_id: USER })]);
    });
    it('a refunded order we never granted and cannot tie to an intent changes nothing', async () => {
        const stranger = lifetimeWorld({ order: { refunded: true, status: 'refunded' } });
        const event = orderEvent('order_refunded');
        event.meta.custom_data = undefined;
        expect((await receiveWebhook(post(event), stranger.admin)).status).toBe(200);
        expect(stranger.applied()).toEqual([]);
    });
    it('a refund that arrives before the paid order is bound through the checkout intent and stored as the final state', async () => {
        const w = lifetimeWorld({ order: { refunded: true, status: 'refunded' } });
        expect((await receiveWebhook(post(orderEvent('order_refunded')), w.admin)).status).toBe(200);
        expect(w.applied()).toEqual([expect.objectContaining({ p_status: 'refunded', p_order_id: '900', p_user_id: USER, p_intent_id: REF })]);
        expect(w.provider.called('DELETE', '')).toEqual([]);
    });
    it('a refund-first order of a deleted account is not bound to anybody', async () => {
        const w = lifetimeWorld({ order: { refunded: true, status: 'refunded' }, intents: [{ id: REF, user_id: null }] });
        await expect(receiveWebhook(post(orderEvent('order_refunded')), w.admin)).rejects.toThrow('billing_orphan_lifetime_order');
        expect(w.applied()).toEqual([]);
    });
    it('a paid snapshot the database calls stale opens nothing and cancels no Pro', async () => {
        const w = lifetimeWorld({ account: { subscription_id: '123', status: 'active', current_period_ends_at: iso(10 * DAY) }, rpcs: { billing_apply_lifetime: () => ({ data: 'stale' }) } });
        expect((await receiveWebhook(post(orderEvent('order_created')), w.admin)).status).toBe(200);
        expect(w.provider.called('DELETE', '')).toEqual([]);
        expect(w.rpcNamed('billing_record_event')).toEqual([]);
    });
    it('a fraudulent order is recorded as fraudulent', async () => {
        const w = lifetimeWorld({ account: { lifetime_status: 'active', lifetime_order_id: '900' }, order: { status: 'fraudulent' } });
        await receiveWebhook(post(orderEvent('order_refunded')), w.admin);
        expect(w.applied()[0]).toMatchObject({ p_status: 'fraudulent' });
    });
    it('a second paid order is flagged by the database and sent to review without changing the entitlement', async () => {
        const w = lifetimeWorld({ rpcs: { billing_apply_lifetime: () => ({ data: 'duplicate' }) } });
        await expect(receiveWebhook(post(orderEvent('order_created')), w.admin)).rejects.toThrow('billing_duplicate_purchase_review_refund');
        expect(w.provider.called('DELETE', '')).toEqual([]);
    });
    it('a paid order of a deleted account, or with no reference at all, is surfaced for a human', async () => {
        const orphan = lifetimeWorld({ intents: [{ id: REF, user_id: null }] });
        await expect(receiveWebhook(post(orderEvent('order_created')), orphan.admin)).rejects.toThrow('billing_orphan_lifetime_order');
        const nameless = lifetimeWorld();
        const event = orderEvent('order_created');
        event.meta.custom_data = undefined;
        await expect(receiveWebhook(post(event), nameless.admin)).rejects.toThrow('billing_unknown_order');
        expect(orphan.applied()).toEqual([]);
        expect(nameless.applied()).toEqual([]);
    });
    it('a Pro order is left to the subscription events; something else in the store is ignored', async () => {
        for (const variant of [2, 3, 77]) {
            const w = lifetimeWorld({ variant });
            expect((await receiveWebhook(post(orderEvent('order_created')), w.admin)).status).toBe(200);
            expect(w.rpcCalls).toEqual([]);
            expect(w.provider.called('GET', 'subscriptions')).toEqual([]);
        }
    });
    it('a refunded Pro order goes back through the account\'s subscription', async () => {
        const w = world({ account: { order_id: '900' }, invoice: lsInvoice({ status: 'refunded', refunded: true }) });
        w.provider.calls.length = 0;
        fakeProvider({
            'GET orders/900': () => lsOrder({ refunded: true, status: 'refunded' }, '900', 2),
            'GET subscriptions/123': () => lsSubscription({ status: 'cancelled', ends_at: iso(DAY) }),
            'GET subscription-invoices?filter': () => [lsInvoice({ status: 'refunded', refunded: true })],
        });
        expect((await receiveWebhook(post(orderEvent('order_refunded')), w.admin)).status).toBe(200);
        expect(w.applied()[0]).toMatchObject({ p_status: 'refunded' });
        const lost = world({ account: { order_id: 'other' } });
        fakeProvider({ 'GET orders/900': () => lsOrder({}, '900', 2) });
        await expect(receiveWebhook(post(orderEvent('order_refunded')), lost.admin)).rejects.toThrow('billing_order_not_reconciled');
    });
    it('rejects an order of another store or mode', async () => {
        for (const order of [{ store_id: 2 }, { test_mode: false }]) {
            const w = lifetimeWorld({ order });
            await expect(receiveWebhook(post(orderEvent('order_created')), w.admin)).rejects.toThrow('billing_order_mismatch');
            expect(w.applied()).toEqual([]);
        }
    });
    it('a database refusal is a failed reconciliation', async () => {
        const w = lifetimeWorld({ rpcs: { billing_apply_lifetime: () => ({ error: { message: 'billing_intent_missing' } }) } });
        await expect(receiveWebhook(post(orderEvent('order_created')), w.admin)).rejects.toThrow('billing_reconciliation_failed');
    });
});

describe('durability and privacy', () => {
    it('retains sanitized routing metadata only and retries after a provider outage', async () => {
        const w = world();
        w.provider.fetchMock.mockResolvedValueOnce(new Response(null, { status: 503 }));
        await expect(receiveWebhook(post(invoiceEvent('subscription_payment_success')), w.admin)).rejects.toThrow('billing_provider_unavailable');
        const inbox = w.tables.get('billing_webhook_inbox')!;
        expect(inbox).toHaveLength(1);
        expect(inbox[0].processed_at).toBeNull();
        expect(JSON.stringify(inbox[0].event)).not.toMatch(/email|card|user_name|buyer/);
        expect(await replayBillingWebhooks(w.admin)).toEqual({ processed: 1, failed: 0 });
        expect(inbox[0].processed_at).toEqual(expect.any(String));
        expect(w.applied()).toHaveLength(1);
    });
    it('a failing replay is pushed back an hour, not dropped', async () => {
        const w = world({ invoice: null });
        await expect(receiveWebhook(post(subscriptionEvent('subscription_updated')), w.admin)).rejects.toThrow();
        const before = Date.parse(w.tables.get('billing_webhook_inbox')![0].next_attempt_at as string);
        w.tables.get('billing_webhook_inbox')![0].next_attempt_at = iso(-1000);
        expect(await replayBillingWebhooks(w.admin)).toEqual({ processed: 0, failed: 1 });
        expect(Date.parse(w.tables.get('billing_webhook_inbox')![0].next_attempt_at as string)).toBeGreaterThan(before + 3_000_000);
    });
    it('never logs a payload, id, address or card detail while processing', async () => {
        const spies = (['log', 'info', 'warn', 'error', 'debug'] as const).map(level => vi.spyOn(console, level).mockImplementation(() => undefined));
        const w = world();
        fakeProvider({
            'GET subscriptions/123': () => lsSubscription(), 'GET subscription-invoices?filter': () => [lsInvoice()], 'GET orders/900': () => lsOrder(),
        });
        await receiveWebhook(post(invoiceEvent('subscription_payment_success')), w.admin);
        await receiveWebhook(post(orderEvent('order_created')), fakeAdmin({ billing_accounts: [accountRow()], billing_checkout_intents: [{ id: REF, user_id: USER }] }, { billing_apply_lifetime: () => ({ data: 'applied' }) }).admin);
        expect(spies.flatMap(spy => spy.mock.calls)).toEqual([]);
    });
});

describe('queued re-reads and the daily sweep', () => {
    it('a queued re-read of a subscription is processed with no checkout reference', async () => {
        const w = world();
        const queued = { meta: { event_name: 'taskforce_reconcile', test_mode: true }, data: { id: '123', type: 'subscriptions', attributes: {} } };
        w.tables.set('billing_webhook_inbox', [{ id: 'reconcile-subscriptions-123-x', event: queued, created_at: iso(-1000), next_attempt_at: iso(-1000), processed_at: null }]);
        expect(await replayBillingWebhooks(w.admin)).toEqual({ processed: 1, failed: 0 });
        expect(w.applied()[0]).toMatchObject({ p_user_id: USER, p_intent_id: null, p_event_id: 'reconcile-subscriptions-123-x' });
    });
    it('a queued re-read of an order re-checks the Lifetime order', async () => {
        const f = fakeAdmin({ billing_accounts: [accountRow({ lifetime_status: 'active', lifetime_order_id: '900' })] }, { billing_apply_lifetime: () => ({ data: 'applied' }) });
        fakeProvider({ 'GET orders/900': () => lsOrder({ refunded: true, status: 'refunded' }) });
        f.tables.set('billing_webhook_inbox', [{ id: 'r1', event: { meta: { event_name: 'taskforce_reconcile', test_mode: true }, data: { id: '900', type: 'orders', attributes: {} } }, created_at: iso(-1000), next_attempt_at: iso(-1000), processed_at: null }]);
        await replayBillingWebhooks(f.admin);
        expect(f.rpcNamed('billing_apply_lifetime')[0]).toMatchObject({ p_status: 'refunded' });
    });
    it('sweeps the claimed accounts, one provider read each, and returns refund claims that never resolved', async () => {
        const claim = [
            { user_id: USER, subscription_id: '123', lifetime_order_id: null, refund_stale: false },
            { user_id: '44444444-4444-4444-8444-444444444444', subscription_id: null, lifetime_order_id: '900', refund_stale: true },
        ];
        const f = fakeAdmin({ billing_accounts: [accountRow(), accountRow({ user_id: claim[1].user_id, lifetime_status: 'active', lifetime_order_id: '900' })], billing_checkout_intents: [] }, { billing_sweep_claim: () => ({ data: claim }), billing_apply_subscription_v2: () => ({ data: 'applied' }), billing_apply_lifetime: () => ({ data: 'applied' }) });
        f.tables.get('billing_accounts')![0].subscription_id = '123';
        fakeProvider({
            'GET subscriptions/123': () => lsSubscription(),
            'GET subscription-invoices?filter': () => [lsInvoice()],
            'GET orders/900': () => lsOrder(),
        });
        expect(await sweepBillingAccounts(f.admin, { limit: 7 })).toEqual({ swept: 2, failed: 0 });
        expect(f.rpcNamed('billing_sweep_claim')).toEqual([{ p_limit: 7 }]);
        expect(f.rpcNamed('billing_apply_subscription_v2')).toHaveLength(1);
        expect(f.rpcNamed('billing_apply_lifetime')).toHaveLength(1);
        expect(f.rpcNamed('billing_release_refund')).toEqual([{ p_user_id: claim[1].user_id, p_clear_used: false }]);
        expect(f.rpcNamed('billing_sweep_done')).toEqual([{ p_user_id: USER, p_ok: true }, { p_user_id: claim[1].user_id, p_ok: true }]);
    });
    it('stops at its deadline and leaves the rest of the claimed batch for the next day', async () => {
        const claim = [{ user_id: USER, subscription_id: '123', lifetime_order_id: null, refund_stale: false }];
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: '123' })] }, { billing_sweep_claim: () => ({ data: claim }) });
        const provider = fakeProvider({});
        expect(await sweepBillingAccounts(f.admin, { deadline: Date.now() - 1 })).toEqual({ swept: 0, failed: 0 });
        expect(provider.fetchMock).not.toHaveBeenCalled();
        // an account the sweep did not get to is not marked done: the claim lease runs out and it is a candidate again
        expect(f.rpcNamed('billing_sweep_done')).toEqual([]);
    });
    it('one account failing does not stop the others and is counted', async () => {
        const claim = [
            { user_id: USER, subscription_id: '123', lifetime_order_id: null, refund_stale: false },
            { user_id: '44444444-4444-4444-8444-444444444444', subscription_id: '124', lifetime_order_id: null, refund_stale: false },
        ];
        const f = fakeAdmin({ billing_accounts: [accountRow({ subscription_id: '123' }), accountRow({ user_id: claim[1].user_id, subscription_id: '124' })] }, { billing_sweep_claim: () => ({ data: claim }), billing_apply_subscription_v2: () => ({ data: 'applied' }) });
        fakeProvider({
            'GET subscriptions/123': new Response('down', { status: 503 }),
            'GET subscriptions/124': () => lsSubscription({}, '124'),
            'GET subscription-invoices?filter': () => [lsInvoice({ subscription_id: 124 })],
        });
        expect(await sweepBillingAccounts(f.admin)).toEqual({ swept: 1, failed: 1 });
        // a failed account backs off (the database pushes its lease an hour out), a good one is stamped done
        expect(f.rpcNamed('billing_sweep_done')).toEqual([{ p_user_id: USER, p_ok: false }, { p_user_id: claim[1].user_id, p_ok: true }]);
    });
});
