import { answerAgentApproval } from "@/lib/agents/approvals";
import { z } from "zod";

import { AnswerInputError, answerFromRoute, loadAnswerTask, type AnswerTask } from "@/lib/agents/answers";
import { agentSelected, attachmentsFromLegacyRefs, checkAttachments, normalizeAttachments, taskforceContextIds, taskforceRefs, taskforceSelected, type AttachmentCheck } from "@/lib/agents/attachments";
import { createAgentConversation, readConversationTarget, type ConversationTargetInfo } from "@/lib/agents/conversations";
import {
  agentMessageExists,
  deliverAgentMessages,
  loadAgentDeliveries,
  loadAgentDeliveriesByIds,
  loadAgentMessageOutcome,
  postAgentUserMessage,
  recordContextAttached,
  setAgentMessageReferent,
  startAgentMessage,
  type AgentMessageOutcome,
  type PostedAgentMessage,
  type RequeueResult,
} from "@/lib/agents/messages";
import type { AnswerAgentQuestionResult } from "@/lib/agents/questions";
import {
  loadSessionAdapter,
  openAgentSessionExternal,
  renameAgentSession,
  resumeAgentSessionHere,
  type OpenAgentSessionExternalResult,
  type RenameAgentSessionResult,
  type ResumeAgentSessionResult,
} from "@/lib/agents/sessions";
import { startNextAgentMessage } from "@/lib/agents/next-turn";
import { stopAgentSession, type StopAgentSessionResult } from "@/lib/agents/tasks";
import { listAssistantTargets, resolveAgentTarget } from "@/lib/agents/targets";

import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

import { authenticateRequest, type ApiContext } from "./auth";
import { consentRequired } from "./consent";
import {
  agentEmptyRequestSchema,
  answerAgentQuestionRequestSchema,
  deliverAgentMessagesRequestSchema,
  postAgentMessageResponseSchema,
  resumeAgentSessionRequestSchema,
  setReferentRequestSchema,
  updateAgentSessionRequestSchema,
  type AgentDelivery,
  type AssistantTarget,
  type AssistantTargetWithDevice,
  type Attachment,
  type AttachmentDropped,
  type AttachmentKind,
  type AttachmentOrigin,
  type DeliverAgentMessagesResponse,
  type PostConversationMessageV2Request,
} from "./contract";
import type { AgentConversationRef, AgentCreateDelegate, AgentPostDelegate, PostMessageDeps, PreparedAttachments } from "./conversations";
import { hasAiConsent } from "./profile-store";
import { errorResponse, parseBody, unauthorized } from "./respond";

// 에이전트 대상 대화 route 처리 (OA D1d-s, Assistant 계약 v3 2–5장). 인증 · gate · 저장 · 에이전트 호출을 인자로 받아 Route Handler 밖에서 테스트한다 (conversations.ts와 같은 방식).
// 규칙은 SQL 함수와 src/lib/agents/*에 있고 여기는 입구 검증 · 오류 모양 · 응답 조립만 한다. 대화 모듈(src/lib/conversation · api/conversations.ts)은 이 파일을 가져오지 않고,
// 이 파일이 만든 delegate를 route가 주입한다 (I04 · OD-27). 이 경로는 respondToMessage · Jev · LLM을 부르지 않는다 (대상이 명시돼 분류를 건너뛴다).
// 사용자 글 · 칩 id · 답 · 질문은 로그에 남기지 않는다 (이벤트 이름 · 오류 이름 · 코드만).
// gate: CONVERSATIONS_V2_ENABLED가 꺼져 있으면 인증 · DB 전에 404. 에이전트 경로는 그 대화 · 세션 · 연결의 adapter 플래그도 켜져 있어야 한다 (꺼져 있으면 404, OD-2).
// 예외: 대화 Stop · 세션 Stop은 adapter 플래그와 무관하게 돈다 (롤백: 새 전달 gate가 닫혀도 받기 · 멈추기는 계속 된다. 코디네이터 결정). 멈춘 뒤 다음 시작만 adapter 플래그 · EXECUTION_ENABLED를 따른다.

type AppUser = { user: { id: string } };
type Base<User> = { enabled: () => boolean; authenticate: (request: Request) => Promise<User | null> };
export type ConversationAccess = ConversationTargetInfo;
type Adapter = { adapter: string; enabled: boolean };

const NOT_FOUND = "대화가 없습니다.";
const SESSION_NOT_FOUND = "세션이 없습니다.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const notFound = (message = NOT_FOUND) => errorResponse(404, "not_found", message);
const notAgent = () => errorResponse(409, "conflict", "에이전트 대화가 아닙니다.");

function codeOf(error: unknown): string | undefined {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  return typeof code === "string" ? code : undefined;
}

