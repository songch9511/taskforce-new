import { randomUUID } from 'node:crypto';
import type { PGlite } from '@electric-sql/pglite';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { planState, type BillingAccount } from '@/lib/billing/state';
import { asUser, createLocalSupabase } from './local-supabase';

// Billing v2 (20261129000000): Pro + Lifetime entitlement, 72-hour refund claim, hidden fair-use window,
// token usage, legacy conversion. The old v1 functions are exercised by billing.test.ts and stay untouched.
const DAY = 86_400_000;
const iso = (offsetMs: number) => new Date(Date.now() + offsetMs).toISOString();
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query('update ai_budget_policy set global_daily_usd=1000,global_total_usd=1000,user_daily_usd=1000');
}, 60_000);
afterAll(async () => { await db?.close(); });

async function user(): Promise<string> {
  const id = randomUUID();
  await db.query('insert into auth.users(id) values($1)', [id]);
  return id;
}
/** Insert / overwrite columns of the account row directly (fixture only). */
async function setAccount(userId: string, input: Record<string, unknown>) {
  // provider ids are unique per account in the table: make every fixture id unique to its owner
  const cols = Object.fromEntries(Object.entries(input).map(([k, v]) => [k, (k === 'subscription_id' || k === 'lifetime_order_id') && typeof v === 'string' ? `${v}-${userId}` : v]));
  const keys = Object.keys(cols);
  const names = ['user_id', ...keys].join(',');
  const marks = ['$1', ...keys.map((_, i) => `$${i + 2}`)].join(',');
  const sets = keys.map((k) => `${k}=excluded.${k}`).join(',');
  await db.query(`insert into billing_accounts(${names}) values(${marks}) on conflict (user_id) do ${keys.length ? `update set ${sets}` : 'nothing'}`, [userId, ...keys.map((k) => cols[k])]);
}
/** An intent as the checkout route leaves it: URL attached, trial and first-month offered (Pro, first checkout). */
async function intent(userId: string, plan: 'pro' | 'lifetime' = 'pro', consumed = false, opts: { trial?: boolean; discount?: boolean; url?: string | null } = {}): Promise<string> {
  const id = randomUUID();
  await db.query('insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,consumed_at,url,with_trial,with_discount) values($1,$2,$3,$4,$5,$6,$7,$8)', [
    id, userId, plan, '2026-10-19', consumed ? new Date().toISOString() : null, opts.url === undefined ? 'https://taskforce.lemonsqueezy.com/checkout/x' : opts.url, opts.trial ?? plan === 'pro', opts.discount ?? plan === 'pro',
  ]);
  return id;
}
type Sub = { event?: string; intent?: string | null; sub?: string; customer?: string; status?: string; ends?: string | null; updated?: string; trial?: string | null; payment?: string | null; invoice?: string | null; order?: string | null; plan?: string; discounted?: boolean };
/** applied | rejected | rejected_known | replay */
const applySub = async (userId: string, o: Sub = {}) =>
  (await db.query<{ r: string }>('select billing_apply_subscription_v2($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) r', [
    userId, o.event ?? randomUUID(), o.intent ?? null, `${o.sub ?? 'sub-1'}-${userId}`, o.customer ?? 'cus-1', o.status ?? 'active', o.ends ?? null,
    o.updated ?? '2026-10-19T00:00:00Z', o.trial ?? null, o.payment ?? null, o.invoice ?? null, o.order ?? '100', o.plan ?? 'monthly', o.discounted ?? false,
  ])).rows[0].r;
type Life = { event?: string; intent?: string | null; order?: string; status?: string; paid?: string; updated?: string };
const applyLife = async (userId: string, o: Life = {}) =>
  (await db.query<{ r: string }>('select billing_apply_lifetime($1,$2,$3,$4,$5,$6,$7,$8) r', [
    userId, o.event ?? randomUUID(), o.intent ?? null, `${o.order ?? 'ord-1'}-${userId}`, 'cus-1', o.status ?? 'active', o.paid ?? new Date().toISOString(), o.updated ?? '2026-10-19T00:00:00Z',
  ])).rows[0].r;
const events = async (userId: string) =>
  (await db.query<{ type: string; props: Record<string, unknown> }>("select type,props from metric_events where user_id=$1 and (type like 'billing\\_%' or type like 'ai\\_key\\_%')", [userId])).rows
    .map((r) => `${r.type} ${JSON.stringify(Object.fromEntries(Object.entries(r.props).sort(([a], [b]) => a.localeCompare(b))))}`).sort();
const row = async (userId: string) => (await db.query<Record<string, unknown>>('select * from billing_accounts where user_id=$1', [userId])).rows[0];
const kind = async (userId: string) => (await db.query<{ k: string }>('select billing_plan_kind(a) k from billing_accounts a where user_id=$1', [userId])).rows[0].k;
const claim = async (userId: string, plan: 'pro' | 'lifetime', terms = '2026-10-19') =>
  (await db.query<{ i: { id: string; plan: string; url: string | null; with_trial: boolean; with_discount: boolean; accepted_terms_version: string } }>('select to_jsonb(billing_claim_checkout_v2($1,$2,$3)) i', [userId, plan, terms])).rows[0].i;

describe('schema and privileges', () => {
  it('adds the account columns, the intent flags and the token columns', async () => {
    const cols = async (table: string) => (await db.query<{ column_name: string }>("select column_name from information_schema.columns where table_schema='public' and table_name=$1", [table])).rows.map((r) => r.column_name);
    expect(await cols('billing_accounts')).toEqual(expect.arrayContaining(['first_subscription_at', 'lifetime_order_id', 'lifetime_status', 'lifetime_paid_at', 'lifetime_updated_at', 'last_payment_at', 'last_invoice_id', 'refund_requested_at', 'self_refund_used_at', 'last_swept_at']));
    expect(await cols('billing_checkout_intents')).toEqual(expect.arrayContaining(['with_trial', 'with_discount']));
    expect(await cols('ai_spend_attempts')).toEqual(expect.arrayContaining(['prompt_tokens', 'completion_tokens']));
  });
  it('owner reads only the own row (new columns included) and nobody writes through the API roles', async () => {
    const alice = await user(), bob = await user();
    await setAccount(alice, { last_invoice_id: 'inv-a', lifetime_order_id: 'ord-a' });
    await setAccount(bob, { last_invoice_id: 'inv-b' });
    await asUser(db, alice, async () => {
      expect((await db.query<{ last_invoice_id: string }>('select last_invoice_id from billing_accounts')).rows).toEqual([{ last_invoice_id: 'inv-a' }]);
      await expect(db.query("update billing_accounts set lifetime_status='active'")).rejects.toThrow(/permission denied/);
      await expect(db.query("update billing_accounts set self_refund_used_at=null where user_id=$1", [alice])).rejects.toThrow(/permission denied/);
      await expect(db.query('insert into billing_accounts(user_id) values($1)', [randomUUID()])).rejects.toThrow(/permission denied/);
      await expect(db.query('delete from billing_accounts')).rejects.toThrow(/permission denied/);
    });
  });
  it('every v2 function is service-role only', async () => {
    const u = randomUUID();
    const calls = [
      "select billing_claim_checkout_v2($1,'pro','2026-10-19')", "select billing_checkout_url_v2($1,$1,'x')",
      "select billing_apply_subscription_v2($1,'e',null,'s','c','active',null,now(),null,null,null,null,'monthly')",
      "select billing_apply_lifetime($1,'e',null,'o','c','active',now(),now())", "select billing_record_event($1,'billing_portal_opened')",
      'select billing_claim_refund($1)', 'select billing_release_refund($1,true)', 'select billing_sweep_done($1,true)', 'select billing_emit_once($1,\'billing_refunded\',\'{}\',\'k\')', 'select * from billing_spend_window_v2($1,10,2)',
      "select reserve_billing_ai_spend_v2($1,$1,'chat','m',0.1,10,2)", 'select billing_spend_summary_v2($1,10,2)',
      'select record_ai_spend_tokens($1,$1,1,1)', "select billing_usage_tokens($1,now())", 'select billing_seed_legacy(now())',
      "select billing_schedule_legacy_notice(now()+interval '40 days')", "select billing_emit($1,'billing_refunded')",
    ];
    for (const role of ['authenticated', 'anon']) {
      await db.exec(`set role ${role}`);
      try {
        for (const sql of calls) await expect(db.query(sql, sql.includes('$1') ? [u] : []), `${role}: ${sql}`).rejects.toThrow(/permission denied/);
      } finally { await db.exec('reset role'); }
    }
  });
  it('metric events accept the billing types, keep every old type, reject unknown ones and stay closed to clients', async () => {
    const u = await user();
    for (const type of ['billing_checkout_started', 'billing_refunded', 'ai_key_saved', 'ai_key_revoked', 'app_opened', 'path_conflict_resolved', 'tool_call_decided', 'source_failed'])
      await db.query('insert into metric_events(user_id,type) values($1,$2)', [u, type]);
    await expect(db.query("insert into metric_events(user_id,type) values($1,'billing_free_money')", [u])).rejects.toThrow(/metric_events_type_check|violates check/);
    await asUser(db, u, async () => {
      await expect(db.query("insert into metric_events(user_id,type) values($1,'billing_refunded')", [u])).rejects.toThrow(/row-level security|permission denied|violates/);
    });
  });
  it('intents accept pro and lifetime plans only besides the old two', async () => {
    const u = await user();
    for (const plan of ['monthly', 'annual', 'pro', 'lifetime']) await db.query("insert into billing_checkout_intents(user_id,plan,accepted_terms_version,consumed_at) values($1,$2,'2026-10-19',now())", [u, plan]);
    await expect(db.query("insert into billing_checkout_intents(user_id,plan,accepted_terms_version) values($1,'weekly','2026-10-19')", [u])).rejects.toThrow(/plan_check|violates check/);
  });
});

