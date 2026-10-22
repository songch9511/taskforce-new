import { z } from "zod";

import { sourceKindSchema } from "@/lib/pipeline/extract";
import { RESPONSE_MISS_STAGES } from "@/lib/pipeline/missing";

// 앱 · 웹이 부르는 /api/v1 요청 · 응답 형식. Swift 모델(TaskforceKit)은 이 파일을 기준으로 맞춘다.
// 호환이 깨지는 변경은 /api/v2로 낸다 (docs/PLATFORMS.md 3장).

export { sourceKindSchema };

/** 원문 한 건의 최대 길이. 긴 회의 전사도 들어가도록 넉넉히 잡고, 모델 입력 한도 안에 둔다. */
export const MAX_SOURCE_TEXT = 200_000;

// 원문 관련자. 메일은 보낸 사람 · 받는 사람 · 참조, 회의 · 캘린더는 참석자.
// 이메일 주소가 있으면 사용자를 확실히 찾을 수 있다.
export const personSchema = z
  .object({ name: z.string().trim().min(1).max(100).optional(), email: z.email().max(320).optional() })
  .refine((p) => p.name || p.email, { message: "이름이나 이메일 중 하나는 필요합니다" });

export const participantsSchema = z.object({
  from: personSchema.optional(),
  to: z.array(personSchema).max(100).optional(),
  cc: z.array(personSchema).max(100).optional(),
  attendees: z.array(personSchema).max(200).optional(),
});
export type ParticipantsInput = z.infer<typeof participantsSchema>;

// POST /api/v1/sources
export const createSourceRequestSchema = z.object({
  kind: sourceKindSchema,
  text: z.string().trim().min(1).max(MAX_SOURCE_TEXT),
  /** 발언 · 작성 시점 (입력 시점 아님). 없으면 서버가 받은 시각 */
  occurred_at: z.iso.datetime({ offset: true }).optional(),
  title: z.string().trim().max(200).optional(),
  external_url: z.url().max(2000).optional(),
  /**
   * 원문에서 사용자를 부르는 이름. 없으면 프로필 이름(없으면 계정 이름 · 이메일 앞부분)을 쓴다.
   * 별칭은 프로필(PUT /api/v1/profile)에 둔다.
   */
  user_name: z.string().trim().min(1).max(50).optional(),
  participants: participantsSchema.optional(),
});
export type CreateSourceRequest = z.infer<typeof createSourceRequestSchema>;

export const createSourceResponseSchema = z.object({
  source_id: z.uuid(),
  status: z.literal("pending"),
});
export type CreateSourceResponse = z.infer<typeof createSourceResponseSchema>;

// PUT /api/v1/profile 본문: 원문에서 사용자를 알아보는 데 쓰는 정보
export const profileInputSchema = z.object({
  /** 원문에서 사용자를 부르는 기본 이름 */
  display_name: z.string().trim().min(1).max(50).nullable(),
  /** 다른 호칭 · 영문 이름 · 받아쓰기가 자주 틀리는 이름 */
  aliases: z.array(z.string().trim().min(1).max(50)).max(20),
  /** 사용자의 이메일 주소 (로그인 주소 외에 회사 · 개인 주소) */
  emails: z.array(z.email().max(320)).max(10),
});
export type ProfileInput = z.infer<typeof profileInputSchema>;

// GET · PUT /api/v1/profile 응답
export const profileSchema = profileInputSchema.extend({
  /**
   * 외부 AI 처리에 동의한 시각 (POST /api/v1/consent). null이면 동의 전이거나 철회함:
   * 서버는 원문을 외부 AI(LLM · Jev · 임베딩)로 보내지 않고, 연결 시작 · 원문 보내기 · 물어보기는 409 conflict다.
   * PUT 본문에 넣어도 무시한다 (동의는 /api/v1/consent로만 바꾼다).
   */
  ai_consent_at: z.string().nullable(),
});
export type Profile = z.infer<typeof profileSchema>;

// POST /api/v1/consent — 외부 AI 처리 동의 (App Store 5.1.2(i)). 204. 다시 보내면 동의 시각을 새로 적는다.
// DELETE /api/v1/consent — 철회. 본문 없음, 204. 이미 들어온 원문 · 할 일은 남고(지우려면 계정 삭제), 이후 처리만 멈춘다.
export const consentRequestSchema = z.object({ ai_processing: z.literal(true) });
export type ConsentRequest = z.infer<typeof consentRequestSchema>;

// ─── Action (Phase 3) ─────────────────────────────────────
// 읽기는 앱이 Supabase에서 직접(RLS) 한다. 여기 있는 것은 서버 계산이 필요한 읽기(지금 할 일 순서)와 모든 쓰기다.

export const actionOwnerSchema = z.enum(["me", "other", "unknown"]);
export const actionStatusSchema = z.enum(["open", "done", "dropped"]);

export const actionSummarySchema = z.object({
  id: z.uuid(),
  title: z.string(),
  owner: actionOwnerSchema,
  status: actionStatusSchema,
  due_date: z.iso.date().nullable(),
  counterpart: z.string().nullable(),
  needs_confirmation: z.boolean(),
  /** 확인 요청 이유 (예: "담당 확인", "기한 확인", "병합 확인 (55%)") */
  confirm_reasons: z.array(z.string()),
  started_at: z.string().nullable(),
  last_activity_at: z.string(),
});
export type ActionSummary = z.infer<typeof actionSummarySchema>;

export const rankedActionSchema = actionSummarySchema.extend({
  score: z.number(),
  reasons: z.array(z.enum(["overdue", "due_today", "due_soon", "external", "neglected", "started"])),
  days_until_due: z.number().nullable(),
  /**
   * 바뀜 점 (U1): 사용자가 마지막으로 본 뒤(POST /api/v1/actions/:id/seen 또는 사용자가 직접 한 쓰기) AI · 원문 · 실행기가 바꿨다.
   * 기한 · 내용 · 담당 변경, 다시 언급(merged), 완료 · 취소 · 다시 열림 신호, 실행 receipt만 센다 (lib/actions/changed.ts).
   * 사용자 자신의 수정과 AI가 새로 만든 할 일은 바뀜이 아니다. 순서와는 상관없다. 예전 서버에는 없다(없으면 false)
   */
  changed: z.boolean().default(false),
});

// 주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?" (지표 5). week_start: 그 주 월요일 (한국 시간)
export const weeklyCheckPromptSchema = z.object({ week_start: z.iso.date() });

/**
 * 원문 처리 실패 까닭 (sources.processing_error_code, 마이그레이션 20261020000000).
 * ai_quota: AI 공급자가 한도 · 잔액으로 거절, ai_timeout: AI 응답 시간 초과, ai_output: AI 응답 형식이 깨짐,
 * consent: 처리 도중 외부 AI 처리 동의 철회, expired: 하루가 지나도록 멈춰 다시 처리하지 않고 닫음, internal: 그 밖.
 */
export const SOURCE_FAILURE_CODES = ["ai_quota", "ai_timeout", "ai_output", "consent", "expired", "internal", "ai_budget_exhausted", "ai_user_daily_budget_exhausted", "ai_global_daily_budget_exhausted", "ai_global_budget_exhausted", "ai_pricing_unavailable", "ai_provider_bound_violation", "ai_budget_unavailable", "billing_required"] as const;
export const sourceFailureCodeSchema = z.enum(SOURCE_FAILURE_CODES);
export type SourceFailureCode = z.infer<typeof sourceFailureCodeSchema>;

/**
 * 처리에 실패한 원문: 실패한 지(processed_at) 하루 안의 글 원문 중 processing_status failed (다시 처리를 기다리는 것 포함, 할 일 DB 항목 제외).
 * 하루가 지난 실패는 세지 않는다 (사라지지 않는 실패가 남지 않게). 앱이 목록이 비었을 때 "All caught up" 대신 실패를 보인다.
 * 실패 원문 목록은 앱이 RLS로 직접 읽는다 (sources: processing_status = 'failed', processing_error_code, processed_at. 같은 범위로 거른다).
 */
export const failedSourcesSchema = z.object({
  count: z.number().int().nonnegative(),
  /** 마지막 실패 시각 (없으면 null) */
  latest_at: z.iso.datetime({ offset: true }).nullable(),
  /** 마지막 실패의 까닭. 없거나 까닭을 기록하기 전(20261020000000 전)의 실패면 null */
  reason: sourceFailureCodeSchema.nullable(),
});
export type FailedSources = z.infer<typeof failedSourcesSchema>;

/**
 * 목록 섹션마다 처음에 보일 개수 (U1 접기: 넘으면 "Show N More"). 앱이 그대로 쓰고, 서버가 바꾸면 앱 배포 없이 바뀐다.
 * 개수(몇 개가 있나)는 내려주지 않는다: 목록이 전부 오므로 앱이 센다. 예전 서버에는 없다(없으면 기본값 2 · 5 · 5)
 */
export const NOW_SECTION_LIMITS = { review: 2, in_progress: 5, to_do: 5 } as const;
export const sectionLimitsSchema = z.object({
  /** Review (확인 요청, confirmations) */
  review: z.number().int().positive(),
  /** In Progress (now 중 착수한 것) */
  in_progress: z.number().int().positive(),
  /** To Do (now 중 착수 전) */
  to_do: z.number().int().positive(),
});

// GET /api/v1/now
export const nowResponseSchema = z.object({
  now: z.array(rankedActionSchema),
  confirmations: z.array(rankedActionSchema),
  /** 이번 주에 물어볼 주간 질문. 물을 때가 아니면 null (필드는 항상 있다) */
  weekly_check: weeklyCheckPromptSchema.nullable(),
  /** 처리에 실패한 원문 (필드는 항상 있다. 못 읽으면 count 0으로 두고 목록은 그대로 돌려준다). 예전 서버에는 없다 */
  failed_sources: failedSourcesSchema,
  section_limits: sectionLimitsSchema.default(NOW_SECTION_LIMITS),
});
export type NowResponse = z.infer<typeof nowResponseSchema>;

// POST /api/v1/weekly-check — 주간 질문 응답. 이번 주(또는 바로 전 주)만 받고, 같은 주에 다시 답하면 덮어쓴다. 204
// 주간 질문이 꺼져 있으면(WEEKLY_CHECK_ENABLED=false) 400 invalid_request.
export const weeklyCheckAnswerSchema = z.enum(["yes", "no", "skipped"]);
export const weeklyCheckRequestSchema = z.object({ week_start: z.iso.date(), answer: weeklyCheckAnswerSchema });
export type WeeklyCheckRequest = z.infer<typeof weeklyCheckRequestSchema>;

// POST /api/v1/sources/:id/missing — 빠진 할 일 신고. 사용자가 원문 구절을 골라 "여기 내 할 일이 있다"고 알려준다 (지표 4).
// 구절은 원문에 실제로 있어야 한다 (공백 · 문장부호 차이는 무시). 처리는 동기(수 초)로 하고 결과를 바로 돌려준다.
// 사용자별로 10분에 10번까지 (넘으면 429 rate_limited, Retry-After 헤더).
export const missingReportRequestSchema = z.object({ quote: z.string().trim().min(1).max(2000) });
export type MissingReportRequest = z.infer<typeof missingReportRequestSchema>;

/**
 * 파이프라인의 어느 단계에서 빠졌나: 처리 실패 / 추출 안 됨(검증 탈락 포함, 연결 메일의 인용된 옛 메일 속이라 버린 것도) / Jev 기각 / 다른 Action에 합쳐짐.
 * 서버 안에서는 quoted_history를 따로 세지만(MISS_STAGES, 이벤트 · 지표) 응답에는 not_extracted로 나간다 (responseMissStage).
 */
export const missStageSchema = z.enum(RESPONSE_MISS_STAGES);

export const missingReportResponseSchema = z.object({
  /**
   * created: 새 Action을 만듦.
   * already_tracked: 이미 있는 Action (신고로 세지 않는다). 이 원문의 같은 구절이 이미 근거인 Action이면 상태와 상관없이
   * (끝냈거나 지운 것도) 그대로 돌려주고, 아니면 확실히 같은 열린 Action에 근거만 더한다.
   */
  status: z.enum(["created", "already_tracked"]),
  action: actionSummarySchema,
  /** already_tracked면 null */
  stage: missStageSchema.nullable(),
});
export type MissingReportResponse = z.infer<typeof missingReportResponseSchema>;

// PATCH /api/v1/actions/:id — 사용자 수정. 바뀐 필드마다 user_edited 이벤트가 남는다 (지표 1).
export const editActionRequestSchema = z
  .object({
    title: z.string().trim().min(1).max(200).optional(),
    due_date: z.iso.date().nullable().optional(),
    status: z.enum(["open", "done"]).optional(),
    owner: z.enum(["me", "other"]).optional(),
  })
  .refine((body) => Object.keys(body).length > 0, { message: "바꿀 필드가 하나는 있어야 합니다" });
export type EditActionRequest = z.infer<typeof editActionRequestSchema>;

// POST /api/v1/actions — 직접 추가 (Mac 런처: 찾는 할 일이 없으면 제목으로 추가, 기한 · 관련 원문 구절은 선택).
// 값은 사용자 Claim(origin user)으로 정하고 user_created 이벤트를 남긴다. 확인 요청은 만들지 않는다.
// 원문 구절을 고른 직접 추가(이벤트 source_id 있음)만 추출이 놓친 신호(지표 4)로 세고, 구절 없는 직접 추가는 일반 입력으로 따로 센다 (A42).
// source_id와 quote는 함께 보낸다. 구절은 그 원문에 실제로 있어야 한다 (공백 · 문장부호 차이는 무시).
// 201 { action, status: "created" } · 200 { action, status: "already_tracked" } (createActionResponseSchema).
// 오류: 400 invalid_request(원문에 없는 구절 · 할 일 DB 항목 · 보관 기간이 지난 원문 포함)
// · 404 not_found(없거나 남의 원문) · 429 rate_limited(사용자별 10분에 30번, Retry-After 헤더. already_tracked는 세지 않는다).
export const createActionRequestSchema = z
  .object({
    title: z.string().trim().min(1).max(200),
    due_date: z.iso.date().nullable().optional(),
    source_id: z.uuid().optional(),
    quote: z.string().trim().min(1).max(2000).optional(),
  })
  .refine((body) => body.source_id === undefined || body.quote !== undefined, { message: "원문을 고르면 구절도 필요합니다", path: ["quote"] })
  .refine((body) => body.quote === undefined || body.source_id !== undefined, { message: "구절은 원문과 함께 보냅니다", path: ["source_id"] });
export type CreateActionRequest = z.infer<typeof createActionRequestSchema>;

export const createActionResponseSchema = z.object({
  action: actionSummarySchema,
  /**
   * created(201): 새 Action을 만듦.
   * already_tracked(200): 고른 구절이 그 원문에서 이미 Action의 근거다 (누락 신고와 같은 확인, 끝냈거나 지운 것도).
   * 그 Action을 그대로 돌려주고 보낸 제목 · 기한은 반영하지 않는다 (바꾸려면 PATCH /api/v1/actions/:id).
   */
  status: z.enum(["created", "already_tracked"]),
});
export type CreateActionResponse = z.infer<typeof createActionResponseSchema>;

// POST /api/v1/actions/:id/progress — 작업 상태 (할 일 · 진행 중 · 완료). 200 { action } (actionResponseSchema).
// to_do: 열림 + 착수 전. 완료였으면 다시 열고(PATCH status open과 같은 user_edited), 착수했었으면 착수를 되돌린다(user_unstarted).
// in_progress: 열림 + 착수. 완료였으면 다시 열고, 착수 전이면 착수한다(start와 같은 user_started · action_started).
// done: 완료 (PATCH status done과 같은 user_edited). 착수 시각은 그대로 둔다.
// 상태 · 착수 시각은 한 트랜잭션으로 바뀐다. 이미 그 상태면 아무것도 쓰지 않고 그대로 돌려준다.
// 오류: 400 invalid_request(본문) · 404 not_found(없거나 남의 것 · 취소된 Action) · 409 conflict(동시 수정이 계속 겹침).
export const actionProgressStateSchema = z.enum(["to_do", "in_progress", "done"]);
export type ActionProgressState = z.infer<typeof actionProgressStateSchema>;
export const actionProgressRequestSchema = z.object({ state: actionProgressStateSchema });
export type ActionProgressRequest = z.infer<typeof actionProgressRequestSchema>;

// PUT /api/v1/actions/:id/notes — notes are preserved verbatim and versioned independently of Action fields.
export const ACTION_NOTES_MAX_UTF16 = 10_000;
export const actionNotesRequestSchema = z.object({
  markdown: z.string().refine((value) => value.length <= ACTION_NOTES_MAX_UTF16, { message: "메모는 10,000자까지 저장할 수 있습니다" }),
  expected_revision: z.number().int().min(0).max(2_147_483_647),
}).strict();
export type ActionNotesRequest = z.infer<typeof actionNotesRequestSchema>;

export const actionNotesResponseSchema = z.object({
  action_id: z.uuid(),
  markdown: z.string(),
  revision: z.number().int().nonnegative(),
});
export type ActionNotesResponse = z.infer<typeof actionNotesResponseSchema>;

// POST /api/v1/actions/:id/seen — 본 것 표시 (U1 바뀜 점). 본문 없음(보내도 읽지 않는다), 204.
// 지금 /now에 바뀜(changed)으로 보일 할 일일 때만 user_seen 이벤트 한 줄을 남기고, 아니면 아무것도 쓰지 않는다:
// 다시 보내도 · 바뀌지 않은 할 일을 보내도 204 그대로라 화살표로 지나가도 이벤트가 쌓이지 않는다. actions 행은 바뀌지 않는다.
// 오류: 404 not_found(id가 uuid가 아님 · 없거나 남의 것).

// PATCH · DELETE · confirm · start · progress 응답
export const actionResponseSchema = z.object({ action: actionSummarySchema });

// POST /api/v1/actions/:id/handoff — 본문 없음은 결정론적 문서, { mode: "assisted" }는 평가와 실행 계획 초안까지 만든다.
export const handoffRequestSchema = z.object({ mode: z.literal("assisted") }).strict();
export type HandoffRequest = z.infer<typeof handoffRequestSchema>;

export const handoffAssessmentSchema = z.object({
  effort: z.enum(["low", "medium", "high", "unknown"]),
  difficulty: z.enum(["low", "medium", "high", "unknown"]),
  context: z.enum(["sufficient", "needs_clarification"]),
  model: z.string().trim().min(1).max(200),
  rubric_version: z.literal("handoff-v1"),
});
export type HandoffAssessment = z.infer<typeof handoffAssessmentSchema>;

export const handoffResponseSchema = z.object({
  action_id: z.uuid(),
  title: z.string(),
  /** 그대로 복사해 AI 도구에 붙여 넣는 문서 */
  markdown: z.string(),
  /** 예전 서버는 보내지 않는다. 값이 없으면 클라이언트는 평가 없는 문맥 문서로 표시한다. */
  assessment: handoffAssessmentSchema.optional(),
});
export type HandoffResponse = z.infer<typeof handoffResponseSchema>;

// POST /api/v1/metric-events — 앱이 직접 남기는 지표. action_started · handoff_used는 해당 API가 서버에서 남긴다 (중복 집계 방지). v1은 동결이다 (contract-v1-freeze.test.ts).
export const metricEventRequestSchema = z.object({
  type: z.enum(["app_opened"]),
  action_id: z.uuid().optional(),
});

// POST /api/v2/external-sessions/shown — 레일의 외부 세션 목록(On this Mac)이 행 1개 이상으로 보인 날의 지표 external_sessions_shown (OA 외부 세션 PR1).
// 값은 구간 문자열뿐이다 (글 · 수 0). 앱의 열 권한 없이 route가 서버 권한으로 남기고, 같은 날 두 번째는 서버가 조용히 넘긴다 (20261203000000).
export const EXTERNAL_ROWS_BUCKETS = ["1", "2-5", "6-15", "16+"] as const;
export const EXTERNAL_HELD_BUCKETS = ["0", "1-2", "3+"] as const;
export const externalSessionsShownRequestSchema = z.strictObject({
  rows_bucket: z.enum(EXTERNAL_ROWS_BUCKETS),
  held_bucket: z.enum(EXTERNAL_HELD_BUCKETS),
});
export type ExternalSessionsShownRequest = z.infer<typeof externalSessionsShownRequestSchema>;

// POST /api/v2/external-sessions/claude-app-opened — 사용자가 Claude 데스크톱 세션 보기(레일 링 · Sessions의 줄)를 연 날의 지표 claude_app_session_opened (OA PR-D2, 계약 21.6).
// **종류만이다**: 본문에 칸이 하나도 없다 (세션 id · 제목 · 폴더 0). 앱의 열 권한 없이 route가 서버 권한으로 남기고, 같은 날(UTC) 두 번째는 서버가 조용히 넘긴다 (20261206000000).
export const claudeAppSessionOpenedRequestSchema = z.strictObject({});
export type ClaudeAppSessionOpenedRequest = z.infer<typeof claudeAppSessionOpenedRequestSchema>;

