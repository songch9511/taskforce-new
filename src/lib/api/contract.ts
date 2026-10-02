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
});

// 주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?" (지표 5). week_start: 그 주 월요일 (한국 시간)
export const weeklyCheckPromptSchema = z.object({ week_start: z.iso.date() });

/**
 * 원문 처리 실패 까닭 (sources.processing_error_code, 마이그레이션 20261020000000).
 * ai_quota: AI 공급자가 한도 · 잔액으로 거절, ai_timeout: AI 응답 시간 초과, ai_output: AI 응답 형식이 깨짐,
 * consent: 처리 도중 외부 AI 처리 동의 철회, expired: 하루가 지나도록 멈춰 다시 처리하지 않고 닫음, internal: 그 밖.
 */
export const SOURCE_FAILURE_CODES = ["ai_quota", "ai_timeout", "ai_output", "consent", "expired", "internal"] as const;
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

// GET /api/v1/now
export const nowResponseSchema = z.object({
  now: z.array(rankedActionSchema),
  confirmations: z.array(rankedActionSchema),
  /** 이번 주에 물어볼 주간 질문. 물을 때가 아니면 null (필드는 항상 있다) */
  weekly_check: weeklyCheckPromptSchema.nullable(),
  /** 처리에 실패한 원문 (필드는 항상 있다. 못 읽으면 count 0으로 두고 목록은 그대로 돌려준다). 예전 서버에는 없다 */
  failed_sources: failedSourcesSchema,
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

// PATCH · DELETE · confirm · start · progress 응답
export const actionResponseSchema = z.object({ action: actionSummarySchema });

// POST /api/v1/actions/:id/handoff — "AI에게 넘기기": 맥락 · 근거 인용을 묶은 마크다운. 서버가 handoff_used 지표를 남긴다.
export const handoffResponseSchema = z.object({
  action_id: z.uuid(),
  title: z.string(),
  /** 그대로 복사해 AI 도구에 붙여 넣는 문서 */
  markdown: z.string(),
});
export type HandoffResponse = z.infer<typeof handoffResponseSchema>;

// POST /api/v1/metric-events — 앱이 직접 남기는 지표. action_started · handoff_used는 해당 API가 서버에서 남긴다 (중복 집계 방지).
export const metricEventRequestSchema = z.object({
  type: z.enum(["app_opened"]),
  action_id: z.uuid().optional(),
});

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
export const deleteAccountResponseSchema = z.object({ deleted: z.literal(true) });
export type DeleteAccountResponse = z.infer<typeof deleteAccountResponseSchema>;

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
/** 실행기가 막힌 이유 (execution_runs.hold_reason): 차단 스위치 · 도구 / 실행 주체 / 보내는 연결 없음 / 크레딧 부족. 풀리면 sweep이 이어 간다 */
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

// GET /api/v1/credits — 내 크레딧 합계 (서버가 계정 행에서 계산). available = 지급 - 예약 - 사용, reserved = 아직 정산 · 해제하지 않은 예약.
// rate_version: 지금 요율 (c3-v1: 1 크레딧 = $0.001). 지급 기록이 없으면 0 · 0
export const creditsResponseSchema = z.object({
  available: z.number().int().nonnegative(),
  reserved: z.number().int().nonnegative(),
  rate_version: z.string().nullable(),
});
export type CreditsResponse = z.infer<typeof creditsResponseSchema>;

export const apiErrorCodeSchema = z.enum(["unauthorized", "invalid_request", "not_found", "conflict", "rate_limited", "internal_error"]);

export const apiErrorSchema = z.object({
  error: z.object({ code: apiErrorCodeSchema, message: z.string() }),
});
export type ApiError = z.infer<typeof apiErrorSchema>;
