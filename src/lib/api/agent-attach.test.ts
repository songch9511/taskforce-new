import { afterEach, describe, expect, it, vi } from "vitest";

import { handleAttachSession, type AttachSessionDeps } from "./agent-conversations";
import { agentAttachErrorCodeSchema, apiErrorV2AgentCodeSchema, attachAgentSessionRequestSchema, attachAgentSessionResponseSchema } from "./contract";
import type { AttachAgentSessionResult } from "@/lib/agents/sessions";

vi.mock("server-only", () => ({}));

// 외부 세션 이어받기 route 처리 (OA 외부 세션 PR2s, ES-17): gate 403 → 인증 401 → 명단 403 → 본문 400 → grade 403 → 저장.
// 사용자 id는 인증에서만 온다. 로그에는 결과 코드뿐 (id · 경로 · 가상 루트 없음).
const USER = "11111111-0000-4000-8000-000000000001";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const EXTERNAL = "5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e";
const WORKSPACE = "/taskforce/ws_0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const CONVERSATION = "c0000000-0000-4000-8000-000000000001";
const CONNECTION = "c1000000-0000-4000-8000-000000000001";
const BODY = { bridge_id: BRIDGE, adapter: "agent:claude-code", external_session_id: EXTERNAL, workspace_ref: WORKSPACE };

const session = { id: SESSION, connection_id: CONNECTION, display_name: "", status: "bound" as const, last_turn_seq: 0, updated_at: "2026-10-21T14:00:00.000Z" };
const created: AttachAgentSessionResult = { status: "created", conversationId: CONVERSATION, session };

function deps(over: Partial<AttachSessionDeps<{ user: { id: string } }>> = {}) {
  const attach = vi.fn<AttachSessionDeps<{ user: { id: string } }>["attach"]>(async () => created);
  const authenticate = vi.fn(async () => ({ user: { id: USER } }));
  const value: AttachSessionDeps<{ user: { id: string } }> = { enabled: () => true, authenticate, betaAllowed: () => true, adapterAllowed: () => true, attach, ...over };
  return { value, attach, authenticate };
}
const post = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://api.example.dev/api/v2/agent-sessions/attach", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) });

afterEach(() => vi.restoreAllMocks());

describe("attachAgentSessionRequestSchema", () => {
  it("정규 소문자 UUID와 가상 루트만 받는다 (strict)", () => {
    expect(attachAgentSessionRequestSchema.parse(BODY)).toEqual(BODY);
  });

  it.each([
    ["대문자 UUID", { external_session_id: EXTERNAL.toUpperCase() }],
    ["중괄호", { external_session_id: `{${EXTERNAL}}` }],
    ["하이픈 없음", { external_session_id: EXTERNAL.replaceAll("-", "") }],
    ["pending 접두", { external_session_id: `pending:${EXTERNAL}` }],
    ["절대 경로 .jsonl", { external_session_id: "/tmp/a.jsonl" }],
    ["옵션 모양", { external_session_id: "--resume" }],
    ["공백", { external_session_id: ` ${EXTERNAL}` }],
    ["뒤 개행", { external_session_id: `${EXTERNAL}\n` }],
    ["빈 글", { external_session_id: "" }],
    ["숫자", { external_session_id: 5 }],
    ["실제 경로", { workspace_ref: "/Users/daniel/Documents/project" }],
    ["홈 경로", { workspace_ref: "~/project" }],
    ["ws_id 대문자", { workspace_ref: WORKSPACE.toUpperCase().replace("/TASKFORCE/WS_", "/taskforce/ws_") }],
    ["하위 경로", { workspace_ref: `${WORKSPACE}/src` }],
    ["뒤 슬래시", { workspace_ref: `${WORKSPACE}/` }],
    ["ws_ 없음", { workspace_ref: `/taskforce/${EXTERNAL}` }],
    ["고정 자리", { workspace_ref: "/taskforce/ws_unregistered" }],
    ["뒤 개행", { workspace_ref: `${WORKSPACE}\n` }],
    ["bridge가 uuid 아님", { bridge_id: "bridge-1" }],
    ["adapter 모양 아님", { adapter: "claude-code" }],
    ["adapter 대문자", { adapter: "agent:Claude" }],
    ["사용자 id를 싣는다 (strict)", { user_id: USER }],
    ["연결 id를 싣는다 (strict)", { connection_id: CONNECTION }],
    ["제목을 싣는다 (strict)", { title: "Fix launcher focus" }],
  ])("거절: %s", (_name, over) => {
    expect(attachAgentSessionRequestSchema.safeParse({ ...BODY, ...over }).success).toBe(false);
  });

  it("칸이 빠지면 거절한다", () => {
    for (const key of Object.keys(BODY)) {
      const rest = Object.fromEntries(Object.entries(BODY).filter(([name]) => name !== key));
      expect(attachAgentSessionRequestSchema.safeParse(rest).success, key).toBe(false);
    }
  });
});

