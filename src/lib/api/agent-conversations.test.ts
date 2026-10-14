import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { id } from "../../../tests/conversation/fakes";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn() }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn() }));

import { AnswerInputError } from "@/lib/agents/answers";
import type { AgentMessageOutcome } from "@/lib/agents/messages";
import type { AttachmentCheck } from "@/lib/agents/attachments";

import {
  createAgentPostDelegate,
  handleAnswerQuestion,
  handleDeliverAgentMessages,
  handleGetDeliveries,
  handleListTargets,
  handleOpenExternal,
  handleRenameSession,
  handleResumeHere,
  handleSetReferent,
  handleStopConversation,
  handleStopSession,
  prepareTaskforceAttachments,
  type AgentPostDeps,
  type AnswerDeps,
  type DeliverDeps,
  type DeliveryReadDeps,
  type OpenExternalDeps,
  type ReferentDeps,
  type RenameSessionDeps,
  type ResumeHereDeps,
  type StopConversationDeps,
  type StopSessionDeps,
  type TargetsDeps,
} from "./agent-conversations";
import { agentStopResponseSchema, apiErrorV2AgentCodeSchema, postAgentMessageResponseSchema, type Attachment } from "./contract";
import { handleCreateConversation, handlePostConversationMessage, type AgentCreateDelegate, type PostMessageDeps } from "./conversations";

// 에이전트 대화 route 처리 (OA D1d-s). 인증 · gate · DB · 에이전트 호출은 인자로 받아 Route Handler 밖에서 시험한다 (conversations.test.ts와 같은 방식).
// 호출 수(mock.calls)로 "쓰기 0 · 전달 0 · 모델 호출 0"을 증명한다.

type User = { user: { id: string } };
const USER: User = { user: { id: id(1, "11111111") } };
const CONV = id(1, "cccccccc");
const CONN = id(1, "c0c0c0c0");
const SESSION = id(1, "5e5e5e5e");
const MSG = id(1, "dddddddd");
const MSG2 = id(2, "dddddddd");
const CLIENT = id(1, "c1c1c1c1");
const TASK = id(1, "7a7a7a7a");
const STEP = id(1, "57575757");
const ACTION = id(1, "acacacac");
const ACTION2 = id(2, "acacacac");
const CONTEXT = id(1, "c7c7c7c7");
const RUN = id(1, "20202020");
const SOURCE = id(1, "50505050");
const ARTIFACT = id(1, "a7a7a7a7");
const TEXT = "이어서 해 줘";
const URL_BASE = "https://api.example.dev/api/v2";

const chip = (kind: Attachment["kind"], chipId: string, origin: Attachment["origin"] = "added"): Attachment => ({ kind, id: chipId, origin });
const noneMissing: AttachmentCheck = { missing: [], purged: [], executionArtifactIds: [] };
const json = (body: unknown, method = "POST", url = `${URL_BASE}/x`) => new Request(url, { method, body: method === "GET" ? undefined : JSON.stringify(body) });
const body = async (response: Response) => (await response.json()) as Record<string, unknown>;

const message = (extra: Record<string, unknown> = {}) => ({
  id: MSG, conversation_id: CONV, seq: 1, role: "user" as const, client_message_id: CLIENT, text: TEXT, refs: { action_ids: [], run_ids: [], artifact_ids: [], suggestion_ids: [], dependency_ids: [], memory_item_ids: [], context_ids: [], proposal: null },
  intent: null, created_at: "2026-10-14T01:00:00.000Z", reply_to: null, content: null, delivery_state: "dispatched" as const, delivery_reason: null, delivery_expires_at: "2026-10-15T01:00:00.000Z", ...extra,
});
const OUTCOME: AgentMessageOutcome = {
  message: message(),
  delivery: { state: "sent" },
  created_action: { id: ACTION, number: 139, title: TEXT, context_id: null },
  agent_task: { id: TASK, state: "dispatched", agent_session_id: SESSION },
};

let errors: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
});
afterEach(() => {
  errors.mockRestore();
});
/** 로그에는 이벤트 이름 · 오류 이름 · 코드만 있다: 글 · 칩 id · 답 · 질문이 없다 (R17) */
const logged = () => errors.mock.calls.map((call: unknown[]) => String(call[0])).join("\n");
const expectNoUserText = () => {
  for (const secret of [TEXT, ACTION, ACTION2, CONTEXT, SOURCE, ARTIFACT, "비밀 답", "Private"]) expect(logged()).not.toContain(secret);
};

// ───────────────────────────── 보내기: 에이전트 대상 ─────────────────────────────

function agentDeps(overrides: Partial<AgentPostDeps<User>> = {}): AgentPostDeps<User> {
  return {
    memoryEnabled: vi.fn(() => true),
    adapterOpen: vi.fn(async () => true),
    messageExists: vi.fn(async () => false),
    checkAttachments: vi.fn(async () => noneMissing),
    post: vi.fn(async () => ({ status: "created" as const, messageId: MSG, seq: 1 })),
    recordAttached: vi.fn(async () => undefined),
    start: vi.fn(async () => ({ status: "started" })),
    outcome: vi.fn(async () => OUTCOME),
    ...overrides,
  };
}
const agentConversation = { id: CONV, contextId: null, contextName: null, targetKind: "agent" as const, agentConnectionId: CONN, agentSessionId: null };

function postDeps(agent: AgentPostDeps<User>, overrides: Partial<PostMessageDeps<User>> = {}) {
  return {
    enabled: vi.fn(() => true),
    memoryEnabled: vi.fn(() => true),
    authenticate: vi.fn(async () => USER),
    hasConsent: vi.fn(async () => true),
    rateLimit: vi.fn(async () => null),
    loadConversation: vi.fn(async () => agentConversation),
    verifySelected: vi.fn(async () => ({ targets: [] })),
    messageExists: vi.fn(async () => false),
    post: vi.fn(),
    loadMessage: vi.fn(),
    loadWindow: vi.fn(),
    respond: vi.fn(),
    finish: vi.fn(),
    release: vi.fn(),
    agent: createAgentPostDelegate(agent),
    ...overrides,
  } as unknown as PostMessageDeps<User> & { [K in "rateLimit" | "verifySelected" | "messageExists" | "post" | "loadMessage" | "loadWindow" | "respond" | "finish" | "release" | "hasConsent"]: ReturnType<typeof vi.fn> };
}
const send = (deps: PostMessageDeps<User>, payload: unknown = { client_message_id: CLIENT, text: TEXT }, conversationId = CONV) =>
  handlePostConversationMessage(new Request(`${URL_BASE}/conversations/${conversationId}/messages`, { method: "POST", body: JSON.stringify(payload) }), conversationId, deps);

