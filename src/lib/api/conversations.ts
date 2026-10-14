import { AiBudgetError } from "@/lib/ai/budget-error";
import { DeadlineExceededError } from "@/lib/ai/deadline";
import { JevError } from "@/lib/ai/jev";
import { LlmError } from "@/lib/ai/llm";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { ConfirmOutcome, DismissOutcome } from "@/lib/conversation/organize";
import type { RespondInput, TurnPlan, WindowMessage } from "@/lib/conversation/respond";
import { normalizeSelected, type SelectedRefs, type Target } from "@/lib/conversation/referent";
import { ConsultOutputError } from "@/lib/conversation/respond";

import { aiBudgetErrorResponse } from "./ai-budget";
import { consentRequired } from "./consent";
import {
  createConversationV2RequestSchema,
  postConversationMessageV2RequestSchema,
  proposalActionRequestSchema,
  proposalConfirmResponseSchema,
  proposalConflictSchema,
  proposalDismissResponseSchema,
  updateConversationRequestSchema,
  type Attachment,
  type Conversation,
  type ConversationMessage,
  type ConversationTargetKind,
  type ConversationWithTarget,
  type CreateConversationRequest,
  type CreateConversationV2Response,
  type PostConversationMessageResponse,
  type PostConversationMessageV2Request,
  type UpdateConversationResponse,
} from "./contract";
import { retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody, unauthorized } from "./respond";

// /api/v2/conversations 처리 (구현 계획 B2). 인증 · gate · 동의 · 대상 확인 · 저장 · 답을 인자로 받아 Route Handler 밖에서 테스트한다.
// 사용자 글 · 답은 로그에 남기지 않는다 (오류 이름 · 단계만).
// gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404: 인증 · DB · 모델을 부르지 않는다 (v1 Ask만 있다).
// 에이전트 대상 대화(OA D1d, Assistant 계약 v3)는 이 파일이 직접 다루지 않는다: 주입된 delegate(deps.agent)로만 넘긴다 (I04 · OD-27 — 대화 모듈은 @/lib/agents를 가져오지 않는다).
// delegate가 주입되지 않으면 에이전트 대상은 404다. 대상 taskforce의 응답 모양은 그대로다(만들기 응답만 대상 열이 붙는다).

const NOT_FOUND = "대화가 없습니다.";

type AppUser = { user: { id: string } };

// ─── 대화 만들기 ─────────────────────────────────────

export type AgentCreateResult =
  | { status: "created" | "existing"; conversation: ConversationWithTarget }
  | { status: "id_taken" | "context_not_found" | "context_off" | "target_mismatch" | "not_found" };

/** 에이전트 대상 만들기 delegate (src/lib/api/agent-conversations.ts가 구현한다) */
export type AgentCreateDelegate<User> = {
  create: (user: User, input: { id?: string; title?: string; contextId: string | null; connectionId: string; sessionId?: string }) => Promise<AgentCreateResult>;
  /** 같은 id의 내 대화가 있으면 그 대상 (taskforce 요청이 기존 에이전트 대화를 가리키면 target_mismatch) */
  targetKind: (user: User, conversationId: string) => Promise<ConversationTargetKind | null>;
};

export type CreateConversationDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  create: (
    user: User,
    input: CreateConversationRequest,
  ) => Promise<{ status: "created" | "existing"; conversation: Conversation } | { status: "id_taken" | "context_not_found" | "context_off" }>;
  agent?: AgentCreateDelegate<User>;
};

