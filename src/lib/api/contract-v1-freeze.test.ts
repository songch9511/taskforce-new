import { createHash } from "node:crypto";

import { describe, expect, it } from "vitest";
import { z } from "zod";

import * as contract from "./contract";

// /api/v1 계약 동결 (0.2.0 구현 계획 8장): 기존 Mac 베타(0.1.0-beta.25–32)가 읽는 v1 요청 · 응답의 모양 · literal · enum을 바꾸지 않는다.
// 아래 지문은 origin/main 0202e1c의 contract.ts에서 뽑았다: zod 스키마는 JSON Schema(입력 · 출력 둘 다)의 sha256 앞 16자,
// 상수는 값의 sha256 앞 16자. 새 export(v2)는 이 목록에 넣지 않는다.
// 지문이 바뀌면 v1을 고친 것이다: 새 값 · 새 기능은 v2 스키마로 낸다. 승인된 optional 필드 추가처럼 v1을 일부러 바꿀 때만
// 지문을 다시 뽑아(아래 fingerprint를 같은 방식으로) 이 표를 고치고, PR에 그 이유를 적는다.
const FROZEN_V1: Record<string, string> = {
  ACTION_NOTES_MAX_UTF16: "39e5b4830d4d9c14",
  MAX_SOURCE_TEXT: "b552e632666bbf61",
  NOW_SECTION_LIMITS: "b317b0d6c662cff4",
  SOURCE_FAILURE_CODES: "bfb2dbb10182f35d",
  actionNotesRequestSchema: "c36857d6d53e2fcf",
  actionNotesResponseSchema: "3bd45b2f8d95f740",
  actionOwnerSchema: "9537d47b68faad14",
  actionProgressRequestSchema: "9b8447d90599a0f0",
  actionProgressStateSchema: "540cefaf343e98bc",
  actionResponseSchema: "a03ba97e4f97ac5a",
  actionStatusSchema: "d7277ad227dafa65",
  actionSummarySchema: "6459b6935f49eecd",
  aiSpendSummarySchema: "e0a71e97aec5d81a",
  apiErrorCodeSchema: "e4c13c5ab18fa692",
  apiErrorSchema: "fa7dd7c53d45ba53",
  artifactSchema: "af3132d2159cfb1b",
  askCitationSchema: "228d327af22a6878",
  askRequestSchema: "ae07b0791598e8f7",
  askResponseSchema: "dce651938e7e360e",
  billingCheckoutRequestSchema: "b12cb982c332315b",
  billingStatusSchema: "bcc0542dbdaae3ca",
  connectProviderSchema: "2efeb5301ab91513",
  connectedStatusSchema: "2c8fdd8c147d1f54",
  connectionAppCallbackErrorSchema: "fb9f216ad77169a7",
  connectionCallbackStatusSchema: "a566426be4effea2",
  connectionCompleteRequestSchema: "3cefbb62372a278f",
  connectionCompleteResponseSchema: "e7bceb36093bd62d",
  connectionRequestSchema: "a7a05ea31d6991c7",
  connectionSettingsSchema: "0b36dd07200fca78",
  connectionStartRequestSchema: "5487a4fa8c792184",
  connectionStartResponseSchema: "428e9c048c74206a",
  connectionStatusSchema: "02ef60dd38a15db1",
  connectionSummarySchema: "d036e0a02a8a16fc",
  consentRequestSchema: "6f1705d40580ac92",
  createActionRequestSchema: "99775d877b6ca7ea",
  createActionResponseSchema: "d10b89c847b45a84",
  createRunRequestSchema: "f3500d3048f2f08a",
  createRunResponseSchema: "10c4f739d682f65a",
  createSourceRequestSchema: "4905f4f3ad335aa5",
  createSourceResponseSchema: "43996e9006b72134",
  creditsResponseSchema: "3dd12691b38de48b",
  dataSourceSettingSchema: "bb80ee4bf6e4d820",
  dataSourceSummarySchema: "b8c7eb22bde76f7e",
  dataSourcesResponseSchema: "100875b2531af618",
  deleteAccountRequestSchema: "a7a222cb728a0356",
  deleteAccountResponseSchema: "1350f5df862cdacc",
  deviceRequestSchema: "a923a0d2c8289ed6",
  editActionRequestSchema: "d8069a89b65f5126",
  failedSourcesSchema: "61eb1cb0330c6501",
  handoffAssessmentSchema: "bb344b3c639f48d3",
  handoffRequestSchema: "a2b580b4c6d67d2f",
  handoffResponseSchema: "e460209a3659ede4",
  legalResponseSchema: "e40098ad9289dba0",
  metricEventRequestSchema: "650d83922f3424bf",
  missStageSchema: "bdc4459aff054642",
  missingReportRequestSchema: "7f9eef0dc624f3a3",
  missingReportResponseSchema: "d0dd48251040a6b6",
  nowResponseSchema: "cc16c6ff667d19cb",
  participantsSchema: "6bde8626ca0cfddf",
  personSchema: "d26009e8c71f61bd",
  policyNoticeSchema: "b19e7a32a3bb3cce",
  policyVersionSchema: "f1f39c3abbd27459",
  profileInputSchema: "51677464657cc46d",
  profileSchema: "31423f4e64d125a9",
  rankedActionSchema: "490be8271fc922c3",
  requestableProviderSchema: "131216f2d35e3dcc",
  runHoldReasonSchema: "e9ce09c0c2b238ff",
  runOutcomeSchema: "419ae7540c10a55d",
  runStateSchema: "e21297c888972767",
  runSummarySchema: "afa9bb8100a038fa",
  saveDataSourceRequestSchema: "5df24b63cc2e7b2c",
  sectionLimitsSchema: "c9c24136a2a4334a",
  sourceFailureCodeSchema: "2e3dec3dfe0348b1",
  sourceKindSchema: "d478ca3046298940",
  stepReceiptSchema: "1d248da30c51aba9",
  stepSummarySchema: "136416cc5a158604",
  stopRunResponseSchema: "10c4f739d682f65a",
  taskPropertyMapSchema: "1ff1a5a6ecd6e674",
  taskStatusSchema: "d7277ad227dafa65",
  weeklyCheckAnswerSchema: "d8afc640522c723b",
  weeklyCheckPromptSchema: "c152fa7047f238f2",
  weeklyCheckRequestSchema: "7dbb6b240b323270",
};

