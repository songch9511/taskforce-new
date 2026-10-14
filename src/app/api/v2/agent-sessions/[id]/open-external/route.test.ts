import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), loadSessionAdapter: vi.fn(), openAgentSessionExternal: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/sessions", async (original) => ({ ...(await original<typeof import("@/lib/agents/sessions")>()), loadSessionAdapter: mocks.loadSessionAdapter, openAgentSessionExternal: mocks.openAgentSessionExternal }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const session = { id: SESSION, connection_id: CONN, display_name: "Pricing", status: "external", last_turn_seq: 1, updated_at: "2026-10-14T01:00:00.000Z" };
const call = () => POST(new Request(`https://api.example.dev/api/v2/agent-sessions/${SESSION}/open-external`, { method: "POST", body: "{}" }), { params: Promise.resolve({ id: SESSION }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: true });
  mocks.openAgentSessionExternal.mockResolvedValue({ status: "external", session });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/agent-sessions/{id}/open-external (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 전이 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.openAgentSessionExternal).not.toHaveBeenCalled();
  });

  it("켜져 있으면 external로 바꾸고 세션을 돌려준다. 턴이 진행 중이면 409 session_busy", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ session });
    expect(mocks.openAgentSessionExternal).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, SESSION);
    mocks.openAgentSessionExternal.mockResolvedValue({ status: "busy" });
    const busy = await call();
    expect(busy.status).toBe(409);
    expect(await busy.json()).toMatchObject({ error: { code: "session_busy" } });
  });
});
