import type { SupabaseClient } from '@supabase/supabase-js';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { billingErrorV2Schema, billingStatusV2Schema } from '@/lib/api/contract';

// The money routes, called the way the app calls them: real authenticateRequest (cookie CSRF included), real body
// validation and error mapping; only the service layer and the database client are replaced.
const mocks = vi.hoisted(() => ({
    createCookieClient: vi.fn(), bearerClient: vi.fn(), admin: vi.fn(),
    checkout: vi.fn(), portalV2: vi.fn(), portal: vi.fn(), resume: vi.fn(), requestRefund: vi.fn(), billingStatusV2: vi.fn(), billingSummary: vi.fn(),
    replay: vi.fn(), sweep: vi.fn(),
}));
vi.mock('server-only', () => ({}));
vi.mock('@/lib/supabase/server', () => ({ createClient: mocks.createCookieClient }));
vi.mock('@/lib/supabase/admin', () => ({ createAdminClient: mocks.admin }));
vi.mock('@supabase/supabase-js', async importOriginal => ({ ...(await importOriginal<typeof import('@supabase/supabase-js')>()), createClient: mocks.bearerClient }));
vi.mock('@/lib/billing/service', () => ({
    checkout: mocks.checkout, portalV2: mocks.portalV2, portal: mocks.portal, resume: mocks.resume, requestRefund: mocks.requestRefund, billingStatusV2: mocks.billingStatusV2, billingSummary: mocks.billingSummary,
}));
vi.mock('@/lib/billing/webhook', () => ({ replayBillingWebhooks: mocks.replay, sweepBillingAccounts: mocks.sweep }));

import { GET as getStatus } from '@/app/api/v2/billing/route';
import { POST as postCheckout } from '@/app/api/v2/billing/checkout/route';
import { POST as postPortal } from '@/app/api/v2/billing/portal/route';
import { POST as postResume } from '@/app/api/v2/billing/resume/route';
import { POST as postRefund } from '@/app/api/v2/billing/refund/route';
import { GET as getV1Status } from '@/app/api/v1/billing/route';
import { POST as postV1Checkout } from '@/app/api/v1/billing/checkout/route';
import { POST as postV1Portal } from '@/app/api/v1/billing/portal/route';
import { GET as cron } from '@/app/api/cron/billing/route';
import * as webhookRoute from '@/app/api/webhooks/lemonsqueezy/route';

const USER = '11111111-0000-4000-8000-000000000001';
const SAME = { 'sec-fetch-site': 'same-origin' };
const ADMIN = { admin: true };
let getClaims: ReturnType<typeof vi.fn>;
const req = (method: string, body?: unknown, headers: Record<string, string> = {}) =>
    new Request('https://api.example.test/api/v2/billing', { method, headers: { 'content-type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
const json = async (response: Response) => response.json();

beforeEach(() => {
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_URL', 'https://project.example.test');
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'sb_publishable_local-test');
    vi.stubEnv('CRON_SECRET', 'cron-secret-value');
    getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: 'me@example.test', user_metadata: {} } }, error: null });
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
    mocks.bearerClient.mockReturnValue({ auth: { getClaims } });
    mocks.admin.mockReturnValue(ADMIN);
    mocks.checkout.mockResolvedValue('https://taskforce.lemonsqueezy.com/checkout/x');
    mocks.portalV2.mockResolvedValue('https://taskforce.lemonsqueezy.com/billing?x=1');
    mocks.portal.mockResolvedValue('https://taskforce.lemonsqueezy.com/billing?x=1');
    mocks.resume.mockResolvedValue({ requested: true });
    mocks.requestRefund.mockResolvedValue({ requested: true });
    mocks.billingSummary.mockResolvedValue({ status: 'legacy_beta' });
    mocks.replay.mockResolvedValue({ processed: 2, failed: 0 });
    mocks.sweep.mockResolvedValue({ swept: 3, failed: 0 });
});
afterEach(() => { vi.clearAllMocks(); vi.unstubAllEnvs(); });

const SERVICES = () => [mocks.checkout, mocks.portalV2, mocks.portal, mocks.resume, mocks.requestRefund, mocks.billingStatusV2, mocks.billingSummary];
type Case = [string, (request: Request) => Promise<Response>, string, unknown];
const V2_POSTS: Case[] = [
    ['POST checkout', r => postCheckout(r), 'checkout', { plan: 'pro', terms_version: '2026-10-19' }],
    ['POST portal', r => postPortal(r), 'portalV2', { target: 'manage' }],
    ['POST resume', r => postResume(r), 'resume', {}],
    ['POST refund', r => postRefund(r), 'requestRefund', {}],
];

