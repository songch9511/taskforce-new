import { randomUUID } from 'node:crypto';
import type { PGlite } from '@electric-sql/pglite';
import { beforeAll, afterAll, it, expect } from 'vitest';
import { createLocalSupabase, asUser } from './local-supabase';
let db: PGlite;
const alice = randomUUID();
const bob = randomUUID();
const intent = randomUUID();
beforeAll(async () => { db = await createLocalSupabase(); await db.query('insert into auth.users(id) values($1),($2)', [alice, bob]); await db.query('insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version) values($1,$2,$3,$4)', [intent, alice, 'monthly','2026-10-08']); }, 60000);
afterAll(async () => { await db?.close(); });
const apply = (event: string, status: string, updated: string, sub = '123') => db.query('select billing_apply_subscription($1,$2,$3,$4,$5,$6,$7,$8,$9)', [alice, event, intent, sub, '12', 'monthly', status, '2026-11-08T00:00:00Z', updated]);
it('starts trial once and restricts mutations / cross-account reads', async () => {
    await db.query("insert into billing_accounts(user_id,onboarding_started_at) values($1,now()) on conflict do nothing",[alice]);
    await db.query('select billing_start_trial($1)', [alice]);
    await db.query("insert into billing_accounts(user_id,onboarding_started_at) values($1,now()) on conflict do nothing",[bob]);
    await db.query('select billing_start_trial($1)', [bob]);
    const first = await db.query('select trial_ends_at from billing_accounts where user_id=$1', [alice]);
    await db.query('select billing_start_trial($1)', [alice]);
    expect((await db.query('select trial_ends_at from billing_accounts where user_id=$1', [alice])).rows).toEqual(first.rows);
    await asUser(db, alice, async () => {
        expect((await db.query('select user_id from billing_accounts')).rows).toEqual([{ user_id: alice }]);
        await expect(db.query("update billing_accounts set status='active'")).rejects.toThrow(/permission denied/);
        await expect(db.query('select billing_start_trial($1)', [alice])).rejects.toThrow(/permission denied/);
        await expect(db.query('select * from billing_checkout_intents')).rejects.toThrow(/permission denied/);
    });
});
it('deduplicates delivery and rejects stale snapshots and second subscriptions', async () => {
    await apply('e1', 'active', '2026-10-08T00:00:00Z');
    await apply('e1', 'expired', '2026-10-09T00:00:00Z');
    await apply('e2', 'expired', '2026-10-07T00:00:00Z');
    expect((await db.query('select status from billing_accounts where user_id=$1', [alice])).rows).toEqual([{ status: 'active' }]);
    await expect(apply('e3', 'active', '2026-10-09T00:00:00Z', '999')).rejects.toThrow(/billing_duplicate_subscription/);
});
it('serializes open checkout and rejects mismatched account intent', async () => {
    await db.query("insert into billing_checkout_intents(user_id,plan,accepted_terms_version) values($1,'annual','2026-10-08')", [bob]);
    await expect(db.query("insert into billing_checkout_intents(user_id,plan,accepted_terms_version) values($1,'monthly','2026-10-08')", [bob])).rejects.toThrow(/unique/);
    await expect(db.query('select billing_apply_subscription($1,$2,$3,$4,$5,$6,$7,$8,$9)', [bob, 'bad', intent, '222', '12', 'monthly', 'active', null, '2026-10-08T00:00:00Z'])).rejects.toThrow(/billing_intent_missing/);
});
it('paid calendar-month budget resets settled cost but carries unknown holds across months', async () => {
    await db.query("update billing_accounts set status='active',current_period_ends_at=now()+interval '1 year' where user_id=$1", [alice]);
    const hold = randomUUID();
    const paid = randomUUID();
    await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd,created_at) values($1,$2,'chat','m',2,null,now()-interval '2 months'),($3,$2,'chat','m',3,3,now()-interval '2 months')", [hold, alice, paid]);
    await db.query("select reserve_billing_ai_spend($1,$2,'chat','m',1,3,1)", [alice, randomUUID()]);
    await expect(db.query("select reserve_billing_ai_spend($1,$2,'embeddings','m',0.01,3,1)", [alice, randomUUID()])).rejects.toThrow(/ai_budget_exhausted/);
    const summary = (await db.query<{
        s: {
            cap_usd: number;
            reserved_usd: number;
            remaining_usd: number;
        };
    }>('select billing_spend_summary($1,3,1) s', [alice])).rows[0].s;
    expect(summary).toMatchObject({ cap_usd: 3, reserved_usd: 3, remaining_usd: 0 });
});
it('trial is capped at one dollar and cannot reserve after expiry', async () => {
    await db.query("select reserve_billing_ai_spend($1,$2,'chat','m',1,3,1)", [bob, randomUUID()]);
    await expect(db.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.01,3,1)", [bob, randomUUID()])).rejects.toThrow(/ai_budget_exhausted/);
    await db.query("update billing_accounts set trial_ends_at=now()-interval '1 hour' where user_id=$1", [bob]);
    await expect(db.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.01,3,1)", [bob, randomUUID()])).rejects.toThrow(/subscription_required/);
});

