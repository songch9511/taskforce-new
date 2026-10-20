import { randomBytes } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { billingErrorV2Schema, billingOpenRouterKeyResponseV2Schema } from '@/lib/api/contract';
import { openUserKey, userKeyEncryptionKey } from '@/lib/ai/user-key';
import { accountRow, fakeAdmin, stubBillingEnv } from '@/lib/billing/testing';

// The key routes, called the way the app calls them: real authenticateRequest (cookie CSRF included), real body validation, real service
// layer and key module; only the database client, the auth client and the outbound network are doubles. Keys here are made-up shapes.
const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), bearerClient: vi.fn(), admin: vi.fn() }));
vi.mock('server-only', () => ({}));
vi.mock('@/lib/supabase/server', () => ({ createClient: mocks.createCookieClient }));
vi.mock('@/lib/supabase/admin', () => ({ createAdminClient: mocks.admin }));
vi.mock('@supabase/supabase-js', async importOriginal => ({ ...(await importOriginal<typeof import('@supabase/supabase-js')>()), createClient: mocks.bearerClient }));

import { DELETE, PUT } from './route';
import { GET as getStatus } from '../route';

const USER = '11111111-0000-4000-8000-000000000001';
const OTHER = '11111111-0000-4000-8000-000000000002';
const KEY = 'sk-or-v1-routeroutertestroutertestroutertestroutertestroutertestrouter';
const ENV_KEY = randomBytes(32).toString('base64');
const SAME = { 'sec-fetch-site': 'same-origin' };
const lifetime = () => accountRow({ user_id: USER, lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: new Date().toISOString() });
const req = (method: string, body?: unknown, headers: Record<string, string> = {}) =>
    new Request('https://api.example.test/api/v2/billing/openrouter-key', { method, headers: { 'content-type': 'application/json', ...headers }, body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body) });
let getClaims: ReturnType<typeof vi.fn>;
let network: ReturnType<typeof vi.fn>;

function world(over: { accounts?: Record<string, unknown>[]; keys?: Record<string, unknown>[]; rpcs?: Parameters<typeof fakeAdmin>[1]; verify?: () => Response | Promise<Response> } = {}) {
    const f = fakeAdmin({ billing_accounts: over.accounts ?? [lifetime()], user_ai_keys: over.keys ?? [] }, { take_rate_limit: () => ({ data: null }), ai_key_put: () => ({ data: false }), ai_key_delete: () => ({ data: true }), ...over.rpcs });
    mocks.admin.mockReturnValue(f.admin);
    network.mockImplementation(async () => (over.verify ? over.verify() : Response.json({ data: { label: 'sk-or-v1-abc...xyz', is_management_key: false } })));
    return f;
}
const consoleSpies = () => (['log', 'info', 'warn', 'error', 'debug'] as const).map(level => vi.spyOn(console, level).mockImplementation(() => undefined));