describe.each(V2_POSTS)('v2 %s: authentication', (_name, call, service, body) => {
    it('rejects an unauthenticated request before any service or database client', async () => {
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error('no session') }) } } as unknown as SupabaseClient);
        const response = await call(req('POST', body, SAME));
        expect(response.status).toBe(401);
        for (const fn of SERVICES()) expect(fn).not.toHaveBeenCalled();
        expect(mocks.admin).not.toHaveBeenCalled();
    });
    it('treats a cross-site cookie write as logged out', async () => {
        const crossSite: Record<string, string>[] = [{ 'sec-fetch-site': 'cross-site' }, { 'sec-fetch-site': 'same-site' }, { origin: 'https://evil.example' }];
        for (const headers of crossSite) {
            expect((await call(req('POST', body, headers))).status, JSON.stringify(headers)).toBe(401);
        }
        for (const fn of SERVICES()) expect(fn).not.toHaveBeenCalled();
    });
    it('acts for the verified user only, from a cookie or a bearer token, and answers no-store', async () => {
        const cookie = await call(req('POST', body, SAME));
        expect(cookie.status).toBe(200);
        expect(cookie.headers.get('cache-control')).toBe('no-store');
        const bearer = await call(req('POST', body, { authorization: 'Bearer token-123' }));
        expect(bearer.status).toBe(200);
        const fn = (mocks as Record<string, ReturnType<typeof vi.fn>>)[service];
        expect(fn).toHaveBeenCalledTimes(2);
        for (const args of fn.mock.calls) {
            expect(args[0]).toBe(ADMIN);
            expect(args[1]).toBe(USER);
        }
    });
});

describe('v2 status', () => {
    it('answers for the verified user with no-store, cookie or bearer, and never needs CSRF for a read', async () => {
        mocks.billingStatusV2.mockResolvedValue({ state: 'beta' });
        expect((await getStatus(req('GET', undefined, { 'sec-fetch-site': 'cross-site' }))).status).toBe(200);
        const response = await getStatus(req('GET', undefined, { authorization: 'Bearer t' }));
        expect(response.headers.get('cache-control')).toBe('no-store');
        expect(await json(response)).toEqual({ state: 'beta' });
        expect(mocks.billingStatusV2).toHaveBeenCalledWith(ADMIN, USER);
    });
    it('is 401 without a session and 503 without detail when the service fails', async () => {
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error('x') }) } } as unknown as SupabaseClient);
        expect((await getStatus(req('GET'))).status).toBe(401);
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
        mocks.billingStatusV2.mockRejectedValue(new Error('secret@example.com sk-or-v1-abcdef'));
        const failed = await getStatus(req('GET'));
        expect(failed.status).toBe(503);
        expect(JSON.stringify(await json(failed))).not.toMatch(/secret|sk-or/);
    });
    it('returns the whole v2 status object unchanged from the service', async () => {
        const status = { state: 'none', plan: null, trial_ends_at: null, current_period_ends_at: null, cancel_at: null, notice_ends_at: null, refund_until: null, refund_state: 'idle', can_use_ai: false, can_checkout: true, can_buy_lifetime: true, with_trial: true, terms_version: '2026-10-19', prices: { pro_monthly: '$12.99', pro_first_month: '$6.99', pro_yearly: '$119.88', lifetime: '$229' }, ai_usage_this_month: null, fair_use_paused_until: null, ai_key: null, ai_key_spend_error_at: null };
        mocks.billingStatusV2.mockResolvedValue(billingStatusV2Schema.parse(status));
        expect(await json(await getStatus(req('GET')))).toEqual(status);
    });
});

