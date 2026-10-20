import { randomUUID } from 'node:crypto';
import type { PGlite } from '@electric-sql/pglite';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { asUser, createLocalSupabase } from './local-supabase';

// BYOK key store (20261130000000): the sealed OpenRouter key of a Lifetime owner. No client role may touch the table or the
// functions; every write leaves its event in the same transaction; the Lifetime refund removes the key. Sealed values here are
// made-up strings: no real key, no real ciphertext.
const DAY = 86_400_000;
let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

async function user(): Promise<string> {
  const id = randomUUID();
  await db.query('insert into auth.users(id) values($1)', [id]);
  return id;
}
const setAccount = (userId: string, input: Record<string, unknown> = {}) => {
  const keys = Object.keys(input);
  return db.query(`insert into billing_accounts(${['user_id', ...keys].join(',')}) values(${['$1', ...keys.map((_, i) => `$${i + 2}`)].join(',')}) on conflict (user_id) do update set ${keys.length ? keys.map((k) => `${k}=excluded.${k}`).join(',') : 'user_id=excluded.user_id'}`, [userId, ...keys.map((k) => input[k])]);
};
/** A Lifetime owner: the entitlement row the key function checks. */
async function owner(): Promise<string> {
  const id = await user();
  await setAccount(id, { lifetime_status: 'active', lifetime_order_id: `ord-${id}`, lifetime_paid_at: new Date().toISOString() });
  return id;
}
const put = async (userId: string, sealed = 'k1.aaa.bbb.ccc', version = 1) =>
  (await db.query<{ r: boolean }>('select ai_key_put($1,$2,$3::smallint) r', [userId, sealed, version])).rows[0].r;
const keyRow = async (userId: string) => (await db.query<Record<string, unknown>>('select * from user_ai_keys where user_id=$1', [userId])).rows[0];
const events = async (userId: string) =>
  (await db.query<{ type: string; props: Record<string, unknown> }>("select type,props from metric_events where user_id=$1 and type like 'ai\\_key\\_%' order by at", [userId])).rows.map((r) => `${r.type} ${JSON.stringify(r.props)}`);

