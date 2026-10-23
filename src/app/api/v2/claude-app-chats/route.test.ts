import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), rpc: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { DELETE, PUT } from "./route";

// Claude 데스크톱 대화 저장 route (OA PR-D3s, 계약 25.3): 세 플래그(대화 v2 · Claude Code adapter · CLAUDE_APP_CHATS_ENABLED) + 베타 명단이 모두 맞을 때만 열리고,
// 사용자 id는 인증에서만 온다. 속도 제한(claude_app_chat) 뒤 SQL 함수 save_claude_app_chat 하나가 쓴다.
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const CHAT = "c0c0c0c0-0000-4000-8000-000000000001";
const ref = (n: number) => n.toString(16).padStart(64, "0");
const MESSAGES = [
  { mac_ref: ref(1), role: "user", body: "보낸 글", truncated: false, said_at: "2026-10-22T09:00:00Z" },
  { mac_ref: ref(2), role: "assistant", reply_to_ref: ref(1), body: "답 글", truncated: false, said_at: "2026-10-22T09:00:05Z", tool_names: ["Read", "Edit"] },
];
const BODY = { bridge_id: BRIDGE, session_ref: ref(900), title: "세션 제목", messages: MESSAGES };
const call = (body: unknown = BODY) => PUT(new Request("https://api.example.dev/api/v2/claude-app-chats", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

const FLAGS = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", CLAUDE_APP_CHATS_ENABLED: "true" };
function open(extra: Record<string, string> = {}) {
  for (const [key, value] of Object.entries({ ...FLAGS, AGENT_BETA_USER_IDS: USER, ...extra })) vi.stubEnv(key, value);
}

/** rpc 이름별 응답. take_rate_limit은 기본 통과(null) */
function rpcReturns(map: Record<string, unknown>) {
  mocks.rpc.mockImplementation((name: string) => ({ throwOnError: () => Promise.resolve({ data: name in map ? map[name] : null, error: null }) }));
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  rpcReturns({ save_claude_app_chat: { status: "ok", chat_id: CHAT, saved: 2, existing: 0, orphan: 0 } });
  mocks.admin.mockReturnValue({ rpc: mocks.rpc });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("PUT /api/v2/claude-app-chats: 문", () => {
  it("플래그가 모두 꺼져 있으면 404: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each(Object.keys(FLAGS))("%s 하나만 꺼져도 404 (인증 · DB 0)", async (flag) => {
    open();
    vi.stubEnv(flag, "false");
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each(["TRUE", "True", "1", " true", "true\n", "yes", ""])("CLAUDE_APP_CHATS_ENABLED가 %j이면 꺼진 것이다 (정확히 \"true\"만 켠다)", async (value) => {
    open({ CLAUDE_APP_CHATS_ENABLED: value });
    expect((await call()).status).toBe(404);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("다른 gate는 이 gate를 켜지 않는다 (EXTERNAL_SESSIONS_REPORT_ENABLED · AGENT_ATTACH_EXISTING_ENABLED · 베타 명단만으로는 404)", async () => {
    for (const [key, value] of Object.entries({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", EXTERNAL_SESSIONS_REPORT_ENABLED: "true", AGENT_ATTACH_EXISTING_ENABLED: "true", AGENT_BETA_USER_IDS: USER })) vi.stubEnv(key, value);
    expect((await call()).status).toBe(404);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("베타 명단 밖 사용자 · 명단이 없는 배포는 404, 로그인하지 않았으면 401: DB 0", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call()).status).toBe(404);
    vi.stubEnv("AGENT_BETA_USER_IDS", "");
    mocks.auth.mockResolvedValue({ user: { id: USER } });
    expect((await call()).status).toBe(404);
    open();
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
  });
});

describe("PUT /api/v2/claude-app-chats: 저장", () => {
  it("속도 제한(claude_app_chat 10분 120번 → claude_app_chat_day 하루 1,000번) 뒤 save_claude_app_chat을 부른다. 사용자 id는 인증에서 온 값이다", async () => {
    open();
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ chat_id: CHAT, saved: 2, existing: 0, orphan: 0 });
    expect(mocks.rpc.mock.calls).toEqual([
      ["take_rate_limit", { p_user_id: USER, p_kind: "claude_app_chat", p_max: 120, p_window_seconds: 600 }],
      ["take_rate_limit", { p_user_id: USER, p_kind: "claude_app_chat_day", p_max: 1000, p_window_seconds: 86_400 }],
      ["save_claude_app_chat", { p_user_id: USER, p_bridge_id: BRIDGE, p_session_ref: ref(900), p_title: "세션 제목", p_keep_title: false, p_messages: MESSAGES }],
    ]);
  });

  it("title: 생략하면 저장된 제목을 그대로 둔다(p_keep_title true, p_title null), 명시한 null이면 지운다(false + null), 문자열이면 바꾼다(false + 값)", async () => {
    open();
    const { title: _title, ...noTitle } = BODY;
    void _title;
    const saves = () => mocks.rpc.mock.calls.filter((c) => c[0] === "save_claude_app_chat").map((c) => c[1]);
    expect((await call(noTitle)).status).toBe(200);
    expect((await call({ ...BODY, title: null })).status).toBe(200);
    expect((await call({ ...BODY, title: "새 제목" })).status).toBe(200);
    expect(saves()).toMatchObject([
      { p_title: null, p_keep_title: true },
      { p_title: null, p_keep_title: false },
      { p_title: "새 제목", p_keep_title: false },
    ]);
  });

  it("본문이 사용자 id를 실어도 받지 않는다 (strict 400): 남의 이름으로 저장하지 못한다", async () => {
    open();
    expect((await call({ ...BODY, user_id: OTHER })).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("없는 · 남의 · 해제된 bridge는 404 **bridge_not_found** (gate 꺼짐의 404 not_found와 코드가 다르다: Mac이 둘을 헷갈리지 않는다)", async () => {
    open();
    rpcReturns({ save_claude_app_chat: { status: "not_found" } });
    const response = await call();
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "bridge_not_found" } });
    // 같은 요청이 gate가 꺼져 있을 때는 not_found
    vi.unstubAllEnvs();
    const gateOff = await call();
    expect(gateOff.status).toBe(404);
    expect(await gateOff.json()).toMatchObject({ error: { code: "not_found" } });
  });

  it("사용자별 한도를 넘기면 413 quota_exceeded: 응답에 요청 값이 없다", async () => {
    open();
    rpcReturns({ save_claude_app_chat: { status: "quota_exceeded" } });
    const response = await call();
    expect(response.status).toBe(413);
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({ error: { code: "quota_exceeded" } });
    expect(text).not.toMatch(/보낸 글|답 글|세션 제목|b0b0b0b0/);
  });

  it("DB가 22023(인자 모양)을 던지면 400 invalid_request (500 아님)", async () => {
    open();
    vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.rpc.mockImplementation((name: string) => ({
      throwOnError: () => (name === "take_rate_limit" ? Promise.resolve({ data: null, error: null }) : Promise.reject(Object.assign(new Error("save_claude_app_chat: invalid message"), { code: "22023" }))),
    }));
    const response = await call();
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "invalid_request" } });
  });

  it("10분 한도에 찼으면 429 + Retry-After, 하루 한도도 저장 함수도 부르지 않는다", async () => {
    open();
    rpcReturns({ take_rate_limit: new Date(Date.now() + 120_000).toISOString() });
    const response = await call();
    expect(response.status).toBe(429);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThanOrEqual(119);
    expect(mocks.rpc.mock.calls.map((c) => c[0])).toEqual(["take_rate_limit"]);
  });

  it("하루 한도에 찼으면 429 + Retry-After, 저장 함수는 부르지 않는다", async () => {
    open();
    const dayFull = new Date(Date.now() + 5 * 3600_000).toISOString();
    mocks.rpc.mockImplementation((name: string, args: { p_kind?: string }) => ({
      throwOnError: () => Promise.resolve({ data: name === "take_rate_limit" && args.p_kind === "claude_app_chat_day" ? dayFull : null, error: null }),
    }));
    const response = await call();
    expect(response.status).toBe(429);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThanOrEqual(5 * 3600 - 2);
    expect(mocks.rpc.mock.calls.map((c) => (c[1] as { p_kind?: string }).p_kind ?? c[0])).toEqual(["claude_app_chat", "claude_app_chat_day"]);
  });

  it("잘못된 본문은 속도 제한도 쓰지 않는다 (400, rpc 0)", async () => {
    open();
    expect((await call({ ...BODY, messages: [] })).status).toBe(400);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("함수가 모르는 모양을 돌려주면 500이다 (계약 밖 값을 응답에 싣지 않는다)", async () => {
    open();
    vi.spyOn(console, "error").mockImplementation(() => {});
    rpcReturns({ save_claude_app_chat: { status: "ok", chat_id: CHAT, saved: 1, existing: 0, orphan: 0, body: "보낸 글" } });
    const response = await call();
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("보낸 글");
  });

  it("저장 오류는 500이고 로그에 글 · 제목이 없다", async () => {
    open();
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.rpc.mockImplementation((name: string) => ({
      throwOnError: () => (name === "take_rate_limit" ? Promise.resolve({ data: null, error: null }) : Promise.reject(Object.assign(new Error("보낸 글 세션 제목 /Users/me"), { code: "XX000" }))),
    }));
    expect((await call()).status).toBe(500);
    expect(JSON.stringify(error.mock.calls)).not.toMatch(/보낸 글|세션 제목|\/Users|답 글/);
  });
});

// ───────────────────────── DELETE (모두 지우기, OA D3v-s, 계약 27장) ─────────────────────────
// 대화마다 지우는 DELETE([id]/route.ts)와 같다: 늘 열려 있다(세 플래그도 베타 명단도 보지 않는다). 로그인(Bearer · 쿠키 + CSRF)이 필요하고 자기 행만 지운다.
// 속도 제한(claude_app_chat_delete_all, 사용자별 10분에 5번) 뒤 SQL 함수 delete_all_claude_app_chats 하나가 한 트랜잭션으로 지운다.
const callAll = (init: RequestInit = {}) => DELETE(new Request("https://api.example.dev/api/v2/claude-app-chats", { method: "DELETE", ...init }));
const rpcCalls = () => mocks.rpc.mock.calls.map((c) => [c[0], c[1]]);

describe("DELETE /api/v2/claude-app-chats (모두 지우기)", () => {
  beforeEach(() => rpcReturns({ delete_all_claude_app_chats: { deleted: 4 } }));

  it("플래그가 모두 꺼져 있고 베타 명단이 없어도 지운다: 속도 제한(claude_app_chat_delete_all 10분 5번) 뒤 delete_all_claude_app_chats(인증된 사용자 id)만 부른다", async () => {
    const response = await callAll();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ deleted: 4 });
    expect(mocks.auth).toHaveBeenCalledTimes(1);
    expect(rpcCalls()).toEqual([
      ["take_rate_limit", { p_user_id: USER, p_kind: "claude_app_chat_delete_all", p_max: 5, p_window_seconds: 600 }],
      ["delete_all_claude_app_chats", { p_user_id: USER }],
    ]);
  });

  it.each(Object.keys(FLAGS))("%s 하나만 꺼져도 지운다 (나머지는 켜짐)", async (flag) => {
    open();
    vi.stubEnv(flag, "false");
    expect((await callAll()).status).toBe(200);
    expect(rpcCalls().map((c) => c[0])).toEqual(["take_rate_limit", "delete_all_claude_app_chats"]);
  });

  it("명단 밖 사용자 · 명단이 비어 있는 배포도 자기 대화를 지운다", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await callAll()).status).toBe(200);
    expect(rpcCalls().at(-1)).toEqual(["delete_all_claude_app_chats", { p_user_id: OTHER }]);
    vi.stubEnv("AGENT_BETA_USER_IDS", "");
    expect((await callAll()).status).toBe(200);
  });

  it("로그인하지 않았으면 401이고 DB를 부르지 않는다 (플래그가 켜져 있어도 꺼져 있어도)", async () => {
    mocks.auth.mockResolvedValue(null);
    expect((await callAll()).status).toBe(401);
    open();
    expect((await callAll()).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("본문 · 쿼리의 사용자 id는 받지 않는다: 지우는 것은 인증된 사용자의 채팅뿐이다", async () => {
    const response = await DELETE(
      new Request(`https://api.example.dev/api/v2/claude-app-chats?user_id=${OTHER}`, { method: "DELETE", headers: { "content-type": "application/json" }, body: JSON.stringify({ user_id: OTHER, p_user_id: OTHER }) }),
    );
    expect(response.status).toBe(200);
    expect(rpcCalls().map((c) => c[1])).toEqual([{ p_user_id: USER, p_kind: "claude_app_chat_delete_all", p_max: 5, p_window_seconds: 600 }, { p_user_id: USER }]);
  });

  it("지울 것이 없으면 200 { deleted: 0 }", async () => {
    rpcReturns({ delete_all_claude_app_chats: { deleted: 0 } });
    const response = await callAll();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ deleted: 0 });
  });

  it("속도 제한에 찼으면 429 + Retry-After이고 지우는 함수는 부르지 않는다. 저장 종류(claude_app_chat · claude_app_chat_day)는 세지 않는다", async () => {
    rpcReturns({ take_rate_limit: new Date(Date.now() + 90_000).toISOString() });
    const response = await callAll();
    expect(response.status).toBe(429);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThanOrEqual(89);
    expect(await response.json()).toMatchObject({ error: { code: "rate_limited" } });
    expect(rpcCalls().map((c) => c[0])).toEqual(["take_rate_limit"]);
    expect(rpcCalls().map((c) => (c[1] as { p_kind?: string }).p_kind)).toEqual(["claude_app_chat_delete_all"]);
  });

  it("함수가 모르는 모양 · 계약 밖 숫자를 돌려주면 500이다 (응답에 싣지 않는다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    for (const bad of [{ deleted: 4, extra: 1 }, { deleted: -1 }, { deleted: 1.5 }, { status: "deleted" }, null]) {
      rpcReturns({ delete_all_claude_app_chats: bad });
      expect((await callAll()).status, JSON.stringify(bad)).toBe(500);
    }
  });

  it("잠금 경합은 409 busy_retry (같은 호출을 세 번까지 다시 한 뒤), 그 밖의 오류는 500이고 로그에 오류 이름과 코드뿐이다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const failWith = (code: string) =>
      mocks.rpc.mockImplementation((name: string) => ({
        throwOnError: () => (name === "delete_all_claude_app_chats" ? Promise.reject(Object.assign(new Error(`내 비밀 글 ${USER}`), { code })) : Promise.resolve({ data: null, error: null })),
      }));
    failWith("40001");
    expect((await callAll()).status).toBe(409);
    expect(mocks.rpc.mock.calls.filter((c) => c[0] === "delete_all_claude_app_chats")).toHaveLength(3);
    mocks.rpc.mockClear();
    failWith("XX000");
    expect((await callAll()).status).toBe(500);
    expect(mocks.rpc.mock.calls.filter((c) => c[0] === "delete_all_claude_app_chats")).toHaveLength(1);
    expect(JSON.stringify(error.mock.calls)).not.toMatch(/비밀|11111111/);
    expect(JSON.stringify(error.mock.calls)).toContain("claude_app_chats_delete_all_failed");
  });
});