// 지문은 JSON Schema로 본 모양 · literal · enum만 고정한다. .refine · .transform · .superRefine 안의 규칙 변화는 지문에 보이지 않는다
// (그 규칙은 아래 v1 본문 왕복 테스트와 각 route 테스트가 지킨다).
function fingerprint(value: unknown): string {
  const shape =
    value instanceof z.ZodType
      ? {
          input: z.toJSONSchema(value, { unrepresentable: "any", io: "input" }),
          output: z.toJSONSchema(value, { unrepresentable: "any", io: "output" }),
        }
      : value;
  return createHash("sha256").update(JSON.stringify(shape)).digest("hex").slice(0, 16);
}

const exported = contract as Record<string, unknown>;

describe("v1 계약 동결", () => {
  it.each(Object.keys(FROZEN_V1))("%s: 모양 · literal · enum이 origin/main과 같다", (name) => {
    expect(exported[name], `${name}가 사라졌다`).toBeDefined();
    expect(fingerprint(exported[name]), `${name}이 바뀌었다 — v1은 동결이다. 새 값은 v2 스키마로`).toBe(FROZEN_V1[name]);
  });

  it("지문은 값이 바뀌면 달라진다 (검사가 실제로 무언가를 본다)", () => {
    expect(fingerprint(z.enum(["monthly", "annual"]))).not.toBe(fingerprint(z.enum(["monthly", "annual", "lifetime"])));
    expect(fingerprint(z.object({ a: z.literal(9.99) }))).not.toBe(fingerprint(z.object({ a: z.literal(12.99) })));
    expect(fingerprint(z.object({ a: z.string() }))).not.toBe(fingerprint(z.object({ a: z.string().optional() })));
  });
});

