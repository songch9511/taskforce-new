import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: async () => ({ user: { id: "alice" }, supabase: {} }) }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: async () => true }));
vi.mock("@/lib/api/rate-limit-store", () => ({ takeRateLimit: async () => null }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: () => ({ rpc: async () => ({ error: { message: "ai_budget_exhausted" } }) }) }));
vi.mock("@/lib/actions/service", () => ({ createUserAction: vi.fn(async () => ({ id: "task", title: "Title" })) }));
import { createUserAction } from "@/lib/actions/service";
import { POST } from "./route";

afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });
describe("direct action embedding budget", () => {
  it("refuses paid embedding on cap exhaustion yet preserves manual action creation", async () => {
    vi.stubEnv("OPENROUTER_API_KEY", "key");
    const send = vi.fn(async (url: string) => url.endsWith("/endpoints") ? new Response(JSON.stringify({ data: { endpoints: [{ tag: "azure", context_length: 8192, pricing: { prompt: "0.00000002", completion: "0", discount: 0 } }] } })) : new Response(JSON.stringify({ data: [{ id: "openai/text-embedding-3-small", context_length: 8192, pricing: { prompt: "0.00000002", completion: "0" } }] }))); vi.stubGlobal("fetch", send);
    vi.spyOn(console, "error").mockImplementation(() => {});
    const result = await POST(new Request("https://example.test/api/v1/actions", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: "Title" }) }));
    expect(result.status).toBe(201);
    expect(send).toHaveBeenCalledTimes(2);
    expect(send.mock.calls.every(([url]) => url.endsWith("/models") || url.endsWith("/endpoints"))).toBe(true);
    expect(createUserAction).toHaveBeenCalledWith(expect.any(Object), "alice", expect.objectContaining({ embedding: null, title: "Title" }));
    expect(console.error).toHaveBeenCalledWith("직접 추가 임베딩 실패:", expect.stringContaining("ai_budget_exhausted"));
  });
});