/** 잠금 경합(55P03) · 직렬화 실패(40001) · 교착(40P01)은 쓰기가 롤백됐으니 같은 요청을 다시 보내도 된다 (409 busy_retry, 500 아님). TS 쪽 재시도(retryOnConflict)를 다 쓴 뒤 여기까지 온다. 그 밖은 500 + 이벤트 이름 · 오류 이름 · 코드만 로그 */
function failed(error: unknown, event: string, message: string): Response {
  const code = codeOf(error);
  if (code === "55P03" || code === "40001" || code === "40P01") return errorResponse(409, "busy_retry", "잠시 뒤 다시 시도해 주세요.");
  console.error(JSON.stringify({ event, error: error instanceof Error ? error.name : "unknown", ...(code ? { code } : {}) }));
  return errorResponse(500, "internal_error", message);
}

/** gate → 인증. 꺼져 있으면 인증 · DB 없이 404 */
async function begin<User extends AppUser>(request: Request, deps: Base<User>): Promise<{ user: User } | { response: Response }> {
  if (!deps.enabled()) return { response: errorResponse(404, "not_found", "없는 경로입니다.") };
  const user = await deps.authenticate(request);
  return user ? { user } : { response: unauthorized() };
}

const keyOf = (item: { kind: AttachmentKind; id: string }) => `${item.kind}:${item.id.toLowerCase()}`;

// ─────────────────────────── 보내기: 에이전트 대상 (delegate) ───────────────────────────

export type AgentPostDeps<User> = {
  memoryEnabled: () => boolean;
  /** 연결의 adapter 플래그 (연결이 없거나 registry 밖 adapter면 false) */
  adapterOpen: (user: User, connectionId: string | null) => Promise<boolean>;
  messageExists: (user: User, conversationId: string, clientMessageId: string) => Promise<boolean>;
  checkAttachments: (user: User, attachments: Attachment[]) => Promise<AttachmentCheck>;
  post: (user: User, input: { conversationId: string; clientMessageId: string; text: string; selected: unknown }) => Promise<PostedAgentMessage>;
  recordAttached: (user: User, chips: { kind: AttachmentKind; origin: AttachmentOrigin; sent: boolean }[]) => Promise<void>;
  start: (user: User, conversationId: string, messageId: string) => Promise<unknown>;
  outcome: (user: User, conversationId: string, messageId: string) => Promise<AgentMessageOutcome | null>;
};

/**
 * 에이전트 대상 대화의 메시지 보내기 (계약 2.2): adapter gate → 칩 정규화 → 소유 확인(없는 · 남의 칩 404, 쓰기 0) → 저장(selected = OD-3)
 * → 새 메시지면 칩마다 context_attached → 전달 시작(보낼 차례가 오면) → 다시 읽은 행으로 응답. 동의 확인은 대화 handler가 먼저 한다.
 * auto 칩은 전달 입력(selected의 id 목록)에 넣지 않고 sent=false로 센다 (AC-6). 같은 제출 재전송에서 사라진 칩은 dropped(deleted) — 첫 제출에서는 404 (OD-23)
 */
export function createAgentPostDelegate<User extends AppUser>(deps: AgentPostDeps<User>): AgentPostDelegate<User> {
  return {
    post: async (user: User, conversation: AgentConversationRef, body: PostConversationMessageV2Request): Promise<Response> => {
      try {
        if (!(await deps.adapterOpen(user, conversation.connectionId))) return notFound();
        const attachments = normalizeAttachments(body.attachments ?? attachmentsFromLegacyRefs(body.refs));
        if (!deps.memoryEnabled() && attachments.some((item) => item.kind === "context")) return errorResponse(400, "invalid_request", "범위 기능이 꺼져 있습니다.");

        const known = await deps.messageExists(user, conversation.id, body.client_message_id);
        const check = await deps.checkAttachments(user, attachments);
        if (check.missing.length && !known) return notFound("대상을 찾지 못했습니다.");
        const missing = new Set(check.missing.map(keyOf));
        const purged = new Set(check.purged.map(keyOf));
        const dropped: AttachmentDropped[] = attachments
          .filter((item) => missing.has(keyOf(item)) || purged.has(keyOf(item)))
          .map((item) => ({ kind: item.kind, id: item.id, reason: missing.has(keyOf(item)) ? "deleted" : "slack_purged" }));

        const posted = await deps.post(user, { conversationId: conversation.id, clientMessageId: body.client_message_id, text: body.text, selected: agentSelected(attachments) });
        if (posted.status === "not_found") return notFound();
        if (posted.status === "mismatch") return errorResponse(409, "conflict", "같은 client_message_id로 다른 글을 보냈습니다.");
        if (posted.status === "refs_mismatch") return errorResponse(409, "conflict", "같은 client_message_id로 다른 대상을 보냈습니다.");
        const messageId = posted.messageId!;

        // 새로 저장한 메시지의 칩마다 한 번 (재전송은 다시 세지 않는다). 지표가 빠져도 메시지는 이미 저장됐다
        if (posted.status === "created" && attachments.length) {
          await deps
            .recordAttached(user, attachments.map((item) => ({ kind: item.kind, origin: item.origin, sent: item.origin === "added" && !missing.has(keyOf(item)) && !purged.has(keyOf(item)) })))
            .catch((error: unknown) => {
              console.error(JSON.stringify({ event: "context_attached_failed", error: error instanceof Error ? error.name : "unknown" }));
            });
        }

        await deps.start(user, conversation.id, messageId);
        const outcome = await deps.outcome(user, conversation.id, messageId);
        if (!outcome) return errorResponse(500, "internal_error", "보낸 메시지를 읽지 못했습니다.");
        return Response.json(postAgentMessageResponseSchema.parse({ ...outcome, reply: null, attachments_dropped: dropped }));
      } catch (error) {
        return failed(error, "agent_message_failed", "메시지를 보내지 못했습니다.");
      }
    },
  };
}

