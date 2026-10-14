import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { errorResponse } from "@/lib/api/respond";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ account: vi.fn(), limit: vi.fn(), auth: vi.fn(), operation: vi.fn() }));
vi.mock("@/lib/bridge/auth", () => ({ verifyBridgeDevice: mocks.auth }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.account }));
vi.mock("@/lib/api/rate-limit", async (original) => ({ ...await original<typeof import("@/lib/api/rate-limit")>(), takeBridgeRequestLimit: mocks.limit }));
const bridgeId = "11111111-1111-4111-8111-111111111111";
const userId = "22222222-2222-4222-8222-222222222222";
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
vi.mock("@/lib/bridge/heartbeat", () => ({ heartbeatBridge: mocks.operation }));
import { POST } from "./route";
const input = { bridge_id: bridgeId, sent_at: "2026-10-14T00:00:00Z", tasks: [] };
const request = (body: unknown = input) => new Request("https://api.example.test/api/v1/bridge/heartbeat", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

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

it("bounds task reports at 50 entries", async () => {
  const task = { task_id: bridgeId, process_alive: true, last_seq: 1 };
  expect((await POST(request({ ...input, tasks: Array.from({ length: 51 }, () => task) }))).status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("maps a bridge revoked after authentication to 404", async () => {
  mocks.operation.mockResolvedValue({ status: "not_found" });
  const response = await POST(request());
  expect(response.status).toBe(404);
  expect((await response.json()).error.code).toBe("not_found");
});
