import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, expect, it } from "vitest";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
const f = bridgeCommandFixtures(() => ({
  query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
  asUser: (user, fn) => asUser(db, user, fn),
}));

const expire = async (w: { step: string }) => {
  await f.updateRow("execution_steps", w.step, { lease_expires_at: "2000-01-01" });
  await f.q("select public.sweep_agent_step_leases(null)");
};
const outcome = (command: string) => f.one("select outcome,outcome_at from public.bridge_commands where id=$1", [command]);

it("review3 unknown report reattaches, expires again, and returns to readbacks", async () => {
  const w = await f.world();
  await f.lease(w);
  await expire(w);
  expect(await f.settle(w, "readback", "unknown")).toMatchObject({status:"settled"});
  expect((await f.list(w)).readbacks).toEqual([]);
  expect(await f.bridgeEvent(w, f.event(w, "unreachable"))).toMatchObject({status:"applied"});
  const calling = await f.one("select state from public.execution_steps where id=$1", [w.step]);
  const cleared = await outcome(w.command);
  await expire(w);
  expect({calling, cleared, listed:(await f.list(w)).readbacks.map(row=>row.command_id)})
    .toEqual({calling:{state:"calling"}, cleared:{outcome:null,outcome_at:null}, listed:[w.command]});
});

it("review3 entering calling through lease clears previous observation", async () => {
  const w = await f.world();
  await f.updateRow("bridge_commands", w.command, {outcome:"unknown",outcome_at:"2000-01-01"});
  expect(await f.lease(w)).toMatchObject({status:"leased"});
  expect(await outcome(w.command)).toEqual({outcome:null,outcome_at:null});
});

it.each(["never_leased", "settled"])("review3 stale readback leaves %s command unchanged", async phase => {
  const w = await f.world();
  if (phase === "settled") {
    await f.lease(w);
    await f.settle(w, "readback", "received");
  }
  const before = await f.snapshot(w);
  expect(await f.settle(w, "readback", "invalid_result")).toEqual({status:"stale"});
  expect(await f.snapshot(w)).toEqual(before);
});

it("review3 rejected reattachment preserves reported outcome and transition history", async () => {
  const w = await f.world();
  await f.lease(w);
  await expire(w);
  await f.settle(w, "readback", "unknown");
  const before = await f.snapshot(w), events = await f.events(w);
  expect(await f.bridgeEvent(w, f.event(w, "accepted", {adapter:"agent:claude-code"}))).toMatchObject({status:"not_found"});
  expect(await f.snapshot(w)).toEqual(before);
  expect(await f.events(w)).toEqual(events);
});
