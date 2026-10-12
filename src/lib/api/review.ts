import {
  returnSummaryBaselineRequestSchema,
  returnSummaryClearRequestSchema,
  suggestionDismissRequestSchema,
  suggestionSnoozeRequestSchema,
  type ReturnSummaryBaselineResponse,
  type ReturnSummaryClearResponse,
  type ReturnSummaryResponse,
  type ReviewResponse,
  type Suggestion,
  type SuggestionResponse,
} from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// /api/v2/review · /api/v2/return-summary(/clear) · /api/v2/suggestions/{id}/(snooze|dismiss) 처리 (0.2.0 C3). 인증 · gate · 읽기/쓰기를 인자로 받아 Route Handler 밖에서 테스트한다.
//  - gate REVIEW_V2_ENABLED가 꺼져 있으면 404: 인증 · DB를 부르지 않는다 (새 쓰기 0, 기존 API 그대로).
//  - 쿠키로 인증하는 쓰기(POST)의 CSRF는 authenticateRequest가 본다. GET 중 복귀 요약은 아무것도 쓰지 않고, Review는 멱등 쓰기를 한다(제안 생산 · 노출 표시: 그날의 비긴급 묶음을 소비한다. Action · run · Claim은 만들지 않는다). 쿠키 인증 GET은 CSRF 검사 대상이 아니다.
//  - 오류 본문에 요청 값을 담지 않는다. 로그에는 오류 이름만 남긴다 (원문 · 제목 · 커서를 남기지 않는다).

type AppUser = { user: { id: string } };

type BaseDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  /** 시험에서 시계를 고정한다 */
  now?: () => Date;
};

const NOT_FOUND = "없는 경로입니다.";
const SUGGESTION_NOT_FOUND = "제안이 없습니다.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NO_STORE = { "Cache-Control": "no-store" };
const MS_PER_DAY = 86_400_000;

const fail = (event: string, error: unknown) =>
  console.error(JSON.stringify({ event, error: error instanceof Error ? error.name : "unknown" }));

// ─── GET: Review · 복귀 요약 ─────────────────────────

export type ReviewDeps<User extends AppUser> = BaseDeps<User> & { load: (user: User, now: Date) => Promise<ReviewResponse> };

/** GET /api/v2/review — C2 결정 대기 계산 + 열린 제안. 일부를 읽지 못해도 200이고 그 부분을 unavailable로 표시한다 */
export async function handleGetReview<User extends AppUser>(request: Request, deps: ReviewDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  try {
    return Response.json(await deps.load(user, deps.now?.() ?? new Date()) satisfies ReviewResponse, { headers: NO_STORE });
  } catch (error) {
    fail("review_failed", error);
    return errorResponse(500, "internal_error", "Review를 불러오지 못했습니다.");
  }
}

export type ReturnSummaryDeps<User extends AppUser> = BaseDeps<User> & { load: (user: User, now: Date) => Promise<ReturnSummaryResponse> };

/** GET /api/v2/return-summary — 복귀 요약. 원천을 읽지 못한 부분은 unavailable · truncated로 표시한다 (비었다고 하지 않는다) */
export async function handleGetReturnSummary<User extends AppUser>(request: Request, deps: ReturnSummaryDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  try {
    return Response.json(await deps.load(user, deps.now?.() ?? new Date()) satisfies ReturnSummaryResponse, { headers: NO_STORE });
  } catch (error) {
    fail("return_summary_failed", error);
    return errorResponse(500, "internal_error", "복귀 요약을 불러오지 못했습니다.");
  }
}

// ─── POST: Clear ─────────────────────────────────────

export type ClearDeps<User extends AppUser> = BaseDeps<User> & {
  clear: (user: User, cursor: string) => Promise<{ status: "cleared"; applied: boolean; clearedThrough: string } | { status: "stale" | "invalid" }>;
};

/**
 * POST /api/v2/return-summary/clear { cursor } — 조회한 범위를 읽음 처리한다 (읽음일 뿐이다).
 * 200 { cleared_through, applied } · 409 conflict(조회 뒤 범위가 달라짐: 아무것도 읽음 처리하지 않았다, 다시 조회) · 400 잘못된 · 미래 · 남의 커서.
 */
export async function handleClearReturnSummary<User extends AppUser>(request: Request, deps: ClearDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, returnSummaryClearRequestSchema);
  if ("error" in body) return body.error;
  try {
    const result = await deps.clear(user, body.data.cursor);
    switch (result.status) {
      case "cleared":
        return Response.json({ cleared_through: result.clearedThrough, applied: result.applied } satisfies ReturnSummaryClearResponse, { headers: NO_STORE });
      case "stale":
        return errorResponse(409, "conflict", "조회한 뒤 바뀐 변화가 있어 읽음 처리하지 않았습니다. 다시 불러온 뒤 시도해 주세요.");
      case "invalid":
        return errorResponse(400, "invalid_request", "잘못된 커서입니다. 다시 불러온 뒤 시도해 주세요.");
    }
  } catch (error) {
    fail("return_summary_clear_failed", error);
    return errorResponse(500, "internal_error", "읽음 처리하지 못했습니다.");
  }
}

// ─── POST: 첫 정상 표시 기준점 확정 ─────────────────────

