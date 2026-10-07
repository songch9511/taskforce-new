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
