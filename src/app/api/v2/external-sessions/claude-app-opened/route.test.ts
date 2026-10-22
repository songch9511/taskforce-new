import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), insert: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { POST } from "./route";

// Claude 데스크톱 세션 보기 지표 route (OA PR-D2): gate · 베타 명단 · 서버 권한 insert (사용자 id는 인증에서만 온다, props는 비어 있다) · 같은 날 두 번째(23505)는 조용히 204
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const call = (body: unknown = {}) =>
  POST(new Request("https://api.example.dev/api/v2/external-sessions/claude-app-opened", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

function open() {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", USER);
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.insert.mockResolvedValue({ error: null });
  mocks.admin.mockReturnValue({ from: (table: string) => ({ insert: (row: unknown) => mocks.insert(table, row) }) });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/external-sessions/claude-app-opened", () => {
  it("플래그가 꺼져 있으면 404: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("베타 명단 밖 사용자는 404 · 로그인하지 않았으면 401 (저장 0)", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call()).status).toBe(404);
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("인증된 사용자 id만으로 서버 권한 insert, props는 비어 있고 응답은 204", async () => {
    open();
    const response = await call();
    expect(response.status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type: "claude_app_session_opened", props: {} });
  });

  it("본문이 어떤 칸(사용자 id · 세션 · 제목)을 실어도 받지 않는다 (strict)", async () => {
    open();
    for (const body of [{ user_id: OTHER }, { title: "Fix launcher" }, { session_id: "5e5e5e5e-0000-4000-8000-000000000001" }, { folder: "/Users/me/secret" }]) {
      expect((await call(body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("같은 날 두 번째(23505)는 조용히 204, 그 밖의 저장 오류는 500 (로그에 값 0)", async () => {
    open();
    mocks.insert.mockResolvedValueOnce({ error: { code: "23505" } });
    expect((await call()).status).toBe(204);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.insert.mockResolvedValueOnce({ error: { code: "XX000" } });
    expect((await call()).status).toBe(500);
    expect(JSON.stringify(log.mock.calls)).toContain("claude_app_session_opened_failed");
    log.mockRestore();
  });
});
