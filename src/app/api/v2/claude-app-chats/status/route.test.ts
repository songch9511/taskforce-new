import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { GET } from "./route";

// 저장이 켜졌는지 Mac이 글을 보내기 전에 묻는다 (OA PR-D3s, 계약 25.3). 꺼짐 · 명단 밖이면 404 — Mac은 404면 글을 서버로 한 바이트도 보내지 않는다.
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const call = () => GET(new Request("https://api.example.dev/api/v2/claude-app-chats/status", { method: "GET" }));
const FLAGS = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", CLAUDE_APP_CHATS_ENABLED: "true" };
function open(extra: Record<string, string> = {}) {
  for (const [key, value] of Object.entries({ ...FLAGS, AGENT_BETA_USER_IDS: USER, ...extra })) vi.stubEnv(key, value);
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/v2/claude-app-chats/status", () => {
  it("기본값(플래그 꺼짐)은 404: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each(Object.keys(FLAGS))("%s 하나만 꺼져도 404", async (flag) => {
    open();
    vi.stubEnv(flag, "false");
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
  });

  it("명단 밖은 404 · 로그인하지 않았으면 401", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call()).status).toBe(404);
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
  });

  it("모두 켜져 있으면 { save: true, max_batch: 20, max_bytes: 262144 } (DB를 부르지 않는다)", async () => {
    open();
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ save: true, max_batch: 20, max_bytes: 262_144 });
    expect(mocks.admin).not.toHaveBeenCalled();
  });
});