describe('the table', () => {
  it('has the contract columns, a single user_id key with cascade, and the closed value lists', async () => {
    const cols = (await db.query<{ column_name: string; is_nullable: string }>("select column_name,is_nullable from information_schema.columns where table_schema='public' and table_name='user_ai_keys' order by ordinal_position")).rows;
    expect(cols.map((c) => c.column_name)).toEqual(['user_id', 'provider', 'sealed_key', 'key_version', 'status', 'verified_at', 'last_ok_at', 'revoked_at', 'last_spend_error_at', 'created_at', 'updated_at']);
    expect(cols.filter((c) => c.is_nullable === 'NO').map((c) => c.column_name)).toEqual(['user_id', 'provider', 'sealed_key', 'key_version', 'status', 'verified_at', 'created_at', 'updated_at']);
    const pk = (await db.query<{ attname: string }>("select a.attname from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=any(i.indkey) where i.indrelid='public.user_ai_keys'::regclass and i.indisprimary")).rows;
    expect(pk).toEqual([{ attname: 'user_id' }]);
    const u = await user();
    const insert = (over: Record<string, unknown>) => {
      const v = { user_id: u, provider: 'openrouter', sealed_key: 'k1.a.b.c', status: 'connected', ...over };
      return db.query('insert into user_ai_keys(user_id,provider,sealed_key,status,verified_at) values($1,$2,$3,$4,now())', [v.user_id, v.provider, v.sealed_key, v.status]);
    };
    await expect(insert({ provider: 'openai' })).rejects.toThrow(/check constraint/);
    await expect(insert({ status: 'expired' })).rejects.toThrow(/check constraint/);
    await expect(insert({ sealed_key: 'x'.repeat(2048) })).rejects.toThrow(/check constraint/);
    await expect(insert({ sealed_key: null })).rejects.toThrow(/not-null/);
    await expect(insert({ user_id: randomUUID() })).rejects.toThrow(/foreign key/);
    await insert({ sealed_key: 'x'.repeat(2047) });
    await expect(insert({})).rejects.toThrow(/duplicate key/);
  });

  it('removes the row with the user (account deletion)', async () => {
    const u = await owner();
    await put(u);
    await db.query('delete from auth.users where id=$1', [u]);
    expect(await keyRow(u)).toBeUndefined();
  });

  it('has row level security with an owner_all policy and no privileges for the client roles', async () => {
    const t = (await db.query<{ relrowsecurity: boolean }>("select relrowsecurity from pg_class where oid='public.user_ai_keys'::regclass")).rows[0];
    expect(t.relrowsecurity).toBe(true);
    const policies = (await db.query<{ policyname: string; roles: string; cmd: string }>("select policyname,roles::text,cmd from pg_policies where schemaname='public' and tablename='user_ai_keys'")).rows;
    expect(policies).toEqual([{ policyname: 'owner_all', roles: '{authenticated}', cmd: 'ALL' }]);
    const grants = (await db.query<{ grantee: string; privilege_type: string }>("select grantee,privilege_type from information_schema.role_table_grants where table_schema='public' and table_name='user_ai_keys' and grantee in ('anon','authenticated','public')")).rows;
    expect(grants).toEqual([]);
  });

  it('neither the owner nor anyone else can read, write or delete it through the API roles', async () => {
    const alice = await owner(), bob = await owner();
    await put(alice, 'k1.alice.sealed.value');
    await put(bob, 'k1.bob.sealed.value');
    for (const role of ['authenticated', 'anon']) {
      await db.exec(`set role ${role}; select set_config('request.jwt.claim.sub', '${alice}', false);`);
      try {
        for (const sql of [
          'select * from user_ai_keys', 'select sealed_key from user_ai_keys', 'select count(*) from user_ai_keys',
          "insert into user_ai_keys(user_id,sealed_key,verified_at) values(gen_random_uuid(),'x',now())",
          "update user_ai_keys set sealed_key='k1.mine.mine.mine'", "update user_ai_keys set status='connected'", 'delete from user_ai_keys',
        ]) await expect(db.query(sql), `${role}: ${sql}`).rejects.toThrow(/permission denied/);
      } finally { await db.exec("reset role; select set_config('request.jwt.claim.sub', '', false);"); }
    }
    await asUser(db, alice, async () => {
      await expect(db.query('select * from user_ai_keys where user_id=$1', [alice])).rejects.toThrow(/permission denied/);
    });
    expect((await keyRow(alice))?.sealed_key).toBe('k1.alice.sealed.value');
    expect((await keyRow(bob))?.sealed_key).toBe('k1.bob.sealed.value');
  });

  it('the service role works with it', async () => {
    const u = await owner();
    await db.exec('set role service_role');
    try {
      await db.query("insert into user_ai_keys(user_id,sealed_key,verified_at) values($1,'k1.s.r.v',now())", [u]);
      expect((await db.query('select user_id from user_ai_keys where user_id=$1', [u])).rows).toHaveLength(1);
      await db.query("update user_ai_keys set status='revoked',revoked_at=now() where user_id=$1", [u]);
      await db.query('delete from user_ai_keys where user_id=$1', [u]);
    } finally { await db.exec('reset role'); }
    expect(await keyRow(u)).toBeUndefined();
  });
});

describe('the functions are service-role only', () => {
  it('no API role may call them', async () => {
    const u = randomUUID();
    const calls = [
      "select ai_key_put($1,'k1.a.b.c',1::smallint)", 'select ai_key_delete($1)', "select ai_key_mark_revoked($1,'k1.a.b.c')",
      "select ai_key_note_spend_error($1,'k1.a.b.c')", "select ai_key_note_ok($1,'k1.a.b.c')", 'select ai_key_after_delete()',
    ];
    for (const role of ['authenticated', 'anon']) {
      await db.exec(`set role ${role}`);
      try {
        for (const sql of calls) await expect(db.query(sql, sql.includes('$1') ? [u] : []), `${role}: ${sql}`).rejects.toThrow(/permission denied/);
      } finally { await db.exec('reset role'); }
    }
    await db.exec('set role service_role');
    try {
      await expect(db.query('select ai_key_delete($1)', [u])).resolves.toBeDefined();
    } finally { await db.exec('reset role'); }
  });

  it('every one pins its search_path and runs with the owner rights', async () => {
    const fns = (await db.query<{ proname: string; prosecdef: boolean; proconfig: string[] | null }>("select proname,prosecdef,proconfig from pg_proc where pronamespace='public'::regnamespace and proname like 'ai\\_key\\_%' order by proname")).rows;
    expect(fns.map((f) => f.proname)).toEqual(['ai_key_after_delete', 'ai_key_delete', 'ai_key_mark_revoked', 'ai_key_note_ok', 'ai_key_note_spend_error', 'ai_key_put']);
    for (const f of fns) {
      expect(f.prosecdef, f.proname).toBe(true);
      expect(f.proconfig, f.proname).toEqual(['search_path=public, pg_temp']);
    }
  });
});