// PUT /api/v2/external-sessions — Mac이 Taskforce 밖에서 시작한 Claude Code 세션의 목록을 알린다 (OA 외부 세션 PR1, 계약 16장). 스냅샷 교체: 이번 목록에 없는 그 Mac의 행은 지운다.
// 서버에 가는 것은 제목 · 상태 · 마지막 활동 시각 · 불투명 id뿐이다. 대화 본문 · 경로 · 폴더 이름 · Claude 세션 id는 보내지 않는다.
// id = Mac이 세션 UUID에서 Mac에만 있는 열쇠로 만든 HMAC-SHA256의 hex 64자 (서버는 UUID를 알 수 없다).
export const EXTERNAL_SESSION_STATES = ["available", "running_claude_app", "running_terminal", "running_elsewhere", "unknown", "unavailable"] as const;
export const externalSessionStateSchema = z.enum(EXTERNAL_SESSION_STATES);
export type ExternalSessionState = z.infer<typeof externalSessionStateSchema>;
export const EXTERNAL_SESSIONS_MAX = 50;
export const EXTERNAL_TITLE_MAX = 200;
export const externalSessionRefSchema = z.string().regex(/^[0-9a-f]{64}$/);
// 제어 글자 · 서식 글자(방향 바꿈 포함) · 줄 구분자는 앱이 지워서 보낸다. 서버는 그런 제목을 받지 않는다
export const externalSessionTitleSchema = z
  .string()
  .min(1)
  .max(EXTERNAL_TITLE_MAX)
  .refine((title) => !/[\p{Cc}\p{Cf}\u2028\u2029]/u.test(title) && title.trim() === title, { message: "invalid title" });
export const externalSessionReportRequestSchema = z.strictObject({
  bridge_id: z.uuid(),
  sessions: z
    .array(
      z.strictObject({
        id: externalSessionRefSchema,
        title: externalSessionTitleSchema.nullable(),
        state: externalSessionStateSchema,
        last_activity_at: z.iso.datetime({ offset: true }),
      }),
    )
    .max(EXTERNAL_SESSIONS_MAX)
    .refine((rows) => new Set(rows.map((row) => row.id)).size === rows.length, { message: "duplicate id" }),
});
export type ExternalSessionReportRequest = z.infer<typeof externalSessionReportRequestSchema>;
export const externalSessionReportResponseSchema = z.strictObject({ kept: z.number().int().min(0), removed: z.number().int().min(0) });
export type ExternalSessionReportResponse = z.infer<typeof externalSessionReportResponseSchema>;

// 연동: 데이터베이스(Notion 데이터 소스)마다 역할과 속성 매핑 (connections.settings.dataSources[id], docs/INTEGRATIONS.md)
export const taskStatusSchema = actionStatusSchema;
export const taskPropertyMapSchema = z.object({
  /** 속성 id */
  title: z.string().min(1),
  assignee: z.string().min(1),
  due: z.string().min(1).nullable(),
  status: z.object({ id: z.string().min(1), type: z.enum(["status", "checkbox"]) }),
});
export type TaskPropertyMap = z.infer<typeof taskPropertyMapSchema>;

export const dataSourceSettingSchema = z.object({
  /** tasks: 속성을 그대로 Claim으로, text: 글 원문으로 읽음(회의록 · 문서), ignore: 가져오지 않음. 예전 이름 meetings는 text로 읽는다 */
  role: z.preprocess((role) => (role === "meetings" ? "text" : role), z.enum(["tasks", "text", "ignore"])),
  // 긴 제목 하나 때문에 연결 설정 전체를 못 읽는 일이 없게, 읽을 때도 자른다.
  title: z
    .string()
    .transform((title) => title.slice(0, 200))
    .nullable(),
  props: taskPropertyMapSchema.optional(),
  /** 상태 옵션 id(체크박스는 "true" · "false") → open · done · dropped */
  statusMap: z.record(z.string(), taskStatusSchema).optional(),
  /** 확인한 시각. 확인 전에는 할 일로 처리하지 않는다 */
  confirmedAt: z.string().optional(),
  /**
   * 누가 확인했나. auto: 할 일 DB로 보이고 담당 · 상태 · 기한 속성이 분명해 동기화가 확인함 (notion/tasks.ts autoConfirmSetting).
   * 사용자가 역할 · 매핑을 저장하면 빠진다. 없으면 사용자가 확인한 것
   */
  confirmedBy: z.enum(["auto"]).optional(),
  /** 처음 켤 때 열린 할 일을 한 번 가져온 시각 */
  backfilledAt: z.string().optional(),
  /** 동기화가 처음 이 DB를 본 시각 (확인 전). 나중에 공유가 끊기면 알아차리고, 새로 공유된 DB를 다시 훑는 기준이 된다 */
  seenAt: z.string().optional(),
});
export type DataSourceSetting = z.infer<typeof dataSourceSettingSchema>;

export const connectionSettingsSchema = z.looseObject({
  dataSources: z.record(z.string(), dataSourceSettingSchema).optional(),
  /** 마지막 동기화가 확인한 연결 상태: 전에 읽던 DB 중 지금 읽을 수 없는 것 (공유가 끊김) */
  health: z
    .object({
      unreachable: z.array(z.object({ id: z.string(), title: z.string().nullable() })),
      checkedAt: z.string(),
    })
    .optional(),
});

// GET /api/v1/connections/:id/data-sources — 공유된 데이터베이스와 역할 (확인 전이면 제안값)
export const dataSourceSummarySchema = z.object({
  id: z.string(),
  title: z.string().nullable(),
  setting: dataSourceSettingSchema,
  confirmed: z.boolean(),
  /** false: 설정은 저장돼 있지만 연결에서 더 이상 읽을 수 없음 (Notion에서 공유가 빠짐) */
  reachable: z.boolean(),
  properties: z.array(z.object({ id: z.string(), name: z.string(), type: z.string() })),
  /** 상태 속성의 옵션 (propertyId: 어느 상태 속성의 옵션인지) */
  statusOptions: z.array(z.object({ propertyId: z.string(), id: z.string(), name: z.string(), group: z.string().nullable() })),
});
export type DataSourceSummary = z.infer<typeof dataSourceSummarySchema>;
export const dataSourcesResponseSchema = z.object({ dataSources: z.array(dataSourceSummarySchema) });

// PUT /api/v1/connections/:id/data-sources/:dataSourceId — 역할 · 매핑 확인 (confirmedAt은 서버가 넣는다)
export const saveDataSourceRequestSchema = dataSourceSettingSchema
  .omit({ confirmedAt: true, confirmedBy: true, backfilledAt: true, seenAt: true, title: true })
  .refine((s) => s.role !== "tasks" || s.props, { message: "할 일 DB에는 속성 매핑이 필요합니다.", path: ["props"] });

// POST /api/v1/devices — 알림용 기기 토큰 (APNs)
export const deviceRequestSchema = z.object({
  token: z.string().regex(/^[0-9a-fA-F]{32,200}$/, "APNs 기기 토큰(16진수)"),
  platform: z.enum(["ios", "macos"]),
  environment: z.enum(["sandbox", "production"]).default("production"),
  app_version: z.string().max(40).optional(),
});

// ─── 연결 (docs/GO_LIVE.md 1장) ─────────────────────────────
// 앱은 연결 목록을 Supabase에서 직접(RLS) 읽는다: connections의 connectionSummarySchema 열.

/** 앱에서 연결할 수 있는 1단계 연동. google = Calendar · Meet 전사, gmail = 메일 (Google 프로젝트가 따로다) */
export const connectProviderSchema = z.enum(["notion", "google", "gmail", "slack"]);
export type ConnectProvider = z.infer<typeof connectProviderSchema>;

/** reauth: 토큰이 만료돼 다시 연결해야 함 (Google 테스트 상태 7일 만료 등) */
export const connectionStatusSchema = z.enum(["active", "error", "revoked", "reauth"]);

export const connectionSummarySchema = z.object({
  id: z.uuid(),
  provider: z.enum(["notion", "google", "gmail", "slack", "github"]),
  /** 워크스페이스 · 계정 이름 */
  display_name: z.string().nullable(),
  status: connectionStatusSchema,
  last_synced_at: z.string().nullable(),
  /** 사용자에게 보여줄 짧은 오류 */
  last_error: z.string().nullable(),
  /** 서버가 동기화하는 동안의 잠금(시작 시각), 끝나면 null. 앱의 "Syncing…" 근거 */
  sync_started_at: z.string().nullable(),
  settings: connectionSettingsSchema,
});
export type ConnectionSummary = z.infer<typeof connectionSummarySchema>;

// POST /api/v1/connections/{provider}/start — OAuth 권한 화면 주소. 앱은 ASWebAuthenticationSession(callback scheme taskforce)으로 연다.
// 본문은 없어도 된다 (알 수 없는 필드는 무시한다: 예전 앱이 보내던 return은 더 이상 쓰지 않는다).
// 권한 화면 뒤에는 taskforce://connections/{provider}?handoff=<id>로 돌아온다 (id는 43자 base64url, 2분 동안 한 번만 쓸 수 있다).
// 앱은 곧바로 로그인한 사용자로 POST /api/v1/connections/{provider}/complete {handoff}를 불러 연결을 마친다.
// 실패하면 taskforce://connections/{provider}?status=<connectionAppCallbackErrorSchema>로 돌아온다.
// 오류: 모르는 provider 404 not_found · 아직 붙이지 않은 서비스 400 invalid_request("아직 연결할 수 없어요.")
//       · 외부 AI 처리 동의 전 409 conflict("외부 AI 처리 동의가 필요해요.") · 10분에 10번을 넘으면 429 rate_limited(Retry-After).
export const connectionStartRequestSchema = z.object({});
export const connectionStartResponseSchema = z.object({ url: z.url() });
export type ConnectionStartResponse = z.infer<typeof connectionStartResponseSchema>;

/**
 * 권한 화면을 마쳤을 때의 결과. connected_empty: 고른 페이지가 없음, connected_no_meetings: 회의록 DB가 빠짐 (Notion).
 * connected_partial: 권한 화면에서 일부 권한의 체크를 빼서 받은 것만으로 연결했음 (Google. Calendar만 · Meet만, 받은 범위는 연결 설정 scopes).
 * missing_scope: 권한 화면에서 필요한 권한의 체크를 빼서 연결하지 않았음 (Gmail · Google. 받은 토큰은 바로 폐기한다, google-integration.md G10).
 * 이 값을 모르는 옛 앱은 연결 실패 문구를 보인다.
 */
export const connectedStatusSchema = z.enum(["connected", "connected_partial", "connected_empty", "connected_no_meetings", "missing_scope"]);
export type ConnectedStatusValue = z.infer<typeof connectedStatusSchema>;
/** 연결이 생기지 않은 결과 (연결 지표 · 첫 동기화를 하지 않는다) */
export const isConnected = (status: ConnectedStatusValue) => status !== "missing_scope";

/**
 * 앱 흐름에서 권한 화면이 실패로 돌아올 때 (taskforce://connections/{provider}?status=…).
 * denied: 사용자가 취소함, error: 서비스 · 서버 오류, invalid_state: 요청이 만료 · 재사용 · 변조됨.
 */
export const connectionAppCallbackErrorSchema = z.enum(["denied", "error", "invalid_state"]);
export type ConnectionAppCallbackError = z.infer<typeof connectionAppCallbackErrorSchema>;

// POST /api/v1/connections/{provider}/complete — 앱 흐름의 연결 마치기 (Bearer 또는 웹 쿠키).
// handoff는 권한 화면 뒤 돌아온 주소의 값. 연결을 시작한 사용자만, 2분 안에, 한 번만 완료할 수 있다.
// 200 { status }: 연결됨. 서버가 곧바로 첫 동기화를 시작한다.
// 오류: handoff가 없거나 · 만료됐거나 · 이미 썼거나 · 다른 사용자가 시작한 것 404 not_found(모두 같은 응답)
//       · 외부 AI 처리 동의 전 409 conflict (handoff는 쓰지 않으므로 2분 안에 동의하고 다시 부르면 된다)
//       · 서비스 토큰 교환 실패 502 internal_error(다시 연결해야 한다) · 모르는 provider 404 · 아직 붙이지 않은 서비스 400.
export const connectionCompleteRequestSchema = z.object({ handoff: z.string().min(32).max(200) });
export type ConnectionCompleteRequest = z.infer<typeof connectionCompleteRequestSchema>;
export const connectionCompleteResponseSchema = z.object({ status: connectedStatusSchema });
export type ConnectionCompleteResponse = z.infer<typeof connectionCompleteResponseSchema>;

/**
 * 웹(/lab) 흐름의 결과 (/lab?{provider}=…). 앱은 쓰지 않는다.
 * consent_required: 외부 AI 처리 동의 전이라 시작하지 않음.
 */
export const connectionCallbackStatusSchema = z.enum([...connectedStatusSchema.options, ...connectionAppCallbackErrorSchema.options, "consent_required"]);
export type ConnectionCallbackStatus = z.infer<typeof connectionCallbackStatusSchema>;

// POST /api/v1/connection-requests — 2단계 연동 "원해요". 204. 같은 서비스를 다시 보내도 하나로 센다.
export const requestableProviderSchema = z.enum(["microsoft", "zoom", "github", "linear", "jira"]);
export const connectionRequestSchema = z.object({ provider: requestableProviderSchema });
export type ConnectionRequest = z.infer<typeof connectionRequestSchema>;

// ─── 물어보기 ───────────────────────────────────────────────
// POST /api/v1/ask — 내 할 일 · 근거 원문에서 찾아 답한다. 답은 질문의 언어로, 인용은 모두 원문에 실제로 있는 구절만 남긴다.
// 근거를 찾지 못하면 unknown: true와 짧은 "찾지 못했어요" 답 (citations는 비어 있다).
// 외부 AI 처리 동의 전 409 conflict. 사용자별로 10분에 20번까지 (넘으면 429 rate_limited, Retry-After 헤더).
export const askRequestSchema = z.object({ question: z.string().trim().min(1).max(500) });
export type AskRequest = z.infer<typeof askRequestSchema>;

export const askCitationSchema = z.object({
  /** 이 인용이 근거인 Action (없으면 null) */
  action_id: z.string().nullable(),
  source_id: z.string(),
  source_title: z.string().nullable(),
  source_kind: z.string(),
  occurred_at: z.string().nullable(),
  external_url: z.string().nullable(),
  /**
   * 원문에서 그대로 잘라 낸 이어진 구절 (모델이 쓴 문자열이 아니다. 떨어진 구절을 "..."로 이은 인용은 버린다).
   * 보관 기간(90일)이 지나 원문 글이 지워진 원문은 저장된 근거 인용 안에서 잘라 낸다.
   */
  quote: z.string(),
});
export type AskCitation = z.infer<typeof askCitationSchema>;

export const askResponseSchema = z.object({
  answer: z.string(),
  unknown: z.boolean(),
  citations: z.array(askCitationSchema),
});
export type AskResponse = z.infer<typeof askResponseSchema>;

// DELETE /api/v1/account — 계정 삭제 (App Store 5.1.1(v)). 본문은 없어도 된다 (deleteAccountRequestSchema, 선택).
// 로그인 계정을 지우면 원문 · 할 일 · Claim · 근거 · 변경 이력 · 지표 · 프로필 · 연결(토큰) · 기기가 DB에서 함께 지워진다 (on delete cascade).
// 되돌릴 수 없다. 이미 지워진 계정이면 그대로 성공으로 답한다 (재시도해도 안전).
// 지우기 전에 연동 토큰을 서비스 쪽에서도 폐기하고(가능한 서비스만), Sign in with Apple 토큰을 Apple REST API로 폐기한다.
// Supabase는 앱 로그인(ID 토큰)에서 Apple 토큰을 받지 않으므로, 앱이 삭제 직전에 받은 authorization code를 선택으로 보낼 수 있다.
// 폐기가 실패해도 삭제는 계속한다.
export const deleteAccountRequestSchema = z.object({ apple_authorization_code: z.string().min(1).max(2000).optional() });
export type DeleteAccountRequest = z.infer<typeof deleteAccountRequestSchema>;
// Mac은 브라우저 창(Apple 웹 로그인)으로 재확인한 code를 보낸다: 그 code는 Services ID 것이라 서버가 폐기할 client를 알아야 한다.
// apple_client: "app"(기본, 번들 id: iPhone 앱 안 로그인의 code) · "web"(Services ID: Mac 웹 재확인의 code). 더하기만 하는 optional 필드라 v1 경로 그대로다.
// 동결된 deleteAccountRequestSchema(contract-v1-freeze.test.ts의 지문)는 건드리지 않고, 서버는 이 확장을 읽는다 (옛 본문은 그대로 파싱된다).
export const appleClientSchema = z.enum(["app", "web"]);
export type AppleClient = z.infer<typeof appleClientSchema>;
export const deleteAccountWithAppleClientRequestSchema = deleteAccountRequestSchema.extend({ apple_client: appleClientSchema.optional() });
export type DeleteAccountWithAppleClientRequest = z.infer<typeof deleteAccountWithAppleClientRequestSchema>;
export const deleteAccountResponseSchema = z.object({ deleted: z.literal(true) });
export type DeleteAccountResponse = z.infer<typeof deleteAccountResponseSchema>;
// 서버가 Apple 토큰을 폐기했는지 알리는 선택 필드 (동결된 deleteAccountResponseSchema는 그대로 두고 확장): true = 폐기함, false = 건너뜀(code 없음 · 다른 계정의 code · 설정 없음 · Apple 거절 · 시간 초과),
// 없음 = Apple 가입과 상관없는 계정(이거나 옛 서버). 앱은 false일 때 로그인 화면에 "직접 지우는 방법" 한 줄을 띄운다.
export const deleteAccountWithRevocationResponseSchema = deleteAccountResponseSchema.extend({ apple_revoked: z.boolean().optional() });
export type DeleteAccountWithRevocationResponse = z.infer<typeof deleteAccountWithRevocationResponseSchema>;

// POST /api/v1/apple/return — Mac의 Apple 웹 로그인(브라우저 창)이 form_post로 돌아오는 곳 (로그인 없음, 저장 · 기록 0).
// Apple이 application/x-www-form-urlencoded로 보낸 결과를 taskforce://auth/apple?… 로 넘기기만 한다 (src/lib/apple/web-return.ts).
// state는 앱이 만든 무작위 값(앱이 자기 것인지 확인한다). user(첫 로그인 때 오는 이름 · 이메일 JSON)는 받되 버린다.
export const APPLE_RETURN_MAX_BYTES = 16 * 1024;
export const appleReturnStateSchema = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
export const appleReturnFormSchema = z.object({
  state: appleReturnStateSchema,
  code: z.string().min(1).max(2000).optional(),
  id_token: z.string().min(1).max(8000).optional(),
  error: z.string().min(1).max(100).optional(),
  user: z.string().optional(),
});
export type AppleReturnForm = z.infer<typeof appleReturnFormSchema>;

// ─── 처리방침 변경 안내 ─────────────────────────────────────
// GET /api/v1/legal — 개인정보 처리방침의 현재 판 · 시행 예정 판과 이 계정에 보일 변경 안내 (Bearer 또는 웹 쿠키).
// 판 · 시행일은 src/lib/legal/policy.ts 한 곳에서 정한다. 시행일은 한국 시간 0시부터이고, 시행 예정 판은 시행일이 지나면 현재 판이 된다.
// notice: 시행 예정 판이 있으면 "upcoming"(시행 전 안내, url은 그 판의 버전 주소), 없으면 계정이 현재 판의 시행일 전에
// 만들어졌을 때만 시행 뒤 30일 동안 "updated". 새 계정은 가입할 때 현재 판에 동의했으므로 안내하지 않는다.
// 앱은 notice.version을 본 적이 없을 때만 한 줄을 보이고, 열거나 닫으면 그 판을 기기에 계정별로 본 것으로 적는다.
// 서버에는 남기지 않는다(처리방침에 없는 이용 기록이 된다). 앱은 모르는 kind를 안내 없음으로 읽는다.
// 오류: 가입 시각이 필요한데(시행 예정 판 없음 · 시행 뒤 30일 안) 읽지 못하면 500 (앱은 조용히 넘긴다).
export const policyVersionSchema = z.object({
  version: z.string().min(1),
  effective_date: z.iso.date(),
  url: z.object({ ko: z.url(), en: z.url() }),
});
export type PolicyVersion = z.infer<typeof policyVersionSchema>;

export const policyNoticeSchema = policyVersionSchema.extend({ kind: z.enum(["updated", "upcoming"]) });
export type PolicyNotice = z.infer<typeof policyNoticeSchema>;

export const legalResponseSchema = z.object({
  privacy: z.object({
    current: policyVersionSchema,
    upcoming: policyVersionSchema.nullable(),
    notice: policyNoticeSchema.nullable(),
  }),
});
export type LegalResponse = z.infer<typeof legalResponseSchema>;

// ─── 실행 (U2, docs/EXECUTION.md) ───────────────────────────
// Action 하나에 Taskforce가 내장 초안을 쓰는 run. 밖으로는 아무것도 보내지 않는다 (발송은 U6a).
// 쓰기만 API로 한다: run 만들기 · 멈추기. run · 단계 · 산출물은 앱이 RLS로 읽는다 (execution_runs · execution_steps · execution_artifacts, 아래 스키마의 열).
// 크레딧 원장 · 계정은 클라이언트가 읽지 못해 합계만 GET /api/v1/credits로 준다.
// 기능 플래그(EXECUTION_ENABLED)가 꺼졌거나 실행 주체 허용 목록 밖이면 세 route 모두 404 not_found (존재를 드러내지 않는다).

/** run 상태 (execution_runs.state). 끝 상태는 done · failed · stopped */
export const runStateSchema = z.enum(["queued", "running", "waiting_approval", "done", "failed", "stopped"]);
/**
 * 실행기가 막힌 이유 (execution_runs.hold_reason): 차단 스위치 · 도구 / 실행 주체 / 보내는 연결 없음 / 크레딧 부족. 풀리면 sweep이 이어 간다.
 * 끝나지 않은 run(queued · running · waiting_approval)에서만 뜻이 있다: 멈춘(stopped) run에는 멈추기 전의 값이 남는다 (크레딧을 기다리는 run은 state도 함께 본다)
 */
