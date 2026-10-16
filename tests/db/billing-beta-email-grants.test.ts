import { randomUUID } from 'node:crypto';
import type { PGlite } from '@electric-sql/pglite';
import { afterAll, beforeAll, expect, it } from 'vitest';
import { asUser, createLocalSupabase } from './local-supabase';

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

async function grant(email: string) {
    await db.query('insert into billing_beta_email_grants(email) values($1)', [email]);
}
async function account(user: string) {
    return (await db.query<{ legacy_beta: boolean; status: string; subscription_id: string | null; deleting: boolean; notice_ends_at: Date | null }>('select legacy_beta, status, subscription_id, deleting, notice_ends_at from billing_accounts where user_id=$1', [user])).rows;
}

it('grants a pending beta invitation only to a confirmed matching email, ignoring case and whitespace', async () => {
    const user = randomUUID();
    await grant('beta@example.com');
    await db.query("insert into auth.users(id,email,email_confirmed_at) values($1,' Beta@Example.com ',now())", [user]);
    expect(await account(user)).toEqual([{ legacy_beta: true, status: 'none', subscription_id: null, deleting: false, notice_ends_at: null }]);
    const other = randomUUID();
    await db.query("insert into auth.users(id,email,email_confirmed_at) values($1,'other@example.com',now())", [other]);
    expect(await account(other)).toEqual([]);
});

it('waits for confirmation and preserves subscription and notice data on repeated confirmation', async () => {
    const user = randomUUID();
    await grant('later@example.com');
    await db.query("insert into auth.users(id,email) values($1,'later@example.com')", [user]);
    expect(await account(user)).toEqual([]);
    await db.query("insert into billing_accounts(user_id,status,subscription_id,notice_ends_at) values($1,'active','paid-sub','2030-01-01')", [user]);
    await db.query('update auth.users set email_confirmed_at=now() where id=$1', [user]);
    const result = await account(user);
    expect(result[0]).toMatchObject({ legacy_beta: true, status: 'active', subscription_id: 'paid-sub' });
    expect(result[0].notice_ends_at).not.toBeNull();
    await db.query('update auth.users set email_confirmed_at=now() where id=$1', [user]);
    expect(await account(user)).toEqual(result);
});

it('handles verified email changes but does not grant while account deletion is in progress', async () => {
    const user = randomUUID();
    await grant('changed@example.com');
    await db.query("insert into auth.users(id,email,email_confirmed_at) values($1,'before@example.com',now())", [user]);
    await db.query("insert into billing_accounts(user_id,deleting) values($1,true)", [user]);
    await db.query("update auth.users set email='changed@example.com' where id=$1", [user]);
    expect((await account(user))[0]).toMatchObject({ legacy_beta: false, deleting: true });
    await db.query('update billing_accounts set deleting=false where user_id=$1', [user]);
    await db.query('update auth.users set email_confirmed_at=now() where id=$1', [user]);
    expect((await account(user))[0]).toMatchObject({ legacy_beta: true, deleting: false });
});

it('keeps the allowlist private and prevents client self-grants', async () => {
    const user = randomUUID();
    await db.query('insert into auth.users(id) values($1)', [user]);
    await asUser(db, user, async () => {
        await expect(db.query('select * from billing_beta_email_grants')).rejects.toThrow(/permission denied/);
        await expect(db.query("insert into billing_beta_email_grants(email) values('self@example.com')")).rejects.toThrow(/permission denied/);
        await expect(db.query('select billing_grant_beta_on_verified_email()')).rejects.toThrow(/permission denied/);
    });
    await db.exec('set role anon');
    try {
        await expect(db.query('select * from billing_beta_email_grants')).rejects.toThrow(/permission denied/);
        await expect(db.query("insert into billing_beta_email_grants(email) values('anon@example.com')")).rejects.toThrow(/permission denied/);
    } finally { await db.exec('reset role'); }
    await db.exec('set role service_role');
    try { await grant('operator@example.com'); } finally { await db.exec('reset role'); }
});