describe('ai_key_put', () => {
  it('only an active Lifetime owner may store a key (no row, none, refunded, fraudulent, deleting)', async () => {
    const none = await user();
    await expect(put(none)).rejects.toThrow(/byok_not_entitled/);
    for (const account of [{}, { lifetime_status: 'refunded', lifetime_order_id: 'o1' }, { lifetime_status: 'fraudulent', lifetime_order_id: 'o2' }, { lifetime_status: 'active', lifetime_order_id: 'o3', deleting: true }, { status: 'active', subscription_id: 's1', current_period_ends_at: new Date(Date.now() + DAY).toISOString() }]) {
      const u = await user();
      await setAccount(u, Object.fromEntries(Object.entries(account).map(([k, v]) => [k, typeof v === 'string' && /^(o\d|s\d)$/.test(v) ? `${v}-${u}` : v])));
      await expect(put(u), JSON.stringify(account)).rejects.toThrow(/byok_not_entitled/);
      expect(await keyRow(u)).toBeUndefined();
      expect(await events(u)).toEqual([]);
    }
  });

  it('stores the sealed value as connected and records ai_key_saved {replaced:false} once', async () => {
    const u = await owner();
    expect(await put(u, 'k1.first.sealed.value')).toBe(false);
    expect(await keyRow(u)).toMatchObject({ user_id: u, provider: 'openrouter', sealed_key: 'k1.first.sealed.value', key_version: 1, status: 'connected', last_ok_at: null, revoked_at: null, last_spend_error_at: null });
    expect((await keyRow(u)).verified_at).toBeInstanceOf(Date);
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}']);
  });

  it('replacing keeps one row, resets every mark, and records {replaced:true}', async () => {
    const u = await owner();
    await put(u, 'k1.old.old.old');
    await db.query("update user_ai_keys set status='revoked',revoked_at=now(),last_ok_at=now(),last_spend_error_at=now() where user_id=$1", [u]);
    expect(await put(u, 'k1.new.new.new', 1)).toBe(true);
    expect((await db.query('select * from user_ai_keys where user_id=$1', [u])).rows).toHaveLength(1);
    expect(await keyRow(u)).toMatchObject({ sealed_key: 'k1.new.new.new', status: 'connected', last_ok_at: null, revoked_at: null, last_spend_error_at: null });
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_saved {"replaced":true}']);
  });

  it('refuses an empty value and a missing user or version without writing anything', async () => {
    const u = await owner();
    for (const args of [[u, '', 1], [u, null, 1], [null, 'k1.a.b.c', 1], [u, 'k1.a.b.c', null]] as const)
      await expect(db.query('select ai_key_put($1,$2,$3::smallint)', [...args]), JSON.stringify(args)).rejects.toThrow(/ai_key_invalid/);
    await expect(put(u, 'x'.repeat(2048))).rejects.toThrow(/check constraint/);
    expect(await keyRow(u)).toBeUndefined();
    expect(await events(u)).toEqual([]);
  });

  it('records the event in the same transaction: a refused write leaves no event and a failed one no row', async () => {
    const u = await owner();
    await db.exec('begin');
    try { await put(u); } finally { await db.exec('rollback'); }
    expect(await keyRow(u)).toBeUndefined();
    expect(await events(u)).toEqual([]);
  });
});

