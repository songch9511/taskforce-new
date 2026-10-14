import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), readConversationTarget: vi.fn(), resolveAgentTarget: vi.fn(),
  setAgentMessageReferent: vi.fn(), startAgentMessage: vi.fn(), loadAgentMessageOutcome: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: vi.fn() }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), resolveAgentTarget: mocks.resolveAgentTarget }));
vi.mock("@/lib/agents/messages", async (original) => ({
  ...(await original<typeof import("@/lib/agents/messages")>()),
  setAgentMessageReferent: mocks.setAgentMessageReferent, startAgentMessage: mocks.startAgentMessage, loadAgentMessageOutcome: mocks.loadAgentMessageOutcome,
}));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const MSG = "dddddddd-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";
const call = (body: unknown = { action_id: ACTION }) =>
  POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/messages/${MSG}/referent`, { method: "POST", body: JSON.stringify(body) }), { params: Promise.resolve({ id: CONV, message_id: MSG }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: null });
  mocks.resolveAgentTarget.mockResolvedValue({ enabled: true });
  mocks.setAgentMessageReferent.mockResolvedValue("already_dispatched");
  mocks.loadAgentMessageOutcome.mockResolvedValue(null);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/messages/{message_id}/referent (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 선택 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.setAgentMessageReferent).not.toHaveBeenCalled();
  });

  it("켜져 있으면 경로의 대화 · 메시지 id와 고른 action으로 선택하고, 선택되면 같은 메시지를 시작한다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.setAgentMessageReferent.mockResolvedValue("selected");
    await call();
    expect(mocks.setAgentMessageReferent).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, conversationId: CONV, messageId: MSG, actionId: ACTION });
    expect(mocks.startAgentMessage).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, conversationId: CONV, messageId: MSG });
  });

  it("이미 전달된 메시지는 시작하지 않는다 (다시 전달 0)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    await call();
    expect(mocks.startAgentMessage).not.toHaveBeenCalled();
  });
});
