import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, expect, it } from "vitest";
import { asUser, createLocalSupabase } from "./local-supabase";
let db: PGlite;
const alice = randomUUID(), bob = randomUUID();
const reserve = async (user = alice, amount = 0.3) => {
  const id = randomUUID();
  await db.query("select reserve_ai_spend($1,$2,'chat','model',$3)", [user,id,amount]);
  return id;
};
const settle = (id: string, amount: number, user: string | null = alice) => db.query("select settle_ai_spend($1,$2,$3,null)", [user,id,amount]);
beforeAll(async () => { db=await createLocalSupabase(); },60_000);
beforeEach(async () => {
  await db.exec("truncate ai_spend_attempts; delete from auth.users; update ai_budget_policy set user_daily_usd=.5,global_daily_usd=5,global_total_usd=50;");
  await db.query("insert into auth.users(id) values($1),($2)",[alice,bob]);
});
afterAll(async()=>{ await db?.close(); });
it("default operator policy allows $3 per user, $5 daily, $50 total",async()=>{
  await db.exec("delete from ai_budget_policy; insert into ai_budget_policy(singleton) values(true)");
  expect((await db.query("select user_daily_usd::text,global_daily_usd::text,global_total_usd::text from ai_budget_policy")).rows).toEqual([{user_daily_usd:"3",global_daily_usd:"5",global_total_usd:"50"}]);
});
it("enforces user daily amount and settlement releases only confirmed excess",async()=>{
  const id=await reserve();
  await expect(reserve()).rejects.toThrow("ai_user_daily_budget_exhausted");
  await settle(id,.1);
  await reserve(alice,.4);
  await expect(reserve(alice,.000001)).rejects.toThrow("ai_user_daily_budget_exhausted");
});
it("unknown holds survive midnight but confirmed prior days do not consume today",async()=>{
  const id=await reserve();
  await db.exec("update ai_spend_attempts set created_at=now()-interval '2 days'");
  await expect(reserve()).rejects.toThrow("ai_user_daily_budget_exhausted");
  await settle(id,.3);
  await reserve(alice,.5);
});
it("global daily combines accounts and old unknown holds",async()=>{
  await db.exec("update ai_budget_policy set global_daily_usd=.5");
  await reserve();
  await db.exec("update ai_spend_attempts set created_at=now()-interval '2 days'");
  await expect(reserve(bob)).rejects.toThrow("ai_global_daily_budget_exhausted");
});
it("global lifetime survives account deletion and anonymous holds can reconcile",async()=>{
  await db.exec("update ai_budget_policy set global_total_usd=.5");
  const id=await reserve();
  await db.query("delete from auth.users where id=$1",[alice]);
  await expect(reserve(bob)).rejects.toThrow("ai_global_budget_exhausted");
  await settle(id,.1,null);
  await reserve(bob,.4);
  const {rows}=await db.query("select user_id,cost_usd from ai_spend_attempts where id=$1",[id]);
  expect(rows).toEqual([{user_id:null,cost_usd:"0.1"}]);
  await asUser(db,bob,async()=>{expect((await db.query("select id from ai_spend_attempts where id=$1",[id])).rows).toEqual([]);});
});
it("policy is fail closed and inaccessible to end users",async()=>{
  await asUser(db,alice,async()=>{
    await expect(db.query("select * from ai_budget_policy")).rejects.toThrow(/permission denied/);
    await expect(db.query("update ai_budget_policy set user_daily_usd=10")).rejects.toThrow(/permission denied/);
  });
  await db.exec("delete from ai_budget_policy");
  await expect(reserve()).rejects.toThrow("ai_budget_policy_unavailable");
  await db.exec("insert into ai_budget_policy(singleton) values(true)");
});

it("in-flight service settlement survives account deletion without accepting another live owner", async () => {
  const id = await reserve();
  await expect(db.query("select settle_ai_spend($1,$2,.1,'gen-inflight')", [bob, id])).rejects.toThrow("ai_attempt_not_found");
  await expect(db.query("select settle_ai_spend(null,$1,.1,'gen-inflight')", [id])).rejects.toThrow("ai_attempt_not_found");
  await db.query("delete from auth.users where id=$1", [alice]);
  await asUser(db, bob, async () => {
    await expect(db.query("select settle_ai_spend($1,$2,.1,'gen-inflight')", [alice, id])).rejects.toThrow(/permission denied/);
  });
  await db.query("select settle_ai_spend($1,$2,.1,'gen-inflight')", [alice, id]);
  expect((await db.query("select user_id,cost_usd,generation_id from ai_spend_attempts where id=$1", [id])).rows)
    .toEqual([{ user_id: null, cost_usd: "0.1", generation_id: "gen-inflight" }]);
});
