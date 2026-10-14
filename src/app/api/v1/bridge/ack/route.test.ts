import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { errorResponse } from "@/lib/api/respond";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ account: vi.fn(), limit: vi.fn(), auth: vi.fn(), operation: vi.fn() }));
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
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());
vi.mock("@/lib/bridge/commands", () => ({ ackBridgeCommand: mocks.operation }));
import { POST } from "./route";
const input = { bridge_id: bridgeId, command_id: commandId, op: "lease" };
const request = (body: unknown = input) => new Request("https://api.example.test/api/v1/bridge/ack", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

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
it.each([undefined, false])("requires process_ended=true for not_received (%s)", async (processEnded) => {
  const response = await POST(request({ bridge_id: bridgeId, command_id: commandId, op: "readback", result: "not_received", process_ended: processEnded }));
  expect(response.status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("maps missing command to the frozen 404 error", async () => {
  mocks.operation.mockResolvedValue({ status: "not_found" });
  const response = await POST(request());
  expect(response.status).toBe(404);
  expect((await response.json()).error.code).toBe("not_found");
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
    expect(mocks.limit).toHaveBeenCalledExactlyOnceWith(admin, userId, bridgeId, "bridge_ack");
    expect(mocks.operation).not.toHaveBeenCalled();
  } finally { vi.useRealTimers(); }
});

it("returns a closed-gate replay as 200 stale without changing its reason", async () => {
  mocks.operation.mockResolvedValue({ status: "stale", reason: "write_gate_closed" });
  const response = await POST(request());
  expect(response.status).toBe(200);
  expect(await response.json()).toEqual({ status: "stale", reason: "write_gate_closed" });
});
