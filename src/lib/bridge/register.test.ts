import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
vi.mock("./triggers", () => ({ kickBridgeConnections: vi.fn().mockResolvedValue(undefined) }));
import { registerBridge, revokeBridge } from "./register";
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
});
