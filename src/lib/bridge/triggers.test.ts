import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("./events", () => ({ drainBridgeSessionEvents: vi.fn().mockResolvedValue(0) }));
vi.mock("@/lib/agents/next-turn", async (importOriginal) => ({ ...await importOriginal<typeof import("@/lib/agents/next-turn")>(), startPinnedAgentMessage: vi.fn() }));
import { sweepBridge } from "./sweep";
import { kickBridgeConnections, kickBridgeSessions, redeliverBridgeMessages } from "./triggers";
import { startPinnedAgentMessage } from "@/lib/agents/next-turn";
import { AGENT_REGISTRY } from "@/lib/agents/registry";
const id = "10000000-0000-4000-8000-000000000001";
beforeEach(() => { vi.clearAllMocks(); vi.mocked(startPinnedAgentMessage).mockResolvedValue({ status: "queued", reason: "session_busy" }); vi.stubEnv("EXECUTION_ENABLED", "true"); vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true"); });
afterEach(() => vi.unstubAllEnvs());
it("starts exactly the SQL-selected head without selecting it again", async () => {
  vi.mocked(startPinnedAgentMessage).mockClear();
  const { admin, rpc } = deliveryDb({
    agent_sessions: { status: "bound", connection_id: id },
    conversation_messages: { delivery_state: "queued", delivery_reason: null, refs: { agent_turn: { action_ids: [id], context_ids: [] } }, selected: null },
  });
  await kickBridgeSessions(admin, id, [id]);
  expect(startPinnedAgentMessage).toHaveBeenCalledExactlyOnceWith(admin, expect.objectContaining({ userId: id, messageId: id, chips: { action_ids: [id], context_ids: [] } }), expect.any(Object));
  expect(rpc.mock.calls.map(([name]) => name)).toEqual(["next_bridge_agent_message"]);
});
it("leaves guarded start outcomes to the shared starter without an unguarded reason write", async () => {
  vi.mocked(startPinnedAgentMessage).mockResolvedValueOnce({ status: "skipped" });
  const { admin, rpc } = deliveryDb();
  await kickBridgeSessions(admin, id, [id]);
  expect(startPinnedAgentMessage).toHaveBeenCalledOnce();
  expect(rpc.mock.calls).toEqual([
    ["next_bridge_agent_message", { p_user_id: id, p_agent_session_id: id, p_retry_gate: false }],
  ]);
});
describe("bridge delivery triggers", () => {
  it("isolates a failed session kick and skips external/closed sessions", async () => {
    vi.mocked(startPinnedAgentMessage).mockRejectedValueOnce(new Error("busy"));
    const { admin } = deliveryDb();
    await expect(kickBridgeSessions(admin, id, [id, id])).resolves.toBeUndefined();
    expect(startPinnedAgentMessage).toHaveBeenCalledTimes(1);
    const external = deliveryDb({ agent_sessions: { status: "external" } });
    await kickBridgeSessions(external.admin, id, [id]);
    expect(startPinnedAgentMessage).toHaveBeenCalledTimes(1);
  });
  it("does no gate retry reads or writes while execution is disabled", async () => {
    const rpc = vi.fn();
    expect(await redeliverBridgeMessages({ rpc } as unknown as SupabaseClient, {})).toBe(0);
    expect(rpc).not.toHaveBeenCalled();
  });
});

it("refuses a blocked FIFO head before invoking the existing turn starter", async () => {
  vi.mocked(startPinnedAgentMessage).mockClear();
  const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: null }) }));
  const from = vi.fn(() => ({ select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(), throwOnError: async () => ({ data: { status: "bound" } }) }));
  await kickBridgeSessions({ from, rpc } as unknown as SupabaseClient, id, [id]);
  expect(startPinnedAgentMessage).not.toHaveBeenCalled();
  expect(rpc).toHaveBeenCalledWith("next_bridge_agent_message", { p_user_id: id, p_agent_session_id: id, p_retry_gate: false });
});

