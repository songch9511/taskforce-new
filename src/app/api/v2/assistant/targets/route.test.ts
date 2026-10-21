import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), listAssistantTargets: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), listAssistantTargets: mocks.listAssistantTargets }));

import { GET } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const targets = [{ kind: "taskforce" }, { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only" }];
const call = () => GET(new Request("https://api.example.dev/api/v2/assistant/targets"));

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.listAssistantTargets.mockResolvedValue(targets);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/v2/assistant/targets (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.listAssistantTargets).not.toHaveBeenCalled();
  });

  it("인증 거부 401", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    expect(mocks.listAssistantTargets).not.toHaveBeenCalled();
  });

  it("켜져 있으면 인증한 사용자의 목록을 돌려준다 (읽기만)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ targets });
    expect(mocks.listAssistantTargets).toHaveBeenCalledExactlyOnceWith({ admin: true }, USER);
  });
});

// Enroll this route fixture only; global-off and authentication assertions are unchanged.
beforeEach(() => vi.stubEnv("AGENT_BETA_USER_IDS", "11111111-0000-4000-8000-000000000001"));