beforeEach(() => {
    stubBillingEnv();
    vi.stubEnv('USER_AI_KEY_ENCRYPTION_KEY', ENV_KEY);
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_URL', 'https://project.example.test');
    vi.stubEnv('NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY', 'sb_publishable_local-test');
    getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: 'me@example.test', user_metadata: {} } }, error: null });
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
    mocks.bearerClient.mockReturnValue({ auth: { getClaims } });
    network = vi.fn();
    vi.stubGlobal('fetch', network);
});
afterEach(() => { vi.clearAllMocks(); vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe('PUT /api/v2/billing/openrouter-key: gate and authentication', () => {
    it('with BYOK_ENABLED off PUT is a 404 before authentication, the database or the network', async () => {
        const f = world();
        vi.stubEnv('BYOK_ENABLED', 'false');
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(404);
        expect(JSON.stringify(await response.json())).not.toContain(KEY);
        expect(getClaims).not.toHaveBeenCalled();
        expect(mocks.admin).not.toHaveBeenCalled();
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcCalls).toEqual([]);
    });

    it('DELETE does not depend on BYOK_ENABLED: a stored key can always be removed (privacy), after authentication', async () => {
        const f = world({ keys: [{ user_id: USER, sealed_key: 'k1.x.y.z', status: 'connected' }] });
        vi.stubEnv('BYOK_ENABLED', 'false');
        const response = await DELETE(req('DELETE', undefined, SAME));
        expect(response.status).toBe(204);
        expect(await response.text()).toBe('');
        expect(getClaims).toHaveBeenCalled();
        expect(f.rpcNamed('ai_key_delete')).toEqual([{ p_user_id: USER }]);
        expect(network).not.toHaveBeenCalled();
    });

    it.each(['false', ''])('DELETE with BYOK_ENABLED=%j still needs a login and a same-site cookie write', async (value) => {
        vi.stubEnv('BYOK_ENABLED', value);
        const f = world();
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error('no session') }) } } as unknown as SupabaseClient);
        expect((await DELETE(req('DELETE', undefined, SAME))).status).toBe(401);
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
        for (const headers of [{ 'sec-fetch-site': 'cross-site' }, { origin: 'https://evil.example' }] as Record<string, string>[]) expect((await DELETE(req('DELETE', undefined, headers))).status, JSON.stringify(headers)).toBe(401);
        expect(f.rpcNamed('ai_key_delete')).toEqual([]);
    });

    it.each([['PUT', () => PUT(req('PUT', { key: KEY }, SAME))], ['DELETE', () => DELETE(req('DELETE', undefined, SAME))]])('%s rejects an unauthenticated request before anything else', async (_name, call) => {
        mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error('no session') }) } } as unknown as SupabaseClient);
        const f = world();
        expect((await call()).status).toBe(401);
        expect(mocks.admin).not.toHaveBeenCalled();
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcCalls).toEqual([]);
    });

    it.each([['PUT', (h: Record<string, string>) => PUT(req('PUT', { key: KEY }, h))], ['DELETE', (h: Record<string, string>) => DELETE(req('DELETE', undefined, h))]])('%s treats a cross-site cookie write as logged out (CSRF)', async (_name, call) => {
        const f = world();
        for (const headers of [{ 'sec-fetch-site': 'cross-site' }, { 'sec-fetch-site': 'same-site' }, { origin: 'https://evil.example' }] as Record<string, string>[]) expect((await call(headers)).status, JSON.stringify(headers)).toBe(401);
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcCalls).toEqual([]);
    });

    it('accepts a bearer token from the app (no cookie, so no CSRF check applies)', async () => {
        world();
        const response = await PUT(req('PUT', { key: KEY }, { authorization: 'Bearer app-token' }));
        expect(response.status).toBe(200);
        expect(mocks.bearerClient).toHaveBeenCalled();
    });
});