describe("POST messages · 에이전트 대상 (delegate)", () => {
  it("R16: 에이전트 대상은 Taskforce 모델 경로(분류 · 상담 · 한도 · 기록 읽기 · 답 쓰기)를 하나도 부르지 않는다", async () => {
    const agent = agentDeps();
    const deps = postDeps(agent);
    const response = await send(deps);
    expect(response.status).toBe(200);
    for (const fn of [deps.rateLimit, deps.verifySelected, deps.messageExists, deps.post, deps.loadMessage, deps.loadWindow, deps.respond, deps.finish, deps.release]) expect(fn).not.toHaveBeenCalled();
  });

  it("에이전트 대화에 delegate가 주입되지 않으면 404 (다른 경로로 새지 않는다)", async () => {
    const deps = postDeps(agentDeps(), { agent: undefined });
    expect((await send(deps)).status).toBe(404);
    expect(deps.respond).not.toHaveBeenCalled();
  });

  it("gate · 인증 · 본문 · 동의는 대화 처리 그대로다: 꺼짐 404 · 인증 거부 401 · 잘못된 id 404 · refs+attachments 400 · 동의 없음 409. 모두 저장 · 전달 0", async () => {
    const agent = agentDeps();
    expect((await send(postDeps(agent, { enabled: vi.fn(() => false) }))).status).toBe(404);
    expect((await send(postDeps(agent, { authenticate: vi.fn(async () => null) }))).status).toBe(401);
    expect((await send(postDeps(agent), undefined, "not-a-uuid")).status).toBe(404);
    expect((await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, refs: {}, attachments: [chip("action", ACTION)] })).status).toBe(400);
    expect((await send(postDeps(agent), { client_message_id: CLIENT, text: "   " })).status).toBe(400);
    const noConsent = postDeps(agent, { hasConsent: vi.fn(async () => false) });
    expect((await send(noConsent)).status).toBe(409);
    expect(noConsent.loadConversation).not.toHaveBeenCalled();
    expect(agent.post).not.toHaveBeenCalled();
    expect(agent.start).not.toHaveBeenCalled();
  });

  it("R1: 그 대화의 adapter 플래그가 꺼져 있으면 404 — 칩 확인 · 저장 · 전달 · 지표 0 (OD-2)", async () => {
    const agent = agentDeps({ adapterOpen: vi.fn(async () => false) });
    const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] });
    expect(response.status).toBe(404);
    expect(agent.adapterOpen).toHaveBeenCalledWith(USER, CONN);
    for (const fn of [agent.checkAttachments, agent.post, agent.recordAttached, agent.start, agent.outcome]) expect(fn).not.toHaveBeenCalled();
  });

  it("새 메시지: 칩 정규화 → 소유 확인 → 저장(selected = added action · context id + 정규화한 칩 전체) → context_attached → 전달 시작 → 다시 읽은 응답", async () => {
    const agent = agentDeps();
    const chips = [chip("context", CONTEXT, "added"), chip("action", ACTION2.toUpperCase(), "auto"), chip("action", ACTION, "added"), chip("action", ACTION2, "added"), chip("source", SOURCE, "auto")];
    const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [...chips, chip("source", SOURCE, "auto")] });
    expect(response.status).toBe(200);
    const normalized = [chip("action", ACTION), chip("action", ACTION2), chip("context", CONTEXT), chip("source", SOURCE, "auto")];
    expect(agent.checkAttachments).toHaveBeenCalledWith(USER, normalized);
    expect(agent.post).toHaveBeenCalledWith(USER, {
      conversationId: CONV, clientMessageId: CLIENT, text: TEXT,
      selected: { action_ids: [ACTION, ACTION2], context_ids: [CONTEXT], attachments: normalized },
    });
    expect(agent.recordAttached).toHaveBeenCalledTimes(1);
    expect(agent.recordAttached).toHaveBeenCalledWith(USER, [
      { kind: "action", origin: "added", sent: true }, { kind: "action", origin: "added", sent: true },
      { kind: "context", origin: "added", sent: true }, { kind: "source", origin: "auto", sent: false },
    ]);
    expect(agent.start).toHaveBeenCalledExactlyOnceWith(USER, CONV, MSG);
    expect(vi.mocked(agent.post).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(agent.start).mock.invocationCallOrder[0]);
    const parsed = postAgentMessageResponseSchema.parse(await response.json());
    expect(parsed).toMatchObject({ reply: null, delivery: { state: "sent" }, attachments_dropped: [], created_action: { number: 139 }, agent_task: { id: TASK } });
  });

  it("R6 AC-6: auto 칩은 전달 입력(selected의 id 목록)에 없고 context_attached.sent=false다", async () => {
    const agent = agentDeliveryProbe();
    await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION, "auto"), chip("context", CONTEXT, "auto"), chip("run", RUN, "auto")] });
    const posted = vi.mocked(agent.post).mock.calls[0][1].selected as { action_ids: string[]; context_ids: string[]; attachments: Attachment[] };
    expect(posted.action_ids).toEqual([]);
    expect(posted.context_ids).toEqual([]);
    expect(posted.attachments).toHaveLength(3);
    expect(vi.mocked(agent.recordAttached).mock.calls[0][1].map((c) => c.sent)).toEqual([false, false, false]);
  });

  it("칩이 없으면 selected는 빈 목록 셋이다 (action_ids · context_ids · attachments). 옛 refs는 added 칩으로 바뀐다", async () => {
    const agent = agentDeps();
    await send(postDeps(agent));
    expect(vi.mocked(agent.post).mock.calls[0][1].selected).toEqual({ action_ids: [], context_ids: [], attachments: [] });
    expect(agent.recordAttached).not.toHaveBeenCalled();
    const legacy = agentDeps();
    await send(postDeps(legacy), { client_message_id: CLIENT, text: TEXT, refs: { action_ids: [ACTION], run_ids: [RUN] } });
    expect(vi.mocked(legacy.post).mock.calls[0][1].selected).toEqual({ action_ids: [ACTION], context_ids: [], attachments: [chip("action", ACTION), chip("run", RUN)] });
  });

  it.each(["action", "context", "agent_session", "run", "artifact", "source"] as const)("R4 AC-1: %s 칩이 남의 · 없는 id면 404 — 저장 · context_attached · 전달 0", async (kind) => {
    const agent = agentDeps({ checkAttachments: vi.fn(async (_user, chips) => ({ ...noneMissing, missing: chips })) });
    const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip(kind, ACTION)] });
    expect(response.status).toBe(404);
    for (const fn of [agent.post, agent.recordAttached, agent.start, agent.outcome]) expect(fn).not.toHaveBeenCalled();
  });

  it("OD-25: 범위 기능이 꺼져 있으면 context 칩은 400 (소유 확인 · 저장 0)", async () => {
    const agent = agentDeps({ memoryEnabled: vi.fn(() => false) });
    const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("context", CONTEXT)] });
    expect(response.status).toBe(400);
    expect((await body(response)).error).toMatchObject({ code: "invalid_request" });
    expect(agent.checkAttachments).not.toHaveBeenCalled();
    expect(agent.post).not.toHaveBeenCalled();
    // context가 아닌 칩은 범위 기능과 무관
    expect((await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] })).status).toBe(200);
  });

  it("R5 AC-2: 같은 client_message_id에 글이 다르면 409(다른 글), 칩이 다르면 409(다른 대상). 지표 · 전달 0", async () => {
    for (const [status, text] of [["mismatch", "다른 글"], ["refs_mismatch", "다른 대상"]] as const) {
      const agent = agentDeps({ post: vi.fn(async () => ({ status, messageId: MSG, seq: 1 })) });
      const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] });
      expect(response.status).toBe(409);
      expect(await body(response)).toMatchObject({ error: { code: "conflict", message: expect.stringContaining(text) } });
      expect(agent.recordAttached).not.toHaveBeenCalled();
      expect(agent.start).not.toHaveBeenCalled();
    }
  });

  it("R5 AC-2: 같은 제출 재전송(exists)은 지표를 다시 세지 않고, 전달은 다시 시도한다 (이미 dispatched면 SQL이 already_dispatched로 막는다)", async () => {
    const agent = agentDeps({ post: vi.fn(async () => ({ status: "exists" as const, messageId: MSG, seq: 1 })), messageExists: vi.fn(async () => true) });
    const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] });
    expect(response.status).toBe(200);
    expect(agent.recordAttached).not.toHaveBeenCalled();
    expect(agent.start).toHaveBeenCalledExactlyOnceWith(USER, CONV, MSG);
  });

  it("대화가 그 사이 사라졌으면(post not_found) 404, 저장한 뒤 읽을 수 없으면 500", async () => {
    const gone = agentDeps({ post: vi.fn(async () => ({ status: "not_found" as const, messageId: null, seq: null })) });
    expect((await send(postDeps(gone))).status).toBe(404);
    const unreadable = agentDeps({ outcome: vi.fn(async () => null) });
    expect((await send(postDeps(unreadable))).status).toBe(500);
  });

  it("OD-23: 첫 제출에서 없는 칩은 404이지만, 같은 제출 재전송에서 그 사이 사라진 칩은 dropped(deleted)다. Slack 연결 해제로 글이 지워진 source는 첫 제출에서도 받고 slack_purged", async () => {
    const purged = chip("source", SOURCE);
    const gone = chip("action", ACTION);
    const first = agentDeps({ checkAttachments: vi.fn(async () => ({ ...noneMissing, purged: [purged] })) });
    const firstResponse = await send(postDeps(first), { client_message_id: CLIENT, text: TEXT, attachments: [purged] });
    expect(firstResponse.status).toBe(200);
    expect((await body(firstResponse)).attachments_dropped).toEqual([{ kind: "source", id: SOURCE, reason: "slack_purged" }]);
    expect(vi.mocked(first.recordAttached).mock.calls[0][1]).toEqual([{ kind: "source", origin: "added", sent: false }]);

    const resend = agentDeps({
      messageExists: vi.fn(async () => true),
      post: vi.fn(async () => ({ status: "exists" as const, messageId: MSG, seq: 1 })),
      checkAttachments: vi.fn(async () => ({ ...noneMissing, missing: [gone] })),
    });
    const resendResponse = await send(postDeps(resend), { client_message_id: CLIENT, text: TEXT, attachments: [gone] });
    expect(resendResponse.status).toBe(200);
    expect((await body(resendResponse)).attachments_dropped).toEqual([{ kind: "action", id: ACTION, reason: "deleted" }]);
    // 사라진 칩도 selected에 그대로 남는다 (같은 제출 비교)
    expect(vi.mocked(resend.post).mock.calls[0][1].selected).toMatchObject({ attachments: [gone] });
  });

  it("지표 기록이 실패해도 메시지는 이미 저장됐다: 200으로 답하고 로그에는 이벤트 이름 · 오류 이름만 (R17)", async () => {
    const agent = agentDeps({ recordAttached: vi.fn(async () => { throw Object.assign(new Error(`원문 ${TEXT} ${ACTION}`), { name: "PostgrestError" }); }) });
    const response = await send(postDeps(agent), { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] });
    expect(response.status).toBe(200);
    expect(agent.start).toHaveBeenCalledTimes(1);
    expect(JSON.parse(logged())).toEqual({ event: "context_attached_failed", error: "PostgrestError" });
    expectNoUserText();
  });

  it("잠금 경합(55P03 · 40001) · 교착(40P01)은 409 busy_retry (쓰기는 롤백됐다, 500 아님), 그 밖 오류는 500 + 이름만 로그", async () => {
    for (const code of ["55P03", "40001", "40P01"]) {
      const agent = agentDeps({ start: vi.fn(async () => { throw Object.assign(new Error(TEXT), { code }); }) });
      const response = await send(postDeps(agent));
      expect(response.status).toBe(409);
      expect((await body(response)).error).toMatchObject({ code: "busy_retry" });
    }
    const broken = agentDeps({ start: vi.fn(async () => { throw Object.assign(new Error(`${TEXT} ${CONTEXT}`), { name: "PostgrestError", code: "XX000" }); }) });
    const response = await send(postDeps(broken));
    expect(response.status).toBe(500);
    expect(JSON.parse(logged())).toMatchObject({ event: "agent_message_failed", error: "PostgrestError", code: "XX000" });
    expectNoUserText();
  });
});

