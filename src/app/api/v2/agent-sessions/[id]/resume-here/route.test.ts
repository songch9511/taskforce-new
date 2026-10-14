import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), loadSessionAdapter: vi.fn(), resumeAgentSessionHere: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/sessions", async (original) => ({ ...(await original<typeof import("@/lib/agents/sessions")>()), loadSessionAdapter: mocks.loadSessionAdapter, resumeAgentSessionHere: mocks.resumeAgentSessionHere }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const MSG = "dddddddd-0000-4000-8000-000000000001";
const session = { id: SESSION, connection_id: CONN, display_name: "Pricing", status: "bound", last_turn_seq: 2, updated_at: "2026-10-14T01:00:00.000Z" };
const call = (body: unknown = { confirmed_terminal_closed: true }) =>
  POST(new Request(`https://api.example.dev/api/v2/agent-sessions/${SESSION}/resume-here`, { method: "POST", body: JSON.stringify(body) }), { params: Promise.resolve({ id: SESSION }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: true });
  mocks.resumeAgentSessionHere.mockResolvedValue({ status: "bound", session, startedMessageId: MSG });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/agent-sessions/{id}/resume-here (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 전이 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.resumeAgentSessionHere).not.toHaveBeenCalled();
  });

  it("터미널을 닫았다는 확인이 있어야 되돌린다 (없으면 400, 전이 0). 되돌리면 세션과 시작된 메시지 id를 돌려준다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    expect((await call({})).status).toBe(400);
    expect((await call({ confirmed_terminal_closed: false })).status).toBe(400);
    expect(mocks.resumeAgentSessionHere).not.toHaveBeenCalled();
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ session, started_message_id: MSG });
    expect(mocks.resumeAgentSessionHere).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, SESSION);
  });
});