describe('checkout claim', () => {
  it('requires an explicit ISO-dated terms version and a valid plan', async () => {
    const u = await user(); await setAccount(u, {});
    for (const terms of [null, '', 'v2', '2026-10']) await expect(db.query("select billing_claim_checkout_v2($1,'pro',$2)", [u, terms])).rejects.toThrow(/billing_terms_required/);
    for (const plan of [null, 'monthly', 'weekly']) await expect(db.query("select billing_claim_checkout_v2($1,$2,'2026-10-19')", [u, plan])).rejects.toThrow(/billing_plan_invalid/);
    expect((await db.query('select count(*)::int n from billing_checkout_intents where user_id=$1', [u])).rows[0]).toEqual({ n: 0 });
  });
  it('offers the trial and the first-month discount to the first Pro checkout only, and records consent', async () => {
    const u = await user(); await setAccount(u, {});
    const first = await claim(u, 'pro');
    expect(first).toMatchObject({ plan: 'pro', url: null, with_trial: true, with_discount: true, accepted_terms_version: '2026-10-19' });
    expect((await db.query<{ ok: boolean }>('select accepted_at is not null ok from billing_checkout_intents where id=$1', [first.id])).rows[0].ok).toBe(true);
    // The account has now had a subscription: the next checkout is a plain restart.
    await db.query('update billing_checkout_intents set consumed_at=now() where id=$1', [first.id]);
    await setAccount(u, { first_subscription_at: iso(-10 * DAY), subscription_id: 's1', status: 'expired' });
    expect(await claim(u, 'pro')).toMatchObject({ with_trial: false, with_discount: false });
  });
  it('Lifetime never carries a trial or a discount', async () => {
    const u = await user(); await setAccount(u, {});
    expect(await claim(u, 'lifetime')).toMatchObject({ plan: 'lifetime', with_trial: false, with_discount: false });
  });
  it('returns the same open intent for the same plan once its URL is known and refuses another plan or a missing URL', async () => {
    const u = await user(); await setAccount(u, {});
    const i = await claim(u, 'pro');
    await expect(db.query("select billing_claim_checkout_v2($1,'pro','2026-10-19')", [u])).rejects.toThrow(/billing_checkout_pending/);
    expect((await db.query<{ ok: boolean }>('select billing_checkout_url_v2($1,$2,$3) ok', [u, i.id, 'https://store.lemonsqueezy.com/checkout/x'])).rows[0].ok).toBe(true);
    expect((await db.query<{ ok: boolean }>('select billing_checkout_url_v2($1,$2,$3) ok', [u, i.id, 'https://store.lemonsqueezy.com/checkout/y'])).rows[0].ok).toBe(false);
    expect((await claim(u, 'pro')).id).toBe(i.id);
    await expect(db.query("select billing_claim_checkout_v2($1,'lifetime','2026-10-19')", [u])).rejects.toThrow(/billing_checkout_pending/);
    expect(await events(u)).toEqual(['billing_checkout_started {"plan":"pro","with_discount":true,"with_trial":true}']);
  });
  it('only the owner of the intent can attach a URL', async () => {
    const a = await user(), b = await user(); await setAccount(a, {}); await setAccount(b, {});
    const i = await claim(a, 'pro');
    expect((await db.query<{ ok: boolean }>("select billing_checkout_url_v2($1,$2,'https://x.lemonsqueezy.com/c') ok", [b, i.id])).rows[0].ok).toBe(false);
    expect((await db.query('select url from billing_checkout_intents where id=$1', [i.id])).rows[0]).toEqual({ url: null });
  });
  it('is closed to deleting accounts, owners of an active Lifetime and live subscriptions', async () => {
    const closed = async (cols: Record<string, unknown>, plan: 'pro' | 'lifetime') => {
      const u = await user(); await setAccount(u, cols);
      await expect(db.query('select billing_claim_checkout_v2($1,$2,$3)', [u, plan, '2026-10-19']), JSON.stringify(cols) + plan).rejects.toThrow(/billing_checkout_unavailable/);
    };
    await closed({ deleting: true }, 'pro');
    await closed({ lifetime_status: 'active', lifetime_order_id: 'o1' }, 'pro');
    await closed({ lifetime_status: 'active', lifetime_order_id: 'o2' }, 'lifetime');
    await closed({ subscription_id: 's', status: 'active', current_period_ends_at: iso(5 * DAY) }, 'pro');
    await closed({ subscription_id: 's', status: 'on_trial', trial_ends_at: iso(2 * DAY) }, 'pro');
    await closed({ subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(5 * DAY) }, 'pro');
    await closed({ subscription_id: 's', status: 'past_due', current_period_ends_at: iso(-1 * DAY) }, 'pro');
    await closed({ subscription_id: 's', status: 'active', current_period_ends_at: iso(5 * DAY) }, 'lifetime');
    await closed({ subscription_id: 's', status: 'on_trial', trial_ends_at: iso(2 * DAY) }, 'lifetime');
    await closed({ subscription_id: 's', status: 'past_due', current_period_ends_at: iso(-1 * DAY) }, 'lifetime');
  });
  it('lets ended subscriptions restart and a cancelled Pro buy Lifetime', async () => {
    for (const status of ['expired', 'refunded', 'unpaid', 'paused']) {
      const u = await user(); await setAccount(u, { subscription_id: `s-${status}`, status, first_subscription_at: iso(-30 * DAY) });
      expect(await claim(u, 'pro')).toMatchObject({ plan: 'pro', with_trial: false });
    }
    const ran = await user(); await setAccount(ran, { subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(-DAY) });
    expect(await claim(ran, 'pro')).toMatchObject({ plan: 'pro' });
    const cancelled = await user(); await setAccount(cancelled, { subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(5 * DAY) });
    expect(await claim(cancelled, 'lifetime')).toMatchObject({ plan: 'lifetime' });
    const refundedLifetime = await user(); await setAccount(refundedLifetime, { lifetime_status: 'refunded', lifetime_order_id: 'old' });
    expect(await claim(refundedLifetime, 'lifetime')).toMatchObject({ plan: 'lifetime' });
  });
  it('expires a stale open intent so a new one can be claimed', async () => {
    const u = await user(); await setAccount(u, {});
    const old = randomUUID();
    await db.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,expires_at) values($1,$2,'pro','2026-10-19',now()-interval '1 minute')", [old, u]);
    const fresh = await claim(u, 'pro');
    expect(fresh.id).not.toBe(old);
    expect((await db.query<{ consumed_at: Date | null }>('select consumed_at from billing_checkout_intents where id=$1', [old])).rows[0].consumed_at).not.toBeNull();
  });
});

describe('subscription entitlement', () => {
  it('walks trial -> paid -> renewal -> failure -> recovery -> cancel -> resume -> plan change -> expiry with one event per transition', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'on_trial', trial: iso(3 * DAY), updated: '2026-10-19T00:00:01Z' });
    let r = await row(u);
    expect(r).toMatchObject({ status: 'on_trial', plan: 'monthly', subscription_id: `sub-1-${u}`, current_period_ends_at: null, order_id: '100' });
    expect(r.first_subscription_at).not.toBeNull();
    expect(await kind(u)).toBe('trial');
    expect((await db.query<{ consumed_at: Date | null }>('select consumed_at from billing_checkout_intents where id=$1', [i])).rows[0].consumed_at).not.toBeNull();

    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', updated: '2026-10-19T00:00:02Z' });
    r = await row(u);
    expect(r).toMatchObject({ status: 'active', last_invoice_id: 'inv-1' });
    expect(r.trial_ends_at).not.toBeNull(); // kept for the same subscription (after_trial evidence)
    expect(await kind(u)).toBe('pro');

    await applySub(u, { status: 'active', ends: iso(60 * DAY), payment: iso(1000), invoice: 'inv-2', updated: '2026-10-19T00:00:03Z' });
    await applySub(u, { status: 'past_due', ends: null, updated: '2026-10-19T00:00:04Z' });
    expect((await row(u)).current_period_ends_at).not.toBeNull(); // the last paid period is kept for the grace calculation
    await applySub(u, { status: 'active', ends: iso(90 * DAY), payment: iso(2000), invoice: 'inv-3', updated: '2026-10-19T00:00:05Z' });
    await applySub(u, { status: 'cancelled', ends: iso(90 * DAY), payment: iso(2000), invoice: 'inv-3', updated: '2026-10-19T00:00:06Z' });
    expect(await kind(u)).toBe('cancelled');
    await applySub(u, { status: 'active', ends: iso(90 * DAY), payment: iso(2000), invoice: 'inv-3', updated: '2026-10-19T00:00:07Z' });
    await applySub(u, { status: 'active', ends: iso(90 * DAY), payment: iso(2000), invoice: 'inv-3', updated: '2026-10-19T00:00:08Z', plan: 'annual' });
    await applySub(u, { status: 'expired', ends: null, updated: '2026-10-19T00:00:09Z', plan: 'annual' });
    expect(await kind(u)).toBe('lapsed');
    // one metric_events row per transition type, written by the transition function itself
    const types = (await db.query<{ type: string }>('select distinct type from metric_events where user_id=$1 order by type', [u])).rows.map((r) => r.type);
    expect(types).toEqual(['billing_payment_failed', 'billing_payment_succeeded', 'billing_plan_changed', 'billing_subscription_activated', 'billing_subscription_cancelled', 'billing_subscription_ended', 'billing_subscription_resumed', 'billing_trial_started']);
    expect(await events(u)).toEqual([
      'billing_payment_failed {"plan":"monthly"}',
      'billing_payment_succeeded {"kind":"recovered"}',
      'billing_payment_succeeded {"kind":"renewal"}',
      'billing_plan_changed {"from":"monthly","to":"annual"}',
      'billing_subscription_activated {"after_trial":true,"plan":"monthly"}',
      'billing_subscription_cancelled {"by":"user"}',
      'billing_subscription_ended {"reason":"expired"}',
      'billing_subscription_resumed {}',
      'billing_trial_started {"plan":"monthly"}',
    ].sort());
  });
  it('does not count a redelivery or an unchanged state twice', async () => {
    const u = await user(); const i = await intent(u);
    const first = randomUUID();
    await applySub(u, { event: first, intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1' });
    await applySub(u, { event: first, intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1' });
    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', updated: '2026-10-19T00:00:05Z' });
    expect(await events(u)).toEqual(['billing_subscription_activated {"after_trial":false,"plan":"monthly"}']);
    expect((await db.query('select count(*)::int n from billing_webhook_events where user_id=$1', [u])).rows[0]).toEqual({ n: 2 });
  });
  it('ignores a snapshot older than the applied one but remembers its delivery', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', updated: '2026-10-19T00:00:10Z' });
    const old = randomUUID();
    await applySub(u, { event: old, status: 'expired', updated: '2026-10-19T00:00:01Z' });
    await applySub(u, { event: old, status: 'expired', updated: '2026-10-19T00:00:01Z' });
    expect((await row(u)).status).toBe('active');
    expect(await events(u)).toEqual(['billing_subscription_activated {"after_trial":false,"plan":"monthly"}']);
  });
  it('binds the first subscription to an own, Pro intent', async () => {
    const a = await user(), b = await user();
    await setAccount(a, {});
    await expect(applySub(a, { intent: null })).rejects.toThrow(/billing_intent_missing/);
    await expect(applySub(a, { intent: await intent(a, 'lifetime') })).rejects.toThrow(/billing_intent_missing/);
    await expect(applySub(a, { intent: randomUUID() })).rejects.toThrow(/billing_intent_missing/);
    expect((await row(a)).subscription_id).toBeNull();
    // somebody else's intent is clear tampering (ch.23): refused for good, flagged, never attached
    expect(await applySub(a, { intent: await intent(b) })).toBe('rejected');
    expect((await row(a)).subscription_id).toBeNull();
    expect(await events(a)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
  });
  it('rejects a second live subscription and accepts a replacement only after the first ended, with a fresh intent', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1' });
    const fresh = await intent(u);
    await expect(applySub(u, { sub: 'sub-2', intent: fresh, status: 'active', ends: iso(30 * DAY) })).rejects.toThrow(/billing_duplicate_subscription/);
    await applySub(u, { status: 'expired', updated: '2026-10-19T00:00:02Z' });
    await applySub(u, { sub: 'sub-2', intent: fresh, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-9', updated: '2026-10-19T00:00:03Z', order: '200' });
    expect(await row(u)).toMatchObject({ subscription_id: `sub-2-${u}`, status: 'active', last_invoice_id: 'inv-9', order_id: '200' });
  });
  it('a replacement never inherits the previous period, payment or trial', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'on_trial', trial: iso(2 * DAY) });
    await applySub(u, { status: 'expired', updated: '2026-10-19T00:00:02Z' });
    await setAccount(u, { last_payment_at: iso(-DAY), last_invoice_id: 'old-inv', current_period_ends_at: iso(20 * DAY) });
    await applySub(u, { sub: 'sub-2', intent: await intent(u), status: 'payment_pending', updated: '2026-10-19T00:00:03Z' });
    expect(await row(u)).toMatchObject({ subscription_id: `sub-2-${u}`, last_payment_at: null, last_invoice_id: null, current_period_ends_at: null, trial_ends_at: null });
    expect(await kind(u)).toBe('lapsed');
  });
  it('past_due keeps access only for 16 days after the last paid period; unconfirmed first payment grants nothing', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'active', ends: iso(1 * DAY), payment: iso(-29 * DAY), invoice: 'inv-1', updated: '2026-10-19T00:00:01Z' });
    await applySub(u, { status: 'past_due', ends: iso(40 * DAY), updated: '2026-10-19T00:00:02Z' }); // a provider date must not extend the grace
    const period = (await row(u)).current_period_ends_at as Date;
    expect(period.getTime()).toBeLessThan(Date.now() + 2 * DAY);
    await setAccount(u, { current_period_ends_at: iso(-15 * DAY) });
    expect(await kind(u)).toBe('past_due');
    await setAccount(u, { current_period_ends_at: iso(-17 * DAY) });
    expect(await kind(u)).toBe('lapsed');
    const fresh = await user(); const j = await intent(fresh);
    await applySub(fresh, { intent: j, status: 'payment_pending', ends: iso(30 * DAY), updated: '2026-10-19T00:00:01Z' });
    expect(await row(fresh)).toMatchObject({ status: 'payment_pending', current_period_ends_at: null });
    expect(await kind(fresh)).toBe('lapsed');
  });
  it('a refund ends the plan at once, counts once and drops the refund claim', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(-1000), invoice: 'inv-1', updated: '2026-10-19T00:00:01Z' });
    await setAccount(u, { refund_requested_at: iso(-500), self_refund_used_at: iso(-500) });
    await applySub(u, { status: 'refunded', ends: null, updated: '2026-10-19T00:00:02Z' });
    await applySub(u, { status: 'refunded', ends: null, updated: '2026-10-19T00:00:03Z' });
    expect(await row(u)).toMatchObject({ status: 'refunded', current_period_ends_at: null, refund_requested_at: null });
    expect((await row(u)).self_refund_used_at).not.toBeNull();
    expect(await kind(u)).toBe('lapsed');
    // the claim set up above was a request, so the confirmation also accounts for it (once)
    expect(await events(u)).toEqual([
      'billing_refund_requested {"plan":"monthly"}', 'billing_refunded {"plan":"monthly"}', 'billing_subscription_activated {"after_trial":false,"plan":"monthly"}', 'billing_subscription_ended {"reason":"refunded"}',
    ].sort());
  });
  it('a paused / unpaid subscription is recorded as ended with its reason', async () => {
    for (const reason of ['paused', 'unpaid']) {
      const u = await user(); const i = await intent(u);
      await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', updated: '2026-10-19T00:00:01Z' });
      await applySub(u, { status: reason, updated: '2026-10-19T00:00:02Z' });
      expect(await kind(u)).toBe('lapsed');
      expect(await events(u)).toContain(`billing_subscription_ended {"reason":"${reason}"}`);
    }
  });
  it('a subscription cancelled during the trial keeps the trial window only', async () => {
    const u = await user(); const i = await intent(u);
    await applySub(u, { intent: i, status: 'on_trial', trial: iso(2 * DAY), updated: '2026-10-19T00:00:01Z' });
    await applySub(u, { status: 'cancelled', ends: iso(2 * DAY), updated: '2026-10-19T00:00:02Z' });
    expect(await kind(u)).toBe('cancelled');
    const w = (await db.query<{ cap: string; kind: string }>('select cap::text,kind from billing_spend_window_v2($1,10,2)', [u])).rows[0];
    expect(w).toEqual({ cap: '2', kind: 'cancelled' });
  });
  it('refuses a live subscription next to an active Lifetime but records an ended one', async () => {
    const u = await user(); await setAccount(u, { lifetime_status: 'active', lifetime_order_id: 'o-life', subscription_id: 'sub-1', status: 'cancelled', first_subscription_at: iso(-DAY) });
    for (const status of ['on_trial', 'active', 'past_due', 'payment_pending']) await expect(applySub(u, { status, trial: iso(DAY), ends: iso(DAY) }), status).rejects.toThrow(/billing_lifetime_active/);
    await applySub(u, { status: 'expired', updated: '2026-10-19T00:00:09Z' });
    expect((await row(u)).status).toBe('expired');
  });
  it('a deleting account accepts only terminal states', async () => {
    const u = await user(); const i = await intent(u);
    await setAccount(u, { deleting: true });
    await expect(applySub(u, { intent: i, status: 'active', ends: iso(DAY) })).rejects.toThrow(/billing_account_deleting/);
    await applySub(u, { intent: i, status: 'cancelled', ends: iso(DAY) });
    expect((await row(u)).status).toBe('cancelled');
  });
  it('rejects unknown plans and statuses', async () => {
    const u = await user(); const i = await intent(u);
    await expect(applySub(u, { intent: i, plan: 'lifetime' })).rejects.toThrow(/billing_plan_invalid/);
    await expect(applySub(u, { intent: i, status: 'gold' })).rejects.toThrow(/billing_status_invalid/);
  });
});

