import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { AiBudgetError } from "@/lib/ai/budget-error";
import { DeadlineExceededError } from "@/lib/ai/deadline";
import { LlmError } from "@/lib/ai/llm";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { ConfirmOutcome, DismissOutcome } from "@/lib/conversation/organize";
import type { TurnPlan } from "@/lib/conversation/respond";

import { emptyRefs, id } from "../../../tests/conversation/fakes";

import { apiErrorV2Schema, postConversationMessageResponseSchema, proposalConfirmResponseSchema, proposalConflictSchema, proposalDismissResponseSchema, updateConversationResponseSchema, type ConversationMessage } from "./contract";
import { handleConfirmProposal, handleCreateConversation, handleDismissProposal, handlePostConversationMessage, handleUpdateConversation, type PostMessageDeps, type ProposalActionDeps } from "./conversations";

// /api/v2/conversations 처리 (B2). 모델 대신 respond를 가짜로 두고 호출 수로 "AI 호출 0"을 증명한다:
// gate 꺼짐 · 인증 거부 · 동의 없음 · 남의 대화/대상 · 같은 제출의 저장된 답 · 처리 중 · 한도에서는 respond(J1 · J2)를 부르지 않는다.

type User = { user: { id: string } };
const USER: User = { user: { id: id(1, "11111111") } };
const CONVERSATION = id(1, "cccccccc");
const MESSAGE = id(1, "dddddddd");
const REPLY = id(2, "dddddddd");
const CLIENT = id(1, "c1c1c1c1");
const TEXT = "오늘 뭘 하면 좋을까?";

const message = (overrides: Partial<ConversationMessage> = {}): ConversationMessage => ({
  id: MESSAGE,
  conversation_id: CONVERSATION,
  seq: 1,
  role: "user",
  client_message_id: CLIENT,
  text: TEXT,
  refs: emptyRefs(),
  intent: { kind: "consult", confidence: 0.9, judge_version: "intent-v1" },
  created_at: "2026-10-10T01:00:00.000Z",
  reply_to: null,
  content: null,
  ...overrides,
});

const replyRow = message({
  id: REPLY,
  seq: 2,
  role: "assistant",
  client_message_id: null,
  text: "등록된 열린 할 일은 없어요.",
  intent: null,
  reply_to: MESSAGE,
  content: { segments: [{ text: "등록된 열린 할 일은 없어요.", tier: "T1" }], citations: [], proposal: null, asks: null, used: null, window: null },
});

const plan = (overrides: Partial<TurnPlan> = {}): TurnPlan =>
  ({
    intent: { kind: "consult", confidence: 0.9, judge_version: "intent-v1" },
    route: "consult",
    user: { refs: emptyRefs() },
    reply: { text: "x", segments: [{ text: "x", tier: "T5" }], citations: [], refs: emptyRefs(), content: replyRow.content! },
    memory: [],
    adopt: null,
    summary: {} as TurnPlan["summary"],
    ...overrides,
  }) as TurnPlan;

function makeDeps(overrides: Partial<PostMessageDeps<User>> = {}) {
  const deps = {
    enabled: vi.fn(() => true),
    memoryEnabled: vi.fn(() => true),
    authenticate: vi.fn(async () => USER),
    hasConsent: vi.fn(async () => true),
    rateLimit: vi.fn(async () => null),
    loadConversation: vi.fn(async () => ({ id: CONVERSATION, contextId: null, contextName: null })),
    verifySelected: vi.fn(async () => ({ targets: [] })),
    messageExists: vi.fn(async () => false),
    post: vi.fn(async () => ({ status: "created" as const, messageId: MESSAGE, seq: 1, replyId: null })),
    loadMessage: vi.fn(async (_u: User, messageId: string) => (messageId === REPLY ? replyRow : message())),
    loadWindow: vi.fn(async () => ({
      messages: [{ id: MESSAGE, seq: 1, role: "user" as const, text: TEXT, textExpired: false, createdAt: "2026-10-10T01:00:00.000Z", refs: emptyRefs(), content: null }],
      omitted: 0,
    })),
    respond: vi.fn(async () => plan()),
    finish: vi.fn(async () => ({ status: "written" as const, replyId: REPLY })),
    release: vi.fn(async () => undefined),
    onDeadlineExceeded: vi.fn(),
    ...overrides,
  };
  return deps;
}

