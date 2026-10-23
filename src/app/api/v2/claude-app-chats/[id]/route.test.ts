import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), rpc: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { DELETE } from "./route";

// 저장된 대화 지우기 (OA PR-D3s, 계약 25.3): 사용자 id는 인증에서만 온다. 남의 · 없는 id는 404. 지표 claude_app_chat_deleted는 SQL 함수가 같은 트랜잭션에서 남긴다.
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const CHAT = "c0c0c0c0-0000-4000-8000-000000000001";
const call = (id: string = CHAT) => DELETE(new Request(`https://api.example.dev/api/v2/claude-app-chats/${id}`, { method: "DELETE" }), { params: Promise.resolve({ id }) });
const FLAGS = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", CLAUDE_APP_CHATS_ENABLED: "true" };
function open(extra: Record<string, string> = {}) {
  for (const [key, value] of Object.entries({ ...FLAGS, AGENT_BETA_USER_IDS: USER, ...extra })) vi.stubEnv(key, value);
}
const rpcReturns = (data: unknown) => mocks.rpc.mockImplementation(() => ({ throwOnError: () => Promise.resolve({ data, error: null }) }));

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  rpcReturns({ status: "deleted" });
  mocks.admin.mockReturnValue({ rpc: mocks.rpc });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

// 저장된 데이터를 지우는 길은 늘 열려 있다 (BYOK 키 DELETE와 같다): CLAUDE_APP_CHATS_ENABLED · 대화 v2 · adapter 플래그와 베타 명단을 보지 않는다.
// 그래도 로그인(Bearer · 쿠키 + CSRF)이 필요하고 자기 행만 지운다.
describe("DELETE /api/v2/claude-app-chats/{id}: 늘 열려 있다", () => {
  it("플래그가 모두 꺼져 있고 베타 명단이 없어도 지운다 (204)", async () => {
    const response = await call();
    expect(response.status).toBe(204);
    expect(mocks.auth).toHaveBeenCalledTimes(1);
    expect(mocks.rpc.mock.calls).toEqual([["delete_claude_app_chat", { p_user_id: USER, p_chat_id: CHAT }]]);
  });

  it.each(Object.keys(FLAGS))("%s 하나만 꺼져도 지운다 (나머지는 켜짐)", async (flag) => {
    open();
    vi.stubEnv(flag, "false");
    expect((await call()).status).toBe(204);
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
  });

  it("명단 밖 사용자 · 명단이 비어 있는 배포도 자기 대화를 지운다", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call()).status).toBe(204);
    expect(mocks.rpc.mock.calls[0]).toEqual(["delete_claude_app_chat", { p_user_id: OTHER, p_chat_id: CHAT }]);
    vi.stubEnv("AGENT_BETA_USER_IDS", "");
    expect((await call()).status).toBe(204);
  });

  it("로그인하지 않았으면 401이고 DB를 부르지 않는다 (플래그가 켜져 있어도 꺼져 있어도)", async () => {
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    open();
    expect((await call()).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("지우면 204 + Cache-Control no-store: delete_claude_app_chat(인증된 사용자 id, 채팅 id)만 부른다", async () => {
    open();
    const response = await call();
    expect(response.status).toBe(204);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).toBe("");
    expect(mocks.rpc.mock.calls).toEqual([["delete_claude_app_chat", { p_user_id: USER, p_chat_id: CHAT }]]);
  });

  it("없는 · 남의 id는 404", async () => {
    open();
    rpcReturns({ status: "not_found" });
    expect((await call()).status).toBe(404);
  });

  it("uuid가 아닌 id는 404이고 DB를 부르지 않는다 (플래그가 꺼져 있어도 같다)", async () => {
    for (const id of ["nope", "status", "c0c0c0c0", `${CHAT}0`]) expect((await call(id)).status, id).toBe(404);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("함수가 모르는 모양을 돌려주면 500", async () => {
    open();
    vi.spyOn(console, "error").mockImplementation(() => {});
    rpcReturns({ status: "deleted", extra: 1 });
    expect((await call()).status).toBe(500);
  });
});
