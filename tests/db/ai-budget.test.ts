import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
const alice = randomUUID();
const bob = randomUUID();
const reserve = async (user: string, amount: number, endpoint = "chat") => {
  const id = randomUUID();
  await db.query("select reserve_ai_spend($1,$2,$3,$4,$5)", [user, id, endpoint, "model", amount]);
  return id;
};
const settle = (user: string, id: string, cost: number | null, generation: string | null = null) =>
  db.query("select settle_ai_spend($1,$2,$3,$4)", [user, id, cost, generation]);
beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("update ai_budget_policy set user_daily_usd=1000, global_daily_usd=1000, global_total_usd=1000");
  await db.query("insert into auth.users(id) values ($1),($2)", [alice, bob]);
}, 60_000);
afterAll(async () => { await db?.close(); });

describe("cumulative USD AI budget", () => {
  it("mixed routes share $10 and unknown spend stays reserved across time", async () => {
    const id = await reserve(alice, 9, "decisions");
    await settle(alice, id, null, "gen-pending");
    await db.query("update ai_spend_attempts set created_at = now() - interval '2 months'");
    await reserve(alice, 1, "embeddings");
    await expect(reserve(alice, 0.01)).rejects.toThrow(/ai_budget_exhausted/);
    await settle(alice, id, 8);
    await reserve(alice, 1);
    await expect(reserve(alice, 0.01)).rejects.toThrow(/ai_budget_exhausted/);
  });
  it("settlement is idempotent, immutable and user-scoped", async () => {
    const id = await reserve(bob, 1);
    await expect(settle(alice, id, 0)).rejects.toThrow(/ai_attempt_not_found/);
    await settle(bob, id, 0.25);
    await settle(bob, id, 0.25);
    await expect(settle(bob, id, 0)).rejects.toThrow(/ai_cost_already_confirmed/);
    await reserve(bob, 9.75);
    await expect(reserve(bob, 0.01)).rejects.toThrow(/ai_budget_exhausted/);
  });
  it("records provider overrun truthfully and freezes further admission", async () => {
    const user = randomUUID();
    await db.query("insert into auth.users(id) values($1)", [user]);
    const id = await reserve(user, 0.1);
    await settle(user, id, 0.2);
    await expect(reserve(user, 0.1)).rejects.toThrow(/ai_provider_bound_breached/);
    const { rows } = await db.query<{ cost: string }>("select cost_usd::text cost from ai_spend_attempts where id=$1", [id]);
    expect(rows[0].cost).toBe("0.2");
  });
  it("rejects invalid reservations and client mutations; owners only read their ledger", async () => {
    await expect(reserve(bob, 0)).rejects.toThrow();
    await expect(reserve(bob, -1)).rejects.toThrow();
    await asUser(db, alice, async () => {
      await expect(reserve(alice, 1)).rejects.toThrow(/permission denied/);
      await expect(db.query("delete from ai_spend_attempts")).rejects.toThrow(/permission denied/);
      const { rows } = await db.query<{ user_id: string }>("select distinct user_id from ai_spend_attempts");
      expect(rows).toEqual([{ user_id: alice }]);
    });
  });
});

it("summary aggregates only the requested account and keeps pending holds", async () => {
  const user = randomUUID();
  await db.query("insert into auth.users(id) values($1)", [user]);
  const id = await reserve(user, 2);
  await settle(user, id, 1.25);
  await reserve(user, 3, "embeddings");
  const { rows } = await db.query<{ summary: unknown }>("select ai_spend_summary($1) summary", [user]);
  expect(rows[0].summary).toEqual({ cap_usd: 10, confirmed_usd: 1.25, reserved_usd: 3, pending_count: 1, remaining_usd: 5.75, status: "available" });
  await asUser(db, bob, async () => {
    await expect(db.query("select ai_spend_summary($1)", [user])).rejects.toThrow(/permission denied/);
  });
});

it("summary reports zero only for a truly empty beta ledger and distinguishes an upstream violation", async () => {
  const user = randomUUID();
  await db.query("insert into auth.users(id) values($1)", [user]);
  const summary = async () => (await db.query<{ value: unknown }>("select ai_spend_summary($1) value", [user])).rows[0].value;
  expect(await summary()).toEqual({ cap_usd: 10, confirmed_usd: 0, reserved_usd: 0, pending_count: 0, remaining_usd: 10, status: "available" });
  const id = await reserve(user, 10);
  expect(await summary()).toMatchObject({ remaining_usd: 0, reserved_usd: 10, pending_count: 1, status: "exhausted" });
  await settle(user, id, 11);
  expect(await summary()).toMatchObject({ confirmed_usd: 11, remaining_usd: 0, reserved_usd: 0, pending_count: 0, status: "provider_bound_violation" });
});