const send = (deps: PostMessageDeps<User>, body: unknown = { client_message_id: CLIENT, text: TEXT }, conversationId = CONVERSATION) =>
  handlePostConversationMessage(new Request(`https://api.example.dev/api/v2/conversations/${conversationId}/messages`, { method: "POST", body: JSON.stringify(body) }), conversationId, deps);

let errors: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
});
afterEach(() => {
  errors.mockRestore();
});

describe("POST /api/v2/conversations/{id}/messages", () => {
  it("gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404: 인증 · DB · 모델을 부르지 않는다 (v1 Ask만)", async () => {
    const deps = makeDeps({ enabled: vi.fn(() => false) });
    const response = await send(deps);
    expect(response.status).toBe(404);
    for (const fn of [deps.authenticate, deps.hasConsent, deps.loadConversation, deps.post, deps.respond, deps.finish]) expect(fn).not.toHaveBeenCalled();
  });

  it("인증 거부 401 · 동의 없음 409 (저장 · 모델 호출 0) · 잘못된 대화 id 404 · 잘못된 본문 400", async () => {
    const unauth = makeDeps({ authenticate: vi.fn(async () => null) });
    expect((await send(unauth)).status).toBe(401);
    expect(unauth.respond).not.toHaveBeenCalled();

    const noConsent = makeDeps({ hasConsent: vi.fn(async () => false) });
    const response = await send(noConsent);
    expect(response.status).toBe(409);
    expect(noConsent.post).not.toHaveBeenCalled();
    expect(noConsent.respond).not.toHaveBeenCalled();

    expect((await send(makeDeps(), undefined, "not-a-uuid")).status).toBe(404);
    expect((await send(makeDeps(), { client_message_id: CLIENT, text: "   " })).status).toBe(400);
    expect((await send(makeDeps(), { client_message_id: CLIENT, text: TEXT, refs: { memory_item_ids: [id(1)] } })).status).toBe(400);
  });

  it("Codex P2: 고른 대상은 정렬 · 중복 제거해 저장 함수에 넘긴다 (같은 제출 비교에 들어간다)", async () => {
    const deps = makeDeps();
    const a = id(2, "abababab");
    const b = id(1, "abababab");
    await send(deps, { client_message_id: CLIENT, text: TEXT, refs: { action_ids: [a, b, a.toUpperCase()] } });
    expect(vi.mocked(deps.post).mock.calls[0][4]).toEqual({ action_ids: [b, a], run_ids: [], artifact_ids: [] });
  });

  it("남의 대화 · 남의 대상(id 주입)이면 404: 저장 · 모델 호출 0", async () => {
    const theirs = makeDeps({ loadConversation: vi.fn(async () => null) });
    expect((await send(theirs)).status).toBe(404);
    expect(theirs.post).not.toHaveBeenCalled();

    const injected = makeDeps({ verifySelected: vi.fn(async () => ({ missing: true as const })) });
    expect((await send(injected, { client_message_id: CLIENT, text: TEXT, refs: { action_ids: [id(9, "99999999")] } })).status).toBe(404);
    expect(injected.verifySelected).toHaveBeenCalledWith(USER, { action_ids: [id(9, "99999999")], run_ids: [], artifact_ids: [] }); // 정규화한 선택으로 확인한다
    expect(injected.post).not.toHaveBeenCalled();
    expect(injected.respond).not.toHaveBeenCalled();
  });

  it("같은 제출(client_message_id)에 답이 있으면 저장된 답 그대로: 한도 · 모델 호출 0", async () => {
    const deps = makeDeps({ messageExists: vi.fn(async () => true), post: vi.fn(async () => ({ status: "answered" as const, messageId: MESSAGE, seq: 1, replyId: REPLY })) });
    const response = await send(deps);
    expect(response.status).toBe(200);
    const body = postConversationMessageResponseSchema.parse(await response.json());
    expect(body.reply).toMatchObject({ id: REPLY, reply_to: MESSAGE, segments: replyRow.content!.segments });
    expect(deps.rateLimit).not.toHaveBeenCalled();
    expect(deps.respond).not.toHaveBeenCalled();
  });

  it.each([
    ["in_progress", "같은 메시지를 처리하고 있습니다."],
    ["mismatch", "같은 client_message_id로 다른 글을 보냈습니다."],
    ["refs_mismatch", "같은 client_message_id로 다른 대상을 보냈습니다."],
    ["stale", "이 메시지 뒤에 새 메시지가 있어 답하지 않았습니다."],
  ] as const)("같은 제출이 %s면 409 · 모델 호출 0", async (status, text) => {
    const deps = makeDeps({ post: vi.fn(async () => ({ status, messageId: MESSAGE, seq: 1, replyId: null })) });
    const response = await send(deps);
    expect(response.status).toBe(409);
    expect((await response.json()).error.message).toBe(text);
    expect(deps.respond).not.toHaveBeenCalled();
  });

  it("L1: 새 제출이 한도에 찼으면 저장 전에 429 (메시지를 남기지 않는다, 모델 호출 0)", async () => {
    const deps = makeDeps({ rateLimit: vi.fn(async () => new Date(Date.now() + 30_000)) });
    const response = await send(deps);
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBeTruthy();
    expect(deps.post).not.toHaveBeenCalled();
    expect(deps.respond).not.toHaveBeenCalled();
  });

  it("L1: 답을 못 받은 같은 제출을 다시 처리할 때(retry)는 저장 뒤에 세고, 한도면 처리 표시를 푼다. 새 제출은 한 번만 센다", async () => {
    const retry = makeDeps({
      messageExists: vi.fn(async () => true),
      post: vi.fn(async () => ({ status: "retry" as const, messageId: MESSAGE, seq: 1, replyId: null })),
      rateLimit: vi.fn(async () => new Date(Date.now() + 30_000)),
    });
    expect((await send(retry)).status).toBe(429);
    expect(retry.release).toHaveBeenCalledWith(USER, MESSAGE);
    expect(retry.respond).not.toHaveBeenCalled();
    const fresh = makeDeps();
    expect((await send(fresh)).status).toBe(200);
    expect(fresh.rateLimit).toHaveBeenCalledTimes(1);
    expect(vi.mocked(fresh.rateLimit).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(fresh.post).mock.invocationCallOrder[0]);
  });

  it("새 메시지: 창 → 답 계획 → 한 트랜잭션 쓰기 → 저장된 사용자 메시지 + 답 (응답 계약)", async () => {
    const deps = makeDeps();
    const response = await send(deps);
    expect(response.status).toBe(200);
    expect(postConversationMessageResponseSchema.safeParse(await response.json()).success).toBe(true);
    expect(deps.loadWindow).toHaveBeenCalledWith(USER, CONVERSATION, 1);
    expect(deps.post).toHaveBeenCalledWith(USER, CONVERSATION, CLIENT, TEXT, { action_ids: [], run_ids: [], artifact_ids: [] });
    const input = vi.mocked(deps.respond).mock.calls[0] as unknown as [User, { message: { id: string; text: string }; flags: { memory: boolean }; selected: unknown[] }];
    expect(input[1]).toMatchObject({ message: { id: MESSAGE, text: TEXT }, flags: { memory: true }, selected: [] });
    expect(deps.finish).toHaveBeenCalledWith(USER, MESSAGE, expect.objectContaining({ route: "consult" }));
    expect(deps.release).not.toHaveBeenCalled();
  });

  it("늦은 응답(finish stale)은 409, 기억 경합(conflict)은 다시 부르지 않고 409, 채택 경합은 한 번 다시 읽어 답한다", async () => {
    const stale = makeDeps({ finish: vi.fn(async () => ({ status: "stale" as const, replyId: null })) });
    expect((await send(stale)).status).toBe(409);

    const memoryConflict = makeDeps({ respond: vi.fn(async () => plan({ memory: [{ item: {} as never, corrects: id(1), expected_version: 1 }] })), finish: vi.fn(async () => ({ status: "conflict" as const, replyId: null })) });
    expect((await send(memoryConflict)).status).toBe(409);
    expect(memoryConflict.respond).toHaveBeenCalledTimes(1);

    const finish = vi.fn().mockResolvedValueOnce({ status: "conflict", replyId: null }).mockResolvedValueOnce({ status: "written", replyId: REPLY });
    const adoptConflict = makeDeps({ respond: vi.fn(async () => plan({ adopt: {} as never })), finish });
    expect((await send(adoptConflict)).status).toBe(200);
    expect(adoptConflict.respond).toHaveBeenCalledTimes(2);
  });

  it("D4c-2: 말로 이동의 범위 version 경합(conflict)도 한 번 다시 읽어 답하고, 그래도 어긋나면 409. 이동 없는 답의 경합은 다시 읽지 않는다", async () => {
    const move = [{ action_id: id(1, "abababab"), add: { context_id: id(1, "c1c1c1c1"), expected_version: 3 }, remove: null }];
    const finish = vi.fn().mockResolvedValueOnce({ status: "conflict", replyId: null }).mockResolvedValueOnce({ status: "written", replyId: REPLY });
    const retried = makeDeps({ respond: vi.fn(async () => plan({ move })), finish });
    expect((await send(retried)).status).toBe(200);
    expect(retried.respond).toHaveBeenCalledTimes(2);

    const stuck = makeDeps({ respond: vi.fn(async () => plan({ move })), finish: vi.fn(async () => ({ status: "conflict" as const, replyId: null })) });
    const response = await send(stuck);
    expect(response.status).toBe(409);
    expect(stuck.respond).toHaveBeenCalledTimes(2);

    const plain = makeDeps({ finish: vi.fn(async () => ({ status: "conflict" as const, replyId: null })) });
    expect((await send(plain)).status).toBe(409);
    expect(plain.respond).toHaveBeenCalledTimes(1);
  });

  it("D4c-2: 앱이 붙인 added context 칩(살아 있는 것)을 respond 입력의 selectedContexts로 넘긴다. 칩이 없으면 빈 목록", async () => {
    const context = id(7, "c1c1c1c1");
    const prepared = makeDeps({
      prepareAttachments: vi.fn(async () => ({
        status: "ok" as const,
        refs: { action_ids: [], run_ids: [], artifact_ids: [] },
        selected: { action_ids: [], run_ids: [], artifact_ids: [], attachments: [{ kind: "context" as const, id: context, origin: "added" as const }] },
        attachments: [{ kind: "context" as const, id: context, origin: "added" as const }],
        context_ids: [context],
      })),
      recordAttachments: vi.fn(async () => undefined),
    });
    expect((await send(prepared, { client_message_id: CLIENT, text: TEXT, attachments: [{ kind: "context", id: context, origin: "added" }] })).status).toBe(200);
    expect(vi.mocked(prepared.respond).mock.calls[0][1]).toMatchObject({ selectedContexts: [context] });

    const none = makeDeps();
    await send(none);
    expect(vi.mocked(none.respond).mock.calls[0][1]).toMatchObject({ selectedContexts: [] });
  });

  it("창에 지금 메시지가 없거나 답 쓰기가 not_found면 처리 표시를 풀고 404", async () => {
    const noWindow = makeDeps({ loadWindow: vi.fn(async () => ({ messages: [], omitted: 0 })) });
    expect((await send(noWindow)).status).toBe(404);
    expect(noWindow.release).toHaveBeenCalledWith(USER, MESSAGE);
    const gone = makeDeps({ finish: vi.fn(async () => ({ status: "not_found" as const, replyId: null })) });
    expect((await send(gone)).status).toBe(404);
    expect(gone.release).toHaveBeenCalledWith(USER, MESSAGE);
  });

  it("도중 실패: 처리 표시를 풀고 동의 철회 409 · 예산 · 마감 504 · 모델 실패 503 · 그 밖 500. 로그에 사용자 글이 없다", async () => {
    const cases: [unknown, number][] = [
      [new ConsentRequiredError(), 409],
      [new AiBudgetError("ai_user_daily_budget_exhausted"), 429],
      [new DeadlineExceededError("llm", "남은 시간 없음"), 504],
      [new LlmError("형식이 깨짐"), 503],
      [new Error(`DB 오류: ${TEXT}`), 500],
    ];
    for (const [error, status] of cases) {
      const deps = makeDeps({ respond: vi.fn(async () => Promise.reject(error)) });
      const response = await send(deps);
      expect(response.status, String(error)).toBe(status);
      expect(deps.release).toHaveBeenCalledWith(USER, MESSAGE);
      if (error instanceof DeadlineExceededError) expect(deps.onDeadlineExceeded).toHaveBeenCalledWith(error);
    }
    const logged = errors.mock.calls.flat().map(String).join("\n");
    expect(logged).not.toContain(TEXT);
  });
});