describe('lifetime entitlement', () => {
  it('opens on a paid order bound to an own Lifetime intent and counts the purchase once', async () => {
    const u = await user(); const i = await intent(u, 'lifetime');
    const e = randomUUID();
    expect(await applyLife(u, { event: e, intent: i })).toBe('applied');
    expect(await applyLife(u, { event: e, intent: i })).toBe('replay');
    expect(await row(u)).toMatchObject({ lifetime_status: 'active', lifetime_order_id: `ord-1-${u}`, customer_id: 'cus-1' });
    expect(await kind(u)).toBe('lifetime');
    expect((await db.query<{ consumed_at: Date | null }>('select consumed_at from billing_checkout_intents where id=$1', [i])).rows[0].consumed_at).not.toBeNull();
    // the same order seen again under another delivery changes nothing
    expect(await applyLife(u, { intent: i, updated: '2026-10-19T00:00:05Z' })).toBe('applied');
    expect(await events(u)).toEqual(['billing_lifetime_purchased {}']);
  });
  it('needs an own Lifetime intent', async () => {
    const a = await user(), b = await user();
    await setAccount(a, {});
    await expect(applyLife(a, { intent: null })).rejects.toThrow(/billing_intent_missing/);
    await expect(applyLife(a, { intent: await intent(b, 'lifetime') })).rejects.toThrow(/billing_intent_missing/);
    await expect(applyLife(a, { intent: await intent(a, 'pro') })).rejects.toThrow(/billing_intent_missing/);
    expect((await row(a)).lifetime_status).toBeNull();
  });
  it('keeps the entitlement on a second paid order and flags it', async () => {
    const u = await user(); const i = await intent(u, 'lifetime');
    await applyLife(u, { intent: i });
    const dup = randomUUID();
    expect(await applyLife(u, { event: dup, order: 'ord-2', intent: await intent(u, 'lifetime') })).toBe('duplicate');
    expect(await applyLife(u, { event: dup, order: 'ord-2' })).toBe('replay');
    expect((await row(u)).lifetime_order_id).toBe(`ord-1-${u}`);
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"lifetime"}', 'billing_lifetime_purchased {}']);
  });
  it('ignores a snapshot older than the applied one', async () => {
    const u = await user(); const i = await intent(u, 'lifetime');
    await applyLife(u, { intent: i, updated: '2026-10-19T00:00:10Z' });
    expect(await applyLife(u, { status: 'refunded', updated: '2026-10-19T00:00:01Z' })).toBe('stale');
    expect((await row(u)).lifetime_status).toBe('active');
  });
  it('a refund ends it, drops the claim, counts once and deletes a stored key', async () => {
    const u = await user(); const i = await intent(u, 'lifetime');
    // the key table exists since 20261130000000: a row with a fake sealed value (never a real key)
    await db.query("insert into public.user_ai_keys(user_id,sealed_key,verified_at) values($1,'k1.x.y.z',now())", [u]);
    await applyLife(u, { intent: i });
    await setAccount(u, { refund_requested_at: iso(-1000), self_refund_used_at: iso(-1000) });
    expect(await applyLife(u, { status: 'refunded', updated: '2026-10-19T00:00:20Z' })).toBe('applied');
    expect(await applyLife(u, { status: 'refunded', updated: '2026-10-19T00:00:21Z' })).toBe('applied');
    expect(await row(u)).toMatchObject({ lifetime_status: 'refunded', refund_requested_at: null });
    expect(await kind(u)).toBe('lapsed');
    expect((await db.query('select * from public.user_ai_keys where user_id=$1', [u])).rows).toEqual([]);
    expect(await events(u)).toEqual(['ai_key_deleted {"by":"refund"}', 'billing_lifetime_purchased {}', 'billing_refund_requested {"plan":"lifetime"}', 'billing_refunded {"plan":"lifetime"}']);
  });
  it('a refund of an unknown order is rejected; a deleting account cannot buy', async () => {
    const u = await user(); await applyLife(u, { intent: await intent(u, 'lifetime') });
    // the refund of an order that is not the entitlement leaves the entitlement alone
    expect(await applyLife(u, { order: 'other', status: 'refunded', updated: '2026-10-19T00:00:40Z' })).toBe('stale');
    expect(await kind(u)).toBe('lifetime');
    const d = await user(); await setAccount(d, { deleting: true });
    await expect(applyLife(d, { intent: await intent(d, 'lifetime') })).rejects.toThrow(/billing_account_deleting/);
    await expect(applyLife(u, { status: 'gold' })).rejects.toThrow(/billing_status_invalid/);
  });
  it('a refunded Lifetime can be bought again with a new order', async () => {
    const u = await user();
    await applyLife(u, { intent: await intent(u, 'lifetime') });
    await applyLife(u, { status: 'refunded', updated: '2026-10-19T00:00:02Z' });
    expect(await applyLife(u, { order: 'ord-9', intent: await intent(u, 'lifetime'), updated: '2026-10-19T00:00:03Z' })).toBe('applied');
    expect(await row(u)).toMatchObject({ lifetime_order_id: `ord-9-${u}`, lifetime_status: 'active' });
  });
});

describe('server-recorded events', () => {
  it('writes only whitelisted metric events and counts a deduplicated one once', async () => {
    const u = await user();
    expect((await db.query<{ ok: boolean }>("select billing_record_event($1,'billing_portal_opened','{\"target\":\"manage\"}') ok", [u])).rows[0].ok).toBe(true);
    expect((await db.query<{ ok: boolean }>("select billing_record_event($1,'billing_refund_requested','{\"plan\":\"monthly\"}') ok", [u])).rows[0].ok).toBe(true);
    for (let n = 0; n < 2; n++) await db.query("select billing_record_event($1,'billing_subscription_cancelled','{\"by\":\"system\"}','sys-1')", [u]);
    expect((await db.query<{ ok: boolean }>("select billing_record_event($1,'billing_duplicate_purchase','{\"plan\":\"monthly\"}','dup-1') ok", [u])).rows[0].ok).toBe(true);
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}', 'billing_portal_opened {"target":"manage"}', 'billing_refund_requested {"plan":"monthly"}', 'billing_subscription_cancelled {"by":"system"}']);
    await expect(db.query("select billing_record_event($1,'billing_refunded')", [u])).rejects.toThrow(/billing_event_not_allowed/);
    await expect(db.query("select billing_record_event($1,'app_opened')", [u])).rejects.toThrow(/billing_event_not_allowed/);
    await expect(db.query("select billing_record_event($1,'billing_portal_opened','[]')", [u])).rejects.toThrow(/billing_event_invalid/);
  });
});

