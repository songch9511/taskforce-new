import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { setConversationContext } from "@/lib/conversation/store";
import { createAdminClient } from "@/lib/supabase/admin";

import { PATCH } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/conversation/store", () => ({
  setConversationContext: vi.fn(async () => ({
    status: "updated",
    conversation: { id: "cccccccc-0000-4000-8000-000000000001", title: null, context_id: "a6a6a6a6-0000-4000-8000-000000000001", created_at: "2026-10-10T01:00:00.000Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null },
  })),
}));

// 대화 범위 바꾸기 (B3, gate CONVERSATIONS_V2_ENABLED). route는 얇다: 본문 · 응답 규칙은 lib/api/conversations.test.ts, 범위 확인은 tests/db/memory-writes.scenarios.ts가 본다.
const CONVERSATION = "cccccccc-0000-4000-8000-000000000001";
const CONTEXT = "a6a6a6a6-0000-4000-8000-000000000001";
const call = (body: unknown, id = CONVERSATION) =>
  PATCH(new Request(`https://api.example.dev/api/v2/conversations/${id}`, { method: "PATCH", body: JSON.stringify(body) }), { params: Promise.resolve({ id }) });

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("PATCH /api/v2/conversations/{id} (route)", () => {
  it("gate 꺼짐(기본)이면 404, DB 클라이언트도 만들지 않는다. 기억 gate(MEMORY_ENABLED)만 켜도 열리지 않는다", async () => {
    expect((await call({ context_id: CONTEXT })).status).toBe(404);
    vi.stubEnv("MEMORY_ENABLED", "true");
    expect((await call({ context_id: CONTEXT })).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(setConversationContext).not.toHaveBeenCalled();
  });

  it("켜져 있으면 인증한 사용자 · 경로의 대화 id · 고른 범위로 바꾼다 (200 { conversation })", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call({ context_id: CONTEXT });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ conversation: { id: CONVERSATION, context_id: CONTEXT } });
    expect(setConversationContext).toHaveBeenCalledWith({ admin: true }, "11111111-0000-4000-8000-000000000001", CONVERSATION, CONTEXT);
    expect((await call({})).status).toBe(400);
    expect(setConversationContext).toHaveBeenCalledTimes(1);
  });
});
