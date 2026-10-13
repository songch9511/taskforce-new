import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), loadSessionAdapter: vi.fn(), stopAgentSession: vi.fn(), startNextQueuedTurn: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/sessions", async (original) => ({ ...(await original<typeof import("@/lib/agents/sessions")>()), loadSessionAdapter: mocks.loadSessionAdapter }));
vi.mock("@/lib/agents/tasks", async (original) => ({ ...(await original<typeof import("@/lib/agents/tasks")>()), stopAgentSession: mocks.stopAgentSession }));
vi.mock("@/lib/agents/turns", async (original) => ({ ...(await original<typeof import("@/lib/agents/turns")>()), startNextQueuedTurn: mocks.startNextQueuedTurn }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const TASK = "7a7a7a7a-0000-4000-8000-000000000001";
const call = () => POST(new Request(`https://api.example.dev/api/v2/agent-sessions/${SESSION}/stop`, { method: "POST", body: "{}" }), { params: Promise.resolve({ id: SESSION }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: true });
  mocks.stopAgentSession.mockResolvedValue({ tasks: [{ agent_task_id: TASK, cancel: "requested_only", processes: "may_continue" }] });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/agent-sessions/{id}/stop (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 중단 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.stopAgentSession).not.toHaveBeenCalled();
  });

  it("롤백 규칙: adapter 플래그가 꺼져 있어도 세션 Stop은 200 — 이미 있는 턴을 멈추고(confirmed) 다음 턴은 시작하지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("EXECUTION_ENABLED", "true");
    mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: false });
    mocks.stopAgentSession.mockResolvedValue({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
    expect(mocks.stopAgentSession).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, sessionId: SESSION, surface: "session_panel" });
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
  });

  it("켜져 있으면 세션 패널의 중단 (surface session_panel). requested_only뿐이면 다음 시작을 부르지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ tasks: [{ agent_task_id: TASK, cancel: "requested_only", processes: "may_continue" }] });
    expect(mocks.stopAgentSession).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, sessionId: SESSION, surface: "session_panel" });
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
  });
});
