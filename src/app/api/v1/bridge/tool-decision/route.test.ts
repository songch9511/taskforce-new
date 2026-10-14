import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { errorResponse } from "@/lib/api/respond";
import { decisionRequest, writeCall } from "@/lib/agents/tool-decision.fixtures";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ account: vi.fn(), auth: vi.fn(), decide: vi.fn(), cookie: vi.fn(), claims: vi.fn(), preflight: vi.fn() }));
vi.mock("@/lib/api/rate-limit", () => ({ takeBridgeDecisionPreflightLimit: mocks.preflight }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.account }));
vi.mock("@/lib/bridge/auth", () => ({ verifyBridgeDevice: mocks.auth }));
vi.mock("@/lib/bridge/tool-decision", () => ({ decideBridgeToolCall: mocks.decide }));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.cookie }));
vi.mock("@/lib/supabase/claims", () => ({ getVerifiedClaims: mocks.claims }));
import { POST, maxDuration } from "./route";
const account = { user: { id: "44444444-4444-4444-8444-444444444444" } };
const admin = { admin: true };
const bridge = { id: decisionRequest.bridge_id };
const response = { decision: "defer", reason: "command_not_readonly", card_flags: [], server_time: "2026-10-14T00:00:00Z" };
function request(body: unknown = decisionRequest, headers: Record<string, string> = {}) { return new Request("https://app.test/api/v1/bridge/tool-decision", { method: "POST", body: JSON.stringify(body), headers }); }
beforeEach(() => { vi.clearAllMocks(); mocks.preflight.mockReturnValue(null); mocks.account.mockResolvedValue(account); mocks.auth.mockResolvedValue({ ...account, admin, bridge }); mocks.decide.mockResolvedValue(response); });
afterEach(() => vi.restoreAllMocks());
it("U3 authenticates account before body, then device before decision", async () => {
  const req = request();
  const result = await POST(req);
  expect(result.status).toBe(200);
  expect(result.headers.get("cache-control")).toBe("no-store");
  expect(maxDuration).toBe(5);
  expect(mocks.account).toHaveBeenCalledExactlyOnceWith(req);
  expect(mocks.auth).toHaveBeenCalledExactlyOnceWith(req, decisionRequest.bridge_id, account);
  expect(mocks.account.mock.invocationCallOrder[0]).toBeLessThan(mocks.auth.mock.invocationCallOrder[0]);
  expect(mocks.auth.mock.invocationCallOrder[0]).toBeLessThan(mocks.decide.mock.invocationCallOrder[0]);
  expect(mocks.decide).toHaveBeenCalledExactlyOnceWith(admin, { userId: account.user.id, bridge, input: decisionRequest, startedAt: expect.any(Number) });
});
it("401 before consuming unauthenticated body", async () => {
  mocks.account.mockResolvedValue(null);
  const req = request();
  expect((await POST(req)).status).toBe(401);
  expect(req.bodyUsed).toBe(false);
  expect(mocks.auth).not.toHaveBeenCalled();
});
for (const status of [401, 403, 404]) it(`preserves device ${status} and does not decide`, async () => {
  mocks.auth.mockResolvedValue({ error: errorResponse(status, status === 404 ? "not_found" : "unauthorized", "No device.") });
  expect((await POST(request())).status).toBe(status);
  expect(mocks.decide).not.toHaveBeenCalled();
});
it("maps SQL ownership not_found to 404", async () => { mocks.decide.mockResolvedValue({ status: "not_found" }); expect((await POST(request())).status).toBe(404); });
it("U2 rejects body content before device auth", async () => {
  for (const field of ["content", "old_string", "new_string"]) expect((await POST(request({ ...decisionRequest, call: { ...writeCall, [field]: "private" } }))).status).toBe(400);
  expect(mocks.auth).not.toHaveBeenCalled();
  expect(mocks.decide).not.toHaveBeenCalled();
});
it("counts streamed bytes, not Content-Length, with 64 KiB boundary", async () => {
  const json = JSON.stringify(decisionRequest);
  for (const [size, status] of [[65536, 200], [65537, 400]]) {
    const req = new Request("https://app.test/api/v1/bridge/tool-decision", { method: "POST", body: json + " ".repeat(size - Buffer.byteLength(json)), headers: { "Content-Length": "1" } });
    expect((await POST(req)).status).toBe(status);
  }
  expect(mocks.decide).toHaveBeenCalledTimes(1);
});
it("malformed JSON does not expose request text", async () => {
  const result = await POST(new Request("https://app.test/api/v1/bridge/tool-decision", { method: "POST", body: "private-command" }));
  expect(result.status).toBe(400); expect(await result.text()).not.toContain("private-command");
});
it("U3 neither response nor exception logs echo command/path/secret", async () => {
  const body = { ...decisionRequest, call: { ...decisionRequest.call, command: "private-command", cwd: "/private-path" } };
  const log = vi.spyOn(console, "error").mockImplementation(() => {});
  expect(await (await POST(request(body))).json()).toEqual(response);
  mocks.decide.mockRejectedValue(new Error("private-command /private-path secret"));
  const result = await POST(request(body));
  expect(result.status).toBe(500);
  expect(await result.text()).not.toContain("private");
  expect(log).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "bridge_tool_decision_failed" }));
});
it("U3 real cookie authentication rejects cross-site writes before body/device", async () => {
  const real = await vi.importActual<typeof import("@/lib/api/auth")>("@/lib/api/auth");
  mocks.account.mockImplementation(real.authenticateRequest);
  const req = request(decisionRequest, { origin: "https://evil.test", cookie: "session=fake" });
  expect((await POST(req)).status).toBe(401);
  expect(req.bodyUsed).toBe(false);
  expect(mocks.cookie).not.toHaveBeenCalled();
  expect(mocks.auth).not.toHaveBeenCalled();
});

