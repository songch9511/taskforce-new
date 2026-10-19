// Test doubles for the billing modules: an in-memory Supabase admin client and recorded-shape Lemon Squeezy payloads
// (shapes follow docs.lemonsqueezy.com: the-subscription-object, the-subscription-invoice-object, the-order-object).
// Never imported by production code; never talks to the network, a database or the provider.
import { vi } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

export type Row = Record<string, unknown>;
type RpcResult = { data?: unknown; error?: { message: string } | null };
type Rpc = (args: Record<string, unknown>) => RpcResult | Promise<RpcResult>;

export const USER = '22222222-2222-4222-8222-222222222222';
export const REF = '11111111-1111-4111-8111-111111111111';
export const NOW_ISO = '2026-10-19T00:00:00.000Z';

/** Account row as the database returns it (select *). */
export const accountRow = (over: Row = {}): Row => ({
    user_id: USER, legacy_beta: false, notice_ends_at: null, onboarding_started_at: null, trial_ends_at: null, subscription_id: null, customer_id: null, order_id: null,
    plan: null, status: 'none', current_period_ends_at: null, provider_updated_at: null, deleting_token: null, deleting: false, first_subscription_at: null,
    lifetime_order_id: null, lifetime_status: null, lifetime_paid_at: null, lifetime_updated_at: null, last_payment_at: null, last_invoice_id: null,
    refund_requested_at: null, self_refund_used_at: null, last_swept_at: null, ...over,
});

const compare = (a: unknown, b: unknown) => String(a).localeCompare(String(b));
/**
 * In-memory stand-in for the service-role client. Supports exactly the query shapes the billing code uses:
 * select / eq / is / gt / lt / lte / order / limit / maybeSingle / single, insert / upsert / update, throwOnError, rpc.
 */