function agentDeliveryProbe() {
  return agentDeps();
}

// ───────────────────────────── 보내기: taskforce 대상의 칩 (OD-5) ─────────────────────────────

describe("POST messages · taskforce 대상의 맥락 칩 (OD-5: 저장 · 검증만, 답 생성 불변)", () => {
  const TF_CONV = { id: CONV, contextId: null, contextName: null };
  const reply = { id: id(9, "dddddddd"), seq: 2, role: "assistant" as const, client_message_id: null, text: "답", refs: message().refs, intent: null, created_at: "2026-10-14T01:00:01.000Z", reply_to: MSG, content: { segments: [{ text: "답", tier: "T5" as const }], citations: [], proposal: null, asks: null, used: null, window: null } };
  function tfDeps(overrides: Record<string, unknown> = {}) {
    return {
      enabled: vi.fn(() => true), memoryEnabled: vi.fn(() => true), authenticate: vi.fn(async () => USER), hasConsent: vi.fn(async () => true), rateLimit: vi.fn(async () => null),
      loadConversation: vi.fn(async () => TF_CONV),
      verifySelected: vi.fn(async () => ({ targets: [] })),
      messageExists: vi.fn(async () => false),
      post: vi.fn(async () => ({ status: "created" as const, messageId: MSG, seq: 1, replyId: null })),
      loadMessage: vi.fn(async (_u: User, messageId: string) => (messageId === reply.id ? reply : { ...message(), delivery_state: undefined, delivery_reason: undefined, delivery_expires_at: undefined })),
      loadWindow: vi.fn(async () => ({ messages: [{ id: MSG, seq: 1, role: "user" as const, text: TEXT, textExpired: false, createdAt: "2026-10-14T01:00:00.000Z", refs: reply.refs, content: null }], omitted: 0 })),
      respond: vi.fn(async () => ({ intent: { kind: "consult", confidence: 0.9, judge_version: "v" }, route: "consult", user: { refs: reply.refs }, reply: { text: "답", segments: [], citations: [], refs: reply.refs, content: reply.content }, memory: [], adopt: null, summary: {} })),
      finish: vi.fn(async () => ({ status: "written" as const, replyId: reply.id })),
      release: vi.fn(async () => undefined),
      ...overrides,
    } as unknown as PostMessageDeps<User> & Record<string, ReturnType<typeof vi.fn>>;
  }
  const ok = (attachments: Attachment[]) => ({ status: "ok" as const, refs: { action_ids: [ACTION], run_ids: [], artifact_ids: [] }, selected: { action_ids: [ACTION], run_ids: [], artifact_ids: [], attachments }, attachments });

  it("칩이 없으면 이전과 같다: prepare · record를 부르지 않고 selected는 옛 모양 그대로, 응답 바이트가 같다", async () => {
    const plain = tfDeps();
    const response = await send(plain);
    expect(response.status).toBe(200);
    expect(plain.post).toHaveBeenCalledWith(USER, CONV, CLIENT, TEXT, { action_ids: [], run_ids: [], artifact_ids: [] });
    const withDeps = tfDeps({ prepareAttachments: vi.fn(), recordAttachments: vi.fn() });
    const second = await send(withDeps);
    expect(withDeps.prepareAttachments).not.toHaveBeenCalled();
    expect(withDeps.recordAttachments).not.toHaveBeenCalled();
    expect(await second.text()).toBe(await (await send(tfDeps())).text());
    expect(Object.keys(await (await send(tfDeps())).json())).toEqual(["message", "reply"]);
  });

  it("빈 attachments 배열은 칩이 없는 것과 같다: 준비 · 지표를 부르지 않고 옛 모양으로 저장한다", async () => {
    const deps = tfDeps({ prepareAttachments: vi.fn(), recordAttachments: vi.fn() });
    expect((await send(deps, { client_message_id: CLIENT, text: TEXT, attachments: [] })).status).toBe(200);
    expect(deps.prepareAttachments).not.toHaveBeenCalled();
    expect(deps.post).toHaveBeenCalledWith(USER, CONV, CLIENT, TEXT, { action_ids: [], run_ids: [], artifact_ids: [] });
  });

  it("칩이 있으면 소유 확인 → added 대상만 지시 대상 규칙 1에 (verifySelected) → 전체를 selected로 저장 → 새 메시지면 지표 한 번. 응답 모양은 그대로", async () => {
    const chips = [chip("action", ACTION), chip("context", CONTEXT, "auto")];
    const deps = tfDeps({ prepareAttachments: vi.fn(async () => ok(chips)), recordAttachments: vi.fn(async () => undefined) });
    const response = await send(deps, { client_message_id: CLIENT, text: TEXT, attachments: chips });
    expect(response.status).toBe(200);
    expect(deps.prepareAttachments).toHaveBeenCalledWith(USER, chips, { known: false });
    expect(deps.verifySelected).toHaveBeenCalledWith(USER, { action_ids: [ACTION], run_ids: [], artifact_ids: [] });
    expect(deps.post).toHaveBeenCalledWith(USER, CONV, CLIENT, TEXT, { action_ids: [ACTION], run_ids: [], artifact_ids: [], attachments: chips });
    expect(deps.recordAttachments).toHaveBeenCalledExactlyOnceWith(USER, chips);
    expect(Object.keys(await response.json())).toEqual(["message", "reply"]);
  });

  it("검토 반영 7-3: 같은 제출 재전송에서 그 사이 지워진 칩은 404가 아니다 — 같은 제출인지를 먼저 보고(known) 저장된 답을 돌려준다. 처리 입력에서는 지워진 칩을 뺀다", async () => {
    const chips = [chip("action", ACTION)];
    const dropped = { status: "ok" as const, refs: { action_ids: [], run_ids: [], artifact_ids: [] }, selected: { action_ids: [ACTION], run_ids: [], artifact_ids: [], attachments: chips }, attachments: chips };
    const deps = tfDeps({
      messageExists: vi.fn(async () => true), prepareAttachments: vi.fn(async () => dropped), recordAttachments: vi.fn(async () => undefined),
      post: vi.fn(async () => ({ status: "answered" as const, messageId: MSG, seq: 1, replyId: reply.id })),
    });
    const response = await send(deps, { client_message_id: CLIENT, text: TEXT, attachments: chips });
    expect(response.status).toBe(200);
    expect(Object.keys(await response.json())).toEqual(["message", "reply"]);
    expect(deps.prepareAttachments).toHaveBeenCalledWith(USER, chips, { known: true });
    expect(deps.messageExists).toHaveBeenCalledTimes(1); // 한도 판단과 같은 읽기를 다시 하지 않는다
    expect(deps.verifySelected).toHaveBeenCalledWith(USER, { action_ids: [], run_ids: [], artifact_ids: [] });
    expect(deps.post).toHaveBeenCalledWith(USER, CONV, CLIENT, TEXT, dropped.selected); // 멱등 비교에는 처음 제출한 첨부 그대로
    expect(deps.respond).not.toHaveBeenCalled();
    expect(deps.recordAttachments).not.toHaveBeenCalled();
  });

  it("재처리(retry)는 지표를 다시 세지 않는다. 지표가 실패해도 답은 간다", async () => {
    const chips = [chip("action", ACTION)];
    const retry = tfDeps({
      prepareAttachments: vi.fn(async () => ok(chips)), recordAttachments: vi.fn(async () => undefined),
      post: vi.fn(async () => ({ status: "retry" as const, messageId: MSG, seq: 1, replyId: null })), messageExists: vi.fn(async () => true),
    });
    await send(retry, { client_message_id: CLIENT, text: TEXT, attachments: chips });
    expect(retry.recordAttachments).not.toHaveBeenCalled();
    const failing = tfDeps({ prepareAttachments: vi.fn(async () => ok(chips)), recordAttachments: vi.fn(async () => { throw Object.assign(new Error(TEXT), { name: "PostgrestError" }); }) });
    expect((await send(failing, { client_message_id: CLIENT, text: TEXT, attachments: chips })).status).toBe(200);
    expectNoUserText();
  });

  it("없는 · 남의 칩 404, 범위 기능이 꺼진 context 칩 400: 저장 · 모델 호출 0", async () => {
    const missing = tfDeps({ prepareAttachments: vi.fn(async () => ({ status: "missing" as const })) });
    expect((await send(missing, { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] })).status).toBe(404);
    const off = tfDeps({ prepareAttachments: vi.fn(async () => ({ status: "context_off" as const })) });
    expect((await send(off, { client_message_id: CLIENT, text: TEXT, attachments: [chip("context", CONTEXT)] })).status).toBe(400);
    for (const deps of [missing, off]) for (const fn of [deps.post, deps.respond, deps.verifySelected]) expect(fn).not.toHaveBeenCalled();
  });

  it("칩을 받을 준비가 안 된 handler(prepareAttachments 없음)는 400", async () => {
    const deps = tfDeps();
    expect((await send(deps, { client_message_id: CLIENT, text: TEXT, attachments: [chip("action", ACTION)] })).status).toBe(400);
    expect(deps.post).not.toHaveBeenCalled();
  });

  describe("prepareTaskforceAttachments", () => {
    const base = { memoryEnabled: () => true, check: vi.fn(async (): Promise<AttachmentCheck> => noneMissing) };
    it("정규화한 칩으로 selected를 만든다: added action · run · execution artifact만 id 목록에, 전체는 attachments에", async () => {
      const check = vi.fn(async (): Promise<AttachmentCheck> => ({ missing: [], purged: [], executionArtifactIds: [ARTIFACT] }));
      const prepared = await prepareTaskforceAttachments({ ...base, check }, USER, [chip("artifact", ARTIFACT.toUpperCase()), chip("run", RUN), chip("action", ACTION, "auto"), chip("action", ACTION), chip("action", ACTION, "auto")]);
      expect(prepared).toMatchObject({
        status: "ok",
        refs: { action_ids: [ACTION], run_ids: [RUN], artifact_ids: [ARTIFACT] },
        selected: { action_ids: [ACTION], run_ids: [RUN], artifact_ids: [ARTIFACT] },
        attachments: [chip("action", ACTION), chip("artifact", ARTIFACT), chip("run", RUN)],
      });
      expect(check).toHaveBeenCalledWith(USER, [chip("action", ACTION), chip("artifact", ARTIFACT), chip("run", RUN)]);
    });
    it("저장용 selected는 칩에서만 정해진다: execution 산출물이 아니어도(에이전트 산출물) artifact_ids에 남고 처리용 refs에서만 빠진다", async () => {
      const prepared = await prepareTaskforceAttachments({ ...base, check: vi.fn(async () => noneMissing) }, USER, [chip("artifact", ARTIFACT)]);
      expect(prepared).toMatchObject({ status: "ok", refs: { artifact_ids: [] }, selected: { artifact_ids: [ARTIFACT], attachments: [chip("artifact", ARTIFACT)] } });
    });
    it("검토 반영 7-3: 같은 제출(known)이면 지워진 칩을 404로 막지 않는다 — 저장용 selected는 원래 첨부 그대로, 처리용 refs에서만 뺀다. 첫 제출(known 아님)은 여전히 missing", async () => {
      const check = vi.fn(async (): Promise<AttachmentCheck> => ({ ...noneMissing, missing: [chip("action", ACTION)], executionArtifactIds: [ARTIFACT] }));
      const chips = [chip("action", ACTION), chip("artifact", ARTIFACT), chip("run", RUN)];
      const resent = await prepareTaskforceAttachments({ ...base, check }, USER, chips, { known: true });
      expect(resent).toMatchObject({
        status: "ok",
        refs: { action_ids: [], run_ids: [RUN], artifact_ids: [ARTIFACT] },
        selected: { action_ids: [ACTION], run_ids: [RUN], artifact_ids: [ARTIFACT], attachments: [chip("action", ACTION), chip("artifact", ARTIFACT), chip("run", RUN)] },
      });
      expect(await prepareTaskforceAttachments({ ...base, check }, USER, chips, { known: false })).toEqual({ status: "missing" });
      expect(await prepareTaskforceAttachments({ ...base, check }, USER, chips)).toEqual({ status: "missing" });
    });
    it("없는 칩은 missing, 범위 기능이 꺼진 context 칩은 context_off (확인 전에)", async () => {
      expect(await prepareTaskforceAttachments({ ...base, check: vi.fn(async () => ({ ...noneMissing, missing: [chip("run", RUN)] })) }, USER, [chip("run", RUN)])).toEqual({ status: "missing" });
      const check = vi.fn(async () => noneMissing);
      expect(await prepareTaskforceAttachments({ memoryEnabled: () => false, check }, USER, [chip("context", CONTEXT)])).toEqual({ status: "context_off" });
      expect(check).not.toHaveBeenCalled();
    });
  });
});

