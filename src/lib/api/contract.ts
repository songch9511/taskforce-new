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

// GET · PUT /api/v1/profile: 원문에서 사용자를 알아보는 데 쓰는 정보
export const profileSchema = z.object({
  /** 원문에서 사용자를 부르는 기본 이름 */
  display_name: z.string().trim().min(1).max(50).nullable(),
  /** 다른 호칭 · 영문 이름 · 받아쓰기가 자주 틀리는 이름 */
  aliases: z.array(z.string().trim().min(1).max(50)).max(20),
  /** 사용자의 이메일 주소 (로그인 주소 외에 회사 · 개인 주소) */
  emails: z.array(z.email().max(320)).max(10),
});
export type Profile = z.infer<typeof profileSchema>;

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

// PATCH · DELETE · confirm · start 응답
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
  /** 사용자가 확인한 시각. 확인 전에는 할 일로 처리하지 않는다 */
  confirmedAt: z.string().optional(),
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
  .omit({ confirmedAt: true, backfilledAt: true, seenAt: true, title: true })
  .refine((s) => s.role !== "tasks" || s.props, { message: "할 일 DB에는 속성 매핑이 필요합니다.", path: ["props"] });

// POST /api/v1/devices — 알림용 기기 토큰 (APNs)
export const deviceRequestSchema = z.object({
  token: z.string().regex(/^[0-9a-fA-F]{32,200}$/, "APNs 기기 토큰(16진수)"),
  platform: z.enum(["ios", "macos"]),
  environment: z.enum(["sandbox", "production"]).default("production"),
  app_version: z.string().max(40).optional(),
});

// DELETE /api/v1/account — 계정 삭제 (App Store 5.1.1(v)). 본문 없음.
// 로그인 계정을 지우면 원문 · 할 일 · Claim · 근거 · 변경 이력 · 지표 · 프로필 · 연결(토큰) · 기기가 DB에서 함께 지워진다 (on delete cascade).
// 되돌릴 수 없다. 이미 지워진 계정이면 그대로 성공으로 답한다 (재시도해도 안전).
export const deleteAccountResponseSchema = z.object({ deleted: z.literal(true) });
export type DeleteAccountResponse = z.infer<typeof deleteAccountResponseSchema>;

export const apiErrorCodeSchema = z.enum(["unauthorized", "invalid_request", "not_found", "conflict", "rate_limited", "internal_error"]);

export const apiErrorSchema = z.object({
  error: z.object({ code: apiErrorCodeSchema, message: z.string() }),
});
export type ApiError = z.infer<typeof apiErrorSchema>;