function deliveryDb(overrides: Record<string, unknown> = {}) {
  const rows: Record<string, unknown> = {
    conversations: { agent_connection_id: id },
    agent_connections: { adapter: "agent:codex", status: "active", bridge_id: id },
    bridges: { status: "active", capabilities: { adapters: { "agent:codex": { installed: true, version: "0.162.1", signed_in: "yes", managed_settings: false } } } },
    execution_policies: { mode: "manual" }, execution_actors: { user_id: id },
    execution_controls: { blocked: false }, execution_tools: { provider: "agent:codex" }, agent_sessions: { status: "bound", connection_id: id },
    conversation_messages: { delivery_state: "queued", delivery_reason: null, refs: {}, selected: null },
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
  vi.mocked(startPinnedAgentMessage).mockClear();
  const { admin, rpc } = deliveryDb(overrides);
  expect(await redeliverBridgeMessages(admin, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe(0);
  expect(startPinnedAgentMessage).not.toHaveBeenCalled();
  expect(rpc).not.toHaveBeenCalledWith("next_bridge_agent_message", expect.anything());
});
it("gate retry reopens the FIFO head exactly once after all gates pass", async () => {
  vi.mocked(startPinnedAgentMessage).mockClear();
  const { admin, rpc } = deliveryDb();
  expect(await redeliverBridgeMessages(admin, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe(1);
  expect(rpc).toHaveBeenCalledWith("next_bridge_agent_message", { p_user_id: id, p_agent_session_id: id, p_retry_gate: true });
  expect(startPinnedAgentMessage).toHaveBeenCalledExactlyOnceWith(admin, expect.objectContaining({ userId: id, messageId: id }), { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" });
});

it("does not kick a session twice when heartbeat also retries its connection", async () => {
  vi.mocked(startPinnedAgentMessage).mockClear();
  const { admin } = deliveryDb({ agent_sessions: [{ id }] });
  const baseFrom = admin.from.bind(admin);
  const from = vi.fn((table: string) => {
    const query = baseFrom(table);
    Object.assign(query, { limit: () => query });
    return query;
  });
  admin.from = from as typeof admin.from;
  await kickBridgeConnections(admin, id, [id], { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" }, [id]);
  expect(from.mock.calls.filter(([table]) => table === "agent_sessions")).toHaveLength(1);
  expect(startPinnedAgentMessage).not.toHaveBeenCalled();
});

// ─── F1s 항목 2 (D2): 계기 ③이 시작 입력을 그대로 넘긴다 (state · reason · 칩 우선순위 · target) ───
describe("redeliverBridgeMessages(③)가 startPinnedAgentMessage에 넘기는 입력 전체", () => {
  const other = "10000000-0000-4000-8000-000000000002";
  const context = "10000000-0000-4000-8000-000000000003";
  const env = { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" };
  const turnChips = { action_ids: [id], context_ids: [] };
  const selectedChips = { action_ids: [other], context_ids: [context] };
  const head = (extra: Record<string, unknown>) => deliveryDb({ conversation_messages: { delivery_state: "not_sent", delivery_reason: "write_gate_closed", refs: {}, selected: null, ...extra } });
  const expectedInput = (chips: { action_ids: string[]; context_ids: string[] }) => ({
    userId: id, messageId: id, state: "not_sent", reason: "write_gate_closed", chips,
    target: { capability: AGENT_REGISTRY["agent:codex"], mode: "manual", connectionStatus: "active" },
  });

  it("refs.agent_turn(A)과 selected(B · 맥락 포함)가 둘 다 있으면 A가 이긴다. state · reason은 머리 그대로", async () => {
    vi.mocked(startPinnedAgentMessage).mockClear();
    const { admin } = head({ refs: { agent_turn: turnChips }, selected: selectedChips });
    expect(await redeliverBridgeMessages(admin, env)).toBe(1);
    expect(startPinnedAgentMessage).toHaveBeenCalledExactlyOnceWith(admin, expectedInput(turnChips), env);
  });

  it("selected만 있으면 B (맥락 칩까지 그대로)", async () => {
    vi.mocked(startPinnedAgentMessage).mockClear();
    const { admin } = head({ selected: selectedChips });
    await redeliverBridgeMessages(admin, env);
    expect(startPinnedAgentMessage).toHaveBeenCalledExactlyOnceWith(admin, expectedInput(selectedChips), env);
  });

  it("둘 다 없으면 빈 칩", async () => {
    vi.mocked(startPinnedAgentMessage).mockClear();
    const { admin } = head({});
    await redeliverBridgeMessages(admin, env);
    expect(startPinnedAgentMessage).toHaveBeenCalledExactlyOnceWith(admin, expectedInput({ action_ids: [], context_ids: [] }), env);
  });

  it.each([["not_sent", "not_connected"], ["not_sent", "adapter_disabled"], ["queued", null]] as const)("머리의 state · reason(%s/%s)을 바꾸지 않고 넘긴다", async (state, reason) => {
    vi.mocked(startPinnedAgentMessage).mockClear();
    const { admin } = head({ delivery_state: state, delivery_reason: reason, refs: { agent_turn: turnChips } });
    await redeliverBridgeMessages(admin, env);
    expect(startPinnedAgentMessage).toHaveBeenCalledExactlyOnceWith(admin, { ...expectedInput(turnChips), state, reason }, env);
  });
});

// ─── OA F3: 만료 회수 뒤 kick은 여섯 번째 세션부터도 간다 (실제 kickBridgeSessions는 한 번에 5개까지만 본다) ───
it("F3: sweepBridge가 한 사용자의 회수 세션 6개를 넘기면 앞 다섯이 unreachable이어도 여섯째(bound)가 시작된다", async () => {
  vi.mocked(startPinnedAgentMessage).mockClear();
  const sessions = Array.from({ length: 6 }, (_, i) => `30000000-0000-4000-8000-00000000000${i + 1}`);
  const sixth = sessions[5];
  const { admin, rpc } = deliveryDb();
  const baseRpc = admin.rpc.bind(admin) as (name: string, args?: Record<string, unknown>) => unknown;
  admin.rpc = ((name: string, args?: Record<string, unknown>) => {
    const answers: Record<string, unknown> = {
      sweep_bridge_heartbeats: [], sweep_agent_step_leases: 0,
      expire_unleased_agent_messages: { reclaimed: 6, busy: 0, sessions: sessions.map((agent_session_id) => ({ user_id: id, agent_session_id })) },
    };
    return name in answers ? { throwOnError: async () => ({ data: answers[name] }) } : baseRpc(name, args);
  }) as typeof admin.rpc;
  const baseFrom = admin.from.bind(admin);
  admin.from = ((table: string) => {
    if (table !== "agent_sessions") return baseFrom(table);
    const filters: Record<string, unknown> = {};
    const query = { select: () => query, eq: (key: string, value: unknown) => { filters[key] = value; return query; }, maybeSingle: () => query,
      throwOnError: async () => ({ data: { status: filters.id === sixth ? "bound" : "unreachable", connection_id: id } }) };
    return query;
  }) as typeof admin.from;
  await sweepBridge(admin);
  const calls = rpc.mock.calls as unknown as [string, { p_agent_session_id?: string } | undefined][];
  const heads = calls.filter(([name, args]) => name === "next_bridge_agent_message" && args?.p_agent_session_id === sixth);
  expect(heads).toHaveLength(1);
  expect(startPinnedAgentMessage).toHaveBeenCalledWith(admin, expect.objectContaining({ userId: id, messageId: id }), expect.any(Object));
});
