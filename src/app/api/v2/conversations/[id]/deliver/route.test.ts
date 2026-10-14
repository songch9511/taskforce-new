import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), readConversationTarget: vi.fn(), resolveAgentTarget: vi.fn(), deliverAgentMessages: vi.fn(), loadAgentDeliveriesByIds: vi.fn(), consent: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: mocks.consent }));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: vi.fn() }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), resolveAgentTarget: mocks.resolveAgentTarget }));
vi.mock("@/lib/agents/messages", async (original) => ({ ...(await original<typeof import("@/lib/agents/messages")>()), deliverAgentMessages: mocks.deliverAgentMessages, loadAgentDeliveriesByIds: mocks.loadAgentDeliveriesByIds }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const MSG = "dddddddd-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const call = (body: unknown = {}) => POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/deliver`, { method: "POST", body: JSON.stringify(body) }), { params: Promise.resolve({ id: CONV }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.consent.mockResolvedValue(true);
  mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: null });
  mocks.resolveAgentTarget.mockResolvedValue({ enabled: true });
  mocks.deliverAgentMessages.mockResolvedValue({ status: "ok", messages: [{ message_id: MSG, result: "requeued" }] });
  mocks.loadAgentDeliveriesByIds.mockResolvedValue({ [MSG]: { state: "queued", reason: "session_busy" } });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/deliver (route)", () => {
  it("CONVERSATIONS_V2_ENABLED가 정확히 'true'가 아니면 404: 인증 · DB 클라이언트 · 다시 보내기를 부르지 않는다", async () => {
    for (const value of [undefined, "1", "TRUE", " true"]) {
      if (value === undefined) vi.unstubAllEnvs();
      else vi.stubEnv("CONVERSATIONS_V2_ENABLED", value);
      expect((await call()).status).toBe(404);
    }
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.deliverAgentMessages).not.toHaveBeenCalled();
  });

  it("켜져 있으면 인증한 사용자 · 경로의 대화 id · 요청한 메시지 id로 다시 보낸다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call({ message_ids: [MSG] });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ messages: [{ message_id: MSG, result: "requeued", delivery: { state: "queued", reason: "session_busy" } }] });
    expect(mocks.deliverAgentMessages).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, conversationId: CONV, messageIds: [MSG] });
    expect(mocks.loadAgentDeliveriesByIds).toHaveBeenCalledWith({ admin: true }, USER, CONV, [MSG]);
  });

  it("adapter 플래그가 꺼진 연결의 대화는 404 (다시 보내기 0)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.resolveAgentTarget.mockResolvedValue({ enabled: false });
    expect((await call()).status).toBe(404);
    expect(mocks.deliverAgentMessages).not.toHaveBeenCalled();
  });
});
