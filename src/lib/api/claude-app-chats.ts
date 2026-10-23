import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { retryOnConflict } from "@/lib/agents/retry";
import { agentBetaUserAllowed, flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

import { authenticateRequest, type ApiContext } from "./auth";
import {
  CLAUDE_APP_CHAT_MAX_BATCH,
  CLAUDE_APP_CHAT_MAX_BYTES,
  claudeAppChatSaveRequestSchema,
  claudeAppChatSaveResponseSchema,
  claudeAppChatsDeleteAllResponseSchema,
  claudeAppSentRequestSchema,
  type ApiErrorV2ClaudeAppChatCode,
  type ClaudeAppChatErrorCode,
  type ClaudeAppChatSaveRequest,
  type ClaudeAppChatSaveResponse,
  type ClaudeAppChatStatusResponse,
  type ClaudeAppSentRequest,
} from "./contract";
import { parseCappedBody } from "./external-sessions";
import { retryAfterSeconds, type RateLimit } from "./rate-limit";
import { errorResponse, unauthorized } from "./respond";

// Claude 데스크톱 세션과 나눈 대화 저장 route 처리 (OA PR-D3s, 계약 25.3 · 26장): Mac이 Claude 데스크톱 앱에 열린 세션으로 보낸 글("Received"로 확인된 것)과 그 뒤 답 글(+ 도구 단계 이름만)을
// 올리고(멱등), 사용자가 지운다. 인증 · gate · 저장을 인자로 받아 Route Handler 밖에서 테스트한다 (external-sessions.ts와 같은 방식).
// **서버가 시작하는 보내기 길은 없다**: 이 파일은 bridge 명령 · 대화 · 에이전트 작업을 만들지 않고, 쓰는 곳은 SQL 함수 둘(save · delete_claude_app_chat)과 지표 한 줄뿐이다.
// gate: 저장 경로(status · PUT)는 CONVERSATIONS_V2_ENABLED ∧ AGENT_ADAPTER_CLAUDE_CODE_ENABLED ∧ CLAUDE_APP_CHATS_ENABLED(새, 기본 꺼짐) ∧ 베타 명단. 꺼져 있으면 인증 · DB 전에 404.
// 보내기 결과 지표(claude-app-sent)는 저장 플래그와 무관하다 (앞의 둘 ∧ 명단).
// **지우기(DELETE)는 gate도 베타 명단도 보지 않는다**: 저장된 데이터는 늘 지울 수 있다 (BYOK 키 DELETE와 같다 — src/app/api/v2/billing/openrouter-key/route.ts). 로그인(Bearer · 쿠키 + CSRF)은 필요하고 자기 행만 지운다.
// 모두 지우기(DELETE /api/v2/claude-app-chats, D3v-s 계약 27장)도 같다: 늘 열려 있고, 한 SQL 함수가 사용자별 잠금 아래 한 트랜잭션으로 모두 지운다.
// 글 · 제목 · ref · id는 로그 · 오류 응답에 담지 않는다 (이벤트 이름 · 결과 코드 · 오류 이름 · code만). 요청 값은 어느 응답에도 되돌리지 않는다.

/** 본문 상한: 답 글 하나가 64 KiB라 4개가 못 들어갈 만큼이다 (status의 max_bytes). 이보다 크면 거절한다 (Content-Length가 있으면 읽기 전에, 없거나 거짓이면 읽다가 넘는 순간) */
const MAX_BODY_BYTES = CLAUDE_APP_CHAT_MAX_BYTES;
/** 지표 본문은 코드 둘뿐이다 */
const MAX_SENT_BODY_BYTES = 1024;

/** 저장 요청 속도 제한: 사용자별 10분에 120번 (take_rate_limit 종류 claude_app_chat, 20261207000000). 멱등 재시도도 센다 */
export const CLAUDE_APP_CHAT_LIMIT: RateLimit = { max: 120, windowMs: 10 * 60_000 };
/** 저장 요청 하루 한도: 사용자별 하루(24시간)에 1,000번 (종류 claude_app_chat_day). 10분 한도를 먼저 세고 그 뒤에 센다 (보안 검토 P2-1) */
export const CLAUDE_APP_CHAT_DAILY_LIMIT: RateLimit = { max: 1000, windowMs: 24 * 3600_000 };
/** 보내기 결과 지표 속도 제한: 사용자별 10분에 120번 (종류 claude_app_sent, 저장과 따로 센다). 지표를 실제로 쓰는 호출만 센다 */
export const CLAUDE_APP_SENT_LIMIT: RateLimit = { max: 120, windowMs: 10 * 60_000 };
/**
 * 모두 지우기 속도 제한: 사용자별 10분에 5번 (종류 claude_app_chat_delete_all, 20261208000000). 쓰는 사람은 한 번이면 된다(조용한 재시도 한 번을 더해도 5번이면 넉넉하다).
 * 이 호출은 사용자별 잠금을 쥔 채 행 수에 비례해 일하므로 되풀이(새는 토큰)를 막는다. 저장(claude_app_chat)과 **따로** 센다: 저장이 가득 차도 지우기는 열려 있고 지우기가 저장 한도를 먹지 않는다
 */
export const CLAUDE_APP_CHATS_DELETE_ALL_LIMIT: RateLimit = { max: 5, windowMs: 10 * 60_000 };

type AppUser = { user: { id: string } };

export type ClaudeAppChatSaveOutcome = ({ status: "ok" } & ClaudeAppChatSaveResponse) | { status: "not_found" } | { status: "quota_exceeded" };

export type ClaudeAppChatsDeps<User extends AppUser> = {
  /** 저장 경로의 gate (대화 v2 ∧ Claude Code adapter ∧ CLAUDE_APP_CHATS_ENABLED). 꺼져 있으면 인증 · DB 전에 404 */
  enabled: () => boolean;
  /** 보내기 결과 지표의 gate (대화 v2 ∧ Claude Code adapter): 저장 플래그와 무관 */
  sentEnabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  betaAllowed: (userId: string) => boolean;
  /** 속도 제한(claude_app_chat, 10분에 120번): 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 한 번 남기고 null. 저장 함수보다 먼저 부른다 */
  takeLimit: (user: User) => Promise<Date | null>;
  /** 하루 한도(claude_app_chat_day, 1,000번): 10분 한도를 통과한 뒤 저장 함수보다 먼저 부른다. 같은 모양 */
  takeDailyLimit: (user: User) => Promise<Date | null>;
  /** 속도 제한(claude_app_sent, 10분에 120번): 지표를 쓰기 전에 부른다. 같은 모양 (한도에 찼으면 시각, 아니면 null) */
  takeSentLimit: (user: User) => Promise<Date | null>;
  /** 속도 제한(claude_app_chat_delete_all, 10분에 5번): 모두 지우기 전에 부른다. 같은 모양 (한도에 찼으면 시각, 아니면 시도를 한 번 남기고 null) */
  takeDeleteAllLimit: (user: User) => Promise<Date | null>;
  save: (user: User, input: ClaudeAppChatSaveRequest) => Promise<ClaudeAppChatSaveOutcome>;
  remove: (user: User, chatId: string) => Promise<"deleted" | "not_found">;
  /** 인증된 사용자의 저장된 대화를 한 트랜잭션으로 모두 지운다 → 지운 채팅 수 (0이면 이미 비어 있었다) */
  removeAll: (user: User) => Promise<number>;
  /** 지표 claude_app_message_sent (결과 코드뿐) */
  recordSent: (user: User, input: ClaudeAppSentRequest) => Promise<void>;
};

const NOT_FOUND = "없는 경로입니다.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function codeOf(error: unknown): string | undefined {
  const code = typeof error === "object" && error !== null ? (error as { code?: unknown }).code : undefined;
  return typeof code === "string" ? code : undefined;
}

