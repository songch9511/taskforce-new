import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("./triggers", () => ({ redeliverBridgeMessages: vi.fn().mockResolvedValue(2), kickBridgeSessions: vi.fn().mockResolvedValue(undefined) }));
vi.mock("./events", () => ({ drainBridgeSessionEvents: vi.fn().mockResolvedValue(0) }));
import { sweepBridge } from "./sweep";
import { kickBridgeSessions, redeliverBridgeMessages } from "./triggers";
const EMPTY_RECLAIM = { reclaimed: 0, busy: 0, sessions: [] };
describe("bridge sweep rollback safety", () => {
  it("counts SQL bridge failures separately from successful session rows and uses the SQL lease clock", async () => {
    const id = "10000000-0000-4000-8000-000000000001";
    const rpc = vi.fn((name: string) => ({ throwOnError: async () => ({ data: name === "sweep_bridge_heartbeats" ? [
      { user_id: id, bridge_id: id, agent_session_id: id, agent_task_id: null, turn_seq: null, failure_count: 0 },
      { user_id: null, bridge_id: null, agent_session_id: null, agent_task_id: null, turn_seq: null, failure_count: 2 },
    ] : name === "expire_unleased_agent_messages" ? EMPTY_RECLAIM : 3 }) }));
    expect(await sweepBridge({ rpc } as unknown as SupabaseClient)).toEqual({ unreachable: 1, expired_leases: 3, reclaimed: 0, reclaim_busy: 0, redelivered: 2, errors: 2 });
    expect(rpc).toHaveBeenCalledWith("sweep_agent_step_leases", { p_now: null });
  });
  it("runs heartbeat and lease cleanup while execution is off and isolates failures", async () => {
    vi.stubEnv("EXECUTION_ENABLED", "false");
    const rpc = vi.fn((name: string) => ({ throwOnError: async () => {
      if (name === "sweep_bridge_heartbeats") throw new Error("unavailable");
      return { data: name === "expire_unleased_agent_messages" ? EMPTY_RECLAIM : 3 };
    } }));
    const result = await sweepBridge({ rpc } as unknown as SupabaseClient);
    expect(result).toMatchObject({ expired_leases: 3, redelivered: 2 });
    expect(rpc).toHaveBeenCalledWith("sweep_agent_step_leases", expect.any(Object));
    expect(rpc).toHaveBeenCalledWith("sweep_bridge_heartbeats", { p_limit: 50 });
    expect(redeliverBridgeMessages).toHaveBeenCalled();
    vi.unstubAllEnvs();
  });
});

// ─── OA F3: 만료한 lease 전 prepared 회수 (expire_unleased_agent_messages) ───
const U1 = "20000000-0000-4000-8000-000000000001";
const U2 = "20000000-0000-4000-8000-000000000002";
const S1 = "30000000-0000-4000-8000-000000000001";
const S2 = "30000000-0000-4000-8000-000000000002";
const S3 = "30000000-0000-4000-8000-000000000003";

/** 이름별로 정한 응답을 돌려주는 가짜 service role. 호출 순서를 order에 쌓는다 */
function fakeAdmin(answers: Record<string, unknown>, order: string[] = []) {
  const rpc = vi.fn((name: string) => ({
    throwOnError: async () => {
      order.push(name);
      const answer = answers[name];
      if (answer instanceof Error) throw answer;
      return { data: answer ?? 3 };
    },
  }));
  return { admin: { rpc } as unknown as SupabaseClient, rpc, order };
}