describe("POST /api/v2/conversations", () => {
  const create = (deps: Parameters<typeof handleCreateConversation<User>>[1], body: unknown = {}) =>
    handleCreateConversation(new Request("https://api.example.dev/api/v2/conversations", { method: "POST", body: JSON.stringify(body) }), deps);
  const conversation = { id: CONVERSATION, title: null, context_id: null, created_at: "2026-10-10T01:00:00.000Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null };

  it("gate 꺼짐 404 (인증도 부르지 않음) · 인증 거부 401", async () => {
    const authenticate = vi.fn(async () => USER);
    expect((await create({ enabled: () => false, authenticate, create: vi.fn() })).status).toBe(404);
    expect(authenticate).not.toHaveBeenCalled();
    expect((await create({ enabled: () => true, authenticate: vi.fn(async () => null), create: vi.fn() })).status).toBe(401);
  });

  it("201 새로 만듦 · 200 같은 id의 내 대화(멱등) · 409 남이 쓴 id · 404 남의 범위 · 400 범위 기능 꺼짐 · 400 모르는 키", async () => {
    const run = async (result: unknown, body: unknown = { id: CONVERSATION }) => (await create({ enabled: () => true, authenticate: async () => USER, create: vi.fn(async () => result as never) }, body)).status;
    expect(await run({ status: "created", conversation })).toBe(201);
    expect(await run({ status: "existing", conversation })).toBe(200);
    expect(await run({ status: "id_taken" })).toBe(409);
    expect(await run({ status: "context_not_found" })).toBe(404);
    expect(await run({ status: "context_off" })).toBe(400);
    expect(await run({ status: "created", conversation }, { user_id: USER.user.id })).toBe(400);
  });
});

describe("PATCH /api/v2/conversations/{id} (B3: 대화 헤더 ProjectLink의 명시적 범위 선택)", () => {
  const CONTEXT = id(1, "a6a6a6a6");
  const conversation = { id: CONVERSATION, title: null, context_id: CONTEXT, created_at: "2026-10-10T01:00:00.000Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null };
  type UpdateDeps = Parameters<typeof handleUpdateConversation<User>>[2];
  const patch = (deps: UpdateDeps, body: unknown = { context_id: CONTEXT }, conversationId = CONVERSATION) =>
    handleUpdateConversation(new Request(`https://api.example.dev/api/v2/conversations/${conversationId}`, { method: "PATCH", body: JSON.stringify(body) }), conversationId, deps);
  const deps = (update: UpdateDeps["update"] = vi.fn(async () => ({ status: "updated" as const, conversation }))): UpdateDeps => ({ enabled: () => true, authenticate: async () => USER, update });

  it("gate CONVERSATIONS_V2_ENABLED 꺼짐 404 (인증 · 쓰기를 부르지 않는다) · 인증 거부 401 · 잘못된 대화 id 404", async () => {
    const authenticate = vi.fn(async () => USER);
    const update = vi.fn();
    expect((await patch({ enabled: () => false, authenticate, update })).status).toBe(404);
    expect(authenticate).not.toHaveBeenCalled();
    expect((await patch({ enabled: () => true, authenticate: async () => null, update })).status).toBe(401);
    expect((await patch(deps(update), { context_id: CONTEXT }, "not-a-uuid")).status).toBe(404);
    expect(update).not.toHaveBeenCalled();
  });

  it("본문은 { context_id: uuid | null } 하나뿐이다: 빈 본문 · 모르는 키(user_id · title · archived_at) · uuid가 아닌 값은 400 (쓰기 0)", async () => {
    const update = vi.fn();
    for (const bad of [{}, { context_id: "x" }, { context_id: CONTEXT, title: "새 제목" }, { context_id: CONTEXT, user_id: USER.user.id }, { context_id: 7 }, { archived_at: null }]) {
      expect((await patch(deps(update), bad)).status, JSON.stringify(bad)).toBe(400);
    }
    expect(update).not.toHaveBeenCalled();
  });

  it("200 { conversation } (바뀜 · 이미 그 범위). 쓰기에는 인증한 사용자 · 경로의 대화 id · 고른 범위(null = All work)만 간다", async () => {
    const update = vi.fn<UpdateDeps["update"]>(async () => ({ status: "updated", conversation }));
    const response = await patch(deps(update));
    expect(response.status).toBe(200);
    expect(updateConversationResponseSchema.parse(await response.json()).conversation).toEqual(conversation);
    await patch(deps(update), { context_id: null });
    expect(update.mock.calls).toEqual([[USER, CONVERSATION, CONTEXT], [USER, CONVERSATION, null]]);
    const same = await patch(deps(vi.fn(async () => ({ status: "unchanged" as const, conversation }))));
    expect(same.status).toBe(200);
  });

  it("남의 · 없는 대화 404 · 남의 · 없는 · 보관된 범위 404 · 범위 기능(MEMORY_ENABLED) 꺼짐 400 — 존재를 드러내지 않는다", async () => {
    const run = async (status: "not_found" | "context_not_found" | "context_off") => {
      const response = await patch(deps(vi.fn(async () => ({ status }))));
      return [response.status, apiErrorV2Schema.parse(await response.json()).error.code] as const;
    };
    expect(await run("not_found")).toEqual([404, "not_found"]);
    expect(await run("context_not_found")).toEqual([404, "not_found"]);
    expect(await run("context_off")).toEqual([400, "invalid_request"]);
  });

  it("예기치 못한 오류는 500이고 로그에 오류 이름만 남는다", async () => {
    const response = await patch(deps(vi.fn(async () => Promise.reject(new Error(`DB 오류 ${CONTEXT}`)))));
    expect(response.status).toBe(500);
    expect(errors.mock.calls.flat().map(String).join("\n")).not.toContain(CONTEXT);
  });
});

// ─── D4c-2: 삭제 · 병합 확인 카드의 버튼 (POST …/proposals/{proposal_id}/confirm · /dismiss) ───
// 쓰기는 conversation_confirm_proposal 한 트랜잭션(store.confirmProposal)이고 AI를 부르지 않는다. 여기서는 gate · 인증 · 입력 · 상태 → HTTP 응답을 본다.
describe("POST /api/v2/conversations/{id}/proposals/{proposal_id}/confirm · dismiss", () => {
  const PROPOSAL = id(7, "fafafafa");
  const ACTION = id(41, "f0b0c918");
  const EVENT = id(8, "dddddddd");
  const NEW_CARD = id(9, "dddddddd");
  const eventRow = message({ id: EVENT, seq: 4, role: "event", client_message_id: null, text: "지웠어요: #141", intent: null, content: { segments: [{ text: "지웠어요: #141", tier: "T1" }], citations: [], proposal: null, asks: null, used: null, window: null } });

  function actionDeps(overrides: Partial<ProposalActionDeps<User>> = {}) {
    return {
      enabled: vi.fn(() => true),
      authenticate: vi.fn(async () => USER),
      confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "confirmed", op: "delete", actionIds: [ACTION], eventId: EVENT })),
      dismiss: vi.fn(async (): Promise<DismissOutcome> => "dismissed"),
      loadMessage: vi.fn(async () => eventRow),
      ...overrides,
    };
  }
  const url = (action: string, conversation = CONVERSATION, proposal = PROPOSAL) => `https://api.example.dev/api/v2/conversations/${conversation}/proposals/${proposal}/${action}`;
  const confirm = (deps: ProposalActionDeps<User>, body: unknown = {}, conversation = CONVERSATION, proposal = PROPOSAL) =>
    handleConfirmProposal(new Request(url("confirm", conversation, proposal), { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) }), conversation, proposal, deps);
  const dismiss = (deps: ProposalActionDeps<User>, conversation = CONVERSATION, proposal = PROPOSAL) =>
    handleDismissProposal(new Request(url("dismiss"), { method: "POST", body: "{}" }), conversation, proposal, deps);

  it("gate가 꺼져 있으면 404 (인증 · 확인 0), 인증 거부 401, 잘못된 id 404, 모르는 본문 400 — 쓰기 0", async () => {
    const off = actionDeps({ enabled: vi.fn(() => false) });
    expect((await confirm(off)).status).toBe(404);
    expect((await dismiss(off)).status).toBe(404);
    for (const fn of [off.authenticate, off.confirm, off.dismiss]) expect(fn).not.toHaveBeenCalled();

    const unauth = actionDeps({ authenticate: vi.fn(async () => null) });
    expect((await confirm(unauth)).status).toBe(401);
    expect((await dismiss(unauth)).status).toBe(401);
    expect(unauth.confirm).not.toHaveBeenCalled();

    const deps = actionDeps();
    expect((await confirm(deps, {}, "not-a-uuid")).status).toBe(404);
    expect((await confirm(deps, {}, CONVERSATION, "nope")).status).toBe(404);
    expect((await dismiss(deps, "x", PROPOSAL)).status).toBe(404);
    expect((await confirm(deps, { extra: 1 })).status).toBe(400);
    expect((await confirm(deps, undefined)).status).toBe(200); // 본문은 없어도 된다
    expect(deps.confirm).toHaveBeenCalledTimes(1);
  });

  it("confirmed · already는 200 { status, op, action_ids, event(기록 줄) }: 두 번 눌러도 같은 모양", async () => {
    const deps = actionDeps();
    const first = await confirm(deps);
    expect(first.status).toBe(200);
    const parsed = proposalConfirmResponseSchema.parse(await first.json());
    expect(parsed).toMatchObject({ status: "confirmed", op: "delete", action_ids: [ACTION], event: { id: EVENT, role: "event", text: "지웠어요: #141" } });
    expect(deps.confirm).toHaveBeenCalledWith(USER, CONVERSATION, PROPOSAL);
    expect(deps.loadMessage).toHaveBeenCalledWith(USER, EVENT);

    const again = actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "already", op: "delete", actionIds: [ACTION], eventId: EVENT })) });
    expect(proposalConfirmResponseSchema.parse(await (await confirm(again)).json()).status).toBe("already");
    // 기록 줄을 찾지 못해도(지워짐) 성공이다
    const lost = actionDeps({ loadMessage: vi.fn(async () => null) });
    expect(proposalConfirmResponseSchema.parse(await (await confirm(lost)).json())).toMatchObject({ status: "confirmed", event: null });
    const noEvent = actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "already", op: "merge", actionIds: [ACTION, id(42, "f0b0c918")], eventId: null })) });
    expect(proposalConfirmResponseSchema.parse(await (await confirm(noEvent)).json())).toMatchObject({ op: "merge", event: null });
    expect(noEvent.loadMessage).not.toHaveBeenCalled();
  });

  it("409: superseded는 쓰기 0 · 새 카드 id를 싣는다 (카드가 없으면 생략), not_open은 취소됐거나 대체된 카드, busy는 busy_retry (다시 보내도 된다)", async () => {
    const superseded = await confirm(actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "superseded", cardMessageId: NEW_CARD })) }));
    expect(superseded.status).toBe(409);
    expect(proposalConflictSchema.parse(await superseded.json())).toMatchObject({ error: { code: "superseded" }, card_message_id: NEW_CARD });
    const none = await confirm(actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "superseded", cardMessageId: null })) }));
    const noneBody = proposalConflictSchema.parse(await none.json());
    expect(noneBody.error.code).toBe("superseded");
    expect(noneBody).not.toHaveProperty("card_message_id");
    const notOpen = await confirm(actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "not_open" })) }));
    expect([notOpen.status, proposalConflictSchema.parse(await notOpen.json()).error.code]).toEqual([409, "not_open"]);
    const busy = await confirm(actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "busy" })) }));
    expect([busy.status, proposalConflictSchema.parse(await busy.json()).error.code]).toEqual([409, "busy_retry"]);
    const gone = await confirm(actionDeps({ confirm: vi.fn(async (): Promise<ConfirmOutcome> => ({ status: "not_found" })) }));
    expect(gone.status).toBe(404);
  });

  it("취소: dismissed · already는 200, not_open은 409, 없음 404", async () => {
    expect(proposalDismissResponseSchema.parse(await (await dismiss(actionDeps())).json())).toEqual({ status: "dismissed" });
    const already = await dismiss(actionDeps({ dismiss: vi.fn(async (): Promise<DismissOutcome> => "already") }));
    expect(proposalDismissResponseSchema.parse(await already.json())).toEqual({ status: "already" });
    const notOpen = await dismiss(actionDeps({ dismiss: vi.fn(async (): Promise<DismissOutcome> => "not_open") }));
    expect([notOpen.status, proposalConflictSchema.parse(await notOpen.json()).error.code]).toEqual([409, "not_open"]);
    expect((await dismiss(actionDeps({ dismiss: vi.fn(async (): Promise<DismissOutcome> => "not_found") }))).status).toBe(404);
  });

  it("예기치 못한 오류는 500이고 오류 이름만 로그에 남긴다 (대화 글 · 제목 없음)", async () => {
    const secret = Object.assign(new Error("제목: 비밀 견적서"), { name: "PostgrestError" });
    const response = await confirm(actionDeps({ confirm: vi.fn(async () => Promise.reject(secret)) }));
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("비밀");
    const logged = errors.mock.calls.map((call: unknown[]) => String(call[0])).join("\n");
    expect(logged).toContain("PostgrestError");
    expect(logged).not.toContain("비밀");
    expect((await dismiss(actionDeps({ dismiss: vi.fn(async () => Promise.reject(secret)) }))).status).toBe(500);
  });
});