export const runHoldReasonSchema = z.enum(["blocked", "actor", "needs_connection", "credit"]);
/** 끝낸 결과 (execution_runs.outcome): 초안 있음 / 보내기는 연결이 필요(초안은 그대로) / 사용자에게 물을 것이 있음(질문은 계획 단계 receipt.question) */
export const runOutcomeSchema = z.enum(["draft_ready", "needs_connection", "needs_input"]);

export const runSummarySchema = z.object({
  id: z.uuid(),
  action_id: z.uuid(),
  goal: z.literal("draft"),
  state: runStateSchema,
  hold_reason: runHoldReasonSchema.nullable(),
  outcome: runOutcomeSchema.nullable(),
  budget_credits: z.number().int().positive().nullable(),
  created_at: z.string(),
  /**
   * 사용자가 멈춘 시각 (execution_runs.stopped_at, DB 시각). POST /runs/:id/stop(어느 기기든)이 열린 run을 멈출 때 처음 한 번 적고 바꾸지 않는다.
   * null: 멈추지 않은 run, 할 일이 닫혀(완료 · 삭제) 서버가 다음 단계 전에 멈춘 run(state stopped, 사용자가 누르지 않았다),
   * 마이그레이션 20261026000000 전에 멈춘 run
   */
  stopped_at: z.string().nullable(),
});
export type RunSummary = z.infer<typeof runSummarySchema>;

/**
 * 단계 receipt (execution_steps.receipt). 글은 사용자에게 보일 것만 담는다.
 * 계획: decision(다음 단계), needs_connection이면 capability, ask_user면 question. 초안: to(초안의 받는 사람, 모델이 자료에서 고른 이름 · 주소).
 * 실패: error (consent: 처리 도중 동의 철회, rejected: AI 공급자가 확정적으로 거절, action_missing: Action이 지워짐, retries_exhausted: 다시 준비 한도,
 * unavailable: 후속 계획이 일시 오류로 끝나지 못함 — 이때 run은 실패가 아니라 draft_ready다)
 */
export const stepReceiptSchema = z.looseObject({
  decision: z.enum(["draft", "needs_connection", "ask_user", "done"]).optional(),
  capability: z.string().optional(),
  question: z.string().optional(),
  to: z.array(z.string()).optional(),
  model: z.string().optional(),
  prompt_version: z.string().optional(),
  error: z.string().optional(),
});

export const stepSummarySchema = z.object({
  id: z.uuid(),
  run_id: z.uuid(),
  seq: z.number().int().positive(),
  kind: z.enum(["plan", "draft", "external"]),
  state: z.enum(["pending", "prepared", "calling", "called", "unknown_outcome", "failed", "skipped"]),
  attempt: z.number().int().nonnegative(),
  receipt: stepReceiptSchema.nullable(),
  created_at: z.string(),
});
export type StepSummary = z.infer<typeof stepSummarySchema>;

/** 초안 (execution_artifacts). 보관 기간(retain_until)이 지나면 본문만 비운다(body = '', body_purged_at) */
export const artifactSchema = z.object({
  id: z.uuid(),
  run_id: z.uuid(),
  step_id: z.uuid(),
  action_id: z.uuid(),
  kind: z.literal("draft"),
  title: z.string(),
  body: z.string(),
  model: z.string(),
  prompt_version: z.string(),
  retain_until: z.string(),
  body_purged_at: z.string().nullable(),
  created_at: z.string(),
});
export type Artifact = z.infer<typeof artifactSchema>;

// POST /api/v1/runs — 열린 내 Action에 내장 초안 run을 만든다 → 202 { run }. 첫 단계(계획)는 응답 뒤에 돈다.
// 차단 스위치가 전체를 막고 있어도 404. 외부 AI 처리 동의 전 409, 없거나 남의 · 열리지 않은 Action 404, 사용자별 10분에 10번을 넘으면 429.
// 크레딧은 여기서 보지 않는다: 초안 단계가 부르기 직전에 예약하고, 모자라면 run이 hold_reason credit으로 기다린다.
export const createRunRequestSchema = z.object({
  action_id: z.uuid(),
  goal: z.literal("draft"),
  /** 사용자가 맡긴 일 (예: "견적 회신 메일 초안 써 줘") */
  request: z.string().trim().min(1).max(2000),
  /**
   * 이 run이 쓸 수 있는 크레딧 상한 (없으면 잔액만 본다). 초안 한 건의 예약(20 크레딧, src/lib/execution/limits.ts)보다 작으면
   * 초안을 한 번도 부르지 못하고 지급으로도 풀리지 않으므로 400으로 받지 않는다 (route가 확인한다: 이 파일은 무료 경로도 읽어 실행 모듈을 가져오지 않는다, A44).
   * 초안 둘을 맡기면 정산 뒤 남은 예산이 다시 예약 이상이어야 둘째 초안을 부른다
   */
  budget_credits: z.number().int().positive().max(1_000_000).optional(),
});
export type CreateRunRequest = z.infer<typeof createRunRequestSchema>;
export const createRunResponseSchema = z.object({ run: runSummarySchema });
export type CreateRunResponse = z.infer<typeof createRunResponseSchema>;

// POST /api/v1/runs/:id/stop — 다음 단계만 막는다 (이미 부르는 단계는 끝까지 결과를 받는다) → 200 { run }. 이미 끝난 run은 그대로 200.
// 없거나 남의 run 404
export const stopRunResponseSchema = z.object({ run: runSummarySchema });
export type StopRunResponse = z.infer<typeof stopRunResponseSchema>;

// GET /api/v1/credits?since=<ISO 8601> — 내 크레딧 합계 (서버가 계정 행 · 원장에서 계산). available = 지급 - 예약 - 사용, reserved = 아직 정산 · 해제하지 않은 예약.
// rate_version: 지금 요율 (c3-v1: 1 크레딧 = $0.001). 지급 기록이 없으면 0 · 0.
// 아래 필드는 Usage & Credits 화면(S3)용으로 나중에 더했다(U2 Mac PR1). 앱은 없는 필드를 기본값으로 읽는다(그 전 서버).
// since: used를 셀 시작 시각. 오프셋이 있는 ISO 8601만 받는다(예: 기기 시간대의 이번 달 1일 00:00을 UTC로 적은 2026-09-30T15:00:00Z.
// +09:00처럼 적으면 쿼리에서 +를 %2B로). 없으면 UTC 이번 달 1일. 형식 오류 · 미래 · 1년 넘게 전이면 400 invalid_request
export const creditsResponseSchema = z.object({
  available: z.number().int().nonnegative(),
  reserved: z.number().int().nonnegative(),
  rate_version: z.string().nullable(),
  /** 끝내지 않은 단계(prepared · calling)에 열린 예약이 있는 run 수 ("Held for N running task(s)") */
  running_runs: z.number().int().nonnegative(),
  /**
   * 끝낸 초안 단계인데 원가가 확정되지 않아 정산을 미룬 예약(A46). reserved에 들어 있다: 진행 중 예약 = reserved - settling.reserved.
   * action_ids: 그 run들의 할 일 id (중복 없이, 앱이 RLS로 제목을 읽는다)
   */
  settling: z.object({
    steps: z.number().int().nonnegative(),
    reserved: z.number().int().nonnegative(),
    action_ids: z.array(z.uuid()),
  }),
  /** since 이후 정산(사용)한 크레딧 합계. since는 실제로 센 시작 시각(UTC ISO 8601) */
  used: z.object({ credits: z.number().int().nonnegative(), since: z.string() }),
  /** 차단 스위치의 전체 행이 열려 있다. false면 POST /api/v1/runs가 404라 앱이 시작을 미리 끈다 */
  accepting_runs: z.boolean(),
  /** 초안 단계 하나의 예약 (src/lib/execution/limits.ts DRAFT_ESTIMATE_CREDITS). 가용 잔액이 이보다 작으면 초안 단계는 크레딧을 기다린다 */
  draft_estimate_credits: z.number().int().positive(),
});
export type CreditsResponse = z.infer<typeof creditsResponseSchema>;

export const apiErrorCodeSchema = z.enum(["unauthorized", "invalid_request", "not_found", "conflict", "rate_limited", "internal_error", "ai_budget_exhausted", "ai_user_daily_budget_exhausted", "ai_global_daily_budget_exhausted", "ai_global_budget_exhausted", "ai_pricing_unavailable", "ai_provider_bound_violation", "ai_budget_unavailable", "billing_required", "ai_timeout", "ai_unavailable"]);

export const apiErrorSchema = z.object({
  error: z.object({ code: apiErrorCodeSchema, message: z.string() }),
});
export type ApiError = z.infer<typeof apiErrorSchema>;

// Supplier USD is separate from execution product credits; cumulative for this beta period.
export const aiSpendSummarySchema = z.object({
  cap_usd: z.number().finite().positive(), confirmed_usd: z.number().finite().nonnegative(),
  reserved_usd: z.number().finite().nonnegative(), pending_count: z.number().int().nonnegative(),
  remaining_usd: z.number().finite().nonnegative().max(10),
  status: z.enum(["available", "exhausted", "provider_bound_violation"]),
});

// Account billing is authoritative on the server; checkout redirects never grant access.
export const billingCheckoutRequestSchema = z.object({ plan: z.enum(["monthly", "annual"]), terms_version: z.literal("2026-10-08") }).strict();
export const billingStatusSchema = z.object({
  status: z.string(), plan: z.enum(["monthly", "annual"]).nullable(),
  trial_ends_at: z.string().nullable(), current_period_ends_at: z.string().nullable(),
  can_use_ai: z.boolean(), can_checkout: z.boolean(),
  monthly_price_usd: z.literal(9.99), annual_price_usd: z.literal(101.9),
  ai_allowance: aiSpendSummarySchema.nullable(), allowance_resets_at: z.string().nullable(),
});
export type BillingStatus = z.infer<typeof billingStatusSchema>;

// ════════════════════════════════════════════════════════════
// 0.2.0 계약 뼈대 (구현 계획 A2) — 타입 · zod만, route는 아직 없다.
// 위의 /api/v1 스키마는 동결이다 (contract-v1-freeze.test.ts): 모양 · literal · enum을 바꾸지 않고, 새 값 · 새 기능은 아래에만 둔다.
// 대화 · 기억 · 범위 · 결제 v2는 /api/v2/*(B1 · B2 · G1), bridge는 설계대로 /api/v1/bridge/*의 새 route(D2)가 쓴다.
// 근거: 0.2.0 아키텍처 5 · 8 · 9 · 10.1장, 런타임 계약 2 · 5 · 10장. 표는 20261103000000_context_core.sql.
// Swift 짝: TaskforceKit AgentBridgeContracts.swift (사건 봉투 · capability · bridge 명령 · heartbeat).
// ════════════════════════════════════════════════════════════

// id 목록은 guid다: start_agent_turn이 sha256에서 만드는 이슈 id(OA D1c, 버전 · variant 자리가 RFC 4122와 다르다)도 refs에 들어간다 (z.uuid()면 refs 전체가 읽히지 않는다)
const idListSchema = z.array(z.guid()).max(100);
const jsonObjectSchema = z.record(z.string(), z.unknown());

/** capability · 사건의 adapter 이름: "agent:<이름>" (예: agent:claude-code) */
export const agentAdapterIdSchema = z.string().max(64).regex(/^agent:[a-z0-9][a-z0-9_-]*$/);

// ─── 대화 v2 (런타임 계약 2장 · 아키텍처 5.6) ──────────────────

/** 사용자 메시지 상한 (런타임 계약 12장). 위임 지시는 질문(Ask 500자)보다 길다 */
export const CONVERSATION_MESSAGE_MAX_CHARS = 4000;

/** 응답 근거의 신뢰 등급 (런타임 계약 10장): T1 확인 사실 · T2 사용자 발화 · T3 실행 결과 · T4 에이전트 주장 · T5 제안/가정 */
export const contextTierSchema = z.enum(["T1", "T2", "T3", "T4", "T5"]);
export type ContextTier = z.infer<typeof contextTierSchema>;

/** 의도 (Jev choice로 가른다). inform · correct는 memory_items에만 쓰고 run · Action을 만들지 않는다 (아키텍처 5.6) */
export const intentKindSchema = z.enum([
  "lookup", "consult", "adopt", "instruct", "modify", "answer", "stop", "preference", "inform", "correct", "other", "organize",
]);
export type IntentKind = z.infer<typeof intentKindSchema>;

/** conversation_messages.intent */
export const messageIntentSchema = z.object({
  kind: intentKindSchema,
  confidence: z.number().min(0).max(1),
  judge_version: z.string().min(1).max(100),
});
export type MessageIntent = z.infer<typeof messageIntentSchema>;

/** assistant 메시지의 제안. 채택은 proposal id로 멱등이다 (같은 제안을 두 번 채택해도 Action · run은 하나) */
export const proposalSchema = z.object({
  id: z.uuid(),
  kind: z.enum(["create_action", "run", "modify", "stop", "preference", "move", "delete", "merge"]),
  payload_hash: z.string().min(1).max(128),
  state: z.enum(["open", "adopted", "superseded", "dismissed"]),
});
export type Proposal = z.infer<typeof proposalSchema>;

/**
 * conversation_messages.refs: 이 메시지가 가리키거나 만든 것. 서버가 쓴다 (모델 출력의 id를 그대로 믿지 않는다).
 * memory_item_ids · context_ids: 무엇을 기억했는지 · 어느 범위에 적용했는지 (ARCH01). 없는 목록은 빈 목록으로 읽는다
 */
export const messageRefsSchema = z.object({
  action_ids: idListSchema.default([]),
  run_ids: idListSchema.default([]),
  artifact_ids: idListSchema.default([]),
  suggestion_ids: idListSchema.default([]),
  dependency_ids: idListSchema.default([]),
  memory_item_ids: idListSchema.default([]),
  context_ids: idListSchema.default([]),
  proposal: proposalSchema.nullable().default(null),
});
export type MessageRefs = z.infer<typeof messageRefsSchema>;

/** conversations 행. context_id: 대화의 기본 범위 (null = All work). 글 보관 기한 뒤 메시지 text만 비운다(text_purged_at) */
export const conversationSchema = z.object({
  id: z.uuid(),
  title: z.string().nullable(),
  context_id: z.uuid().nullable(),
  created_at: z.string(),
  last_message_at: z.string().nullable(),
  last_read_at: z.string().nullable(),
  archived_at: z.string().nullable(),
  text_purged_at: z.string().nullable(),
});
export type Conversation = z.infer<typeof conversationSchema>;

/**
 * 대화 만들기 (POST /api/v2/conversations). id: 앱이 정한 대화 id (B2, 선택). 같은 id로 다시 보내면 새로 만들지 않고 그 대화를 돌려준다(멱등).
 * 다른 사용자가 이미 쓴 id면 409. context_id는 내 범위여야 한다(아니면 404)
 */
export const createConversationRequestSchema = z
  .object({ id: z.uuid().optional(), title: z.string().trim().min(1).max(200).optional(), context_id: z.uuid().nullable().optional() })
  .strict();
export type CreateConversationRequest = z.infer<typeof createConversationRequestSchema>;

/** 대화 만들기 응답 (201 새로 만듦 · 200 같은 id의 대화가 이미 있음) */
export const createConversationResponseSchema = z.object({ conversation: conversationSchema });
export type CreateConversationResponse = z.infer<typeof createConversationResponseSchema>;

/**
 * 메시지 보내기. client_message_id가 같으면 같은 제출이다: 두 번 저장 · 실행하지 않는다 (unique (conversation_id, client_message_id)).
 * refs: 앱에서 고른 대상 (지시 대상 규칙 1번: 선택된 Action · run · 산출물).
 * 같은 제출이려면 text와 refs(서버가 소문자 · 중복 제거 · 정렬해 견준다)가 모두 같아야 한다 (B2): 같은 client_message_id에
 * 다른 text면 409("다른 글"), 다른 refs면 409("다른 대상"). 다시 보낼 때는 처음과 같은 text · refs를 보낸다
 */
export const postConversationMessageRequestSchema = z
  .object({
    client_message_id: z.uuid(),
    text: z.string().trim().min(1).max(CONVERSATION_MESSAGE_MAX_CHARS),
    refs: z
      .object({ action_ids: z.array(z.uuid()).max(20).optional(), run_ids: z.array(z.uuid()).max(20).optional(), artifact_ids: z.array(z.uuid()).max(20).optional() })
      .strict()
      .optional(),
  })
  .strict();
export type PostConversationMessageRequest = z.infer<typeof postConversationMessageRequestSchema>;

/** 응답 구간. 이어 붙이면 응답 text다. 앱은 등급이 다른 구간만 구별해 보인다 (모든 문장에 배지를 붙이지 않는다) */
export const responseSegmentSchema = z.object({ text: z.string(), tier: contextTierSchema });
export type ResponseSegment = z.infer<typeof responseSegmentSchema>;

// --- D4c-2 (content 앞) ---
// organize 의도(이슈 이동 · 삭제 · 병합)의 제안 내용과 답 내용. conversationMessageContentSchema가 모듈 로드 때 이것을 쓰므로 그 앞에 둔다.

export const organizeOpSchema = z.enum(["move", "remove", "delete", "merge"]);
export type OrganizeOp = z.infer<typeof organizeOpSchema>;
export const organizeContextRefSchema = z.strictObject({ id: z.uuid(), name: z.string().max(200), version: z.number().int().positive() });
/** 확인 카드 · 이동 질문이 보이는 이슈 한 줄 (action_id는 guid: 에이전트 턴이 만든 이슈 id도 받는다). version은 카드가 본 Action.version (낡음 판정), 제목 · 숫자는 hash에 넣지 않는다 */
export const organizeTargetSchema = z.strictObject({
  action_id: z.guid(),
  number: z.number().int().positive(),
  title: z.string().max(200),
  version: z.number().int().nonnegative(),
  contexts: z.array(z.strictObject({ id: z.uuid(), name: z.string().max(200) })).max(5),
  open_sessions: z.number().int().nonnegative(),
  evidence_count: z.number().int().nonnegative(),
});
export type OrganizeTarget = z.infer<typeof organizeTargetSchema>;
/** 제안 내용: create_action은 지금 모양 그대로(strict 아님), 나머지는 D4c-2. to null = 빼기, from null = 넣기 */
export const proposalPayloadSchema = z.discriminatedUnion("kind", [
  z.object({ kind: z.literal("create_action"), title: z.string() }),
  z.strictObject({
    kind: z.literal("move"),
    targets: z.array(organizeTargetSchema).min(1).max(3),
    from: organizeContextRefSchema.nullable(),
    to: organizeContextRefSchema.nullable(),
  }),
  z.strictObject({ kind: z.literal("delete"), targets: z.array(organizeTargetSchema).min(1).max(3) }),
  z.strictObject({ kind: z.literal("merge"), from: organizeTargetSchema, into: organizeTargetSchema }),
]);
export type ProposalPayloadV2 = z.infer<typeof proposalPayloadSchema>;
// contextMembershipEffectSchema(아래 S3b)와 같은 모양이다. 이 스키마가 더 앞에서 쓰여 따로 두었고, 같음은 contract-v2.test.ts가 본다
const membershipChangeSchema = z.strictObject({
  added: z.array(z.strictObject({ context_id: z.uuid(), context_version: z.number().int().positive() })),
  removed: z.array(z.strictObject({ context_id: z.uuid(), context_version: z.number().int().positive() })),
});
/** 답이 한 정리: pending(한 번 더 물음) · moved(말로 이동, change는 TS가 null로 보내고 SQL이 쓰기 직후 값으로 채운다) · deleted · merged(확인 event 행) */
export const organizeContentSchema = z.discriminatedUnion("state", [
  z.strictObject({
    state: z.literal("pending"),
    op: organizeOpSchema.nullable(),
    action_ids: z.array(z.guid()).max(3),
    context_id: z.uuid().nullable(),
    missing: z.enum(["issue", "project", "from", "op", "into"]),
  }),
  z.strictObject({
    state: z.literal("moved"),
    results: z
      .array(
        z.strictObject({
          action_id: z.guid(),
          number: z.number().int().positive(),
          from_context_id: z.uuid().nullable(),
          to_context_id: z.uuid().nullable(),
          change: membershipChangeSchema.nullable(),
        }),
      )
      .min(1)
      .max(3),
  }),
  z.strictObject({ state: z.literal("deleted"), action_ids: z.array(z.guid()).min(1).max(3) }),
  z.strictObject({ state: z.literal("merged"), from_action_id: z.guid(), into_action_id: z.guid() }),
]);
export type OrganizeContent = z.infer<typeof organizeContentSchema>;

/**
 * assistant 답의 내용 (conversation_messages.content, B2). 앱이 RLS로 읽어 대화를 복원한다. 글(구간 · 인용 · 제안 글)이 들어 있어
 * 대화 글 보관 기한에 text와 함께 비운다. 빠진 값은 기본값으로 읽는다 (옛 행 · 사용자 메시지는 content가 없다)
 */