// ─────────────────────────── 보내기: taskforce 대상의 칩 (OD-5) ───────────────────────────

export type TaskforceAttachmentDeps<User> = {
  memoryEnabled: () => boolean;
  check: (user: User, attachments: Attachment[]) => Promise<AttachmentCheck>;
};

/**
 * 대상 taskforce의 칩 준비: 정규화 · 범위 기능 확인 · 소유 확인. 저장용 selected는 칩 전체에서(멱등 비교는 처음 제출 그대로),
 * 처리용 refs는 added action · run · execution artifact 중 지금도 있는 것만 지시 대상 규칙 1에 쓴다 (답 생성 불변).
 * known(같은 client_message_id의 메시지가 이미 있음)이면 그 사이 지워진 칩을 404로 막지 않는다 — 같은 제출을 먼저 본다 (검토 반영 7-3, OD-23). 첫 제출은 여전히 missing
 */
export async function prepareTaskforceAttachments<User>(
  deps: TaskforceAttachmentDeps<User>,
  user: User,
  attachments: Attachment[],
  options: { known?: boolean } = {},
): Promise<PreparedAttachments> {
  const chips = normalizeAttachments(attachments);
  if (!deps.memoryEnabled() && chips.some((item) => item.kind === "context")) return { status: "context_off" };
  const check = await deps.check(user, chips);
  if (check.missing.length && !options.known) return { status: "missing" };
  return { status: "ok", refs: taskforceRefs(chips, check), selected: taskforceSelected(chips), attachments: chips, context_ids: taskforceContextIds(chips, check) };
}

// ─────────────────────────── Send again ───────────────────────────

export type DeliverDeps<User> = Base<User> & {
  hasConsent: (user: User) => Promise<boolean>;
  conversation: (user: User, id: string) => Promise<ConversationAccess | null>;
  adapterOpen: (user: User, connectionId: string | null) => Promise<boolean>;
  /** requeue → commit 뒤 다시 대기시킨 메시지를 seq 순으로 하나씩 시작 */
  deliver: (user: User, conversationId: string, messageIds: string[] | undefined) => Promise<RequeueResult>;
  deliveries: (user: User, conversationId: string, messageIds: string[]) => Promise<Record<string, AgentDelivery>>;
};

/** POST /api/v2/conversations/{id}/deliver (계약 2.3): 보류 · 만료 메시지를 다시 보낸다. 두 번 눌러도 새 전달은 한 번뿐이다 (이미 queued · dispatched면 건너뜀) */
export async function handleDeliverAgentMessages<User extends AppUser>(request: Request, conversationId: string, deps: DeliverDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(conversationId)) return notFound();
  const body = await parseBody(request, deliverAgentMessagesRequestSchema);
  if ("error" in body) return body.error;
  try {
    // 다시 보내는 것은 칩이 든 글을 에이전트로 다시 내보내는 일이다: 보낼 때와 같이 동의가 먼저다
    if (!(await deps.hasConsent(user))) return consentRequired();
    const conversation = await deps.conversation(user, conversationId);
    if (!conversation) return notFound();
    if (conversation.targetKind !== "agent") return notAgent();
    if (!(await deps.adapterOpen(user, conversation.connectionId))) return notFound();

    const result = await deps.deliver(user, conversation.id, body.data.message_ids);
    if (result.status === "not_found") return notFound();
    if (result.status === "wrong_target") return notAgent();
    const deliveries = await deps.deliveries(user, conversation.id, result.messages.filter((item) => item.reason !== "not_found").map((item) => item.message_id));
    const messages: DeliverAgentMessagesResponse["messages"] = result.messages.map((item) => ({
      message_id: item.message_id,
      result: item.result,
      ...(item.reason ? { skipped_reason: item.reason } : {}),
      ...(deliveries[item.message_id] ? { delivery: deliveries[item.message_id] } : {}),
    }));
    return Response.json({ messages });
  } catch (error) {
    return failed(error, "agent_deliver_failed", "다시 보내지 못했습니다.");
  }
}