export function fakeAdmin(seed: Record<string, Row[]> = {}, rpcs: Record<string, Rpc> = {}) {
    const tables = new Map<string, Row[]>(Object.entries(seed).map(([name, rows]) => [name, rows.map(row => ({ ...row }))]));
    const rpcCalls: [string, Record<string, unknown>][] = [];
    const writes: { table: string; op: string; payload: unknown }[] = [];
    const table = (name: string) => tables.get(name) ?? tables.set(name, []).get(name)!;
    function from(name: string) {
        const filters: ((row: Row) => boolean)[] = [];
        let op: 'select' | 'insert' | 'upsert' | 'update' = 'select';
        let payload: unknown;
        let single = false;
        let ignoreDuplicates = false;
        let limit = Infinity;
        const run = () => {
            const rows = table(name);
            if (op === 'insert' || op === 'upsert') {
                const incoming = payload as Row;
                const key = name === 'billing_accounts' ? 'user_id' : 'id';
                const exists = incoming[key] !== undefined && rows.some(row => row[key] === incoming[key]);
                writes.push({ table: name, op, payload });
                if (exists && op === 'upsert' && ignoreDuplicates) return { data: null, error: null };
                if (exists && op === 'insert') return { data: null, error: { message: 'duplicate key value' } };
                // column defaults of the inbox table
                const defaults = name === 'billing_webhook_inbox' ? { created_at: new Date().toISOString(), next_attempt_at: new Date().toISOString(), processed_at: null } : {};
                if (!exists) rows.push({ ...defaults, ...incoming });
                return { data: null, error: null };
            }
            const matching = rows.filter(row => filters.every(filter => filter(row)));
            if (op === 'update') {
                writes.push({ table: name, op, payload });
                for (const row of matching) Object.assign(row, payload);
                return { data: single ? (matching[0] ?? null) : matching, error: null };
            }
            const picked = matching.slice(0, limit).map(row => ({ ...row }));
            return { data: single ? (picked[0] ?? null) : picked, error: null };
        };
        const builder = {
            select: () => builder,
            eq: (key: string, value: unknown) => { filters.push(row => row[key] === value); return builder; },
            is: (key: string, value: unknown) => { filters.push(row => (row[key] ?? null) === value); return builder; },
            gt: (key: string, value: unknown) => { filters.push(row => row[key] !== null && row[key] !== undefined && compare(row[key], value) > 0); return builder; },
            lt: (key: string, value: unknown) => { filters.push(row => row[key] !== null && row[key] !== undefined && compare(row[key], value) < 0); return builder; },
            lte: (key: string, value: unknown) => { filters.push(row => row[key] !== null && row[key] !== undefined && compare(row[key], value) <= 0); return builder; },
            order: () => builder,
            limit: (count: number) => { limit = count; return builder; },
            maybeSingle: () => { single = true; return builder; },
            single: () => { single = true; return builder; },
            insert: (row: unknown) => { op = 'insert'; payload = row; return builder; },
            upsert: (row: unknown, options?: { ignoreDuplicates?: boolean }) => { op = 'upsert'; payload = row; ignoreDuplicates = !!options?.ignoreDuplicates; return builder; },
            update: (patch: unknown) => { op = 'update'; payload = patch; return builder; },
            throwOnError: () => builder,
            then: (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve().then(run).then(resolve, reject),
        };
        return builder;
    }
    const rpc = (name: string, args: Record<string, unknown> = {}) => {
        rpcCalls.push([name, args]);
        const handler = rpcs[name];
        const settle = Promise.resolve(handler ? handler(args) : { data: null, error: null }).then(result => ({ data: result.data ?? null, error: result.error ?? null }));
        const builder = {
            throwOnError: () => ({ then: (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => settle.then(result => { if (result.error) throw new Error(result.error.message); return result; }).then(resolve, reject) }),
            then: (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => settle.then(resolve, reject),
        };
        return builder;
    };
    return { admin: { from, rpc } as unknown as SupabaseClient, tables, rpcCalls, writes, rpcNamed: (name: string) => rpcCalls.filter(([called]) => called === name).map(([, args]) => args) };
}

/** Provider variants used by every billing test: Pro monthly 2, Pro yearly 3, Lifetime 4. */
export function stubBillingEnv(extra: Record<string, string> = {}) {
    const env: Record<string, string> = {
        BILLING_ENABLED: 'true', BYOK_ENABLED: 'true', LEMONSQUEEZY_API_KEY: 'test', LEMONSQUEEZY_WEBHOOK_SECRET: '0123456789abcdef0123456789abcdef', LEMONSQUEEZY_STORE_ID: '1',
        LEMONSQUEEZY_PRO_MONTHLY_VARIANT_ID: '2', LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID: '3', LEMONSQUEEZY_LIFETIME_VARIANT_ID: '4', LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE: 'FIRSTMONTH',
        LEMONSQUEEZY_TEST_MODE: 'true',
        // Test numbers only: the real caps live in the production environment and nowhere in the repository.
        BILLING_MONTHLY_AI_BUDGET_USD: '25', BILLING_TRIAL_AI_BUDGET_USD: '4', ...extra,
    };
    for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
}

const lsTime = (iso: string) => iso.replace('Z', '000Z'); // the provider prints 6 fractional digits
export const lsSubscription = (over: Row = {}, id = '123') => ({
    type: 'subscriptions', id, attributes: {
        store_id: 1, customer_id: 77, order_id: 5, order_item_id: 6, product_id: 9, variant_id: 2, product_name: 'Taskforce Pro', variant_name: 'Monthly',
        user_name: 'Buyer Name', user_email: 'buyer@example.com', status: 'active', status_formatted: 'Active', card_brand: 'visa', card_last_four: '4242', payment_processor: 'stripe',
        pause: null, cancelled: false, trial_ends_at: null, billing_anchor: 19, first_subscription_item: null,
        urls: { update_payment_method: 'https://taskforce.lemonsqueezy.com/subscription/123/payment-details?signature=a', customer_portal: 'https://taskforce.lemonsqueezy.com/billing?signature=b' },
        renews_at: '2026-11-19T00:00:00.000000Z', ends_at: null, created_at: lsTime(NOW_ISO), updated_at: lsTime(NOW_ISO), test_mode: true, ...over,
    },
});
export const lsInvoice = (over: Row = {}, id = '44') => ({
    type: 'subscription-invoices', id, attributes: {
        store_id: 1, subscription_id: 123, customer_id: 77, user_email: 'buyer@example.com', billing_reason: 'renewal', card_brand: 'visa', card_last_four: '4242', currency: 'USD',
        status: 'paid', status_formatted: 'Paid', refunded: false, refunded_at: null, total: 1299, discount_total: 0, created_at: lsTime(NOW_ISO), updated_at: lsTime(NOW_ISO), test_mode: true, ...over,
    },
});
export const lsOrder = (over: Row = {}, id = '900', variantId = 4) => ({
    type: 'orders', id, attributes: {
        store_id: 1, customer_id: 77, identifier: 'a1b2', order_number: 12, user_name: 'Buyer Name', user_email: 'buyer@example.com', currency: 'USD', total: 22900,
        status: 'paid', status_formatted: 'Paid', refunded: false, refunded_at: null, first_order_item: { id: 1, order_id: Number(id), product_id: 10, variant_id: variantId, price: 22900, test_mode: true },
        urls: { receipt: 'https://taskforce.lemonsqueezy.com/my-orders/a1b2?signature=c' }, created_at: lsTime(NOW_ISO), updated_at: lsTime(NOW_ISO), test_mode: true, ...over,
    },
});

export type Provider = { method: string; path: string; body: unknown };
type Reply = unknown | Response | ((call: Provider) => unknown | Response);
/**
 * Replaces global fetch with a router. Keys are "METHOD path-prefix"; the first matching prefix wins; an unknown route throws
 * so a test can never reach the real provider by accident. Bodies are returned as JSON:API documents.
 */
export function fakeProvider(routes: Record<string, Reply>) {
    const calls: Provider[] = [];
    const fetchMock = vi.fn(async (url: unknown, init?: RequestInit) => {
        const path = String(url).replace('https://api.lemonsqueezy.com/v1/', '');
        const method = init?.method ?? 'GET';
        const call = { method, path, body: init?.body ? JSON.parse(String(init.body)) : undefined };
        calls.push(call);
        const key = Object.keys(routes).find(route => route.startsWith(`${method} `) && path.startsWith(route.slice(method.length + 1)));
        if (!key) throw new Error(`unexpected provider call ${method} ${path}`);
        const reply = routes[key];
        const value = typeof reply === 'function' ? (reply as (call: Provider) => unknown)(call) : reply;
        return value instanceof Response ? value : Response.json({ data: value });
    });
    vi.stubGlobal('fetch', fetchMock);
    return { calls, fetchMock, called: (method: string, prefix: string) => calls.filter(call => call.method === method && call.path.startsWith(prefix)) };
}