export const conversationMessageContentSchema = z.object({
  segments: z.array(responseSegmentSchema).default([]),
  citations: z.array(askCitationSchema).default([]),
  /** refs.proposal의 내용. payload_hash = 이 객체의 sha256 (채택할 때 서버가 다시 견준다) */
  proposal: proposalPayloadSchema.nullable().default(null),
  /** 이 답이 사용자에게 물은 것: remember(기억해 둘까요) · referent(어느 일인가요, 후보 ≤ 3) · clarify(무엇을 원하나요) · adopt(추가할까요 · 옮길까요) · confirm(삭제 · 병합 카드) · organize(정리할 때 모자란 것) */
  asks: z.enum(["remember", "referent", "clarify", "adopt", "confirm", "organize"]).nullable().default(null),
  /** D4c-2: 이 답이 한 정리. 옛 행에는 없다(없음 = null). optional인 이유: 이 키가 없는 기존 리터럴 · 앱 디코더가 그대로 읽는다 */
  organize: organizeContentSchema.nullable().optional(),
  /** 답을 만들 때 본 범위 · 기억 · 원문 · 할 일 (id만, 글 없음). context_version은 그때의 범위 version */
  used: z
    .object({
      context_id: z.uuid().nullable(),
      context_version: z.number().int().positive().nullable(),
      memory_item_ids: z.array(z.uuid()).default([]),
      source_ids: z.array(z.uuid()).default([]),
      action_ids: z.array(z.guid()).default([]), // guid: 에이전트 턴이 만든 이슈 id(sha256에서 만든 값)도 읽힌다
    })
    .nullable()
    .default(null),
  /** 모델에 넣은 메시지 수와 넣지 않은 앞 메시지 수 (런타임 계약 12장: 최근 20개) */
  window: z.object({ shown: z.number().int().nonnegative(), omitted: z.number().int().nonnegative() }).nullable().default(null),
});
export type ConversationMessageContent = z.infer<typeof conversationMessageContentSchema>;

/** conversation_messages 행. role event: run · 에이전트 사건 중 사용자가 알아야 할 것만 (heartbeat 없음) */
export const conversationMessageSchema = z.object({
  id: z.uuid(),
  conversation_id: z.uuid(),
  seq: z.number().int().positive(),
  role: z.enum(["user", "assistant", "event"]),
  client_message_id: z.uuid().nullable(),
  text: z.string(),
  refs: messageRefsSchema,
  intent: messageIntentSchema.nullable(),
  created_at: z.string(),
  /** 이 답이 답한 사용자 메시지 (assistant만, B2). 사용자 메시지 하나에 답 하나 */
  reply_to: z.uuid().nullable().optional(),
  /** assistant 답의 내용 (B2) */
  content: conversationMessageContentSchema.nullable().optional(),
});
export type ConversationMessage = z.infer<typeof conversationMessageSchema>;

/** 메시지 보내기 응답: 저장한 사용자 메시지 + assistant 답 ({text, segments[], citations[], refs}, 런타임 계약 2장) */
export const postConversationMessageResponseSchema = z.object({
  message: conversationMessageSchema,
  reply: conversationMessageSchema.extend({
    role: z.literal("assistant"),
    segments: z.array(responseSegmentSchema),
    citations: z.array(askCitationSchema),
  }),
});
export type PostConversationMessageResponse = z.infer<typeof postConversationMessageResponseSchema>;

// ─── 기억 (memory_items, 아키텍처 5.3) ─────────────────────────
// 기억은 Action 필드를 바꾸지 않고(I01) 실행 권한에 닿지 않는다(I04). 정정은 새 행 + 옛 행 superseded_by, 잊기는 revoked_at.

export const MEMORY_STATEMENT_MAX_CHARS = 1000;
export const memoryKindSchema = z.enum([
  "identity_link", "goal", "condition", "outcome_criteria", "relationship", "fact", "working_rule", "plan",
]);
export const memoryScopeKindSchema = z.enum(["global", "context", "action", "counterpart", "agent"]);
/** explicit(사용자가 직접 말함) > observed(자료 · 검증된 결과에서 읽음, source_ref 필수) > inferred(모델 추정, confidence 필수) */
export const memoryOriginSchema = z.enum(["explicit", "observed", "inferred"]);

/** 출처: message_id | source_id + quote | artifact_id | event_id 중 하나 이상. event_id는 execution_events(bigint) · inbox_events(uuid)를 문자열로 */
export const memorySourceRefSchema = z
  .object({
    message_id: z.uuid().optional(),
    source_id: z.uuid().optional(),
    quote: z.string().optional(),
    artifact_id: z.uuid().optional(),
    event_id: z.string().min(1).max(100).optional(),
  })
  .refine((ref) => ref.message_id || ref.source_id || ref.artifact_id || ref.event_id, { message: "출처 id가 하나는 필요합니다" });
export type MemorySourceRef = z.infer<typeof memorySourceRefSchema>;

/** memory_items 행 (앱은 RLS로 읽는다: Settings › Remembered). 빈 statement ⇔ source_purged (출처 원문 글이 지워진 observed 항목) */
export const memoryItemSchema = z.object({
  id: z.uuid(),
  kind: memoryKindSchema,
  scope_kind: memoryScopeKindSchema,
  context_id: z.uuid().nullable(),
  action_id: z.uuid().nullable(),
  person_id: z.uuid().nullable(),
  /** scope_kind agent의 대상 (capability.adapter, 예: agent:claude-code) */
  agent_adapter: agentAdapterIdSchema.nullable(),
  /**
   * 같은 사실의 열쇠 (B1, 20261104000000_context_layer). 같은 범위 · 같은 kind · 같은 subject끼리만 정정한다. null = 주제 없음(아무것도 덮지 않는다).
   * B1 전에 만든 행 · 옛 서버 응답에는 없을 수 있다
   */
  subject: z.string().nullable().optional(),
  // 읽기 스키마에는 길이 상한을 두지 않는다: DB는 char_length(코드 포인트), zod .max는 UTF-16 단위라 이모지가 든 행을 못 읽게 된다
  statement: z.string(),
  value: jsonObjectSchema,
  origin: memoryOriginSchema,
  source_ref: memorySourceRefSchema.nullable(),
  observed_at: z.string(),
  valid_from: z.string().nullable(),
  valid_until: z.string().nullable(),
  /** 정정한 새 항목. 그 항목이 지워지면 null이 되지만 superseded_at은 남는다 */
  superseded_by: z.uuid().nullable(),
  /** 정정된 시각 (한 번 남으면 지워지지 않는다) */
  superseded_at: z.string().nullable(),
  /** 잊은 시각 (한 번 남으면 지워지지 않는다) */
  revoked_at: z.string().nullable(),
  confidence: z.number().min(0).max(1).nullable(),
  source_purged: z.boolean(),
  version: z.number().int().positive(),
  created_at: z.string(),
  updated_at: z.string(),
});
export type MemoryItem = z.infer<typeof memoryItemSchema>;

/**
 * 지금 쓰는 기억인지: 정정되지 않았고(superseded_at) 잊지 않은(revoked_at) 항목 (DB 인덱스 memory_items_user_current_idx와 같은 조건).
 * superseded_by로 판단하지 않는다: 정정한 새 항목이 지워지면 포인터는 비지만 옛 항목은 정정된 채로 남는다.
 * 사실의 유효 구간(valid_from · valid_until)과 범위는 보지 않는다: 묶음에 넣을지는 맥락층(B1)이 시각 · 범위로 따로 고른다.
 */
export function isCurrentMemoryItem(item: Pick<MemoryItem, "superseded_at" | "revoked_at">): boolean {
  return item.superseded_at === null && item.revoked_at === null;
}

/** 추정(inferred) 항목 확인: 새 explicit 행을 만들고 옛 행은 superseded_by. expected_version이 다르면 409 (동시 수정) */
export const memoryConfirmRequestSchema = z.object({ expected_version: z.number().int().positive() }).strict();
export type MemoryConfirmRequest = z.infer<typeof memoryConfirmRequestSchema>;

/** 정정 (correct): 새 explicit 행 + 옛 행 superseded_by. 옛 행은 지우지 않는다 */
export const memoryEditRequestSchema = z
  .object({
    expected_version: z.number().int().positive(),
    statement: z.string().trim().min(1).max(MEMORY_STATEMENT_MAX_CHARS),
    value: jsonObjectSchema.optional(),
    valid_from: z.iso.datetime({ offset: true }).nullable().optional(),
    valid_until: z.iso.datetime({ offset: true }).nullable().optional(),
  })
  .strict()
  .refine((r) => !r.valid_from || !r.valid_until || Date.parse(r.valid_from) <= Date.parse(r.valid_until), {
    message: "valid_from이 valid_until보다 늦습니다",
    path: ["valid_until"],
  });
export type MemoryEditRequest = z.infer<typeof memoryEditRequestSchema>;

/** 잊기: revoked_at. 이미 에이전트에게 보낸 묶음은 회수하지 못한다 (아키텍처 6.5) */
export const memoryForgetRequestSchema = z.object({ expected_version: z.number().int().positive() }).strict();
export type MemoryForgetRequest = z.infer<typeof memoryForgetRequestSchema>;

/**
 * 범위 옮기기 (POST /api/v2/memory/{id}/scope, B3): explicit 항목만. 같은 kind · subject · 글로 대상 범위에 새 explicit 행을 만들고 옛 행은 잊는다(한 트랜잭션).
 * 정정(superseded)과 다르다: 새 행의 value.moved_from이 옮긴 출처 id다. 대상은 전체(global, context_id null) 또는 내 active 범위(context, context_id)
 */
export const memoryScopeRequestSchema = z
  .object({
    expected_version: z.number().int().positive(),
    scope_kind: z.enum(["global", "context"]),
    context_id: z.uuid().nullable().default(null),
  })
  .strict()
  .refine((r) => (r.scope_kind === "context") === (r.context_id !== null), {
    message: "context_id는 scope_kind가 context일 때만 필요합니다",
    path: ["context_id"],
  });
export type MemoryScopeRequest = z.infer<typeof memoryScopeRequestSchema>;

/** 기억 쓰기(확인 · 정정 · 잊기 · 범위 옮기기) 응답: 지금 상태의 항목. 확인 · 정정 · 옮기기는 새 지금 행, 잊기는 revoked_at이 선 그 행 */
export const memoryItemResponseSchema = z.object({ item: memoryItemSchema });
export type MemoryItemResponse = z.infer<typeof memoryItemResponseSchema>;

/**
 * 기억 쓰기의 409 이유 코드 (B3). 둘 다 "다시 읽어도 소용없는" 거절이다(version 충돌 conflict와 다르다): 앱은 해당 동작을 감춘다.
 * v1 apiErrorCodeSchema는 동결이라 값을 더하지 않고 v2 오류 코드를 따로 둔다 (모양은 { error: { code, message } }로 같다)
 */
export const memoryUnavailableCodeSchema = z.enum(["confirm_unavailable", "scope_unavailable"]);
export const apiErrorV2CodeSchema = z.enum([...apiErrorCodeSchema.options, ...memoryUnavailableCodeSchema.options]);
export type ApiErrorV2Code = z.infer<typeof apiErrorV2CodeSchema>;
export const apiErrorV2Schema = z.object({ error: z.object({ code: apiErrorV2CodeSchema, message: z.string() }) });
export type ApiErrorV2 = z.infer<typeof apiErrorV2Schema>;

/**
 * 대화의 범위 바꾸기 (PATCH /api/v2/conversations/{id}, B3): 헤더 ProjectLink에서 사용자가 명시적으로 고른 범위. null = All work.
 * 내 active 범위만(아니면 404). 자동 범위 추정 · 멤버십 쓰기는 없다 (S3b)
 */
export const updateConversationRequestSchema = z.object({ context_id: z.uuid().nullable() }).strict();
export type UpdateConversationRequest = z.infer<typeof updateConversationRequestSchema>;
export const updateConversationResponseSchema = z.object({ conversation: conversationSchema });
export type UpdateConversationResponse = z.infer<typeof updateConversationResponseSchema>;

// ─── 범위 (work_contexts · context_members, 아키텍처 5.4) ───────
// 범위는 어떤 gate · 전이 · 판정에도 입력이 아니다(I14). 멤버십을 바꿔도 권한은 바뀌지 않는다.

export const workContextKindSchema = z.enum(["project", "client", "goal", "personal"]);
export const workContextStatusSchema = z.enum(["active", "archived"]);
export const PROJECT_ICON_POOL = ["rocket", "briefcase", "flask-conical", "palette", "code-xml", "megaphone", "book-open", "building-2", "leaf", "compass", "target", "users"] as const;
export const projectIconSchema = z.enum(PROJECT_ICON_POOL);

/** work_contexts 행 */
export const workContextSchema = z.object({
  id: z.uuid(),
  name: z.string(),
  kind: workContextKindSchema,
  status: workContextStatusSchema,
  icon: projectIconSchema,
  version: z.number().int().positive(),
  context_version: z.number().int().positive(),
  last_activity_at: z.string(),
  created_at: z.string(),
  updated_at: z.string(),
});
export type WorkContext = z.infer<typeof workContextSchema>;

export const createWorkContextRequestSchema = z.object({ name: z.string().trim().min(1).max(200), kind: z.literal("project"), icon: projectIconSchema.optional() }).strict();
export type CreateWorkContextRequest = z.infer<typeof createWorkContextRequestSchema>;
export const workContextResponseSchema = z.object({ context: workContextSchema });
export type WorkContextResponse = z.infer<typeof workContextResponseSchema>;

/** 프로젝트 이름 · 아이콘 · 상태 수정. expected_version은 필수다. */
export const updateWorkContextRequestSchema = z
  .object({ name: z.string().trim().min(1).max(200).optional(), icon: projectIconSchema.optional(), status: workContextStatusSchema.optional(), expected_version: z.number().int().positive().max(2147483647) })
  .strict()
  .refine((r) => r.name !== undefined || r.icon !== undefined || r.status !== undefined, { message: "바꿀 값이 없습니다" });
export type UpdateWorkContextRequest = z.infer<typeof updateWorkContextRequestSchema>;

export const contextMemberKindSchema = z.enum(["action", "source", "person"]);
/** user(사용자가 정함, 자동 규칙이 덮지 않는다) · auto(코드 규칙) · inferred(모델 후보, confidence 필수) */
export const contextMemberOriginSchema = z.enum(["user", "auto", "inferred"]);

/** context_members 행: 멤버 종류마다 열 하나 (member_kind에 맞는 열만 채워진다) */
export const contextMemberSchema = z.object({
  id: z.uuid(),
  context_id: z.uuid(),
  member_kind: contextMemberKindSchema,
  action_id: z.guid().nullable(),
  source_id: z.uuid().nullable(),
  person_id: z.uuid().nullable(),
  origin: contextMemberOriginSchema,
  confidence: z.number().min(0).max(1).nullable(),
  /** 사용자가 뺀 멤버 (origin user). 자동 규칙이 다시 넣지 않도록 행이 남는다. 지금 멤버 = null */
  removed_at: z.string().nullable(),
  created_at: z.string(),
  updated_at: z.string(),
});
export type ContextMember = z.infer<typeof contextMemberSchema>;

const membershipTargetSchema = z.object({ op: z.enum(["add", "remove"]), member_kind: contextMemberKindSchema, member_id: z.guid() });

/** 앱이 보내는 멤버십 변경의 대상 (A2 스키마, 조건 없음). S3b route는 조건부 contextMembershipWriteRequestSchema를 받는다. origin은 언제나 user다 (Set by you · Undo) */
export const contextMembershipRequestSchema = membershipTargetSchema.strict();
export type ContextMembershipRequest = z.infer<typeof contextMembershipRequestSchema>;

/** 서버 쪽 멤버십 변경 (코드 규칙 auto · 모델 후보 inferred · 사용자 user). confidence는 inferred에만, inferred에는 반드시 */
export const contextMembershipChangeSchema = membershipTargetSchema
  .extend({ origin: contextMemberOriginSchema, confidence: z.number().min(0).max(1).nullable().default(null) })
  .strict()
  .refine((c) => (c.origin === "inferred") === (c.confidence !== null), { message: "confidence는 inferred에만 붙습니다", path: ["confidence"] });
export type ContextMembershipChange = z.infer<typeof contextMembershipChangeSchema>;

// ─── 사용자 멤버십 쓰기 (S3b: ProjectLink "Set by you" · 바꾸기 · Undo) ───
// 조건부 쓰기다: 요청이 본 범위 version(work_contexts.context_version, 앱이 RLS로 읽은 값 또는 앞 응답의 값)이 지금과 다르면 쓰기 0 + 409 conflict.
// 옛 요청(응답을 잃은 재전송 · 오래 열린 화면 · 늦은 Undo)이 더 새 사용자 결정을 덮지 못한다. 새 멱등성 저장소는 없다: 응답을 잃은 성공 요청의 재전송도 409일 수 있고,
// 앱은 409를 성공으로 보지 않고 다시 읽는다(B3와 같다). version은 범위 전체의 신호라 무관한 변경(다른 멤버 · 범위 기억 · 원문 revision)에도 올라 거짓 409가 생길 수 있다.

/** 넣기 · 빼기 요청 (POST /api/v2/contexts/{id}/members). origin은 언제나 user다. S3b는 할 일(action)만 받는다. contextMembershipRequestSchema(A2)에 조건을 더한 것 */
export const contextMembershipWriteRequestSchema = z
  .object({ op: z.enum(["add", "remove"]), member_kind: z.literal("action"), member_id: z.guid(), expected_context_version: z.number().int().positive() })
  .strict();
export type ContextMembershipWriteRequest = z.infer<typeof contextMembershipWriteRequestSchema>;

/**
 * 옮기기 요청 (POST /api/v2/contexts/{to}/members/move): 한 할 일을 from 범위에서 빼고 경로의 범위에 넣는다. 한 트랜잭션, origin user.
 * ProjectLink "바꾸기 A → B"와 Undo가 쓴다. 전체 교체가 아니다: 그 할 일의 다른 범위 멤버십은 그대로다. 두 범위의 version을 모두 보낸다
 */
export const contextMemberMoveRequestSchema = z
  .object({
    member_kind: z.literal("action"),
    member_id: z.guid(),
    from_context_id: z.uuid(),
    expected_context_version: z.number().int().positive(),
    expected_from_context_version: z.number().int().positive(),
  })
  .strict();
export type ContextMemberMoveRequest = z.infer<typeof contextMemberMoveRequestSchema>;

/**
 * 실제로 바뀐 것. added = 이 요청으로 확인된 멤버가 된 범위, removed = 확인된 멤버가 아니게 된 범위 (각 범위의 쓰기 직후 version과 함께).
 * 이미 멤버였던 도착 범위 · 멤버가 아니던 출발 범위 · auto → user 승격 · inferred 후보를 뺀 것은 바뀐 멤버가 아니라 목록에 없다. 둘 다 비면 되돌릴 것이 없다.
 * Undo는 이 변화의 역연산만 보낸다(원래 있던 대상 · 무관한 멤버십을 지우지 않는다): added만 → 그 범위 빼기, removed만 → 그 범위 넣기, 둘 다 → 옮기기(added → removed 범위로).
 * 그 version을 expected로 보내므로 그 사이 다른 기기가 그 범위를 바꿨다면 Undo는 409다. Undo로 돌아온 멤버는 origin user다(Auto-linked가 아니라 Set by you)
 */
export const contextMembershipEffectSchema = z.object({
  added: z.array(z.object({ context_id: z.uuid(), context_version: z.number().int().positive() })),
  removed: z.array(z.object({ context_id: z.uuid(), context_version: z.number().int().positive() })),
});
export type ContextMembershipEffect = z.infer<typeof contextMembershipEffectSchema>;

/**
 * 넣기 · 빼기 응답. member = 쓰고 난 뒤의 그 행 (add: 지금 멤버 · origin user, remove: removed_at이 선 행), context_version = 쓰기 직후의 그 범위 version(트랜잭션 안에서 읽은 정확한 값).
 * 200만 "이 요청이 처리됨"의 증거다: 오류 · 응답 유실 뒤에 다시 읽은 지금 상태는 성공의 증거가 아니다 (B3 409 교훈)
 */
export const contextMembershipResponseSchema = z.object({ member: contextMemberSchema, context_version: z.number().int().positive(), change: contextMembershipEffectSchema });
export type ContextMembershipResponse = z.infer<typeof contextMembershipResponseSchema>;

/** 옮기기 응답. member = 도착(경로) 범위의 지금 멤버, from_member = 출발 범위에서 사용자가 뺀 행(removed_at). 두 범위의 쓰기 직후 version을 각각 */
export const contextMemberMoveResponseSchema = z.object({
  member: contextMemberSchema,
  from_member: contextMemberSchema,
  context_version: z.number().int().positive(),
  from_context_version: z.number().int().positive(),
  change: contextMembershipEffectSchema,
});
export type ContextMemberMoveResponse = z.infer<typeof contextMemberMoveResponseSchema>;

// ─── 에이전트 adapter (런타임 계약 5장 · 아키텍처 8.2 · 8.3) ─────


/** 권한 경계 하나. verified는 D0 통제 테스트에서 실제로 막힘을 본 것만 true (프롬프트에 범위를 적는 것은 통로가 아니다) */
export const boundarySchema = z.object({
  channel: z.string().min(1).max(200).nullable(),
  verified: z.boolean(),
  evidence: z.string().max(2000).optional(),
});
export type Boundary = z.infer<typeof boundarySchema>;

/**
 * adapter capability 서술자. 쓰기는 동작 × 모드의 경계(approval_gate · target_scope · revocation)가 모두 verified일 때만 (I05).
 * budget만 verified인 adapter는 쓰기 0이다. 확인하지 못한 항목은 unsupported로 둔다
 */