describe('v2 checkout', () => {
    it('passes the plan and the terms version and returns the provider URL', async () => {
        const response = await postCheckout(req('POST', { plan: 'lifetime', terms_version: '2026-10-19' }, SAME));
        expect(await json(response)).toEqual({ url: 'https://taskforce.lemonsqueezy.com/checkout/x' });
        expect(mocks.checkout).toHaveBeenCalledWith(ADMIN, USER, 'lifetime', '2026-10-19');
    });
    it.each([
        ['no plan', { terms_version: '2026-10-19' }], ['the retired monthly plan', { plan: 'monthly', terms_version: '2026-10-19' }], ['no terms', { plan: 'pro' }],
        ['empty terms', { plan: 'pro', terms_version: '' }], ['long terms', { plan: 'pro', terms_version: 'x'.repeat(33) }],
        ['a client price', { plan: 'pro', terms_version: '2026-10-19', price: 1 }], ['a client user id', { plan: 'pro', terms_version: '2026-10-19', user_id: 'someone' }],
        ['a client redirect', { plan: 'pro', terms_version: '2026-10-19', redirect_url: 'https://evil.example' }], ['a client variant', { plan: 'pro', terms_version: '2026-10-19', variant_id: 5 }],
    ])('rejects %s with 400 and never reaches the service', async (_label, body) => {
        const response = await postCheckout(req('POST', body, SAME));
        expect(response.status).toBe(400);
        expect(mocks.checkout).not.toHaveBeenCalled();
    });
    it('rejects a body that is not JSON', async () => {
        const response = await postCheckout(new Request('https://api.example.test/api/v2/billing/checkout', { method: 'POST', headers: SAME, body: 'plan=pro' }));
        expect(response.status).toBe(400);
        expect(mocks.checkout).not.toHaveBeenCalled();
    });
});

describe('v2 portal, resume, refund bodies', () => {
    it('portal takes only a known target', async () => {
        expect((await postPortal(req('POST', { target: 'payment' }, SAME))).status).toBe(200);
        expect(mocks.portalV2).toHaveBeenCalledWith(ADMIN, USER, 'payment');
        for (const body of [{}, { target: 'cancel' }, { target: 'manage', url: 'https://x' }]) expect((await postPortal(req('POST', body, SAME))).status).toBe(400);
        expect(mocks.portalV2).toHaveBeenCalledTimes(1);
        expect(await json(await postPortal(req('POST', { target: 'manage' }, SAME)))).toEqual({ url: 'https://taskforce.lemonsqueezy.com/billing?x=1' });
    });
    it('resume and refund take no body at all and answer {requested:true}', async () => {
        for (const call of [postResume, postRefund]) {
            expect(await json(await call(req('POST', undefined, SAME)))).toEqual({ requested: true });
            expect((await call(req('POST', { order_id: '1' }, SAME))).status).toBe(400);
            expect((await call(req('POST', { amount: 1 }, SAME))).status).toBe(400);
        }
        expect(mocks.resume).toHaveBeenCalledTimes(1);
        expect(mocks.requestRefund).toHaveBeenCalledTimes(1);
    });
});

describe('v2 error mapping', () => {
    const REFUSALS = ['billing_disabled', 'billing_subscription_exists', 'billing_checkout_pending', 'billing_not_configured', 'billing_subscription_missing', 'billing_portal_unavailable', 'billing_resume_unavailable', 'billing_refund_unavailable'];
    it.each(REFUSALS)('%s is a 409 billing_unavailable', async message => {
        mocks.checkout.mockRejectedValue(new Error(message));
        const response = await postCheckout(req('POST', { plan: 'pro', terms_version: '2026-10-19' }, SAME));
        expect(response.status).toBe(409);
        const body = billingErrorV2Schema.parse(await json(response));
        expect(body.error.code).toBe('billing_unavailable');
        expect(response.headers.get('cache-control')).toBe('no-store');
    });
    it.each([['billing_terms_required'], ['billing_refund_window_closed'], ['billing_refund_used'], ['billing_refund_pending']])('%s keeps its own code (409)', async message => {
        mocks.requestRefund.mockRejectedValue(new Error(message));
        const response = await postRefund(req('POST', undefined, SAME));
        expect(response.status).toBe(409);
        expect(billingErrorV2Schema.parse(await json(response)).error.code).toBe(message);
    });
    it.each(['billing_provider_unavailable', 'billing_unavailable', 'connection reset by peer', 'ECONNREFUSED 10.0.0.1'])('an outage (%s) is a 503 with a fixed message that carries none of the failure text', async message => {
        mocks.portalV2.mockRejectedValue(new Error(message));
        const response = await postPortal(req('POST', { target: 'manage' }, SAME));
        expect(response.status).toBe(503);
        const body = billingErrorV2Schema.parse(await json(response));
        expect(body.error).toEqual({ code: 'billing_unavailable', message: 'Billing is temporarily unavailable.' });
    });
    it('a thrown non-Error is also a plain 503', async () => {
        mocks.resume.mockRejectedValue('boom');
        expect((await postResume(req('POST', undefined, SAME))).status).toBe(503);
    });
});