export async function handleCreateConversation<User extends AppUser>(request: Request, deps: CreateConversationDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, createConversationV2RequestSchema);
  if ("error" in body) return body.error;
  const { target, ...input } = body.data;
  try {
    if (target?.kind === "agent") {
      if (!deps.agent) return errorResponse(404, "not_found", "없는 경로입니다.");
      const created = await deps.agent.create(user, { id: input.id, title: input.title, contextId: input.context_id ?? null, connectionId: target.connection_id, sessionId: target.session_id });
      switch (created.status) {
        case "created":
        case "existing":
          return Response.json({ conversation: created.conversation } satisfies CreateConversationV2Response, { status: created.status === "created" ? 201 : 200 });
        case "id_taken":
          return errorResponse(409, "conflict", "이미 쓰인 대화 id입니다. 다른 id로 만들어 주세요.");
        case "target_mismatch":
          return errorResponse(409, "target_mismatch", "같은 id의 대화가 다른 대상으로 이미 있습니다.");
        case "not_found":
          return errorResponse(404, "not_found", "연결이나 세션이 없습니다.");
        case "context_not_found":
          return errorResponse(404, "not_found", "범위가 없습니다.");
        case "context_off":
          return errorResponse(400, "invalid_request", "범위 기능이 꺼져 있습니다.");
      }
    }
    const result = await deps.create(user, input);
    switch (result.status) {
      case "created":
      case "existing": {
        // 같은 id의 기존 대화가 에이전트 대상이면 taskforce 요청으로 열 수 없다 (대상은 바뀌지 않는다)
        if (result.status === "existing" && (await deps.agent?.targetKind(user, result.conversation.id)) === "agent") {
          return errorResponse(409, "target_mismatch", "같은 id의 대화가 다른 대상으로 이미 있습니다.");
        }
        const conversation: ConversationWithTarget = { ...result.conversation, target_kind: "taskforce", agent_connection_id: null, agent_session_id: null };
        return Response.json({ conversation } satisfies CreateConversationV2Response, { status: result.status === "created" ? 201 : 200 });
      }
      case "id_taken":
        return errorResponse(409, "conflict", "이미 쓰인 대화 id입니다. 다른 id로 만들어 주세요.");
      case "context_not_found":
        return errorResponse(404, "not_found", "범위가 없습니다.");
      case "context_off":
        return errorResponse(400, "invalid_request", "범위 기능이 꺼져 있습니다.");
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "conversation_create_failed", error: error instanceof Error ? error.name : "unknown" }));
    return errorResponse(500, "internal_error", "대화를 만들지 못했습니다.");
  }
}

// ─── 대화 범위 바꾸기 (B3) ─────────────────────────────

export type UpdateConversationDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  /** 범위를 고른 것으로 바꾼다. 남의 · 없는 대화 not_found, 내 active 범위가 아니면 context_not_found, 범위 기능이 꺼져 있으면 context_off (null로 되돌리기는 늘 된다) */
  update: (
    user: User,
    conversationId: string,
    contextId: string | null,
  ) => Promise<{ status: "updated" | "unchanged"; conversation: Conversation } | { status: "not_found" | "context_not_found" | "context_off" }>;
};

/**
 * PATCH /api/v2/conversations/{id}: 대화 헤더 ProjectLink에서 사용자가 명시적으로 고른 범위 ({ context_id: uuid | null }, null = All work).
 * 자동 범위 추정 · 멤버십 쓰기 · 기억 쓰기가 없다. gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404 (인증 · DB를 부르지 않는다)
 */
export async function handleUpdateConversation<User extends AppUser>(request: Request, conversationId: string, deps: UpdateConversationDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(conversationId)) return errorResponse(404, "not_found", NOT_FOUND);
  const body = await parseBody(request, updateConversationRequestSchema);
  if ("error" in body) return body.error;
  try {
    const result = await deps.update(user, conversationId, body.data.context_id);
    switch (result.status) {
      case "updated":
      case "unchanged":
        return Response.json({ conversation: result.conversation } satisfies UpdateConversationResponse);
      case "not_found":
        return errorResponse(404, "not_found", NOT_FOUND);
      case "context_not_found":
        return errorResponse(404, "not_found", "범위가 없습니다.");
      case "context_off":
        return errorResponse(400, "invalid_request", "범위 기능이 꺼져 있습니다.");
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "conversation_update_failed", error: error instanceof Error ? error.name : "unknown" }));
    return errorResponse(500, "internal_error", "대화를 바꾸지 못했습니다.");
  }
}

// ─── 메시지 보내기 ───────────────────────────────────

export type PostResult = {
  status: "created" | "retry" | "answered" | "in_progress" | "mismatch" | "refs_mismatch" | "stale" | "not_found";
  messageId: string | null;
  seq: number | null;
  replyId: string | null;
};
export type FinishResult = { status: "written" | "answered" | "stale" | "conflict" | "not_found"; replyId: string | null };

/** 에이전트 대상 대화 (OA D1d): 연결 · 세션은 delegate가 gate와 전달에 쓴다 */
export type AgentConversationRef = { id: string; connectionId: string | null; sessionId: string | null };

/** 에이전트 대상 보내기 delegate (src/lib/api/agent-conversations.ts가 구현한다): 칩 확인 · 저장 · 전달 시작 · 응답까지 맡고 Response를 돌려준다. respondToMessage · Jev · LLM을 부르지 않는다 */
export type AgentPostDelegate<User> = {
  post: (user: User, conversation: AgentConversationRef, body: PostConversationMessageV2Request) => Promise<Response>;
};

