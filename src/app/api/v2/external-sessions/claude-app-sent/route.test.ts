import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), insert: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { POST } from "./route";

// 보내기 결과 지표 claude_app_message_sent (OA PR-D3s, 계약 25.3 · 25.6): 글 0, **저장 플래그와 무관**. 저장이 켜져 있으면 received는 save_claude_app_chat이 남기므로
// 이 route는 남기지 않는다(두 번 세지 않는다). not_sent는 늘 여기서 남긴다. 사용자 id는 인증에서만 온다.
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const call = (body: unknown) =>
  POST(new Request("https://api.example.dev/api/v2/external-sessions/claude-app-sent", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

function base(extra: Record<string, string> = {}) {
  for (const [key, value] of Object.entries({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", AGENT_BETA_USER_IDS: USER, ...extra })) vi.stubEnv(key, value);
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.insert.mockResolvedValue({ error: null });
  mocks.admin.mockReturnValue({ from: (table: string) => ({ insert: (row: unknown) => mocks.insert(table, row) }) });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("POST /api/v2/external-sessions/claude-app-sent", () => {
  it("대화 v2 · adapter 플래그가 꺼져 있으면 404: 인증 · DB 0", async () => {
    expect((await call({ result: "received" })).status).toBe(404);
    base();
    vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "false");
    expect((await call({ result: "received" })).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("베타 명단 밖은 404 · 로그인하지 않았으면 401 (저장 0)", async () => {
    base();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call({ result: "received" })).status).toBe(404);
    mocks.auth.mockResolvedValue(null);
    expect((await call({ result: "received" })).status).toBe(401);
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("저장 플래그(CLAUDE_APP_CHATS_ENABLED)가 꺼져 있어도 열린다: 인증된 사용자 id와 결과 코드만으로 서버 권한 insert, 204", async () => {
    base();
    const response = await call({ result: "received" });
    expect(response.status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type: "claude_app_message_sent", props: { result: "received" } });
    mocks.insert.mockClear();
    expect((await call({ result: "not_sent", reason: "bypass" })).status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type: "claude_app_message_sent", props: { result: "not_sent", reason: "bypass" } });
  });

  it("저장 플래그가 켜져 있으면 received는 남기지 않는다 (204), not_sent는 남긴다", async () => {
    base({ CLAUDE_APP_CHATS_ENABLED: "true" });
    expect((await call({ result: "received" })).status).toBe(204);
    expect(mocks.insert).not.toHaveBeenCalled();
    expect((await call({ result: "not_sent", reason: "session_closed" })).status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type: "claude_app_message_sent", props: { result: "not_sent", reason: "session_closed" } });
  });

  it("본문이 사용자 id · 글 · 제목 칸을 실어도 받지 않는다 (strict 400)", async () => {
    base();
    for (const extra of [{ user_id: OTHER }, { body: "보낸 글" }, { title: "세션 제목" }]) expect((await call({ result: "received", ...extra })).status).toBe(400);
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("저장 오류는 500", async () => {
    base();
    vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.insert.mockResolvedValue({ error: { code: "XX000" } });
    expect((await call({ result: "not_sent" })).status).toBe(500);
  });
});
