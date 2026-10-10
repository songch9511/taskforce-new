import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { INTERACTIVE_MAX_DURATION_S, RESPONSE_MARGIN_MS } from "@/lib/ai/deadline";
import { hasAiConsent } from "@/lib/api/profile-store";
import { respondToMessage } from "@/lib/conversation/respond";
import { conversationModelsFromEnv, loadConsultContext, postUserMessage } from "@/lib/conversation/store";
import { createAdminClient } from "@/lib/supabase/admin";

import { maxDuration, POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/api/rate-limit-store", () => ({ takeRateLimit: vi.fn(async () => null) }));
vi.mock("@/lib/conversation/respond", async (original) => ({
  ...(await original<typeof import("@/lib/conversation/respond")>()),
  respondToMessage: vi.fn(async (_input: unknown, deps: { retrieve: (q: { text: string; chunks: boolean }) => Promise<unknown> }) => {
    await deps.retrieve({ text: "q", chunks: true });
    return {
      intent: { kind: "consult", confidence: 0.9, judge_version: "intent-v1" },
      route: "consult",
      user: { refs: {} },
      reply: { text: "x", segments: [], citations: [], refs: {}, content: {} },
      memory: [],
      adopt: null,
      summary: {},
    };
  }),
}));
const MESSAGE = "dddddddd-0000-4000-8000-000000000001";
const REPLY = "dddddddd-0000-4000-8000-000000000002";
const row = (id: string, role: "user" | "assistant") => ({
  id,
  conversation_id: "cccccccc-0000-4000-8000-000000000001",
  seq: role === "user" ? 1 : 2,
  role,
  client_message_id: role === "user" ? "c1c1c1c1-0000-4000-8000-000000000001" : null,
  text: "x",
  refs: { action_ids: [], run_ids: [], artifact_ids: [], suggestion_ids: [], dependency_ids: [], memory_item_ids: [], context_ids: [], proposal: null },
  intent: null,
  created_at: "2026-10-10T01:00:00.000Z",
  reply_to: role === "assistant" ? MESSAGE : null,
  content: null,
});
vi.mock("@/lib/conversation/store", () => ({
  conversationModelsFromEnv: vi.fn(() => ({ decide: vi.fn(), complete: vi.fn() })),
  loadConsultContext: vi.fn(async () => ({})),
  loadConversation: vi.fn(async () => ({ id: "cccccccc-0000-4000-8000-000000000001", contextId: null, contextName: null })),
  verifySelected: vi.fn(async () => ({ targets: [] })),
  userMessageExists: vi.fn(async () => false),
  postUserMessage: vi.fn(async () => ({ status: "created", messageId: MESSAGE, seq: 1, replyId: null })),
  loadMessage: vi.fn(async (_admin: unknown, _user: string, id: string) => row(id, id === REPLY ? "assistant" : "user")),
  loadWindow: vi.fn(async () => ({ messages: [{ id: MESSAGE, seq: 1, role: "user", text: "x", textExpired: false, createdAt: "2026-10-10T01:00:00.000Z", refs: {}, content: null }], omitted: 0 })),
  finishTurn: vi.fn(async () => ({ status: "written", replyId: REPLY, memoryIds: [], actionId: null })),
  releaseLease: vi.fn(async () => undefined),
}));

const CONVERSATION = "cccccccc-0000-4000-8000-000000000001";
const send = () =>
  POST(new Request(`https://api.example.dev/api/v2/conversations/${CONVERSATION}/messages`, { method: "POST", body: JSON.stringify({ client_message_id: "c1c1c1c1-0000-4000-8000-000000000001", text: "오늘 뭐 하지?" }) }), {
    params: Promise.resolve({ id: CONVERSATION }),
  });

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("POST /api/v2/conversations/{id}/messages (route)", () => {
  it("실행 한도는 사용자가 기다리는 요청의 한도와 같다 (앱도 그만큼 기다린다)", () => {
    expect(maxDuration).toBe(INTERACTIVE_MAX_DURATION_S);
  });

  it("CONVERSATIONS_V2_ENABLED가 정확히 'true'가 아니면 404: DB 클라이언트 · 모델 설정 · 답 만들기를 부르지 않는다 (AI 호출 0)", async () => {
    for (const value of [undefined, "1", "TRUE", " true"]) {
      if (value === undefined) vi.stubEnv("CONVERSATIONS_V2_ENABLED", undefined as unknown as string);
      else vi.stubEnv("CONVERSATIONS_V2_ENABLED", value);
      const response = await send();
      expect(response.status, String(value)).toBe(404);
    }
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(conversationModelsFromEnv).not.toHaveBeenCalled();
    expect(respondToMessage).not.toHaveBeenCalled();
  });

  it("켜져 있으면 요청을 받자마자 정한 마감을 모델 · 기록 읽기에 넘긴다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.spyOn(Date, "now").mockReturnValue(1_000_000);
    const response = await send();
    expect(response.status).toBe(200);
    const deadline = 1_000_000 + INTERACTIVE_MAX_DURATION_S * 1000 - RESPONSE_MARGIN_MS;
    expect(conversationModelsFromEnv).toHaveBeenCalledWith({ admin: true }, "11111111-0000-4000-8000-000000000001", deadline);
    expect(vi.mocked(loadConsultContext).mock.calls[0][2]).toMatchObject({ deadline, chunks: true, contextId: null });
  });

  it("동의가 없으면 409: 저장 · 모델 설정을 부르지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.mocked(hasAiConsent).mockResolvedValueOnce(false);
    expect((await send()).status).toBe(409);
    expect(postUserMessage).not.toHaveBeenCalled();
    expect(conversationModelsFromEnv).not.toHaveBeenCalled();
  });
});
