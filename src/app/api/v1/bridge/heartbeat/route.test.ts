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

// ─── F1s: 기기 이름 (표시용) ───
const WATCH_NAME = "WATCH-DEVICE-NAME-Studio";
const consoleText = () => JSON.stringify(["log", "info", "warn", "error", "debug"].map((method) => vi.mocked(console[method as "log"]).mock.calls));
function silenceConsole() {
  for (const method of ["log", "info", "warn", "error", "debug"] as const) vi.spyOn(console, method).mockImplementation(() => {});
}
it("device_name이 없는 옛 본문도 그대로 통과한다 (옛 Mac)", async () => {
  expect((await POST(request())).status).toBe(200);
  expect(mocks.operation).toHaveBeenCalledWith(admin, { userId, bridge, input });
  expect(mocks.operation.mock.calls[0][1].input).not.toHaveProperty("device_name");
});
it("device_name이 있으면 원문 그대로 heartbeatBridge에 넘긴다 (정규화는 거기서)", async () => {
  expect((await POST(request({ ...input, device_name: "  Studio  " }))).status).toBe(200);
  expect(mocks.operation).toHaveBeenCalledWith(admin, { userId, bridge, input: { ...input, device_name: "  Studio  " } });
});
it("원문 256 코드 포인트까지 통과하고 257에서 400이다", async () => {
  expect((await POST(request({ ...input, device_name: "\u{1f34e}".repeat(256) }))).status).toBe(200);
  mocks.operation.mockClear();
  expect((await POST(request({ ...input, device_name: "\u{1f34e}".repeat(257) }))).status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it.each([5, null, ["Studio"], { name: "Studio" }, true])("device_name이 문자열이 아니면 400이다: %j", async (value) => {
  expect((await POST(request({ ...input, device_name: value }))).status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("모르는 키는 device_name이 있어도 400이다 (strict 유지)", async () => {
  expect((await POST(request({ ...input, device_name: "Studio", hostname: "mac.local" }))).status).toBe(400);
  expect(mocks.operation).not.toHaveBeenCalled();
});
it("이름이 실린 요청이 실패해도 console 출력 · 응답에 이름이 없다", async () => {
  silenceConsole();
  mocks.operation.mockRejectedValue(new Error(`failed for ${WATCH_NAME}`));
  const response = await POST(request({ ...input, device_name: WATCH_NAME }));
  expect(response.status).toBe(500);
  expect(await response.text()).not.toContain(WATCH_NAME);
  expect(consoleText()).not.toContain(WATCH_NAME);
  mocks.operation.mockResolvedValue({ status: "settled" });
  expect((await POST(request({ ...input, device_name: WATCH_NAME }))).status).toBe(200);
  expect(consoleText()).not.toContain(WATCH_NAME);
});