// ─────────────────────────── referent ───────────────────────────

export type ReferentDeps<User> = Base<User> & {
  hasConsent: (user: User) => Promise<boolean>;
  conversation: (user: User, id: string) => Promise<ConversationAccess | null>;
  adapterOpen: (user: User, connectionId: string | null) => Promise<boolean>;
  setReferent: (user: User, conversationId: string, messageId: string, actionId: string) => Promise<"selected" | "not_found" | "already_dispatched" | "expired">;
  start: (user: User, conversationId: string, messageId: string) => Promise<unknown>;
  outcome: (user: User, conversationId: string, messageId: string) => Promise<AgentMessageOutcome | null>;
};

/**
 * POST /api/v2/conversations/{id}/messages/{message_id}/referent (계약 2.4 · AC-4): needs_referent 후보 중 하나를 고르면 같은 메시지를 그대로 한 번 전달한다.
 * 이미 전달됐거나 만료된 메시지는 200 + 계산한 delivery만 돌려준다 (다시 전달하지 않는다)
 */
export async function handleSetReferent<User extends AppUser>(request: Request, conversationId: string, messageId: string, deps: ReferentDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(conversationId) || !UUID.test(messageId)) return notFound();
  const body = await parseBody(request, setReferentRequestSchema);
  if ("error" in body) return body.error;
  try {
    if (!(await deps.hasConsent(user))) return consentRequired();
    const conversation = await deps.conversation(user, conversationId);
    if (!conversation) return notFound();
    if (conversation.targetKind !== "agent") return notAgent();
    if (!(await deps.adapterOpen(user, conversation.connectionId))) return notFound();

    const selected = await deps.setReferent(user, conversation.id, messageId, body.data.action_id);
    if (selected === "not_found") return notFound("메시지나 후보를 찾지 못했습니다.");
    if (selected === "selected") await deps.start(user, conversation.id, messageId);
    const outcome = await deps.outcome(user, conversation.id, messageId);
    if (!outcome) return notFound("메시지를 찾지 못했습니다.");
    return Response.json(postAgentMessageResponseSchema.parse({ ...outcome, reply: null, attachments_dropped: [] }));
  } catch (error) {
    return failed(error, "agent_referent_failed", "대상을 정하지 못했습니다.");
  }
}

// ─────────────────────────── Stop ───────────────────────────

type StopFn<User, Surface extends "assistant" | "session_panel"> = (user: User, sessionId: string, surface: Surface) => Promise<StopAgentSessionResult>;
type AfterStop<User> = (user: User, sessionId: string) => Promise<void>;

/**
 * Stop 응답 만들기 + 로컬에서 확정된 작업이 있으면 commit 뒤 같은 세션의 다음 대기 메시지를 한 번 시작해 본다 (코디네이터 5.1). 그 시작이 실패해도 Stop 결과는 그대로다.
 * Stop 자체는 adapter 플래그와 무관하다(롤백 규칙: 새 전달 gate가 닫혀도 받기 · 멈추기는 계속 된다). 다음 시작(mayStartNext)만 adapter 플래그를 따른다 — 실행 플래그는 startNextAgentMessage가 본다
 */
async function stopResponse<User, Surface extends "assistant" | "session_panel">(
  user: User, sessionId: string, surface: Surface, stop: StopFn<User, Surface>, afterStop: AfterStop<User>, mayStartNext: boolean,
): Promise<Response> {
  const result = await stop(user, sessionId, surface);
  if ("status" in result) return notFound(SESSION_NOT_FOUND);
  if (mayStartNext && result.tasks.some((task) => task.cancel === "confirmed")) {
    await afterStop(user, sessionId).catch((error: unknown) => {
      console.error(JSON.stringify({ event: "agent_stop_next_failed", error: error instanceof Error ? error.name : "unknown" }));
    });
  }
  return Response.json({ tasks: result.tasks });
}

export type StopConversationDeps<User> = Base<User> & {
  conversation: (user: User, id: string) => Promise<ConversationAccess | null>;
  adapterOpen: (user: User, connectionId: string | null) => Promise<boolean>;
  stop: StopFn<User, "assistant">;
  afterStop: AfterStop<User>;
};

/** POST /api/v2/conversations/{id}/stop (계약 5장 · AC-12): 이 대화에 묶인 세션 단위 중단. 세션이 없는 대화는 { tasks: [] } (쓰기 0, OD-19). adapter 플래그가 꺼져 있어도 멈춘다 */
export async function handleStopConversation<User extends AppUser>(request: Request, conversationId: string, deps: StopConversationDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(conversationId)) return notFound();
  const body = await parseBody(request, agentEmptyRequestSchema);
  if ("error" in body) return body.error;
  try {
    const conversation = await deps.conversation(user, conversationId);
    if (!conversation) return notFound();
    if (conversation.targetKind !== "agent") return notAgent();
    if (!conversation.sessionId) return Response.json({ tasks: [] });
    return await stopResponse(user, conversation.sessionId, "assistant", deps.stop, deps.afterStop, await deps.adapterOpen(user, conversation.connectionId));
  } catch (error) {
    return failed(error, "agent_stop_failed", "중단하지 못했습니다.");
  }
}

