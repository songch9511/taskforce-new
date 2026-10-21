import { afterEach, describe, expect, it, vi } from "vitest";
import { handleCreateConversation } from "./conversations";
const USER = "10000000-0000-4000-8000-000000000001";
const OUTSIDER = "20000000-0000-4000-8000-000000000002";
afterEach(() => vi.unstubAllEnvs());
describe("conversation rollout admission order", () => {
  it("global-off returns 404 before authentication", async () => {
    const authenticate = vi.fn();
    const create = vi.fn();
    const response = await handleCreateConversation(new Request("https://api.example.test/api/v2/conversations", { method: "POST" }), { enabled: () => false, authenticate, create });
    expect(response.status).toBe(404);
    expect(authenticate).not.toHaveBeenCalled();
    expect(create).not.toHaveBeenCalled();
  });
  it("authenticated outsider is denied before parsing or creating", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_BETA_USER_IDS", USER);
    const authenticate = vi.fn(async () => ({ user: { id: OUTSIDER } }));
    const create = vi.fn();
    const response = await handleCreateConversation(new Request("https://api.example.test/api/v2/conversations", { method: "POST", body: "not-json" }), { enabled: () => true, authenticate, create });
    expect(response.status).toBe(404);
    expect(authenticate).toHaveBeenCalledOnce();
    expect(create).not.toHaveBeenCalled();
  });
});