describe('PUT: a Lifetime owner saves a key', () => {
    it('checks the key with OpenRouter, seals it with the user as AAD, answers connected and returns no key', async () => {
        const f = world();
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(200);
        expect(response.headers.get('cache-control')).toBe('no-store');
        const text = await response.text();
        expect(billingOpenRouterKeyResponseV2Schema.parse(JSON.parse(text))).toEqual({ ai_key: 'connected' });
        expect(text).not.toContain(KEY);
        expect(text).not.toContain('sk-or');
        // the outbound call: the fixed URL, this key only
        expect(network).toHaveBeenCalledTimes(1);
        const [url, init] = network.mock.calls[0] as [string, RequestInit];
        expect(url).toBe('https://openrouter.ai/api/v1/key');
        expect(new Headers(init.headers).get('authorization')).toBe(`Bearer ${KEY}`);
        // the stored value: sealed, and only openable as this user
        const [put] = f.rpcNamed('ai_key_put');
        expect(put).toEqual({ p_user_id: USER, p_sealed_key: expect.stringMatching(/^k1\.[^.]+\.[^.]+\.[^.]+$/), p_key_version: 1 });
        expect(JSON.stringify(f.rpcCalls)).not.toContain(KEY);
        expect(openUserKey(put.p_sealed_key as string, USER, userKeyEncryptionKey())).toBe(KEY);
        expect(() => openUserKey(put.p_sealed_key as string, OTHER, userKeyEncryptionKey())).toThrow();
    });

    it('trims surrounding whitespace before checking and sealing', async () => {
        const f = world();
        expect((await PUT(req('PUT', { key: `  ${KEY}\n` }, SAME))).status).toBe(200);
        expect(new Headers((network.mock.calls[0] as [string, RequestInit])[1].headers).get('authorization')).toBe(`Bearer ${KEY}`);
        expect(openUserKey(f.rpcNamed('ai_key_put')[0].p_sealed_key as string, USER, userKeyEncryptionKey())).toBe(KEY);
    });

    it('takes one attempt (kind ai_key, 10 per hour) before the outbound call, and stores only after the check', async () => {
        const order: string[] = [];
        const f = world({ rpcs: { take_rate_limit: () => { order.push('limit'); return { data: null }; }, ai_key_put: () => { order.push('put'); return { data: false }; } } });
        network.mockImplementation(async () => { order.push('verify'); return Response.json({ data: { is_management_key: false } }); });
        await PUT(req('PUT', { key: KEY }, SAME));
        expect(order).toEqual(['limit', 'verify', 'put']);
        expect(f.rpcNamed('take_rate_limit')).toEqual([{ p_user_id: USER, p_kind: 'ai_key', p_max: 10, p_window_seconds: 3600 }]);
    });

    it('the eleventh attempt within the hour is a 429 with Retry-After, and OpenRouter is not asked', async () => {
        let count = 0;
        const retryAt = new Date(Date.now() + 1_800_000).toISOString();
        const f = world({ rpcs: { take_rate_limit: () => ({ data: ++count > 10 ? retryAt : null }) } });
        for (let i = 0; i < 10; i++) expect((await PUT(req('PUT', { key: KEY }, SAME))).status).toBe(200);
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(429);
        expect(Number(response.headers.get('retry-after'))).toBeGreaterThan(1700);
        expect(billingErrorV2Schema.parse(await response.json()).error.code).toBe('rate_limited');
        expect(network).toHaveBeenCalledTimes(10);
        expect(f.rpcNamed('ai_key_put')).toHaveLength(10);
    });

    it('a failing rate-limit read is an outage, nothing is sent', async () => {
        const f = world({ rpcs: { take_rate_limit: () => ({ error: { message: 'down' } }) } });
        expect((await PUT(req('PUT', { key: KEY }, SAME))).status).toBe(503);
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
    });
});

describe('PUT: nothing is stored unless it checks out', () => {
    it.each([
        ['body is not JSON', 'not json', 400],
        ['no key', {}, 400],
        ['an extra field', { key: KEY, label: 'work' }, 400],
        ['key is not a string', { key: 12 }, 400],
        ['key is far too large', { key: 'sk-or-'.padEnd(5000, 'a') }, 400],
    ])('%s: 400 invalid_request, no outbound call, no write', async (_label, body, status) => {
        const f = world();
        const response = await PUT(req('PUT', body, SAME));
        expect(response.status).toBe(status);
        expect(billingErrorV2Schema.parse(await response.json()).error.code).toBe('invalid_request');
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
    });

    it.each([
        ['no sk-or- prefix', 'x'.repeat(40)],
        ['too short', 'sk-or-short'],
        ['too long', `sk-or-${'a'.repeat(300)}`],
        ['whitespace inside', 'sk-or-v1-aaaaaaaaaaaa bbbbbbbbbbbb'],
        ['a control character', 'sk-or-v1-aaaaaaaaaaaa\u0000bbbbbbbbbbbb'],
    ])('a key that is %s: 422 ai_key_invalid, OpenRouter is not asked, no attempt is used, nothing is stored', async (_label, key) => {
        const f = world();
        const response = await PUT(req('PUT', { key }, SAME));
        expect(response.status).toBe(422);
        const body = billingErrorV2Schema.parse(await response.json());
        expect(body.error.code).toBe('ai_key_invalid');
        expect(JSON.stringify(body)).not.toContain(key.slice(0, 20));
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcNamed('take_rate_limit')).toEqual([]);
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
    });

    it('OpenRouter 401: 422 ai_key_invalid, nothing stored', async () => {
        const f = world({ verify: () => new Response(JSON.stringify({ error: { message: `no ${KEY}` } }), { status: 401 }) });
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(422);
        const text = await response.text();
        expect(billingErrorV2Schema.parse(JSON.parse(text)).error.code).toBe('ai_key_invalid');
        expect(text).not.toContain('sk-or');
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
    });

    it('a management key: 422 ai_key_management, nothing stored', async () => {
        const f = world({ verify: () => Response.json({ data: { is_management_key: true } }) });
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(422);
        expect(billingErrorV2Schema.parse(await response.json()).error.code).toBe('ai_key_management');
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
    });

    it.each([
        ['5xx', () => new Response('down', { status: 503 })],
        ['429', () => new Response('slow', { status: 429 })],
        ['an answer in the wrong shape', () => Response.json({ ok: true })],
        ['an answer that does not say whether it is a management key', () => Response.json({ data: { label: 'sk-or-v1-abc...xyz' } })],
        ['a network error', () => { throw new Error(`socket ${KEY}`); }],
        ['a timeout', () => { throw new DOMException('timed out', 'TimeoutError'); }],
    ])('OpenRouter %s: 503 billing_unavailable, nothing stored', async (_label, verify) => {
        const f = world({ verify });
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(503);
        const text = await response.text();
        expect(billingErrorV2Schema.parse(JSON.parse(text)).error.code).toBe('billing_unavailable');
        expect(text).not.toContain('sk-or');
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
    });

    it('a database failure while storing is a 503 and the key is in no message', async () => {
        const spies = consoleSpies();
        world({ rpcs: { ai_key_put: () => ({ error: { message: `insert failed ${KEY}` } }) } });
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(503);
        expect(await response.text()).not.toContain('sk-or');
        expect(JSON.stringify(spies.map(spy => spy.mock.calls))).not.toContain('sk-or');
    });

    it('a missing or invalid USER_AI_KEY_ENCRYPTION_KEY is an outage before anything is sent: no attempt used, OpenRouter not asked, nothing stored, no value leaks', async () => {
        const spies = consoleSpies();
        const f = world();
        vi.stubEnv('USER_AI_KEY_ENCRYPTION_KEY', 'not-a-valid-key-value');
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(503);
        const text = await response.text();
        expect(text).not.toContain('not-a-valid');
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcNamed('take_rate_limit')).toEqual([]);
        expect(f.rpcNamed('ai_key_put')).toEqual([]);
        expect(JSON.stringify(spies.map(spy => spy.mock.calls))).not.toContain('not-a-valid');
    });
});