export type StopSessionDeps<User> = Base<User> & {
  sessionAdapter: (user: User, sessionId: string) => Promise<Adapter | null>;
  stop: StopFn<User, "session_panel">;
  afterStop: AfterStop<User>;
};

/** POST /api/v2/agent-sessions/{id}/stop: 세션 패널의 같은 동작 (surface session_panel). adapter 플래그가 꺼져 있어도 멈춘다 */
export async function handleStopSession<User extends AppUser>(request: Request, sessionId: string, deps: StopSessionDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(sessionId)) return notFound(SESSION_NOT_FOUND);
  const body = await parseBody(request, agentEmptyRequestSchema);
  if ("error" in body) return body.error;
  try {
    const owner = await deps.sessionAdapter(user, sessionId);
    return await stopResponse(user, sessionId, "session_panel", deps.stop, deps.afterStop, owner?.enabled === true);
  } catch (error) {
    return failed(error, "agent_stop_failed", "중단하지 못했습니다.");
  }
}

// ─────────────────────────── 전달 읽기 ───────────────────────────

export type DeliveryReadDeps<User> = Base<User> & {
  conversation: (user: User, id: string) => Promise<ConversationAccess | null>;
  adapterOpen: (user: User, connectionId: string | null) => Promise<boolean>;
  deliveries: (user: User, conversationId: string, sinceSeq: number | undefined) => Promise<{ message_id: string; seq: number; delivery: AgentDelivery }[]>;
};

/** GET /api/v2/conversations/{id}/delivery?since_seq= (OD-13): RLS로 읽은 사용자 메시지의 전달 표시를 서버 계산으로. 읽기만 한다 */
export async function handleGetDeliveries<User extends AppUser>(request: Request, conversationId: string, deps: DeliveryReadDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(conversationId)) return notFound();
  const since = new URL(request.url).searchParams.get("since_seq");
  if (since !== null && !/^\d+$/.test(since)) return errorResponse(400, "invalid_request", "잘못된 필드: since_seq");
  try {
    const conversation = await deps.conversation(user, conversationId);
    if (!conversation) return notFound();
    if (conversation.targetKind !== "agent") return notAgent();
    if (!(await deps.adapterOpen(user, conversation.connectionId))) return notFound();
    return Response.json({ messages: await deps.deliveries(user, conversation.id, since === null ? undefined : Number(since)) });
  } catch (error) {
    return failed(error, "agent_delivery_read_failed", "전달 상태를 읽지 못했습니다.");
  }
}

// ─────────────────────────── 세션 ───────────────────────────

type SessionDeps<User> = Base<User> & { sessionAdapter: (user: User, sessionId: string) => Promise<Adapter | null> };

export type RenameSessionDeps<User> = SessionDeps<User> & { rename: (user: User, sessionId: string, displayName: string) => Promise<RenameAgentSessionResult> };

/** PATCH /api/v2/agent-sessions/{id} (계약 3.8): 세션 이름 (trim 1–200자) */
export async function handleRenameSession<User extends AppUser>(request: Request, sessionId: string, deps: RenameSessionDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(sessionId)) return notFound(SESSION_NOT_FOUND);
  const body = await parseBody(request, updateAgentSessionRequestSchema);
  if ("error" in body) return body.error;
  try {
    const owner = await deps.sessionAdapter(user, sessionId);
    if (!owner?.enabled) return notFound(SESSION_NOT_FOUND);
    const result = await deps.rename(user, sessionId, body.data.display_name);
    return result.status === "not_found" ? notFound(SESSION_NOT_FOUND) : Response.json({ session: result.session });
  } catch (error) {
    return failed(error, "agent_session_rename_failed", "이름을 바꾸지 못했습니다.");
  }
}

export type OpenExternalDeps<User> = SessionDeps<User> & { open: (user: User, sessionId: string) => Promise<OpenAgentSessionExternalResult> };

