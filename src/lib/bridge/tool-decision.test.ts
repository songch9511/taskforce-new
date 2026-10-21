import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ mode: vi.fn(), access: vi.fn(), after: vi.fn(), append: vi.fn() }));
vi.mock("next/server", () => ({ after: mocks.after }));
vi.mock("./commands", () => ({ bridgePolicyMode: mocks.mode, bridgeDeliveryAccess: mocks.access }));
vi.mock("./events", () => ({ appendBridgeSessionEvent: mocks.append }));
import { decideBridgeToolCall } from "./tool-decision";
import { decisionRequest, writeCall } from "@/lib/agents/tool-decision.fixtures";
const userId = "44444444-4444-4444-8444-444444444444";
const runId = "55555555-5555-4555-8555-555555555555";
const leaseId = "66666666-6666-4666-8666-666666666666";
const bridge = { id: decisionRequest.bridge_id, status: "active" as const, secret_hash: null, capabilities: {} };
const decided = { status: "decided", decision: "allow", reason: "readonly_command", lease_ids: [], run_id: runId };
function setup(results: unknown[]) {
  let index = 0;
  const rpc = vi.fn<(name: string, args: Record<string, unknown>) => unknown>(() => ({ throwOnError: vi.fn().mockImplementation(async () => ({ data: results[index++] })) }));
  return { rpc, admin: { rpc } as unknown as SupabaseClient };
}
beforeEach(() => { vi.clearAllMocks(); mocks.mode.mockResolvedValue("manual"); mocks.access.mockReturnValue("write"); mocks.append.mockResolvedValue(undefined); });
it("one RPC has exact identity, policy, no command or parse argv", async () => {
  const { admin, rpc } = setup([decided]);
  const result = await decideBridgeToolCall(admin, { userId, bridge, input: decisionRequest });
  expect(result).toMatchObject({ decision: "allow", reason: "readonly_command", parse: { argv: ["ls"], implicit_cwd: true } });
  expect(rpc).toHaveBeenCalledExactlyOnceWith("decide_agent_tool_call", { p_user_id: userId, p_bridge_id: bridge.id, p_session_id: decisionRequest.agent_session_id, p_task_id: decisionRequest.agent_task_id, p_turn_seq: 1, p_mode: "manual", p_decision: { decision: "allow", reason: "readonly_command", access: "write", call_kind: "claude_bash", request_id: "tool-1", workspace_real_path: "/w/proj", targets: [], lease_op: "none", card_flags: [], server_ms: expect.any(Number) } });
  expect(JSON.stringify(rpc.mock.calls)).not.toContain('"command"');
  expect(result).not.toHaveProperty("run_id");
  expect(result).not.toHaveProperty("lease_ids");
  expect(mocks.after).not.toHaveBeenCalled();
});
it("re-evaluates mode once, then fails closed on a second change", async () => {
  const { admin, rpc } = setup([{ status: "policy_changed" }, { status: "policy_changed" }]);
  mocks.mode.mockResolvedValueOnce("auto").mockResolvedValueOnce("manual");
  expect(await decideBridgeToolCall(admin, { userId, bridge, input: { ...decisionRequest, call: writeCall } })).toMatchObject({ decision: "defer", reason: "server_busy" });
  expect(rpc.mock.calls).toHaveLength(2);
  expect(rpc.mock.calls[0][1]).toMatchObject({ p_mode: "auto", p_decision: { decision: "allow", lease_op: "acquire" } });
  expect(rpc.mock.calls[1][1]).toMatchObject({ p_mode: "manual", p_decision: { decision: "defer", lease_op: "reserve" } });
});
it("SQL downgrade strips parser and deny note is fixed", async () => {
  const { admin } = setup([{ ...decided, decision: "deny", reason: "write_gate_closed" }]);
  const result = await decideBridgeToolCall(admin, { userId, bridge, input: decisionRequest });
  expect(result).toMatchObject({ decision: "deny", reason: "write_gate_closed", agent_note: expect.any(String) });
  expect(result).not.toHaveProperty("parse");
});
it("outside Codex target flag comes from SQL key comparison, no TS normalization", async () => {
  const { admin } = setup([{ ...decided, decision: "defer", reason: "manual_write", card_flags: ["runs_without_sandbox"] }]);
  expect(await decideBridgeToolCall(admin, { userId, bridge, input: decisionRequest })).toMatchObject({ card_flags: ["runs_without_sandbox"] });
});
it("missing ownership maps to not_found", async () => {
  const { admin } = setup([{ status: "not_found" }]);
  expect(await decideBridgeToolCall(admin, { userId, bridge, input: decisionRequest })).toEqual({ status: "not_found" });
});
it("U3 path wait append is after commit, once, originating conversation only", async () => {
  const { admin } = setup([{ ...decided, decision: "deny", reason: "path_in_use", lease_ids: [leaseId], holder: { action_number: 139, rel_path: "a.md" } }]);
  const result = await decideBridgeToolCall(admin, { userId, bridge, input: { ...decisionRequest, call: writeCall } });
  expect(result).toMatchObject({ decision: "deny", agent_note: "a.md is being changed by another task (#139). Do other work first or wait." });
  expect(mocks.after).toHaveBeenCalledTimes(1);
  expect(mocks.append).not.toHaveBeenCalled();
  await mocks.after.mock.calls[0][0]();
  expect(mocks.append).toHaveBeenCalledExactlyOnceWith(admin, { userId, sessionId: decisionRequest.agent_session_id, taskId: decisionRequest.agent_task_id, turnSeq: 1, eventId: `path-wait:${leaseId}:${runId}`, text: "Waiting for #139 · a.md", originatingOnly: true });
});
it("after append failure logs no command, path or exception", async () => {
  const { admin } = setup([{ ...decided, decision: "deny", reason: "path_in_use", lease_ids: [leaseId], holder: { action_number: null, rel_path: "private-path" } }]);
  await decideBridgeToolCall(admin, { userId, bridge, input: { ...decisionRequest, call: writeCall } });
  mocks.append.mockRejectedValue(new Error("private command/path"));
  const log = vi.spyOn(console, "error").mockImplementation(() => {});
  try { await mocks.after.mock.calls[0][0](); expect(log).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "bridge_tool_decision_failed" })); } finally { log.mockRestore(); }
});

