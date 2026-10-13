import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { MAX_LIVE_EXTERNAL_TASKS } from "@/lib/execution/limits";
import { AGENT_REGISTRY } from "./registry";
import { startAgentTurn, startNextQueuedTurn } from "./turns";

const userId = "10000000-0000-4000-8000-000000000001";
const messageId = "10000000-0000-4000-8000-000000000002";
const started = { status: "started", action_id: userId, run_id: userId, agent_task_id: userId, step_id: userId, turn_seq: 1, created_action: false };
function db(count = 0, response: unknown = started) {
  const query = { select: vi.fn(), eq: vi.fn(), in: vi.fn(), gt: vi.fn(), update: vi.fn(), maybeSingle: vi.fn(), throwOnError: vi.fn() };
  for (const key of ["select", "eq", "in", "gt", "update", "maybeSingle"] as const) query[key].mockReturnValue(query);
  query.throwOnError.mockResolvedValue({ count, data: { id: messageId } });
  const rpc = vi.fn().mockReturnValue({ throwOnError: vi.fn().mockResolvedValue({ data: response }) });
  const from = vi.fn().mockReturnValue(query);
  return { admin: { from, rpc } as unknown as SupabaseClient, from, rpc, query };
}
const input = { userId, messageId, capability: AGENT_REGISTRY["agent:codex"], mode: "manual", connectionStatus: "active" } as const;
// OD-2: Codex 대화도 gate(AGENT_ADAPTER_CODEX_ENABLED, 기본 꺼짐)가 켜져야 시작한다.
const CODEX_ON = { AGENT_ADAPTER_CODEX_ENABLED: "true" };