/**
 * 잠금 경합(55P03) · 직렬화 실패(40001) · 교착(40P01)은 쓰기가 롤백됐으니 같은 요청을 다시 보내도 된다 (409 busy_retry, 500 아님).
 * 22023(SQL 함수의 인자 모양 검사)은 zod가 이미 막았어야 할 값이다: 500이 아니라 400 invalid_request (요청 값은 되돌리지 않는다; 로그에는 이벤트 이름 · 오류 이름 · code만 — 두 검사가 어긋났다는 신호).
 * 그 밖은 500 + 이벤트 이름 · 오류 이름 · 코드만 로그
 */
function failed(error: unknown, event: string, message: string): Response {
  const code = codeOf(error);
  if (code === "55P03" || code === "40001" || code === "40P01") return errorResponse(409, "busy_retry", "잠시 뒤 다시 시도해 주세요.");
  console.error(JSON.stringify({ event, error: error instanceof Error ? error.name : "unknown", ...(code ? { code } : {}) }));
  if (code === "22023") return errorResponse(400, "invalid_request", "잘못된 요청입니다.");
  return errorResponse(500, "internal_error", message);
}

/**
 * bridge_not_found · quota_exceeded는 공용 errorResponse의 코드 목록(apiErrorV2AgentCodeSchema: 길이를 고정하는 시험이 있다)에 없다.
 * 같은 모양({ error: { code, message } })을 이 route의 목록(apiErrorV2ClaudeAppChatCodeSchema)으로 확인하며 만든다
 */
