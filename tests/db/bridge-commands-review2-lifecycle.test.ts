import type { PGlite } from "@electric-sql/pglite";
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, expect, it } from "vitest";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
const f = bridgeCommandFixtures(() => ({
  query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
  asUser: (user, fn) => asUser(db, user, fn),
}));

it("review2 Stop and task_unknown still settle a not_received readback", async () => {
  const w = await f.world();
  await f.lease(w);
  await f.updateRow("execution_steps", w.step, { lease_expires_at: "2000-01-01" });
  await f.q("select public.sweep_agent_step_leases(now())");
  await f.stop(w.user, w.session);
  const cancel = String((await f.one("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'", [w.task])).id);
  await f.lease({ ...w, command: cancel });
  await f.settle({ ...w, command: cancel }, "complete", "task_unknown");
  const task = await f.one("select * from public.agent_tasks where id=$1", [w.task]), message = await f.msg(w.message);
  expect((await f.list(w)).readbacks).toHaveLength(1);
  expect(await f.settle(w, "readback", "not_received", true)).toEqual({ status: "settled", task_state: "cancelled" });
  expect(await f.one("select * from public.agent_tasks where id=$1", [w.task])).toEqual(task);
  expect(await f.msg(w.message)).toEqual(message);
  expect(await f.one("select state,receipt,lease_owner,lease_expires_at from public.execution_steps where id=$1", [w.step]))
    .toEqual({ state: "failed", receipt: { reason: "not_received" }, lease_owner: null, lease_expires_at: null });
  expect(await f.one("select outcome,outcome_at is not null as reported from public.bridge_commands where id=$1", [w.command]))
    .toEqual({ outcome: "not_received", reported: true });
  expect((await f.list(w)).readbacks).toEqual([]);
});

it("review2 stale readback records its server observation time", async () => {
  const w = await f.world();
  await f.lease(w);
  await f.updateRow("execution_steps", w.step, { lease_expires_at: "2000-01-01" });
  await f.q("select public.sweep_agent_step_leases(now())");
  const before = await f.one("select * from public.execution_steps where id=$1", [w.step]);
  expect(await f.settle(w, "readback", "invalid_result")).toEqual({ status: "stale" });
  expect(await f.one("select * from public.execution_steps where id=$1", [w.step])).toEqual(before);
  expect(await f.one("select outcome,outcome_at is not null as reported from public.bridge_commands where id=$1", [w.command]))
    .toEqual({ outcome: "unknown", reported: true });
  expect((await f.list(w)).readbacks).toEqual([]);
});

it.each(["running", "unreachable"])("review2 revoke terminalizes external %s task with uncertainty", async state => {
  const w = await f.world();
  await f.lease(w);
  await f.updateRow("agent_tasks", w.task, { state, last_live_state: "accepted" });
  await f.updateRow("agent_sessions", w.session, { status: "external" });
  expect((await f.one("select public.revoke_bridge($1,$2) as result", [w.user, w.bridge])).result)
    .toMatchObject({ status: "revoked", tasks: [{ agent_task_id: w.task, cancel: "requested_only" }] });
  expect(await f.one("select state,last_live_state,cancel_requested_at is not null as requested from public.agent_tasks where id=$1", [w.task]))
    .toEqual({ state: "cancelled", last_live_state: state === "unreachable" ? "accepted" : "running", requested: true });
});

it("review2 expired answer does not restore an unreachable task card", async () => {
  const w = await f.world();
  await f.lease(w);
  await f.bridgeEvent(w, f.event(w, "question", { text: "Choose", question: answerQuestionFixture() }));
  const answer = await f.answer(w.user, w.task);
  const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [answer.step_id])).id);
  await f.q("update public.execution_steps set args=args-'answers' where id=$1", [answer.step_id]);
  await f.q("select public.prepare_step(id,version) from public.execution_steps where id=$1", [answer.step_id]);
  await f.updateRow("agent_tasks", w.task, { state: "unreachable", last_live_state: "running" });
  const task = await f.one("select * from public.agent_tasks where id=$1", [w.task]);
  expect(await f.lease({ ...w, command })).toEqual({ status: "withdrawn", reason: "expired" });
  expect(await f.one("select * from public.agent_tasks where id=$1", [w.task])).toEqual(task);
});

it.each(["write_gate_closed", "not_connected", "adapter_disabled", "not_received", "unsupported", "sign_in_needed", "usage_limited", "spawn_failed"])("review2 N11 redelivery SQL filters %s", async reason => {
  const w = await f.world();
  await f.lease(w, null);
  await f.updateRow("conversation_messages", w.message, { delivery_reason: reason });
  const rows = await f.q("select * from public.bridge_redelivery_candidates(10000)");
  expect(rows.filter(row => row.user_id === w.user)).toEqual(
    ["write_gate_closed", "not_connected", "adapter_disabled"].includes(reason)
      ? [{ user_id: w.user, agent_session_id: w.session, conversation_id: w.conversation }] : [],
  );
});

it.each([false, true])("review2 N12 unbound SQL filters head state with retry=%s", async retry => {
  const w = await f.turnWorld();
  await f.updateRow("conversation_messages", w.message, { delivery_state: "not_sent", delivery_reason: "not_received" });
  await f.post(w.user, w.conversation, randomUUID(), "Queued behind blocked head");
  const read = () => f.one("select public.next_unbound_agent_messages($1,$2,5,$3) as ids", [w.user, w.connection, retry]);
  expect(await read()).toEqual({ ids: [] });
  await f.updateRow("conversation_messages", w.message, { delivery_reason: "write_gate_closed" });
  expect(await read()).toEqual({ ids: retry ? [w.message] : [] });
  await f.updateRow("conversation_messages", w.message, { delivery_state: "queued", delivery_reason: null });
  expect(await read()).toEqual({ ids: [w.message] });
});
