import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { errorResponse } from "@/lib/api/respond";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ account: vi.fn(), limit: vi.fn(), auth: vi.fn(), operation: vi.fn(), stopConflicts: vi.fn() }));
vi.mock("@/lib/bridge/auth", () => ({ verifyBridgeDevice: mocks.auth }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.account }));
vi.mock("@/lib/api/rate-limit", async (original) => ({ ...await original<typeof import("@/lib/api/rate-limit")>(), takeBridgeRequestLimit: mocks.limit }));
const bridgeId = "11111111-1111-4111-8111-111111111111";
const userId = "22222222-2222-4222-8222-222222222222";
const commandId = "33333333-3333-4333-8333-333333333333";
const admin = { admin: true };
const bridge = { id: bridgeId, user_id: userId, status: "active" };
beforeEach(() => {
  vi.clearAllMocks();
  mocks.account.mockResolvedValue({ user: { id: userId } });
  mocks.limit.mockResolvedValue(undefined);
  mocks.auth.mockResolvedValue({ user: { id: userId }, admin, bridge });
  mocks.operation.mockResolvedValue({ status: "settled" });
  mocks.stopConflicts.mockResolvedValue({ stopped: 0, errors: 0 });
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());
vi.mock("@/lib/bridge/events", () => ({ applyBridgeEvents: mocks.operation }));
vi.mock("@/lib/agents/path-leases", () => ({ stopPathConflictRuns: mocks.stopConflicts }));
import { POST } from "./route";
const input = { bridge_id: bridgeId, events: [{ adapter: "agent:codex", session_ref: { agent_session_id: commandId }, agent_task_id: commandId, event_id: "event-1", type: "progress", observed_at: "2026-10-14T00:00:00Z" }] };
const request = (body: unknown = input) => new Request("https://api.example.test/api/v1/bridge/events", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

it.each([401, 403, 404])("device authentication %s has no side effects", async (status) => {
  mocks.auth.mockResolvedValue({ error: errorResponse(status, status === 404 ? "not_found" : "unauthorized", "Denied") });
  const response = await POST(request());
  expect(response.status).toBe(status);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("passes only authenticated ownership to the operation", async () => {
  const response = await POST(request());
  expect(response.status).toBe(200);
  expect(mocks.auth).toHaveBeenCalledWith(expect.any(Request), bridgeId, { user: { id: userId } });
  expect(mocks.operation).toHaveBeenCalledWith(admin, expect.objectContaining({ userId }));
});
it("keeps unexpected failure details out of logs and the response", async () => {
  const privateText = "PRIVATE-REQUEST-TEXT";
  mocks.operation.mockRejectedValue(new Error(privateText));
  const response = await POST(request());
  expect(response.status).toBe(500);
  expect(await response.text()).not.toContain(privateText);
  expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain(privateText);
});
it("rejects unknown input fields without writes", async () => {
  const response = await POST(request({ ...input, private_value: "hidden" }));
  expect(response.status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("rejects more than 100 events", async () => {
  const response = await POST(request({ ...input, events: Array.from({ length: 101 }, () => input.events[0]) }));
  expect(response.status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("rejects a streamed body over 1 MB without trusting Content-Length", async () => {
  const batch = { ...input, events: Array.from({ length: 32 }, (_, index) => ({ ...input.events[0], event_id: `event-${index}`, type: "message", text: "x".repeat(32_000) })) };
  const req = request(batch);
  req.headers.set("Content-Length", "1");
  const response = await POST(req);
  expect(response.status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});

it("accepts exactly 1 MB and cancels the stream immediately above the bound", async () => {
  const json = JSON.stringify(input);
  const response = await POST(new Request("https://api.example.test/api/v1/bridge/events", { method: "POST", body: json.padEnd(1_000_000) }));
  expect(response.status).toBe(200);
  expect(response.headers.get("Cache-Control")).toBe("no-store");
  mocks.operation.mockClear();
  const cancel = vi.fn();
  const stream = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(1_000_001)); }, cancel });
  const req = new Request("https://api.example.test/api/v1/bridge/events", { method: "POST", body: stream, duplex: "half" } as RequestInit);
  expect((await POST(req)).status).toBe(400);
  expect(cancel).toHaveBeenCalledOnce();
  expect(mocks.operation).not.toHaveBeenCalled();
});
it.each(["{", "null", "[]"]) ("rejects malformed event bodies (%s)", async (body) => {
  expect((await POST(new Request("https://api.example.test/api/v1/bridge/events", { method: "POST", body }))).status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});

import { RateLimitedError } from "@/lib/api/rate-limit";
it("returns 429 with Retry-After before executing a limited request", async () => {
  vi.useFakeTimers();
  try {
    vi.setSystemTime(new Date("2026-10-14T00:00:00Z"));
    mocks.limit.mockRejectedValueOnce(new RateLimitedError(new Date("2026-10-14T00:00:02.100Z")));
    const response = await POST(request());
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("3");
    expect(mocks.limit).toHaveBeenCalledExactlyOnceWith(admin, userId, bridgeId, "bridge_events");
    expect(mocks.operation).not.toHaveBeenCalled();
  } finally { vi.useRealTimers(); }
});

it("passes invalid individual events to per-event rejection without rejecting the batch", async () => {
  const events = [input.events[0], null, { event_id: "bad", type: "not-an-event" }];
  mocks.operation.mockResolvedValue({ accepted_event_ids: ["event-1"], retry_event_ids: [], results: [], rejected: [{ event_id: "", code: "invalid" }, { event_id: "bad", code: "invalid" }] });
  const response = await POST(request({ bridge_id: bridgeId, events }));
  expect(response.status).toBe(200);
  expect(mocks.operation).toHaveBeenCalledWith(admin, { userId, bridgeId, events });
  expect((await response.json()).rejected).toEqual([{ event_id: "", code: "invalid" }, { event_id: "bad", code: "invalid" }]);
});

it("U6 stops path conflict runs only after the event batch commits", async () => {
  const response = await POST(request());
  expect(await response.json()).toEqual({ status: "settled" });
  expect(mocks.stopConflicts).toHaveBeenCalledExactlyOnceWith(admin, { userId, bridgeId });
  expect(mocks.operation.mock.invocationCallOrder[0]).toBeLessThan(mocks.stopConflicts.mock.invocationCallOrder[0]);
});
it("U6 contains postcommit conflict stop failures and private exception text", async () => {
  mocks.stopConflicts.mockRejectedValue(new Error("PRIVATE-PATH-TEXT"));
  const response = await POST(request());
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ status: "settled" });
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "path_conflict_stop_failed" }));
});

it("U6 reports contained per-lease failures without changing committed event results", async () => {
  mocks.stopConflicts.mockResolvedValue({ stopped: 1, errors: 1 });
  expect((await POST(request())).status).toBe(200);
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "path_conflict_stop_failed" }));
});
