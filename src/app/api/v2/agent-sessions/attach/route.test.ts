import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { fakeAdmin } from "@/lib/agents/fake-admin";
import { realAttachDeps } from "@/lib/api/agent-conversations";

const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { POST } from "./route";

// 외부 세션 이어받기 route (OA 외부 세션 PR2s, ES-16 · ES-17): 플래그 · 명단 · registry grade가 모두 맞을 때만 열리고,
// 사용자 id는 인증에서만 온다. 저장은 SQL 함수 attach_agent_session 하나.
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const EXTERNAL = "5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e";
const WORKSPACE = "/taskforce/ws_0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const CONVERSATION = "c0000000-0000-4000-8000-000000000001";
const CONNECTION = "c1000000-0000-4000-8000-000000000001";
const BODY = { bridge_id: BRIDGE, adapter: "agent:claude-code", external_session_id: EXTERNAL, workspace_ref: WORKSPACE };
const call = (body: unknown = BODY) =>
  POST(new Request("https://api.example.dev/api/v2/agent-sessions/attach", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

const sessionRow = { id: SESSION, user_id: USER, connection_id: CONNECTION, display_name: "", status: "bound", last_turn_seq: 0, updated_at: "2026-10-21T14:00:00Z" };
const FLAGS = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ATTACH_EXISTING_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" };
function open(extra: Record<string, string> = {}) {
  for (const [key, value] of Object.entries({ ...FLAGS, AGENT_BETA_USER_IDS: USER, ...extra })) vi.stubEnv(key, value);
}

/** SQL 함수처럼 같은 (사용자, Claude id)를 한 번만 만든다: 동시에 와도 하나는 created, 나머지는 existing */
function statefulFake() {
  const sessions = new Map<string, string>();
  let functionCalls = 0;
  const fake = fakeAdmin({
    tables: { agent_sessions: [sessionRow] },
    rpc: {
      attach_agent_session: (args) => {
        functionCalls += 1;
        const key = `${args.p_user_id}:${args.p_external_session_id}`;
        const existing = sessions.has(key);
        sessions.set(key, SESSION);
        return { status: existing ? "existing" : "created", session_id: SESSION, conversation_id: CONVERSATION };
      },
    },
  });
  return { fake, sessions, calls: () => functionCalls };
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("POST /api/v2/agent-sessions/attach: 문", () => {
  it("플래그가 모두 꺼져 있으면 403: 인증 · DB 0", async () => {
    expect((await call()).status).toBe(403);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each(["CONVERSATIONS_V2_ENABLED", "AGENT_ATTACH_EXISTING_ENABLED"])("%s 하나만 꺼져도 403 (인증 · DB 0)", async (flag) => {
    open();
    vi.stubEnv(flag, "false");
    expect((await call()).status).toBe(403);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it.each(["false", "TRUE", "True", "1", " true", "true\n", "yes", ""])("AGENT_ATTACH_EXISTING_ENABLED가 %j이면 꺼진 것이다 (정확히 \"true\"만 켠다)", async (value) => {
    open({ AGENT_ATTACH_EXISTING_ENABLED: value });
    expect((await call()).status).toBe(403);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("다른 gate는 이 gate를 켜지 않는다 (EXTERNAL_SESSIONS_REPORT_ENABLED · adapter gate · 베타 명단만으로는 403)", async () => {
    for (const [key, value] of Object.entries({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", EXTERNAL_SESSIONS_REPORT_ENABLED: "true", AGENT_BETA_USER_IDS: USER })) vi.stubEnv(key, value);
    expect((await call()).status).toBe(403);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("adapter gate(AGENT_ADAPTER_CLAUDE_CODE_ENABLED)가 꺼져 있으면 403: DB 0", async () => {
    open({ AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "false" });
    expect((await call()).status).toBe(403);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("베타 명단 밖 사용자 · 명단이 없는 배포는 403: DB 0", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call()).status).toBe(403);
    vi.stubEnv("AGENT_BETA_USER_IDS", "");
    mocks.auth.mockResolvedValue({ user: { id: USER } });
    expect((await call()).status).toBe(403);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("registry가 attach_existing false인 adapter(Codex)는 gate가 모두 켜져 있어도 403: DB 0", async () => {
    open({ AGENT_ADAPTER_CODEX_ENABLED: "true" });
    const response = await call({ ...BODY, adapter: "agent:codex" });
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: { code: "forbidden" } });
    expect(mocks.admin).not.toHaveBeenCalled();
    // registry 밖 adapter도 같다
    expect((await call({ ...BODY, adapter: "agent:cursor" })).status).toBe(403);
    expect(mocks.admin).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401: DB 0", async () => {
    open();
    mocks.auth.mockResolvedValue(null);
    expect((await call()).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
  });
});

describe("POST /api/v2/agent-sessions/attach: 본문", () => {
  it.each([
    ["대문자 UUID", { ...BODY, external_session_id: EXTERNAL.toUpperCase() }],
    ["pending 접두", { ...BODY, external_session_id: `pending:${EXTERNAL}` }],
    ["경로 모양 workspace_ref", { ...BODY, workspace_ref: "/Users/daniel/Documents/project" }],
    ["사용자 id를 싣는다", { ...BODY, user_id: OTHER }],
    ["bridge가 uuid 아님", { ...BODY, bridge_id: "mine" }],
  ])("%s → 400: DB 0", async (_name, body) => {
    open();
    const response = await call(body);
    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: { code: "invalid_request" } });
    expect(mocks.admin).not.toHaveBeenCalled();
  });
});

describe("POST /api/v2/agent-sessions/attach: 이어받기", () => {
  it("created → 201 { status, conversation_id, session }. 함수는 인증된 사용자 id와 받은 칸 그대로 한 번 부른다", async () => {
    open();
    const { fake } = statefulFake();
    mocks.admin.mockReturnValue(fake.admin);
    const response = await call();
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({
      status: "created",
      conversation_id: CONVERSATION,
      session: { id: SESSION, connection_id: CONNECTION, display_name: "", status: "bound", last_turn_seq: 0, updated_at: "2026-10-21T14:00:00.000Z" },
    });
    expect(fake.rpcCalls("attach_agent_session")).toHaveLength(1);
    expect(fake.rpcCalls("attach_agent_session")[0].args).toEqual({
      p_user_id: USER, p_bridge_id: BRIDGE, p_adapter: "agent:claude-code", p_external_session_id: EXTERNAL, p_workspace_ref: WORKSPACE,
    });
    expect(fake.calls.filter((c) => ["insert", "update", "upsert"].includes(c.kind))).toEqual([]);
  });

  it("사용자 id는 본문이 아니라 인증에서만 온다 (다른 사용자로 인증하면 그 id로 부른다)", async () => {
    open({ AGENT_BETA_USER_IDS: `${USER},${OTHER}` });
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    const { fake } = statefulFake();
    mocks.admin.mockReturnValue(fake.admin);
    await call();
    expect(fake.rpcCalls("attach_agent_session")[0].args).toMatchObject({ p_user_id: OTHER });
  });

  it("검증을 건너뛴 입력에 user_id가 실려 있어도 저장 함수는 인증된 사용자 id로만 부른다 (strict와 겹친 방어)", async () => {
    open();
    const { fake } = statefulFake();
    mocks.admin.mockReturnValue(fake.admin);
    await realAttachDeps().attach({ user: { id: USER } } as never, { ...BODY, user_id: OTHER } as never);
    expect(fake.rpcCalls("attach_agent_session")[0].args).toMatchObject({ p_user_id: USER });
    expect(JSON.stringify(fake.rpcCalls("attach_agent_session")[0].args)).not.toContain(OTHER);
  });

  it("같은 요청 두 번 → 201 다음 200 (existing), 세션 하나", async () => {
    open();
    const state = statefulFake();
    mocks.admin.mockReturnValue(state.fake.admin);
    const first = await call();
    const second = await call();
    expect([first.status, second.status]).toEqual([201, 200]);
    expect((await first.json()).status).toBe("created");
    expect((await second.json()).status).toBe("existing");
    expect(state.sessions.size).toBe(1);
  });

  it("동시에 온 두 요청 → 함수를 한 번씩 부르고, 응답은 created 하나 + existing 하나, 세션 하나", async () => {
    open();
    const state = statefulFake();
    mocks.admin.mockReturnValue(state.fake.admin);
    const responses = await Promise.all([call(), call()]);
    expect(responses.map((r) => r.status).sort()).toEqual([200, 201]);
    expect(state.calls()).toBe(2);
    expect(state.sessions.size).toBe(1);
    const statuses = (await Promise.all(responses.map((r) => r.json()))).map((body) => body.status).sort();
    expect(statuses).toEqual(["created", "existing"]);
  });

  it("없는 · 남의 · 해제된 bridge는 404, 다른 연결에 이미 이어받은 id는 409 session_in_use", async () => {
    open();
    mocks.admin.mockReturnValue(fakeAdmin({ rpc: { attach_agent_session: () => ({ status: "not_found" }) } }).admin);
    expect((await call()).status).toBe(404);
    mocks.admin.mockReturnValue(fakeAdmin({ rpc: { attach_agent_session: () => ({ status: "session_in_use" }) } }).admin);
    const response = await call();
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: { code: "session_in_use" } });
  });

  it("함수 오류는 500이고 로그에 id · 가상 루트가 없다", async () => {
    open();
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    mocks.admin.mockReturnValue(fakeAdmin({ rpc: { attach_agent_session: () => { throw Object.assign(new Error(`${EXTERNAL} ${WORKSPACE}`), { code: "XX000" }); } } }).admin);
    expect((await call()).status).toBe(500);
    const logged = JSON.stringify([error.mock.calls, info.mock.calls]);
    for (const secret of [EXTERNAL, WORKSPACE, BRIDGE, USER]) expect(logged).not.toContain(secret);
  });
});