describe("startAgentTurn", () => {
  it("starts S0 Codex with read_only and validates RPC output", async () => {
    const d = db();
    expect(await startAgentTurn(d.admin, input, CODEX_ON)).toEqual(started);
    expect(d.from).not.toHaveBeenCalled();
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("route_agent_message", { p_user_id: userId, p_message_id: messageId, p_action_ids: [], p_context_ids: [], p_access: "read_only", p_live_limit: MAX_LIVE_EXTERNAL_TASKS });
  });
  it("keeps Codex closed while its adapter gate is off: no route RPC, message marked unsupported", async () => {
    const d = db(0, { status: "not_sent", reason: "unsupported" });
    expect(await startAgentTurn(d.admin, input, {})).toEqual({ status: "not_sent", reason: "unsupported" });
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("mark_agent_message_not_sent", { p_user_id: userId, p_message_id: messageId, p_reason: "unsupported" });
  });
  it.each([{ status: "answered", step_id: userId }, { status: "duplicate", step_id: userId }, { status: "secret_requires_local" }, { status: "question_stale" }, { status: "invalid_answer" }])("preserves question routing outcomes", async (response) => {
    expect(await startAgentTurn(db(0, response).admin, input, CODEX_ON)).toEqual(response);
  });
  it("marks S0 Claude Code not_sent with no dispatch", async () => {
    const d = db(0, { status: "not_sent", reason: "write_gate_closed" });
    expect(await startAgentTurn(d.admin, { ...input, capability: AGENT_REGISTRY["agent:claude-code"] }, { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("mark_agent_message_not_sent", { p_user_id: userId, p_message_id: messageId, p_reason: "write_gate_closed" });
    expect(d.from).not.toHaveBeenCalled();
  });
  it("keeps the Claude Code flag closed even if boundaries are verified", async () => {
    const capability = structuredClone(AGENT_REGISTRY["agent:claude-code"]);
    capability.enforcement.revocation.verified = true;
    const d = db(0, { status: "not_sent", reason: "unsupported" });
    await startAgentTurn(d.admin, { ...input, capability }, CODEX_ON);
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("mark_agent_message_not_sent", { p_user_id: userId, p_message_id: messageId, p_reason: "unsupported" });
  });
  it("marks missing direct-chat support unsupported even with an access grade", async () => {
    const capability = structuredClone(input.capability);
    capability.resume = "unsupported";
    const d = db(0, { status: "not_sent", reason: "unsupported" });
    await startAgentTurn(d.admin, { ...input, capability }, CODEX_ON);
    expect(d.rpc).toHaveBeenCalledWith("mark_agent_message_not_sent", expect.objectContaining({ p_reason: "unsupported" }));
  });
  it.each(["not_connected", "sign_in_needed", "unsupported"] as const)("records connection %s without starting", async (reason) => {
    const d = db(0, { status: "not_sent", reason });
    await startAgentTurn(d.admin, { ...input, connectionStatus: reason }, CODEX_ON);
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("mark_agent_message_not_sent", { p_user_id: userId, p_message_id: messageId, p_reason: reason });
  });
  it.each(["live_limit", "queue_order", "question_open"] as const)("preserves SQL admission reason %s without direct updates", async (reason) => {
    const d = db(0, { status: "queued", reason });
    expect(await startAgentTurn(d.admin, input, CODEX_ON)).toEqual({ status: "queued", reason });
    expect(d.from).not.toHaveBeenCalled();
  });
  it("preserves the terminal invalid_referent response", async () => {
    const response = { status: "not_sent", reason: "invalid_referent" };
    expect(await startAgentTurn(db(0, response).admin, input, CODEX_ON)).toEqual(response);
  });
  it("preserves a closed session and referent candidates", async () => {
    for (const response of [{ status: "not_sent", reason: "session_closed" }, { status: "needs_referent", candidates: [userId] }]) {
      expect(await startAgentTurn(db(0, response).admin, input, CODEX_ON)).toEqual(response);
    }
  });
  it("starts below the live limit and passes normalized added chips", async () => {
    const d = db(4);
    await startAgentTurn(d.admin, { ...input, actionIds: [userId], contextIds: [messageId] }, CODEX_ON);
    expect(d.rpc).toHaveBeenCalledWith("route_agent_message", expect.objectContaining({ p_action_ids: [userId], p_context_ids: [messageId] }));
  });
  it("accepts deterministic Action UUIDs without imposing a random UUID version", async () => {
    const response = { ...started, action_id: "f0000000-0000-f000-f000-000000000001" };
    expect(await startAgentTurn(db(0, response).admin, input, CODEX_ON)).toEqual(response);
  });
  it("propagates SQL errors without a direct update", async () => {
    const d = db();
    d.rpc.mockReturnValue({ throwOnError: vi.fn().mockRejectedValue(new Error("db")) });
    await expect(startAgentTurn(d.admin, input, CODEX_ON)).rejects.toThrow("db");
    expect(d.from).not.toHaveBeenCalled();
  });
  it.each([{ status: "started" }, { ...started, turn_seq: 0 }, { status: "unexpected" }])("rejects malformed RPC output", async (response) => {
    const d = db(0, response);
    await expect(startAgentTurn(d.admin, input, CODEX_ON)).rejects.toThrow();
  });
  it("validates mark-not-sent output and preserves guard failures", async () => {
    const d = db(0, { status: "expired" });
    expect(await startAgentTurn(d.admin, { ...input, connectionStatus: "not_connected" }, CODEX_ON)).toEqual({ status: "expired" });
    const broken = db(0, { status: "not_sent", reason: "unexpected" });
    await expect(startAgentTurn(broken.admin, { ...input, connectionStatus: "not_connected" }, CODEX_ON)).rejects.toThrow();
  });
});

function queuedDb(adapter = "agent:codex", status = "active", mode = "manual") {
  const d = db();
  d.rpc.mockImplementation((name) => ({ throwOnError: vi.fn().mockResolvedValue({ data: name === "next_queued_agent_message" ? messageId : name === "mark_agent_message_not_sent" ? { status: "not_sent", reason: status === "active" ? "write_gate_closed" : "not_connected" } : started }) }));
  const rows: Record<string, unknown> = {
    agent_sessions: { connection_id: userId }, agent_connections: { adapter, status }, execution_policies: { mode },
    conversation_messages: { refs: { agent_turn: { action_ids: [userId], context_ids: [messageId] } }, selected: {} },
  };
  d.from.mockImplementation((table: string) => {
    const query = { select: vi.fn(), eq: vi.fn(), maybeSingle: vi.fn(), throwOnError: vi.fn().mockResolvedValue({ data: rows[table] }) };
    for (const key of ["select", "eq", "maybeSingle"] as const) query[key].mockReturnValue(query);
    return query;
  });
  return { ...d, rows };
}
describe("startNextQueuedTurn", () => {
  it("returns null when no candidate is available without reading connection context", async () => {
    const d = db(0, null);
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toBeNull();
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("next_queued_agent_message", { p_user_id: userId, p_session_id: userId });
    expect(d.from).not.toHaveBeenCalled();
  });
  it("resolves current registry, policy and connection and resumes retained chips", async () => {
    const d = queuedDb();
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toEqual(started);
    expect(d.rpc).toHaveBeenLastCalledWith("route_agent_message", expect.objectContaining({ p_message_id: messageId, p_access: "read_only", p_action_ids: [userId], p_context_ids: [messageId], p_live_limit: MAX_LIVE_EXTERNAL_TASKS }));
    for (const table of ["agent_sessions", "agent_connections", "execution_policies", "conversation_messages"]) expect(d.from).toHaveBeenCalledWith(table);
    for (const result of d.from.mock.results) expect(result.value.eq).toHaveBeenCalledWith("user_id", userId);
  });
  it("uses the registry to keep Claude Code's unverified gate closed", async () => {
    const d = queuedDb("agent:claude-code");
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(d.rpc).toHaveBeenLastCalledWith("mark_agent_message_not_sent", expect.objectContaining({ p_reason: "write_gate_closed" }));
  });
  it("uses current revoked connection state", async () => {
    const d = queuedDb("agent:codex", "revoked");
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toEqual({ status: "not_sent", reason: "not_connected" });
  });
  it("handles absent selection and policy using the database defaults", async () => {
    const d = queuedDb();
    d.rows.conversation_messages = { refs: {}, selected: null };
    d.rows.execution_policies = null;
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toEqual(started);
    expect(d.rpc).toHaveBeenLastCalledWith("route_agent_message", expect.objectContaining({ p_action_ids: [], p_context_ids: [] }));
  });
  it.each(["agent_sessions", "agent_connections", "conversation_messages"])("handles %s disappearing after selection", async (table) => {
    const d = queuedDb();
    d.rows[table] = null;
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toEqual({ status: "not_found" });
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });
  it("rejects malformed policy before starting", async () => {
    const d = queuedDb();
    d.rows.execution_policies = { mode: "unexpected" };
    await expect(startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).rejects.toThrow();
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });

  it.each(["not_found", "already_dispatched"] as const)("retires an unusable selected message with truthful %s reason", async (reason) => {
    const d = queuedDb();
    const response = { status: "not_sent", reason };
    d.rpc.mockImplementation((name) => ({ throwOnError: vi.fn().mockResolvedValue({ data: name === "next_queued_agent_message" ? messageId : name === "route_agent_message" ? { status: reason } : response }) }));
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toEqual(response);
    expect(d.rpc).toHaveBeenLastCalledWith("mark_agent_message_not_sent", { p_user_id: userId, p_message_id: messageId, p_reason: reason });
  });
  it("preserves the marking helper guard when the selected message disappeared", async () => {
    const d = queuedDb();
    d.rpc.mockImplementation((name) => ({ throwOnError: vi.fn().mockResolvedValue({ data: name === "next_queued_agent_message" ? messageId : { status: "not_found" } }) }));
    expect(await startNextQueuedTurn(d.admin, { userId, sessionId: userId }, CODEX_ON)).toEqual({ status: "not_found" });
    expect(d.rpc).toHaveBeenCalledTimes(3);
  });

});
