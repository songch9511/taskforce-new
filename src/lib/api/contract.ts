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

export const apiErrorCodeSchema = z.enum(["unauthorized", "invalid_request", "rate_limited", "internal_error"]);

export const apiErrorSchema = z.object({
  error: z.object({ code: apiErrorCodeSchema, message: z.string() }),
});
export type ApiError = z.infer<typeof apiErrorSchema>;