describe('ai_key_delete', () => {
  it('removes the row and records ai_key_deleted once; deleting again is false and silent', async () => {
    const u = await owner();
    await put(u);
    expect((await db.query<{ r: boolean }>('select ai_key_delete($1) r', [u])).rows[0].r).toBe(true);
    expect((await db.query<{ r: boolean }>('select ai_key_delete($1) r', [u])).rows[0].r).toBe(false);
    expect(await keyRow(u)).toBeUndefined();
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {}']);
  });

  it('only touches the named user', async () => {
    const a = await owner(), b = await owner();
    await put(a); await put(b);
    await db.query('select ai_key_delete($1)', [a]);
    expect(await keyRow(a)).toBeUndefined();
    expect(await keyRow(b)).toBeDefined();
  });

  it('works for an account that is no longer Lifetime (a stray key can always go)', async () => {
    const u = await user();
    await db.query("insert into user_ai_keys(user_id,sealed_key,verified_at) values($1,'k1.stray.stray.stray',now())", [u]);
    expect((await db.query<{ r: boolean }>('select ai_key_delete($1) r', [u])).rows[0].r).toBe(true);
  });
});

describe('what the provider said about the key', () => {
  it('ai_key_mark_revoked: connected to revoked once, for the exact sealed value, with one event {by:"provider"}', async () => {
    const u = await owner();
    await put(u, 'k1.used.used.used');
    const revoke = async (sealed: string) => (await db.query<{ r: boolean }>('select ai_key_mark_revoked($1,$2) r', [u, sealed])).rows[0].r;
    expect(await revoke('k1.other.other.other')).toBe(false);
    expect((await keyRow(u)).status).toBe('connected');
    expect(await revoke('k1.used.used.used')).toBe(true);
    expect(await keyRow(u)).toMatchObject({ status: 'revoked', sealed_key: 'k1.used.used.used' });
    expect((await keyRow(u)).revoked_at).toBeInstanceOf(Date);
    expect(await revoke('k1.used.used.used')).toBe(false);
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_revoked {"by":"provider"}']);
  });

  it('a late 401 of the old key does not revoke the key the owner has just saved', async () => {
    const u = await owner();
    await put(u, 'k1.old.old.old');
    await put(u, 'k1.new.new.new');
    expect((await db.query<{ r: boolean }>("select ai_key_mark_revoked($1,'k1.old.old.old') r", [u])).rows[0].r).toBe(false);
    expect((await keyRow(u)).status).toBe('connected');
  });

  it('a 402/403 keeps the key connected and notes the time; success clears it and notes the last good call', async () => {
    const u = await owner();
    await put(u, 'k1.a.b.c');
    await db.query("select ai_key_note_spend_error($1,'k1.zzz')", [u]);
    expect((await keyRow(u)).last_spend_error_at).toBeNull();
    await db.query("select ai_key_note_spend_error($1,'k1.a.b.c')", [u]);
    expect(await keyRow(u)).toMatchObject({ status: 'connected' });
    expect((await keyRow(u)).last_spend_error_at).toBeInstanceOf(Date);
    await db.query("select ai_key_note_ok($1,'k1.zzz')", [u]);
    expect((await keyRow(u)).last_spend_error_at).toBeInstanceOf(Date);
    await db.query("select ai_key_note_ok($1,'k1.a.b.c')", [u]);
    expect(await keyRow(u)).toMatchObject({ status: 'connected', last_spend_error_at: null });
    expect((await keyRow(u)).last_ok_at).toBeInstanceOf(Date);
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}']);
  });

  it('a revoked key is not changed by later notes (it stays revoked until replaced)', async () => {
    const u = await owner();
    await put(u, 'k1.a.b.c');
    await db.query("select ai_key_mark_revoked($1,'k1.a.b.c')", [u]);
    await db.query("select ai_key_note_spend_error($1,'k1.a.b.c')", [u]);
    await db.query("select ai_key_note_ok($1,'k1.a.b.c')", [u]);
    expect(await keyRow(u)).toMatchObject({ status: 'revoked', last_ok_at: null, last_spend_error_at: null });
  });
});

