import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, expect, it } from "vitest";
import { supabaseSchemaScripts } from "../db/local-supabase";
const connectionString = process.env.DATABASE_URL;
if (!connectionString)
    throw new Error("DATABASE_URL is required for actual Postgres budget contention tests");
const database = `taskforce_billing_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let a: pg.Client;
let b: pg.Client;
const user = randomUUID();
beforeAll(async () => {
    admin = new pg.Client({ connectionString });
    await admin.connect();
    await admin.query(`create database ${database}`);
    const url = new URL(connectionString!);
    url.pathname = `/${database}`;
    a = new pg.Client({ connectionString: url.toString() });
    b = new pg.Client({ connectionString: url.toString() });
    await a.connect();
    await b.connect();
    for (const sql of await supabaseSchemaScripts())
        await a.query(sql);
    await a.query("insert into auth.users(id) values($1)", [user]);
});
afterAll(async () => {
    await Promise.allSettled([a?.end(), b?.end()]);
    if (admin) {
        await admin.query(`drop database if exists ${database} with (force)`);
        await admin.end();
    }
});
it("concurrent paid requests share one cap across endpoints", async () => {
    await a.query("insert into billing_accounts(user_id,status,current_period_ends_at) values($1,'active',now()+interval '1 month')", [user]);
    await a.query("begin");
    await a.query("select reserve_billing_ai_spend($1,$2,'chat','m',2,3,1)", [user, randomUUID()]);
    const pending = b.query("select reserve_billing_ai_spend($1,$2,'embeddings','m',2,3,1)", [user, randomUUID()]).then(() => "admitted", (error: Error) => error.message);
    await a.query("commit");
    expect(await pending).toMatch(/ai_budget_exhausted/);
});
it("account lock permits only one checkout claim", async () => {
    await a.query("begin");
    await a.query("select billing_claim_checkout($1,'monthly','2026-10-08')", [user]);
    const pending = b.query("select billing_claim_checkout($1,'annual','2026-10-08')", [user]).then(() => "admitted", (error: Error) => error.message);
    await a.query("commit");
    expect(await pending).toMatch(/billing_checkout_pending/);
});
it("simultaneous deletion claims cannot overwrite the active operation token",async()=>{
 const account=randomUUID(),first=randomUUID(),second=randomUUID();
 await a.query('insert into auth.users(id) values($1)',[account]);
 await a.query('insert into billing_accounts(user_id) values($1)',[account]);
 await a.query('begin');
 expect((await a.query('update billing_accounts set deleting=true,deleting_token=$2 where user_id=$1 and deleting=false returning deleting_token',[account,first])).rowCount).toBe(1);
 const next=b.query('update billing_accounts set deleting=true,deleting_token=$2 where user_id=$1 and deleting=false returning deleting_token',[account,second]);
 await a.query('commit');expect((await next).rowCount).toBe(0);
 await b.query('update billing_accounts set deleting=false,deleting_token=null where user_id=$1 and deleting_token=$2',[account,second]);
 expect((await a.query('select deleting,deleting_token from billing_accounts where user_id=$1',[account])).rows).toEqual([{deleting:true,deleting_token:first}]);
});
it("legacy and paid requests serialize against the same global cap",async()=>{
 const paid=randomUUID(),legacy=randomUUID();
 await a.query('insert into auth.users(id) values($1),($2)',[paid,legacy]);
 await a.query("insert into billing_accounts(user_id,status,current_period_ends_at) values($1,'active',now()+interval '1 month')",[paid]);
 await a.query('update ai_budget_policy set global_daily_usd=(select coalesce(sum(coalesce(cost_usd,reserved_usd)),0)+3 from ai_spend_attempts)');
 await a.query('begin');
 await a.query("select reserve_billing_ai_spend($1,$2,'chat','m',2,3,1)",[paid,randomUUID()]);
 const pending=b.query("select reserve_ai_spend($1,$2,'chat','m',2)",[legacy,randomUUID()]).then(()=>"admitted",(error:Error)=>error.message);
 await a.query('commit');expect(await pending).toMatch(/ai_global_daily_budget_exhausted/);
});

it.each(['refunded', 'expired', 'past_due', 'cancelled'])('%s subscription cannot restart trial or reserve its allowance', async status => {
    const account = randomUUID();
    await a.query('insert into auth.users(id) values($1)', [account]);
    await a.query('insert into billing_accounts(user_id, subscription_id, status) values($1,$2,$3)', [account, randomUUID(), status]);
    await a.query('select billing_start_trial($1)', [account]);
    expect((await a.query('select trial_ends_at from billing_accounts where user_id=$1', [account])).rows[0].trial_ends_at).toBeNull();
    for (const previousTrial of [false, true]) {
        if (previousTrial) await a.query("update billing_accounts set trial_ends_at=now()+interval '7 days' where user_id=$1", [account]);
        await expect(a.query('select billing_spend_summary($1,3,1)', [account])).rejects.toThrow(/subscription_required/);
        for (const initialSync of [false, true]) {
            await expect(a.query("select reserve_billing_ai_spend($1,$2,'chat','m',0.01,3,1,$3)", [account, randomUUID(), initialSync])).rejects.toThrow(/subscription_required/);
        }
    }
});

it('keeps genuine trial, legacy notice, and cancelled paid-through windows', async () => {
    const trial = randomUUID(), legacy = randomUUID(), cancelled = randomUUID();
    await a.query('insert into auth.users(id) values($1),($2),($3)', [trial, legacy, cancelled]);
    await a.query('select billing_start_trial($1)', [trial]);
    await a.query('insert into billing_accounts(user_id,legacy_beta) values($1,true)', [legacy]);
    await a.query("insert into billing_accounts(user_id,subscription_id,status,current_period_ends_at) values($1,$2,'cancelled',now()+interval '1 day')", [cancelled, randomUUID()]);
    for (const [account, cap] of [[trial, '1'], [legacy, '10'], [cancelled, '3']]) {
        expect((await a.query('select cap from billing_spend_window($1,3,1)', [account])).rows[0].cap).toBe(cap);
    }
});