describe('refund claim', () => {
  it('claims a subscription payment inside 72 hours, once, and never twice for the same account', async () => {
    const u = await user();
    await setAccount(u, { subscription_id: 'sub-1', status: 'active', plan: 'annual', last_invoice_id: 'inv-7', last_payment_at: iso(-71 * 3_600_000), current_period_ends_at: iso(300 * DAY) });
    const claimed = (await db.query<{ c: Record<string, unknown> }>('select billing_claim_refund($1) c', [u])).rows[0].c;
    expect(claimed).toEqual({ kind: 'subscription', subscription_id: `sub-1-${u}`, invoice_id: 'inv-7', plan: 'annual', claim_key: expect.stringMatching(/^refund-requested:/) });
    await expect(db.query('select billing_claim_refund($1)', [u])).rejects.toThrow(/billing_refund_pending/);
    expect((await row(u)).refund_requested_at).not.toBeNull();
    expect((await row(u)).status).toBe('active'); // asking never changes entitlement
    // a refusal before anything was sent gives the claim and the self-service use back
    expect((await db.query<{ ok: boolean }>('select billing_release_refund($1,true) ok', [u])).rows[0].ok).toBe(true);
    expect((await db.query<{ ok: boolean }>('select billing_release_refund($1,true) ok', [u])).rows[0].ok).toBe(false);
    expect((await row(u)).self_refund_used_at).toBeNull();
    await db.query('select billing_claim_refund($1)', [u]);
    await setAccount(u, { refund_requested_at: null });
    await expect(db.query('select billing_claim_refund($1)', [u])).rejects.toThrow(/billing_refund_used/);
  });
  it('a confirmed-and-used refund cannot be released back', async () => {
    const u = await user();
    await setAccount(u, { subscription_id: 'sub-1', status: 'active', plan: 'monthly', last_invoice_id: 'inv-7', last_payment_at: iso(-3_600_000) });
    await db.query('select billing_claim_refund($1)', [u]);
    await applySub(u, { status: 'refunded', updated: '2026-10-19T00:00:02Z' }).catch(() => null);
    await setAccount(u, { refund_requested_at: null });
    expect((await db.query<{ ok: boolean }>('select billing_release_refund($1,true) ok', [u])).rows[0].ok).toBe(false);
    expect((await row(u)).self_refund_used_at).not.toBeNull();
  });
  it('claims a Lifetime order inside 72 hours', async () => {
    const u = await user();
    await setAccount(u, { lifetime_status: 'active', lifetime_order_id: 'ord-5', lifetime_paid_at: iso(-3_600_000) });
    expect((await db.query<{ c: Record<string, unknown> }>('select billing_claim_refund($1) c', [u])).rows[0].c).toEqual({ kind: 'lifetime', order_id: `ord-5-${u}`, claim_key: expect.stringMatching(/^refund-requested:/) });
  });
  it('is closed after 72 hours, without a paid invoice, for refunded plans and for deleting accounts', async () => {
    const closed = async (cols: Record<string, unknown>, message: RegExp) => {
      const u = await user(); await setAccount(u, cols);
      await expect(db.query('select billing_claim_refund($1)', [u]), JSON.stringify(cols)).rejects.toThrow(message);
      expect((await row(u)).self_refund_used_at ?? null).toBeNull();
    };
    await closed({ subscription_id: 's', status: 'active', last_invoice_id: 'i', last_payment_at: iso(-73 * 3_600_000) }, /billing_refund_window_closed/);
    await closed({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-73 * 3_600_000) }, /billing_refund_window_closed/);
    await closed({ subscription_id: 's', status: 'on_trial', trial_ends_at: iso(DAY) }, /billing_refund_window_closed/);
    await closed({ subscription_id: 's', status: 'refunded', last_invoice_id: 'i', last_payment_at: iso(-3_600_000) }, /billing_refund_window_closed/);
    await closed({ subscription_id: 's', status: 'active', last_invoice_id: 'i', last_payment_at: iso(-3_600_000), deleting: true }, /billing_refund_unavailable/);
    const missing = randomUUID();
    await db.query('insert into auth.users(id) values($1)', [missing]);
    await expect(db.query('select billing_claim_refund($1)', [missing])).rejects.toThrow(/billing_refund_unavailable/);
  });
});

describe('plan kind and hidden fair-use window', () => {
  const cases: [string, Record<string, unknown>, string][] = [
    ['deleting beats everything', { deleting: true, lifetime_status: 'active', status: 'active', current_period_ends_at: iso(DAY) }, 'lapsed'],
    ['lifetime', { lifetime_status: 'active' }, 'lifetime'],
    ['lifetime beats a live Pro', { lifetime_status: 'active', status: 'active', current_period_ends_at: iso(DAY) }, 'lifetime'],
    ['trial', { status: 'on_trial', trial_ends_at: iso(DAY), subscription_id: 's' }, 'trial'],
    ['trial ended', { status: 'on_trial', trial_ends_at: iso(-DAY), subscription_id: 's' }, 'lapsed'],
    ['pro', { status: 'active', current_period_ends_at: iso(DAY), subscription_id: 's', last_payment_at: iso(-DAY) }, 'pro'],
    ['pro period over', { status: 'active', current_period_ends_at: iso(-1000), subscription_id: 's' }, 'lapsed'],
    ['cancelled inside the period', { status: 'cancelled', current_period_ends_at: iso(DAY), subscription_id: 's', last_payment_at: iso(-DAY) }, 'cancelled'],
    ['cancelled after the period', { status: 'cancelled', current_period_ends_at: iso(-1000), subscription_id: 's' }, 'lapsed'],
    ['past_due inside 16 days', { status: 'past_due', current_period_ends_at: iso(-10 * DAY), subscription_id: 's', last_payment_at: iso(-40 * DAY) }, 'past_due'],
    ['payment_pending inside 16 days', { status: 'payment_pending', current_period_ends_at: iso(-3 * DAY), subscription_id: 's', last_payment_at: iso(-40 * DAY) }, 'past_due'],
    ['past_due beyond 16 days', { status: 'past_due', current_period_ends_at: iso(-17 * DAY), subscription_id: 's' }, 'lapsed'],
    ['past_due without a paid period', { status: 'past_due', subscription_id: 's' }, 'lapsed'],
    ['beta', { legacy_beta: true }, 'beta'],
    ['beta with a future notice', { legacy_beta: true, notice_ends_at: iso(DAY) }, 'beta'],
    ['beta after the notice', { legacy_beta: true, notice_ends_at: iso(-DAY) }, 'none'],
    ['beta after the notice with a past plan', { legacy_beta: true, notice_ends_at: iso(-DAY), subscription_id: 's', status: 'expired' }, 'lapsed'],
    ['paying beta account', { legacy_beta: true, status: 'active', current_period_ends_at: iso(DAY), subscription_id: 's' }, 'pro'],
    ['expired', { status: 'expired', subscription_id: 's' }, 'lapsed'],
    ['refunded lifetime', { lifetime_status: 'refunded' }, 'lapsed'],
    ['nothing', {}, 'none'],
  ];
  it.each(cases)('%s -> %s', async (_label, cols, expected) => {
    const u = await user(); await setAccount(u, cols);
    expect(await kind(u)).toBe(expected);
  });

  it('agrees with planState() in src/lib/billing/state.ts for every case', async () => {
    for (const [label, cols, expected] of cases) {
      const u = await user(); await setAccount(u, cols);
      const stored = await row(u);
      const account = Object.fromEntries(Object.entries(stored).map(([k, v]) => [k, v instanceof Date ? v.toISOString() : v])) as unknown as BillingAccount;
      expect(planState(account, Date.now(), { billing: true, byok: true }).state, label).toBe(expected);
    }
  });

  const windowOf = async (u: string, monthly = 10, trial = 2) =>
    (await db.query<{ cap: string; starts_at: Date; kind: string }>('select cap::text,starts_at,kind from billing_spend_window_v2($1,$2,$3)', [u, monthly, trial])).rows[0];
  it('paid kinds get the monthly cap, trial the trial cap, beta the legacy window', async () => {
    const pro = await user(); await setAccount(pro, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    const cancelled = await user(); await setAccount(cancelled, { status: 'cancelled', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    const late = await user(); await setAccount(late, { status: 'past_due', current_period_ends_at: iso(-DAY), last_payment_at: iso(-31 * DAY) });
    const trial = await user(); await setAccount(trial, { status: 'on_trial', trial_ends_at: iso(DAY), first_subscription_at: iso(-DAY) });
    const beta = await user(); await setAccount(beta, { legacy_beta: true });
    for (const u of [pro, cancelled, late]) expect(await windowOf(u)).toMatchObject({ cap: '10' });
    expect((await windowOf(pro)).starts_at.toISOString()).toBe(new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1)).toISOString());
    expect(await windowOf(trial)).toMatchObject({ cap: '2', kind: 'trial' });
    expect(await windowOf(beta)).toMatchObject({ cap: '10', kind: 'beta' });
  });
  it('closes lifetime with byok_required and everything else without access with subscription_required', async () => {
    const life = await user(); await setAccount(life, { lifetime_status: 'active' });
    await expect(windowOf(life)).rejects.toThrow(/byok_required/);
    for (const cols of [{}, { status: 'expired', subscription_id: 's' }, { deleting: true, status: 'active', current_period_ends_at: iso(DAY) }, { legacy_beta: true, notice_ends_at: iso(-DAY) }]) {
      const u = await user(); await setAccount(u, cols);
      await expect(windowOf(u), JSON.stringify(cols)).rejects.toThrow(/subscription_required/);
    }
    await expect(windowOf(randomUUID())).rejects.toThrow(/subscription_required/);
  });
  it('accepts operator caps up to 100 and rejects more, zero and nulls', async () => {
    const u = await user(); await setAccount(u, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    expect(await windowOf(u, 100, 100)).toMatchObject({ cap: '100' });
    for (const [m, t] of [[101, 2], [10, 101], [0, 2], [10, 0]]) await expect(windowOf(u, m, t), `${m}/${t}`).rejects.toThrow(/ai_invalid_budget/);
    await expect(db.query('select * from billing_spend_window_v2($1,null,2)', [u])).rejects.toThrow(/ai_invalid_budget/);
  });
});

describe('managed reservations', () => {
  const reserve = (u: string, usd: number, monthly = 10, trial = 2) =>
    db.query("select reserve_billing_ai_spend_v2($1,$2,'chat','m',$3,$4,$5)", [u, randomUUID(), usd, monthly, trial]);
  const attempts = async (u: string) => (await db.query<{ n: number }>('select count(*)::int n from ai_spend_attempts where user_id=$1', [u])).rows[0].n;

  it('never reserves managed cost for a Lifetime account (I15 held by the database)', async () => {
    const u = await user(); await setAccount(u, { lifetime_status: 'active' });
    await expect(reserve(u, 0.01)).rejects.toThrow(/byok_required/);
    expect(await attempts(u)).toBe(0);
  });
  it('stops accounts without access', async () => {
    for (const cols of [{}, { status: 'expired', subscription_id: 's' }, { deleting: true, lifetime_status: 'active' }]) {
      const u = await user(); await setAccount(u, cols);
      await expect(reserve(u, 0.01), JSON.stringify(cols)).rejects.toThrow(/subscription_required|byok_required/);
      expect(await attempts(u)).toBe(0);
    }
  });
  it('caps a trial at its allowance and a paid month at the monthly cap, counting unresolved holds across months', async () => {
    const trial = await user(); await setAccount(trial, { status: 'on_trial', trial_ends_at: iso(DAY), first_subscription_at: iso(-DAY) });
    await reserve(trial, 2);
    await expect(reserve(trial, 0.01)).rejects.toThrow(/ai_budget_exhausted/);
    const pro = await user(); await setAccount(pro, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd,created_at) values($1,$2,'chat','m',10,10,now()-interval '2 months')", [randomUUID(), pro]);
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd,created_at) values($1,$2,'chat','m',4,null,now()-interval '2 months')", [randomUUID(), pro]);
    await reserve(pro, 6);
    await expect(reserve(pro, 0.01)).rejects.toThrow(/ai_budget_exhausted/);
  });
  it('reserves only below the operator cap and shares the global limits with every other account', async () => {
    const pro = await user(); await setAccount(pro, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    await reserve(pro, 10, 100, 2);
    await reserve(pro, 10, 100, 2);
    await db.query('update ai_budget_policy set global_daily_usd=(select coalesce(sum(coalesce(cost_usd,reserved_usd)),0) from ai_spend_attempts where cost_usd is null or created_at>=date_trunc(\'day\',now() at time zone \'UTC\') at time zone \'UTC\')');
    try { await expect(reserve(pro, 0.01, 100, 2)).rejects.toThrow(/ai_global_daily_budget_exhausted/); }
    finally { await db.query('update ai_budget_policy set global_daily_usd=1000'); }
    await db.query('update ai_budget_policy set global_total_usd=(select sum(coalesce(cost_usd,reserved_usd)) from ai_spend_attempts)');
    try { await expect(reserve(pro, 0.01, 100, 2)).rejects.toThrow(/ai_global_budget_exhausted/); }
    finally { await db.query('update ai_budget_policy set global_total_usd=1000'); }
  });
  it('freezes an account whose provider cost exceeded its reservation', async () => {
    const u = await user(); await setAccount(u, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd) values($1,$2,'chat','m',0.1,0.5)", [randomUUID(), u]);
    await expect(reserve(u, 0.01)).rejects.toThrow(/ai_provider_bound_breached/);
  });
  it('rejects absurd reservations and caps', async () => {
    const u = await user(); await setAccount(u, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    for (const usd of [0, -1, 10.01]) await expect(reserve(u, usd)).rejects.toThrow(/ai_invalid_reservation/);
    await expect(reserve(u, 0.01, 101)).rejects.toThrow(/ai_invalid_budget/);
  });
  it('grandfathered beta keeps the old daily and lifetime limits through the legacy function', async () => {
    const u = await user(); await setAccount(u, { legacy_beta: true });
    await db.query('update ai_budget_policy set user_daily_usd=0.1');
    try { await expect(reserve(u, 0.2)).rejects.toThrow(/ai_user_daily_budget_exhausted/); }
    finally { await db.query('update ai_budget_policy set user_daily_usd=1000'); }
    await reserve(u, 0.2);
    expect(await attempts(u)).toBe(1);
  });
  it('summarises the hidden window: available, then exhausted until next month; beta delegates', async () => {
    const u = await user(); await setAccount(u, { status: 'active', current_period_ends_at: iso(DAY), last_payment_at: iso(-DAY) });
    const summary = async (id: string, monthly = 10) => (await db.query<{ s: Record<string, unknown> }>('select billing_spend_summary_v2($1,$2,2) s', [id, monthly])).rows[0].s;
    expect(await summary(u)).toMatchObject({ status: 'available', cap_usd: 10, remaining_usd: 10, pending_count: 0 });
    await reserve(u, 10);
    expect(await summary(u)).toMatchObject({ status: 'exhausted', remaining_usd: 0, pending_count: 1 });
    expect(await summary(u, 100)).toMatchObject({ status: 'available', remaining_usd: 90 });
    const beta = await user(); await setAccount(beta, { legacy_beta: true });
    expect(await summary(beta)).toMatchObject({ cap_usd: 10, status: 'available' });
    const none = await user(); await setAccount(none, {});
    await expect(summary(none)).rejects.toThrow(/subscription_required/);
  });
});

describe('token usage', () => {
  it('records tokens once per attempt, for the owner only, and sums since a date', async () => {
    const a = await user(), b = await user();
    const mine = randomUUID(), old = randomUUID();
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd) values($1,$2,'chat','m',1,0.5)", [mine, a]);
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd,created_at) values($1,$2,'chat','m',1,0.5,now()-interval '3 months')", [old, a]);
    await db.query('select record_ai_spend_tokens($1,$2,100,40)', [a, mine]);
    await db.query('select record_ai_spend_tokens($1,$2,999,999)', [a, mine]); // second write ignored
    await db.query('select record_ai_spend_tokens($1,$2,50,0)', [b, mine]); // not the owner: ignored
    await db.query('select record_ai_spend_tokens($1,$2,7,3)', [a, old]);
    const since = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1)).toISOString();
    expect((await db.query<{ t: Record<string, number> }>('select billing_usage_tokens($1,$2) t', [a, since])).rows[0].t).toEqual({ prompt_tokens: 100, completion_tokens: 40 });
    expect((await db.query<{ t: Record<string, number> }>('select billing_usage_tokens($1,$2) t', [b, since])).rows[0].t).toEqual({ prompt_tokens: 0, completion_tokens: 0 });
    await expect(db.query('select record_ai_spend_tokens($1,$2,-1,0)', [a, mine])).rejects.toThrow(/ai_invalid_tokens/);
    await expect(db.query('select record_ai_spend_tokens($1,$2,null,0)', [a, mine])).rejects.toThrow(/ai_invalid_tokens/);
  });
});