/** 대상 taskforce의 칩 준비 결과 (OD-5): refs = 지시 대상 규칙 1에 쓰는 added action · run · artifact, selected = 같은 제출 비교에 저장하는 전체(정규화한 칩 포함), context_ids = 살아 있는 added context 칩(이슈 정리의 프로젝트 지칭, D4c-2) */
export type PreparedAttachments =
  | { status: "ok"; refs: SelectedRefs; selected: SelectedRefs & { attachments?: Attachment[] }; attachments: Attachment[]; context_ids?: string[] }
  | { status: "missing" | "context_off" };

export type PostMessageDeps<User extends AppUser> = {
  enabled: () => boolean;
  memoryEnabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 남기고 null (모델을 부르기 전에) */
  rateLimit: (user: User) => Promise<Date | null>;
  /** targetKind가 없으면 taskforce. 에이전트 대화는 연결 · 세션 id를 함께 돌려준다 */
  loadConversation: (
    user: User,
    conversationId: string,
  ) => Promise<{ id: string; contextId: string | null; contextName: string | null; targetKind?: ConversationTargetKind; agentConnectionId?: string | null; agentSessionId?: string | null } | null>;
  /** refs: 정규화한 선택(normalizeSelected). 하나라도 내 것이 아니면 missing */
  verifySelected: (user: User, refs: SelectedRefs) => Promise<{ targets: Target[] } | { missing: true }>;
  /**
   * attachments(맥락 칩)를 정규화하고 종류별 소유를 확인한다. 없는 · 남의 칩이 하나라도 있으면 missing, 범위 칩은 MEMORY_ENABLED가 꺼져 있으면 context_off.
   * known: 같은 client_message_id의 메시지가 이미 있다(같은 제출 재전송) — 그 사이 지워진 칩은 missing으로 막지 않고 처리 입력에서만 뺀다 (검토 반영 7-3)
   */
  prepareAttachments?: (user: User, attachments: Attachment[], options: { known: boolean }) => Promise<PreparedAttachments>;
  /** 새로 저장한 메시지의 칩마다 측정 이벤트 한 줄 (context_attached). 실패해도 메시지는 남는다 */
  recordAttachments?: (user: User, attachments: Attachment[]) => Promise<void>;
  /** 이 대화에 같은 client_message_id의 사용자 메시지가 이미 있는가 (한도를 저장 전에 셀지 정한다) */
  messageExists: (user: User, conversationId: string, clientMessageId: string) => Promise<boolean>;
  /** selected: 앱이 고른 대상(정렬 · 중복 제거). 같은 client_message_id라도 글이나 대상이 다르면 mismatch */
  post: (user: User, conversationId: string, clientMessageId: string, text: string, selected: SelectedRefs & { attachments?: Attachment[] }) => Promise<PostResult>;
  loadMessage: (user: User, messageId: string) => Promise<ConversationMessage | null>;
  loadWindow: (user: User, conversationId: string, uptoSeq: number) => Promise<{ messages: WindowMessage[]; omitted: number }>;
  /** 답 만들기 (모델 · 기록 읽기를 묶은 respondToMessage) */
  respond: (user: User, input: RespondInput) => Promise<TurnPlan>;
  finish: (user: User, messageId: string, plan: TurnPlan) => Promise<FinishResult>;
  release: (user: User, messageId: string) => Promise<void>;
  onDeadlineExceeded?: (error: DeadlineExceededError) => void;
  now?: () => Date;
  /** 에이전트 대상 대화의 보내기. 주입되지 않으면 에이전트 대상은 404 */
  agent?: AgentPostDelegate<User>;
};

const conflict = (message: string) => errorResponse(409, "conflict", message);

