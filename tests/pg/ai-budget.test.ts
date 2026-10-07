import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, expect, it } from "vitest";
import { supabaseSchemaScripts } from "../db/local-supabase";
const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error("DATABASE_URL is required for actual Postgres budget contention tests");
const database = `taskforce_budget_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let a: pg.Client;
let b: pg.Client;
const user = randomUUID();
beforeAll(async () => {
  admin = new pg.Client({ connectionString }); await admin.connect();
  await admin.query(`create database ${database}`);
  const url = new URL(connectionString!); url.pathname = `/${database}`;
  a = new pg.Client({ connectionString: url.toString() }); b = new pg.Client({ connectionString: url.toString() });
  await a.connect(); await b.connect();
  for (const sql of await supabaseSchemaScripts()) await a.query(sql);
  await a.query("update ai_budget_policy set user_daily_usd=1000, global_daily_usd=1000, global_total_usd=1000");
  await a.query("insert into auth.users(id) values($1)", [user]);
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end()]);
  if (admin) { await admin.query(`drop database if exists ${database} with (force)`); await admin.end(); }
});
it("simultaneous mixed routes cannot jointly reserve above $10", async () => {
  await a.query("select reserve_ai_spend($1,$2,'chat','m',9)", [user, randomUUID()]);
  await a.query("begin");
  await a.query("select reserve_ai_spend($1,$2,'embeddings','m',0.6)", [user, randomUUID()]);
  const pending = b.query("select reserve_ai_spend($1,$2,'decisions','m',0.6)", [user, randomUUID()]).then(() => "admitted", (error: Error) => error.message);
  await a.query("commit");
  expect(await pending).toMatch(/ai_budget_exhausted/);
  const { rows } = await a.query("select sum(coalesce(cost_usd,reserved_usd))::text total from ai_spend_attempts where user_id=$1", [user]);
  expect(Number(rows[0].total)).toBe(9.6);
});

it("different users compete atomically for shared daily allowance", async () => {
  await a.query("truncate ai_spend_attempts");
  await a.query("update ai_budget_policy set global_daily_usd=.5,user_daily_usd=.5,global_total_usd=50");
  const other = randomUUID();
  await a.query("insert into auth.users(id) values($1)", [other]);
  await a.query("begin");
  await a.query("select reserve_ai_spend($1,$2,'chat','m',.3)", [user,randomUUID()]);
  const pending=b.query("select reserve_ai_spend($1,$2,'decisions','m',.3)",[other,randomUUID()]).then(()=>"admitted",(error:Error)=>error.message);
  await a.query("commit");
  expect(await pending).toMatch(/ai_global_daily_budget_exhausted/);
});
it("different users compete atomically for shared lifetime allowance", async () => {
  await a.query("truncate ai_spend_attempts");
  await a.query("update ai_budget_policy set global_daily_usd=5,user_daily_usd=.5,global_total_usd=.5");
  const other = randomUUID();
  await a.query("insert into auth.users(id) values($1)", [other]);
  await a.query("begin");
  await a.query("select reserve_ai_spend($1,$2,'chat','m',.3)", [user,randomUUID()]);
  const pending=b.query("select reserve_ai_spend($1,$2,'embeddings','m',.3)",[other,randomUUID()]).then(()=>"admitted",(error:Error)=>error.message);
  await a.query("commit");
  expect(await pending).toMatch(/ai_global_budget_exhausted/);
});

it("in-flight settlement records known cost after a concurrent account deletion", async () => {
  await a.query("truncate ai_spend_attempts");
  await a.query("update ai_budget_policy set global_daily_usd=5,user_daily_usd=2,global_total_usd=50");
  const deleted = randomUUID(), id = randomUUID();
  await a.query("insert into auth.users(id) values($1)", [deleted]);
  await a.query("select reserve_ai_spend($1,$2,'chat','m',.3)", [deleted,id]);
  await a.query("begin");
  await a.query("delete from auth.users where id=$1", [deleted]);
  const pending = b.query("select settle_ai_spend($1,$2,.1,'gen-after-delete')", [deleted,id]);
  await a.query("commit");
  await pending;
  expect((await a.query("select user_id,cost_usd,generation_id from ai_spend_attempts where id=$1", [id])).rows)
    .toEqual([{ user_id: null, cost_usd: "0.1", generation_id: "gen-after-delete" }]);
});