function chatError(status: 404 | 413, code: ClaudeAppChatErrorCode, message: string): Response {
  return Response.json({ error: { code, message } } satisfies { error: { code: ApiErrorV2ClaudeAppChatCode; message: string } }, { status });
}

/** gate 404 → 인증 401 → 베타 명단 404 (저장 경로 공통) */
async function begin<User extends AppUser>(request: Request, deps: ClaudeAppChatsDeps<User>, gate: () => boolean): Promise<{ user: User } | { response: Response }> {
  if (!gate()) return { response: errorResponse(404, "not_found", NOT_FOUND) };
  const user = await deps.authenticate(request);
  if (!user) return { response: unauthorized() };
  if (!deps.betaAllowed(user.user.id)) return { response: errorResponse(404, "not_found", NOT_FOUND) };
  return { user };
}

/** GET /api/v2/claude-app-chats/status: Mac이 **글을 보내기 전에** 저장이 켜졌는지 묻는다. 꺼짐 · 명단 밖은 404 — 그러면 Mac은 글을 서버로 한 바이트도 보내지 않는다 */
export async function handleClaudeAppChatStatus<User extends AppUser>(request: Request, deps: ClaudeAppChatsDeps<User>): Promise<Response> {
  const started = await begin(request, deps, deps.enabled);
  if ("response" in started) return started.response;
  return Response.json({ save: true, max_batch: CLAUDE_APP_CHAT_MAX_BATCH, max_bytes: CLAUDE_APP_CHAT_MAX_BYTES } satisfies ClaudeAppChatStatusResponse);
}

/**
 * PUT /api/v2/claude-app-chats: 한 교환의 행들을 올린다 (멱등, 한 번에 최대 20행 · 본문 256 KiB).
 * 순서: gate 404 not_found(인증 · DB 0) → 인증 401(Bearer · 쿠키 + CSRF) → 베타 명단 404 not_found → 본문 400(strict) → 10분 한도 429 → 하루 한도 429 → 저장.
 * 404 bridge_not_found = 없는 · 남의 · 해제된 bridge (구별해서 알리지 않는다; gate가 꺼진 404 not_found와 코드가 다르다). 413 quota_exceeded = 사용자별 한도(저장 본문 50 MiB · 채팅 2,000개).
 * 사용자 id는 인증에서만 온다. 응답은 개수뿐이다 (글 · 제목을 되돌리지 않는다).
 */
