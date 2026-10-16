import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
vi.mock("./triggers", () => ({ kickBridgeConnections: vi.fn().mockResolvedValue(undefined) }));
import { registerBridge, revokeBridge } from "./register";
import { kickBridgeConnections } from "./triggers";
const id = "10000000-0000-4000-8000-000000000001";
describe("bridge registration", () => {
  it("returns the active bridge cap rejection without issuing a credential", async () => {
    const rpc = vi.fn((name: string) => ({ throwOnError: async () => ({ data: name === "take_rate_limit" ? null : { status: "too_many_bridges" } }) }));
    expect(await registerBridge({ rpc } as unknown as SupabaseClient, id, { device_id: "new-installation", app_version: "1", adapters: [], connect: [], reactivate: false })).toEqual({ status: "too_many_bridges" });
  });
  it("stores only a user-scoped device digest and rotating credential digest", async () => {
    const rpc = vi.fn((...args: [string, Record<string, unknown>]) => ({ throwOnError: async () => ({ data: args[0] === "take_rate_limit" ? null : { status: "registered", bridge_id: id, connections: [] } }) }));
    const input = { device_id: "random-installation", app_version: "1", adapters: [], connect: [], reactivate: false };
    const first = await registerBridge({ rpc } as unknown as SupabaseClient, id, input);
    const second = await registerBridge({ rpc } as unknown as SupabaseClient, id, input);
    expect(first).toHaveProperty("bridge_secret");
    if (!("bridge_secret" in first) || !("bridge_secret" in second)) throw new Error("registration failed");
    expect(first.bridge_secret).not.toBe(second.bridge_secret);
    const args = rpc.mock.calls.find(([name]) => name === "register_bridge")?.[1];
    expect(args).toMatchObject({ p_device_ref: createHash("sha256").update(`${id}:${input.device_id}`).digest("hex"), p_secret_hash: createHash("sha256").update(first.bridge_secret).digest("hex") });
    expect(JSON.stringify(args)).not.toContain(first.bridge_secret);
    expect(JSON.stringify(args)).not.toContain(input.device_id);
  });
  it("retries only atomic NOWAIT revocations and preserves arguments", async () => {
    let attempts = 0;
    const rpc = vi.fn(() => ({ throwOnError: async () => { if (++attempts < 3) throw { code: "55P03" }; return { data: { status: "revoked", tasks: [] } }; } }));
    expect(await revokeBridge({ rpc } as unknown as SupabaseClient, id, id)).toEqual({ status: "revoked", tasks: [] });
    expect(rpc).toHaveBeenCalledTimes(3);
  });
  it("OA F3 also retries a deadlock victim (40P01), mixed with 55P03, and stops after three calls", async () => {
    const codes = ["40P01", "55P03"];
    let attempts = 0;
    const rpc = vi.fn((...call: unknown[]) => ({ throwOnError: async () => { void call; if (attempts < 2) throw { code: codes[attempts++] }; return { data: { status: "revoked", tasks: [] } }; } }));
    expect(await revokeBridge({ rpc } as unknown as SupabaseClient, id, id)).toEqual({ status: "revoked", tasks: [] });
    expect(rpc).toHaveBeenCalledTimes(3);
    expect(rpc.mock.calls[1]).toEqual(rpc.mock.calls[0]);
    const exhausted = vi.fn(() => ({ throwOnError: async () => { throw { code: "40P01" }; } }));
    await expect(revokeBridge({ rpc: exhausted } as unknown as SupabaseClient, id, id)).rejects.toEqual({ code: "40P01" });
    expect(exhausted).toHaveBeenCalledTimes(3);
  });
  it("OA F3 revokeBridge waits 50ms and then 150ms between attempts (a holder of the message row for ~10ms+ exhausted three immediate retries)", async () => {
    vi.useFakeTimers();
    try {
      let attempts = 0;
      const rpc = vi.fn((...call: unknown[]) => ({ throwOnError: async () => { void call; if (++attempts < 3) throw { code: "55P03" }; return { data: { status: "revoked", tasks: [] } }; } }));
      const result = revokeBridge({ rpc } as unknown as SupabaseClient, id, id);
      await vi.advanceTimersByTimeAsync(49);
      expect(rpc).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(rpc).toHaveBeenCalledTimes(2);
      await vi.advanceTimersByTimeAsync(149);
      expect(rpc).toHaveBeenCalledTimes(2);
      await vi.advanceTimersByTimeAsync(1);
      expect(await result).toEqual({ status: "revoked", tasks: [] });
      expect(rpc).toHaveBeenCalledTimes(3);
    } finally {
      vi.useRealTimers();
    }
  });
  it.each(["40001", "P0002", "XX000"])("OA F3 does not retry %s", async (code) => {
    const rpc = vi.fn(() => ({ throwOnError: async () => { throw { code }; } }));
    await expect(revokeBridge({ rpc } as unknown as SupabaseClient, id, id)).rejects.toEqual({ code });
    expect(rpc).toHaveBeenCalledTimes(1);
  });
});