describe('legacy beta conversion', () => {
  let fresh: PGlite;
  beforeAll(async () => {
    fresh = await createLocalSupabase();
    // The test stub of auth.users has no created_at; the real table does.
    await fresh.exec('alter table auth.users add column if not exists created_at timestamptz not null default now()');
  }, 60_000);
  afterAll(async () => { await fresh?.close(); });
  const mk = async (createdAt: string, cols: Record<string, unknown> = {}) => {
    const id = randomUUID();
    await fresh.query('insert into auth.users(id,created_at) values($1,$2)', [id, createdAt]);
    const keys = Object.keys(cols);
    if (keys.length || cols) await fresh.query(`insert into billing_accounts(user_id${keys.map((k) => ',' + k).join('')}) values($1${keys.map((_, i) => `,$${i + 2}`).join('')})`, [id, ...keys.map((k) => cols[k])]);
    return id;
  };
  const legacy = async (id: string) => (await fresh.query<{ legacy_beta: boolean | null }>('select legacy_beta from billing_accounts where user_id=$1', [id])).rows[0]?.legacy_beta ?? null;
  const markedEvents = async () => (await fresh.query<{ n: number }>("select count(*)::int n from metric_events where type='billing_legacy_marked'")).rows[0].n;

  it('marks accounts created before the cutoff that never bought anything, once, with one event each', async () => {
    const at = (offsetMs: number) => new Date(Date.now() + offsetMs).toISOString();
    const HOURS = 3_600_000;
    const noRow = await mk(at(-30 * 24 * HOURS));
    await fresh.query('delete from billing_accounts where user_id=$1', [noRow]);
    const plain = await mk(at(-29 * 24 * HOURS));
    const after = await mk(at(-1 * HOURS));
    const subscribed = await mk(at(-28 * 24 * HOURS), { subscription_id: 's', status: 'expired' });
    const lifetime = await mk(at(-27 * 24 * HOURS), { lifetime_status: 'active', lifetime_order_id: 'o' });
    const deleting = await mk(at(-26 * 24 * HOURS), { deleting: true });
    const already = await mk(at(-25 * 24 * HOURS), { legacy_beta: true });
    await fresh.query('delete from billing_accounts where user_id in ($1,$2)', [after, noRow]);
    const cutoff = at(-2 * HOURS);
    expect((await fresh.query<{ n: number }>('select billing_seed_legacy($1) n', [cutoff])).rows[0].n).toBe(2);
    expect(await legacy(noRow)).toBe(true);
    expect(await legacy(plain)).toBe(true);
    expect(await legacy(after)).toBeNull();
    expect(await legacy(subscribed)).toBe(false);
    expect(await legacy(lifetime)).toBe(false);
    expect(await legacy(deleting)).toBe(false);
    expect(await legacy(already)).toBe(true);
    expect(await markedEvents()).toBe(2);
    expect((await fresh.query<{ n: number }>('select billing_seed_legacy($1) n', [cutoff])).rows[0].n).toBe(0);
    expect(await markedEvents()).toBe(2);
    // a later cutoff covers the account created in between
    expect((await fresh.query<{ n: number }>('select billing_seed_legacy(now()) n')).rows[0].n).toBe(1);
    expect(await legacy(after)).toBe(true);
    await expect(fresh.query('select billing_seed_legacy(null)')).rejects.toThrow(/billing_cutoff_required/);
  });
  it('schedules the notice only 30 days or more ahead, only for beta accounts without one, one event each', async () => {
    const day = 86_400_000;
    for (const days of [0, 1, 29]) await expect(fresh.query('select billing_schedule_legacy_notice($1)', [new Date(Date.now() + days * day).toISOString()]), String(days)).rejects.toThrow(/billing_notice_too_soon/);
    await expect(fresh.query('select billing_schedule_legacy_notice(null)')).rejects.toThrow(/billing_notice_too_soon/);
    const set = await mk('2026-09-07T00:00:00Z', { legacy_beta: true, notice_ends_at: '2027-01-01T00:00:00Z' });
    const when = new Date(Date.now() + 30 * day + 60_000).toISOString();
    const eligible = (await fresh.query<{ n: number }>('select count(*)::int n from billing_accounts where legacy_beta and notice_ends_at is null and not deleting')).rows[0].n;
    expect((await fresh.query<{ n: number }>('select billing_schedule_legacy_notice($1) n', [when])).rows[0].n).toBe(eligible);
    expect(eligible).toBeGreaterThan(0);
    expect((await fresh.query<{ n: Date }>('select notice_ends_at n from billing_accounts where user_id=$1', [set])).rows[0].n.toISOString()).toBe('2027-01-01T00:00:00.000Z');
    expect((await fresh.query<{ n: number }>("select count(*)::int n from metric_events where type='billing_notice_scheduled'")).rows[0].n).toBe(eligible);
    expect((await fresh.query<{ n: number }>('select billing_schedule_legacy_notice($1) n', [when])).rows[0].n).toBe(0);
  });
});