/** POST /api/v2/agent-sessions/{id}/open-external (계약 3.8 · AC-36): 턴이 돌거나 답을 기다리는 동안은 409 session_busy. bridge 쪽 순서(Codex unsubscribe · 터미널 열기)는 앱이 한다 (OD-22) */
export async function handleOpenExternal<User extends AppUser>(request: Request, sessionId: string, deps: OpenExternalDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(sessionId)) return notFound(SESSION_NOT_FOUND);
  const body = await parseBody(request, agentEmptyRequestSchema);
  if ("error" in body) return body.error;
  try {
    const owner = await deps.sessionAdapter(user, sessionId);
    if (!owner?.enabled) return notFound(SESSION_NOT_FOUND);
    const result = await deps.open(user, sessionId);
    switch (result.status) {
      case "external":
      case "unchanged":
        return Response.json({ session: result.session });
      case "busy":
        return errorResponse(409, "session_busy", "에이전트가 일하고 있거나 답을 기다리고 있습니다.");
      case "not_started":
        return errorResponse(409, "conflict", "아직 첫 턴이 끝나지 않아 터미널에서 열 수 없습니다.");
      case "not_bound":
        return errorResponse(409, "conflict", "이 세션은 터미널에서 열 수 있는 상태가 아닙니다.");
      case "not_found":
        return notFound(SESSION_NOT_FOUND);
    }
  } catch (error) {
    return failed(error, "agent_session_open_failed", "터미널에서 열지 못했습니다.");
  }
}

export type ResumeHereDeps<User> = SessionDeps<User> & { resume: (user: User, sessionId: string) => Promise<ResumeAgentSessionResult> };

/** POST /api/v2/agent-sessions/{id}/resume-here (계약 3.8 · ONE-TF-13 서버 몫): 터미널 세션을 닫았다는 사용자 확인이 본문에 있어야 한다. 되돌린 뒤 대기 메시지는 보낸 순서대로 시작한다 */
export async function handleResumeHere<User extends AppUser>(request: Request, sessionId: string, deps: ResumeHereDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(sessionId)) return notFound(SESSION_NOT_FOUND);
  const body = await parseBody(request, resumeAgentSessionRequestSchema);
  if ("error" in body) return body.error;
  try {
    const owner = await deps.sessionAdapter(user, sessionId);
    if (!owner?.enabled) return notFound(SESSION_NOT_FOUND);
    const result = await deps.resume(user, sessionId);
    if (!("session" in result)) return result.status === "not_found" ? notFound(SESSION_NOT_FOUND) : errorResponse(409, "conflict", "터미널에서 열린 세션이 아닙니다.");
    return Response.json({ session: result.session, started_message_id: result.startedMessageId });
  } catch (error) {
    return failed(error, "agent_session_resume_failed", "다시 가져오지 못했습니다.");
  }
}

// ─────────────────────────── 대상 목록 ───────────────────────────

export type TargetsDeps<User> = Base<User> & { list: (user: User) => Promise<(AssistantTarget | AssistantTargetWithDevice)[]> };

/** GET /api/v2/assistant/targets (계약 4.5): 읽기만 한다 (CSRF 대상이 아니다) */
export async function handleListTargets<User extends AppUser>(request: Request, deps: TargetsDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  try {
    return Response.json({ targets: await deps.list(started.user) });
  } catch (error) {
    return failed(error, "agent_targets_failed", "대상 목록을 읽지 못했습니다.");
  }
}

// ─────────────────────────── 질문 답 ───────────────────────────

export type AnswerDeps<User> = SessionDeps<User> & {
  loadTask: (user: User, taskId: string) => Promise<AnswerTask | null>;
  answerApproval: (user: User, input: { taskId: string; providerRequestId: string; answers: Record<string, string | string[]>; question: unknown }) => Promise<AnswerAgentQuestionResult>;
  answer: (user: User, input: { taskId: string; providerRequestId: string; answers: Record<string, string | string[]>; question: unknown }) => Promise<AnswerAgentQuestionResult>;
};

const questionShape = z.object({ kind: z.enum(["input", "approval"]), questions: z.array(z.object({ secret: z.boolean() }).passthrough()) }).passthrough();

/**
 * POST /api/v2/agent-tasks/{id}/answer (계약 3.6 · OD-14): input 질문에 구조화된 답. 열쇠(question_key)가 다르거나 질문이 없으면 409 question_stale,
 * 승인 답은 lease와 같은 트랜잭션으로 처리하고(D3c-2), 비밀값이 하나라도 섞이면 409 secret_requires_local(RPC 0 — 값은 서버로 오지 않는다).
 * 같은 답을 다시 보내면 이미 답이 간 질문(answered_question)으로 SQL이 duplicate(같은 step)로 수렴시킨다
 */