export const agentCapabilitySchema = z.object({
  adapter: agentAdapterIdSchema,
  display_name: z.string().min(1).max(200).optional(),
  transport: z.enum(["remote_api", "local_bridge"]),
  sign_in: z.enum(["user_terminal", "user_app", "token"]).optional(),
  // evidence: 이 값들을 true로 두는 실측 근거 (경계 evidence와 같은 방식). 지금은 attach_existing만 쓴다 (OA 외부 세션 PR2s). 없으면 근거 없음
  session: z.object({ list: z.boolean(), attach_existing: z.boolean(), create: z.boolean(), workspace_scoped: z.boolean(), evidence: z.string().max(2000).optional() }),
  dispatch: z.object({ ack_level: z.enum(["transport", "agent"]), max_instruction_chars: z.number().int().positive() }),
  events: z.enum(["push", "poll", "none"]),
  question: z.object({ receive: z.boolean(), answer: z.boolean(), structured: z.boolean().optional() }),
  cancel: z.enum(["confirmed", "requested_only", "unsupported"]),
  cancel_scope: z.enum(["turn", "turn_and_processes"]).optional(),
  version_range: z.string().min(1).max(200).optional(),
  resume: z.enum(["supported", "unsupported"]),
  enforcement: z.object({ approval_gate: boundarySchema, target_scope: boundarySchema, revocation: boundarySchema, budget: boundarySchema, read_only: boundarySchema.optional() }),
  cost: z.enum(["observable", "estimated", "unknown"]),
  artifacts: z.array(z.enum(["files", "diff", "url", "text"])),
});
export type AgentCapability = z.infer<typeof agentCapabilitySchema>;

/**
 * 사건 종류. 런타임 계약 5장의 아홉 값 + unsupported(bridge가 모르는 명령 kind를 받았을 때, 아키텍처 9.3 → run needs_capability).
 * question의 payload.kind: approval(도구 승인 콜백) · input(사용자 질문). 끝: completed · failed · cancelled
 */
export const agentEventTypeSchema = z.enum([
  "accepted", "progress", "question", "artifact", "completed", "failed", "cancelled", "unreachable", "reconcile", "unsupported",
]);
export type AgentEventType = z.infer<typeof agentEventTypeSchema>;

/**
 * 사건 봉투 (inbound). (bridge_id 또는 session, event_id)로 한 번만 적용한다(I07). seq가 없으면 observed_at은 도착 순서일 뿐이다.
 * payload에는 글을 담지 않는다: 질문 글은 agent_tasks.pending_question, 결과 글은 산출물에만
 */
export const agentEventEnvelopeSchema = z.object({
  adapter: agentAdapterIdSchema,
  session_id: z.string().min(1).max(200),
  external_task_id: z.string().min(1).max(200),
  event_id: z.string().min(1).max(200),
  seq: z.number().int().nonnegative().optional(),
  type: agentEventTypeSchema,
  directive_version: z.number().int().positive().optional(),
  result_revision: z.number().int().nonnegative().optional(),
  payload: jsonObjectSchema,
  observed_at: z.iso.datetime({ offset: true }),
});
export type AgentEventEnvelope = z.infer<typeof agentEventEnvelopeSchema>;

/**
 * agent_tasks.state (런타임 계약 5장). unreachable은 실패가 아니다: reconcile 뒤 last_live_state로 돌아갈 수 있다.
 * idle은 직접 대화의 턴이 끝나 다음 사용자 메시지를 기다리는 상태다 — completed가 아니다 (계약 v3 3.4)
 */
export const agentTaskStateSchema = z.enum([
  "dispatched", "accepted", "running", "awaiting_answer", "idle", "completed", "failed", "cancelled", "unreachable",
]);
export type AgentTaskState = z.infer<typeof agentTaskStateSchema>;

/**
 * agent_sessions.status (계약 v3 3.8). external = 사용자가 Open in Terminal로 터미널에서 이어 쓰는 중(Taskforce 전달 0), unreachable은 bridge에 닿지 않음,
 * closed는 끝난 세션이다
 */
export const agentSessionStatusSchema = z.enum(["bound", "external", "unreachable", "closed"]);
export type AgentSessionStatus = z.infer<typeof agentSessionStatusSchema>;

// ─── Mac bridge (아키텍처 9.1). bridge는 끌어온다: 명령 long-poll ≤ 25초, heartbeat 30초 (3회 누락 → unreachable) ───

/** bridge_commands.kind. bridge가 모르는 kind는 실행하지 않고 unsupported 사건으로 답한다 */
export const bridgeCommandKindSchema = z.enum(["dispatch", "message", "cancel", "reconcile", "check"]);
export type BridgeCommandKind = z.infer<typeof bridgeCommandKindSchema>;

/** POST /api/v1/bridge/register — 기기당 하나. 다른 Mac은 다른 bridge이고 세션은 만든 bridge에 묶인다 */
export const bridgeRegisterRequestSchema = z
  .object({
    device_id: z.string().min(1).max(200),
    app_version: z.string().min(1).max(50),
    capabilities: z.array(agentCapabilitySchema).max(20),
  })
  .strict();
export type BridgeRegisterRequest = z.infer<typeof bridgeRegisterRequestSchema>;
export const bridgeRegisterResponseSchema = z.object({ bridge_id: z.uuid(), heartbeat_interval_seconds: z.number().int().positive() });
export type BridgeRegisterResponse = z.infer<typeof bridgeRegisterResponseSchema>;

/** 명령 (서버 → bridge). GET /api/v1/bridge/commands?since= 로 가져가고 ack로 lease를 잡는다. payload의 묶음은 그대로 에이전트에 넣는다 */
export const bridgeCommandSchema = z.object({
  id: z.uuid(),
  bridge_id: z.uuid(),
  kind: bridgeCommandKindSchema,
  payload: jsonObjectSchema,
  lease_until: z.string().nullable(),
  acked_at: z.string().nullable(),
  created_at: z.string(),
});
export type BridgeCommand = z.infer<typeof bridgeCommandSchema>;
export const bridgeCommandsResponseSchema = z.object({ commands: z.array(bridgeCommandSchema) });
export type BridgeCommandsResponse = z.infer<typeof bridgeCommandsResponseSchema>;

/** POST /api/v1/bridge/events — 사건 배열 (outbox 재생 포함). 이미 받은 event_id도 accepted로 돌려줘 bridge가 outbox에서 지운다 */
export const bridgeEventsRequestSchema = z.object({ bridge_id: z.uuid(), events: z.array(agentEventEnvelopeSchema).min(1).max(100) }).strict();
export type BridgeEventsRequest = z.infer<typeof bridgeEventsRequestSchema>;
export const bridgeEventsResponseSchema = z.object({ accepted_event_ids: z.array(z.string()) });
export type BridgeEventsResponse = z.infer<typeof bridgeEventsResponseSchema>;

/** POST /api/v1/bridge/heartbeat — 30초마다, 살아 있는 agent_tasks의 (task_id, process_alive, last_seq) */
export const bridgeHeartbeatRequestSchema = z
  .object({
    bridge_id: z.uuid(),
    sent_at: z.iso.datetime({ offset: true }),
    tasks: z.array(z.object({ task_id: z.uuid(), process_alive: z.boolean(), last_seq: z.number().int().nonnegative() }).strict()).max(50),
  })
  .strict();
export type BridgeHeartbeatRequest = z.infer<typeof bridgeHeartbeatRequestSchema>;

// ─── 결제 v2 (아키텍처 10.1 · 결제 계약 oa-billing: Pro 월간 · 연간 + Lifetime, 3일 환불) ───
// v1(billingStatusSchema · billingCheckoutRequestSchema)은 그대로다: lifetime 계정은 v1에서 plan null · status active ·
// can_use_ai true · can_checkout false로 매핑하고, v1 checkout은 늘 409다 (구현 계획 8장). 가격 숫자는 서버(src/lib/billing/prices.ts)가 표시 글자로 내려 준다.

export const billingPlanV2Schema = z.enum(["monthly", "annual", "lifetime"]);
export type BillingPlanV2 = z.infer<typeof billingPlanV2Schema>;

/** PlanSummary 8 상태. beta = billing_accounts.legacy_beta (유료 전환 고지 전 기존 계정) */
export const planStateSchema = z.enum(["none", "trial", "pro", "cancelled", "past_due", "lapsed", "lifetime", "beta"]);
export type PlanState = z.infer<typeof planStateSchema>;

/** 이번 달(UTC 1일부터) Taskforce 자체 AI 호출의 토큰 사용량. 참고값이고 상한이 아니다 */
export const aiUsageTokensSchema = z.object({
  since: z.string(),
  prompt_tokens: z.number().int().nonnegative(),
  completion_tokens: z.number().int().nonnegative(),
  total_tokens: z.number().int().nonnegative(),
});
export type AiUsageTokens = z.infer<typeof aiUsageTokensSchema>;

/** 서버가 정한 표시 가격. 앱은 이 글자를 문장 틀에 끼울 뿐 숫자 상수를 두지 않는다 (예: "$12.99") */
export const billingPricesV2Schema = z.object({ pro_monthly: z.string(), pro_first_month: z.string(), pro_yearly: z.string(), lifetime: z.string() });
export type BillingPricesV2 = z.infer<typeof billingPricesV2Schema>;

/** 사용자의 OpenRouter 키 상태 (Lifetime만, 서버의 user_ai_keys가 정한다). 키 자체나 일부는 어디에도 내리지 않는다 */
export const aiKeyStatusV2Schema = z.enum(["connected", "missing", "revoked"]);

/** GET /api/v2/billing. 자격은 결제 제공자 webhook으로만 바뀐다 (I15, 클라이언트 신고 없음) */
export const billingStatusV2Schema = z.object({
  state: planStateSchema,
  plan: billingPlanV2Schema.nullable(),
  trial_ends_at: z.string().nullable(),
  current_period_ends_at: z.string().nullable(),
  /** 해지했지만 이 시각까지 쓸 수 있다 (state cancelled) */
  cancel_at: z.string().nullable(),
  /** 기존 베타 계정의 유료 전환 고지 끝 (state beta이고 고지가 잡힌 뒤). 없으면 null */
  notice_ends_at: z.string().nullable(),
  /** 환불 요청을 받는 마지막 시각 (결제 3일 안). 지났거나 해당 없으면 null */
  refund_until: z.string().nullable(),
  /** requested = 환불을 요청했고 제공자 확정을 기다린다 (자격은 확정 뒤에만 바뀐다) */
  refund_state: z.enum(["idle", "requested"]),
  can_use_ai: z.boolean(),
  can_checkout: z.boolean(),
  can_buy_lifetime: z.boolean(),
  /** 지금 Pro를 시작하면 3일 무료 체험과 첫 달 할인이 붙는가 (계정당 처음 한 번) */
  with_trial: z.boolean(),
  /** checkout 요청에 그대로 되돌려 보낼 현재 약관 판 */
  terms_version: z.string(),
  prices: billingPricesV2Schema,
  ai_usage_this_month: aiUsageTokensSchema.nullable(),
  /** 공정 사용 안전장치에 닿아 AI가 쉬는 동안, 다시 시작하는 시각. 아니면 null. 숫자 한도는 내리지 않는다 */
  fair_use_paused_until: z.string().nullable(),
  ai_key: aiKeyStatusV2Schema.nullable(),
  ai_key_spend_error_at: z.string().nullable(),
});
export type BillingStatusV2 = z.infer<typeof billingStatusV2Schema>;

/** POST /api/v2/billing/checkout. 가격 · 변형 · 코드 · 돌아올 주소는 서버가 정한다 (클라이언트 값 0) */
export const billingCheckoutPlanV2Schema = z.enum(["pro", "lifetime"]);
export const billingCheckoutRequestV2Schema = z.object({ plan: billingCheckoutPlanV2Schema, terms_version: z.string().min(1).max(32) }).strict();
export type BillingCheckoutRequestV2 = z.infer<typeof billingCheckoutRequestV2Schema>;
/** checkout · portal 응답. https *.lemonsqueezy.com 주소만 */
export const billingUrlResponseV2Schema = z.object({ url: z.string().url() });

/** POST /api/v2/billing/portal. manage = 구독 관리, payment = 결제 수단 바꾸기 */
export const billingPortalRequestV2Schema = z.object({ target: z.enum(["manage", "payment"]) }).strict();

/** POST /api/v2/billing/resume — 본문 없음. 해지했고 기간이 남았을 때 다시 시작을 요청한다. 확정은 webhook이 오면 */
export const billingResumeRequestV2Schema = z.object({}).strict();
export const billingResumeResponseV2Schema = z.object({ requested: z.literal(true) });

/** POST /api/v2/billing/refund — 본문 없음. 서버가 3일 창을 확인하고 환불을 요청한다. 확정은 webhook이 오면 (자격은 그때 바뀐다) */
export const billingRefundRequestV2Schema = z.object({}).strict();
export const billingRefundResponseV2Schema = z.object({ requested: z.literal(true) });
export type BillingRefundResponseV2 = z.infer<typeof billingRefundResponseV2Schema>;

/**
 * PUT /api/v2/billing/openrouter-key — Lifetime 사용자의 OpenRouter 키 (BYOK). 키는 이 본문으로만 들어오고 서버는 다시 내려 주지 않는다(상태만).
 * 모양(접두 sk-or- · 길이 20–256 · 앞뒤 공백 지움)과 OpenRouter에서의 확인은 서버가 하고, 여기서는 터무니없이 큰 본문만 거른다.
 */
export const billingOpenRouterKeyRequestV2Schema = z.object({ key: z.string().min(1).max(4096) }).strict();
export const billingOpenRouterKeyResponseV2Schema = z.object({ ai_key: z.literal("connected") }).strict();
/** DELETE /api/v2/billing/openrouter-key는 본문 없이 204 */

/**
 * v2 결제 route의 오류 코드. 켜져 있지 않거나 지금 할 수 없는 요청은 409, 제공자 · DB 장애는 503 (같은 billing_unavailable).
 * 키 저장: 422 ai_key_invalid(OpenRouter가 거절했거나 모양이 아님) · 422 ai_key_management(관리 키) · 429 rate_limited(Retry-After, 시간당 10회).
 * v1 오류 코드는 늘지 않는다: 호출 중 키 문제는 v1 밖에서 billing_required로 닫히고 정확한 이유는 상태의 ai_key가 말한다.
 */
export const billingErrorCodeV2Schema = z.enum(["unauthorized", "invalid_request", "billing_unavailable", "billing_terms_required", "billing_refund_window_closed", "billing_refund_used", "billing_refund_pending", "ai_key_invalid", "ai_key_management", "rate_limited"]);
export const billingErrorV2Schema = z.object({ error: z.object({ code: billingErrorCodeV2Schema, message: z.string() }) });
export type BillingErrorCodeV2 = z.infer<typeof billingErrorCodeV2Schema>;

// ─── Review · 복귀 요약 · 제안 (0.2.0 C3, 런타임 계약 6 · 8장, 디자인 D-12) ───────────────────
// 새 경로는 모두 /api/v2/ 아래이고 gate가 꺼져 있으면 404다 (복귀 요약 세 경로는 RETURN_SUMMARY_ENABLED 또는 REVIEW_V2_ENABLED, 나머지는 REVIEW_V2_ENABLED; v1 동결 지문은 그대로).
// 서버는 토큰(코드가 정한 짧은 이름)과 id · 시각만 내린다. 사용자에게 보일 문구는 앱이 토큰에서 만든다 — 서버가 문구를 지어내지 않는다.
// 읽기(GET)는 아무것도 지우지 않는다. 시각은 마이크로초까지 있는 UTC 글자("...123456Z")이고 앱은 Date로 바꾸지 않고 그대로 돌려준다(커서).

const tokenSchema = z.string().regex(/^[a-z][a-z0-9_]{0,63}$/);
const utcMicroSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/);

/** 한 원천을 읽었나. unavailable이면 그 부분은 비어 있는 것이 아니라 모르는 것이다 (앱은 empty · 모두 처리됨으로 보이면 안 된다) */
export const reviewSourceStatusSchema = z.enum(["ok", "unavailable"]);

/** 결정 대기 종류 (src/lib/coordinator/pending.ts PENDING_KINDS와 같다: 테스트가 견준다). 지금 실제 원천이 있는 것은 앞의 넷이다 */
export const pendingDecisionKindSchema = z.enum(["approval", "review_failed", "run_input", "confirm", "agent_question", "suggestion", "blocked_dependency"]);
export type PendingDecisionKind = z.infer<typeof pendingDecisionKindSchema>;

/** 결정 대기 항목 하나. version은 처리되면 바뀌는 식별이다: 다른 기기에서 처리되면 다음 조회에서 사라지거나(gone) version이 달라진다(stale) */
export const pendingDecisionItemSchema = z.object({
  id: z.string(),
  kind: pendingDecisionKindSchema,
  action_id: z.uuid(),
  run_id: z.uuid().nullable(),
  step_id: z.uuid().nullable(),
  question_id: z.string().nullable(),
  version: z.string(),
  urgent: z.boolean(),
  urgent_reason: z.enum(["due_window", "blocks_other_work"]).nullable(),
  created_at: z.string(),
});
export type PendingDecisionItem = z.infer<typeof pendingDecisionItemSchema>;

/** (업무, 종류) 묶음. version은 항목 version이 하나라도 바뀌면 달라진다. 목록에는 개수 상한이 없다 */
export const pendingDecisionGroupSchema = z.object({
  key: z.string(),
  action_id: z.uuid(),
  kind: pendingDecisionKindSchema,
  urgent: z.boolean(),
  version: z.string(),
  created_at: z.string(),
  items: z.array(pendingDecisionItemSchema),
});
export type PendingDecisionGroup = z.infer<typeof pendingDecisionGroupSchema>;

/** 제안 종류 (코드 토큰). 문구는 앱이 만든다 */
export const suggestionKindSchema = z.enum(["due_window", "run_failed", "source_revised_run"]);
export type SuggestionKind = z.infer<typeof suggestionKindSchema>;
export const suggestionStateSchema = z.enum(["open", "accepted", "snoozed", "dismissed", "expired"]);

/**
 * 제안 하나. version은 상태가 바뀔 때마다 오른다(snooze · dismiss · 다시 열림 · 만료): 처리할 때 읽은 version을 expected_version으로 보낸다.
 * offered_on: 비긴급이 처음 노출된 사용자 현지 날짜(YYYY-MM-DD), 긴급은 null. 이 서버에서 accepted는 쓰이지 않는다(채택은 없다).
 */
export const suggestionSchema = z.object({
  id: z.uuid(),
  kind: suggestionKindSchema,
  action_id: z.uuid(),
  run_id: z.uuid().nullable(),
  urgent: z.boolean(),
  state: suggestionStateSchema,
  version: z.number().int().positive(),
  snooze_until: z.string().nullable(),
  offered_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).nullable(),
  created_at: z.string(),
  shown_at: z.string().nullable(),
});
export type Suggestion = z.infer<typeof suggestionSchema>;

/**
 * GET /api/v2/review — Review: C2 결정 대기 계산(decisions, 개수 상한 없음) + 열린 제안(suggestions).
 * 제안을 보는 것만으로 Action · run은 생기지 않는다(노출 표시 shown_at · 묶음 batch_day만 쓴다).
 * complete: 모든 원천을 읽었다. empty: complete이면서 둘 다 비었다 — 비었다는 말은 empty일 때만 해도 된다 (일부 실패 · 잘림을 비었다고 하지 않는다).
 * sources.time_zone: 사용자 시간대(하루 경계)를 읽었나. unavailable = 예상 못한 읽기 오류 — 모르는 것과 다르다.
 * suggestion_batch.state: ready = 시간대를 알아 하루 묶음을 센다 · needs_time_zone = 저장된 시간대가 없다(정당한 모름, 완전한 읽기): 새 비긴급 제안은 아직 내지 않는다 ·
 *   unavailable = 시간대를 읽지 못했다(sources.time_zone도 unavailable, complete false): 새 비긴급은 내지 않는다. 어느 쪽이든 긴급과 이미 낸 제안은 보인다. 하루 상한 size개.
 * unavailable인 원천의 목록(decisions · suggestions)은 null이거나 일부일 수 있다 — 어느 쪽이든 비어 있다고 말하지 않는다 (empty는 complete일 때만).
 */
export const reviewResponseSchema = z.object({
  generated_at: z.string(),
  complete: z.boolean(),
  empty: z.boolean(),
  sources: z.object({ decisions: reviewSourceStatusSchema, suggestions: reviewSourceStatusSchema, time_zone: reviewSourceStatusSchema }),
  decisions: z.array(pendingDecisionGroupSchema).nullable(),
  suggestions: z.array(suggestionSchema).nullable(),
  suggestion_batch: z.object({ state: z.enum(["ready", "needs_time_zone", "unavailable"]), local_day: z.string().nullable(), size: z.number().int().positive() }),
});
export type ReviewResponse = z.infer<typeof reviewResponseSchema>;

/** 복귀 요약에서 변화가 온 원천: action_event(원문 · AI 변화, 사용자의 자기 수정은 제외) · run(실행 결과 전이) · message(안 읽은 assistant/event 메시지) */
export const returnSummaryChangeSourceSchema = z.enum(["action_event", "run", "message"]);
/** 원문 상태 토큰: 지워진 원문 · 접근 상실 · 보관 만료를 글이나 옛 제목으로 되살리지 않고 이 토큰만 낸다. action_event가 아니면 null */
export const returnSummarySourceStateSchema = z.enum(["available", "deleted", "access_lost", "text_expired"]);

export const returnSummaryChangeSchema = z.object({
  source: returnSummaryChangeSourceSchema,
  /** action_event: due_changed · scope_changed · owner_changed · merged · completed · dropped · reopened · artifact_created / run: done · failed / message: assistant · event */
  kind: tokenSchema,
  at: utcMicroSchema,
  /** run done이면 그 run의 outcome(draft_ready · needs_input · …), 아니면 null */
  detail: tokenSchema.nullable(),
  source_state: returnSummarySourceStateSchema.nullable(),
});
export type ReturnSummaryChange = z.infer<typeof returnSummaryChangeSchema>;