describe('missed-event sweep claim', () => {
  let sweepDb: PGlite;
  beforeAll(async () => { sweepDb = await createLocalSupabase(); }, 60_000);
  afterAll(async () => { await sweepDb?.close(); });
  let sequence = 0;
  const make = async (cols: Record<string, unknown>) => {
    const id = randomUUID();
    await sweepDb.query('insert into auth.users(id) values($1)', [id]);
    const unique = Object.fromEntries(Object.entries(cols).map(([k, v]) => [k, (k === 'subscription_id' || k === 'lifetime_order_id') && typeof v === 'string' ? `${v}-${++sequence}` : v]));
    const keys = Object.keys(unique);
    await sweepDb.query(`insert into billing_accounts(user_id${keys.map((k) => ',' + k).join('')}) values($1${keys.map((_, i) => `,$${i + 2}`).join('')})`, [id, ...keys.map((k) => unique[k])]);
    return id;
  };
  const claim = async (limit = 20) => (await sweepDb.query<{ user_id: string; subscription_id: string | null; lifetime_order_id: string | null; refund_stale: boolean }>('select * from billing_sweep_claim($1)', [limit])).rows;

  it('claims exactly the accounts whose provider state can drift, once a day', async () => {
    const picked = {
      trial: await make({ subscription_id: 's', status: 'on_trial', trial_ends_at: iso(DAY) }),
      cancelled: await make({ subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(DAY) }),
      pastDue: await make({ subscription_id: 's', status: 'past_due', current_period_ends_at: iso(-DAY) }),
      pending: await make({ subscription_id: 's', status: 'payment_pending', current_period_ends_at: iso(-DAY) }),
      expiring: await make({ subscription_id: 's', status: 'active', current_period_ends_at: iso(DAY / 2) }),
      lapsedActive: await make({ subscription_id: 's', status: 'active', current_period_ends_at: iso(-DAY) }),
      freshLifetime: await make({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-3_600_000) }),
      staleRefund: await make({ subscription_id: 's', status: 'expired', refund_requested_at: iso(-2 * 3_600_000), self_refund_used_at: iso(-2 * 3_600_000) }),
    };
    // none of these may be claimed (the exact-list assertion below proves it)
    await Promise.all([
      make({ subscription_id: 's', status: 'active', current_period_ends_at: iso(20 * DAY) }),
      make({ subscription_id: 's', status: 'expired' }),
      make({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-80 * 3_600_000) }),
      make({}),
      make({ legacy_beta: true }),
      make({ deleting: true, subscription_id: 's', status: 'on_trial', trial_ends_at: iso(DAY) }),
      make({ subscription_id: 's', status: 'cancelled', current_period_ends_at: iso(DAY), last_swept_at: iso(-3_600_000) }),
      make({ subscription_id: 's', status: 'active', current_period_ends_at: iso(20 * DAY), refund_requested_at: iso(-1_800_000), self_refund_used_at: iso(-1_800_000) }),
    ]);
    const rows = await claim(100);
    expect(rows.map((r) => r.user_id).sort()).toEqual(Object.values(picked).sort());
    expect(rows.find((r) => r.user_id === picked.freshLifetime)).toMatchObject({ subscription_id: null, refund_stale: false });
    expect(rows.find((r) => r.user_id === picked.trial)!.subscription_id).toMatch(/^s-\d+$/);
    expect(rows.find((r) => r.user_id === picked.staleRefund)!.refund_stale).toBe(true);
    // claimed is not done: a lease keeps overlapping runs apart, but nothing is stamped as swept yet
    expect(await claim(100)).toEqual([]);
    const count = async (where: string) => (await sweepDb.query<{ n: number }>(`select count(*)::int n from billing_accounts where ${where} and user_id = any($1)`, [Object.values(picked)])).rows[0].n;
    expect(await count('sweep_claimed_at is not null')).toBe(Object.values(picked).length);
    expect(await count('last_swept_at is not null')).toBe(0);
    for (const id of Object.values(picked)) await sweepDb.query('select billing_sweep_done($1,true)', [id]);
    expect(await count('last_swept_at is not null and sweep_claimed_at is null')).toBe(Object.values(picked).length);
    await sweepDb.query('update billing_accounts set sweep_claimed_at=null where user_id=any($1)', [Object.values(picked)]);
    expect(await claim(100)).toEqual([]); // swept today
  });
  it('an account skipped before it was swept comes back after the lease, also at the edge of the 72-hour refund window', async () => {
    const lifetime = await make({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-72 * 3_600_000 + 60_000) });
    expect((await claim()).map((r) => r.user_id)).toEqual([lifetime]);
    expect(await claim()).toEqual([]); // leased
    await sweepDb.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes' where user_id=$1", [lifetime]);
    expect((await claim()).map((r) => r.user_id)).toEqual([lifetime]); // never stamped done: due again
    // the window closes while that claim is still unfinished: an unfinished claim stays retryable outside the window (contract ch.23)
    await sweepDb.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes',lifetime_paid_at=now()-interval '73 hours' where user_id=$1", [lifetime]);
    expect((await claim()).map((r) => r.user_id)).toEqual([lifetime]);
    await sweepDb.query("update billing_accounts set sweep_claimed_at=null,lifetime_paid_at=now()-interval '73 hours' where user_id=$1", [lifetime]);
    expect(await claim()).toEqual([]); // outside the window and never needing the daily pass any more
    await sweepDb.query("delete from billing_accounts where user_id=$1", [lifetime]);
  });
  it('an unfinished claim is retried even when the account was swept earlier today (recent stamp) and the window is over', async () => {
    const lifetime = await make({ lifetime_status: 'active', lifetime_order_id: 'o', lifetime_paid_at: iso(-72 * 3_600_000 + 60_000), last_swept_at: iso(-2 * 3_600_000) });
    expect(await claim()).toEqual([]); // swept two hours ago, nothing is due
    await sweepDb.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes',lifetime_paid_at=now()-interval '73 hours' where user_id=$1", [lifetime]);
    expect((await claim()).map((r) => r.user_id)).toEqual([lifetime]);
    await sweepDb.query('select billing_sweep_done($1,true)', [lifetime]);
    expect(await claim()).toEqual([]); // finished: done means done
    await sweepDb.query('delete from billing_accounts where user_id=$1', [lifetime]);
  });
  it('a failed account backs off for an hour instead of being retried every run or starving the others', async () => {
    const u = await make({ subscription_id: 's', status: 'on_trial', trial_ends_at: iso(DAY) });
    expect((await claim()).map((r) => r.user_id)).toEqual([u]);
    await sweepDb.query('select billing_sweep_done($1,false)', [u]);
    expect((await sweepDb.query<{ n: number }>('select count(*)::int n from billing_accounts where user_id=$1 and last_swept_at is null', [u])).rows[0].n).toBe(1);
    await sweepDb.query("update billing_accounts set sweep_claimed_at=now()+interval '30 minutes' where user_id=$1", [u]);
    expect(await claim()).toEqual([]);
    await sweepDb.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes' where user_id=$1", [u]);
    expect((await claim()).map((r) => r.user_id)).toEqual([u]);
    await sweepDb.query('select billing_sweep_done($1,true)', [u]);
  });
  it('keeps looking at a refunded subscription for 35 days: the provider cancel may have failed and a renewal would bill again', async () => {
    const recent = await make({ subscription_id: 's', status: 'refunded', provider_updated_at: iso(-3 * DAY) });
    const old = await make({ subscription_id: 's', status: 'refunded', provider_updated_at: iso(-40 * DAY) });
    const claimed = (await claim()).map((r) => r.user_id);
    expect(claimed).toContain(recent);
    expect(claimed).not.toContain(old);
    await sweepDb.query('select billing_sweep_done($1,true)', [recent]);
  });
  it('re-claims an unresolved refund claim after half an hour even though the daily stamp is fresh', async () => {
    const u = await make({ subscription_id: 's', status: 'active', current_period_ends_at: iso(20 * DAY), refund_requested_at: iso(-2 * 3_600_000), self_refund_used_at: iso(-2 * 3_600_000), last_swept_at: iso(-40 * 60_000) });
    expect((await claim()).map((r) => r.user_id)).toEqual([u]);
    expect(await claim()).toEqual([]);
    await sweepDb.query('select billing_sweep_done($1,true)', [u]);
  });
  it('honours the limit, oldest stamp first, and caps a huge request', async () => {
    const ids: string[] = [];
    for (let n = 0; n < 5; n++) ids.push(await make({ subscription_id: 's', status: 'on_trial', trial_ends_at: iso(DAY), last_swept_at: iso(-(2 + n) * DAY) }));
    const first = await claim(2);
    expect(first.map((r) => r.user_id).sort()).toEqual([ids[4], ids[3]].sort());
    expect((await claim(1_000_000)).map((r) => r.user_id).sort()).toEqual([ids[0], ids[1], ids[2]].sort());
    expect(await claim(0)).toEqual([]);
    for (const id of ids) await sweepDb.query('select billing_sweep_done($1,true)', [id]);
  });
});