// 기존 앱 · 서버가 주고받던 v1 본문은 그대로 파싱된다 (값이 바뀌지 않는다)
describe("v1 본문이 그대로 파싱된다", () => {
  const ACTION = "11111111-1111-4111-8111-111111111111";
  const RUN = "22222222-2222-4222-8222-222222222222";
  const SOURCE = "33333333-3333-4333-8333-333333333333";

  it.each<[string, z.ZodType, unknown]>([
    [
      "GET /api/v1/now",
      contract.nowResponseSchema,
      {
        now: [
          {
            id: ACTION,
            title: "제안서 발송",
            owner: "me",
            status: "open",
            due_date: "2026-10-10",
            counterpart: "지훈",
            needs_confirmation: false,
            confirm_reasons: [],
            started_at: null,
            last_activity_at: "2026-10-08T01:00:00.123456+00:00",
            score: 3.5,
            reasons: ["due_soon", "external"],
            days_until_due: 2,
            changed: true,
          },
        ],
        confirmations: [],
        weekly_check: null,
        failed_sources: { count: 0, latest_at: null, reason: null },
        section_limits: { review: 2, in_progress: 5, to_do: 5 },
      },
    ],
    ["POST /api/v1/sources 요청", contract.createSourceRequestSchema, { kind: "meeting", text: "금요일까지 보내드릴게요", occurred_at: "2026-09-22T10:00:00+09:00" }],
    ["POST /api/v1/sources 응답", contract.createSourceResponseSchema, { source_id: SOURCE, status: "pending" }],
    ["POST /api/v1/ask 요청", contract.askRequestSchema, { question: "오늘 남은 일이 뭐야" }],
    [
      "POST /api/v1/ask 응답",
      contract.askResponseSchema,
      {
        answer: "제안서 발송이 남았어요.",
        unknown: false,
        citations: [
          { action_id: ACTION, source_id: SOURCE, source_title: "주간 회의", source_kind: "meeting", occurred_at: "2026-10-07T01:00:00Z", external_url: null, quote: "금요일까지" },
        ],
      },
    ],
    [
      "run",
      contract.runSummarySchema,
      { id: RUN, action_id: ACTION, goal: "draft", state: "running", hold_reason: "credit", outcome: null, budget_credits: 40, created_at: "2026-10-04T05:00:00Z", stopped_at: null },
    ],
    ["POST /api/v1/billing/checkout", contract.billingCheckoutRequestSchema, { plan: "annual", terms_version: "2026-10-08" }],
    [
      "GET /api/v1/billing",
      contract.billingStatusSchema,
      {
        status: "trialing",
        plan: null,
        trial_ends_at: "2026-10-15T00:00:00Z",
        current_period_ends_at: null,
        can_use_ai: true,
        can_checkout: true,
        monthly_price_usd: 9.99,
        annual_price_usd: 101.9,
        ai_allowance: null,
        allowance_resets_at: null,
      },
    ],
    [
      // 구현 계획 8장: lifetime 계정은 v1에서 plan null · status active · can_use_ai true · can_checkout false로 보인다
      "GET /api/v1/billing (lifetime 계정의 v1 매핑)",
      contract.billingStatusSchema,
      {
        status: "active",
        plan: null,
        trial_ends_at: null,
        current_period_ends_at: null,
        can_use_ai: true,
        can_checkout: false,
        monthly_price_usd: 9.99,
        annual_price_usd: 101.9,
        ai_allowance: null,
        allowance_resets_at: null,
      },
    ],
    ["오류", contract.apiErrorSchema, { error: { code: "billing_required", message: "Subscription required" } }],
  ])("%s", (_label, schema, body) => {
    expect(schema.parse(body)).toEqual(body);
  });

  it("v1은 새 값을 받지 않는다 (lifetime · 다른 약관 판은 v2에서만)", () => {
    expect(contract.billingCheckoutRequestSchema.safeParse({ plan: "lifetime", terms_version: "2026-10-08" }).success).toBe(false);
    expect(contract.billingCheckoutRequestSchema.safeParse({ plan: "monthly", terms_version: "2026-10-09" }).success).toBe(false);
    expect(contract.askRequestSchema.safeParse({ question: "a".repeat(501) }).success).toBe(false);
  });
});
