import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("./triggers", () => ({ kickBridgeSessions: vi.fn() }));
import { pollBridgeCommands, bridgeDeliveryAccess } from "./commands";
const id = "10000000-0000-4000-8000-000000000001";
const empty = { commands: [], readbacks: [], next_cursor: 0 };
const report = { reported_at: "2026-10-14T00:00:00Z", adapters: { "agent:codex": { installed: true, version: "0.162.1", signed_in: "yes", managed_settings: false } } };
afterEach(() => vi.useRealTimers());
describe("bridge long polling", () => {
  it("wait zero does one read", async () => {
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: empty }) }));
    const result = await pollBridgeCommands({ rpc } as unknown as SupabaseClient, { userId: id, bridgeId: id, after: 0, wait: 0, signal: new AbortController().signal });
    expect(result.commands).toEqual([]);
    expect(rpc).toHaveBeenCalledTimes(1);
  });
  it("aborts without another database read", async () => {
    vi.useFakeTimers();
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: empty }) }));
    const controller = new AbortController();
    const promise = pollBridgeCommands({ rpc } as unknown as SupabaseClient, { userId: id, bridgeId: id, after: 0, wait: 25, signal: controller.signal });
    await vi.advanceTimersByTimeAsync(100);
    controller.abort();
    await promise;
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(vi.getTimerCount()).toBe(0);
  });
  it("returns readbacks immediately even when the cursor has not advanced", async () => {
    const readbacks = [{ command_id: id, kind: "message", agent_session_id: id, agent_task_id: id, turn_seq: 1, marker: "tf:marker", leased_at: "2026-10-14T00:00:00Z" }];
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: { commands: [], readbacks, next_cursor: 7 } }) }));
    const result = await pollBridgeCommands({ rpc } as unknown as SupabaseClient, { userId: id, bridgeId: id, after: 7, wait: 25, signal: new AbortController().signal });
    expect(result.readbacks).toEqual(readbacks);
    expect(rpc).toHaveBeenCalledExactlyOnceWith("list_bridge_commands", { p_user_id: id, p_bridge_id: id, p_after: 7, p_limit: 50 });
  });
  it("caps a polling call at 25 seconds", async () => {
    vi.useFakeTimers();
    const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: empty }) }));
    const promise = pollBridgeCommands({ rpc } as unknown as SupabaseClient, { userId: id, bridgeId: id, after: 0, wait: 99, signal: new AbortController().signal });
    await vi.advanceTimersByTimeAsync(25000);
    await promise;
    expect(rpc).toHaveBeenCalledTimes(14);
  });
});
describe("registry intersect bridge report", () => {
  it("narrows registry and never lets bridge claims open verification", () => {
    expect(bridgeDeliveryAccess("agent:codex", report, "manual", { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe("read_only");
    expect(bridgeDeliveryAccess("agent:codex", report, "manual", {})).toBeNull();
    expect(bridgeDeliveryAccess("agent:codex", report, "manual", { EXECUTION_ENABLED: "true" })).toBeNull();
    for (const change of [{ installed: false }, { version: "99.0.0" }, { signed_in: "no" }, { managed_settings: true }]) {
      expect(bridgeDeliveryAccess("agent:codex", { ...report, adapters: { "agent:codex": { ...report.adapters["agent:codex"], ...change } } }, "manual", { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBeNull();
    }
  });
});

import { ackBridgeCommand } from "./commands";
import * as registry from "@/lib/agents/registry";
import { appendBridgeSessionEvent } from "./events";
vi.mock("./events", () => ({ appendBridgeSessionEvent: vi.fn() }));
const timestamp = "2026-10-14T00:00:00Z";
const baseCommand = { id, agent_session_id: id, agent_task_id: id, turn_seq: 1, step_id: id,
  adapter: "agent:codex", marker: "tf:marker", session: { external_session_id: null, workspace_ref: null, resume: false } };
function ackDb(response: unknown, kind = "message", provider = "agent:codex") {
  const rpc = vi.fn(() => ({ throwOnError: vi.fn().mockResolvedValue({ data: response }) }));
  const from = vi.fn((table: string) => ({ select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(),
    throwOnError: vi.fn().mockResolvedValue({ data: table === "bridge_commands" ? { step_id: id, agent_task_id: id, kind }
      : table === "execution_steps" ? { provider } : table === "agent_tasks" ? { agent_session_id: id, turn_seq: 1 } : { mode: "full" } }) }));
  return { admin: { rpc, from } as unknown as SupabaseClient, rpc, from };
}
const bridge = { id, status: "active" as const, secret_hash: null, capabilities: report };
describe("bridge acknowledgment rollback safety", () => {
  afterEach(() => vi.restoreAllMocks());
  it("returns an allowed replay payload after supplying current access", async () => {
    const response = { status: "replay", lease_expires_at: timestamp, command: { ...baseCommand, kind: "message", access: "read_only", policy_mode: "manual", message: { id, text: "once" }, close_before: null } };
    const { admin, rpc } = ackDb(response);
    expect(await ackBridgeCommand(admin, { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "lease" } }, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toEqual(response);
    expect(rpc).toHaveBeenCalledWith("lease_bridge_command", expect.objectContaining({ p_access: "read_only", p_mode: "full" }));
  });
  it.each(["leased", "replay"])("uses Claude turn-and-processes scope for %s cancel with flags off", async (status) => {
    const { admin, rpc } = ackDb({ status, lease_expires_at: timestamp, command: { ...baseCommand, adapter: "agent:claude-code", kind: "cancel", abandoned_request_id: null, cancel_scope: "turn" } }, "cancel", "agent:claude-code");
    const result = await ackBridgeCommand(admin, { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "lease" } }, {});
    expect(result).toMatchObject({ status, command: { cancel_scope: "turn_and_processes" } });
    expect(rpc).toHaveBeenCalledWith("lease_bridge_command", expect.objectContaining({ p_access: null }));
  });
  it("reports adapter_disabled only for a withdrawn new delivery", async () => {
    const { admin } = ackDb({ status: "withdrawn", reason: "write_gate_closed" });
    vi.spyOn(registry, "adapterEnabled").mockReturnValue(false);
    expect(await ackBridgeCommand(admin, { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "lease" } }, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toEqual({ status: "withdrawn", reason: "adapter_disabled" });
  });
  it("readback never evaluates current policy or adapter flags", async () => {
    const { admin, from, rpc } = ackDb({ status: "settled", task_state: "accepted" });
    const enabled = vi.spyOn(registry, "adapterEnabled");
    await ackBridgeCommand(admin, { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "readback", result: "received", process_ended: false } }, {});
    expect(from).toHaveBeenCalledTimes(1);
    expect(enabled).not.toHaveBeenCalled();
    expect(rpc).toHaveBeenCalledWith("settle_bridge_command", expect.objectContaining({ p_op: "readback", p_result: "received" }));
  });
  it("repairs partial request_closed fanout on an idempotent settled retry", async () => {
    const { admin } = ackDb({ status: "settled", task_state: "running" }, "answer");
    const append = vi.mocked(appendBridgeSessionEvent).mockReset().mockRejectedValueOnce(new Error("append unavailable")).mockResolvedValue(undefined);
    const input = { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "request_closed" as const } };
    await expect(ackBridgeCommand(admin, input, {})).rejects.toThrow("append unavailable");
    await expect(ackBridgeCommand(admin, input, {})).resolves.toMatchObject({ status: "settled" });
    expect(append.mock.calls[0]).toEqual(append.mock.calls[1]);
    expect(append).toHaveBeenLastCalledWith(admin, expect.objectContaining({ originatingOnly: true, eventId: `bridge-ack:${id}:request_closed` }));
  });
});

describe("bridge capability boundary details", () => {
  it("rejects a disabled adapter even with healthy capabilities and execution enabled", () => {
    const enabled = vi.spyOn(registry, "adapterEnabled").mockReturnValue(false);
    try { expect(bridgeDeliveryAccess("agent:codex", report, "manual", { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBeNull(); }
    finally { enabled.mockRestore(); }
  });
  it.each(["0.162.0", "0.163.0", "0.162.1-beta", "9007199254740992.0.0", null])("fails closed on unsupported version %s", (version) => {
    expect(bridgeDeliveryAccess("agent:codex", { adapters: { "agent:codex": { ...report.adapters["agent:codex"], version } } }, "manual", { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBeNull();
  });
  it("uses server policy and registry enforcement even when client reports readiness", () => {
    for (const mode of ["manual", "auto", "full"] as const) {
      expect(bridgeDeliveryAccess("agent:codex", report, mode, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBe("read_only");
      expect(bridgeDeliveryAccess("agent:claude-code", { adapters: { "agent:claude-code": { ...report.adapters["agent:codex"], version: "2.1.241" } } }, mode, { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" })).toBeNull();
    }
    expect(bridgeDeliveryAccess("agent:other", report, "manual", { EXECUTION_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" })).toBeNull();
  });
});

it.each(["write_gate_closed", "not_connected", "adapter_disabled"])("does not kick a gate-withdrawn acknowledgment: %s", async (reason) => {
  const { kickBridgeSessions } = await import("./triggers");
  vi.mocked(kickBridgeSessions).mockClear();
  const { admin } = ackDb({ status: "withdrawn", reason });
  await ackBridgeCommand(admin, { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "lease" } });
  expect(kickBridgeSessions).not.toHaveBeenCalled();
});
it("returns stale/write_gate_closed from replay without another kick", async () => {
  const { kickBridgeSessions } = await import("./triggers");
  vi.mocked(kickBridgeSessions).mockClear();
  const { admin, rpc } = ackDb({ status: "stale", reason: "write_gate_closed" });
  expect(await ackBridgeCommand(admin, { userId: id, bridge, input: { bridge_id: id, command_id: id, op: "lease" } }, {})).toEqual({ status: "stale", reason: "write_gate_closed" });
  expect(rpc).toHaveBeenCalledWith("lease_bridge_command", expect.objectContaining({ p_access: null }));
  expect(kickBridgeSessions).not.toHaveBeenCalled();
});