describe("attachAgentSessionResponseSchema · 오류 코드", () => {
  it("{ status, conversation_id, session }만 (strict)", () => {
    const response = { status: "created", conversation_id: CONVERSATION, session };
    expect(attachAgentSessionResponseSchema.parse(response)).toEqual(response);
    expect(attachAgentSessionResponseSchema.parse({ ...response, status: "existing" }).status).toBe("existing");
    expect(attachAgentSessionResponseSchema.safeParse({ ...response, status: "attached" }).success).toBe(false);
    expect(attachAgentSessionResponseSchema.safeParse({ ...response, extra: 1 }).success).toBe(false);
  });

  it("session_in_use · forbidden은 v2 에이전트 오류 코드에 든다", () => {
    expect(agentAttachErrorCodeSchema.options).toEqual(["session_in_use", "forbidden"]);
    for (const code of agentAttachErrorCodeSchema.options) expect(apiErrorV2AgentCodeSchema.options).toContain(code);
  });
});

describe("handleAttachSession", () => {
  it("gate가 꺼져 있으면 403 forbidden: 인증 · 저장 0", async () => {
    const d = deps({ enabled: () => false });
    const response = await handleAttachSession(post(BODY), d.value);
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: { code: "forbidden" } });
    expect(d.authenticate).not.toHaveBeenCalled();
    expect(d.attach).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401 (저장 0)", async () => {
    const d = deps({ authenticate: async () => null });
    expect((await handleAttachSession(post(BODY), d.value)).status).toBe(401);
    expect(d.attach).not.toHaveBeenCalled();
  });

  it("베타 명단 밖 사용자는 403: 본문을 보기 전에 막는다 (저장 0)", async () => {
    const d = deps({ betaAllowed: () => false });
    expect((await handleAttachSession(post(BODY), d.value)).status).toBe(403);
    expect((await handleAttachSession(post("not json"), d.value)).status).toBe(403);
    expect(d.attach).not.toHaveBeenCalled();
  });

  it("adapter가 이어받기를 허용하지 않으면 403 (본문은 올바른데도): 저장 0", async () => {
    const adapterAllowed = vi.fn(() => false);
    const d = deps({ adapterAllowed });
    const response = await handleAttachSession(post({ ...BODY, adapter: "agent:codex" }), d.value);
    expect(response.status).toBe(403);
    expect(adapterAllowed).toHaveBeenCalledExactlyOnceWith("agent:codex");
    expect(d.attach).not.toHaveBeenCalled();
  });

  it.each([
    ["JSON이 아님", "{not json"],
    ["빈 본문", ""],
    ["대문자 UUID", { ...BODY, external_session_id: EXTERNAL.toUpperCase() }],
    ["pending 접두", { ...BODY, external_session_id: `pending:${EXTERNAL}` }],
    ["경로 모양 workspace_ref", { ...BODY, workspace_ref: "/Users/daniel/Documents/project" }],
    ["사용자 id를 싣는다", { ...BODY, user_id: "22222222-0000-4000-8000-000000000002" }],
    ["칸 빠짐", { bridge_id: BRIDGE }],
  ])("잘못된 본문(%s)은 400이고 저장하지 않는다. 오류 글에 요청 값이 없다", async (_name, body) => {
    const d = deps();
    const response = await handleAttachSession(post(body), d.value);
    expect(response.status).toBe(400);
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({ error: { code: "invalid_request" } });
    for (const secret of [EXTERNAL, EXTERNAL.toUpperCase(), "/Users/daniel", "pending:", WORKSPACE, BRIDGE]) expect(text).not.toContain(secret);
    expect(d.attach).not.toHaveBeenCalled();
  });

  it("created → 201 { status, conversation_id, session }. 저장은 인증된 사용자 id와 검증한 칸으로만 부른다", async () => {
    const d = deps();
    const response = await handleAttachSession(post(BODY), d.value);
    expect(response.status).toBe(201);
    expect(attachAgentSessionResponseSchema.parse(await response.json())).toEqual({ status: "created", conversation_id: CONVERSATION, session });
    expect(d.attach).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, BODY);
  });

  it("existing → 200 같은 모양", async () => {
    const d = deps({ attach: async () => ({ status: "existing", conversationId: CONVERSATION, session }) });
    const response = await handleAttachSession(post(BODY), d.value);
    expect(response.status).toBe(200);
    expect(attachAgentSessionResponseSchema.parse(await response.json())).toMatchObject({ status: "existing", conversation_id: CONVERSATION });
  });

  it("없는 · 남의 · 해제된 bridge는 같은 404 (존재를 알리지 않는다)", async () => {
    const d = deps({ attach: async () => ({ status: "not_found" }) });
    const response = await handleAttachSession(post(BODY), d.value);
    expect(response.status).toBe(404);
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({ error: { code: "not_found" } });
    expect(text).not.toContain(BRIDGE);
  });

  it("다른 연결 · 닫힌 세션에 묶여 있으면 409 session_in_use", async () => {
    const d = deps({ attach: async () => ({ status: "session_in_use" }) });
    const response = await handleAttachSession(post(BODY), d.value);
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: { code: "session_in_use" } });
  });

  it("잠금 경합(55P03 · 40001 · 40P01)은 409 busy_retry, 그 밖의 오류는 500 (오류 이름 · 코드만 로그)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    for (const code of ["55P03", "40001", "40P01"]) {
      const d = deps({ attach: async () => { throw Object.assign(new Error(`${EXTERNAL} ${WORKSPACE}`), { code }); } });
      const response = await handleAttachSession(post(BODY), d.value);
      expect(response.status, code).toBe(409);
      expect(await response.json()).toMatchObject({ error: { code: "busy_retry" } });
    }
    const d = deps({ attach: async () => { throw Object.assign(new Error(`${EXTERNAL} ${WORKSPACE} ${BRIDGE}`), { code: "XX000" }); } });
    const response = await handleAttachSession(post(BODY), d.value);
    expect(response.status).toBe(500);
    const body = await response.text();
    expect(log).toHaveBeenCalledTimes(1);
    const logged = JSON.stringify(log.mock.calls);
    expect(JSON.parse(String(log.mock.calls[0][0]))).toEqual({ event: "agent_session_attach_failed", error: "Error", code: "XX000" });
    for (const secret of [EXTERNAL, WORKSPACE, BRIDGE, USER]) {
      expect(logged).not.toContain(secret);
      expect(body).not.toContain(secret);
    }
  });

  it("로그는 결과 코드뿐이다: 어떤 결과에서도 id · 가상 루트 · 사용자 id가 로그에 없다", async () => {
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const outcomes: AttachAgentSessionResult[] = [created, { status: "existing", conversationId: CONVERSATION, session }, { status: "not_found" }, { status: "session_in_use" }];
    for (const outcome of outcomes) await handleAttachSession(post(BODY), deps({ attach: async () => outcome }).value);
    const lines = info.mock.calls.map((call) => JSON.parse(String(call[0])) as Record<string, unknown>);
    expect(lines).toEqual([
      { event: "agent_session_attach", result: "created" },
      { event: "agent_session_attach", result: "existing" },
      { event: "agent_session_attach", result: "not_found" },
      { event: "agent_session_attach", result: "session_in_use" },
    ]);
    const everything = JSON.stringify([info.mock.calls, error.mock.calls, warn.mock.calls, log.mock.calls]);
    for (const secret of [EXTERNAL, WORKSPACE, BRIDGE, USER, SESSION, CONVERSATION, CONNECTION]) expect(everything).not.toContain(secret);
  });
});
