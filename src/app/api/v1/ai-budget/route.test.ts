import { beforeEach, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ auth: vi.fn(), rpc: vi.fn() }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: () => ({ rpc: mocks.rpc }) }));
import { GET } from "./route";
const summary = { cap_usd: 10, confirmed_usd: 2, reserved_usd: 3, pending_count: 4, remaining_usd: 5, status: "available" };
beforeEach(() => { vi.clearAllMocks(); mocks.auth.mockResolvedValue({ user: { id: "alice" } }); mocks.rpc.mockResolvedValue({ data: summary, error: null }); });
it("auth scopes aggregate reads, ignores supplied account and strips detail", async () => {
  mocks.rpc.mockResolvedValue({ data: { ...summary, generation_id: "private" }, error: null });
  const response = await GET(new Request("https://test/api/v1/ai-budget?user_id=bob"));
  expect(mocks.rpc).toHaveBeenCalledWith("ai_spend_summary", { p_user_id: "alice" });
  expect(await response.json()).toEqual(summary);
  expect(response.headers.get("Cache-Control")).toBe("no-store");
});
it("requires authentication", async () => {
  mocks.auth.mockResolvedValue(null);
  expect((await GET(new Request("https://test"))).status).toBe(401);
  expect(mocks.rpc).not.toHaveBeenCalled();
});
it.each([{ data: null, error: { message: "private database detail" } }, { data: { ...summary, confirmed_usd: null }, error: null }])("does not invent a zero summary on database/malformed results", async (result) => {
  mocks.rpc.mockResolvedValue(result);
  const response = await GET(new Request("https://test"));
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: { code: "ai_budget_unavailable", message: "Could not load your AI allowance." } });
});
