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
beforeAll(async () => { db = await createLocalSupabase(); vi.stubEnv("EXECUTION_ENABLED", "true"); vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true"); }, 60_000);
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
it("filters a deleted Action chip and delivers the selected message without skipping its FIFO turn", async () => {
  const w = await f.world();
  await f.updateRow("agent_sessions", w.session, { status: "bound", external_session_id: `session:${randomUUID()}` });
  await f.updateRow("bridges", w.bridge, { capabilities });
  await f.lease(w);
  await f.bridgeEvent(w, f.event(w, "accepted"));
  await f.bridgeEvent(w, f.event(w, "turn_completed"));
  const chip = await f.action(w.user);
  const m2 = String((await f.post(w.user, w.conversation, randomUUID(), "Uses a deleted chip")).message_id);
  const selected = { action_ids: [chip], context_ids: [] };
  await f.updateRow("conversation_messages", m2, { delivery_state: "queued", delivery_reason: "session_busy", selected });
  await f.q("delete from public.actions where id=$1", [chip]);
  const m3 = String((await f.post(w.user, w.conversation, randomUUID(), "Plain follow-up")).message_id);
  await f.updateRow("conversation_messages", m3, { delivery_state: "queued", delivery_reason: "queue_order" });
  const before = await counts(w.user), client = admin();
  const rpc = vi.spyOn(client, "rpc");
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await f.msg(m2)).toMatchObject({ delivery_state: "dispatched", delivery_reason: null });
  expect(await f.one("select selected from public.conversation_messages where id=$1", [m2])).toEqual({ selected });
  expect(await f.msg(m3)).toMatchObject({ delivery_state: "queued" });
  const after = await counts(w.user);
  expect(after.slice(0, 3)).toEqual(before.slice(0, 3).map(n => Number(n) + 1));
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await counts(w.user)).toEqual(after);
  expect(rpc.mock.calls.filter(([name]) => name === "start_agent_turn_auto").map(([, args]) => args?.p_message_id)).toEqual([m2, m3]);
  expect(rpc.mock.calls.find(([name]) => name === "start_agent_turn_auto")?.[1]?.p_action_ids).toEqual([]);
});