describe('PUT: only a Lifetime account may hold a key', () => {
    const accounts: [string, Record<string, unknown>][] = [
        ['a new account', accountRow({ user_id: USER })],
        ['a Pro', accountRow({ user_id: USER, subscription_id: 's', status: 'active', plan: 'monthly', current_period_ends_at: new Date(Date.now() + 86_400_000).toISOString() })],
        ['a refunded Lifetime', accountRow({ user_id: USER, lifetime_status: 'refunded', lifetime_order_id: 'o' })],
        ['a legacy beta', accountRow({ user_id: USER, legacy_beta: true })],
        ['an account being deleted', accountRow({ user_id: USER, lifetime_status: 'active', lifetime_order_id: 'o', deleting: true })],
    ];
    it.each(accounts)('%s: 409 billing_unavailable, no attempt used, no outbound call, no write', async (_label, account) => {
        const f = world({ accounts: [account] });
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(409);
        expect(billingErrorV2Schema.parse(await response.json()).error.code).toBe('billing_unavailable');
        expect(network).not.toHaveBeenCalled();
        expect(f.rpcCalls).toEqual([]);
    });

    it('with billing off nobody has a key to store and the account table is not even read', async () => {
        const f = world();
        vi.stubEnv('BILLING_ENABLED', 'false');
        expect((await PUT(req('PUT', { key: KEY }, SAME))).status).toBe(409);
        expect(f.writes).toEqual([]);
        expect(network).not.toHaveBeenCalled();
    });

    it('if the entitlement ended while OpenRouter was being asked, the database refuses and the answer is 409', async () => {
        const f = world({ rpcs: { ai_key_put: () => ({ error: { message: 'byok_not_entitled' } }) } });
        const response = await PUT(req('PUT', { key: KEY }, SAME));
        expect(response.status).toBe(409);
        expect(billingErrorV2Schema.parse(await response.json()).error.code).toBe('billing_unavailable');
        expect(f.rpcNamed('ai_key_put')).toHaveLength(1);
    });
});

