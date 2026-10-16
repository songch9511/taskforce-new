import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ cookie: vi.fn(), admin: vi.fn(), operation: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.cookie }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/bridge/commands", () => ({ ackBridgeCommand: mocks.operation, pollBridgeCommands: mocks.operation }));
vi.mock("@/lib/bridge/answer-local", () => ({ answerSecretLocally: mocks.operation }));
vi.mock("@/lib/bridge/heartbeat", () => ({ heartbeatBridge: mocks.operation }));
vi.mock("@/lib/bridge/events", () => ({ applyBridgeEvents: mocks.operation }));
vi.mock("@/lib/bridge/register", () => ({ registerBridge: mocks.operation, revokeBridge: mocks.operation }));

import { GET as commands } from "@/app/api/v1/bridge/commands/route";
import { POST as ack } from "@/app/api/v1/bridge/ack/route";
import { POST as answerLocal } from "@/app/api/v1/bridge/answer-local/route";
import { POST as events } from "@/app/api/v1/bridge/events/route";
import { POST as heartbeat } from "@/app/api/v1/bridge/heartbeat/route";
import { POST as register, DELETE as revoke } from "@/app/api/v1/bridge/register/route";

const userId = "11111111-1111-4111-8111-111111111111";
const bridgeId = "22222222-2222-4222-8222-222222222222";
const taskId = "33333333-3333-4333-8333-333333333333";
const secret = "A".repeat(43);
const bridge = { id: bridgeId, status: "active", capabilities: {}, secret_hash: createHash("sha256").update(secret).digest("hex") };
const at = "2026-10-14T00:00:00Z";
const routes = [
  { path: "commands", method: "GET", handler: commands, body: undefined },
  { path: "ack", method: "POST", handler: ack, body: { bridge_id: bridgeId, command_id: taskId, op: "lease" } },
  { path: "events", method: "POST", handler: events, body: { bridge_id: bridgeId, events: [{ adapter: "agent:codex", session_ref: { agent_session_id: taskId }, agent_task_id: taskId, event_id: "event-1", type: "progress", observed_at: at }] } },
  { path: "heartbeat", method: "POST", handler: heartbeat, body: { bridge_id: bridgeId, sent_at: at, tasks: [] } },
  { path: "answer-local", method: "POST", handler: answerLocal, body: { bridge_id: bridgeId, agent_task_id: taskId, request_digest: "a".repeat(64) } },
];
const writes = [
  ...routes.filter((route) => route.method === "POST"),
  { path: "register", method: "POST", handler: register, body: { device_id: "installation-random-id", app_version: "0.2.0", adapters: [] } },
  { path: "register", method: "DELETE", handler: revoke, body: { bridge_id: bridgeId } },
];
function request(route: { path: string; method: string; body?: unknown }, headers: Record<string, string> = {}) {
  return new Request(`https://api.example.test/api/v1/bridge/${route.path}?bridge_id=${bridgeId}`, {
    method: route.method, headers: { "content-type": "application/json", "X-Taskforce-Bridge-Secret": secret, ...headers },
    body: route.body ? JSON.stringify(route.body) : undefined,
  });
}
function database(row: unknown = bridge) {
  const query = { select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(), throwOnError: vi.fn(async () => ({ data: row })) };
  mocks.admin.mockReturnValue({ from: vi.fn(() => query), rpc: vi.fn(() => ({ throwOnError: async () => ({ data: null }) })) } as unknown as SupabaseClient);
  return query;
}
const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
const token = () => `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ sub: userId, role: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600 })}.c2ln`;

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_bridge-test");
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
  mocks.cookie.mockResolvedValue({ auth: { getClaims: vi.fn(async () => ({ data: { claims: { sub: userId } }, error: null })) } });
  database();
  mocks.operation.mockResolvedValue({ status: "settled" });
});
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

describe("bridge routes with real request and device authentication", () => {
  it.each(writes)("rejects cross-site cookie $method $path before privileged access", async (route) => {
    const response = await route.handler(request(route, { "sec-fetch-site": "cross-site" }));
    expect(response.status).toBe(401);
    expect(mocks.cookie).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.operation).not.toHaveBeenCalled();
  });
  it.each(routes)("accepts same-origin cookie $path with the matching device credential", async (route) => {
    const query = database();
    const response = await route.handler(request(route, { origin: "https://api.example.test" }));
    expect(response.status).toBe(200);
    expect(mocks.cookie).toHaveBeenCalledOnce();
    expect(query.eq).toHaveBeenCalledWith("user_id", userId);
    expect(query.eq).toHaveBeenCalledWith("id", bridgeId);
    expect(mocks.operation).toHaveBeenCalledOnce();
  });
  it.each(routes)("accepts verified Bearer $path and bypasses cookie CSRF only", async (route) => {
    const fetch = vi.fn(async () => Response.json({ id: userId }));
    vi.stubGlobal("fetch", fetch);
    expect((await route.handler(request(route, { authorization: `Bearer ${token()}`, "sec-fetch-site": "cross-site" }))).status).toBe(200);
    expect(fetch).toHaveBeenCalledOnce();
    expect(mocks.cookie).not.toHaveBeenCalled();
    expect(mocks.operation).toHaveBeenCalledOnce();
  });
  it.each(routes)("requires a JWT/session as well as a device secret for $path", async (route) => {
    mocks.cookie.mockResolvedValue({ auth: { getClaims: vi.fn(async () => ({ data: null, error: null })) } });
    expect((await route.handler(request(route))).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.operation).not.toHaveBeenCalled();
  });
  it.each(routes)("rejects missing/wrong credentials, another account and revoked $path without writes", async (route) => {
    for (const credential of ["", "B".repeat(43)]) {
      expect((await route.handler(request(route, { "X-Taskforce-Bridge-Secret": credential }))).status).toBe(401);
    }
    database(null);
    expect((await route.handler(request(route))).status).toBe(404);
    database({ ...bridge, status: "revoked" });
    expect((await route.handler(request(route))).status).toBe(403);
    expect(mocks.operation).not.toHaveBeenCalled();
  });
});

it.each([...routes, ...writes.filter((route) => route.path === "register")])("authenticates before reading or parsing malformed $method $path", async (route) => {
  const req = new Request("https://api.example.test/api/v1/bridge/" + route.path + "?bridge_id=invalid", {
    method: route.method, headers: { "sec-fetch-site": "cross-site" },
    ...(route.method === "GET" ? {} : { body: "{" }),
  });
  mocks.cookie.mockResolvedValue({ auth: { getClaims: vi.fn(async () => ({ data: null, error: null })) } });
  const read = vi.spyOn(req, "json");
  expect((await route.handler(req)).status).toBe(401);
  expect(read).not.toHaveBeenCalled();
  expect(req.bodyUsed).toBe(false);
  expect(mocks.admin).not.toHaveBeenCalled();
  expect(mocks.operation).not.toHaveBeenCalled();
});
