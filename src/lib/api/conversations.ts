import { AiBudgetError } from "@/lib/ai/budget-error";
import { DeadlineExceededError } from "@/lib/ai/deadline";
import { JevError } from "@/lib/ai/jev";
import { LlmError } from "@/lib/ai/llm";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { RespondInput, TurnPlan, WindowMessage } from "@/lib/conversation/respond";
import { normalizeSelected, type SelectedRefs, type Target } from "@/lib/conversation/referent";
import { ConsultOutputError } from "@/lib/conversation/respond";

import { aiBudgetErrorResponse } from "./ai-budget";
import { consentRequired } from "./consent";
import {
  createConversationRequestSchema,
  postConversationMessageRequestSchema,
  type Conversation,
  type ConversationMessage,
  type CreateConversationRequest,
  type CreateConversationResponse,
  type PostConversationMessageRequest,
  type PostConversationMessageResponse,
} from "./contract";
import { retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody, unauthorized } from "./respond";

// /api/v2/conversations 처리 (구현 계획 B2). 인증 · gate · 동의 · 대상 확인 · 저장 · 답을 인자로 받아 Route Handler 밖에서 테스트한다.
// 사용자 글 · 답은 로그에 남기지 않는다 (오류 이름 · 단계만).
// gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404: 인증 · DB · 모델을 부르지 않는다 (v1 Ask만 있다).

const NOT_FOUND = "대화가 없습니다.";

type AppUser = { user: { id: string } };

// ─── 대화 만들기 ─────────────────────────────────────

export type CreateConversationDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  create: (
    user: User,
    input: CreateConversationRequest,
  ) => Promise<{ status: "created" | "existing"; conversation: Conversation } | { status: "id_taken" | "context_not_found" | "context_off" }>;
};

export async function handleCreateConversation<User extends AppUser>(request: Request, deps: CreateConversationDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, createConversationRequestSchema);
  if ("error" in body) return body.error;
  try {
    const result = await deps.create(user, body.data);
    switch (result.status) {
      case "created":
      case "existing":
        return Response.json({ conversation: result.conversation } satisfies CreateConversationResponse, { status: result.status === "created" ? 201 : 200 });
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

// ─── 메시지 보내기 ───────────────────────────────────

export type PostResult = {
  status: "created" | "retry" | "answered" | "in_progress" | "mismatch" | "refs_mismatch" | "stale" | "not_found";
  messageId: string | null;
  seq: number | null;
  replyId: string | null;
};
export type FinishResult = { status: "written" | "answered" | "stale" | "conflict" | "not_found"; replyId: string | null };

export type PostMessageDeps<User extends AppUser> = {
  enabled: () => boolean;
  memoryEnabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 남기고 null (모델을 부르기 전에) */
  rateLimit: (user: User) => Promise<Date | null>;
  loadConversation: (user: User, conversationId: string) => Promise<{ id: string; contextId: string | null; contextName: string | null } | null>;
  verifySelected: (user: User, refs: PostConversationMessageRequest["refs"]) => Promise<{ targets: Target[] } | { missing: true }>;
  /** 이 대화에 같은 client_message_id의 사용자 메시지가 이미 있는가 (한도를 저장 전에 셀지 정한다) */
  messageExists: (user: User, conversationId: string, clientMessageId: string) => Promise<boolean>;
  /** selected: 앱이 고른 대상(정렬 · 중복 제거). 같은 client_message_id라도 글이나 대상이 다르면 mismatch */
  post: (user: User, conversationId: string, clientMessageId: string, text: string, selected: SelectedRefs) => Promise<PostResult>;
  loadMessage: (user: User, messageId: string) => Promise<ConversationMessage | null>;
  loadWindow: (user: User, conversationId: string, uptoSeq: number) => Promise<{ messages: WindowMessage[]; omitted: number }>;
  /** 답 만들기 (모델 · 기록 읽기를 묶은 respondToMessage) */
  respond: (user: User, input: RespondInput) => Promise<TurnPlan>;
  finish: (user: User, messageId: string, plan: TurnPlan) => Promise<FinishResult>;
  release: (user: User, messageId: string) => Promise<void>;
  onDeadlineExceeded?: (error: DeadlineExceededError) => void;
  now?: () => Date;
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
  const body = await parseBody(request, postConversationMessageRequestSchema);
  if ("error" in body) return body.error;
  // 메시지와 할 일 · 기억 · 원문 발췌를 외부 AI로 보내므로 동의가 먼저다 (동의 전에는 저장도 하지 않는다)
  if (!(await deps.hasConsent(user))) return consentRequired();

  let leased: string | null = null;
  try {
    const conversation = await deps.loadConversation(user, conversationId);
    if (!conversation) return errorResponse(404, "not_found", NOT_FOUND);
    // 앱이 보낸 대상은 모두 내 것이어야 한다: 남의 id로 대상 · 권한을 얻지 못한다
    const selected = await deps.verifySelected(user, body.data.refs);
    if ("missing" in selected) return errorResponse(404, "not_found", "대상을 찾지 못했습니다.");

    // 한도: 새 제출이면 저장하기 전에 센다(한도에 걸린 메시지를 남기지 않는다). 같은 제출의 재전송(저장된 답 · 처리 중)은 세지 않고,
    // 답을 못 받은 같은 제출을 다시 처리할 때(retry)만 저장 뒤에 센다
    const tooMany = (retryAt: Date) => {
      const response = errorResponse(429, "rate_limited", "메시지가 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, deps.now?.() ?? new Date())));
      return response;
    };
    const known = await deps.messageExists(user, conversation.id, body.data.client_message_id);
    if (!known) {
      const retryAt = await deps.rateLimit(user);
      if (retryAt) return tooMany(retryAt);
    }

    // 고른 대상도 같은 제출의 일부다: 처음 고른 대상이 메시지에 남고, 다시 보낼 때 다르면 mismatch (다시 처리할 때도 처음 대상과 같은 것만 받는다)
    const posted = await deps.post(user, conversation.id, body.data.client_message_id, body.data.text, normalizeSelected(body.data.refs));
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

    if (known && posted.status === "retry") {
      const retryAt = await deps.rateLimit(user);
      if (retryAt) {
        await deps.release(user, messageId);
        leased = null;
        return tooMany(retryAt);
      }
    }

    // 채택 경합(그 사이 같은 제안이 채택됨)이면 한 번 다시 읽어 답한다. 기억 경합은 다시 보내게 한다(모델을 다시 부르지 않는다)
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
        selected: selected.targets,
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
          if (plan.adopt && attempt === 0) continue;
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