// ── review round 1 (contract ch.22) ───────────────────────────────────────
describe('a subscription is bound to the intent that was issued for it (trial and first-month code once)', () => {
  it('rejects a trial that the intent never offered, records the review event once and never attaches the subscription', async () => {
    const u = await user();
    const i = await intent(u, 'pro', false, { trial: false, discount: false });
    expect(await applySub(u, { intent: i, status: 'on_trial', trial: iso(3 * DAY) })).toBe('rejected');
    expect(await row(u)).toMatchObject({ subscription_id: null, first_subscription_at: null });
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
    // every later delivery of the same provider subscription is refused without a second event, whatever it says now
    expect(await applySub(u, { intent: i, status: 'cancelled', ends: null, updated: '2026-10-19T00:00:09Z' })).toBe('rejected_known');
    expect(await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-x' })).toBe('rejected_known');
    expect(await row(u)).toMatchObject({ subscription_id: null, first_subscription_at: null });
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
    // the intent was not spent: the real checkout of this account still works
    expect(await applySub(u, { sub: 'sub-real', intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1' })).toBe('applied');
  });
  it('the retry of the very event that was rejected is still "rejected_known", so the caller cancels the provider subscription again if the first cancel failed', async () => {
    const u = await user();
    const i = await intent(u, 'pro', false, { trial: false, discount: false });
    const event = randomUUID();
    expect(await applySub(u, { event, intent: i, status: 'on_trial', trial: iso(3 * DAY) })).toBe('rejected');
    expect(await applySub(u, { event, intent: i, status: 'on_trial', trial: iso(3 * DAY) })).toBe('rejected_known');
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
  });
  it('a trial on an account that already had a subscription is clear tampering: the server never issues that link — refused for good and flagged', async () => {
    const u = await user();
    await setAccount(u, { subscription_id: 'old', status: 'expired', first_subscription_at: iso(-30 * DAY) });
    const stale = await intent(u, 'pro', false, { trial: true, discount: true });
    expect(await applySub(u, { sub: 'again', intent: stale, status: 'on_trial', trial: iso(3 * DAY) })).toBe('rejected');
    expect((await row(u)).subscription_id).toBe(`old-${u}`);
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
    expect(await applySub(u, { sub: 'again', intent: stale, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', updated: '2026-10-19T00:00:09Z' })).toBe('rejected_known');
  });
  it('a trial on an intent that is already bound to a different subscription is clear tampering, whatever the account history says (trial_reused)', async () => {
    const u = await user();
    await setAccount(u, {});
    const used = await intent(u, 'pro', true, { trial: true, discount: true });
    await db.query('update billing_checkout_intents set bound_subscription_id=$2 where id=$1', [used, `earlier-${u}`]);
    expect(await applySub(u, { sub: 'second', intent: used, status: 'on_trial', trial: iso(3 * DAY) })).toBe('rejected');
    expect((await row(u)).subscription_id).toBeNull();
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
    // the same intent carrying an order (a Lifetime-bound link) is just as used
    const ordered = await intent(u, 'pro', true, { trial: true, discount: true });
    await db.query("update billing_checkout_intents set bound_order_id='some-order' where id=$1", [ordered]);
    expect(await applySub(u, { sub: 'third', intent: ordered, status: 'on_trial', trial: iso(3 * DAY) })).toBe('rejected');
  });
  it('a discounted first payment on an intent that is already bound to a different subscription is clear tampering (discount_reused)', async () => {
    const u = await user();
    await setAccount(u, {});
    const used = await intent(u, 'pro', true, { trial: true, discount: true });
    await db.query('update billing_checkout_intents set bound_subscription_id=$2 where id=$1', [used, `earlier-${u}`]);
    expect(await applySub(u, { sub: 'second', intent: used, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true })).toBe('rejected');
    expect((await row(u)).subscription_id).toBeNull();
    expect(await events(u)).toEqual(['billing_duplicate_purchase {"plan":"monthly"}']);
    // the same used intent at full price is only reviewed: the payment is real
    expect(await applySub(u, { sub: 'fourth', intent: used, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-2', updated: '2026-10-19T00:00:09Z' })).toBe('applied');
    expect(await events(u)).toContain('billing_review_needed {"plan":"monthly","reason":"intent_bound_elsewhere"}');
  });
  it('an intent that was never issued (no URL) is attached and reviewed; one that is merely spent or expired (not bound to anything) is simply accepted', async () => {
    const noUrl = await user();
    expect(await applySub(noUrl, { intent: await intent(noUrl, 'pro', false, { url: null }), status: 'on_trial', trial: iso(DAY) })).toBe('applied');
    expect(await events(noUrl)).toEqual(expect.arrayContaining(['billing_review_needed {"plan":"monthly","reason":"intent_not_issued"}']));
    const spent = await user();
    expect(await applySub(spent, { intent: await intent(spent, 'pro', true), status: 'on_trial', trial: iso(DAY) })).toBe('applied');
    expect(await events(spent)).toEqual(['billing_trial_started {"plan":"monthly"}']);
  });
  it('a payment discounted without the first-month offer is rejected; the offered one and later invoices are not', async () => {
    const plain = await user();
    const noOffer = await intent(plain, 'pro', false, { trial: false, discount: false });
    expect(await applySub(plain, { intent: noOffer, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true })).toBe('rejected');
    expect((await row(plain)).subscription_id).toBeNull();
    const ok = await user();
    const offered = await intent(ok, 'pro');
    expect(await applySub(ok, { intent: offered, status: 'on_trial', trial: iso(3 * DAY) })).toBe('applied');
    expect(await applySub(ok, { intent: offered, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true, updated: '2026-10-19T00:00:02Z' })).toBe('applied');
    // the renewal is full price; a discounted later invoice (operator coupon) is not a first-month abuse
    expect(await applySub(ok, { status: 'active', ends: iso(60 * DAY), payment: iso(1000), invoice: 'inv-2', discounted: true, updated: '2026-10-19T00:00:03Z' })).toBe('applied');
  });
  it('a discounted first payment of an already bound subscription, read without any reference, is judged from the stored binding: accepted, nothing cancelled', async () => {
    const u = await user();
    await setAccount(u, { subscription_id: 'sub-1', status: 'on_trial', trial_ends_at: iso(DAY), first_subscription_at: iso(-DAY), plan: 'monthly' });
    expect(await applySub(u, { intent: null, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true })).toBe('applied');
    expect((await row(u)).status).toBe('active');
    expect(await events(u)).not.toContain('billing_duplicate_purchase {"plan":"monthly"}');
  });
  it('legitimate flows keep working: trial then paid with the offered code, and a restart without any offer', async () => {
    const u = await user();
    const i = await intent(u, 'pro');
    expect(await applySub(u, { intent: i, status: 'on_trial', trial: iso(3 * DAY) })).toBe('applied');
    expect(await applySub(u, { status: 'expired', updated: '2026-10-19T00:00:02Z' })).toBe('applied');
    const restart = await intent(u, 'pro', false, { trial: false, discount: false });
    expect(await applySub(u, { sub: 'sub-2', intent: restart, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-9', updated: '2026-10-19T00:00:03Z' })).toBe('applied');
  });
});

describe('a Lifetime refund that arrives before its paid snapshot', () => {
  it('is recorded against the checkout intent and the late paid snapshot cannot open it', async () => {
    const u = await user();
    const i = await intent(u, 'lifetime');
    expect(await applyLife(u, { intent: i, status: 'refunded', updated: '2026-10-19T00:00:20Z' })).toBe('applied');
    expect(await row(u)).toMatchObject({ lifetime_status: 'refunded', lifetime_order_id: `ord-1-${u}` });
    expect(await kind(u)).toBe('lapsed');
    // a paid snapshot with an older or even a newer clock reading still stays closed: a refunded order is final
    expect(await applyLife(u, { intent: i, status: 'active', updated: '2026-10-19T00:00:10Z' })).toBe('stale');
    expect(await applyLife(u, { intent: i, status: 'active', updated: '2026-10-19T00:00:30Z' })).toBe('stale');
    expect(await kind(u)).toBe('lapsed');
    expect(await events(u)).toEqual([]);
  });
  it('without a usable intent it is still refused, and a refund of a different order never touches an active entitlement', async () => {
    const a = await user();
    await setAccount(a, {});
    await expect(applyLife(a, { status: 'refunded' })).rejects.toThrow(/billing_order_unknown/);
    await expect(applyLife(a, { status: 'refunded', intent: await intent(a, 'lifetime', false, { url: null }) })).rejects.toThrow(/billing_order_unknown/);
    const b = await user();
    await applyLife(b, { intent: await intent(b, 'lifetime') });
    expect(await applyLife(b, { order: 'other', status: 'refunded', intent: await intent(b, 'lifetime', true), updated: '2026-10-19T00:00:50Z' })).toBe('stale');
    expect(await kind(b)).toBe('lifetime');
  });
});

describe('self-service refund use is kept unless nothing was sent', () => {
  it('releasing without clearing the use keeps the one self-service refund spent', async () => {
    const u = await user();
    await setAccount(u, { subscription_id: 'sub-1', status: 'active', plan: 'monthly', last_invoice_id: 'inv-7', last_payment_at: iso(-3_600_000) });
    await db.query('select billing_claim_refund($1)', [u]);
    expect((await db.query<{ ok: boolean }>('select billing_release_refund($1,false) ok', [u])).rows[0].ok).toBe(true);
    expect(await row(u)).toMatchObject({ refund_requested_at: null });
    expect((await row(u)).self_refund_used_at).not.toBeNull();
    await expect(db.query('select billing_claim_refund($1)', [u])).rejects.toThrow(/billing_refund_used/);
  });
  it('the claim key is stable so the request event is written once whichever path confirms the refund first', async () => {
    const u = await user();
    await setAccount(u, { subscription_id: 'sub-1', status: 'active', plan: 'monthly', last_invoice_id: 'inv-7', last_payment_at: iso(-3_600_000) });
    const claimed = (await db.query<{ c: { claim_key: string } }>('select billing_claim_refund($1) c', [u])).rows[0].c;
    expect(claimed.claim_key).toMatch(/^refund-requested:/);
    // the request path wrote it first ...
    await db.query("select billing_record_event($1,'billing_refund_requested','{\"plan\":\"monthly\"}',$2)", [u, claimed.claim_key]);
    // ... and the provider's confirmation (the other path) must not count it a second time
    await applySub(u, { status: 'refunded', updated: '2026-10-19T00:00:02Z' }).catch(() => null);
    const types = (await db.query<{ type: string }>("select type from metric_events where user_id=$1 and type='billing_refund_requested'", [u])).rows;
    expect(types).toHaveLength(1);
  });
  it('a confirmed refund whose request event was lost still counts the request exactly once', async () => {
    const u = await user();
    const i = await intent(u, 'pro');
    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(-1000), invoice: 'inv-1', updated: '2026-10-19T00:00:01Z' });
    await db.query('select billing_claim_refund($1)', [u]);
    await applySub(u, { status: 'refunded', updated: '2026-10-19T00:00:02Z' });
    await applySub(u, { status: 'refunded', updated: '2026-10-19T00:00:03Z' });
    expect((await events(u)).filter((e) => e.startsWith('billing_refund_requested'))).toEqual(['billing_refund_requested {"plan":"monthly"}']);
    const life = await user();
    await setAccount(life, {});
    await applyLife(life, { intent: await intent(life, 'lifetime') });
    await db.query('select billing_claim_refund($1)', [life]);
    await applyLife(life, { status: 'refunded', updated: '2026-10-19T00:00:20Z' });
    expect((await events(life)).filter((e) => e.startsWith('billing_refund_requested'))).toEqual(['billing_refund_requested {"plan":"lifetime"}']);
  });
});

describe('legacy conversion order and the hidden cap', () => {
  let ldb: PGlite;
  beforeAll(async () => {
    ldb = await createLocalSupabase();
    await ldb.exec('alter table auth.users add column if not exists created_at timestamptz not null default now()');
  }, 60_000);
  afterAll(async () => { await ldb?.close(); });
  const mk = async (createdAt: string) => {
    const id = randomUUID();
    await ldb.query('insert into auth.users(id,created_at) values($1,$2)', [id, createdAt]);
    return id;
  };
  const notice = async (id: string) => (await ldb.query<{ n: Date | null }>('select notice_ends_at n from billing_accounts where user_id=$1', [id])).rows[0]?.n ?? null;

  it('rejects a cutoff in the future', async () => {
    await expect(ldb.query("select billing_seed_legacy(now()+interval '1 minute')")).rejects.toThrow(/billing_cutoff_future/);
    await expect(ldb.query("select billing_seed_legacy(now()+interval '30 days')")).rejects.toThrow(/billing_cutoff_future/);
    await ldb.query('select billing_seed_legacy(now())');
  });
  it('seeds first, notifies second: accounts seeded after the notice get at least 30 days from their own seeding', async () => {
    const early = await mk('2026-09-01T00:00:00Z');
    await ldb.query('select billing_seed_legacy(now())');
    const day = 86_400_000;
    const ends = new Date(Date.now() + 45 * day);
    await ldb.query('select billing_schedule_legacy_notice($1)', [ends.toISOString()]);
    expect((await notice(early))!.getTime()).toBe(ends.getTime());
    const late = await mk('2026-10-10T00:00:00Z');
    expect(await ldb.query<{ n: number }>('select billing_seed_legacy(now()) n').then((r) => r.rows[0].n)).toBeGreaterThanOrEqual(1);
    const lateNotice = (await notice(late))!.getTime();
    expect(lateNotice).toBeGreaterThanOrEqual(ends.getTime());
    expect(lateNotice).toBeGreaterThanOrEqual(Date.now() + 30 * day - 5_000);
    // never an open-ended beta once a notice exists
    expect(await ldb.query<{ n: number }>('select count(*)::int n from billing_accounts where legacy_beta and notice_ends_at is null').then((r) => r.rows[0].n)).toBe(0);
  });
  it('a late seed when the promised date is almost here still gets 30 days from its own seeding, and the others keep their date', async () => {
    const day = 86_400_000;
    await ldb.query("update billing_accounts set notice_ends_at=now()+interval '3 days' where legacy_beta");
    const late = await mk('2026-10-11T00:00:00Z');
    await ldb.query('select billing_seed_legacy(now())');
    expect((await notice(late))!.getTime()).toBeGreaterThanOrEqual(Date.now() + 30 * day - 5_000);
    expect(await ldb.query<{ n: number }>("select count(*)::int n from billing_accounts where legacy_beta and notice_ends_at<now()+interval '4 days'").then((r) => r.rows[0].n)).toBeGreaterThanOrEqual(2);
  });
  it('before any notice exists a late seed leaves the notice to the scheduling call', async () => {
    const fresh = await createLocalSupabase();
    try {
      await fresh.exec('alter table auth.users add column if not exists created_at timestamptz not null default now()');
      const id = randomUUID();
      await fresh.query("insert into auth.users(id,created_at) values($1,'2026-09-01T00:00:00Z')", [id]);
      await fresh.query('select billing_seed_legacy(now())');
      expect((await fresh.query<{ n: Date | null }>('select notice_ends_at n from billing_accounts where user_id=$1', [id])).rows[0].n).toBeNull();
    } finally { await fresh.close(); }
  });
});

describe('hidden fair-use cap cannot be derived by a client', () => {
  it('an authenticated owner reads no money or token column of the spend ledger, but keeps the ownership columns', async () => {
    const u = await user();
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd,prompt_tokens,completion_tokens) values($1,$2,'chat','m',1,0.4,10,5)", [randomUUID(), u]);
    await asUser(db, u, async () => {
      expect((await db.query('select distinct user_id from ai_spend_attempts')).rows).toEqual([{ user_id: u }]);
      for (const column of ['cost_usd', 'reserved_usd', 'prompt_tokens', 'completion_tokens', 'generation_id'])
        await expect(db.query(`select ${column} from ai_spend_attempts`), column).rejects.toThrow(/permission denied/);
      await expect(db.query('select * from ai_spend_attempts')).rejects.toThrow(/permission denied/);
    });
    const other = await user();
    await asUser(db, other, async () => { expect((await db.query('select id from ai_spend_attempts')).rows).toEqual([]); });
  });
});

describe('older functions and function hygiene', () => {
  it('the retired spend window refuses a Lifetime account too, so a rollback never reserves managed cost for it', async () => {
    const u = await user();
    await setAccount(u, { lifetime_status: 'active', lifetime_order_id: 'o', status: 'active', current_period_ends_at: iso(DAY) });
    await expect(db.query('select * from billing_spend_window($1,10,2)', [u])).rejects.toThrow(/byok_required/);
    await expect(db.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.1,10,2)", [u, randomUUID()])).rejects.toThrow(/byok_required/);
    await expect(db.query('select billing_spend_summary($1,10,2)', [u])).rejects.toThrow(/byok_required/);
    // an ordinary paid account is unchanged
    const paid = await user();
    await setAccount(paid, { status: 'active', current_period_ends_at: iso(DAY) });
    expect((await db.query<{ cap: string }>('select cap::text from billing_spend_window($1,10,2)', [paid])).rows[0].cap).toBe('10');
  });
  it('every new SECURITY DEFINER function pins its search_path to public, pg_temp', async () => {
    const names = ['billing_emit', 'billing_emit_once', 'billing_claim_checkout_v2', 'billing_checkout_url_v2', 'billing_apply_subscription_v2', 'billing_apply_lifetime', 'billing_record_event', 'billing_claim_refund',
      'billing_release_refund', 'billing_spend_window_v2', 'reserve_billing_ai_spend_v2', 'billing_spend_summary_v2', 'record_ai_spend_tokens', 'billing_usage_tokens', 'billing_sweep_claim', 'billing_sweep_done',
      'billing_seed_legacy', 'billing_schedule_legacy_notice', 'billing_spend_window', 'billing_plan_kind', 'billing_sub_ended', 'billing_mark_agent_block'];
    const rows = (await db.query<{ proname: string; config: string[] | null }>('select proname, proconfig as config from pg_proc where pronamespace=\'public\'::regnamespace and proname = any($1)', [names])).rows;
    expect(rows.map((r) => r.proname).sort()).toEqual([...names].sort());
    for (const r of rows) expect(r.config, r.proname).toContain('search_path=public, pg_temp');
  });
  it('the server (service role) can write and read the durable marker rows the webhook code keeps next to the delivery digests', async () => {
    const u = await user();
    await db.exec('set role service_role');
    try {
      await db.query("insert into billing_webhook_events(id,user_id) values($1,$2) on conflict (id) do nothing", [`syscancel:marker-${u}`, u]);
      expect((await db.query('select id from billing_webhook_events where id=$1', [`syscancel:marker-${u}`])).rows).toHaveLength(1);
    } finally { await db.exec('reset role'); }
  });
  it('the retired functions keep their signatures (rollback) and are still service-role only', async () => {
    const calls = ['select billing_spend_window($1,3,1)', 'select billing_spend_summary($1,3,1)', "select reserve_billing_ai_spend($1,$1,'chat','m',0.1,3,1)"];
    const u = randomUUID();
    await db.exec('set role authenticated');
    try { for (const sql of calls) await expect(db.query(sql, [u]), sql).rejects.toThrow(/permission denied/); } finally { await db.exec('reset role'); }
  });
});

// ── re-review 1 (contract ch.23): violations are judged once, at the first binding ──────────────────────────────
describe('a bound purchase is never judged again', () => {
  const duplicates = async (u: string) => (await events(u)).filter((e) => e.startsWith('billing_duplicate_purchase'));
  const violations = async (u: string) => (await db.query<{ n: number }>("select count(*)::int n from billing_webhook_events where user_id=$1 and id like 'violation:%'", [u])).rows[0].n;

  it('regression: the sweep reads the discounted first payment before the webhook with the reference does — normal, nothing cancelled, and the late webhook is normal too', async () => {
    const u = await user();
    const i = await intent(u, 'pro');
    expect(await applySub(u, { intent: i, status: 'on_trial', trial: iso(3 * DAY) })).toBe('applied');
    // the sweep has no reference
    expect(await applySub(u, { intent: null, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true, updated: '2026-10-19T00:00:02Z' })).toBe('applied');
    expect(await violations(u)).toBe(0);
    expect(await duplicates(u)).toEqual([]);
    // the webhook that was late (it carries the reference) finds a bound subscription and is just as normal
    expect(await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true, updated: '2026-10-19T00:00:02Z' })).toBe('applied');
    expect(await row(u)).toMatchObject({ status: 'active', last_invoice_id: 'inv-1' });
    expect(await kind(u)).toBe('pro');
    expect(await duplicates(u)).toEqual([]);
  });

  it('regression: a late payment on an intent that expired and was consumed by a newer Start Pro is normal', async () => {
    const u = await user();
    await setAccount(u, {});
    const old = randomUUID();
    await db.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,url,with_trial,with_discount,expires_at) values($1,$2,'pro','2026-10-19','https://taskforce.lemonsqueezy.com/checkout/x',true,true,now()-interval '1 minute')", [old, u]);
    const fresh = await claim(u, 'pro'); // the user pressed Start Pro again: the old intent is consumed
    expect(fresh.id).not.toBe(old);
    expect((await db.query<{ consumed_at: Date | null }>('select consumed_at from billing_checkout_intents where id=$1', [old])).rows[0].consumed_at).not.toBeNull();
    // the delayed delivery of the first purchase arrives now
    expect(await applySub(u, { intent: old, status: 'on_trial', trial: iso(3 * DAY) })).toBe('applied');
    expect(await applySub(u, { intent: old, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true, updated: '2026-10-19T00:00:02Z' })).toBe('applied');
    expect(await row(u)).toMatchObject({ subscription_id: `sub-1-${u}`, status: 'active' });
    expect(await duplicates(u)).toEqual([]);
    expect(await events(u)).not.toContain('billing_review_needed {"plan":"monthly","reason":"intent_not_issued"}');
  });

  it('the first binding stores what was verified: the intent, its trial and discount offer on the account, the subscription on the intent', async () => {
    const u = await user();
    const i = await intent(u, 'pro', false, { trial: true, discount: false });
    await applySub(u, { intent: i, status: 'on_trial', trial: iso(3 * DAY) });
    expect(await row(u)).toMatchObject({ bound_intent_id: i, bound_with_trial: true, bound_with_discount: false });
    expect((await db.query('select bound_subscription_id,bound_order_id,consumed_at is not null as consumed from billing_checkout_intents where id=$1', [i])).rows[0]).toEqual({ bound_subscription_id: `sub-1-${u}`, bound_order_id: null, consumed: true });
    // later deliveries of the same subscription, with another intent or none, change nothing of the binding
    const other = await intent(u, 'pro', false, { trial: false, discount: true }).catch(() => null);
    await applySub(u, { intent: other, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', updated: '2026-10-19T00:00:02Z' });
    await applySub(u, { intent: null, status: 'active', ends: iso(60 * DAY), payment: iso(1000), invoice: 'inv-2', updated: '2026-10-19T00:00:03Z' });
    expect(await row(u)).toMatchObject({ bound_intent_id: i, bound_with_trial: true, bound_with_discount: false });
  });

  it('a first payment that is discounted although the bound intent did not offer it is reviewed by a person, not cancelled', async () => {
    const u = await user();
    const i = await intent(u, 'pro', false, { trial: true, discount: false });
    await applySub(u, { intent: i, status: 'on_trial', trial: iso(3 * DAY) });
    expect(await applySub(u, { intent: null, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true, updated: '2026-10-19T00:00:02Z' })).toBe('applied');
    expect(await events(u)).toContain('billing_review_needed {"plan":"monthly","reason":"discount_not_offered"}');
    expect(await duplicates(u)).toEqual([]);
    expect(await violations(u)).toBe(0);
    expect(await kind(u)).toBe('pro'); // entitlement follows the payment
    // the same stored facts do not raise it again on the next delivery
    await applySub(u, { intent: null, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true, updated: '2026-10-19T00:00:03Z' });
    expect((await events(u)).filter((e) => e.startsWith('billing_review_needed'))).toHaveLength(1);
  });

  it('an intent that already carries another subscription is used again only to review: the payment is real, the entitlement follows it', async () => {
    const u = await user();
    const i = await intent(u, 'pro');
    await applySub(u, { intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1' });
    await applySub(u, { status: 'expired', updated: '2026-10-19T00:00:02Z' });
    expect(await applySub(u, { sub: 'sub-2', intent: i, status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-9', updated: '2026-10-19T00:00:03Z' })).toBe('applied');
    expect(await events(u)).toContain('billing_review_needed {"plan":"monthly","reason":"intent_bound_elsewhere"}');
    expect(await duplicates(u)).toEqual([]);
    expect(await kind(u)).toBe('pro');
    expect((await db.query<{ s: string }>('select bound_subscription_id s from billing_checkout_intents where id=$1', [i])).rows[0].s).toBe(`sub-1-${u}`); // the first binding stays
  });

  it('the clear cases at the first binding are still cancelled: no trial offered, no discount offered, somebody else\'s intent', async () => {
    const trial = await user();
    expect(await applySub(trial, { intent: await intent(trial, 'pro', false, { trial: false, discount: false }), status: 'on_trial', trial: iso(DAY) })).toBe('rejected');
    const discount = await user();
    expect(await applySub(discount, { intent: await intent(discount, 'pro', false, { trial: false, discount: false }), status: 'active', ends: iso(30 * DAY), payment: iso(0), invoice: 'inv-1', discounted: true })).toBe('rejected');
    const owner = await user(), thief = await user();
    expect(await applySub(thief, { intent: await intent(owner, 'pro'), status: 'on_trial', trial: iso(DAY) })).toBe('rejected');
    for (const u of [trial, discount, thief]) expect(await violations(u)).toBe(1);
  });

  it('Lifetime stores the order on the intent; an intent that already carries another order is reviewed, not refused', async () => {
    const u = await user();
    const i = await intent(u, 'lifetime');
    expect(await applyLife(u, { intent: i })).toBe('applied');
    expect((await db.query<{ o: string; c: boolean }>('select bound_order_id o,consumed_at is not null c from billing_checkout_intents where id=$1', [i])).rows[0]).toEqual({ o: `ord-1-${u}`, c: true });
    // refunded, then the same stale link buys again
    await applyLife(u, { intent: i, status: 'refunded', updated: '2026-10-19T00:00:20Z' });
    expect(await applyLife(u, { intent: i, order: 'ord-2', status: 'active', updated: '2026-10-19T00:00:30Z' })).toBe('applied');
    expect(await events(u)).toContain('billing_review_needed {"plan":"lifetime","reason":"intent_bound_elsewhere"}');
    expect(await kind(u)).toBe('lifetime');
  });
});

describe('why an agent message could not start', () => {
  const message = async (u: string, over: { state?: string; reason?: string | null; refs?: object } = {}) => {
    const connection = randomUUID(), conversation = randomUUID(), id = randomUUID();
    await db.query("insert into agent_connections(id,user_id,adapter) values($1,$2,'agent:codex')", [connection, u]);
    await db.query("insert into conversations(id,user_id,target_kind,agent_connection_id) values($1,$2,'agent',$3)", [conversation, u, connection]);
    await db.query("insert into conversation_messages(id,user_id,conversation_id,seq,role,client_message_id,text,refs,delivery_state,delivery_reason) values($1,$2,$3,1,'user',$4,'hi',$5,$6,$7)",
      [id, u, conversation, randomUUID(), JSON.stringify(over.refs ?? {}), over.state ?? 'not_sent', over.reason === undefined ? 'write_gate_closed' : over.reason]);
    return id;
  };
  const refs = async (id: string) => (await db.query<{ refs: Record<string, unknown> }>('select refs from conversation_messages where id=$1', [id])).rows[0].refs;
  const mark = async (u: string, id: string, blocked: boolean) => (await db.query<{ r: boolean }>('select billing_mark_agent_block($1,$2,$3) r', [u, id, blocked])).rows[0].r;

  it('writes the billing mark next to the other refs only on a message stopped by the shared gate reason, and removes it again', async () => {
    const u = await user();
    const id = await message(u, { refs: { action_ids: [] } });
    expect(await mark(u, id, true)).toBe(true);
    expect(await refs(id)).toEqual({ action_ids: [], blocked_by: 'billing' });
    expect(await mark(u, id, true)).toBe(false); // already marked
    expect(await mark(u, id, false)).toBe(true);
    expect(await refs(id)).toEqual({ action_ids: [] });
    expect(await mark(u, id, false)).toBe(false);
  });
  it('refuses to mark anything else and never reaches another user\'s message', async () => {
    const u = await user(), other = await user();
    for (const [state, reason] of [['queued', null], ['not_sent', 'spawn_failed'], ['dispatched', null]] as const) {
      const id = await message(u, { state, reason });
      expect(await mark(u, id, true), `${state}/${reason}`).toBe(false);
    }
    const mine = await message(u);
    expect(await mark(other, mine, true)).toBe(false);
    expect(await refs(mine)).toEqual({});
  });
  it('clears a stale mark whatever the message state is now (a requeued message keeps no mark)', async () => {
    const u = await user();
    const id = await message(u, { state: 'queued', reason: null, refs: { blocked_by: 'billing' } });
    expect(await mark(u, id, false)).toBe(true);
    expect(await refs(id)).toEqual({});
  });
  it('is callable by the service role only', async () => {
    await db.exec('set role authenticated');
    try { await expect(db.query('select billing_mark_agent_block($1,$1,true)', [randomUUID()])).rejects.toThrow(/permission denied/); } finally { await db.exec('reset role'); }
  });
});