export async function handleAnswerQuestion<User extends AppUser>(request: Request, taskId: string, deps: AnswerDeps<User>): Promise<Response> {
  const started = await begin(request, deps);
  if ("response" in started) return started.response;
  const { user } = started;
  if (!UUID.test(taskId)) return notFound("작업이 없습니다.");
  const body = await parseBody(request, answerAgentQuestionRequestSchema);
  if ("error" in body) return body.error;
  try {
    const task = await deps.loadTask(user, taskId);
    if (!task) return notFound("작업이 없습니다.");
    const owner = await deps.sessionAdapter(user, task.sessionId);
    if (!owner?.enabled) return notFound("작업이 없습니다.");

    const requestId = body.data.provider_request_id;
    const keyMatches = (candidate: unknown) => {
      const key = candidate !== null && typeof candidate === "object" ? (candidate as { question_key?: unknown }).question_key : undefined;
      return Array.isArray(key) && key.length === 2 && String(key[0]).toLowerCase() === task.id.toLowerCase() && key[1] === requestId;
    };
    const question = keyMatches(task.pendingQuestion) ? task.pendingQuestion : keyMatches(task.answeredQuestion) ? task.answeredQuestion : null;
    if (!question) return errorResponse(409, "question_stale", "이미 닫히거나 바뀐 질문입니다.");
    const shape = questionShape.parse(question);
    let answer = deps.answer;
    if (shape.kind === "approval") {
      if (shape.questions.length !== 1 || shape.questions[0].id !== "approval" || Object.keys(body.data.answers).length !== 1
        || (body.data.answers.approval !== "allow" && body.data.answers.approval !== "deny")) {
        return errorResponse(400, "invalid_request", "답이 질문과 맞지 않습니다.");
      }
      answer = deps.answerApproval;
    }
    if (shape.questions.some((item) => item.secret)) return errorResponse(409, "secret_requires_local", "비밀값은 이 세션을 가진 Mac에서만 답할 수 있습니다.");

    let result: AnswerAgentQuestionResult;
    try {
      result = await answer(user, { taskId: task.id, providerRequestId: requestId, answers: body.data.answers, question });
    } catch (error) {
      if (error instanceof AnswerInputError) return errorResponse(400, "invalid_request", "답이 질문과 맞지 않습니다.");
      throw error;
    }
    switch (result.status) {
      case "answered":
      case "duplicate":
        return Response.json({ status: result.status, step_id: result.step_id });
      case "question_stale":
        return errorResponse(409, "question_stale", "이미 닫히거나 바뀐 질문입니다.");
      case "secret_requires_local":
        return errorResponse(409, "secret_requires_local", "비밀값은 이 세션을 가진 Mac에서만 답할 수 있습니다.");
      case "invalid_answer":
        return errorResponse(400, "invalid_request", "답이 질문과 맞지 않습니다.");
      case "not_found":
        return notFound("작업이 없습니다.");
    }
  } catch (error) {
    return failed(error, "agent_answer_failed", "답을 보내지 못했습니다.");
  }
}

// ─────────────────────────── 실제 의존성 (route가 쓴다) ───────────────────────────
// 아래는 Route Handler에서 handler에 꽂는 서버 구현이다. 대화 route는 @/lib/agents를 직접 가져오지 않고 여기서만 받는다 (OD-27, boundary.test.ts).

const admin = () => createAdminClient();
const gate = () => flagEnabled("CONVERSATIONS_V2_ENABLED");
const base: Base<ApiContext> = { enabled: gate, authenticate: authenticateRequest };

const conversationAccess = async ({ user }: ApiContext, id: string): Promise<ConversationAccess | null> => readConversationTarget(admin(), user.id, id);
/** 그 연결의 adapter 플래그가 켜져 있는가 (연결이 없거나 registry 밖 adapter면 false) */
const adapterOpen = async ({ user }: ApiContext, connectionId: string | null): Promise<boolean> =>
  connectionId !== null && (await resolveAgentTarget(admin(), user.id, connectionId))?.enabled === true;
const sessionAdapter = ({ user }: ApiContext, sessionId: string) => loadSessionAdapter(admin(), user.id, sessionId);
const stopSession = ({ user }: ApiContext, sessionId: string, surface: "assistant" | "session_panel") => stopAgentSession(admin(), { userId: user.id, sessionId, surface });
const afterStop = async ({ user }: ApiContext, sessionId: string): Promise<void> => {
  await startNextAgentMessage(admin(), { userId: user.id, sessionId });
};

/** POST /api/v2/conversations의 agent 대상 delegate */
export function agentCreateDelegate(): AgentCreateDelegate<ApiContext> {
  return {
    create: ({ user }, input) => createAgentConversation(admin(), user.id, input),
    targetKind: async ({ user }, id) => (await readConversationTarget(admin(), user.id, id))?.targetKind ?? null,
  };
}

/** 대화 읽기에 대상 · 연결 · 세션을 더한다 (대화 handler가 에이전트 대상을 delegate로 넘기려고 쓴다) */
export function withConversationTarget(load: PostMessageDeps<ApiContext>["loadConversation"]): PostMessageDeps<ApiContext>["loadConversation"] {
  return async (ctx, id) => {
    const [conversation, target] = await Promise.all([load(ctx, id), readConversationTarget(admin(), ctx.user.id, id)]);
    return conversation && target ? { ...conversation, targetKind: target.targetKind, agentConnectionId: target.connectionId, agentSessionId: target.sessionId } : null;
  };
}

