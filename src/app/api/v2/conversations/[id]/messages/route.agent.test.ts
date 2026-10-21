import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), consent: vi.fn(), readConversationTarget: vi.fn(), resolveAgentTarget: vi.fn(),
  loadConversation: vi.fn(), respondToMessage: vi.fn(), postUserMessage: vi.fn(), takeRateLimit: vi.fn(),
  checkAttachments: vi.fn(), postAgentUserMessage: vi.fn(), recordContextAttached: vi.fn(), startAgentMessage: vi.fn(), loadAgentMessageOutcome: vi.fn(), agentMessageExists: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: mocks.consent }));
vi.mock("@/lib/api/rate-limit-store", () => ({ takeRateLimit: mocks.takeRateLimit }));
vi.mock("@/lib/conversation/respond", async (original) => ({ ...(await original<typeof import("@/lib/conversation/respond")>()), respondToMessage: mocks.respondToMessage }));
vi.mock("@/lib/conversation/store", () => ({
  conversationModelsFromEnv: vi.fn(), loadConsultContext: vi.fn(), loadConversation: mocks.loadConversation, verifySelected: vi.fn(), userMessageExists: vi.fn(), postUserMessage: mocks.postUserMessage,
  loadMessage: vi.fn(), loadWindow: vi.fn(), finishTurn: vi.fn(), releaseLease: vi.fn(),
}));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: vi.fn() }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), resolveAgentTarget: mocks.resolveAgentTarget }));
vi.mock("@/lib/agents/attachments", async (original) => ({ ...(await original<typeof import("@/lib/agents/attachments")>()), checkAttachments: mocks.checkAttachments }));
vi.mock("@/lib/agents/messages", async (original) => ({
  ...(await original<typeof import("@/lib/agents/messages")>()),
  postAgentUserMessage: mocks.postAgentUserMessage, recordContextAttached: mocks.recordContextAttached, startAgentMessage: mocks.startAgentMessage,
  loadAgentMessageOutcome: mocks.loadAgentMessageOutcome, agentMessageExists: mocks.agentMessageExists,
}));

import { POST } from "./route";

// 에이전트 대상 대화는 같은 메시지 route로 들어와 agent delegate로 간다 (OA D1d): Taskforce 모델 경로(respondToMessage · 한도 · 기록 읽기)는 하나도 부르지 않는다 (R16).
const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const MSG = "dddddddd-0000-4000-8000-000000000001";
const CLIENT = "c1c1c1c1-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const ACTION = "aaaaaaaa-0000-4000-8000-000000000001";
const message = {
  id: MSG, conversation_id: CONV, seq: 1, role: "user", client_message_id: CLIENT, text: "이어서 해 줘",
  refs: { action_ids: [], run_ids: [], artifact_ids: [], suggestion_ids: [], dependency_ids: [], memory_item_ids: [], context_ids: [], proposal: null },
  intent: null, created_at: "2026-10-14T01:00:00.000Z", reply_to: null, content: null, delivery_state: "dispatched", delivery_reason: null, delivery_expires_at: "2026-10-15T01:00:00.000Z",
};
const call = (body: unknown = { client_message_id: CLIENT, text: "이어서 해 줘", attachments: [{ kind: "action", id: ACTION, origin: "added" }] }) =>
  POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/messages`, { method: "POST", body: JSON.stringify(body) }), { params: Promise.resolve({ id: CONV }) });

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.consent.mockResolvedValue(true);
  mocks.loadConversation.mockResolvedValue({ id: CONV, contextId: null, contextName: null });
  mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: null });
  mocks.resolveAgentTarget.mockResolvedValue({ enabled: true });
  mocks.agentMessageExists.mockResolvedValue(false);
  mocks.checkAttachments.mockResolvedValue({ missing: [], purged: [], executionArtifactIds: [] });
  mocks.postAgentUserMessage.mockResolvedValue({ status: "created", messageId: MSG, seq: 1 });
  mocks.recordContextAttached.mockResolvedValue(undefined);
  mocks.startAgentMessage.mockResolvedValue({ status: "queued", reason: "session_busy" });
  mocks.loadAgentMessageOutcome.mockResolvedValue({ message, delivery: { state: "queued", reason: "session_busy" }, created_action: null, agent_task: null });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/messages · 에이전트 대상 (route)", () => {
  it("에이전트 대화: 칩을 확인해 저장하고 전달을 시작한 뒤 reply 없는 응답을 돌려준다. Taskforce 모델 경로 호출 0", async () => {
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ reply: null, delivery: { state: "queued", reason: "session_busy" }, attachments_dropped: [], created_action: null, agent_task: null });
    expect(mocks.postAgentUserMessage).toHaveBeenCalledExactlyOnceWith({ admin: true }, {
      userId: USER, conversationId: CONV, clientMessageId: CLIENT, text: "이어서 해 줘",
      selected: { action_ids: [ACTION], context_ids: [], attachments: [{ kind: "action", id: ACTION, origin: "added" }] },
    });
    expect(mocks.recordContextAttached).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, "agent", [{ kind: "action", origin: "added", sent: true }]);
    expect(mocks.startAgentMessage).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, conversationId: CONV, messageId: MSG });
    for (const fn of [mocks.respondToMessage, mocks.postUserMessage, mocks.takeRateLimit]) expect(fn).not.toHaveBeenCalled();
  });

  it("그 연결의 adapter 플래그가 꺼져 있으면 404: 확인 · 저장 · 전달 0", async () => {
    mocks.resolveAgentTarget.mockResolvedValue({ enabled: false });
    expect((await call()).status).toBe(404);
    for (const fn of [mocks.checkAttachments, mocks.postAgentUserMessage, mocks.startAgentMessage]) expect(fn).not.toHaveBeenCalled();
  });

  it("남의 · 없는 칩이면 404: 저장 · 지표 · 전달 0 (AC-1)", async () => {
    mocks.checkAttachments.mockResolvedValue({ missing: [{ kind: "action", id: ACTION, origin: "added" }], purged: [], executionArtifactIds: [] });
    expect((await call()).status).toBe(404);
    for (const fn of [mocks.postAgentUserMessage, mocks.recordContextAttached, mocks.startAgentMessage]) expect(fn).not.toHaveBeenCalled();
  });

  it("동의가 없으면 409: 저장 · 전달 0", async () => {
    mocks.consent.mockResolvedValue(false);
    expect((await call()).status).toBe(409);
    expect(mocks.postAgentUserMessage).not.toHaveBeenCalled();
  });
});

// Enroll this route fixture only; global-off and authentication assertions are unchanged.
beforeEach(() => vi.stubEnv("AGENT_BETA_USER_IDS", "11111111-0000-4000-8000-000000000001"));