// ─── F1s: 기기 이름 (표시용) ───
describe("bridge registration device name (F1s)", () => {
  afterEach(() => vi.restoreAllMocks());
  const bridge = "10000000-0000-4000-8000-0000000000b1";
  const base = { device_id: "random-installation", app_version: "1", adapters: [], connect: [], reactivate: false };
  const connection = { connection_id: "10000000-0000-4000-8000-0000000000c1", adapter: "agent:codex", status: "active", activated: true };
  function world(options: { status?: string; failName?: boolean } = {}) {
    const rpc = vi.fn<(name: string, args?: Record<string, unknown>) => unknown>((name) => ({
      throwOnError: async () => {
        if (name === "take_rate_limit") return { data: null };
        if (name === "set_bridge_device_name") {
          if (options.failName) throw new Error(`name write failed for WATCH-NAME ${bridge}`);
          return { data: { status: "updated" } };
        }
        return { data: { status: options.status ?? "registered", bridge_id: bridge, connections: [connection] } };
      },
    }));
    return { admin: { rpc } as unknown as SupabaseClient, rpc };
  }
  const nameCalls = (rpc: ReturnType<typeof world>["rpc"]) => rpc.mock.calls.filter(([name]) => name === "set_bridge_device_name");
  const expectedResponse = {
    bridge_id: bridge, bridge_secret: expect.any(String), heartbeat_interval_seconds: 30, unreachable_after_seconds: 90, long_poll_max_seconds: 25,
    connections: [{ connection_id: connection.connection_id, adapter: "agent:codex", status: "active" }],
  };

  it("이름이 없으면 이름 쓰기 0, 응답은 F1s 전과 같다 (이름 키 없음)", async () => {
    const { admin, rpc } = world();
    expect(await registerBridge(admin, id, base)).toEqual(expectedResponse);
    expect(rpc.mock.calls.map(([name]) => name)).toEqual(["take_rate_limit", "register_bridge"]);
  });

  it.each(["registered", "rotated", "reactivated"])("%s: register_bridge 뒤 kick 앞에 정규화한 이름을 한 번 쓴다 (응답에는 이름이 없다)", async (status) => {
    vi.mocked(kickBridgeConnections).mockClear();
    const { admin, rpc } = world({ status });
    expect(await registerBridge(admin, id, { ...base, device_name: "  Studio \u202e " })).toEqual(expectedResponse);
    expect(nameCalls(rpc)).toEqual([["set_bridge_device_name", { p_user_id: id, p_bridge_id: bridge, p_device_name: "Studio" }]]);
    const order = rpc.mock.calls.map(([name]) => name);
    expect(order.indexOf("set_bridge_device_name")).toBeGreaterThan(order.indexOf("register_bridge"));
    const write = rpc.mock.invocationCallOrder[order.indexOf("set_bridge_device_name")];
    expect(vi.mocked(kickBridgeConnections).mock.invocationCallOrder[0]).toBeGreaterThan(write);
  });

  it.each(["revoked", "too_many_bridges"])("%s면 이름을 쓰지 않는다", async (status) => {
    const { admin, rpc } = world({ status });
    expect(await registerBridge(admin, id, { ...base, device_name: "Studio" })).toEqual({ status });
    expect(nameCalls(rpc)).toEqual([]);
  });

  it("정규화하면 비는 이름은 쓰지 않는다", async () => {
    const { admin, rpc } = world();
    await registerBridge(admin, id, { ...base, device_name: " \u202e\u200b \t" });
    expect(nameCalls(rpc)).toEqual([]);
  });

  it("이름 쓰기가 던져도 응답 · secret은 그대로이고 사건 이름만 한 줄 남는다 (이미 secret을 회전했다)", async () => {
    vi.mocked(kickBridgeConnections).mockClear();
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin, rpc } = world({ failName: true });
    const result = await registerBridge(admin, id, { ...base, device_name: "WATCH-NAME" });
    expect(result).toEqual(expectedResponse);
    if (!("bridge_secret" in result)) throw new Error("registration failed");
    expect(rpc.mock.calls.find(([name]) => name === "register_bridge")?.[1]).toMatchObject({ p_secret_hash: expect.any(String) });
    expect(kickBridgeConnections).toHaveBeenCalledOnce();
    expect(error.mock.calls).toEqual([[JSON.stringify({ event: "bridge_device_name_failed" })]]);
    expect(JSON.stringify(error.mock.calls)).not.toContain("WATCH-NAME");
  });

  it("모르는 키 · 257 코드 포인트 이름 · 문자열이 아닌 이름은 던진다 (strict 유지)", async () => {
    const { admin, rpc } = world();
    await expect(registerBridge(admin, id, { ...base, device_name: "Studio", extra: 1 } as never)).rejects.toThrow();
    await expect(registerBridge(admin, id, { ...base, device_name: "\u{1f34e}".repeat(257) })).rejects.toThrow();
    await expect(registerBridge(admin, id, { ...base, device_name: 5 } as never)).rejects.toThrow();
    expect(rpc).not.toHaveBeenCalled();
    await expect(registerBridge(admin, id, { ...base, device_name: "\u{1f34e}".repeat(256) })).resolves.toMatchObject({ bridge_id: bridge });
  });
});
