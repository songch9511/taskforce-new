import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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

// ─── F1s: 기기 이름 (표시용) ───
describe("bridge heartbeat device name (F1s)", () => {
  afterEach(() => vi.restoreAllMocks());
  function named(data: unknown, options: { failName?: boolean } = {}) {
    const rpc = vi.fn<(name: string, args?: Record<string, unknown>) => unknown>((name) => ({
      throwOnError: async () => {
        if (name === "set_bridge_device_name") {
          if (options.failName) throw new Error(`name write failed for WATCH-NAME ${id}`);
          return { data: { status: "updated" } };
        }
        return { data };
      },
    }));
    const from = vi.fn(() => ({ select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), limit: vi.fn().mockReturnThis(), throwOnError: vi.fn().mockResolvedValue({ data: [{ id: other }] }) }));
    return { admin: { rpc, from } as unknown as SupabaseClient, rpc };
  }
  const nameCalls = (rpc: ReturnType<typeof named>["rpc"]) => rpc.mock.calls.filter(([name]) => name === "set_bridge_device_name");
  const expected = { heartbeat_interval_seconds: 30, server_time: expect.any(String), pending_commands: 3, unknown_task_ids: [other], missing_task_ids: [id] };

  it("이름이 없으면 이름 쓰기 0, 응답은 F1s 전과 같다", async () => {
    const { admin, rpc } = named(response);
    expect(await heartbeatBridge(admin, { userId: id, bridge, input })).toEqual(expected);
    expect(rpc.mock.calls.map(([name]) => name)).toEqual(["bridge_heartbeat"]);
  });

  it("이름이 있으면 bridge_heartbeat 뒤 kick 앞에 정규화한 이름을 한 번 쓴다 (응답에는 이름이 없다)", async () => {
    const { admin, rpc } = named(response);
    expect(await heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "  Studio \u202e " } })).toEqual(expected);
    expect(nameCalls(rpc)).toEqual([["set_bridge_device_name", { p_user_id: id, p_bridge_id: id, p_device_name: "Studio" }]]);
    const order = rpc.mock.calls.map(([name]) => name);
    expect(order).toEqual(["bridge_heartbeat", "set_bridge_device_name"]);
    const write = rpc.mock.invocationCallOrder[1];
    expect(vi.mocked(kickBridgeSessions).mock.invocationCallOrder[0]).toBeGreaterThan(write);
    expect(vi.mocked(drainBridgeSessionEvents).mock.invocationCallOrder[0]).toBeGreaterThan(write);
  });

  it("스로틀 응답에서도 이름을 한 번 쓴다 (app_version처럼 잃지 않는다)", async () => {
    const { admin, rpc } = named({ ...response, throttled: true });
    expect(await heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "Studio" } })).toEqual({ ...expected, throttled: true });
    expect(nameCalls(rpc)).toEqual([["set_bridge_device_name", { p_user_id: id, p_bridge_id: id, p_device_name: "Studio" }]]);
    expect(kickBridgeSessions).not.toHaveBeenCalled();
  });

  it("not_found(폐기 · 남의 bridge)면 이름을 쓰지 않는다", async () => {
    const { admin, rpc } = named({ status: "not_found" });
    expect(await heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "Studio" } })).toEqual({ status: "not_found" });
    expect(nameCalls(rpc)).toEqual([]);
  });

  it("정규화하면 비는 이름은 쓰지 않는다", async () => {
    const { admin, rpc } = named(response);
    await heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "\u200b \u202e" } });
    expect(nameCalls(rpc)).toEqual([]);
  });

  it.each([false, true])("이름 쓰기가 던져도 heartbeat 응답 · 생존 판정(kick · drain)은 그대로이고 사건 이름만 한 줄 남는다 (throttled=%s)", async (throttled) => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = named(throttled ? { ...response, throttled: true } : response, { failName: true });
    const result = await heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "WATCH-NAME" } });
    expect(result).toEqual(throttled ? { ...expected, throttled: true } : expected);
    expect(vi.mocked(kickBridgeSessions).mock.calls.length).toBe(throttled ? 0 : 1);
    expect(error.mock.calls).toEqual([[JSON.stringify({ event: "bridge_device_name_failed" })]]);
    expect(JSON.stringify(error.mock.calls)).not.toContain("WATCH-NAME");
  });

  it("모르는 키 · 257 코드 포인트 이름은 던진다 (strict 유지)", async () => {
    const { admin, rpc } = named(response);
    await expect(heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "Studio", extra: 1 } as never })).rejects.toThrow();
    await expect(heartbeatBridge(admin, { userId: id, bridge, input: { ...input, device_name: "\u{1f34e}".repeat(257) } })).rejects.toThrow();
    expect(rpc).not.toHaveBeenCalled();
  });
});
