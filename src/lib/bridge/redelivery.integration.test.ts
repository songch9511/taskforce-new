import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import { createLocalSupabase, asUser } from "../../../tests/db/local-supabase";
import { bridgeCommandFixtures } from "../../../tests/db/bridge-commands.scenarios";
import { kickBridgeSessions, redeliverBridgeMessages } from "./triggers";
import { heartbeatBridge } from "./heartbeat";
import { sweepBridge } from "./sweep";
let db: PGlite;
const f = bridgeCommandFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
beforeAll(async () => { db = await createLocalSupabase(); vi.stubEnv("EXECUTION_ENABLED", "true"); }, 60_000);
afterAll(async () => { vi.unstubAllEnvs(); await db?.close(); });
// Only the PostgREST operations exercised by these production bridge paths.
function admin(): SupabaseClient {
  const rpc = (name: string, args: Record<string, unknown>) => ({ throwOnError: async () => {
    const entries = Object.entries(args);
    if (name === "bridge_redelivery_candidates" || name === "sweep_bridge_heartbeats") return { data: (await db.query(`select * from public.${name}(p_limit => $1)`, [args.p_limit])).rows };
    const { rows } = await db.query<{ value: unknown }>(`select public.${name}(${entries.map(([key], i) => `${key} => $${i + 1}`).join(",")}) as value`, entries.map(([key, value]) => ["p_tasks", "p_report", "p_event"].includes(key) && value !== null ? JSON.stringify(value) : value));
    return { data: rows[0].value };
  } });
  const from = (table: string) => {
    let columns = "*", single = false, limit = "";
    const conditions: string[] = [], values: unknown[] = [], orders: string[] = [];
    const column = (name: string) => name.includes("->>") ? name.replace(/->>(.+)$/, "->>'$1'") : name;
    const q = {
      select: (value: string) => { columns = value; return q; },
      eq: (key: string, value: unknown) => { values.push(value); conditions.push(`${column(key)}=$${values.length}`); return q; },
      in: (key: string, value: unknown[]) => { values.push(value); conditions.push(`${column(key)}=any($${values.length})`); return q; },
      order: (key: string) => { orders.push(key); return q; },
      limit: (value: number) => { limit = ` limit ${value}`; return q; },
      maybeSingle: () => { single = true; return q; },
      throwOnError: async () => {
        const { rows } = await db.query(`select ${columns} from public.${table}${conditions.length ? ` where ${conditions.join(" and ")}` : ""}${orders.length ? ` order by ${orders.join(",")}` : ""}${limit}`, values);
        return { data: single ? rows[0] ?? null : rows };
      },
    };
    return q;
  };
  return { rpc, from } as unknown as SupabaseClient;
}
async function counts(user: string) {
  return Promise.all(["agent_tasks", "execution_steps", "bridge_commands", "metric_events"].map(async (table) => (await f.one(`select count(*)::int n from public.${table} where user_id=$1`, [user])).n));
}
const capabilities = { adapters: { "agent:codex": { installed: true, version: "0.162.1", signed_in: "yes", managed_settings: false } } };
it("review3 excludes a deleted Action chip head and starts the next message without rewriting the failed head", async () => {
  const w = await f.world();
  await f.updateRow("agent_sessions", w.session, { status: "bound", external_session_id: `session:${randomUUID()}` });
  await f.updateRow("bridges", w.bridge, { capabilities });
  await f.lease(w);
  await f.bridgeEvent(w, f.event(w, "accepted"));
  await f.bridgeEvent(w, f.event(w, "turn_completed"));
  const chip = await f.action(w.user);
  const m2 = String((await f.post(w.user, w.conversation, randomUUID(), "Uses a deleted chip")).message_id);
  const refs = { agent_turn: { action_ids: [chip], context_ids: [] } };
  await f.updateRow("conversation_messages", m2, { delivery_state: "queued", delivery_reason: "session_busy", refs });
  await f.q("delete from public.actions where id=$1", [chip]);
  const m3 = String((await f.post(w.user, w.conversation, randomUUID(), "Plain follow-up")).message_id);
  await f.updateRow("conversation_messages", m3, { delivery_state: "queued", delivery_reason: "queue_order" });
  const before = await counts(w.user), client = admin();
  const rpc = vi.spyOn(client, "rpc");
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await f.msg(m2)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "not_found" });
  expect(await f.msg(m3)).toMatchObject({ delivery_state: "queued" });
  expect(await counts(w.user)).toEqual(before);
  const failedHead = await f.one("select *,xmin::text as row_version from public.conversation_messages where id=$1", [m2]);
  expect(failedHead.refs).toEqual(refs);
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await f.msg(m3)).toMatchObject({ delivery_state: "dispatched", delivery_reason: null });
  const after = await counts(w.user);
  expect(after.slice(0, 3)).toEqual(before.slice(0, 3).map(n => Number(n) + 1));
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await counts(w.user)).toEqual(after);
  expect(await f.one("select *,xmin::text as row_version from public.conversation_messages where id=$1", [m2])).toEqual(failedHead);
  expect(rpc.mock.calls.filter(([name]) => name === "route_agent_message").map(([, args]) => args?.p_message_id)).toEqual([m2, m3]);
});
it.each(["gate", "decline", "preaccept", "not_received"])("%s keeps the failed FIFO head and later messages unchanged through kicks and heartbeat", async (kind) => {
  const w = await f.world();
  await f.updateRow("agent_sessions", w.session, { status: "bound", external_session_id: `session:${randomUUID()}` });
  await f.updateRow("bridges", w.bridge, { capabilities });
  if (kind === "gate") expect(await f.lease(w, null)).toMatchObject({ status: "withdrawn", reason: "write_gate_closed" });
  else if (kind === "decline") expect(await f.settle(w, "decline", "unsupported_kind")).toMatchObject({ status: "withdrawn", reason: "unsupported" });
  else {
    expect(await f.lease(w)).toMatchObject({ status: "leased" });
    if (kind === "preaccept") expect(await f.bridgeEvent(w, f.event(w, "failed", { payload: { reason: "spawn_failed" } }))).toMatchObject({ status: "applied", task_state: "failed" });
    if (kind === "not_received") expect(await f.settle(w, "readback", "not_received", true)).toMatchObject({ status: "settled", task_state: "failed" });
  }
  const next = await f.post(w.user, w.conversation, randomUUID(), "Waiting behind failed head");
  await f.q("update public.conversation_messages set delivery_state='queued',delivery_reason=null where id=$1", [next.message_id]);
  const before = await counts(w.user);
  const client = admin();
  await kickBridgeSessions(client, w.user, [w.session]);
  await f.q("update public.bridges set last_heartbeat_at=public.db_now()-interval '6 seconds' where id=$1", [w.bridge]);
  const heartbeat = await heartbeatBridge(client, { userId: w.user, bridge: { id: w.bridge, status: "active", secret_hash: null, capabilities }, input: { bridge_id: w.bridge, sent_at: new Date().toISOString(), tasks: [] } });
  expect(heartbeat).toMatchObject({ heartbeat_interval_seconds: 30 });
  expect(await counts(w.user)).toEqual(before);
  expect(await f.one("select delivery_state from public.conversation_messages where id=$1", [next.message_id])).toEqual({ delivery_state: "queued" });
  if (kind === "gate") {
    await redeliverBridgeMessages(client, { EXECUTION_ENABLED: "true" });
    const after = await counts(w.user);
    expect(after.slice(0, 3)).toEqual(before.slice(0, 3).map(n => Number(n) + 1));
    await redeliverBridgeMessages(client, { EXECUTION_ENABLED: "true" });
    expect(await counts(w.user)).toEqual(after);
  } else {
    await redeliverBridgeMessages(client, { EXECUTION_ENABLED: "true" });
    expect(await counts(w.user)).toEqual(before);
  }
});