export async function handleSaveClaudeAppChat<User extends AppUser>(request: Request, deps: ClaudeAppChatsDeps<User>): Promise<Response> {
  const started = await begin(request, deps, deps.enabled);
  if ("response" in started) return started.response;
  const { user } = started;
  const body = await parseCappedBody(request, claudeAppChatSaveRequestSchema, MAX_BODY_BYTES);
  if ("error" in body) return body.error;
  try {
    const retryAt = await deps.takeLimit(user);
    if (retryAt) {
      console.info(JSON.stringify({ event: "claude_app_chat_save", result: "rate_limited" }));
      const response = errorResponse(429, "rate_limited", "저장 요청이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, new Date())));
      return response;
    }
    const dailyRetryAt = await deps.takeDailyLimit(user);
    if (dailyRetryAt) {
      console.info(JSON.stringify({ event: "claude_app_chat_save", result: "rate_limited" }));
      const response = errorResponse(429, "rate_limited", "오늘 저장 요청이 너무 많습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(dailyRetryAt, new Date())));
      return response;
    }
    const outcome = await deps.save(user, body.data);
    if (outcome.status === "not_found") {
      console.info(JSON.stringify({ event: "claude_app_chat_save", result: "bridge_not_found" }));
      return chatError(404, "bridge_not_found", "이 Mac을 찾지 못했습니다.");
    }
    if (outcome.status === "quota_exceeded") {
      console.info(JSON.stringify({ event: "claude_app_chat_save", result: "quota_exceeded" }));
      return chatError(413, "quota_exceeded", "저장 한도에 닿았습니다. 저장된 대화를 지우면 다시 저장할 수 있습니다.");
    }
    console.info(JSON.stringify({ event: "claude_app_chat_save", result: "ok" }));
    return Response.json(claudeAppChatSaveResponseSchema.parse({ chat_id: outcome.chat_id, saved: outcome.saved, existing: outcome.existing, orphan: outcome.orphan }));
  } catch (error) {
    return failed(error, "claude_app_chat_save_failed", "대화를 저장하지 못했습니다.");
  }
}

/**
 * DELETE /api/v2/claude-app-chats/{id}: 사용자가 저장된 대화를 지운다 (채팅 + 모든 행, 지표 claude_app_chat_deleted는 SQL이 같은 트랜잭션에서).
 * **늘 열려 있다**: gate(CLAUDE_APP_CHATS_ENABLED · 대화 v2 · adapter)도 베타 명단도 보지 않는다 — 플래그를 끈 뒤에도 이미 저장된 데이터는 지울 수 있어야 한다 (BYOK 키 DELETE와 같다).
 * 순서: 인증 401(Bearer · 쿠키 + CSRF) → id 모양 404 → 지우기. 사용자 id는 인증에서만 온다: 자기 행만 지운다. 남의 · 없는 · 모양이 틀린 id는 404, 지우면 204 (Cache-Control no-store).
 */
export async function handleDeleteClaudeAppChat<User extends AppUser>(request: Request, chatId: string, deps: ClaudeAppChatsDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(chatId)) return errorResponse(404, "not_found", "저장된 대화를 찾지 못했습니다.");
  try {
    const result = await deps.remove(user, chatId);
    console.info(JSON.stringify({ event: "claude_app_chat_delete", result }));
    return result === "deleted" ? new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } }) : errorResponse(404, "not_found", "저장된 대화를 찾지 못했습니다.");
  } catch (error) {
    return failed(error, "claude_app_chat_delete_failed", "대화를 지우지 못했습니다.");
  }
}

/**
 * DELETE /api/v2/claude-app-chats: 사용자의 저장된 대화를 **모두** 지운다 (D3v-s, 계약 27장). 요청 본문 · 쿼리는 읽지 않는다. 200 { deleted: 지운 채팅 수 } (Cache-Control no-store).
 * 채팅 + 모든 행 + 묘비(재시도가 되살리지 못하게) + 지표 claude_app_chats_deleted_all은 SQL이 **한 트랜잭션**으로 한다: 일부만 지워진 상태가 없고, 겹친 저장은 사용자별 잠금에 줄을 선다. 이미 비어 있으면 200 { deleted: 0 }.
 * **늘 열려 있다**: gate(CLAUDE_APP_CHATS_ENABLED · 대화 v2 · adapter)도 베타 명단도 보지 않는다 — 플래그를 끈 뒤에도 이미 저장된 데이터는 지울 수 있어야 한다 (대화마다 지우는 DELETE · BYOK 키 DELETE와 같다).
 * 순서: 인증 401(Bearer · 쿠키 + CSRF) → 속도 제한 429(+ Retry-After; 저장 한도와 따로 센다) → 지우기 → 200 / 409 `busy_retry`(롤백된 경합: 같은 요청을 다시 보내도 된다) / 500.
 * 사용자 id는 인증에서만 온다: 자기 행만 지운다. 로그는 이벤트 이름 · 결과 코드 · 오류 이름 · code만 (지운 수도 남기지 않는다).
 */