describe('events never carry the key', () => {
  it('writes each of the three key event types, and only through its function', async () => {
    const u = await owner();
    await put(u, 'k1.a.b.c');
    await db.query("select ai_key_mark_revoked($1,'k1.a.b.c')", [u]);
    await db.query('select ai_key_delete($1)', [u]);
    const types = (await db.query<{ type: string }>('select type from metric_events where user_id=$1 order by at', [u])).rows.map((r) => r.type);
    expect(types).toEqual(['ai_key_saved', 'ai_key_revoked', 'ai_key_deleted']);
    // a client can write none of them directly (the table accepts only the app's own two types)
    await asUser(db, u, async () => {
      for (const type of ['ai_key_saved', 'ai_key_deleted', 'ai_key_revoked'])
        await expect(db.query('insert into metric_events(type) values($1)', [type]), type).rejects.toThrow(/row-level security|permission denied/);
    });
  });

  it('props hold only replaced / by, whatever the sealed value is', async () => {
    const u = await owner();
    const sealed = 'k1.SEALEDMARKER.SEALEDMARKER.SEALEDMARKER';
    await put(u, sealed); await put(u, sealed + 'x');
    await db.query('select ai_key_mark_revoked($1,$2)', [u, sealed + 'x']);
    await db.query('select ai_key_delete($1)', [u]);
    const rows = (await db.query<{ type: string; props: unknown }>("select type,props from metric_events where user_id=$1 and type like 'ai\\_key\\_%'", [u])).rows;
    expect(rows).toHaveLength(4);
    expect(JSON.stringify(rows)).not.toMatch(/SEALEDMARKER|k1\./);
    for (const r of rows) expect(Object.keys(r.props as object).every((k) => ['replaced', 'by'].includes(k)), r.type).toBe(true);
  });
});

describe('the Lifetime refund removes the stored key (BL-20)', () => {
  const lifetimeBought = async () => {
    const u = await user();
    const intent = randomUUID();
    await db.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,url,with_trial,with_discount) values($1,$2,'lifetime','2026-10-19','https://taskforce.lemonsqueezy.com/checkout/x',false,false)", [intent, u]);
    const apply = (status: string, updated: string) =>
      db.query('select billing_apply_lifetime($1,$2,$3,$4,$5,$6,$7,$8)', [u, randomUUID(), intent, `ord-${u}`, 'cus', status, new Date().toISOString(), updated]);
    await apply('active', '2026-10-19T00:00:00Z');
    return { u, apply };
  };

  it('a confirmed refund deletes the key and leaves ai_key_deleted {by:"refund"} once, even when the refund is delivered again; the owner cannot save a new one afterwards', async () => {
    const { u, apply } = await lifetimeBought();
    await put(u, 'k1.a.b.c');
    await apply('refunded', '2026-10-19T00:00:10Z');
    expect(await keyRow(u)).toBeUndefined();
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {"by":"refund"}']);
    await apply('refunded', '2026-10-19T00:00:11Z');
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {"by":"refund"}']);
    await expect(put(u)).rejects.toThrow(/byok_not_entitled/);
  });

  it('a refund with no stored key leaves no deletion event', async () => {
    const { u, apply } = await lifetimeBought();
    await apply('refunded', '2026-10-19T00:00:10Z');
    expect(await events(u)).toEqual([]);
  });

  it('a fraudulent order removes it too; a late paid snapshot does not bring the entitlement or the key back', async () => {
    const { u, apply } = await lifetimeBought();
    await put(u, 'k1.a.b.c');
    await apply('fraudulent', '2026-10-19T00:00:10Z');
    expect(await keyRow(u)).toBeUndefined();
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {"by":"refund"}']);
    await apply('active', '2026-10-19T00:00:20Z');
    await expect(put(u)).rejects.toThrow(/byok_not_entitled/);
  });

  it('the label follows the cause, not the order: a removal by the owner right before a later refund in the same transaction stays {} and the refund is {by:"refund"}', async () => {
    const { u, apply } = await lifetimeBought();
    await db.exec('begin');
    try {
      await put(u, 'k1.first.first.first');
      await db.query('select ai_key_delete($1)', [u]);
      await put(u, 'k1.second.second.second');
      await apply('refunded', '2026-10-19T00:00:10Z');
    } finally { await db.exec('commit'); }
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {}', 'ai_key_saved {"replaced":false}', 'ai_key_deleted {"by":"refund"}']);
  });

  it('another user\'s refund leaves this key alone', async () => {
    const mine = await owner();
    await put(mine, 'k1.mine.mine.mine');
    const { u, apply } = await lifetimeBought();
    await put(u, 'k1.a.b.c');
    await apply('refunded', '2026-10-19T00:00:10Z');
    expect((await keyRow(mine))?.sealed_key).toBe('k1.mine.mine.mine');
  });
});

