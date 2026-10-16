import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { RateLimitedError } from "@/lib/api/rate-limit";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ auth: vi.fn(), register: vi.fn(), revoke: vi.fn(), admin: { admin: true } }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: () => mocks.admin }));
vi.mock("@/lib/bridge/register", () => ({ registerBridge: mocks.register, revokeBridge: mocks.revoke }));
import { POST, DELETE } from "./route";
const userId = "22222222-2222-4222-8222-222222222222";
const bridgeId = "11111111-1111-4111-8111-111111111111";
const input = { device_id: "installation-random-id", app_version: "0.2.0", adapters: [] };
const request = (method: string, body: unknown = input) => new Request("https://api.example.test/api/v1/bridge/register", { method, body: JSON.stringify(body) });
beforeEach(() => {
  vi.clearAllMocks();
  mocks.auth.mockResolvedValue({ user: { id: userId } });
  mocks.register.mockResolvedValue({ bridge_id: bridgeId, bridge_secret: "issued-once" });
  mocks.revoke.mockResolvedValue({ status: "revoked", tasks: [] });
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());
it.each([POST, DELETE])("requires user authentication", async (handler) => {
  mocks.auth.mockResolvedValue(null);
  expect((await handler(request("POST"))).status).toBe(401);
  expect(mocks.register).not.toHaveBeenCalled();
  expect(mocks.revoke).not.toHaveBeenCalled();
});
it("registers normalized input under JWT ownership", async () => {
  expect((await POST(request("POST"))).status).toBe(200);
  expect(mocks.register).toHaveBeenCalledWith(mocks.admin, userId, { ...input, connect: [], reactivate: false });
});
it("allows revocation from another authenticated device without bridge secret", async () => {
  const response = await DELETE(request("DELETE", { bridge_id: bridgeId }));
  expect(response.status).toBe(200);
  expect(mocks.revoke).toHaveBeenCalledWith(mocks.admin, userId, bridgeId);
});
it("requires explicit reactivation for a revoked installation", async () => {
  mocks.register.mockResolvedValue({ status: "revoked" });
  expect((await POST(request("POST"))).status).toBe(403);
});
it("returns HTTP 409 for too_many_bridges", async () => {
  mocks.register.mockResolvedValue({ status: "too_many_bridges" });
  const response = await POST(request("POST"));
  expect(response.status).toBe(409);
  expect(await response.json()).toMatchObject({ error: { code: "conflict", message: "too_many_bridges" } });
});
it("enforces the register rate limit with Retry-After", async () => {
  mocks.register.mockRejectedValue(new RateLimitedError(new Date(Date.now() + 60_000)));
  const response = await POST(request("POST"));
  expect(response.status).toBe(429);
  expect(Number(response.headers.get("Retry-After"))).toBeGreaterThan(0);
});
it("rejects raw credentials and unknown report fields", async () => {
  expect((await POST(request("POST", { ...input, token: "not-allowed" }))).status).toBe(400);
  expect(mocks.register).not.toHaveBeenCalled();
});
it("keeps thrown provider values out of logs and responses", async () => {
  mocks.register.mockRejectedValue(new Error("PRIVATE-TEXT"));
  const response = await POST(request("POST"));
  expect(response.status).toBe(500);
  expect(await response.text()).not.toContain("PRIVATE-TEXT");
  expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("PRIVATE-TEXT");
});

// ─── F1s: 기기 이름 (표시용) ───
const WATCH_NAME = "WATCH-DEVICE-NAME-Studio";
const consoleText = () => JSON.stringify(["log", "info", "warn", "error", "debug"].map((method) => vi.mocked(console[method as "log"]).mock.calls));
function silenceConsole() {
  for (const method of ["log", "info", "warn", "error", "debug"] as const) vi.spyOn(console, method).mockImplementation(() => {});
}
it("device_name이 없는 옛 본문도 그대로 통과한다 (옛 Mac)", async () => {
  expect((await POST(request("POST"))).status).toBe(200);
  expect(mocks.register).toHaveBeenCalledWith(mocks.admin, userId, { ...input, connect: [], reactivate: false });
  expect(mocks.register.mock.calls[0][2]).not.toHaveProperty("device_name");
});
it("device_name이 있으면 원문 그대로 registerBridge에 넘긴다 (정규화는 거기서)", async () => {
  expect((await POST(request("POST", { ...input, device_name: "  Studio  " }))).status).toBe(200);
  expect(mocks.register).toHaveBeenCalledWith(mocks.admin, userId, { ...input, connect: [], reactivate: false, device_name: "  Studio  " });
});
it("원문 256 코드 포인트까지 통과하고 257에서 400이다", async () => {
  expect((await POST(request("POST", { ...input, device_name: "\u{1f34e}".repeat(256) }))).status).toBe(200);
  mocks.register.mockClear();
  expect((await POST(request("POST", { ...input, device_name: "\u{1f34e}".repeat(257) }))).status).toBe(400);
  expect(mocks.register).not.toHaveBeenCalled();
});
it.each([5, null, ["Studio"], { name: "Studio" }, true])("device_name이 문자열이 아니면 400이다: %j", async (value) => {
  expect((await POST(request("POST", { ...input, device_name: value }))).status).toBe(400);
  expect(mocks.register).not.toHaveBeenCalled();
});
it("모르는 키는 device_name이 있어도 400이다 (strict 유지)", async () => {
  expect((await POST(request("POST", { ...input, device_name: "Studio", hostname: "mac.local" }))).status).toBe(400);
  expect(mocks.register).not.toHaveBeenCalled();
});
it("이름이 실린 요청이 실패해도 console 출력 · 응답에 이름이 없다", async () => {
  silenceConsole();
  mocks.register.mockRejectedValue(new Error(`failed for ${WATCH_NAME}`));
  const response = await POST(request("POST", { ...input, device_name: WATCH_NAME }));
  expect(response.status).toBe(500);
  expect(await response.text()).not.toContain(WATCH_NAME);
  expect(consoleText()).not.toContain(WATCH_NAME);
  mocks.register.mockResolvedValue({ bridge_id: bridgeId, bridge_secret: "issued-once" });
  expect((await POST(request("POST", { ...input, device_name: WATCH_NAME }))).status).toBe(200);
  expect(consoleText()).not.toContain(WATCH_NAME);
});