export async function handlePostConversationMessage<User extends AppUser>(
  request: Request,
  conversationId: string,
  deps: PostMessageDeps<User>,
): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(conversationId)) return errorResponse(404, "not_found", NOT_FOUND);
  const body = await parseBody(request, postConversationMessageV2RequestSchema);
  if ("error" in body) return body.error;
  // 메시지와 할 일 · 기억 · 원문 발췌를 외부 AI로 보내므로 동의가 먼저다 (동의 전에는 저장도 하지 않는다)
  if (!(await deps.hasConsent(user))) return consentRequired();

  let leased: string | null = null;
  try {
    const conversation = await deps.loadConversation(user, conversationId);
    if (!conversation) return errorResponse(404, "not_found", NOT_FOUND);
    // 에이전트 대상: 사용자의 글은 그 에이전트 세션으로 그대로 간다. Taskforce 모델(분류 · 상담)은 부르지 않는다 (계약 3.2) — delegate가 맡는다
    if (conversation.targetKind === "agent") {
      if (!deps.agent) return errorResponse(404, "not_found", NOT_FOUND);
      return await deps.agent.post(user, { id: conversation.id, connectionId: conversation.agentConnectionId ?? null, sessionId: conversation.agentSessionId ?? null }, body.data);
    }
    // 앱이 보낸 대상은 모두 내 것이어야 한다: 남의 id로 대상 · 권한을 얻지 못한다.
    // 소유를 확인하기 전에 한 번 정규화한다(소문자 · 중복 제거 · 정렬): 대소문자만 다른 같은 uuid를 두 대상으로 세어 404를 내지 않고, 확인 · 저장 · 답이 같은 선택을 쓴다
    // attachments(맥락 칩, OD-5)는 종류별 소유를 확인해 저장한다. added action · run · artifact만 지금의 지시 대상 규칙 1에 쓰고, 나머지는 저장만 한다 (답 생성 불변)
    let refs = normalizeSelected(body.data.refs);
    let stored: SelectedRefs & { attachments?: Attachment[] } = refs;
    let chips: Attachment[] = [];
    let contextIds: string[] = [];
    let knownEarly: boolean | null = null;
    if (body.data.attachments?.length) {
      if (!deps.prepareAttachments) return errorResponse(400, "invalid_request", "맥락 칩을 받지 않습니다.");
      // 같은 제출인지를 칩 존재 확인보다 먼저 본다: 재전송이면 그 사이 지워진 칩 때문에 404가 되지 않고 저장된 응답을 돌려준다 (OD-23)
      knownEarly = await deps.messageExists(user, conversation.id, body.data.client_message_id);
      const prepared = await deps.prepareAttachments(user, body.data.attachments, { known: knownEarly });
      if (prepared.status !== "ok") {
        return prepared.status === "context_off" ? errorResponse(400, "invalid_request", "범위 기능이 꺼져 있습니다.") : errorResponse(404, "not_found", "대상을 찾지 못했습니다.");
      }
      ({ refs, selected: stored, attachments: chips } = prepared);
      contextIds = prepared.context_ids ?? [];
    }
    const verified = await deps.verifySelected(user, refs);
    if ("missing" in verified) return errorResponse(404, "not_found", "대상을 찾지 못했습니다.");

    // 한도: 새 제출이면 저장하기 전에 센다(한도에 걸린 메시지를 남기지 않는다). 같은 제출의 재전송(저장된 답 · 처리 중)은 세지 않고,
    // 답을 못 받은 같은 제출을 다시 처리할 때(retry)만 저장 뒤에 센다
    const tooMany = (retryAt: Date) => {
      const response = errorResponse(429, "rate_limited", "메시지가 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, deps.now?.() ?? new Date())));
      return response;
    };
    const known = knownEarly ?? (await deps.messageExists(user, conversation.id, body.data.client_message_id));
    if (!known) {
      const retryAt = await deps.rateLimit(user);
      if (retryAt) return tooMany(retryAt);
    }

    // 고른 대상도 같은 제출의 일부다: 처음 고른 대상이 메시지에 남고, 다시 보낼 때 다르면 mismatch (다시 처리할 때도 처음 대상과 같은 것만 받는다)
    const posted = await deps.post(user, conversation.id, body.data.client_message_id, body.data.text, stored);
    switch (posted.status) {
      case "not_found":
        return errorResponse(404, "not_found", NOT_FOUND);
      case "answered":
        return await pairResponse(deps, user, posted.messageId!, posted.replyId!);
      case "in_progress":
        return conflict("같은 메시지를 처리하고 있습니다.");
      case "mismatch":
        return conflict("같은 client_message_id로 다른 글을 보냈습니다.");
      case "refs_mismatch":
        return conflict("같은 client_message_id로 다른 대상을 보냈습니다.");
      case "stale":
        return conflict("이 메시지 뒤에 새 메시지가 있어 답하지 않았습니다.");
    }
    const messageId = posted.messageId!;
    const seq = posted.seq!;
    leased = messageId;

    // 칩 측정은 새로 저장한 메시지에서만 한 번 (재전송 · 재처리는 다시 세지 않는다). 실패해도 메시지는 이미 저장됐다
    if (posted.status === "created" && chips.length && deps.recordAttachments) {
      await deps.recordAttachments(user, chips).catch((error: unknown) => {
        console.error(JSON.stringify({ event: "context_attached_failed", error: error instanceof Error ? error.name : "unknown" }));
      });
    }

    if (known && posted.status === "retry") {
      const retryAt = await deps.rateLimit(user);
      if (retryAt) {
        await deps.release(user, messageId);
        leased = null;
        return tooMany(retryAt);
      }
    }

    // 채택 경합(그 사이 같은 제안이 채택됨)이면 한 번 다시 읽어 답한다. 말로 이동의 범위 version 경합도 한 번 다시 읽은 version으로 (D4c-2). 기억 경합은 다시 보내게 한다(모델을 다시 부르지 않는다)
    for (let attempt = 0; attempt < 2; attempt++) {
      const window = await deps.loadWindow(user, conversation.id, seq);
      const current = window.messages.find((m) => m.id === messageId);
      if (!current) {
        await deps.release(user, messageId);
        leased = null;
        return errorResponse(404, "not_found", NOT_FOUND);
      }
      const plan = await deps.respond(user, {
        userId: user.user.id,
        conversation,
        message: { id: messageId, seq, text: current.text, createdAt: current.createdAt },
        window: window.messages,
        omitted: window.omitted,
        selected: verified.targets,
        selectedContexts: contextIds,
        flags: { memory: deps.memoryEnabled() },
        now: deps.now?.() ?? new Date(),
      });
      const finished = await deps.finish(user, messageId, plan);
      switch (finished.status) {
        case "written":
        case "answered":
          leased = null;
          return await pairResponse(deps, user, messageId, finished.replyId!);
        case "stale":
          leased = null;
          return conflict("이 메시지 뒤에 새 메시지가 있어 답하지 않았습니다.");
        case "not_found":
          await deps.release(user, messageId);
          leased = null;
          return errorResponse(404, "not_found", NOT_FOUND);
        case "conflict":
          leased = null;
          if ((plan.adopt || plan.move) && attempt === 0) continue;
          return conflict("그 사이 기억이나 제안이 바뀌었습니다. 다시 보내 주세요.");
      }
    }
    return conflict("그 사이 기억이나 제안이 바뀌었습니다. 다시 보내 주세요.");
  } catch (error) {
    if (leased) await deps.release(user, leased).catch(() => undefined);
    // 답을 만드는 도중에 동의를 철회함 (모델 호출 직전 확인, lib/consent)
    if (error instanceof ConsentRequiredError) return consentRequired();
    if (error instanceof AiBudgetError) return aiBudgetErrorResponse(error);
    if (error instanceof DeadlineExceededError) {
      deps.onDeadlineExceeded?.(error);
      return errorResponse(504, "ai_timeout", "AI 응답이 늦어졌습니다. 다시 보내 주세요.");
    }
    if (error instanceof LlmError || error instanceof JevError || error instanceof ConsultOutputError) {
      console.error(JSON.stringify({ event: "conversation_failed", error: error.name }));
      return errorResponse(503, "ai_unavailable", "답을 만들지 못했습니다. 다시 보내 주세요.");
    }
    console.error(JSON.stringify({ event: "conversation_failed", error: error instanceof Error ? error.name : "unknown" }));
    return errorResponse(500, "internal_error", "답을 만들지 못했습니다.");
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 저장된 사용자 메시지 + 답 (같은 제출을 다시 보내도 같은 답) */
async function pairResponse<User extends AppUser>(deps: PostMessageDeps<User>, user: User, messageId: string, replyId: string): Promise<Response> {
  const [message, reply] = await Promise.all([deps.loadMessage(user, messageId), deps.loadMessage(user, replyId)]);
  if (!message || !reply || reply.role !== "assistant") return errorResponse(500, "internal_error", "답을 읽지 못했습니다.");
  const body: PostConversationMessageResponse = {
    message,
    reply: { ...reply, role: "assistant", segments: reply.content?.segments ?? [], citations: reply.content?.citations ?? [] },
  };
  return Response.json(body);
}

// ─── 삭제 · 병합 확인 카드의 버튼 (D4c-2) ─────────────────

export type ProposalActionDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  /** 확인: 카드를 읽고 쓰기 계획을 세워 conversation_confirm_proposal 한 트랜잭션으로 쓴다 (store.confirmProposal). AI를 부르지 않는다 */
  confirm: (user: User, conversationId: string, proposalId: string) => Promise<ConfirmOutcome>;
  dismiss: (user: User, conversationId: string, proposalId: string) => Promise<DismissOutcome>;
  /** 응답에 싣는 기록 줄(role event) 읽기 */
  loadMessage: (user: User, messageId: string) => Promise<ConversationMessage | null>;
};

const proposalConflict = (code: "superseded" | "not_open" | "busy_retry", message: string, cardMessageId?: string | null) =>
  Response.json(proposalConflictSchema.parse({ error: { code, message }, ...(cardMessageId ? { card_message_id: cardMessageId } : {}) }), { status: 409 });

async function proposalAction<User extends AppUser>(
  request: Request,
  conversationId: string,
  proposalId: string,
  deps: ProposalActionDeps<User>,
  event: string,
  run: (user: User) => Promise<Response>,
): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(conversationId) || !UUID.test(proposalId)) return errorResponse(404, "not_found", NOT_FOUND);
  const body = await parseBody(request, proposalActionRequestSchema);
  if ("error" in body) return body.error;
  try {
    return await run(user);
  } catch (error) {
    // 오류 이름만 남긴다 (대화 글 · 이슈 제목 없음)
    console.error(JSON.stringify({ event, error: error instanceof Error ? error.name : "unknown" }));
    return errorResponse(500, "internal_error", "처리하지 못했습니다.");
  }
}