describe('every removal of a key is counted once, whoever does it', () => {
  it('the owner\'s DELETE leaves {} exactly once (not twice)', async () => {
    const u = await owner();
    await put(u);
    await db.query('select ai_key_delete($1)', [u]);
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {}']);
  });

  it('a removal by anyone else with direct access (an operator clearing the table) is {by:"system"}', async () => {
    const u = await owner();
    await put(u);
    await db.query('delete from user_ai_keys where user_id=$1', [u]);
    expect(await events(u)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {"by":"system"}']);
  });

  it('deleting the account removes the key silently: no event is written for a user who is going away, and the deletion itself succeeds', async () => {
    const u = await owner();
    await put(u);
    await db.query('delete from auth.users where id=$1', [u]);
    expect(await keyRow(u)).toBeUndefined();
    expect((await db.query('select 1 from metric_events where user_id=$1', [u])).rows).toEqual([]);
  });

  it('a refunded owner who then deletes the account still deletes cleanly', async () => {
    const u = await owner();
    await put(u);
    await db.query("update billing_accounts set lifetime_status='refunded' where user_id=$1", [u]);
    await db.query('delete from auth.users where id=$1', [u]);
    expect(await keyRow(u)).toBeUndefined();
  });
});

describe('rate limit kind ai_key (hourly attempts)', () => {
  const take = async (userId: string, kind: string, max = 10, windowSeconds = 3600) =>
    (await db.query<{ r: Date | null }>('select take_rate_limit($1,$2,$3,$4) r', [userId, kind, max, windowSeconds])).rows[0].r;

  it('lets ten attempts through and answers the eleventh with the time the oldest one leaves the window', async () => {
    const u = await user();
    for (let i = 0; i < 10; i++) expect(await take(u, 'ai_key'), `attempt ${i + 1}`).toBeNull();
    const retryAt = await take(u, 'ai_key');
    expect(retryAt).toBeInstanceOf(Date);
    const inMs = retryAt!.getTime() - Date.now();
    expect(inMs).toBeGreaterThan(59 * 60_000);
    expect(inMs).toBeLessThanOrEqual(60 * 60_000);
    expect((await db.query<{ n: number }>("select count(*)::int n from rate_limit_events where user_id=$1 and kind='ai_key'", [u])).rows[0].n).toBe(10);
  });

  it('counts per user and per kind, and attempts older than the window do not count', async () => {
    const a = await user(), b = await user();
    for (let i = 0; i < 10; i++) await take(a, 'ai_key');
    expect(await take(a, 'ai_key')).toBeInstanceOf(Date);
    expect(await take(b, 'ai_key')).toBeNull();
    expect(await take(a, 'ask', 3, 600)).toBeNull();
    await db.query("update rate_limit_events set created_at=now()-interval '61 minutes' where user_id=$1 and kind='ai_key'", [a]);
    expect(await take(a, 'ai_key')).toBeNull();
  });

  it('the old kinds still work, and an unknown kind is still refused by both the function and the table', async () => {
    const u = await user();
    for (const kind of ['ask', 'connection_start', 'action_create', 'run_create', 'bridge_register']) expect(await take(u, kind, 2, 600), kind).toBeNull();
    await expect(take(u, 'made_up')).rejects.toThrow(/모르는 종류/);
    await expect(db.query("insert into rate_limit_events(user_id,kind) values($1,'made_up')", [u])).rejects.toThrow(/check constraint/);
    await expect(db.query("insert into rate_limit_events(user_id,kind) values($1,'ai_key')", [u])).resolves.toBeDefined();
  });

  it('is not callable by the API roles', async () => {
    const u = await user();
    for (const role of ['authenticated', 'anon']) {
      await db.exec(`set role ${role}`);
      try { await expect(db.query("select take_rate_limit($1,'ai_key',10,3600)", [u])).rejects.toThrow(/permission denied/); } finally { await db.exec('reset role'); }
    }
  });
});
