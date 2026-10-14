import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("./triggers", () => ({ redeliverBridgeMessages: vi.fn().mockResolvedValue(2) }));
vi.mock("./events", () => ({ drainBridgeSessionEvents: vi.fn().mockResolvedValue(0) }));
import { sweepBridge } from "./sweep";
import { redeliverBridgeMessages } from "./triggers";
describe("bridge sweep rollback safety", () => {
  it("counts SQL bridge failures separately from successful session rows and uses the SQL lease clock", async () => {
    const id = "10000000-0000-4000-8000-000000000001";
    const rpc = vi.fn((name: string) => ({ throwOnError: async () => ({ data: name === "sweep_bridge_heartbeats" ? [
      { user_id: id, bridge_id: id, agent_session_id: id, agent_task_id: null, turn_seq: null, failure_count: 0 },
      { user_id: null, bridge_id: null, agent_session_id: null, agent_task_id: null, turn_seq: null, failure_count: 2 },
    ] : 3 }) }));
    expect(await sweepBridge({ rpc } as unknown as SupabaseClient)).toEqual({ unreachable: 1, expired_leases: 3, redelivered: 2, errors: 2 });
    expect(rpc).toHaveBeenCalledWith("sweep_agent_step_leases", { p_now: null });
  });
  it("runs heartbeat and lease cleanup while execution is off and isolates failures", async () => {
    vi.stubEnv("EXECUTION_ENABLED", "false");
    const rpc = vi.fn((name: string) => ({ throwOnError: async () => {
      if (name === "sweep_bridge_heartbeats") throw new Error("unavailable");
      return { data: 3 };
    } }));
    const result = await sweepBridge({ rpc } as unknown as SupabaseClient);
    expect(result).toMatchObject({ expired_leases: 3, redelivered: 2 });
    expect(rpc).toHaveBeenCalledWith("sweep_agent_step_leases", expect.any(Object));
    expect(rpc).toHaveBeenCalledWith("sweep_bridge_heartbeats", { p_limit: 50 });
    expect(redeliverBridgeMessages).toHaveBeenCalled();
    vi.unstubAllEnvs();
  });
});