// ───────────────────────────── 대화 만들기: 대상 ─────────────────────────────

describe("POST /api/v2/conversations · 대상 지정 (AC-5)", () => {
  const row = { id: CONV, title: null, context_id: null, created_at: "2026-10-14T01:00:00.000Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null };
  const agentRow = { ...row, target_kind: "agent" as const, agent_connection_id: CONN, agent_session_id: null };
  const create = (deps: Parameters<typeof handleCreateConversation<User>>[1], payload: unknown = {}) =>
    handleCreateConversation(new Request(`${URL_BASE}/conversations`, { method: "POST", body: JSON.stringify(payload) }), deps);
  const delegate = (result: unknown, targetKind: "taskforce" | "agent" | null = null): AgentCreateDelegate<User> => ({ create: vi.fn(async () => result as never), targetKind: vi.fn(async () => targetKind) });
  const base = (agent?: AgentCreateDelegate<User>, taskforce: unknown = { status: "created", conversation: row }) => ({
    enabled: () => true, authenticate: vi.fn(async () => USER), create: vi.fn(async () => taskforce as never), agent,
  });

  it("agent 대상: 연결 id(+ 세션 id)를 delegate에 넘겨 만든다 (201 새로 · 200 같은 대상). 응답 대화에 대상 열이 있다", async () => {
    const agent = delegate({ status: "created", conversation: agentRow });
    const deps = base(agent);
    const response = await create(deps, { id: CONV, title: "T", context_id: CONTEXT, target: { kind: "agent", connection_id: CONN, session_id: SESSION } });
    expect(response.status).toBe(201);
    expect(await body(response)).toEqual({ conversation: agentRow });
    expect(agent.create).toHaveBeenCalledWith(USER, { id: CONV, title: "T", contextId: CONTEXT, connectionId: CONN, sessionId: SESSION });
    expect(deps.create).not.toHaveBeenCalled();
    expect((await create(base(delegate({ status: "existing", conversation: agentRow })), { id: CONV, target: { kind: "agent", connection_id: CONN } })).status).toBe(200);
  });

  it.each([
    [{ status: "target_mismatch" }, 409, "target_mismatch"],
    [{ status: "id_taken" }, 409, "conflict"],
    [{ status: "not_found" }, 404, "not_found"],
    [{ status: "context_not_found" }, 404, "not_found"],
    [{ status: "context_off" }, 400, "invalid_request"],
  ])("agent 대상 결과 %j → %i %s", async (result, status, code) => {
    const response = await create(base(delegate(result)), { id: CONV, target: { kind: "agent", connection_id: CONN } });
    expect(response.status).toBe(status);
    expect((await body(response)).error).toMatchObject({ code });
    expect(apiErrorV2AgentCodeSchema.safeParse(code).success).toBe(true);
  });

  it("delegate가 없는 handler는 agent 대상을 404로 거절한다 (taskforce 경로로 새지 않는다)", async () => {
    const deps = base();
    expect((await create(deps, { target: { kind: "agent", connection_id: CONN } })).status).toBe(404);
    expect(deps.create).not.toHaveBeenCalled();
  });

  it("taskforce 대상: 기존 create 그대로 + 응답에 target_kind 'taskforce' · 연결 · 세션 null. target을 명시해도 같다", async () => {
    for (const payload of [{ id: CONV }, { id: CONV, target: { kind: "taskforce" } }]) {
      const deps = base(delegate(null));
      const response = await create(deps, payload);
      expect(response.status).toBe(201);
      expect(await body(response)).toEqual({ conversation: { ...row, target_kind: "taskforce", agent_connection_id: null, agent_session_id: null } });
      expect(deps.create).toHaveBeenCalledWith(USER, { id: CONV });
    }
  });

  it("AC-5: 같은 id의 기존 대화가 agent면 taskforce 요청은 409 target_mismatch (새로 만든 경우에는 묻지 않는다)", async () => {
    const existing = base(delegate(null, "agent"), { status: "existing", conversation: row });
    const response = await create(existing, { id: CONV });
    expect(response.status).toBe(409);
    expect((await body(response)).error).toMatchObject({ code: "target_mismatch" });
    const fresh = delegate(null, "agent");
    expect((await create(base(fresh), { id: CONV })).status).toBe(201);
    expect(fresh.targetKind).not.toHaveBeenCalled();
    expect((await create(base(delegate(null, "taskforce"), { status: "existing", conversation: row }), { id: CONV })).status).toBe(200);
  });

  it("target의 모르는 키 · 연결 id 없는 agent는 400 (쓰기 0)", async () => {
    const agent = delegate({ status: "created", conversation: agentRow });
    for (const target of [{ kind: "agent" }, { kind: "agent", connection_id: CONN, extra: 1 }, { kind: "other" }]) {
      expect((await create(base(agent), { target })).status, JSON.stringify(target)).toBe(400);
    }
    expect(agent.create).not.toHaveBeenCalled();
  });

  it("gate 꺼짐 404(인증도 부르지 않음) · 인증 거부 401", async () => {
    const off = base(delegate(null));
    expect((await create({ ...off, enabled: () => false }, { target: { kind: "agent", connection_id: CONN } })).status).toBe(404);
    expect(off.authenticate).not.toHaveBeenCalled();
    expect((await create({ ...base(delegate(null)), authenticate: vi.fn(async () => null) }, {})).status).toBe(401);
  });
});

// ───────────────────────────── 공통 표 ─────────────────────────────

const agentConv = { id: CONV, targetKind: "agent" as const, connectionId: CONN, sessionId: SESSION };
const baseDeps = () => ({ enabled: vi.fn(() => true), authenticate: vi.fn(async () => USER) });

type Case = { name: string; call: (deps: never) => Promise<Response>; make: () => Record<string, unknown>; writes: string[] };

describe("R1 · R2: 새 route 공통 — gate 꺼짐 404(인증 · DB 0) · 인증 거부 401 · 잘못된 id 404", () => {
  const delivered = { status: "ok" as const, messages: [] };
  const cases: Case[] = [
    { name: "deliver", writes: ["deliver"], call: (d) => handleDeliverAgentMessages(json({}), CONV, d), make: () => ({ ...baseDeps(), hasConsent: vi.fn(async () => true), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true), deliver: vi.fn(async () => delivered), deliveries: vi.fn(async () => ({})) } satisfies DeliverDeps<User>) },
    { name: "referent", writes: ["setReferent", "start"], call: (d) => handleSetReferent(json({ action_id: ACTION }), CONV, MSG, d), make: () => ({ ...baseDeps(), hasConsent: vi.fn(async () => true), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true), setReferent: vi.fn(async () => "selected" as const), start: vi.fn(async () => undefined), outcome: vi.fn(async () => OUTCOME) } satisfies ReferentDeps<User>) },
    { name: "conversation stop", writes: ["stop"], call: (d) => handleStopConversation(json({}), CONV, d), make: () => ({ ...baseDeps(), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true), stop: vi.fn(async () => ({ tasks: [] })), afterStop: vi.fn(async () => undefined) } satisfies StopConversationDeps<User>) },
    { name: "delivery read", writes: [], call: (d) => handleGetDeliveries(json(undefined, "GET", `${URL_BASE}/conversations/${CONV}/delivery`), CONV, d), make: () => ({ ...baseDeps(), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true), deliveries: vi.fn(async () => []) } satisfies DeliveryReadDeps<User>) },
    { name: "session stop", writes: ["stop"], call: (d) => handleStopSession(json({}), SESSION, d), make: () => ({ ...baseDeps(), sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })), stop: vi.fn(async () => ({ tasks: [] })), afterStop: vi.fn(async () => undefined) } satisfies StopSessionDeps<User>) },
    { name: "rename", writes: ["rename"], call: (d) => handleRenameSession(json({ display_name: "x" }, "PATCH"), SESSION, d), make: () => ({ ...baseDeps(), sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })), rename: vi.fn() } satisfies RenameSessionDeps<User>) },
    { name: "open-external", writes: ["open"], call: (d) => handleOpenExternal(json({}), SESSION, d), make: () => ({ ...baseDeps(), sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })), open: vi.fn() } satisfies OpenExternalDeps<User>) },
    { name: "resume-here", writes: ["resume"], call: (d) => handleResumeHere(json({ confirmed_terminal_closed: true }), SESSION, d), make: () => ({ ...baseDeps(), sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })), resume: vi.fn() } satisfies ResumeHereDeps<User>) },
    { name: "targets", writes: [], call: (d) => handleListTargets(json(undefined, "GET"), d), make: () => ({ ...baseDeps(), list: vi.fn(async () => [{ kind: "taskforce" as const }]) } satisfies TargetsDeps<User>) },
    { name: "answer", writes: ["answer"], call: (d) => handleAnswerQuestion(json({ provider_request_id: "q", answers: { a: "x" } }), TASK, d), make: () => answerDeps() },
  ];

  it.each(cases)("$name: gate가 꺼져 있으면 404 — 인증 · DB 함수 0", async ({ call, make }) => {
    const deps = make();
    deps.enabled = vi.fn(() => false);
    expect((await call(deps as never)).status).toBe(404);
    for (const [key, value] of Object.entries(deps)) if (key !== "enabled") expect(value, key).not.toHaveBeenCalled();
  });

  it.each(cases)("$name: 인증 거부 401 — 쓰기 함수 0", async ({ call, make, writes }) => {
    const deps = make();
    deps.authenticate = vi.fn(async () => null);
    const response = await call(deps as never);
    expect(response.status).toBe(401);
    for (const key of writes) expect(deps[key], key).not.toHaveBeenCalled();
  });
});

