import { z } from "zod";

import { sourceKindSchema } from "@/lib/pipeline/extract";
import { MISS_STAGES } from "@/lib/pipeline/missing";

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

// GET /api/v1/now
export const nowResponseSchema = z.object({
  now: z.array(rankedActionSchema),
  confirmations: z.array(rankedActionSchema),
  /** 이번 주에 물어볼 주간 질문. 물을 때가 아니면 null (필드는 항상 있다) */
  weekly_check: weeklyCheckPromptSchema.nullable(),
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

/** 파이프라인의 어느 단계에서 빠졌나: 처리 실패 / 추출 안 됨(검증 탈락 포함) / Jev 기각 / 다른 Action에 합쳐짐 */
export const missStageSchema = z.enum(MISS_STAGES);

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
// 값은 사용자 Claim(origin user)으로 정하고 user_created 이벤트를 남긴다 (추출이 놓친 신호, 지표 4). 확인 요청은 만들지 않는다.
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

/** 연결에 성공했을 때의 결과. connected_empty: 고른 페이지가 없음, connected_no_meetings: 회의록 DB가 빠짐 (Notion) */
export const connectedStatusSchema = z.enum(["connected", "connected_empty", "connected_no_meetings"]);
export type ConnectedStatusValue = z.infer<typeof connectedStatusSchema>;

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

export const apiErrorCodeSchema = z.enum(["unauthorized", "invalid_request", "not_found", "conflict", "rate_limited", "internal_error"]);

export const apiErrorSchema = z.object({
  error: z.object({ code: apiErrorCodeSchema, message: z.string() }),
});
export type ApiError = z.infer<typeof apiErrorSchema>;
