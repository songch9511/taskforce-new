import { z } from "zod";

import { sourceKindSchema } from "@/lib/pipeline/extract";

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

// GET /api/v1/now
export const nowResponseSchema = z.object({
  now: z.array(rankedActionSchema),
  confirmations: z.array(rankedActionSchema),
});
export type NowResponse = z.infer<typeof nowResponseSchema>;

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

// POST /api/v1/metric-events
export const metricEventRequestSchema = z.object({
  type: z.enum(["app_opened", "handoff_used"]),
  action_id: z.uuid().optional(),
});

// POST /api/v1/devices — 알림용 기기 토큰 (APNs)
export const deviceRequestSchema = z.object({
  token: z.string().regex(/^[0-9a-fA-F]{32,200}$/, "APNs 기기 토큰(16진수)"),
  platform: z.enum(["ios", "macos"]),
  environment: z.enum(["sandbox", "production"]).default("production"),
  app_version: z.string().max(40).optional(),
});

export const apiErrorCodeSchema = z.enum(["unauthorized", "invalid_request", "not_found", "conflict", "rate_limited", "internal_error"]);

export const apiErrorSchema = z.object({
  error: z.object({ code: apiErrorCodeSchema, message: z.string() }),
});
export type ApiError = z.infer<typeof apiErrorSchema>;