// ───────────────────────────── Send again ─────────────────────────────

describe("POST …/deliver (Send again, AC-22 · AC-26)", () => {
  const delivery = { state: "queued" as const, reason: "session_busy" as const };
  function deps(overrides: Partial<DeliverDeps<User>> = {}): DeliverDeps<User> {
    return {
      ...baseDeps(), hasConsent: vi.fn(async () => true), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true),
      deliver: vi.fn(async () => ({ status: "ok" as const, messages: [{ message_id: MSG, result: "requeued" as const }, { message_id: MSG2, result: "skipped" as const, reason: "unknown_outcome" as const }, { message_id: id(3, "dddddddd"), result: "skipped" as const, reason: "not_found" as const }] })),
      deliveries: vi.fn(async () => ({ [MSG]: delivery, [MSG2]: { state: "unknown" as const } })),
      ...overrides,
    };
  }
  const run = (d: DeliverDeps<User>, payload: unknown = {}, conversationId = CONV) => handleDeliverAgentMessages(json(payload), conversationId, d);

  it("다시 대기시키고 시작한 뒤 메시지마다 결과 + 다시 읽은 delivery를 돌려준다. not_found에는 delivery가 없다", async () => {
    const d = deps();
    const response = await run(d, { message_ids: [MSG, MSG2, id(3, "dddddddd")] });
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({
      messages: [
        { message_id: MSG, result: "requeued", delivery },
        { message_id: MSG2, result: "skipped", skipped_reason: "unknown_outcome", delivery: { state: "unknown" } },
        { message_id: id(3, "dddddddd"), result: "skipped", skipped_reason: "not_found" },
      ],
    });
    expect(d.deliver).toHaveBeenCalledWith(USER, CONV, [MSG, MSG2, id(3, "dddddddd")]);
    expect(d.deliveries).toHaveBeenCalledWith(USER, CONV, [MSG, MSG2]);
  });

  it("message_ids가 없으면 대상 상태 전부 (undefined를 넘긴다)", async () => {
    const d = deps();
    await run(d);
    expect(d.deliver).toHaveBeenCalledWith(USER, CONV, undefined);
  });

  it("본문 검증: 빈 목록 · 51개 · uuid가 아닌 값 · 모르는 키는 400 (전달 0)", async () => {
    for (const payload of [{ message_ids: [] }, { message_ids: Array.from({ length: 51 }, () => MSG) }, { message_ids: ["x"] }, { extra: 1 }]) {
      const d = deps();
      expect((await run(d, payload)).status).toBe(400);
      expect(d.deliver).not.toHaveBeenCalled();
    }
    expect((await run(deps(), {}, "not-a-uuid")).status).toBe(404);
  });

  it("동의 없음 409, 대화 없음 404, taskforce 대화 409 conflict, adapter 플래그 꺼짐 404 — 전달 0", async () => {
    const noConsent = deps({ hasConsent: vi.fn(async () => false) });
    expect((await run(noConsent)).status).toBe(409);
    expect((await run(deps({ conversation: vi.fn(async () => null) }))).status).toBe(404);
    const taskforce = deps({ conversation: vi.fn(async () => ({ ...agentConv, targetKind: "taskforce" as const, connectionId: null, sessionId: null })) });
    const response = await run(taskforce);
    expect(response.status).toBe(409);
    expect((await body(response)).error).toMatchObject({ code: "conflict" });
    const closed = deps({ adapterOpen: vi.fn(async () => false) });
    expect((await run(closed)).status).toBe(404);
    for (const d of [noConsent, taskforce, closed]) expect(d.deliver).not.toHaveBeenCalled();
  });

  it("SQL이 대화 없음 · taskforce 대화라고 답해도 같은 오류다", async () => {
    expect((await run(deps({ deliver: vi.fn(async () => ({ status: "not_found" as const, messages: [] })) }))).status).toBe(404);
    expect((await run(deps({ deliver: vi.fn(async () => ({ status: "wrong_target" as const, messages: [] })) }))).status).toBe(409);
  });

  it("잠금 경합 · 교착(55P03 · 40001 · 40P01)은 409 busy_retry, 그 밖 오류는 500 + 이름만 로그", async () => {
    for (const code of ["55P03", "40001", "40P01"]) {
      const busy = await run(deps({ deliver: vi.fn(async () => { throw Object.assign(new Error(TEXT), { code }); }) }));
      expect(busy.status, code).toBe(409);
      expect((await body(busy)).error).toMatchObject({ code: "busy_retry" });
    }
    const broken = await run(deps({ deliver: vi.fn(async () => { throw Object.assign(new Error(TEXT), { name: "PostgrestError" }); }) }));
    expect(broken.status).toBe(500);
    expect(JSON.parse(logged())).toMatchObject({ event: "agent_deliver_failed", error: "PostgrestError" });
    expectNoUserText();
  });
});

// ───────────────────────────── referent ─────────────────────────────

