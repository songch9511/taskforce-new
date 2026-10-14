import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), readConversationTarget: vi.fn(), resolveAgentTarget: vi.fn(), loadAgentDeliveries: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: vi.fn() }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), resolveAgentTarget: mocks.resolveAgentTarget }));
vi.mock("@/lib/agents/messages", async (original) => ({ ...(await original<typeof import("@/lib/agents/messages")>()), loadAgentDeliveries: mocks.loadAgentDeliveries }));

import { GET } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const MSG = "dddddddd-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const call = (query = "") => GET(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/delivery${query}`), { params: Promise.resolve({ id: CONV }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: null });
  mocks.resolveAgentTarget.mockResolvedValue({ enabled: true });
  mocks.loadAgentDeliveries.mockResolvedValue([{ message_id: MSG, seq: 3, delivery: { state: "accepted" } }]);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/v2/conversations/{id}/delivery (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("켜져 있으면 since_seq 뒤의 전달 표시를 돌려준다 (읽기만)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call("?since_seq=2");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ messages: [{ message_id: MSG, seq: 3, delivery: { state: "accepted" } }] });
    expect(mocks.loadAgentDeliveries).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER, CONV, { sinceSeq: 2 });
  });
});