/**
 * POST /api/v2/conversations/{id}/proposals/{proposal_id}/confirm: 삭제 · 병합 카드의 Delete · Merge 버튼. 두 번 눌러도 쓰기 한 번(200 already).
 * 409 superseded = 대상이 카드 뒤에 바뀜(쓰기 0, 새 카드가 대화에 있다: 앱은 대화를 다시 읽는다) · not_open = 취소됐거나 다른 제안으로 대체됨 · busy_retry = 잠금 경합(쓰기 0, 다시 보내도 된다). 404 = 없는 · 남의 · 삭제/병합이 아닌 제안.
 * gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404 (인증 · DB 0). 동의 검사 · 요청 한도는 없다 (외부 AI를 부르지 않고 멱등이다).
 */
export async function handleConfirmProposal<User extends AppUser>(request: Request, conversationId: string, proposalId: string, deps: ProposalActionDeps<User>): Promise<Response> {
  return proposalAction(request, conversationId, proposalId, deps, "proposal_confirm_failed", async (user) => {
    const outcome = await deps.confirm(user, conversationId, proposalId);
    switch (outcome.status) {
      case "confirmed":
      case "already": {
        const event = outcome.eventId ? await deps.loadMessage(user, outcome.eventId) : null;
        return Response.json(proposalConfirmResponseSchema.parse({ status: outcome.status, op: outcome.op, action_ids: outcome.actionIds, event }));
      }
      case "superseded":
        return proposalConflict("superseded", "대상이 바뀌어 쓰지 않았습니다. 새 카드를 확인해 주세요.", outcome.cardMessageId);
      case "not_open":
        return proposalConflict("not_open", "이미 취소됐거나 다른 제안으로 바뀐 카드입니다.");
      case "busy":
        return proposalConflict("busy_retry", "잠시 뒤 다시 시도해 주세요.");
      case "not_found":
        return errorResponse(404, "not_found", NOT_FOUND);
    }
  });
}

/** POST …/proposals/{proposal_id}/dismiss: 카드의 Cancel 버튼. 열린 카드만 dismissed로 (쓰기 0). 이미 취소했으면 200 already, 확인했거나 대체된 카드는 409 not_open */
export async function handleDismissProposal<User extends AppUser>(request: Request, conversationId: string, proposalId: string, deps: ProposalActionDeps<User>): Promise<Response> {
  return proposalAction(request, conversationId, proposalId, deps, "proposal_dismiss_failed", async (user) => {
    const outcome = await deps.dismiss(user, conversationId, proposalId);
    switch (outcome) {
      case "dismissed":
      case "already":
        return Response.json(proposalDismissResponseSchema.parse({ status: outcome }));
      case "not_open":
        return proposalConflict("not_open", "이미 확인했거나 다른 제안으로 바뀐 카드입니다.");
      case "not_found":
        return errorResponse(404, "not_found", NOT_FOUND);
    }
  });
}