/** POST …/messages의 에이전트 대상 delegate */
export function agentPostDelegate(): AgentPostDelegate<ApiContext> {
  return createAgentPostDelegate<ApiContext>({
    memoryEnabled: () => flagEnabled("MEMORY_ENABLED"),
    adapterOpen,
    messageExists: ({ user }, conversationId, clientMessageId) => agentMessageExists(admin(), user.id, conversationId, clientMessageId),
    checkAttachments: ({ user }, attachments) => checkAttachments(admin(), user.id, attachments),
    post: ({ user }, input) => postAgentUserMessage(admin(), { userId: user.id, ...input }),
    recordAttached: ({ user }, chips) => recordContextAttached(admin(), user.id, "agent", chips),
    start: ({ user }, conversationId, messageId) => startAgentMessage(admin(), { userId: user.id, conversationId, messageId }),
    outcome: ({ user }, conversationId, messageId) => loadAgentMessageOutcome(admin(), user.id, conversationId, messageId),
  });
}

/** POST …/messages의 taskforce 대상 칩 (OD-5) */
export function taskforceAttachmentDeps(): Pick<PostMessageDeps<ApiContext>, "prepareAttachments" | "recordAttachments"> {
  const deps: TaskforceAttachmentDeps<ApiContext> = {
    memoryEnabled: () => flagEnabled("MEMORY_ENABLED"),
    check: ({ user }, attachments) => checkAttachments(admin(), user.id, attachments),
  };
  return {
    prepareAttachments: (ctx, attachments, options) => prepareTaskforceAttachments(deps, ctx, attachments, options),
    recordAttachments: ({ user }, attachments) =>
      recordContextAttached(admin(), user.id, "taskforce", attachments.map((item) => ({ kind: item.kind, origin: item.origin, sent: false }))),
  };
}

export const realDeliverDeps = (): DeliverDeps<ApiContext> => ({
  ...base,
  hasConsent: hasAiConsent,
  conversation: conversationAccess,
  adapterOpen,
  deliver: ({ user }, conversationId, messageIds) => deliverAgentMessages(admin(), { userId: user.id, conversationId, messageIds }),
  deliveries: ({ user }, conversationId, messageIds) => loadAgentDeliveriesByIds(admin(), user.id, conversationId, messageIds),
});

export const realReferentDeps = (): ReferentDeps<ApiContext> => ({
  ...base,
  hasConsent: hasAiConsent,
  conversation: conversationAccess,
  adapterOpen,
  setReferent: ({ user }, conversationId, messageId, actionId) => setAgentMessageReferent(admin(), { userId: user.id, conversationId, messageId, actionId }),
  start: ({ user }, conversationId, messageId) => startAgentMessage(admin(), { userId: user.id, conversationId, messageId }),
  outcome: ({ user }, conversationId, messageId) => loadAgentMessageOutcome(admin(), user.id, conversationId, messageId),
});

export const realStopConversationDeps = (): StopConversationDeps<ApiContext> => ({
  ...base,
  conversation: conversationAccess,
  adapterOpen,
  stop: stopSession,
  afterStop,
});

export const realStopSessionDeps = (): StopSessionDeps<ApiContext> => ({ ...base, sessionAdapter, stop: stopSession, afterStop });

export const realDeliveryReadDeps = (): DeliveryReadDeps<ApiContext> => ({
  ...base,
  conversation: conversationAccess,
  adapterOpen,
  deliveries: ({ user }, conversationId, sinceSeq) => loadAgentDeliveries(admin(), user.id, conversationId, { sinceSeq }),
});

export const realRenameSessionDeps = (): RenameSessionDeps<ApiContext> => ({
  ...base,
  sessionAdapter,
  rename: ({ user }, sessionId, displayName) => renameAgentSession(admin(), user.id, sessionId, displayName),
});

export const realOpenExternalDeps = (): OpenExternalDeps<ApiContext> => ({
  ...base,
  sessionAdapter,
  open: ({ user }, sessionId) => openAgentSessionExternal(admin(), user.id, sessionId),
});

export const realResumeHereDeps = (): ResumeHereDeps<ApiContext> => ({
  ...base,
  sessionAdapter,
  resume: ({ user }, sessionId) => resumeAgentSessionHere(admin(), user.id, sessionId),
});

export const realTargetsDeps = (): TargetsDeps<ApiContext> => ({ ...base, list: ({ user }) => listAssistantTargets(admin(), user.id) });

export const realAnswerDeps = (): AnswerDeps<ApiContext> => ({
  ...base,
  sessionAdapter,
  loadTask: ({ user }, taskId) => loadAnswerTask(admin(), user.id, taskId),
  answerApproval: ({ user }, input) => answerAgentApproval(admin(), { userId: user.id, agentTaskId: input.taskId, providerRequestId: input.providerRequestId, answers: input.answers, question: input.question }),
  answer: ({ user }, input) => answerFromRoute(admin(), { userId: user.id, agentTaskId: input.taskId, providerRequestId: input.providerRequestId, answers: input.answers, question: input.question }),
});