describe('v1 routes (frozen shape, old app builds)', () => {
    it('status is the service result, no-store; a failure is a 503 without detail', async () => {
        const ok = await getV1Status(req('GET'));
        expect(await json(ok)).toEqual({ status: 'legacy_beta' });
        expect(ok.headers.get('cache-control')).toBe('no-store');
        mocks.billingSummary.mockRejectedValue(new Error('detail'));
        const failed = await getV1Status(req('GET'));
        expect(failed.status).toBe(503);
        expect(JSON.stringify(await json(failed))).not.toContain('detail');
    });
    it('checkout is closed for good: 409 billing_unavailable for every request, nothing created, no body read, no database client', async () => {
        for (const body of [{ plan: 'monthly', terms_version: '2026-10-08' }, { plan: 'annual', terms_version: '2026-10-08' }, { plan: 'lifetime', terms_version: '2026-10-19' }, {}, 'junk']) {
            const response = await postV1Checkout(req('POST', body, SAME));
            expect(response.status).toBe(409);
            expect((await json(response)).error.code).toBe('billing_unavailable');
        }
        expect(mocks.checkout).not.toHaveBeenCalled();
        expect(mocks.admin).not.toHaveBeenCalled();
    });
    it('checkout still requires a session', async () => {
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error('x') }) } } as unknown as SupabaseClient);
        expect((await postV1Checkout(req('POST', { plan: 'monthly', terms_version: '2026-10-08' }, SAME))).status).toBe(401);
    });
    it('portal keeps opening the subscription portal', async () => {
        const response = await postV1Portal(req('POST', undefined, SAME));
        expect(await json(response)).toEqual({ url: 'https://taskforce.lemonsqueezy.com/billing?x=1' });
        mocks.portal.mockRejectedValue(new Error('x'));
        expect((await postV1Portal(req('POST', undefined, SAME))).status).toBe(503);
    });
});

describe('billing cron', () => {
    const call = (secret?: string) => cron(new Request('https://api.example.test/api/cron/billing', { headers: secret ? { authorization: `Bearer ${secret}` } : {} }));
    it('is closed without the cron secret', async () => {
        expect((await call()).status).toBe(401);
        expect((await call('wrong-secret-value')).status).toBe(401);
        expect(mocks.replay).not.toHaveBeenCalled();
        expect(mocks.sweep).not.toHaveBeenCalled();
    });
    it('purges, replays the inbox and sweeps in one run', async () => {
        const rpc = vi.fn(() => ({ throwOnError: async () => ({}) }));
        mocks.admin.mockReturnValue({ rpc });
        const response = await call('cron-secret-value');
        expect(response.status).toBe(200);
        expect(await json(response)).toEqual({ processed: 2, failed: 0, swept: 3, sweep_failed: 0 });
        expect(rpc).toHaveBeenCalledWith('purge_billing_checkout_intents');
        // the sweep shares the run's time budget instead of getting its own
        expect(mocks.sweep).toHaveBeenCalledWith(expect.anything(), { deadline: expect.any(Number) });
        expect(mocks.sweep.mock.calls[0][1].deadline - Date.now()).toBeLessThanOrEqual(270_000);
    });
    it('reports 503 when a replay or a sweep step failed, and never leaks the reason when the run itself fails', async () => {
        mocks.admin.mockReturnValue({ rpc: () => ({ throwOnError: async () => ({}) }) });
        mocks.replay.mockResolvedValue({ processed: 1, failed: 1 });
        expect((await call('cron-secret-value')).status).toBe(503);
        mocks.replay.mockResolvedValue({ processed: 1, failed: 0 });
        mocks.sweep.mockResolvedValue({ swept: 0, failed: 2 });
        expect((await call('cron-secret-value')).status).toBe(503);
        mocks.sweep.mockRejectedValue(new Error('secret detail'));
        const failed = await call('cron-secret-value');
        expect(failed.status).toBe(503);
        expect(JSON.stringify(await json(failed))).not.toContain('secret detail');
    });
});

describe('webhook route runtime', () => {
    it('is given a minute: the re-read of the provider objects and the database call must not be cut off by the platform default', () => {
        expect(webhookRoute.runtime).toBe('nodejs');
        expect(webhookRoute.maxDuration).toBe(60);
    });
});