describe("POST …/messages/{message_id}/referent (AC-4)", () => {
  function deps(overrides: Partial<ReferentDeps<User>> = {}): ReferentDeps<User> {
    return {
      ...baseDeps(), hasConsent: vi.fn(async () => true), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true),
      setReferent: vi.fn(async () => "selected" as const), start: vi.fn(async () => undefined), outcome: vi.fn(async () => OUTCOME), ...overrides,
    };
  }
  const run = (d: ReferentDeps<User>, payload: unknown = { action_id: ACTION }, conversationId = CONV, messageId = MSG) =>
    handleSetReferent(json(payload), conversationId, messageId, d);

  it("후보를 고르면(selected) 같은 메시지를 한 번 시작하고 보내기와 같은 응답을 돌려준다", async () => {
    const d = deps();
    const response = await run(d);
    expect(response.status).toBe(200);
    expect(postAgentMessageResponseSchema.parse(await response.json())).toMatchObject({ reply: null, delivery: { state: "sent" } });
    expect(d.setReferent).toHaveBeenCalledWith(USER, CONV, MSG, ACTION);
    expect(d.start).toHaveBeenCalledExactlyOnceWith(USER, CONV, MSG);
    expect(vi.mocked(d.setReferent).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(d.start).mock.invocationCallOrder[0]);
  });

  it.each(["already_dispatched", "expired"] as const)("%s는 200 + 계산한 delivery — 같은 메시지를 다시 전달하지 않는다", async (status) => {
    const d = deps({ setReferent: vi.fn(async () => status) });
    expect((await run(d)).status).toBe(200);
    expect(d.start).not.toHaveBeenCalled();
    expect(d.outcome).toHaveBeenCalledTimes(1);
  });

  it("없는 메시지 · 다른 대화의 메시지 · 후보가 아닌 action은 404 (시작 0)", async () => {
    const d = deps({ setReferent: vi.fn(async () => "not_found" as const) });
    expect((await run(d)).status).toBe(404);
    expect(d.start).not.toHaveBeenCalled();
    expect((await run(deps({ outcome: vi.fn(async () => null) }))).status).toBe(404);
  });

  it("본문 · id 검증: action_id 필수(버전 비트 없는 id도 받는다) · 모르는 키 400 · 잘못된 id 404", async () => {
    expect((await run(deps(), { action_id: "f0000000-0000-f000-f000-000000000001" })).status).toBe(200);
    for (const payload of [{}, { action_id: "x" }, { action_id: ACTION, extra: 1 }]) expect((await run(deps(), payload)).status).toBe(400);
    expect((await run(deps(), { action_id: ACTION }, "bad")).status).toBe(404);
    expect((await run(deps(), { action_id: ACTION }, CONV, "bad")).status).toBe(404);
  });

  it("동의 없음 409 · taskforce 대화 409 · adapter 꺼짐 404 · 대화 없음 404 — 선택 · 시작 0", async () => {
    const cases = [
      deps({ hasConsent: vi.fn(async () => false) }),
      deps({ conversation: vi.fn(async () => ({ ...agentConv, targetKind: "taskforce" as const })) }),
      deps({ adapterOpen: vi.fn(async () => false) }),
      deps({ conversation: vi.fn(async () => null) }),
    ];
    expect((await Promise.all(cases.map((d) => run(d)))).map((r) => r.status)).toEqual([409, 409, 404, 404]);
    for (const d of cases) {
      expect(d.setReferent).not.toHaveBeenCalled();
      expect(d.start).not.toHaveBeenCalled();
    }
  });

  it("잠금 경합 · 교착(40001 · 40P01 · 55P03) 409 busy_retry", async () => {
    for (const code of ["40001", "40P01", "55P03"]) {
      const response = await run(deps({ start: vi.fn(async () => { throw Object.assign(new Error("x"), { code }); }) }));
      expect(response.status, code).toBe(409);
      expect((await body(response)).error).toMatchObject({ code: "busy_retry" });
    }
  });
});

// ───────────────────────────── Stop ─────────────────────────────

describe("POST …/stop (AC-12): 세션 단위 중단", () => {
  const confirmed = { tasks: [{ agent_task_id: TASK, cancel: "confirmed" as const }] };
  const requested = { tasks: [{ agent_task_id: TASK, cancel: "requested_only" as const, processes: "may_continue" as const }] };

  function convDeps(overrides: Partial<StopConversationDeps<User>> = {}): StopConversationDeps<User> {
    return { ...baseDeps(), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true), stop: vi.fn(async () => requested), afterStop: vi.fn(async () => undefined), ...overrides };
  }
  const stopConversation = (d: StopConversationDeps<User>, payload: unknown = {}, conversationId = CONV) => handleStopConversation(json(payload), conversationId, d);

  it("대화에 묶인 세션을 surface 'assistant'로 멈추고 작업별 결과(processes 그대로)를 돌려준다", async () => {
    const d = convDeps();
    const response = await stopConversation(d);
    expect(response.status).toBe(200);
    expect(agentStopResponseSchema.parse(await response.json())).toEqual(requested);
    expect(d.stop).toHaveBeenCalledExactlyOnceWith(USER, SESSION, "assistant");
  });

  it("OD-19: 세션이 없는 대화는 200 { tasks: [] } — 쓰기 0", async () => {
    const d = convDeps({ conversation: vi.fn(async () => ({ ...agentConv, sessionId: null })) });
    const response = await stopConversation(d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ tasks: [] });
    expect(d.stop).not.toHaveBeenCalled();
    expect(d.afterStop).not.toHaveBeenCalled();
  });

  it("로컬에서 확정된 작업이 있으면 commit 뒤 다음 대기 메시지를 한 번 시작해 본다 (5.1). requested_only뿐이면 부르지 않는다", async () => {
    const done = convDeps({ stop: vi.fn(async () => confirmed) });
    await stopConversation(done);
    expect(done.afterStop).toHaveBeenCalledExactlyOnceWith(USER, SESSION);
    expect(vi.mocked(done.stop).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(done.afterStop).mock.invocationCallOrder[0]);
    const pending = convDeps();
    await stopConversation(pending);
    expect(pending.afterStop).not.toHaveBeenCalled();
  });

  it("뒤따르는 시작이 실패해도 Stop 결과는 그대로다 (이름만 로그)", async () => {
    const d = convDeps({ stop: vi.fn(async () => confirmed), afterStop: vi.fn(async () => { throw Object.assign(new Error(TEXT), { name: "PostgrestError" }); }) });
    const response = await stopConversation(d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual(confirmed);
    expect(JSON.parse(logged())).toEqual({ event: "agent_stop_next_failed", error: "PostgrestError" });
    expectNoUserText();
  });

  it("세션이 사라졌으면(not_found) 404, 55P03 소진은 409 busy_retry, 그 밖 오류는 500", async () => {
    expect((await stopConversation(convDeps({ stop: vi.fn(async () => ({ status: "not_found" as const })) }))).status).toBe(404);
    for (const code of ["55P03", "40001", "40P01"]) {
      const busy = await stopConversation(convDeps({ stop: vi.fn(async () => { throw Object.assign(new Error("lock"), { code }); }) }));
      expect(busy.status, code).toBe(409);
      expect((await body(busy)).error).toMatchObject({ code: "busy_retry" });
    }
    expect((await stopConversation(convDeps({ stop: vi.fn(async () => { throw new Error("x"); }) }))).status).toBe(500);
  });

  it("본문은 {}뿐 · taskforce 대화 409 · 대화 없음 404", async () => {
    expect((await stopConversation(convDeps(), { x: 1 })).status).toBe(400);
    expect((await stopConversation(convDeps(), {}, "bad")).status).toBe(404);
    expect((await stopConversation(convDeps({ conversation: vi.fn(async () => ({ ...agentConv, targetKind: "taskforce" as const })) }))).status).toBe(409);
    expect((await stopConversation(convDeps({ conversation: vi.fn(async () => null) }))).status).toBe(404);
  });

  it("롤백 규칙(코디네이터 결정): adapter 플래그가 꺼져 있어도 Stop은 200으로 돈다 — 이미 있는 턴을 멈추고 결과를 돌려준다. 다음 대기 메시지 시작만 플래그를 따른다(0)", async () => {
    const closed = convDeps({ adapterOpen: vi.fn(async () => false), stop: vi.fn(async () => confirmed) });
    const response = await stopConversation(closed);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual(confirmed);
    expect(closed.stop).toHaveBeenCalledExactlyOnceWith(USER, SESSION, "assistant");
    expect(closed.afterStop).not.toHaveBeenCalled();
    // 켜져 있으면 확정된 작업 뒤에 다음 시작을 해 본다 (위 시험)
    const open = convDeps({ stop: vi.fn(async () => confirmed) });
    await stopConversation(open);
    expect(open.afterStop).toHaveBeenCalledTimes(1);
  });

  it("세션 패널 Stop: surface 'session_panel', 없는 세션 404 (중단 함수가 not_found)", async () => {
    const d: StopSessionDeps<User> = { ...baseDeps(), sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })), stop: vi.fn(async () => requested), afterStop: vi.fn(async () => undefined) };
    const response = await handleStopSession(json({}), SESSION, d);
    expect(response.status).toBe(200);
    expect(d.stop).toHaveBeenCalledExactlyOnceWith(USER, SESSION, "session_panel");
    const none = { ...d, sessionAdapter: vi.fn(async () => null), stop: vi.fn(async () => ({ status: "not_found" as const })) };
    expect((await handleStopSession(json({}), SESSION, none)).status).toBe(404);
    expect((await handleStopSession(json({}), "bad", d)).status).toBe(404);
  });

  it("롤백 규칙(코디네이터 결정): adapter 플래그가 꺼져 있어도 세션 Stop은 200으로 돈다. 다음 대기 메시지 시작만 플래그를 따른다(0)", async () => {
    const off: StopSessionDeps<User> = {
      ...baseDeps(), sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: false })), stop: vi.fn(async () => confirmed), afterStop: vi.fn(async () => undefined),
    };
    const response = await handleStopSession(json({}), SESSION, off);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual(confirmed);
    expect(off.stop).toHaveBeenCalledExactlyOnceWith(USER, SESSION, "session_panel");
    expect(off.afterStop).not.toHaveBeenCalled();
    // 어느 adapter인지 알 수 없는 세션(연결이 registry 밖)도 멈추기는 한다
    const unknown = { ...off, sessionAdapter: vi.fn(async () => null) };
    expect((await handleStopSession(json({}), SESSION, unknown)).status).toBe(200);
    expect(unknown.afterStop).not.toHaveBeenCalled();
  });
});