it.each(["start", "mark"])("preserves concurrent spawn_failed after selecting a queued head at the %s guard", async (phase) => {
  const w = await f.world();
  await f.updateRow("agent_sessions", w.session, { status: "bound", external_session_id: `session:${randomUUID()}` });
  await f.updateRow("bridges", w.bridge, { capabilities });
  await f.lease(w);
  await f.bridgeEvent(w, f.event(w, "accepted"));
  await f.bridgeEvent(w, f.event(w, "turn_completed"));
  const messageId = String((await f.post(w.user, w.conversation, randomUUID(), "Queued before a concurrent failure")).message_id);
  await f.updateRow("conversation_messages", messageId, { delivery_state: "queued", delivery_reason: "session_busy" });
  const before = await counts(w.user), client = admin();
  const originalRpc = client.rpc.bind(client);
  let guarded = false;
  const rpc = vi.spyOn(client, "rpc").mockImplementation((...args) => {
    if (args[0] === "start_agent_turn_auto") {
      return { throwOnError: async () => {
        guarded = true;
        await f.updateRow("conversation_messages", messageId, { delivery_state: "not_sent", delivery_reason: "spawn_failed" });
        return phase === "mark" ? { data: { status: "not_found" } } : originalRpc(...args).throwOnError();
      } } as unknown as ReturnType<typeof client.rpc>;
    }
    return originalRpc(...args);
  });
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(guarded).toBe(true);
  expect(await f.msg(messageId)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "spawn_failed" });
  expect(await counts(w.user)).toEqual(before);
  expect(rpc.mock.calls.some(([name]) => name === "mark_agent_message_not_sent")).toBe(false);
  if (phase === "mark") expect(rpc).toHaveBeenCalledWith("mark_agent_message_not_sent_auto", expect.objectContaining({ p_message_id: messageId }));
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
    await redeliverBridgeMessages(client, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" });
    const after = await counts(w.user);
    expect(after.slice(0, 3)).toEqual(before.slice(0, 3).map(n => Number(n) + 1));
    await redeliverBridgeMessages(client, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" });
    expect(await counts(w.user)).toEqual(after);
  } else {
    await redeliverBridgeMessages(client, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" });
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
    expect(await sweepBridge(admin())).toEqual({ unreachable: 0, expired_leases: 1, lease_busy: 0, reclaimed: 0, reclaim_busy: 0, redelivered: 0, errors: 0 });
    expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({ state: "unknown_outcome" });
  } finally { vi.stubEnv("EXECUTION_ENABLED", "true"); }
});

// ─── F1s 항목 3 (D3): 계기 ③은 후보 대화 하나의 머리만 시작한다 (onlyConversationId 필터) ───
const gateEnv = { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" };
it("③: 같은 연결의 세션 없는 대화 둘 중 후보로 넘어온 대화의 머리만 시작한다", async () => {
  const w = await f.world();
  await f.updateRow("agent_sessions", w.session, { status: "bound", external_session_id: `session:${randomUUID()}` });
  await f.updateRow("bridges", w.bridge, { capabilities });
  const heads: string[] = [], conversations: string[] = [];
  for (const text of ["First unbound head", "Second unbound head"]) {
    const conversation = await f.agentConversation(w.user, w.connection, null);
    const message = String((await f.post(w.user, conversation, randomUUID(), text)).message_id);
    await f.updateRow("conversation_messages", message, { delivery_state: "not_sent", delivery_reason: "write_gate_closed" });
    conversations.push(conversation);
    heads.push(message);
  }
  const before = await counts(w.user), client = admin();
  // 실제 SQL(next_unbound_agent_messages)은 연결의 세션 없는 대화 머리를 모두 돌려준다 — 둘째 대화의 머리를 건드리지 않는 것은 TS 필터(onlyConversationId)의 몫이다
  expect((await client.rpc("next_unbound_agent_messages", { p_user_id: w.user, p_connection_id: w.connection, p_limit: 10, p_retry_gate: true }).throwOnError()).data).toEqual(expect.arrayContaining(heads));
  const originalRpc = client.rpc.bind(client);
  const rpc = vi.spyOn(client, "rpc").mockImplementation((...args) => {
    // 후보 SQL은 분마다 순서를 돌려 어느 대화가 오는지 정해져 있지 않다: 첫째 대화 하나만 돌려주고 나머지는 실제 SQL을 쓴다
    if (args[0] === "bridge_redelivery_candidates") {
      return { throwOnError: async () => ({ data: [{ user_id: w.user, agent_session_id: null, conversation_id: conversations[0] }] }) } as unknown as ReturnType<typeof client.rpc>;
    }
    return originalRpc(...args);
  });
  expect(await redeliverBridgeMessages(client, gateEnv)).toBe(1);
  expect(await f.msg(heads[0])).toMatchObject({ delivery_state: "dispatched", delivery_reason: null });
  expect(await f.msg(heads[1])).toMatchObject({ delivery_state: "not_sent", delivery_reason: "write_gate_closed" });
  expect(rpc.mock.calls.filter(([name]) => name === "start_agent_turn_auto").map(([, args]) => args?.p_message_id)).toEqual([heads[0]]);
  expect((await counts(w.user)).slice(0, 3)).toEqual(before.slice(0, 3).map((n) => Number(n) + 1));
});

// ─── F1s 항목 4 (D4): 실제 not_found 머리는 대기열에서 빠지고 다음 kick이 그 뒤 메시지를 시작한다 ───
// (FU의 예시 "지워진 context 칩"은 not_found가 아니다: 없는 · 보관한 context는 Ungrouped다. 실제 not_found는 남의 칩, 또는 TS 필터 뒤 SQL 전에 지워진 Action이다)
it.each(["another user's context chip", "Action deleted just before the start"])("not_found 머리(%s)는 대기열에서 빠지고 다음 kick이 M3을 시작한다", async (kind) => {
  const w = await f.world();
  await f.updateRow("agent_sessions", w.session, { status: "bound", external_session_id: `session:${randomUUID()}` });
  await f.updateRow("bridges", w.bridge, { capabilities });
  await f.lease(w);
  await f.bridgeEvent(w, f.event(w, "accepted"));
  await f.bridgeEvent(w, f.event(w, "turn_completed"));
  const foreign = kind.startsWith("another") ? await f.context(await f.user()) : null;
  const chip = foreign ? null : await f.action(w.user);
  const selected = foreign ? { action_ids: [], context_ids: [foreign] } : { action_ids: [chip!], context_ids: [] };
  const m2 = String((await f.post(w.user, w.conversation, randomUUID(), "Chip that will not resolve")).message_id);
  await f.updateRow("conversation_messages", m2, { delivery_state: "queued", delivery_reason: "session_busy", selected });
  const m3 = String((await f.post(w.user, w.conversation, randomUUID(), "Plain follow-up")).message_id);
  await f.updateRow("conversation_messages", m3, { delivery_state: "queued", delivery_reason: "queue_order" });
  const before = await counts(w.user), client = admin();
  const originalRpc = client.rpc.bind(client);
  const rpc = vi.spyOn(client, "rpc").mockImplementation((...args) => {
    if (args[0] === "start_agent_turn_auto" && args[1]?.p_message_id === m2 && chip) {
      // TS가 칩 Action이 있는 것을 확인한 뒤, SQL이 보기 전에 지워진다
      return { throwOnError: async () => { await f.q("delete from public.actions where id=$1", [chip]); return originalRpc(...args).throwOnError(); } } as unknown as ReturnType<typeof client.rpc>;
    }
    return originalRpc(...args);
  });
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await f.msg(m2)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "not_found" });
  expect(await f.msg(m3)).toMatchObject({ delivery_state: "queued" });
  expect(await counts(w.user)).toEqual(before);
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await f.msg(m2)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "not_found" });
  expect(await f.msg(m3)).toMatchObject({ delivery_state: "dispatched", delivery_reason: null });
  const after = await counts(w.user);
  expect(after.slice(0, 3)).toEqual(before.slice(0, 3).map((n) => Number(n) + 1));
  expect(rpc.mock.calls.filter(([name]) => name === "start_agent_turn_auto").map(([, args]) => args?.p_message_id)).toEqual([m2, m3]);
  await kickBridgeSessions(client, w.user, [w.session]);
  expect(await counts(w.user)).toEqual(after);
});
