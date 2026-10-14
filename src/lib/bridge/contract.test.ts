import { describe, expect, it } from "vitest";
import { bridgeV1AckResponseSchema, bridgeV1EventsRequestSchema, bridgeV1HeartbeatResponseSchema, bridgeV1AckRequestSchema, bridgeV1EventSchema, bridgeV1RegisterRequestSchema } from "@/lib/api/contract";
const id = "10000000-0000-4000-8000-000000000001";
const report = { adapter: "agent:codex", installed: true, version: "0.162.1", signed_in: "yes", managed_settings: false };
const event = { adapter: "agent:codex", session_ref: { agent_session_id: id }, agent_task_id: id, event_id: "e", type: "message", observed_at: "2026-10-14T00:00:00Z" };
describe("D2a DTO boundary", () => {
  it("requires ended process evidence for a negative readback", () => {
    const ack = { bridge_id: id, command_id: id, op: "readback", result: "not_received" };
    expect(bridgeV1AckRequestSchema.safeParse(ack).success).toBe(false);
    expect(bridgeV1AckRequestSchema.safeParse({ ...ack, process_ended: false }).success).toBe(false);
    expect(bridgeV1AckRequestSchema.safeParse({ ...ack, process_ended: true }).success).toBe(true);
  });
  it("uses UTF-8 bytes for the event body limit", () => {
    expect(bridgeV1EventSchema.safeParse({ ...event, text: "🙂".repeat(8192) }).success).toBe(true);
    expect(bridgeV1EventSchema.safeParse({ ...event, text: "🙂".repeat(8193) }).success).toBe(false);
  });
  it("rejects duplicate reports and client permission claims", () => {
    const registration = { device_id: "device-installation", app_version: "1", adapters: [report] };
    expect(bridgeV1RegisterRequestSchema.parse(registration).connect).toEqual([]);
    expect(bridgeV1RegisterRequestSchema.safeParse({ ...registration, adapters: [report, report] }).success).toBe(false);
    expect(bridgeV1RegisterRequestSchema.safeParse({ ...registration, adapters: [{ ...report, verified: true }] }).success).toBe(false);
  });
  it("rejects unknown operations and payload text copies", () => {
    expect(bridgeV1AckRequestSchema.safeParse({ bridge_id: id, command_id: id, op: "dispatch" }).success).toBe(false);
    expect(bridgeV1EventSchema.safeParse({ ...event, text: "ok", payload: { text: "copy" } }).success).toBe(false);
  });
});

it("connect accepts only registry adapters", () => {
  const body = { device_id: "device-installation", app_version: "1", adapters: [] };
  expect(bridgeV1RegisterRequestSchema.safeParse({ ...body, connect: ["agent:unknown"] }).success).toBe(false);
  expect(bridgeV1RegisterRequestSchema.parse({ ...body, connect: ["agent:codex", "agent:claude-code"] }).connect).toEqual(["agent:codex", "agent:claude-code"]);
});
it("validates event envelopes independently of individual events", () => {
  expect(bridgeV1EventsRequestSchema.parse({ bridge_id: id, events: [event, null, { event_id: "bad" }] }).events).toEqual([event, null, { event_id: "bad" }]);
});
it("accepts explicit throttled heartbeat responses", () => {
  expect(bridgeV1HeartbeatResponseSchema.parse({ heartbeat_interval_seconds: 30, server_time: "2026-10-14T00:00:00Z", pending_commands: 0, unknown_task_ids: [], missing_task_ids: [], throttled: true }).throttled).toBe(true);
});

it("preserves a closed-gate replay as stale rather than an invalid response", () => {
  expect(bridgeV1AckResponseSchema.parse({ status: "stale", reason: "write_gate_closed" })).toEqual({ status: "stale", reason: "write_gate_closed" });
});