it("bounds path-in-use note to 300 characters and handles unknown action", async () => {
  const { admin } = setup([{ ...decided, decision: "deny", reason: "path_in_use", lease_ids: [leaseId], holder: { action_number: null, rel_path: "a".repeat(1000) } }]);
  const result = await decideBridgeToolCall(admin, { userId, bridge, input: { ...decisionRequest, call: writeCall } });
  expect(result).toHaveProperty("agent_note");
  if ("agent_note" in result) { expect(result.agent_note!.length).toBeLessThanOrEqual(300); expect(result.agent_note).toContain("another task"); }
});

// Explicit beta fixture; production remains fail-closed.
beforeEach(() => { vi.stubEnv("AGENT_BETA_USER_IDS", userId); vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true"); });
afterEach(() => vi.unstubAllEnvs());

it("cohort removal denies tool access while recording the denial", async () => {
  vi.stubEnv("AGENT_BETA_USER_IDS", "");
  const { admin, rpc } = setup([{ ...decided, decision: "deny", reason: "write_gate_closed" }]);
  expect(await decideBridgeToolCall(admin, { userId, bridge, input: decisionRequest })).toMatchObject({ decision: "deny", reason: "write_gate_closed" });
  expect(rpc).toHaveBeenCalledWith("decide_agent_tool_call", expect.objectContaining({ p_decision: expect.objectContaining({ access: null, decision: "deny", lease_op: "none" }) }));
});