it.each(["unknown", "cancelled", "stale"])("a reported %s readback does not end long polling", async (state) => {
  const { pollBridgeCommands } = await import("./commands");
  const w = await f.world();
  await f.lease(w);
  await f.updateRow("execution_steps", w.step, { lease_expires_at: "2000-01-01T00:00:00Z" });
  await f.q("select public.sweep_agent_step_leases(public.db_now())");
  expect((await f.list(w)).readbacks).toHaveLength(1);
  if (state === "cancelled") {
    await f.stop(w.user, w.session);
    const cancel = String((await f.one("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'", [w.task])).id);
    await f.lease({ ...w, command: cancel });
    await f.settle({ ...w, command: cancel }, "complete", "task_unknown");
    expect(await f.settle(w, "readback", "not_received", true)).toMatchObject({ status: "settled", task_state: "cancelled" });
  } else if (state === "stale") {
    await f.updateRow("execution_steps", w.step, { state: "failed" });
    expect(await f.settle(w, "readback", "received")).toMatchObject({ status: "stale" });
  } else expect(await f.settle(w, "readback", "unknown")).toMatchObject({ status: "settled" });
  const client = admin();
  const originalRpc = client.rpc.bind(client);
  const controller = new AbortController();
  let reads = 0;
  const rpc = vi.spyOn(client, "rpc").mockImplementation((...args) => {
    if (++reads === 2) controller.abort();
    return originalRpc(...args);
  });
  const result = await pollBridgeCommands(client, { userId: w.user, bridgeId: w.bridge, after: (await f.list(w)).next_cursor, wait: 25, signal: controller.signal });
  expect(result.readbacks).toEqual([]);
  expect(rpc.mock.calls.length).toBeGreaterThanOrEqual(2);
});

it("sweeps the actual SQL lease function through the production TS caller", async () => {
  const w = await f.world();
  await f.lease(w);
  await f.updateRow("execution_steps", w.step, { lease_expires_at: "2000-01-01" });
  vi.stubEnv("EXECUTION_ENABLED", "false");
  try {
    expect(await sweepBridge(admin())).toEqual({ unreachable: 0, expired_leases: 1, redelivered: 0, errors: 0 });
    expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({ state: "unknown_outcome" });
  } finally { vi.stubEnv("EXECUTION_ENABLED", "true"); }
});