// ───────────────────────────── 전달 읽기 ─────────────────────────────

describe("GET …/delivery (OD-13)", () => {
  const url = (query = "") => `${URL_BASE}/conversations/${CONV}/delivery${query}`;
  function deps(overrides: Partial<DeliveryReadDeps<User>> = {}): DeliveryReadDeps<User> {
    return { ...baseDeps(), conversation: vi.fn(async () => agentConv), adapterOpen: vi.fn(async () => true), deliveries: vi.fn(async () => [{ message_id: MSG, seq: 1, delivery: { state: "accepted" as const } }]), ...overrides };
  }

  it("전달 표시를 서버 계산으로 돌려준다 (읽기만). since_seq를 넘긴다", async () => {
    const d = deps();
    const response = await handleGetDeliveries(json(undefined, "GET", url("?since_seq=4")), CONV, d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ messages: [{ message_id: MSG, seq: 1, delivery: { state: "accepted" } }] });
    expect(d.deliveries).toHaveBeenCalledWith(USER, CONV, 4);
    await handleGetDeliveries(json(undefined, "GET", url()), CONV, d);
    expect(d.deliveries).toHaveBeenLastCalledWith(USER, CONV, undefined);
  });

  it("since_seq가 정수가 아니거나 음수면 400", async () => {
    for (const query of ["?since_seq=x", "?since_seq=-1", "?since_seq=1.5", "?since_seq="]) {
      const d = deps();
      expect((await handleGetDeliveries(json(undefined, "GET", url(query)), CONV, d)).status, query).toBe(400);
      expect(d.deliveries).not.toHaveBeenCalled();
    }
  });

  it("대화 없음 404 · taskforce 대화 409 · adapter 꺼짐 404", async () => {
    expect((await handleGetDeliveries(json(undefined, "GET", url()), CONV, deps({ conversation: vi.fn(async () => null) }))).status).toBe(404);
    expect((await handleGetDeliveries(json(undefined, "GET", url()), CONV, deps({ conversation: vi.fn(async () => ({ ...agentConv, targetKind: "taskforce" as const })) }))).status).toBe(409);
    expect((await handleGetDeliveries(json(undefined, "GET", url()), CONV, deps({ adapterOpen: vi.fn(async () => false) }))).status).toBe(404);
  });
});

// ───────────────────────────── 세션 ─────────────────────────────

describe("세션 route: 이름 · Open in Terminal · Resume here", () => {
  const session = { id: SESSION, connection_id: CONN, display_name: "Pricing", status: "external" as const, last_turn_seq: 3, updated_at: "2026-10-14T01:00:00.000Z" };
  const adapter = { sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })) };

  it("이름 바꾸기: trim한 이름으로 부르고 세션을 돌려준다 (R14: 공백 · 200자 넘음 400, 남의 세션 404, adapter 꺼짐 404)", async () => {
    const d: RenameSessionDeps<User> = { ...baseDeps(), ...adapter, rename: vi.fn(async () => ({ status: "renamed" as const, session })) };
    const response = await handleRenameSession(json({ display_name: "  Pricing  " }, "PATCH"), SESSION, d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ session });
    expect(d.rename).toHaveBeenCalledWith(USER, SESSION, "Pricing");
    for (const payload of [{ display_name: "   " }, { display_name: "x".repeat(201) }, {}, { display_name: "a", status: "closed" }]) {
      expect((await handleRenameSession(json(payload, "PATCH"), SESSION, d)).status).toBe(400);
    }
    expect(d.rename).toHaveBeenCalledTimes(1);
    const unchanged = { ...d, rename: vi.fn(async () => ({ status: "unchanged" as const, session })) };
    expect((await handleRenameSession(json({ display_name: "Pricing" }, "PATCH"), SESSION, unchanged)).status).toBe(200);
    expect((await handleRenameSession(json({ display_name: "a" }, "PATCH"), SESSION, { ...d, rename: vi.fn(async () => ({ status: "not_found" as const })) })).status).toBe(404);
    const stranger = { ...d, sessionAdapter: vi.fn(async () => null), rename: vi.fn() };
    expect((await handleRenameSession(json({ display_name: "a" }, "PATCH"), SESSION, stranger)).status).toBe(404);
    const off = { ...d, sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: false })), rename: vi.fn() };
    expect((await handleRenameSession(json({ display_name: "a" }, "PATCH"), SESSION, off)).status).toBe(404);
    expect(stranger.rename).not.toHaveBeenCalled();
    expect(off.rename).not.toHaveBeenCalled();
  });

  it.each([
    [{ status: "external", session }, 200, null],
    [{ status: "unchanged", session }, 200, null],
    [{ status: "busy" }, 409, "session_busy"],
    [{ status: "not_started" }, 409, "conflict"],
    [{ status: "not_bound" }, 409, "conflict"],
    [{ status: "not_found" }, 404, "not_found"],
  ])("Open in Terminal 결과 %j → %i %s", async (result, status, code) => {
    const d: OpenExternalDeps<User> = { ...baseDeps(), ...adapter, open: vi.fn(async () => result as never) };
    const response = await handleOpenExternal(json({}), SESSION, d);
    expect(response.status).toBe(status);
    if (code) expect((await body(response)).error).toMatchObject({ code });
    else expect(await body(response)).toEqual({ session });
  });

  it("Open in Terminal: 본문은 {}뿐, adapter 꺼짐 · 없는 세션 404 (SQL 0)", async () => {
    const d: OpenExternalDeps<User> = { ...baseDeps(), ...adapter, open: vi.fn() };
    expect((await handleOpenExternal(json({ x: 1 }), SESSION, d)).status).toBe(400);
    expect((await handleOpenExternal(json({}), "bad", d)).status).toBe(404);
    const off = { ...d, sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: false })) };
    expect((await handleOpenExternal(json({}), SESSION, off)).status).toBe(404);
    expect(d.open).not.toHaveBeenCalled();
  });

  it("Resume here: 터미널을 닫았다는 확인(confirmed_terminal_closed: true)이 있어야 한다 — 없으면 400, 전이 0", async () => {
    const d: ResumeHereDeps<User> = { ...baseDeps(), ...adapter, resume: vi.fn(async () => ({ status: "bound" as const, session, startedMessageId: MSG })) };
    for (const payload of [{}, { confirmed_terminal_closed: false }, { confirmed_terminal_closed: "true" }]) {
      expect((await handleResumeHere(json(payload), SESSION, d)).status).toBe(400);
    }
    expect(d.resume).not.toHaveBeenCalled();
    const response = await handleResumeHere(json({ confirmed_terminal_closed: true }), SESSION, d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ session, started_message_id: MSG });
  });

  it.each([
    [{ status: "unchanged", session, startedMessageId: null }, 200, null],
    [{ status: "not_external", startedMessageId: null }, 409, "conflict"],
    [{ status: "not_found", startedMessageId: null }, 404, "not_found"],
  ])("Resume here 결과 %j → %i %s", async (result, status, code) => {
    const d: ResumeHereDeps<User> = { ...baseDeps(), ...adapter, resume: vi.fn(async () => result as never) };
    const response = await handleResumeHere(json({ confirmed_terminal_closed: true }), SESSION, d);
    expect(response.status).toBe(status);
    if (code) expect((await body(response)).error).toMatchObject({ code });
    else expect(await body(response)).toEqual({ session, started_message_id: null });
  });

  it("세션 route의 잠금 경합은 409 busy_retry, 그 밖 오류는 500 (이름만 로그)", async () => {
    const d: OpenExternalDeps<User> = { ...baseDeps(), ...adapter, open: vi.fn(async () => { throw Object.assign(new Error("x"), { code: "55P03" }); }) };
    for (const code of ["55P03", "40001", "40P01"]) {
      const busy = await handleOpenExternal(json({}), SESSION, { ...d, open: vi.fn(async () => { throw Object.assign(new Error("x"), { code }); }) });
      expect(busy.status, code).toBe(409);
      expect((await body(busy)).error).toMatchObject({ code: "busy_retry" });
    }
    const broken = await handleOpenExternal(json({}), SESSION, { ...d, open: vi.fn(async () => { throw Object.assign(new Error(TEXT), { name: "PostgrestError" }); }) });
    expect(broken.status).toBe(500);
    expect(JSON.parse(logged())).toMatchObject({ event: "agent_session_open_failed", error: "PostgrestError" });
    expectNoUserText();
  });
});

