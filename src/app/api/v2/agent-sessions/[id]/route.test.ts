import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), loadSessionAdapter: vi.fn(), renameAgentSession: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/sessions", async (original) => ({ ...(await original<typeof import("@/lib/agents/sessions")>()), loadSessionAdapter: mocks.loadSessionAdapter, renameAgentSession: mocks.renameAgentSession }));

import { PATCH } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const session = { id: SESSION, connection_id: CONN, display_name: "Pricing", status: "bound", last_turn_seq: 1, updated_at: "2026-10-14T01:00:00.000Z" };
const call = (body: unknown = { display_name: "  Pricing  " }) => PATCH(new Request(`https://api.example.dev/api/v2/agent-sessions/${SESSION}`, { method: "PATCH", body: JSON.stringify(body) }), { params: Promise.resolve({ id: SESSION }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: true });
  mocks.renameAgentSession.mockResolvedValue({ status: "renamed", session });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("PATCH /api/v2/agent-sessions/{id} (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 이름 바꾸기 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.renameAgentSession).not.toHaveBeenCalled();
  });

  it("켜져 있으면 trim한 이름으로 바꾼다 (사용자 id · 경로의 세션 id)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ session });
    expect(mocks.renameAgentSession).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, SESSION, "Pricing");
  });

  it("adapter 플래그가 꺼져 있으면 404 (이름 바꾸기 0)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: false });
    expect((await call()).status).toBe(404);
    expect(mocks.renameAgentSession).not.toHaveBeenCalled();
  });
});