describe("OA F3 sweepBridge: 만료한 lease 전 prepared 회수", () => {
  beforeEach(() => {
    vi.mocked(kickBridgeSessions).mockClear();
    vi.mocked(redeliverBridgeMessages).mockClear();
  });

  it("step lease 정리 뒤 · 재전달 앞에서 { p_limit: 50 }으로 한 번 부르고, 회수한 수와 막힌 수가 결과 숫자로 나온다", async () => {
    const order: string[] = [];
    vi.mocked(redeliverBridgeMessages).mockImplementationOnce(async () => { order.push("redeliver"); return 2; });
    const { admin, rpc } = fakeAdmin({ sweep_bridge_heartbeats: [], expire_unleased_agent_messages: { reclaimed: 3, busy: 2, sessions: [{ user_id: U1, agent_session_id: S1 }] } }, order);
    const result = await sweepBridge(admin);
    expect(result).toEqual({ unreachable: 0, expired_leases: 3, reclaimed: 3, reclaim_busy: 2, redelivered: 2, errors: 0 });
    expect(rpc.mock.calls.filter(([name]) => name === "expire_unleased_agent_messages")).toEqual([["expire_unleased_agent_messages", { p_limit: 50 }]]);
    expect(order).toEqual(["sweep_bridge_heartbeats", "sweep_agent_step_leases", "expire_unleased_agent_messages", "redeliver"]);
  });

  it("회수한 세션은 사용자별로 묶어 kick한다 (같은 사용자의 세션은 한 번에, 사용자가 다르면 따로)", async () => {
    const { admin } = fakeAdmin({
      sweep_bridge_heartbeats: [],
      expire_unleased_agent_messages: { reclaimed: 3, busy: 0, sessions: [{ user_id: U1, agent_session_id: S1 }, { user_id: U2, agent_session_id: S2 }, { user_id: U1, agent_session_id: S3 }] },
    });
    await sweepBridge(admin);
    expect(vi.mocked(kickBridgeSessions).mock.calls.map(([, userId, sessionIds]) => [userId, sessionIds])).toEqual([[U1, [S1, S3]], [U2, [S2]]]);
  });

  it("회수한 것이 없으면 kick하지 않는다", async () => {
    const { admin } = fakeAdmin({ sweep_bridge_heartbeats: [], expire_unleased_agent_messages: { reclaimed: 0, busy: 1, sessions: [] } });
    expect(await sweepBridge(admin)).toMatchObject({ reclaimed: 0, reclaim_busy: 1, errors: 0 });
    expect(kickBridgeSessions).not.toHaveBeenCalled();
  });

  it.each([
    ["모르는 키", { reclaimed: 1, busy: 0, sessions: [], extra: 1 }],
    ["음수", { reclaimed: -1, busy: 0, sessions: [] }],
    ["세션 줄의 모르는 키", { reclaimed: 1, busy: 0, sessions: [{ user_id: U1, agent_session_id: S1, text: "x" }] }],
    ["uuid가 아닌 id", { reclaimed: 1, busy: 0, sessions: [{ user_id: "u", agent_session_id: S1 }] }],
    ["객체가 아님", 3],
  ])("응답 모양이 틀리면 errors+1이고 결과 숫자는 0 · kick 0 · 다음 단계는 이어 돈다 (%s)", async (_name, answer) => {
    const { admin } = fakeAdmin({ sweep_bridge_heartbeats: [], expire_unleased_agent_messages: answer });
    const result = await sweepBridge(admin);
    expect(result).toMatchObject({ reclaimed: 0, reclaim_busy: 0, errors: 1, redelivered: 2 });
    expect(kickBridgeSessions).not.toHaveBeenCalled();
    expect(redeliverBridgeMessages).toHaveBeenCalled();
  });

  it("RPC가 실패하면 errors+1이고 재전달은 이어 돈다 (오류 글은 결과에 없다)", async () => {
    const { admin } = fakeAdmin({ sweep_bridge_heartbeats: [], expire_unleased_agent_messages: new Error("PRIVATE-DB-TEXT function missing") });
    const result = await sweepBridge(admin);
    expect(result).toEqual({ unreachable: 0, expired_leases: 3, reclaimed: 0, reclaim_busy: 0, redelivered: 2, errors: 1 });
    expect(JSON.stringify(result)).not.toContain("PRIVATE-DB-TEXT");
    expect(redeliverBridgeMessages).toHaveBeenCalled();
  });

  it("결과 객체의 값은 숫자뿐이다 (id · 글 0): cron 로그 bridge_sweep에 그대로 실린다", async () => {
    const { admin } = fakeAdmin({ sweep_bridge_heartbeats: [], expire_unleased_agent_messages: { reclaimed: 1, busy: 1, sessions: [{ user_id: U1, agent_session_id: S1 }] } });
    const result = await sweepBridge(admin);
    for (const value of Object.values(result)) expect(typeof value).toBe("number");
    expect(JSON.stringify(result)).not.toContain(S1);
    expect(JSON.stringify(result)).not.toContain(U1);
  });
});