export async function handleDeleteAllClaudeAppChats<User extends AppUser>(request: Request, deps: ClaudeAppChatsDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  try {
    const retryAt = await deps.takeDeleteAllLimit(user);
    if (retryAt) {
      console.info(JSON.stringify({ event: "claude_app_chats_delete_all", result: "rate_limited" }));
      const response = errorResponse(429, "rate_limited", "요청이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, new Date())));
      return response;
    }
    const body = claudeAppChatsDeleteAllResponseSchema.parse({ deleted: await deps.removeAll(user) });
    console.info(JSON.stringify({ event: "claude_app_chats_delete_all", result: "ok" }));
    return Response.json(body, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    return failed(error, "claude_app_chats_delete_all_failed", "대화를 지우지 못했습니다.");
  }
}

/**
 * POST /api/v2/external-sessions/claude-app-sent: 보내기 결과 지표 claude_app_message_sent (글 0, **저장 플래그와 무관**). 본문은 코드뿐이다 { result: received|not_sent, reason? }. 응답은 204.
 * 저장이 켜져 있으면 received는 save_claude_app_chat이 새 사용자 글마다 남기므로 여기서는 남기지 않는다 (두 번 세지 않는다). not_sent는 늘 여기서 남긴다.
 * 예외: received + uploaded:false (Mac이 올리기를 포기했다)는 저장이 켜져 있어도 여기서 센다 — 저장 함수가 못 센 받은 글이다.
 * 속도 제한(claude_app_sent, 사용자별 10분 120번)은 **지표를 실제로 쓰는 호출만** 센다 (아무것도 쓰지 않는 received · 잘못된 본문은 세지 않는다). 한도에 찼으면 429 + Retry-After.
 */
export async function handleClaudeAppSent<User extends AppUser>(request: Request, deps: ClaudeAppChatsDeps<User>): Promise<Response> {
  const started = await begin(request, deps, deps.sentEnabled);
  if ("response" in started) return started.response;
  const body = await parseCappedBody(request, claudeAppSentRequestSchema, MAX_SENT_BODY_BYTES);
  if ("error" in body) return body.error;
  try {
    if (body.data.result === "received" && body.data.uploaded !== false && deps.enabled()) return new Response(null, { status: 204 });
    const retryAt = await deps.takeSentLimit(started.user);
    if (retryAt) {
      console.info(JSON.stringify({ event: "claude_app_sent", result: "rate_limited" }));
      const response = errorResponse(429, "rate_limited", "요청이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, new Date())));
      return response;
    }
    // uploaded는 어느 쪽 지표로 셀지 가르는 데만 쓰고 props에는 남기지 않는다 (props = 결과 코드뿐)
    await deps.recordSent(started.user, body.data.result === "received" ? { result: "received" } : body.data);
    return new Response(null, { status: 204 });
  } catch (error) {
    return failed(error, "claude_app_sent_failed", "이벤트를 남기지 못했습니다.");
  }
}

const saveRpcSchema = z.union([
  z.strictObject({ status: z.literal("ok"), chat_id: z.guid().nullable(), saved: z.number().int().min(0), existing: z.number().int().min(0), orphan: z.number().int().min(0) }),
  z.strictObject({ status: z.literal("not_found") }),
  z.strictObject({ status: z.literal("quota_exceeded") }),
]);
const deleteRpcSchema = z.strictObject({ status: z.enum(["deleted", "not_found"]) });

async function takeKindLimit(admin: SupabaseClient, userId: string, kind: "claude_app_chat" | "claude_app_chat_day" | "claude_app_sent" | "claude_app_chat_delete_all", limit: RateLimit): Promise<Date | null> {
  const { data } = await admin.rpc("take_rate_limit", { p_user_id: userId, p_kind: kind, p_max: limit.max, p_window_seconds: limit.windowMs / 1000 }).throwOnError();
  return data ? new Date(String(data)) : null;
}

/** 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 한 번 남기고 null. 저장 함수를 부르기 전에 부른다 */
export const takeClaudeAppChatLimit = (admin: SupabaseClient, userId: string) => takeKindLimit(admin, userId, "claude_app_chat", CLAUDE_APP_CHAT_LIMIT);
/** 같은 모양, 저장 요청의 하루 한도 (종류 claude_app_chat_day). 10분 한도를 통과한 뒤에 부른다 */
export const takeClaudeAppChatDailyLimit = (admin: SupabaseClient, userId: string) => takeKindLimit(admin, userId, "claude_app_chat_day", CLAUDE_APP_CHAT_DAILY_LIMIT);
/** 같은 모양, 보내기 결과 지표를 쓰기 전에 부른다 (종류 claude_app_sent) */
export const takeClaudeAppSentLimit = (admin: SupabaseClient, userId: string) => takeKindLimit(admin, userId, "claude_app_sent", CLAUDE_APP_SENT_LIMIT);
/** 같은 모양, 모두 지우기 전에 부른다 (종류 claude_app_chat_delete_all) */
export const takeClaudeAppChatsDeleteAllLimit = (admin: SupabaseClient, userId: string) => takeKindLimit(admin, userId, "claude_app_chat_delete_all", CLAUDE_APP_CHATS_DELETE_ALL_LIMIT);

export const realClaudeAppChatsDeps = (): ClaudeAppChatsDeps<ApiContext> => ({
  enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED") && flagEnabled("AGENT_ADAPTER_CLAUDE_CODE_ENABLED") && flagEnabled("CLAUDE_APP_CHATS_ENABLED"),
  sentEnabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED") && flagEnabled("AGENT_ADAPTER_CLAUDE_CODE_ENABLED"),
  authenticate: authenticateRequest,
  betaAllowed: agentBetaUserAllowed,
  takeLimit: ({ user }) => takeClaudeAppChatLimit(createAdminClient(), user.id),
  takeDailyLimit: ({ user }) => takeClaudeAppChatDailyLimit(createAdminClient(), user.id),
  takeSentLimit: ({ user }) => takeClaudeAppSentLimit(createAdminClient(), user.id),
  takeDeleteAllLimit: ({ user }) => takeClaudeAppChatsDeleteAllLimit(createAdminClient(), user.id),
  // 멱등이라 롤백된 경합은 같은 호출로 다시 한다 (retryOnConflict). 소유 확인 · 직렬화 · 지표는 모두 SQL 함수 안이다
  save: async ({ user }, input) => {
    const admin = createAdminClient();
    const { data } = await retryOnConflict(
      async () =>
        await admin
          // title 칸이 없으면 저장된 제목을 그대로 둔다 (p_keep_title), 명시한 null이면 지운다
          .rpc("save_claude_app_chat", { p_user_id: user.id, p_bridge_id: input.bridge_id, p_session_ref: input.session_ref, p_title: input.title ?? null, p_keep_title: input.title === undefined, p_messages: input.messages })
          .throwOnError(),
    );
    return saveRpcSchema.parse(data);
  },
  remove: async ({ user }, chatId) => {
    const { data } = await retryOnConflict(async () => await createAdminClient().rpc("delete_claude_app_chat", { p_user_id: user.id, p_chat_id: chatId }).throwOnError());
    return deleteRpcSchema.parse(data).status;
  },
  // 롤백된 경합은 같은 호출로 다시 한다 (지우기는 멱등: 이미 지운 것은 0으로 센다). 묘비 · 지표 · 사용자별 잠금은 모두 SQL 함수 안이다
  removeAll: async ({ user }) => {
    const { data } = await retryOnConflict(async () => await createAdminClient().rpc("delete_all_claude_app_chats", { p_user_id: user.id }).throwOnError());
    return claudeAppChatsDeleteAllResponseSchema.parse(data).deleted;
  },
  // 앱의 열 권한(type · props)을 넓히지 않으려고 코드를 검증한 뒤 서버 권한으로 남긴다. 사용자 id는 인증에서만 온다
  recordSent: async ({ user }, input) => {
    const { error } = await createAdminClient().from("metric_events").insert({ user_id: user.id, type: "claude_app_message_sent", props: input });
    if (error) throw error;
  },
});
