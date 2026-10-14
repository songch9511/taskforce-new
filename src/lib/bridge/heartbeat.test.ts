import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("./events", () => ({ drainBridgeSessionEvents: vi.fn().mockResolvedValue(0) }));
vi.mock("./triggers", () => ({ kickBridgeSessions: vi.fn().mockResolvedValue(undefined), kickBridgeConnections: vi.fn().mockResolvedValue(undefined) }));
import { heartbeatBridge } from "./heartbeat";
import { drainBridgeSessionEvents } from "./events";
import { kickBridgeConnections, kickBridgeSessions } from "./triggers";
const id = "10000000-0000-4000-8000-000000000001";
const other = "10000000-0000-4000-8000-000000000002";
const bridge = { id, status: "active" as const, secret_hash: null, capabilities: {} };
const input = { bridge_id: id, sent_at: "2099-01-01T00:00:00Z", tasks: [{ task_id: id, process_alive: false, last_seq: 1 }] };
const response = { revived_session_ids: [id], kick_session_ids: [id], activated_connection_ids: [other], pending_commands: 3, unknown_task_ids: [other], missing_task_ids: [id] };
function db(data: unknown) {
  const rpc = vi.fn(() => ({ throwOnError: vi.fn().mockResolvedValue({ data }) }));
  const from = vi.fn(() => ({ select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), limit: vi.fn().mockReturnThis(), throwOnError: vi.fn().mockResolvedValue({ data: [{ id: other }] }) }));
  return { admin: { rpc, from } as unknown as SupabaseClient, rpc, from };
}
beforeEach(() => vi.clearAllMocks());
describe("bridge heartbeat", () => {
  it("passes process evidence without client time and returns only the heartbeat DTO", async () => {
    const { admin, rpc } = db(response);
    const result = await heartbeatBridge(admin, { userId: id, bridge, input });
    expect(rpc).toHaveBeenCalledWith("bridge_heartbeat", { p_user_id: id, p_bridge_id: id, p_tasks: input.tasks, p_report: null, p_app_version: null });
    expect(result).toEqual({ heartbeat_interval_seconds: 30, server_time: expect.any(String), pending_commands: 3, unknown_task_ids: [other], missing_task_ids: [id] });
    expect(kickBridgeSessions).toHaveBeenCalledWith(admin, id, [id]);
    expect(kickBridgeConnections).toHaveBeenCalledWith(admin, id, [other], process.env, [id]);
    expect(drainBridgeSessionEvents).toHaveBeenCalledWith(admin, { userId: id, bridgeId: id });
  });
  it("normalizes optional adapter reports without inventing permissions", async () => {
    const { admin, rpc } = db(response);
    const adapter = { adapter: "agent:codex" as const, installed: true, version: "0.162.1", signed_in: "yes" as const, managed_settings: false };
    await heartbeatBridge(admin, { userId: id, bridge, input: { ...input, adapters: [adapter], app_version: "2" } });
    expect(rpc).toHaveBeenCalledWith("bridge_heartbeat", expect.objectContaining({ p_app_version: "2", p_report: { reported_at: expect.any(String), adapters: { "agent:codex": { installed: true, version: "0.162.1", signed_in: "yes", managed_settings: false } } } }));
  });
  it("retries durable status lines on a later heartbeat even without newly revived sessions", async () => {
    const { admin } = db({ ...response, revived_session_ids: [] });
    vi.mocked(drainBridgeSessionEvents).mockRejectedValueOnce(new Error("database offline")).mockResolvedValueOnce(0);
    await expect(heartbeatBridge(admin, { userId: id, bridge, input })).resolves.toMatchObject({ pending_commands: 3 });
    await expect(heartbeatBridge(admin, { userId: id, bridge, input })).resolves.toMatchObject({ pending_commands: 3 });
    expect(drainBridgeSessionEvents).toHaveBeenCalledTimes(2);
  });
  it("retries active connections after activation has already committed", async () => {
    const { admin, from } = db({ ...response, activated_connection_ids: [] });
    await heartbeatBridge(admin, { userId: id, bridge, input });
    expect(from).toHaveBeenCalledWith("agent_connections");
    expect(kickBridgeConnections).toHaveBeenCalledWith(admin, id, [other], process.env, [id]);
  });
  it("does not trigger or fan out after an ownership refusal", async () => {
    const { admin } = db({ status: "not_found" });
    expect(await heartbeatBridge(admin, { userId: id, bridge, input })).toEqual({ status: "not_found" });
    expect(kickBridgeSessions).not.toHaveBeenCalled();
    expect(drainBridgeSessionEvents).not.toHaveBeenCalled();
  });
});

it("throttled heartbeat has no fanout, queue kicks, or connection reads", async () => {
  const { admin, from } = db({ ...response, throttled: true });
  expect(await heartbeatBridge(admin, { userId: id, bridge, input })).toMatchObject({ throttled: true, pending_commands: 3 });
  expect(from).not.toHaveBeenCalled();
  expect(drainBridgeSessionEvents).not.toHaveBeenCalled();
  expect(kickBridgeSessions).not.toHaveBeenCalled();
  expect(kickBridgeConnections).not.toHaveBeenCalled();
});