export type BaselineDeps<User extends AppUser> = BaseDeps<User> & {
  initialize: (user: User, token: string) => Promise<{ status: "initialized"; applied: true } | { status: "already_initialized"; applied: false } | { status: "stale" | "invalid" }>;
};

/**
 * POST /api/v2/return-summary/baseline { init_token } — 앱이 복귀 요약을 처음 정상으로 표시했을 때 그 순간의 run 결과 · 대화 메시지 이력을 기준점으로 확정한다 (읽음 표시일 뿐).
 * 200 { status: initialized | already_initialized, applied } · 409 conflict(조회 뒤 범위가 달라짐: 아무것도 쓰지 않았다, 다음 정상 표시의 새 토큰으로 다시) · 400 잘못된 · 미래 · 남의 토큰.
 */
export async function handleInitializeReturnSummaryBaseline<User extends AppUser>(request: Request, deps: BaselineDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, returnSummaryBaselineRequestSchema);
  if ("error" in body) return body.error;
  try {
    const result = await deps.initialize(user, body.data.init_token);
    switch (result.status) {
      case "initialized":
      case "already_initialized":
        return Response.json({ status: result.status, applied: result.applied } as ReturnSummaryBaselineResponse, { headers: NO_STORE });
      case "stale":
        return errorResponse(409, "conflict", "조회한 뒤 바뀐 기록이 있어 기준점을 정하지 않았습니다. 다음에 다시 불러온 뒤 시도해 주세요.");
      case "invalid":
        return errorResponse(400, "invalid_request", "잘못된 토큰입니다. 다시 불러온 뒤 시도해 주세요.");
    }
  } catch (error) {
    fail("return_summary_baseline_failed", error);
    return errorResponse(500, "internal_error", "기준점을 정하지 못했습니다.");
  }
}

// ─── POST: 제안 snooze · dismiss ─────────────────────

type TransitionOutcome = { status: "ok"; suggestion: Suggestion } | { status: "not_found" | "conflict" | "invalid" };

function respondTransition(outcome: TransitionOutcome): Response {
  switch (outcome.status) {
    case "ok":
      return Response.json({ suggestion: outcome.suggestion } satisfies SuggestionResponse, { headers: NO_STORE });
    case "not_found":
      return errorResponse(404, "not_found", SUGGESTION_NOT_FOUND);
    case "conflict":
      return errorResponse(409, "conflict", "그 사이 제안이 바뀌었거나 이미 처리됐습니다. 다시 불러온 뒤 시도해 주세요.");
    case "invalid":
      return errorResponse(400, "invalid_request", "처리할 수 없는 요청입니다.");
  }
}

export type SnoozeDeps<User extends AppUser> = BaseDeps<User> & {
  snooze: (user: User, id: string, expectedVersion: number, until: Date, now: Date) => Promise<TransitionOutcome>;
  /** snooze로 고를 수 있는 가장 먼 시점 (일) — 기술 한도 */
  maxDays: number;
};

/**
 * POST /api/v2/suggestions/{id}/snooze { expected_version, snooze_until } — 사용자가 고른 시점까지 숨긴다.
 * 시점은 지금보다 뒤이고 maxDays 이내여야 한다(400). 서버가 시점을 정하지 않는다. 옛 version이거나 이미 끝난 제안은 409 (자동 재시도 없음).
 */
export async function handleSnoozeSuggestion<User extends AppUser>(request: Request, id: string, deps: SnoozeDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(id)) return errorResponse(404, "not_found", SUGGESTION_NOT_FOUND);
  const body = await parseBody(request, suggestionSnoozeRequestSchema);
  if ("error" in body) return body.error;
  const now = deps.now?.() ?? new Date();
  const until = new Date(body.data.snooze_until);
  if (Number.isNaN(until.getTime()) || until.getTime() <= now.getTime() || until.getTime() > now.getTime() + deps.maxDays * MS_PER_DAY) {
    return errorResponse(400, "invalid_request", "다시 알릴 시점은 지금 이후이고 1년 이내여야 합니다.");
  }
  try {
    return respondTransition(await deps.snooze(user, id, body.data.expected_version, until, now));
  } catch (error) {
    fail("suggestion_snooze_failed", error);
    return errorResponse(500, "internal_error", "제안을 처리하지 못했습니다.");
  }
}

export type DismissDeps<User extends AppUser> = BaseDeps<User> & {
  dismiss: (user: User, id: string, expectedVersion: number, scope: "this" | "topic", now: Date) => Promise<TransitionOutcome>;
};

/** POST /api/v2/suggestions/{id}/dismiss { expected_version, scope } — this: 이 계기만 / topic: 같은 종류 + 주제의 새 계기도 다시 제안하지 않는다 */
export async function handleDismissSuggestion<User extends AppUser>(request: Request, id: string, deps: DismissDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", NOT_FOUND);
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(id)) return errorResponse(404, "not_found", SUGGESTION_NOT_FOUND);
  const body = await parseBody(request, suggestionDismissRequestSchema);
  if ("error" in body) return body.error;
  try {
    return respondTransition(await deps.dismiss(user, id, body.data.expected_version, body.data.scope, deps.now?.() ?? new Date()));
  } catch (error) {
    fail("suggestion_dismiss_failed", error);
    return errorResponse(500, "internal_error", "제안을 처리하지 못했습니다.");
  }
}