it("preflight is after authentication, before decision RPC, and never counts SQL twice", async () => {
  mocks.preflight.mockReturnValue(new Date(Date.now() + 60000));
  const result = await POST(request());
  expect(result.status).toBe(200);
  expect(await result.json()).toMatchObject({ decision: "deny", reason: "rate_limited" });
  expect(mocks.preflight).toHaveBeenCalledExactlyOnceWith(account.user.id, bridge.id);
  expect(mocks.auth.mock.invocationCallOrder[0]).toBeLessThan(mocks.preflight.mock.invocationCallOrder[0]);
  expect(mocks.decide).not.toHaveBeenCalled();
});
it("failed bridge authentication does not consume a preflight slot", async () => {
  mocks.auth.mockResolvedValue({ error: errorResponse(403, "unauthorized", "No device.") });
  expect((await POST(request())).status).toBe(403);
  expect(mocks.preflight).not.toHaveBeenCalled();
});

it("overlong targets reach SQL denial instead of a raw-length HTTP 400", async () => {
  mocks.decide.mockResolvedValue({ ...response, decision: "deny", reason: "path_too_long" });
  for (const real_path of ["/w/proj/" + "\u0958".repeat(600), "/w/proj/" + "a".repeat(1001)]) {
    const result = await POST(request({ ...decisionRequest, call: { ...writeCall, target: { real_path, rel_path: "a" } } }));
    expect(result.status).toBe(200);
    expect(await result.json()).toMatchObject({ decision: "deny", reason: "path_too_long" });
  }
  expect(mocks.decide).toHaveBeenCalledTimes(2);
});

it("preflight denial carries the same actionable agent note as SQL denial", async () => {
  mocks.preflight.mockReturnValue(new Date(Date.now() + 60000));
  expect(await (await POST(request())).json()).toMatchObject({
    decision: "deny", reason: "rate_limited", agent_note: "Too many tool requests. Wait before trying again.",
  });
  expect(mocks.decide).not.toHaveBeenCalled();
});
