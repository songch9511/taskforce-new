import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("./triggers", () => ({ kickBridgeSessions: vi.fn().mockResolvedValue(undefined) }));
vi.mock("@/lib/agents/events", () => ({ applyAgentEvent: vi.fn() }));
import { applyAgentEvent } from "@/lib/agents/events";
import { applyBridgeEvents } from "./events";
const id = "10000000-0000-4000-8000-000000000001";
const other = "10000000-0000-4000-8000-000000000002";
const event = (event_id: string, session = id) => ({ adapter: "agent:codex", session_ref: { agent_session_id: session }, agent_task_id: id, event_id, type: "accepted", observed_at: "2026-10-14T00:00:00Z" });
const admin = {} as SupabaseClient;
beforeEach(() => vi.resetAllMocks());
describe("bridge event outbox acknowledgments", () => {
  it.each(["55P03", "40001", "40P01", "08006", "XX000"])("retries %s and blocks only later events of that session", async (code) => {
    vi.mocked(applyAgentEvent).mockRejectedValueOnce({ code }).mockResolvedValue({ status: "applied", applied: true });
    const result = await applyBridgeEvents(admin, { userId: id, bridgeId: id, events: [event("1"), event("2"), event("3", other)] });
    expect(result.retry_event_ids).toEqual(["1", "2"]);
    expect(result.accepted_event_ids).toEqual(["3"]);
    expect(applyAgentEvent).toHaveBeenCalledTimes(2);
    expect(applyAgentEvent).toHaveBeenLastCalledWith(admin, expect.objectContaining({ bridgeId: id }));
  });
  it("separates invalid input from final and retry outcomes", async () => {
    vi.mocked(applyAgentEvent).mockRejectedValueOnce({ code: "22023" }).mockResolvedValue({ status: "duplicate", applied: false });
    const result = await applyBridgeEvents(admin, { userId: id, bridgeId: id, events: [event("1"), event("2")] });
    expect(result.rejected).toEqual([{ event_id: "1", code: "invalid" }]);
    expect(result.accepted_event_ids).toEqual(["2"]);
    expect(result.retry_event_ids).toEqual([]);
  });
});

import { drainBridgeSessionEvents } from "./events";
describe("durable bridge status fanout", () => {
  it("keeps a partially appended status pending and repairs it with the same id", async () => {
    const descriptor = { id, user_id: id, bridge_id: id, external_event_id: `bridge-restored:${id}:1`,
      payload: { event_type: "bridge_restored", agent_session_id: id, agent_task_id: id, turn_seq: 1, fanout_pending: true } };
    const updates = vi.fn();
    const from = vi.fn((table: string) => {
      let updating = false;
      return { select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), contains: vi.fn().mockReturnThis(), in: vi.fn().mockReturnThis(), order: vi.fn().mockReturnThis(), limit: vi.fn().mockReturnThis(),
        update: vi.fn((payload: unknown) => { updating = true; updates(payload); return from("updated"); }),
        throwOnError: vi.fn(async () => ({ data: updating || table === "updated" ? null : table === "execution_events" ? [descriptor] : [{ id }, { id: other }] })) };
    });
    let failed = false;
    const rpc = vi.fn((_name: string, args: { p_conversation_id: string }) => ({ throwOnError: async () => {
      if (args.p_conversation_id === other && !failed) { failed = true; throw new Error("busy"); }
      return { data: [{ status: "created", message_id: id, seq: 1 }] };
    } }));
    const db = { from, rpc } as unknown as SupabaseClient;
    expect(await drainBridgeSessionEvents(db, { userId: id, bridgeId: id })).toBe(1);
    expect(updates).not.toHaveBeenCalled();
    expect(await drainBridgeSessionEvents(db, { userId: id, bridgeId: id })).toBe(0);
    expect(updates).toHaveBeenCalledWith({ payload: { ...descriptor.payload, fanout_pending: false } });
    expect(rpc.mock.calls[0]).toEqual(rpc.mock.calls[2]);
    expect(rpc.mock.calls[1]).toEqual(rpc.mock.calls[3]);
    expect(rpc.mock.calls[0][1]).toMatchObject({ p_text: "Connection restored" });
  });
});

it("rejects malformed events individually and continues valid events in the same session", async () => {
  vi.mocked(applyAgentEvent).mockResolvedValue({ status: "applied", applied: true });
  const result = await applyBridgeEvents(admin, { userId: id, bridgeId: id, events: [{ ...event("bad"), type: "invalid" }, event("good")] });
  expect(result.rejected).toEqual([{ event_id: "bad", code: "invalid" }]);
  expect(result.accepted_event_ids).toEqual(["good"]);
  expect(applyAgentEvent).toHaveBeenCalledTimes(1);
});
it("uses the partial-index predicate and both ownership filters for pending fanout", async () => {
  const q = { select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), contains: vi.fn().mockReturnThis(), in: vi.fn().mockReturnThis(), order: vi.fn().mockReturnThis(), limit: vi.fn().mockReturnThis(), throwOnError: async () => ({ data: [] }) };
  await drainBridgeSessionEvents({ from: () => q } as unknown as SupabaseClient, { userId: id, bridgeId: other });
  expect(q.eq).toHaveBeenCalledWith("payload->>fanout_pending", "true");
  expect(q.eq).toHaveBeenCalledWith("user_id", id);
  expect(q.eq).toHaveBeenCalledWith("bridge_id", other);
});
it("global fanout discovers only ownership metadata before reading scoped descriptors", async () => {
  const selections: string[] = [];
  const q = { select: (value: string) => { selections.push(value); return q; }, eq: vi.fn().mockReturnThis(), in: vi.fn().mockReturnThis(), order: vi.fn().mockReturnThis(), limit: vi.fn().mockReturnThis(), throwOnError: async () => ({ data: [] }) };
  await drainBridgeSessionEvents({ from: () => q } as unknown as SupabaseClient);
  expect(selections).toEqual(["user_id,bridge_id"]);
});