describe('DELETE', () => {
    it('removes the key and answers 204 with no body; asking twice is the same', async () => {
        const f = world({ keys: [{ user_id: USER, sealed_key: 'k1.x.y.z', status: 'connected' }] });
        for (let i = 0; i < 2; i++) {
            const response = await DELETE(req('DELETE', undefined, SAME));
            expect(response.status).toBe(204);
            expect(response.headers.get('cache-control')).toBe('no-store');
            expect(await response.text()).toBe('');
        }
        expect(f.rpcNamed('ai_key_delete')).toEqual([{ p_user_id: USER }, { p_user_id: USER }]);
        expect(network).not.toHaveBeenCalled();
    });

    it('works for an account that is no longer Lifetime (a stray key can always be removed)', async () => {
        const f = world({ accounts: [accountRow({ user_id: USER })] });
        expect((await DELETE(req('DELETE', undefined, SAME))).status).toBe(204);
        expect(f.rpcNamed('ai_key_delete')).toHaveLength(1);
    });

    it('a database failure is a 503', async () => {
        world({ rpcs: { ai_key_delete: () => ({ error: { message: 'down' } }) } });
        const response = await DELETE(req('DELETE', undefined, SAME));
        expect(response.status).toBe(503);
        expect(billingErrorV2Schema.parse(await response.json()).error.code).toBe('billing_unavailable');
    });
});

describe('GET /api/v2/billing reports the key state and nothing of the key', () => {
    const status = async () => {
        const response = await getStatus(new Request('https://api.example.test/api/v2/billing', { headers: { authorization: 'Bearer app-token' } }));
        expect(response.status).toBe(200);
        return { text: await response.clone().text(), body: (await response.json()) as Record<string, unknown> };
    };
    it('Lifetime without a row: missing', async () => {
        world();
        expect((await status()).body).toMatchObject({ state: 'lifetime', ai_key: 'missing', ai_key_spend_error_at: null });
    });
    it('Lifetime with a connected key: connected, plus the time of the last out-of-credit answer', async () => {
        const at = '2026-10-19T10:00:00.000Z';
        world({ keys: [{ user_id: USER, sealed_key: 'k1.secret.secret.secret', status: 'connected', last_spend_error_at: at }] });
        const { text, body } = await status();
        expect(body).toMatchObject({ ai_key: 'connected', ai_key_spend_error_at: at });
        expect(text).not.toContain('secret');
        expect(text).not.toContain('k1.');
    });
    it('a revoked key: revoked, and no spend-error time', async () => {
        world({ keys: [{ user_id: USER, sealed_key: 'k1.a.b.c', status: 'revoked', last_spend_error_at: '2026-10-19T10:00:00.000Z' }] });
        expect((await status()).body).toMatchObject({ ai_key: 'revoked', ai_key_spend_error_at: null });
    });
    it('another user\'s key is never reported', async () => {
        world({ keys: [{ user_id: OTHER, sealed_key: 'k1.a.b.c', status: 'connected', last_spend_error_at: null }] });
        expect((await status()).body).toMatchObject({ ai_key: 'missing' });
    });
    it('anything but Lifetime has no key state', async () => {
        world({ accounts: [accountRow({ user_id: USER })], keys: [{ user_id: USER, sealed_key: 'k1.a.b.c', status: 'connected' }] });
        expect((await status()).body).toMatchObject({ state: 'none', ai_key: null, ai_key_spend_error_at: null });
    });
    it('a key table that cannot be read fails the status instead of guessing', async () => {
        const f = world();
        const admin = { ...f.admin, from: (table: string) => (table === 'user_ai_keys' ? { select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: { message: 'down' } }) }) }) } : f.admin.from(table)) } as never;
        mocks.admin.mockReturnValue(admin);
        const response = await getStatus(new Request('https://api.example.test/api/v2/billing', { headers: { authorization: 'Bearer app-token' } }));
        expect(response.status).toBe(503);
    });
});

describe('no key in any log', () => {
    it('saving, refusing, failing and removing print nothing that contains a key', async () => {
        const spies = consoleSpies();
        for (const verify of [undefined, () => new Response(`bad ${KEY}`, { status: 401 }), () => { throw new Error(`boom ${KEY}`); }]) {
            world({ verify });
            await PUT(req('PUT', { key: KEY }, SAME));
        }
        world();
        await DELETE(req('DELETE', undefined, SAME));
        expect(JSON.stringify(spies.map(spy => spy.mock.calls))).not.toContain('sk-or');
    });
});