/** Next 토큰: answer(답할 결정이 있다, decision_kinds) · review_result(끝난 결과를 볼 차례) · open(그 작업을 열어 본다) */
export const returnSummaryNextSchema = z.object({
  kind: z.enum(["answer", "review_result", "open"]),
  decision_kinds: z.array(pendingDecisionKindSchema),
});

export const returnSummaryItemSchema = z.object({
  action_id: z.uuid(),
  /** 지금 제목 (옛 제목 · 원문 글이 아니다) */
  title: z.string(),
  status: actionStatusSchema,
  /** StatusMark: 할 일(to_do) · 진행 중(in_progress) · 완료(done). 취소(dropped)는 null */
  state: actionProgressStateSchema.nullable(),
  /** 답할 결정이 있다 ("Needs your answer" 강조). 읽음 · Clear는 이것을 지우지 않는다 */
  needs_answer: z.boolean(),
  urgent: z.boolean(),
  decisions: z.array(z.object({ id: z.string(), kind: pendingDecisionKindSchema, version: z.string(), urgent: z.boolean() })),
  changes: z.array(returnSummaryChangeSchema),
  next: returnSummaryNextSchema,
  /** 이 줄의 내용이 바뀌면 달라진다 (변화 · 결정 · version): 앱이 줄을 비교할 때 쓴다. id는 action_id다 */
  version: z.string(),
});
export type ReturnSummaryItem = z.infer<typeof returnSummaryItemSchema>;

/**
 * GET /api/v2/return-summary — 복귀 요약. 숫자 없음(개수를 내리지 않는다).
 * since: 마지막 Clear의 지평(마이크로초 UTC 글자, 앱이 "Since …" 표시를 위해 시각으로 바꿔도 되지만 커서에는 쓰지 않는다). 표시용이다 — 무엇이 읽혔는지는 시각이 아니라
 *   서버가 (사건, 작업) 쌍으로 기억한다(Clear 뒤에 commit되는 사건은 시각이 이르더라도 새 변화로 보인다). 한 번도 Clear하지 않았으면 null.
 * baseline: cleared(Clear한 적 있음, 업그레이드 이전 Clear 사용자 포함) | initialized(첫 정상 표시 기준점은 있고 Clear는 아직 없음 — 새 run 결과 · 메시지가 Clear 없이 나온다) |
 *   never_cleared(둘 다 없음 — run · 대화 이력은 변화로 올리지 않고, 작업 변화는 사용자가 마지막으로 본 뒤의 것만 낸다. init_token으로 기준점을 정할 수 있다) | unknown(변화 원천을 읽지 못함).
 * cursor: Clear에 그대로 돌려준다(불투명, 최대 약 9KB). 변화 원천을 읽지 못했으면 null. **잘렸어도(truncated) 커서가 있다** — 그 커서는 보인 작업의 사건만 읽음 처리하고,
 *   보이지 않은 작업은 다음 조회에 나온다 (Clear 가능 = cursor가 있다).
 * complete: 모든 원천을 읽었고 잘리지 않았다. empty: complete이면서 items가 비었다 — "변화 없음 · 모두 처리됨"은 empty일 때만.
 */
export const returnSummaryResponseSchema = z.object({
  generated_at: z.string(),
  since: utcMicroSchema.nullable(),
  baseline: z.enum(["cleared", "initialized", "never_cleared", "unknown"]),
  /** 첫 정상 표시 기준점의 초기화 토큰 (불투명). baseline이 never_cleared이고 변화 원천을 읽었을 때만(빈 첫 화면 · 잘린 첫 화면 포함), 아니면 null */
  init_token: z.string().max(400).nullable(),
  cursor: z.string().nullable(),
  complete: z.boolean(),
  empty: z.boolean(),
  sources: z.object({ changes: z.enum(["ok", "unavailable", "truncated"]), decisions: reviewSourceStatusSchema }),
  items: z.array(returnSummaryItemSchema),
});
export type ReturnSummaryResponse = z.infer<typeof returnSummaryResponseSchema>;

/**
 * POST /api/v2/return-summary/baseline — 첫 정상 표시 기준점 확정. 요청 { init_token } (GET이 준 글자 그대로, 그 밖의 키는 400).
 * 앱이 그 응답을 **정상으로 표시했을 때만** 보낸다 (읽기 실패 · 오래됨 · 닫힘 · 다른 계정이면 보내지 않는다). GET은 읽기만 하고 이것이 유일한 쓰기다.
 * 200 { status: "initialized", applied: true }: 그때까지의 run 결과 · 읽은 시각이 없는 대화 메시지 이력만 읽음으로 삼았다 (미열람 Action 변화 · 미결정은 그대로).
 *   이후에는 Clear를 누르지 않아도 새 run 결과 · 메시지가 요약에 나온다.
 * 200 { status: "already_initialized", applied: false }: 이미 기준점이 있거나 Clear한 적이 있다 (두 기기 · 응답 유실 재시도 · 늦은 확정). 아무것도 쓰지 않았다 — 성공이다.
 * 409 conflict: 조회 뒤 확정 전에 기준점 범위가 달라졌다(늦게 들어온 결과 · 삭제). 아무것도 쓰지 않았다. 앱은 자동 재전송하지 않고 다음 정상 표시(새 GET의 새 토큰)에서 다시 확정한다.
 * 400 invalid_request: 모양이 틀린 · 미래 · 남의 · 옛 형식 토큰. 404 gate 꺼짐 · 401.
 */
export const returnSummaryBaselineRequestSchema = z.object({ init_token: z.string().min(1).max(400) }).strict();
export type ReturnSummaryBaselineRequest = z.infer<typeof returnSummaryBaselineRequestSchema>;
export const returnSummaryBaselineResponseSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("initialized"), applied: z.literal(true) }),
  z.object({ status: z.literal("already_initialized"), applied: z.literal(false) }),
]);
export type ReturnSummaryBaselineResponse = z.infer<typeof returnSummaryBaselineResponseSchema>;

/**
 * POST /api/v2/return-summary/clear — 조회가 본 사건을 읽음 처리한다. 읽음일 뿐이다(해결 · 승인 · 완료 · 거절이 아니다: 결정 · Action은 그대로).
 * 200 { cleared_through, applied }: applied=false는 쓸 것이 없었다(재시도 · 다른 기기에서 먼저 Clear) — 성공이다.
 * 409 conflict: 조회한 뒤 Clear 전에 그 범위의 사건이 달라졌다(늦게 들어온 변화 · 삭제). 아무것도 읽음 처리하지 않았다: 다시 조회한다 (자동 재시도 없음).
 * 조회 때 아직 commit되지 않았던 사건은 Clear가 읽음으로 만들지 못한다 — 나중에 commit되면 다음 조회에 보인다.
 * 400 invalid_request: 모양이 틀린 · 미래 · 남의 커서.
 */
export const returnSummaryClearRequestSchema = z.object({ cursor: z.string().min(1).max(10_000) }).strict();
export type ReturnSummaryClearRequest = z.infer<typeof returnSummaryClearRequestSchema>;
export const returnSummaryClearResponseSchema = z.object({ cleared_through: utcMicroSchema, applied: z.boolean() });
export type ReturnSummaryClearResponse = z.infer<typeof returnSummaryClearResponseSchema>;

/** POST /api/v2/suggestions/{id}/snooze — 사용자가 고른 시점까지 숨긴다 (서버가 시점을 정하지 않는다). 지금보다 뒤 · 366일 이내 */
export const suggestionSnoozeRequestSchema = z
  .object({ expected_version: z.number().int().positive(), snooze_until: z.iso.datetime({ offset: true }) })
  .strict();
export type SuggestionSnoozeRequest = z.infer<typeof suggestionSnoozeRequestSchema>;

/** POST /api/v2/suggestions/{id}/dismiss — this: 이 계기만 / topic: 같은 종류 + 같은 주제의 새 계기도 다시 제안하지 않는다 */
export const suggestionDismissRequestSchema = z
  .object({ expected_version: z.number().int().positive(), scope: z.enum(["this", "topic"]) })
  .strict();
export type SuggestionDismissRequest = z.infer<typeof suggestionDismissRequestSchema>;

/** 200 { suggestion }: 처리한 뒤의 제안. 404 없는/남의 제안 · 409 conflict(옛 version이거나 이미 끝난 제안: 다시 조회) · 400 잘못된 본문 · 시점 */
export const suggestionResponseSchema = z.object({ suggestion: suggestionSchema });
export type SuggestionResponse = z.infer<typeof suggestionResponseSchema>;

// --- D2a ---
const bridgeV1BoundedText = (max: number) => z.string().refine((value) => Array.from(value).length <= max);
const bridgeV1Identity = bridgeV1BoundedText(200).refine((value) => value.length > 0);
const bridgeV1QuestionSchema = z.strictObject({
  provider_request_id: bridgeV1Identity, kind: z.enum(["input", "approval"]), structured: z.boolean(),
  questions: z.array(z.strictObject({
    id: bridgeV1BoundedText(200), header: bridgeV1BoundedText(200), text: bridgeV1BoundedText(4000),
    options: z.array(z.strictObject({ label: bridgeV1BoundedText(500), description: bridgeV1BoundedText(1000) })).max(10),
    multi_select: z.boolean(), allow_other: z.boolean(), secret: z.boolean(),
  })).min(1).max(4).refine((questions) => new Set(questions.map((question) => question.id)).size === questions.length),
});
const bridgeV1EmptyPayload = z.strictObject({}).optional();
const bridgeV1Envelope = {
  adapter: agentAdapterIdSchema,
  session_ref: z.strictObject({ agent_session_id: z.guid() }),
  agent_task_id: z.guid().optional(), external_task_id: bridgeV1Identity.optional(),
  event_id: bridgeV1Identity, seq: z.number().int().positive().optional(),
  turn_seq: z.number().int().positive().optional(), observed_at: z.iso.datetime({ offset: true }),
  text: z.string().optional(),
};
const bridgeV1SessionTypes = ["session_bound", "unreachable", "reconcile"];

// Match JSONB's spaces at structural separators, including nested question metadata.
function bridgeV1JsonbText(value: unknown): string {
  if (Array.isArray(value)) return "[" + value.map(bridgeV1JsonbText).join(", ") + "]";
  if (value !== null && typeof value === "object") {
    return "{" + Object.entries(value).map(([key, item]) => `${JSON.stringify(key)}: ${bridgeV1JsonbText(item)}`).join(", ") + "}";
  }
  return JSON.stringify(value);
}

/** Bridge and internal event application share the same bounded envelope. */
export const bridgeV1EventSchema = z.discriminatedUnion("type", [
  z.strictObject({ ...bridgeV1Envelope, type: z.enum(["accepted", "progress", "turn_completed", "cancelled", "unreachable"]), payload: bridgeV1EmptyPayload }),
  z.strictObject({ ...bridgeV1Envelope, type: z.literal("message"), text: z.string(), payload: bridgeV1EmptyPayload }),
  z.strictObject({ ...bridgeV1Envelope, type: z.literal("question"), text: z.string(), question: bridgeV1QuestionSchema, payload: bridgeV1EmptyPayload }),
  z.strictObject({ ...bridgeV1Envelope, type: z.literal("artifact"), payload: z.strictObject({ path: bridgeV1BoundedText(1000).refine((value) => value.length > 0), hash: bridgeV1Identity, summary: bridgeV1BoundedText(2000) }) }),
  z.strictObject({ ...bridgeV1Envelope, type: z.literal("failed"), payload: z.strictObject({ reason: z.enum(["sign_in_needed", "usage_limited", "spawn_failed", "version_unsupported", "agent_error"]).optional() }).optional() }),
  z.strictObject({ ...bridgeV1Envelope, type: z.literal("session_bound"), payload: z.strictObject({ external_session_id: bridgeV1Identity.refine((id) => !id.startsWith("pending:")), workspace_ref: bridgeV1BoundedText(500).refine((value) => value.length > 0).optional() }) }),
  z.strictObject({ ...bridgeV1Envelope, type: z.literal("reconcile"), payload: z.strictObject({ state: z.enum(["dispatched", "accepted", "running", "awaiting_answer", "idle", "failed", "cancelled"]).optional() }).optional() }),
]).superRefine((event, ctx) => {
  if (!bridgeV1SessionTypes.includes(event.type) && !event.agent_task_id && !event.external_task_id) {
    ctx.addIssue({ code: "custom", message: "Task identity is required", path: ["agent_task_id"] });
  }
  if (event.text !== undefined && new TextEncoder().encode(event.text).length > 32768) {
    ctx.addIssue({ code: "custom", message: "Text exceeds 32768 UTF-8 bytes", path: ["text"] });
  }
  if (event.text !== undefined && event.type !== "message" && event.type !== "question") {
    ctx.addIssue({ code: "custom", message: "Text belongs only to messages and questions", path: ["text"] });
  }
  if (event.type === "question") {
    const pending = { ...event.question,
      question_key: [event.agent_task_id ?? "00000000-0000-0000-0000-000000000000", event.question.provider_request_id],
      asked_at: event.observed_at,
    };
    if (new TextEncoder().encode(bridgeV1JsonbText(pending)).length > 32768) {
      ctx.addIssue({ code: "custom", message: "Pending question exceeds 32768 UTF-8 bytes", path: ["question"] });
    }
  }
  const payloadText = bridgeV1JsonbText(event.payload ?? {});
  if (new TextEncoder().encode(payloadText).length > 4096) {
    ctx.addIssue({ code: "custom", message: "Payload exceeds 4096 UTF-8 bytes", path: ["payload"] });
  }
});
export type BridgeV1Event = z.infer<typeof bridgeV1EventSchema>;
export const bridgeV1AdapterReportSchema = z.strictObject({
  adapter: agentAdapterIdSchema, installed: z.boolean(), version: z.string().max(50).nullable(),
  signed_in: z.enum(["yes", "no", "unknown"]), managed_settings: z.boolean(),
});
export const bridgeV1AdapterReportsSchema = z.array(bridgeV1AdapterReportSchema).max(8)
  .refine((reports) => new Set(reports.map((report) => report.adapter)).size === reports.length);
import { AGENT_REGISTRY } from "@/lib/agents/registry";
export const bridgeV1RegisterRequestSchema = z.strictObject({
  device_id: z.string().min(16).max(200), app_version: z.string().min(1).max(50), adapters: bridgeV1AdapterReportsSchema,
  connect: z.array(z.enum(Object.keys(AGENT_REGISTRY) as (keyof typeof AGENT_REGISTRY)[])).max(8).default([]), reactivate: z.boolean().default(false),
});
export type BridgeV1RegisterRequest = z.infer<typeof bridgeV1RegisterRequestSchema>;
export const bridgeV1RevokeRequestSchema = z.strictObject({ bridge_id: z.guid() });
const bridgeV1ConnectionSchema = z.strictObject({ connection_id: z.guid(), adapter: agentAdapterIdSchema, status: z.enum(["active", "error", "revoked"]) });
export const bridgeV1RegisterResponseSchema = z.strictObject({
  bridge_id: z.guid(), bridge_secret: z.string().min(1), heartbeat_interval_seconds: z.literal(30),
  unreachable_after_seconds: z.literal(90), long_poll_max_seconds: z.literal(25), connections: z.array(bridgeV1ConnectionSchema),
});
export const bridgeV1RevokeResponseSchema = z.strictObject({ status: z.literal("revoked"), tasks: z.array(z.strictObject({ agent_task_id: z.guid(), cancel: z.enum(["requested_only", "confirmed"]), processes: z.literal("may_continue").optional() })) });
export const bridgeV1CommandsQuerySchema = z.strictObject({
  bridge_id: z.guid(), after: z.coerce.number().int().nonnegative().default(0), wait: z.coerce.number().min(0).max(25).default(0),
});
const bridgeV1KindSchema = z.enum(["message", "answer", "cancel"]);
const bridgeV1TaskRef = { agent_session_id: z.guid(), agent_task_id: z.guid(), turn_seq: z.number().int().positive() };
export const bridgeV1CommandsResponseSchema = z.strictObject({
  commands: z.array(z.strictObject({ id: z.guid(), cursor: z.number().int().positive(), kind: bridgeV1KindSchema, ...bridgeV1TaskRef, created_at: z.iso.datetime({ offset: true }), leased_by_me: z.boolean() })).max(50),
  readbacks: z.array(z.strictObject({ command_id: z.guid(), kind: bridgeV1KindSchema, ...bridgeV1TaskRef, marker: z.string().min(1), leased_at: z.iso.datetime({ offset: true }) })).max(50),
  next_cursor: z.number().int().nonnegative(), server_time: z.iso.datetime({ offset: true }),
});
const bridgeV1AckRef = { bridge_id: z.guid(), command_id: z.guid() };
export const bridgeV1AckRequestSchema = z.discriminatedUnion("op", [
  z.strictObject({ ...bridgeV1AckRef, op: z.literal("lease") }),
  z.strictObject({ ...bridgeV1AckRef, op: z.literal("complete"), result: z.enum(["sent", "task_unknown"]) }),
  z.strictObject({ ...bridgeV1AckRef, op: z.literal("readback"), result: z.enum(["received", "not_received", "unknown"]), process_ended: z.boolean() }),
  z.strictObject({ ...bridgeV1AckRef, op: z.literal("request_closed") }),
  z.strictObject({ ...bridgeV1AckRef, op: z.literal("decline"), reason: z.literal("unsupported_kind") }),
]).refine((ack) => ack.op !== "readback" || ack.result !== "not_received" || ack.process_ended, { message: "A terminated process is required for not_received" });
export type BridgeV1AckRequest = z.infer<typeof bridgeV1AckRequestSchema>;
const bridgeV1CommandBase = {
  id: z.guid(), ...bridgeV1TaskRef, step_id: z.guid(), adapter: agentAdapterIdSchema, marker: z.string().min(1),
  session: z.strictObject({ external_session_id: z.string().nullable(), workspace_ref: z.string().nullable(), resume: z.boolean() }),
};
const bridgeV1DeliveryBase = { access: z.enum(["write", "read_only"]), policy_mode: z.enum(["manual", "auto", "full"]) };
export const bridgeV1CommandPayloadSchema = z.discriminatedUnion("kind", [
  z.strictObject({ ...bridgeV1CommandBase, ...bridgeV1DeliveryBase, kind: z.literal("message"), message: z.strictObject({ id: z.guid(), text: bridgeV1BoundedText(4000) }), close_before: z.strictObject({ provider_request_id: bridgeV1Identity }).nullable() }),
  z.strictObject({ ...bridgeV1CommandBase, ...bridgeV1DeliveryBase, kind: z.literal("answer"), provider_request_id: bridgeV1Identity,
    question_kind: z.enum(["input", "approval"]), structured: z.boolean(), answers: z.record(z.string(), z.union([z.string(), z.array(z.string())])).nullable(), answer_text: z.string().nullable(), answered_locally: z.boolean(),
  }).refine((command) => !command.answered_locally || (command.answers === null && command.answer_text === null)),
  z.strictObject({ ...bridgeV1CommandBase, kind: z.literal("cancel"), abandoned_request_id: bridgeV1Identity.nullable(), cancel_scope: z.enum(["turn", "turn_and_processes"]) }),
]);
export const bridgeV1AckResponseSchema = z.discriminatedUnion("status", [
  z.strictObject({ status: z.enum(["leased", "replay"]), command: bridgeV1CommandPayloadSchema, lease_expires_at: z.iso.datetime({ offset: true }) }),
  z.strictObject({ status: z.literal("withdrawn"), reason: z.enum(["write_gate_closed", "adapter_disabled", "not_connected", "session_closed", "session_external", "expired", "action_closed", "stale_answer", "unsupported"]) }),
  z.strictObject({ status: z.literal("stale"), reason: z.enum(["not_prepared", "heartbeat_first", "policy_changed", "run_closed", "wrong_state", "write_gate_closed"]).optional() }),
  z.strictObject({ status: z.literal("settled"), task_state: agentTaskStateSchema.optional() }),
]);
export const bridgeV1EventsRequestSchema = z.strictObject({ bridge_id: z.guid(), events: z.array(z.unknown()).min(1).max(100) });
export const bridgeV1EventsResponseSchema = z.strictObject({
  results: z.array(z.strictObject({ event_id: bridgeV1Identity, status: z.enum(["applied", "duplicate", "ignored", "late", "conflict", "question_conflict", "reconcile_conflict", "invalid_state", "step_not_calling", "not_found", "wrong_bridge"]), task_state: agentTaskStateSchema.optional() })),
  accepted_event_ids: z.array(bridgeV1Identity), retry_event_ids: z.array(bridgeV1Identity), rejected: z.array(z.strictObject({ event_id: z.string(), code: z.literal("invalid") })),
});
export const bridgeV1HeartbeatRequestSchema = z.strictObject({
  bridge_id: z.guid(), sent_at: z.iso.datetime({ offset: true }), app_version: z.string().min(1).max(50).optional(),
  tasks: z.array(z.strictObject({ task_id: z.guid(), process_alive: z.boolean(), last_seq: z.number().int().nonnegative().nullable() })).max(50), adapters: bridgeV1AdapterReportsSchema.optional(),
});
export type BridgeV1HeartbeatRequest = z.infer<typeof bridgeV1HeartbeatRequestSchema>;
export const bridgeV1HeartbeatResponseSchema = z.strictObject({ throttled: z.literal(true).optional(), heartbeat_interval_seconds: z.literal(30), server_time: z.iso.datetime({ offset: true }), pending_commands: z.number().int().nonnegative(), unknown_task_ids: z.array(z.guid()).max(50), missing_task_ids: z.array(z.guid()).max(50) });
// --- D1d ---
// 대화 API v2 확장 (OA D1d-s, Assistant 계약 v3 2–5장). 기존 B2 스키마는 지문 · 모양 그대로 두고, 필요한 확장은 파생 스키마를 새 이름으로 둔다 (OD-26).
// 에이전트 대화 route(/api/v2/conversations 확장 · agent-sessions · agent-tasks · assistant/targets)만 이 스키마를 쓴다. 결정적 Action id는 UUID 버전 비트가 없어 Action id는 z.guid()다.