it('deletion strips account linkage and checkout URL, then expires the retry reference',async()=>{
 const user=randomUUID();const reference=randomUUID();
 await db.query('insert into auth.users(id) values($1)',[user]);
 await db.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,url,expires_at) values($1,$2,'monthly','2026-10-08','https://store.lemonsqueezy.com/checkout/private',now()-interval '8 days')",[reference,user]);
 await db.query('delete from auth.users where id=$1',[user]);
 expect((await db.query('select user_id,url from billing_checkout_intents where id=$1',[reference])).rows).toEqual([{user_id:null,url:null}]);
 await db.query('select purge_billing_checkout_intents()');
 expect((await db.query('select id from billing_checkout_intents where id=$1',[reference])).rows).toEqual([]);
});
it('requires explicit current billing terms and records consent time',async()=>{
 const user=randomUUID();await db.query('insert into auth.users(id) values($1)',[user]);await db.query('insert into billing_accounts(user_id) values($1)',[user]);
 for(const terms of [null,'2026-10-07'])await expect(db.query("select billing_claim_checkout($1,'monthly',$2)",[user,terms])).rejects.toThrow(/billing_terms_required/);
 await db.query("select billing_claim_checkout($1,'monthly','2026-10-08')",[user]);
 expect((await db.query('select accepted_terms_version,accepted_at is not null as accepted from billing_checkout_intents where user_id=$1',[user])).rows).toEqual([{accepted_terms_version:'2026-10-08',accepted:true}]);
});

it('late old-subscription webhook cannot consume a replacement checkout',async()=>{
 const user=randomUUID();const oldIntent=randomUUID();
 await db.query('insert into auth.users(id) values($1)',[user]);
 await db.query("insert into billing_accounts(user_id,subscription_id,status,provider_updated_at) values($1,'old-sub','expired','2026-01-01')",[user]);
 await db.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,consumed_at) values($1,$2,'monthly','2026-10-08',now())",[oldIntent,user]);
 const fresh=(await db.query<{id:string}>("select (billing_claim_checkout($1,'monthly','2026-10-08')).id",[user])).rows[0].id;
 await db.query('select billing_apply_subscription($1,$2,$3,$4,$5,$6,$7,$8,$9)',[user,'late-old',oldIntent,'old-sub','12','monthly','expired',null,'2026-02-01']);
 expect((await db.query('select consumed_at from billing_checkout_intents where id=$1',[fresh])).rows).toEqual([{consumed_at:null}]);
 await db.query('select billing_apply_subscription($1,$2,$3,$4,$5,$6,$7,$8,$9)',[user,'paid-new',fresh,'new-sub','12','monthly','active','2026-12-01','2026-03-01']);
 expect((await db.query('select subscription_id,status from billing_accounts where user_id=$1',[user])).rows).toEqual([{subscription_id:'new-sub',status:'active'}]);
});
it('first sync retry after onboarding expiry uses the same total dollar; standalone AI stays denied',async()=>{
 const user=randomUUID();const old=new Date(Date.now()-3*86400_000).toISOString();
 await db.query('insert into auth.users(id) values($1)',[user]);await db.query('insert into billing_accounts(user_id,onboarding_started_at) values($1,$2)',[user,old]);
 await db.query("insert into ai_spend_attempts(id,user_id,endpoint,model,reserved_usd,cost_usd,created_at) values($1,$2,'chat','m',0.8,0.8,$3)",[randomUUID(),user,old]);
 await expect(db.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.1,3,1)",[user,randomUUID()])).rejects.toThrow(/subscription_required/);
 await expect(db.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.3,3,1,true)",[user,randomUUID()])).rejects.toThrow(/ai_budget_exhausted/);
 await db.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.2,3,1,true)",[user,randomUUID()]);
 await db.query('select billing_start_trial($1)',[user]);
 const account=(await db.query<{onboarding_started_at:Date;trial_ends_at:Date}>('select onboarding_started_at,trial_ends_at from billing_accounts where user_id=$1',[user])).rows[0];
 expect(new Date(account.onboarding_started_at).toISOString()).toBe(old);
 expect(new Date(account.trial_ends_at).getTime()).toBeGreaterThan(Date.now()+6.9*86400_000);
});
