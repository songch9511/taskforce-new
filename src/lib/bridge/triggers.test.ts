import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("@/lib/agents/turns", () => ({ startNextQueuedTurn: vi.fn().mockResolvedValue(null), startAgentTurn: vi.fn() }));
import { kickBridgeConnections, kickBridgeSessions, redeliverBridgeMessages } from "./triggers";
import { startAgentTurn, startNextQueuedTurn } from "@/lib/agents/turns";
const id = "10000000-0000-4000-8000-000000000001";
beforeEach(() => { vi.clearAllMocks(); vi.mocked(startAgentTurn).mockResolvedValue({ status: "queued", reason: "session_busy" }); vi.stubEnv("EXECUTION_ENABLED", "true"); });
afterEach(() => vi.unstubAllEnvs());
it("starts exactly the SQL-selected head without selecting it again", async () => {
  vi.mocked(startAgentTurn).mockClear();
  vi.mocked(startNextQueuedTurn).mockClear();
  const { admin, rpc } = deliveryDb({
    agent_sessions: { status: "bound", connection_id: id },
    conversation_messages: { refs: { agent_turn: { action_ids: [id], context_ids: [] } }, selected: null },
  });
  await kickBridgeSessions(admin, id, [id]);
  expect(startAgentTurn).toHaveBeenCalledExactlyOnceWith(admin, expect.objectContaining({ userId: id, messageId: id, actionIds: [id] }), expect.any(Object));
  expect(startNextQueuedTurn).not.toHaveBeenCalled();
  expect(rpc.mock.calls.map(([name]) => name)).toEqual(["next_bridge_agent_message"]);
});
it.each(["not_found", "already_dispatched"] as const)("removes a selected %s head through the guarded message RPC", async status => {
  vi.mocked(startAgentTurn).mockResolvedValueOnce({ status });
  const { admin, rpc } = deliveryDb();
  await kickBridgeSessions(admin, id, [id]);
  expect(rpc.mock.calls).toEqual([
    ["next_bridge_agent_message", { p_user_id: id, p_agent_session_id: id, p_retry_gate: false }],
    ["mark_agent_message_not_sent", { p_user_id: id, p_message_id: id, p_reason: status }],
  ]);
});
describe("bridge delivery triggers", () => {
  it("isolates a failed session kick and skips external/closed sessions", async () => {
    vi.mocked(startAgentTurn).mockRejectedValueOnce(new Error("busy"));
    const { admin } = deliveryDb();
    await expect(kickBridgeSessions(admin, id, [id, id])).resolves.toBeUndefined();
    expect(startAgentTurn).toHaveBeenCalledTimes(1);
    const external = deliveryDb({ agent_sessions: { status: "external" } });
    await kickBridgeSessions(external.admin, id, [id]);
    expect(startAgentTurn).toHaveBeenCalledTimes(1);
  });
  it("does no gate retry reads or writes while execution is disabled", async () => {
    const rpc = vi.fn();
    expect(await redeliverBridgeMessages({ rpc } as unknown as SupabaseClient, {})).toBe(0);
    expect(rpc).not.toHaveBeenCalled();
  });
});

it("refuses a blocked FIFO head before invoking the existing turn starter", async () => {
  vi.mocked(startAgentTurn).mockClear();
  const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: null }) }));
  const from = vi.fn(() => ({ select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(), throwOnError: async () => ({ data: { status: "bound" } }) }));
  await kickBridgeSessions({ from, rpc } as unknown as SupabaseClient, id, [id]);
  expect(startAgentTurn).not.toHaveBeenCalled();
  expect(rpc).toHaveBeenCalledWith("next_bridge_agent_message", { p_user_id: id, p_agent_session_id: id, p_retry_gate: false });
});

function deliveryDb(overrides: Record<string, unknown> = {}) {
  const rows: Record<string, unknown> = {
    conversations: { agent_connection_id: id },
    agent_connections: { adapter: "agent:codex", status: "active", bridge_id: id },
    bridges: { status: "active", capabilities: { adapters: { "agent:codex": { installed: true, version: "0.162.1", signed_in: "yes", managed_settings: false } } } },
    execution_policies: { mode: "manual" }, execution_actors: { user_id: id },
    execution_controls: { blocked: false }, execution_tools: { provider: "agent:codex" }, agent_sessions: { status: "bound", connection_id: id },
    conversation_messages: { refs: {}, selected: null },
    ...overrides,
  };
  const rpc = vi.fn((name: string) => ({ throwOnError: async () => ({ data: name === "bridge_redelivery_candidates" ? [{ user_id: id, agent_session_id: id, conversation_id: id }] : name === "next_unbound_agent_messages" ? [] : id }) }));
  const from = vi.fn((table: string) => ({ select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(), throwOnError: async () => ({ data: rows[table] }) }));
  return { admin: { rpc, from } as unknown as SupabaseClient, rpc };
}
it.each([
  { execution_actors: null }, { execution_controls: { blocked: true } }, { execution_tools: null },
  { agent_connections: { adapter: "agent:codex", status: "revoked", bridge_id: id } },
  { bridges: { status: "active", capabilities: {} } },
])("gate retry starts nothing while an admission gate is closed: %j", async (overrides) => {
  vi.mocked(startAgentTurn).mockClear();
  const { admin, rpc } = deliveryDb(overrides);
  expect(await redeliverBridgeMessages(admin, { EXECUTION_ENABLED: "true" })).toBe(0);
  expect(startAgentTurn).not.toHaveBeenCalled();
  expect(rpc).not.toHaveBeenCalledWith("next_bridge_agent_message", expect.anything());
});
it("gate retry reopens the FIFO head exactly once after all gates pass", async () => {
  vi.mocked(startAgentTurn).mockClear();
  const { admin, rpc } = deliveryDb();
  expect(await redeliverBridgeMessages(admin, { EXECUTION_ENABLED: "true" })).toBe(1);
  expect(rpc).toHaveBeenCalledWith("next_bridge_agent_message", { p_user_id: id, p_agent_session_id: id, p_retry_gate: true });
  expect(startAgentTurn).toHaveBeenCalledExactlyOnceWith(admin, expect.objectContaining({ userId: id, messageId: id }), { EXECUTION_ENABLED: "true" });
});

it("does not kick a session twice when heartbeat also retries its connection", async () => {
  vi.mocked(startAgentTurn).mockClear();
  const { admin } = deliveryDb({ agent_sessions: [{ id }] });
  const baseFrom = admin.from.bind(admin);
  const from = vi.fn((table: string) => {
    const query = baseFrom(table);
    Object.assign(query, { limit: () => query });
    return query;
  });
  admin.from = from as typeof admin.from;
  await kickBridgeConnections(admin, id, [id], { EXECUTION_ENABLED: "true" }, [id]);
  expect(from.mock.calls.filter(([table]) => table === "agent_sessions")).toHaveLength(1);
  expect(startAgentTurn).not.toHaveBeenCalled();
});