export const conversationTargetKindSchema = z.enum(["taskforce", "agent"]);
export type ConversationTargetKind = z.infer<typeof conversationTargetKindSchema>;
/** 대화 대상 (계약 3.1): 만든 뒤 바뀌지 않는다. agent는 내 에이전트 연결이 필수이고 세션은 선택(같은 연결의 세션) */
export const conversationTargetSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("taskforce") }),
  z.strictObject({ kind: z.literal("agent"), connection_id: z.uuid(), session_id: z.uuid().optional() }),
]);
export type ConversationTarget = z.infer<typeof conversationTargetSchema>;

/** POST /api/v2/conversations: 기존 { id?, title?, context_id? } + target?(없으면 taskforce). 같은 id에 다른 target이면 409 target_mismatch */
export const createConversationV2RequestSchema = createConversationRequestSchema.extend({ target: conversationTargetSchema.optional() });
export type CreateConversationV2Request = z.infer<typeof createConversationV2RequestSchema>;
/** 만들기 응답의 대화: 기존 행 + 대상 열 (taskforce는 target_kind 'taskforce', 연결 · 세션 null) */
export const conversationWithTargetSchema = conversationSchema.extend({
  target_kind: conversationTargetKindSchema,
  agent_connection_id: z.uuid().nullable(),
  agent_session_id: z.uuid().nullable(),
});
export type ConversationWithTarget = z.infer<typeof conversationWithTargetSchema>;
export const createConversationV2ResponseSchema = z.object({ conversation: conversationWithTargetSchema });
export type CreateConversationV2Response = z.infer<typeof createConversationV2ResponseSchema>;

// ─── 맥락 칩 (계약 2.1 · 2.2) ───
export const attachmentKindSchema = z.enum(["action", "context", "agent_session", "run", "artifact", "source"]);
export type AttachmentKind = z.infer<typeof attachmentKindSchema>;
/** auto = 패널에 열린 항목(점선 칩, 에이전트로는 보내지 않는다) · added = Ask · 끌어다 놓기 · 첨부 */
export const attachmentOriginSchema = z.enum(["auto", "added"]);
export type AttachmentOrigin = z.infer<typeof attachmentOriginSchema>;
export const attachmentSchema = z.strictObject({ kind: attachmentKindSchema, id: z.guid(), origin: attachmentOriginSchema });
export type Attachment = z.infer<typeof attachmentSchema>;

/**
 * POST /api/v2/conversations/{id}/messages: 기존 { client_message_id, text, refs? } + attachments?(≤ 20).
 * refs와 attachments를 함께 보내면 400 (OD-4): 새 앱은 attachments만 보낸다. 같은 client_message_id에 정규화한 attachments가 다르면 409 conflict(다른 대상)
 */
export const postConversationMessageV2RequestSchema = postConversationMessageRequestSchema
  .extend({ attachments: z.array(attachmentSchema).max(20).optional() })
  .refine((request) => request.refs === undefined || request.attachments === undefined, { message: "refs와 attachments는 함께 보낼 수 없습니다", path: ["attachments"] });
export type PostConversationMessageV2Request = z.infer<typeof postConversationMessageV2RequestSchema>;

// ─── 전달 표시 (계약 2.4 · 3.2) ───
/** answered ~ cancelled는 메시지 열(또는 답 글), sent · accepted · unknown은 dispatched 뒤 전달 단계에서 계산한다 */
export const agentDeliveryStateSchema = z.enum(["answered", "queued", "needs_referent", "not_sent", "expired", "cancelled", "sent", "accepted", "unknown"]);
export type AgentDeliveryState = z.infer<typeof agentDeliveryStateSchema>;
/**
 * 계약 2.4의 아홉 + SQL이 실제로 쓰는 여덟 (OD-12) + 읽을 때 서버가 계산하는 하나. 앱은 모르는 값을 만나도 깨지지 않는다 (open string).
 * billing_required: 구독이 끝난 계정 때문에 멈춘 메시지(저장된 이유는 write_gate_closed)를 읽을 때만 보인다 — SQL은 이 값을 쓰지 않는다 (결제 계약 22장)
 */
export const agentDeliveryReasonSchema = z.enum([
  "not_connected", "sign_in_needed", "unsupported", "write_gate_closed", "session_external", "version_unsupported", "usage_limited", "spawn_failed", "not_received",
  "session_busy", "live_limit", "queue_order", "session_closed", "invalid_referent", "not_found", "already_dispatched", "question_open", "billing_required",
]);
export type AgentDeliveryReason = z.infer<typeof agentDeliveryReasonSchema>;
export const agentDeliverySchema = z.strictObject({
  state: agentDeliveryStateSchema,
  reason: agentDeliveryReasonSchema.optional(),
  /** needs_referent일 때 ≤ 3 */
  candidates: z.array(z.strictObject({ action_id: z.guid(), title: z.string() })).max(3).optional(),
});
export type AgentDelivery = z.infer<typeof agentDeliverySchema>;
export const attachmentDroppedSchema = z.strictObject({ kind: attachmentKindSchema, id: z.guid(), reason: z.enum(["deleted", "access_lost", "slack_purged"]) });
export type AttachmentDropped = z.infer<typeof attachmentDroppedSchema>;

/** 에이전트 대화의 사용자 메시지: 기존 메시지 + 전달 열 (대상 agent의 사용자 메시지만 값이 있다) */
export const agentConversationMessageSchema = conversationMessageSchema.extend({
  delivery_state: z.enum(["queued", "not_sent", "dispatched", "expired", "cancelled"]).nullable(),
  delivery_reason: z.string().nullable(),
  delivery_expires_at: z.string().nullable(),
});
export type AgentConversationMessage = z.infer<typeof agentConversationMessageSchema>;

/** 에이전트 대상 보내기 · referent 응답 (계약 2.4): reply는 null — 답은 비동기로 대화에 쓰인다 (3.5) */
export const postAgentMessageResponseSchema = z.object({
  message: agentConversationMessageSchema,
  reply: z.null(),
  delivery: agentDeliverySchema,
  attachments_dropped: z.array(attachmentDroppedSchema),
  created_action: z.strictObject({ id: z.guid(), number: z.number().int().positive().nullable(), title: z.string(), context_id: z.uuid().nullable() }).nullable(),
  agent_task: z.strictObject({ id: z.guid(), state: agentTaskStateSchema, agent_session_id: z.guid() }).nullable(),
});
export type PostAgentMessageResponse = z.infer<typeof postAgentMessageResponseSchema>;

/** POST /api/v2/conversations/{id}/deliver (Send again): message_ids가 없으면 그 대화의 보류 · 만료 메시지 전부 */
export const deliverAgentMessagesRequestSchema = z.strictObject({ message_ids: z.array(z.uuid()).min(1).max(50).optional() });
export type DeliverAgentMessagesRequest = z.infer<typeof deliverAgentMessagesRequestSchema>;
/** result requeued: 다시 대기시켰다 · skipped: 건너뛰었다(not_eligible 상태가 아님 · not_found 이 대화의 것이 아님 · unknown_outcome 결과 불명). not_found에는 delivery가 없다 */
export const deliverAgentMessagesResponseSchema = z.object({
  messages: z.array(z.strictObject({
    message_id: z.guid(),
    result: z.enum(["requeued", "skipped"]),
    skipped_reason: z.enum(["not_eligible", "not_found", "unknown_outcome"]).optional(),
    delivery: agentDeliverySchema.optional(),
  })),
});
export type DeliverAgentMessagesResponse = z.infer<typeof deliverAgentMessagesResponseSchema>;

/** POST /api/v2/conversations/{id}/messages/{message_id}/referent: needs_referent 후보 중 하나를 고른다 */
export const setReferentRequestSchema = z.strictObject({ action_id: z.guid() });
export type SetReferentRequest = z.infer<typeof setReferentRequestSchema>;

/** GET /api/v2/conversations/{id}/delivery?since_seq= (OD-13): RLS로 읽은 메시지의 전달 표시를 서버 계산으로 */
export const conversationDeliveryResponseSchema = z.object({
  messages: z.array(z.strictObject({ message_id: z.guid(), seq: z.number().int().positive(), delivery: agentDeliverySchema })).max(100),
});
export type ConversationDeliveryResponse = z.infer<typeof conversationDeliveryResponseSchema>;

// ─── 중단 · 세션 (계약 3.8 · 5장) ───
/** 본문 없는 쓰기 (Stop · Open in Terminal): {} */
export const agentEmptyRequestSchema = z.strictObject({});
export const agentStopResponseSchema = z.strictObject({
  tasks: z.array(z.strictObject({
    agent_task_id: z.guid(),
    cancel: z.enum(["requested_only", "confirmed"]),
    /** Codex처럼 턴만 끊는 adapter: 실행 중 명령이 남을 수 있다 */
    processes: z.literal("may_continue").optional(),
  })),
});
export type AgentStopResponse = z.infer<typeof agentStopResponseSchema>;
export const agentSessionSchema = z.strictObject({
  id: z.guid(),
  connection_id: z.guid(),
  display_name: z.string(),
  status: agentSessionStatusSchema,
  last_turn_seq: z.number().int().nonnegative(),
  updated_at: z.string(),
});
export type AgentSession = z.infer<typeof agentSessionSchema>;
export const updateAgentSessionRequestSchema = z.strictObject({ display_name: z.string().trim().min(1).max(200) });
export type UpdateAgentSessionRequest = z.infer<typeof updateAgentSessionRequestSchema>;
export const agentSessionResponseSchema = z.object({ session: agentSessionSchema });
export type AgentSessionResponse = z.infer<typeof agentSessionResponseSchema>;
/** Resume here: 사용자가 터미널 세션을 닫았다고 확인한 뒤에만 (계약 3.8). 서버는 이 확인을 본문으로 받는다 */
export const resumeAgentSessionRequestSchema = z.strictObject({ confirmed_terminal_closed: z.literal(true) });
export type ResumeAgentSessionRequest = z.infer<typeof resumeAgentSessionRequestSchema>;
export const resumeAgentSessionResponseSchema = z.object({ session: agentSessionSchema, started_message_id: z.guid().nullable() });
export type ResumeAgentSessionResponse = z.infer<typeof resumeAgentSessionResponseSchema>;

// ─── 외부 세션 이어받기 (OA 외부 세션 PR2s, 계약 7장 ES-16 · ES-17 · 19장) ───
/**
 * POST /api/v2/agent-sessions/attach: Taskforce 밖에서 시작한 Claude Code 세션을 이 Mac의 세션으로 이어받는다.
 * - external_session_id: Claude 세션 UUID, 정규 소문자 형태만. `--resume`에 그대로 쓰이므로 경로 · 옵션 · `pending:` 모양이 들어갈 길을 0으로 한다 (보안 T5).
 * - workspace_ref: 가상 루트 `/taskforce/ws_<소문자 UUID>`뿐 (D4a2-03). 실제 경로 모양은 서버가 받지 않는다 — 경로가 서버에 오지 않음을 서버도 강제한다.
 * 사용자 id · 연결 id는 본문에 없다 (인증과 bridge의 active 연결에서 온다). 모르는 칸은 거절한다.
 */
export const attachAgentSessionRequestSchema = z.strictObject({
  bridge_id: z.uuid(),
  adapter: agentAdapterIdSchema,
  external_session_id: z.uuid().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
  workspace_ref: z.string().regex(/^\/taskforce\/ws_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/),
});
export type AttachAgentSessionRequest = z.infer<typeof attachAgentSessionRequestSchema>;
/**
 * created = 이 요청이 세션 또는 대화를 새로 만들었다 (201), existing = 같은 Claude id가 이미 묶여 있어 그 행을 돌려준다 (200, 멱등).
 * workspace_ref = 서버에 저장된 가상 루트 (앱은 자기 핀과 맞춘다). existing인데 보낸 값과 다르면 서버가 bound · 열린 작업 없음일 때 보낸 값으로 고친 것이다 —
 * 고칠 수 없으면 409 workspace_mismatch. 이미 있던 세션의 값은 가상 루트 모양이 아닐 수 있어 응답은 비어 있지 않은 글만 본다.
 */
export const attachAgentSessionResponseSchema = z.strictObject({
  status: z.enum(["created", "existing"]),
  conversation_id: z.guid(),
  workspace_ref: z.string().min(1).max(500),
  session: agentSessionSchema,
});
export type AttachAgentSessionResponse = z.infer<typeof attachAgentSessionResponseSchema>;

// ─── 대상 목록 (계약 4.5) ───
export const agentTargetStateSchema = z.enum(["ready", "not_connected", "sign_in_needed", "unreachable", "unsupported"]);
export type AgentTargetState = z.infer<typeof agentTargetStateSchema>;
export const agentAccessSchema = z.enum(["write", "read_only"]);
export type AgentAccess = z.infer<typeof agentAccessSchema>;
export const assistantTargetSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("taskforce") }),
  z.strictObject({
    kind: z.literal("agent"),
    adapter: agentAdapterIdSchema,
    display_name: z.string(),
    connection_id: z.guid().nullable(),
    state: agentTargetStateSchema,
    access: agentAccessSchema.nullable(),
  }),
]);
export type AssistantTarget = z.infer<typeof assistantTargetSchema>;
export const assistantTargetsResponseSchema = z.object({ targets: z.array(assistantTargetSchema) });
export type AssistantTargetsResponse = z.infer<typeof assistantTargetsResponseSchema>;

// ─── 질문에 답하기 (계약 3.6) ───
const agentAnswerTextSchema = z.string().refine((value) => Array.from(value).length <= 2000, "답은 2000자 이하");
/** POST /api/v2/agent-tasks/{id}/answer: 질문마다 단일 글 또는 선택지 배열(다중 선택). 정확한 검증은 질문 모양에 맞춰 서버가 다시 한다 */
export const answerAgentQuestionRequestSchema = z.strictObject({
  provider_request_id: z.string().min(1).max(200),
  answers: z.record(z.string().max(200), z.union([agentAnswerTextSchema, z.array(agentAnswerTextSchema).max(10)])),
});
export type AnswerAgentQuestionRequest = z.infer<typeof answerAgentQuestionRequestSchema>;
export const answerAgentQuestionResponseSchema = z.strictObject({ status: z.enum(["answered", "duplicate"]), step_id: z.guid() });
export type AnswerAgentQuestionResponse = z.infer<typeof answerAgentQuestionResponseSchema>;

// ─── 오류 코드 ───
/** busy_retry: 잠금 경합(55P03 · 40001)이 재시도를 넘겼다 — 쓰기 0이고 같은 요청을 다시 보내도 된다 (코디네이터 결정 5.1). 나머지는 계약 OD-26 */
export const agentConversationErrorCodeSchema = z.enum(["target_mismatch", "question_stale", "secret_requires_local", "session_busy", "approval_via_review", "busy_retry"]);
export type AgentConversationErrorCode = z.infer<typeof agentConversationErrorCodeSchema>;
/**
 * 이어받기(POST /api/v2/agent-sessions/attach)가 더하는 코드. session_in_use = 409 (다른 연결 · 닫힌 세션에 이미 묶임), forbidden = 403 (registry grade),
 * workspace_mismatch = 409 (이미 묶인 세션의 가상 루트가 보낸 값과 다른데 고칠 수 없다: bound가 아니거나 열린 작업이 있다). 위 여섯 목록은 그대로다
 */
export const agentAttachErrorCodeSchema = z.enum(["session_in_use", "forbidden", "workspace_mismatch"]);
export type AgentAttachErrorCode = z.infer<typeof agentAttachErrorCodeSchema>;
/**
 * Claude 데스크톱 대화 저장(PUT /api/v2/claude-app-chats, OA PR-D3s)이 더하는 코드. bridge_not_found = 404 (없는 · 남의 · 해제된 bridge: 저장 gate가 꺼진 404 not_found와 **다른 코드**라
 * Mac이 둘을 헷갈리지 않는다), quota_exceeded = 413 (사용자별 한도: 저장 본문 합계 50 MiB · 채팅 2,000개). 위 목록(apiErrorV2AgentCodeSchema)은 그대로다
 * (그 길이를 고정하는 시험이 있다): 이 route의 목록은 따로 `apiErrorV2ClaudeAppChatCodeSchema`(= v2 에이전트 코드 + 이 둘)다
 */
export const claudeAppChatErrorCodeSchema = z.enum(["bridge_not_found", "quota_exceeded"]);
export type ClaudeAppChatErrorCode = z.infer<typeof claudeAppChatErrorCodeSchema>;
export const apiErrorV2AgentCodeSchema = z.enum([...apiErrorV2CodeSchema.options, ...agentConversationErrorCodeSchema.options, ...agentAttachErrorCodeSchema.options]);
export type ApiErrorV2AgentCode = z.infer<typeof apiErrorV2AgentCodeSchema>;
export const apiErrorV2ClaudeAppChatCodeSchema = z.enum([...apiErrorV2AgentCodeSchema.options, ...claudeAppChatErrorCodeSchema.options]);
export type ApiErrorV2ClaudeAppChatCode = z.infer<typeof apiErrorV2ClaudeAppChatCodeSchema>;

// --- D3c-2 ---
// SQL measures target length after NFC so overlong targets return deny/path_too_long, not HTTP 400.
const toolRealPathSchema = z.string().min(1).refine((value) =>
  value.startsWith("/") && (value === "/" || !value.slice(1).split("/").some((part) => part === "" || part === "." || part === ".."))
  && !Array.from(value).some((char) => char.charCodeAt(0) < 32 || char.charCodeAt(0) === 127));
const toolRequestIdSchema = z.string().min(1).max(200);
const toolCwdSchema = z.string().min(1).max(4096).startsWith("/");
const toolTargetSchema = z.strictObject({ real_path: toolRealPathSchema, rel_path: z.string().min(1).max(1000) });
export const toolDecisionReasonSchema = z.enum([
  "readonly_command", "policy_auto", "manual_write", "command_not_readonly", "actions_not_read", "not_first_request",
  "runs_without_sandbox", "server_busy", "write_gate_closed", "read_only", "permission_mode", "background", "sandbox_disabled",
  "outside_workspace", "workspace_mismatch", "path_in_use", "not_live", "rate_limited", "tool_config_write", "path_too_long",
]);
export type ToolDecisionReason = z.infer<typeof toolDecisionReasonSchema>;
export const bridgeV1ToolDecisionRequestSchema = z.strictObject({
  bridge_id: z.guid(), agent_session_id: z.guid(), agent_task_id: z.guid(), turn_seq: z.number().int().positive(),
  workspace_real_path: toolRealPathSchema.refine((value) => Array.from(value.normalize("NFC")).length <= 500),
  call: z.discriminatedUnion("kind", [
    z.strictObject({ kind: z.literal("claude_bash"), tool_use_id: toolRequestIdSchema, permission_mode: z.string().min(1).max(50),
      cwd: toolCwdSchema, command: z.string().min(1).max(4096), run_in_background: z.boolean(), dangerously_disable_sandbox: z.boolean() }),
    z.strictObject({ kind: z.literal("claude_write"), tool_use_id: toolRequestIdSchema, permission_mode: z.string().min(1).max(50),
      tool: z.enum(["Edit", "Write"]), target: toolTargetSchema }),
    z.strictObject({ kind: z.literal("codex_command"), provider_request_id: toolRequestIdSchema, cwd: toolCwdSchema,
      command: z.string().min(1).max(4096), command_actions: z.array(z.string().min(1).max(50)).max(32), first_for_item: z.boolean() }),
    z.strictObject({ kind: z.literal("codex_file_change"), provider_request_id: toolRequestIdSchema,
      targets: z.array(toolTargetSchema).min(1).max(20), first_for_item: z.boolean() }),
  ]),
});
export type BridgeV1ToolDecisionRequest = z.infer<typeof bridgeV1ToolDecisionRequestSchema>;
export const bridgeV1ToolDecisionResponseSchema = z.strictObject({
  decision: z.enum(["allow", "deny", "defer"]), reason: toolDecisionReasonSchema,
  parse: z.strictObject({ wrapper: z.enum(["none", "zsh_lc"]), argv: z.array(z.string()),
    paths: z.array(z.strictObject({ index: z.number().int().nonnegative().nullable(), absolute: z.string().startsWith("/") })), implicit_cwd: z.boolean() }).optional(),
  agent_note: z.string().max(300).optional(), holder: z.strictObject({ action_number: z.number().int().nullable(), rel_path: z.string().min(1).max(1000) }).optional(),
  card_flags: z.array(z.literal("runs_without_sandbox")).max(1), server_time: z.iso.datetime({ offset: true }),
}).refine((value) => (!value.parse || value.decision === "allow" && value.reason === "readonly_command") && (!value.agent_note || value.decision === "deny"));
export type BridgeV1ToolDecisionResponse = z.infer<typeof bridgeV1ToolDecisionResponseSchema>;
// --- D4b-s ---
// Review 입력 연결 (OA D4b-s). C3 줄은 고치지 않고 파생 스키마를 새 이름으로 둔다 (D1d OD-26 방식). 최상위 키 · sources · complete · empty의 뜻은 그대로다:
// 새 것은 ① 종류 값 넷 ② 새 종류에만 붙는 선택 키(agent · result · conflict) ③ 해소 route 하나다. 응답에 글이 없다 — 질문 글 · 경로 · 제목은 앱이 RLS로 읽는다.
// Action id는 결정적 id라 UUID 버전 비트가 없어 z.guid()다 (run · lease id는 gen_random_uuid()라 z.uuid()).

