import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createConversation } from "@/lib/conversation/store";
import { createAdminClient } from "@/lib/supabase/admin";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "11111111-0000-4000-8000-000000000001" } })) }));
vi.mock("@/lib/conversation/store", () => ({
  createConversation: vi.fn(async () => ({
    status: "created",
    conversation: { id: "cccccccc-0000-4000-8000-000000000001", title: null, context_id: null, created_at: "2026-10-10T01:00:00.000Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null },
  })),
}));

const create = (body: unknown) => POST(new Request("https://api.example.dev/api/v2/conversations", { method: "POST", body: JSON.stringify(body) }));

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllEnvs());

describe("POST /api/v2/conversations (route)", () => {
  it("gate 꺼짐(기본)이면 404, DB를 부르지 않는다", async () => {
    expect((await create({})).status).toBe(404);
    expect(createAdminClient).not.toHaveBeenCalled();
    expect(createConversation).not.toHaveBeenCalled();
  });

  it("켜져 있으면 앱이 정한 id · 범위로 만든다 (201)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await create({ id: "cccccccc-0000-4000-8000-000000000001", title: "Shape", context_id: null });
    expect(response.status).toBe(201);
    expect(createConversation).toHaveBeenCalledWith({ admin: true }, "11111111-0000-4000-8000-000000000001", {
      id: "cccccccc-0000-4000-8000-000000000001",
      title: "Shape",
      contextId: null,
    });
  });
});
