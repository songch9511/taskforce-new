import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), readConversationTarget: vi.fn(), resolveAgentTarget: vi.fn(), stopAgentSession: vi.fn(), startNextQueuedTurn: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: vi.fn() }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), resolveAgentTarget: mocks.resolveAgentTarget }));
vi.mock("@/lib/agents/tasks", async (original) => ({ ...(await original<typeof import("@/lib/agents/tasks")>()), stopAgentSession: mocks.stopAgentSession }));
vi.mock("@/lib/agents/turns", async (original) => ({ ...(await original<typeof import("@/lib/agents/turns")>()), startNextQueuedTurn: mocks.startNextQueuedTurn }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const TASK = "7a7a7a7a-0000-4000-8000-000000000001";
const call = () => POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/stop`, { method: "POST", body: "{}" }), { params: Promise.resolve({ id: CONV }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: SESSION });
  mocks.resolveAgentTarget.mockResolvedValue({ enabled: true });
  mocks.stopAgentSession.mockResolvedValue({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
  mocks.startNextQueuedTurn.mockResolvedValue(null);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/stop (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 중단 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.stopAgentSession).not.toHaveBeenCalled();
  });

  it("그 대화의 세션을 surface 'assistant'로 멈추고, 확정된 작업이 있으면 다음 대기 메시지를 한 번 시작해 본다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("EXECUTION_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
    expect(mocks.stopAgentSession).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, sessionId: SESSION, surface: "assistant" });
    expect(mocks.startNextQueuedTurn).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, sessionId: SESSION }, expect.objectContaining({ EXECUTION_ENABLED: "true" }));
  });

  it("D2a 보안 검토 P1 방어: 실행 kill switch가 꺼져 있으면 Stop은 그대로 하되 다음 턴을 시작하지 않고 머리를 write_gate_closed로 표시한다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const MESSAGE = "dddddddd-0000-4000-8000-000000000001";
    const rpc = vi.fn((name: string) => ({ throwOnError: async () => ({ data: name === "next_queued_agent_message" ? MESSAGE : { status: "not_sent", reason: "write_gate_closed" }, error: null }) }));
    mocks.admin.mockReturnValue({ admin: true, rpc } as never);
    const response = await call();
    expect(response.status).toBe(200);
    expect(mocks.stopAgentSession).toHaveBeenCalledTimes(1);
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
    expect(rpc.mock.calls.map(([name]) => name)).toEqual(["next_queued_agent_message", "mark_agent_message_not_sent"]);
    mocks.admin.mockReturnValue({ admin: true });
  });

  it("세션이 없는 대화는 { tasks: [] }이고 중단 · 시작을 부르지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: null });
    const response = await call();
    expect(await response.json()).toEqual({ tasks: [] });
    expect(mocks.stopAgentSession).not.toHaveBeenCalled();
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
  });
});