/** 결정 대기 종류 (src/lib/coordinator/pending.ts PENDING_KINDS와 같다: 순서까지 시험이 견준다). C3 종류가 앞부분이고 에이전트 종류 넷이 끝에 덧붙는다 */
export const reviewDecisionKindSchema = z.enum([...pendingDecisionKindSchema.options, "agent_approval", "agent_secret_question", "result_ready", "path_conflict"]);
export type ReviewDecisionKind = z.infer<typeof reviewDecisionKindSchema>;

/** agent_question · agent_approval · agent_secret_question 항목의 열쇠: 답은 POST /api/v2/agent-tasks/{task_id}/answer { provider_request_id, answers }. bridge_id는 세션 연결의 bridge (지워졌으면 null) */
export const reviewAgentRefSchema = z.strictObject({ task_id: z.guid(), session_id: z.guid(), provider_request_id: z.string().min(1).max(200), adapter: agentAdapterIdSchema, bridge_id: z.guid().nullable() });
export type ReviewAgentRef = z.infer<typeof reviewAgentRefSchema>;
/** result_ready 항목: 검토하지 않은 산출물이 있는 턴 범위 (reviewed_turn_seq 초과 ~ last_turn_seq). changed_at = 그 산출물 중 가장 늦은 생성 시각 */
export const reviewResultRefSchema = z.strictObject({ session_id: z.guid().nullable(), reviewed_turn_seq: z.number().int().min(0), last_turn_seq: z.number().int().min(1), changed_at: z.string() });
export type ReviewResultRef = z.infer<typeof reviewResultRefSchema>;
/** path_conflict 항목: 해소는 POST /api/v2/path-conflicts/{lease_id}/resolve { keep, conflict_version }. released = lease가 이미 해제됨, stopped = 늦게 쓴 run을 멈췄다 */
export const reviewConflictRefSchema = z.strictObject({
  lease_id: z.uuid(), conflict_version: z.number().int().min(1), holder_action_id: z.guid(), holder_run_id: z.uuid(), later_run_id: z.uuid(), released: z.boolean(), stopped: z.boolean(),
});
export type ReviewConflictRef = z.infer<typeof reviewConflictRefSchema>;

/** 결정 항목: 새 종류는 자기 ref 하나만 갖고, C3 종류에는 세 키가 모두 없다 (키 자체가 없다) */
export const reviewDecisionItemSchema = pendingDecisionItemSchema.extend({
  kind: reviewDecisionKindSchema,
  action_id: z.guid(),
  agent: reviewAgentRefSchema.optional(),
  result: reviewResultRefSchema.optional(),
  conflict: reviewConflictRefSchema.optional(),
});
export type ReviewDecisionItem = z.infer<typeof reviewDecisionItemSchema>;
export const reviewDecisionGroupSchema = pendingDecisionGroupSchema.extend({ kind: reviewDecisionKindSchema, action_id: z.guid(), items: z.array(reviewDecisionItemSchema) });
export type ReviewDecisionGroup = z.infer<typeof reviewDecisionGroupSchema>;
/** GET /api/v2/review 응답 (D4b-s 이후). decisions가 서버 순서 그대로 Needs you 순서다 — 앱은 다시 정렬하지 않는다 */
export const reviewWithAgentsResponseSchema = reviewResponseSchema.extend({ decisions: z.array(reviewDecisionGroupSchema).nullable() });
export type ReviewWithAgentsResponse = z.infer<typeof reviewWithAgentsResponseSchema>;

/** 복귀 요약 줄 (D4b-s 이후): decisions[].id/version = Review 항목 id/version. needs_answer는 result_ready 아닌 결정이 있을 때, next는 answer → review_result → open 순 */
export const returnSummaryWithAgentsItemSchema = returnSummaryItemSchema.extend({
  action_id: z.guid(),
  decisions: z.array(z.object({ id: z.string(), kind: reviewDecisionKindSchema, version: z.string(), urgent: z.boolean() })),
  next: returnSummaryNextSchema.extend({ decision_kinds: z.array(reviewDecisionKindSchema) }),
});
export type ReturnSummaryWithAgentsItem = z.infer<typeof returnSummaryWithAgentsItemSchema>;
export const returnSummaryWithAgentsResponseSchema = returnSummaryResponseSchema.extend({ items: z.array(returnSummaryWithAgentsItemSchema) });
export type ReturnSummaryWithAgentsResponse = z.infer<typeof returnSummaryWithAgentsResponseSchema>;

/**
 * POST /api/v2/path-conflicts/{lease_id}/resolve { keep, conflict_version }: conflict_version은 Review 항목 conflict.conflict_version 그대로 (integer CAS, DB integer 범위).
 * holder = 먼저 쓴 쪽을 남긴다(충돌 표시만 지운다) · later = 늦게 쓴 쪽을 남긴다(holder의 살아 있는 lease를 푼다). 멈춘 run을 다시 시작하지 않고 파일을 되돌리지 않는다.
 * 200 { status: "resolved" } · 409 conflict(옛 version이거나 이미 해소됨: 쓰기 0, 앱은 자동 재시도 없이 Review를 다시 읽는다) · 404 · 400 · 401
 */
export const resolvePathConflictRequestSchema = z.strictObject({ keep: z.enum(["holder", "later"]), conflict_version: z.number().int().min(1).max(2_147_483_647) });
export type ResolvePathConflictRequest = z.infer<typeof resolvePathConflictRequestSchema>;
export const resolvePathConflictResponseSchema = z.strictObject({ status: z.literal("resolved") });
export type ResolvePathConflictResponse = z.infer<typeof resolvePathConflictResponseSchema>;

// --- D4c-2 ---
// 이슈 삭제 · 병합 확인 카드(제안 delete · merge)의 버튼. 쓰기는 conversation_confirm_proposal 한 트랜잭션이고 AI를 부르지 않는다.

/** POST /api/v2/conversations/{id}/proposals/{proposal_id}/confirm · /dismiss — 본문은 빈 객체(또는 없음) */
export const proposalActionRequestSchema = z.strictObject({});
export type ProposalActionRequest = z.infer<typeof proposalActionRequestSchema>;
/** 200: confirmed(이 요청이 썼다) · already(이미 확인한 카드: 쓰기 0, 두 번 눌러도 한 번). event = 대화의 기록 줄(role event), 찾지 못하면 null */
export const proposalConfirmResponseSchema = z.strictObject({
  status: z.enum(["confirmed", "already"]),
  op: z.enum(["delete", "merge"]),
  action_ids: z.array(z.guid()).min(1).max(3),
  event: conversationMessageSchema.nullable(),
});
export type ProposalConfirmResponse = z.infer<typeof proposalConfirmResponseSchema>;
export const proposalDismissResponseSchema = z.strictObject({ status: z.enum(["dismissed", "already"]) });
export type ProposalDismissResponse = z.infer<typeof proposalDismissResponseSchema>;

/** 409: superseded = 대상이 카드 뒤에 바뀜(쓰기 0, 새 카드가 대화에 있다) · not_open = 취소됐거나 다른 제안으로 대체됨. busy_retry는 D1d 코드를 같이 쓴다(잠금 경합이 재시도를 넘김: 쓰기 0, 다시 보내도 된다) */
export const organizeErrorCodeSchema = z.enum(["superseded", "not_open"]);
export const apiErrorV2OrganizeCodeSchema = z.enum([...apiErrorV2CodeSchema.options, ...organizeErrorCodeSchema.options, "busy_retry"]);
export const proposalConflictSchema = z.object({
  error: z.object({ code: apiErrorV2OrganizeCodeSchema, message: z.string() }),
  /** superseded일 때 대화에 새로 낸 카드 메시지 (앱은 대화를 다시 읽는다) */
  card_message_id: z.uuid().optional(),
});
export type ProposalConflict = z.infer<typeof proposalConflictSchema>;
// --- F2 ---
/**
 * POST /api/v1/bridge/answer-local (OA F2): 그 세션을 가진 Mac이 "이 비밀값 질문은 이 Mac에서 답했다"를 서버에 표시한다. 값은 오지 않는다.
 * 사용자 토큰 + X-Taskforce-Bridge-Secret 헤더(기기 자격). 본문에는 글을 담을 자리가 없다: UUID 둘과 고정 길이 소문자 16진 하나뿐인 strict 객체이고 상한은 512바이트다.
 * request_digest = provider_request_id의 UTF-8 SHA-256 소문자 16진 64자 (provider_request_id는 아무 글자 200자까지라 본문에 실을 수 없다).
 * 200 { status: "answered" | "duplicate", step_id } · { status: "stale", reason } — 도메인 결과는 200의 status로 준다(D2a ack의 stale · withdrawn과 같은 bridge 관례).
 * 오류는 v1 코드만: 400 invalid_request(고정 문구) · 401 · 403 · 404 not_found · 409 conflict(다시 보내도 된다) · 429 rate_limited.
 */
export const BRIDGE_ANSWER_LOCAL_MAX_BYTES = 512;
export const bridgeV1AnswerLocalRequestSchema = z.strictObject({
  bridge_id: z.guid(), agent_task_id: z.guid(), request_digest: z.string().regex(/^[0-9a-f]{64}$/),
});
export type BridgeV1AnswerLocalRequest = z.infer<typeof bridgeV1AnswerLocalRequestSchema>;
/** question_closed = 이미 닫히거나 바뀐 질문 · not_live = heartbeat 공백(참고: Mac이 되살린 뒤 한 번 다시) · not_secret = 비밀값 입력 질문이 아님 */
export const bridgeV1AnswerLocalStaleReasonSchema = z.enum(["question_closed", "not_live", "not_secret"]);
export const bridgeV1AnswerLocalResponseSchema = z.discriminatedUnion("status", [
  z.strictObject({ status: z.enum(["answered", "duplicate"]), step_id: z.guid() }),
  z.strictObject({ status: z.literal("stale"), reason: bridgeV1AnswerLocalStaleReasonSchema }),
]);
export type BridgeV1AnswerLocalResponse = z.infer<typeof bridgeV1AnswerLocalResponseSchema>;

// --- F1s ---
// Mac 기기 이름(표시용, OA F1s). 식별(device_ref 해시 · device_id)과 섞지 않는다: 이름은 화면에 보이는 글자일 뿐 어떤 판정 · 조인 · 열쇠에도 쓰지 않는다.
// 위 스키마는 F1s 전 모양의 기록으로 그대로 두고, 이름을 받고 내는 파생 스키마를 새 이름으로 둔다.

/** 서버 정규화 뒤 이름은 1–64 코드 포인트다 (src/lib/bridge/device-name.ts). 받는 원문은 256 코드 포인트까지만 받는다 */
export const BRIDGE_DEVICE_NAME_MAX = 64;
export const bridgeV1DeviceNameSchema = z.string().refine((value) => Array.from(value).length <= 256, "기기 이름 원문은 256 코드 포인트 이하");
export const bridgeV1RegisterRequestWithDeviceSchema = bridgeV1RegisterRequestSchema.extend({ device_name: bridgeV1DeviceNameSchema.optional() });
export const bridgeV1HeartbeatRequestWithDeviceSchema = bridgeV1HeartbeatRequestSchema.extend({ device_name: bridgeV1DeviceNameSchema.optional() });
export type BridgeV1RegisterRequestWithDevice = z.infer<typeof bridgeV1RegisterRequestWithDeviceSchema>;
export type BridgeV1HeartbeatRequestWithDevice = z.infer<typeof bridgeV1HeartbeatRequestWithDeviceSchema>;

/** 대상 목록의 agent 행: 모르면 device_name null (옛 Mac · 연결 없음 · bridge 없음 · 폐기), bridge_id는 연결의 bridge (연결 없음 · bridge 지워짐이면 null) */
export const assistantAgentTargetWithDeviceSchema = assistantTargetSchema.options[1].extend({
  device_name: z.string().refine((value) => {
    const points = Array.from(value).length;
    return points >= 1 && points <= BRIDGE_DEVICE_NAME_MAX;
  }, "기기 이름은 1–64 코드 포인트").nullable(),
  bridge_id: z.guid().nullable(),
});
export const assistantTargetWithDeviceSchema = z.discriminatedUnion("kind", [assistantTargetSchema.options[0], assistantAgentTargetWithDeviceSchema]);
export const assistantTargetsWithDeviceResponseSchema = z.object({ targets: z.array(assistantTargetWithDeviceSchema) });
export type AssistantTargetWithDevice = z.infer<typeof assistantTargetWithDeviceSchema>;
export type AssistantTargetsWithDeviceResponse = z.infer<typeof assistantTargetsWithDeviceResponseSchema>;

// --- R-dec ---
// 결정만 읽기 (OA R-dec, U3-21). GET /api/v2/review와 같은 계산(decisions · 순서 · version · 에이전트 ref)이고 Taskforce 행을 쓰지 않는다(제안 생산 · 노출 · 묶음 소비 0).
// 원천이 결정 하나라 complete = sources.decisions가 ok, empty = complete이면서 결정 0. 응답에 글 · 개수가 없다.
/** GET /api/v2/review/decisions 응답. decisions가 서버 순서 그대로 Needs you 순서다 — 앱은 다시 정렬하지 않는다 */
export const reviewDecisionsResponseSchema = z.strictObject({
  generated_at: z.string(),
  complete: z.boolean(),
  empty: z.boolean(),
  sources: z.strictObject({ decisions: reviewSourceStatusSchema }),
  decisions: z.array(reviewDecisionGroupSchema).nullable(),
});
export type ReviewDecisionsResponse = z.infer<typeof reviewDecisionsResponseSchema>;

// --- PR-D3s ---
// Claude 데스크톱 세션과 나눈 대화 저장 (OA PR-D3s, 계약 handoffs/oa-external-sessions-contract.md 25 · 26장). 새 경로라 v1 · 기존 v2 호환 영향 0.
// 서버에 가는 것: Mac이 Claude 데스크톱 세션으로 보낸 글("Received"로 확인된 것) + 그 뒤 세션의 답 글 + 답 글 앞에서 쓴 **도구 단계의 이름만**(순서대로, 최대 40) + 제목 + 불투명 id(HMAC).
// 도구 입력 · 결과 · 경로 · 명령 · 폴더 이름 · Claude 세션 id는 받지 않는다 (strict). 서버가 시작하는 보내기 길은 없다. 보관: 사용자가 지울 때까지 (자동 삭제 없음, 26장).
export const CLAUDE_APP_CHAT_MAX_BATCH = 20;
export const CLAUDE_APP_CHAT_TOOL_NAMES_MAX = 40;
export const CLAUDE_APP_CHAT_USER_BODY_MAX = 16_000;
export const CLAUDE_APP_CHAT_ASSISTANT_BODY_MAX_BYTES = 64 * 1024;
/** PUT 본문 상한 (바이트): status가 max_bytes로 알려 준다. 넘으면 400 — Mac이 묶음을 이 크기로 나눈다 */
export const CLAUDE_APP_CHAT_MAX_BYTES = 256 * 1024;

// 짝 없는 서로게이트(JSON \ud800 같은)는 jsonb · text에 들어가지 못한다. NUL도 text에 못 담는다
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;
const claudeAppChatTextSchema = z
  .string()
  .min(1)
  .refine((value) => !value.includes("\u0000") && !LONE_SURROGATE.test(value), { message: "invalid text" });
/** 제목: 1차 보고(externalSessionTitleSchema)와 같은 규칙 + 짝 없는 서로게이트 거절 (그 값은 text 인자에 들어가지 못한다) */
const claudeAppChatTitleSchema = externalSessionTitleSchema.refine((value) => !LONE_SURROGATE.test(value), { message: "invalid title" });
/**
 * 도구 이름의 모양: 영문 · 숫자 · _ · -, 128자 이하. 경로 · 명령(`Bash(git status)`) · 공백이 든 값은 도구 이름이 아니다.
 * 128인 이유: Claude Code가 기록에 남기는 MCP 이름은 mcp__<서버 이름 또는 uuid>__<도구> 모양이라 Anthropic API의 64자를 넘는다 (uuid 서버는 80자 안팎).
 * 이 모양에 맞지 않는 이름은 Mac이 **그 이름만 버린다** (묶음을 실패시키지 않는다): 서버는 맞지 않는 이름이 하나라도 있으면 묶음 전체를 400으로 거절하기 때문이다.
 */
export const claudeAppToolNameSchema = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
const claudeAppChatRowBase = {
  /** Mac 열쇠 HMAC (사용자 글 = peer msg_id + pid, 답 글 = 기록 줄 uuid + 블록 번호) — 서버는 기록 id를 모른다. (chat, mac_ref)가 멱등 열쇠다 */
  mac_ref: externalSessionRefSchema,
  truncated: z.boolean(),
  /** 기록 줄의 시각 */
  said_at: z.iso.datetime({ offset: true }),
};
export const claudeAppChatMessageSchema = z.discriminatedUnion("role", [
  z.strictObject({ ...claudeAppChatRowBase, role: z.literal("user"), body: claudeAppChatTextSchema.max(CLAUDE_APP_CHAT_USER_BODY_MAX) }),
  z.strictObject({
    ...claudeAppChatRowBase,
    role: z.literal("assistant"),
    /** 같은 채팅의 사용자 글 mac_ref. 풀리지 않으면 그 행만 orphan으로 거절된다 */
    reply_to_ref: externalSessionRefSchema,
    body: claudeAppChatTextSchema
      .max(CLAUDE_APP_CHAT_ASSISTANT_BODY_MAX_BYTES)
      .refine((value) => new TextEncoder().encode(value).byteLength <= CLAUDE_APP_CHAT_ASSISTANT_BODY_MAX_BYTES, { message: "too large" }),
    /** 이 답 글 앞에서 쓴 도구 단계의 이름만 (순서대로). 입력 · 결과 · 경로 · 명령은 보내지 않는다 */
    tool_names: z.array(claudeAppToolNameSchema).max(CLAUDE_APP_CHAT_TOOL_NAMES_MAX).optional(),
  }),
]);
export type ClaudeAppChatMessage = z.infer<typeof claudeAppChatMessageSchema>;

/**
 * PUT /api/v2/claude-app-chats — 한 교환의 행들을 올린다 (멱등). 사용자 글은 그 답 글보다 앞(같은 묶음 또는 먼저 올린 묶음)이어야 풀린다.
 * title: **생략하면 저장된 제목을 그대로 둔다**, 명시한 값이면 바꾼다, 명시한 null이면 지운다 (새 행이 없는 재시도는 어느 쪽이든 제목을 건드리지 않는다).
 */
export const claudeAppChatSaveRequestSchema = z.strictObject({
  bridge_id: z.uuid(),
  session_ref: externalSessionRefSchema,
  title: claudeAppChatTitleSchema.nullable().optional(),
  messages: z
    .array(claudeAppChatMessageSchema)
    .min(1)
    .max(CLAUDE_APP_CHAT_MAX_BATCH)
    .refine((rows) => new Set(rows.map((row) => row.mac_ref)).size === rows.length, { message: "duplicate mac_ref" }),
});
export type ClaudeAppChatSaveRequest = z.infer<typeof claudeAppChatSaveRequestSchema>;
/** chat_id는 사용자 글 없이 답 글만 온 묶음(채팅이 없고 만들지 않음)일 때 null이다. existing = 이미 저장된 행, orphan = 풀리지 않은 답 글 */
export const claudeAppChatSaveResponseSchema = z.strictObject({
  chat_id: z.guid().nullable(),
  saved: z.number().int().min(0),
  existing: z.number().int().min(0),
  orphan: z.number().int().min(0),
});
export type ClaudeAppChatSaveResponse = z.infer<typeof claudeAppChatSaveResponseSchema>;

/**
 * GET /api/v2/claude-app-chats/status — Mac이 글을 보내기 전에 저장이 켜졌는지 묻는다. 꺼짐 · 명단 밖은 404 (Mac은 404면 글을 서버로 한 바이트도 보내지 않는다).
 * max_batch = 한 번에 올릴 수 있는 행 수, max_bytes = 요청 본문 상한(바이트, JSON 이스케이프 포함)
 */
export const claudeAppChatStatusResponseSchema = z.strictObject({
  save: z.literal(true),
  max_batch: z.literal(CLAUDE_APP_CHAT_MAX_BATCH),
  max_bytes: z.literal(CLAUDE_APP_CHAT_MAX_BYTES),
});
export type ClaudeAppChatStatusResponse = z.infer<typeof claudeAppChatStatusResponseSchema>;

/**
 * POST /api/v2/external-sessions/claude-app-sent — 보내기 결과 지표 claude_app_message_sent (글 0, 저장 플래그와 무관). 코드만이다.
 * received의 uploaded: false = Mac이 올리기를 포기했다(10분 재시도 끝에 버림) → 저장이 켜져 있어도 이 지표로 센다 (저장 함수가 못 센 받은 글). 생략 · true는 저장이 켜져 있으면 세지 않는다
 */
export const CLAUDE_APP_SENT_REASONS = ["session_closed", "not_received", "bypass", "two_writers", "relay_failed"] as const;
export const claudeAppSentRequestSchema = z.discriminatedUnion("result", [
  z.strictObject({ result: z.literal("received"), uploaded: z.boolean().optional() }),
  z.strictObject({ result: z.literal("not_sent"), reason: z.enum(CLAUDE_APP_SENT_REASONS).optional() }),
]);
export type ClaudeAppSentRequest = z.infer<typeof claudeAppSentRequestSchema>;
