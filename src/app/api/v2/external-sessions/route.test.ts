import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), rpc: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { PUT } from "./route";

// 외부 세션 목록 보고 route (OA 외부 세션 PR1): gate · 베타 명단 · 저장 함수 인자 (사용자 id는 인증에서만 온다)
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const ref = (n: number) => n.toString(16).padStart(64, "0");
const row = { id: ref(1), title: "Fix launcher focus", state: "running_claude_app", last_activity_at: "2026-10-21T09:00:00Z" };
const call = (body: unknown = { bridge_id: BRIDGE, sessions: [row] }) =>
  PUT(new Request("https://api.example.dev/api/v2/external-sessions", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

function open() {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
  vi.stubEnv("EXTERNAL_SESSIONS_REPORT_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", USER);
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.admin.mockReturnValue({ rpc: mocks.rpc });
  mocks.rpc.mockResolvedValue({ data: { status: "ok", kept: 1, removed: 0 }, error: null });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("PUT /api/v2/external-sessions", () => {
  it("플래그가 꺼져 있으면 404: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each(["CONVERSATIONS_V2_ENABLED", "AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "EXTERNAL_SESSIONS_REPORT_ENABLED"])("%s 하나만 꺼져도 404 (제목 보고는 전용 gate가 따로 필요하다)", async (flag) => {
    open();
    vi.stubEnv(flag, "false");
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
  });

  it.each(["false", "TRUE", "1", " true", ""])("전용 gate 값이 %j이면 꺼진 것이다 (정확히 \"true\"만 켠다)", async (value) => {
    open();
    vi.stubEnv("EXTERNAL_SESSIONS_REPORT_ENABLED", value);
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("베타 명단 밖 사용자는 404 (DB 0)", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call()).status).toBe(404);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401", async () => {
    open();
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("저장 함수는 인증된 사용자 id와 검증한 bridge · 목록으로만 부른다", async () => {
    open();
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ kept: 1, removed: 0 });
    expect(mocks.rpc).toHaveBeenCalledExactlyOnceWith("report_external_sessions", { p_user_id: USER, p_bridge_id: BRIDGE, p_sessions: [row] });
  });

  it("본문이 사용자 id를 실어도 받지 않는다 (strict)", async () => {
    open();
    expect((await call({ bridge_id: BRIDGE, user_id: OTHER, sessions: [] })).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("함수가 not_found를 주면 404, 오류를 주면 500 (제목 없이)", async () => {
    open();
    mocks.rpc.mockResolvedValueOnce({ data: { status: "not_found" }, error: null });
    expect((await call()).status).toBe(404);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.rpc.mockResolvedValueOnce({ data: null, error: Object.assign(new Error("Fix launcher focus"), { code: "XX000" }) });
    expect((await call()).status).toBe(500);
    expect(JSON.stringify(log.mock.calls)).not.toContain("Fix launcher");
    log.mockRestore();
  });

  it("함수가 모르는 모양을 돌려주면 500이다 (조용히 성공으로 보이지 않는다)", async () => {
    open();
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.rpc.mockResolvedValueOnce({ data: { status: "ok", kept: -1, removed: 0 }, error: null });
    expect((await call()).status).toBe(500);
    log.mockRestore();
  });
});