// ───────────────────────────── 대상 목록 ─────────────────────────────

describe("GET /api/v2/assistant/targets", () => {
  it("목록을 돌려준다 (읽기만). 인증 거부 401, 오류는 500", async () => {
    const targets = [{ kind: "taskforce" as const }, { kind: "agent" as const, adapter: "agent:codex", display_name: "Codex", connection_id: CONN, state: "ready" as const, access: "read_only" as const }];
    const d: TargetsDeps<User> = { ...baseDeps(), list: vi.fn(async () => targets) };
    const response = await handleListTargets(json(undefined, "GET"), d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ targets });
    expect(d.list).toHaveBeenCalledWith(USER);
    expect((await handleListTargets(json(undefined, "GET"), { ...d, list: vi.fn(async () => { throw new Error("x"); }) })).status).toBe(500);
  });
});

// ───────────────────────────── 질문 답 ─────────────────────────────

function pendingQuestion(extra: Record<string, unknown> = {}, secret = false) {
  return {
    question_key: [TASK, "q-1"], provider_request_id: "q-1", kind: "input", structured: true, asked_at: "2026-10-14T01:00:00Z",
    questions: [{ id: "choice", header: "Private header", text: "Private question", options: [{ label: "Yes", description: "d" }, { label: "No", description: "d" }], multi_select: false, allow_other: true, secret }],
    ...extra,
  };
}
function answerDeps(overrides: Partial<AnswerDeps<User>> = {}): AnswerDeps<User> & Record<string, ReturnType<typeof vi.fn>> {
  return {
    ...baseDeps(),
    loadTask: vi.fn(async () => ({ id: TASK, sessionId: SESSION, pendingQuestion: pendingQuestion(), answeredQuestion: null })),
    sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: true })),
    answer: vi.fn(async () => ({ status: "answered" as const, step_id: STEP })),
    ...overrides,
  } as never;
}

describe("POST /api/v2/agent-tasks/{id}/answer (R13)", () => {
  const run = (d: AnswerDeps<User>, payload: unknown = { provider_request_id: "q-1", answers: { choice: "Yes" } }, taskId = TASK) => handleAnswerQuestion(json(payload), taskId, d);

  it("input 질문에 답한다: 정확한 질문(pending_question)과 답을 RPC 래퍼에 넘기고 answered + step_id (지표 question_answered는 SQL 래퍼가 같은 트랜잭션에서 남긴다: handler는 쓰지 않는다)", async () => {
    const d = answerDeps();
    const response = await run(d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ status: "answered", step_id: STEP });
    expect(d.answer).toHaveBeenCalledWith(USER, { taskId: TASK, providerRequestId: "q-1", answers: { choice: "Yes" }, question: pendingQuestion() });
  });

  it("다중 선택 · 선택지 밖 입력(Other)도 같은 경로다", async () => {
    for (const answers of [{ choice: ["Yes", "No"] }, { choice: "비밀 답 아님 직접 입력" }]) {
      const d = answerDeps();
      expect((await run(d, { provider_request_id: "q-1", answers })).status).toBe(200);
      expect(vi.mocked(d.answer).mock.calls[0][1].answers).toEqual(answers);
    }
  });

  it("같은 답 두 번: duplicate는 200 같은 step이고 지표를 다시 세지 않는다 (이미 답이 간 질문 answered_question으로 확인)", async () => {
    const d = answerDeps({
      loadTask: vi.fn(async () => ({ id: TASK, sessionId: SESSION, pendingQuestion: null, answeredQuestion: pendingQuestion() })),
      answer: vi.fn(async () => ({ status: "duplicate" as const, step_id: STEP })),
    });
    const response = await run(d);
    expect(response.status).toBe(200);
    expect(await body(response)).toEqual({ status: "duplicate", step_id: STEP });
  });

  it("옛 열쇠 · 질문이 없음 · 다른 질문이면 409 question_stale (RPC 0)", async () => {
    for (const task of [
      { id: TASK, sessionId: SESSION, pendingQuestion: null, answeredQuestion: null },
      { id: TASK, sessionId: SESSION, pendingQuestion: pendingQuestion({ question_key: [TASK, "q-2"], provider_request_id: "q-2" }), answeredQuestion: null },
      { id: TASK, sessionId: SESSION, pendingQuestion: pendingQuestion({ question_key: [id(9, "7a7a7a7a"), "q-1"] }), answeredQuestion: null },
    ]) {
      const d = answerDeps({ loadTask: vi.fn(async () => task) });
      const response = await run(d);
      expect(response.status).toBe(409);
      expect((await body(response)).error).toMatchObject({ code: "question_stale" });
      expect(d.answer).not.toHaveBeenCalled();
    }
  });

  it("승인 질문은 409 approval_via_review: RPC 0 (Review의 Allow · Deny가 정책 평가기를 거친다)", async () => {
    const d = answerDeps({ loadTask: vi.fn(async () => ({ id: TASK, sessionId: SESSION, pendingQuestion: pendingQuestion({ kind: "approval" }), answeredQuestion: null })) });
    const response = await run(d, { provider_request_id: "q-1", answers: { choice: "allow" } });
    expect(response.status).toBe(409);
    expect((await body(response)).error).toMatchObject({ code: "approval_via_review" });
    expect(d.answer).not.toHaveBeenCalled();
  });

  it("비밀값이 하나라도 섞인 질문은 409 secret_requires_local: RPC 0, 값은 로그에도 없다 (R13)", async () => {
    const mixed = pendingQuestion({}, true);
    mixed.questions.push({ id: "other", header: "h", text: "t", options: [], multi_select: false, allow_other: true, secret: false });
    for (const question of [pendingQuestion({}, true), mixed]) {
      const d = answerDeps({ loadTask: vi.fn(async () => ({ id: TASK, sessionId: SESSION, pendingQuestion: question, answeredQuestion: null })) });
      const response = await run(d, { provider_request_id: "q-1", answers: { choice: "비밀 답", other: "x" } });
      expect(response.status).toBe(409);
      expect((await body(response)).error).toMatchObject({ code: "secret_requires_local" });
      expect(d.answer).not.toHaveBeenCalled();
    }
    expectNoUserText();
  });

  it("모양이 틀린 답은 400 (본문 검증 · 질문과 맞지 않는 답 · RPC invalid_answer)", async () => {
    for (const payload of [{}, { provider_request_id: "q-1" }, { provider_request_id: "q-1", answers: { choice: 1 } }, { provider_request_id: "q-1", answers: {}, extra: 1 }]) {
      const d = answerDeps();
      expect((await run(d, payload)).status).toBe(400);
      expect(d.answer).not.toHaveBeenCalled();
    }
    const mismatch = answerDeps({ answer: vi.fn(async () => { throw new AnswerInputError("Answer does not match the question"); }) });
    expect((await run(mismatch)).status).toBe(400);
    const sqlInvalid = answerDeps({ answer: vi.fn(async () => ({ status: "invalid_answer" as const })) });
    expect((await run(sqlInvalid)).status).toBe(400);
  });

  it("RPC가 question_stale · secret_requires_local · not_found를 돌려주면 같은 오류로 옮긴다", async () => {
    for (const [status, http, code] of [["question_stale", 409, "question_stale"], ["secret_requires_local", 409, "secret_requires_local"], ["not_found", 404, "not_found"]] as const) {
      const response = await run(answerDeps({ answer: vi.fn(async () => ({ status })) }));
      expect(response.status).toBe(http);
      expect((await body(response)).error).toMatchObject({ code });
    }
  });

  it("작업이 없거나 남의 것이면 404, 세션 adapter 플래그가 꺼져 있으면 404, 잘못된 id 404 (RPC 0)", async () => {
    const none = answerDeps({ loadTask: vi.fn(async () => null) });
    expect((await run(none)).status).toBe(404);
    const off = answerDeps({ sessionAdapter: vi.fn(async () => ({ adapter: "agent:codex", enabled: false })) });
    expect((await run(off)).status).toBe(404);
    const noAdapter = answerDeps({ sessionAdapter: vi.fn(async () => null) });
    expect((await run(noAdapter)).status).toBe(404);
    expect((await run(answerDeps(), undefined, "bad")).status).toBe(404);
    for (const d of [none, off, noAdapter]) expect(d.answer).not.toHaveBeenCalled();
  });

  it("잠금 경합은 409 busy_retry, 그 밖 DB 오류는 500 + 이름만 로그 (답 · 질문 글 없음)", async () => {
    for (const code of ["55P03", "40001", "40P01"]) {
      const busy = await run(answerDeps({ answer: vi.fn(async () => { throw Object.assign(new Error("x"), { code }); }) }));
      expect(busy.status, code).toBe(409);
      expect((await body(busy)).error).toMatchObject({ code: "busy_retry" });
    }
    const broken = await run(answerDeps({ answer: vi.fn(async () => { throw Object.assign(new Error("Private question 비밀 답"), { name: "PostgrestError", code: "XX000" }); }) }));
    expect(broken.status).toBe(500);
    expect(JSON.parse(logged())).toMatchObject({ event: "agent_answer_failed", error: "PostgrestError", code: "XX000" });
    expectNoUserText();
  });
});
