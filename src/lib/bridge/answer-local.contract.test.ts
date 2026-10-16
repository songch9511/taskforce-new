import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  BRIDGE_ANSWER_LOCAL_MAX_BYTES,
  apiErrorSchema,
  bridgeV1AnswerLocalRequestSchema,
  bridgeV1AnswerLocalResponseSchema,
} from "@/lib/api/contract";

// OA F2 U1: 요청 본문에는 값을 담을 자리가 없다 (구조 증명) + D4b-m(Swift DTO)이 읽는 기준 JSON.
// POST /api/v1/bridge/answer-local { bridge_id, agent_task_id, request_digest } — request_digest = provider_request_id의 UTF-8 SHA-256 소문자 16진 64자.
const BRIDGE_ID = "11111111-1111-4111-8111-111111111111";
const TASK_ID = "33333333-3333-4333-8333-333333333333";
const STEP_ID = "44444444-4444-4444-8444-444444444444";
const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");

/** Swift 시험이 같은 값을 쓴다: 알려진 provider_request_id와 그 digest (둘째는 UTF-8 멀티바이트) */
export const ANSWER_LOCAL_REQUEST_JSON = {
  known_ids: [
    { provider_request_id: "toolu_01F2SecretLocalAnswer", request_digest: "0e558779236c0c8b12aad0b75364ec4a080b58bba3e5fb8795316522a2d08c4e" },
    { provider_request_id: "가나 ✓ 日本", request_digest: "f724923ecc39a80fbdc26c6afd41817f598f99a9d94cb7177b29c178cbdc7740" },
  ],
  request: { bridge_id: BRIDGE_ID, agent_task_id: TASK_ID, request_digest: "0e558779236c0c8b12aad0b75364ec4a080b58bba3e5fb8795316522a2d08c4e" },
  responses: {
    answered: { status: "answered", step_id: STEP_ID },
    duplicate: { status: "duplicate", step_id: STEP_ID },
    stale_question_closed: { status: "stale", reason: "question_closed" },
    stale_not_live: { status: "stale", reason: "not_live" },
    stale_not_secret: { status: "stale", reason: "not_secret" },
  },
  errors: {
    bad_request: { status: 400, body: { error: { code: "invalid_request", message: "Invalid local answer request." } } },
    unauthorized: { status: 401, body: { error: { code: "unauthorized", message: "로그인이 필요합니다." } } },
    revoked: { status: 403, body: { error: { code: "unauthorized", message: "Bridge revoked." } } },
    not_found: { status: 404, body: { error: { code: "not_found", message: "Local answer target not found." } } },
    conflict: { status: 409, body: { error: { code: "conflict", message: "Busy, retry." } } },
    rate_limited: { status: 429, body: { error: { code: "rate_limited", message: "Please try again later." } } },
  },
} as const;

describe("U1 요청 스키마: 값을 담을 자리가 없다", () => {
  const json = z.toJSONSchema(bridgeV1AnswerLocalRequestSchema) as { type: string; additionalProperties: unknown; required: string[]; properties: Record<string, Record<string, unknown>> };
  const UUID_PATTERN = /^\^\(\[0-9a-fA-F\]\{8\}-/;

  it("strict 객체이고 키는 정확히 셋, 모두 필수", () => {
    expect(json.type).toBe("object");
    expect(json.additionalProperties).toBe(false);
    expect(Object.keys(json.properties).sort()).toEqual(["agent_task_id", "bridge_id", "request_digest"]);
    expect([...json.required].sort()).toEqual(["agent_task_id", "bridge_id", "request_digest"]);
  });

  it("모든 잎이 UUID 모양이거나 고정 길이 소문자 16진이다: 제약 없는 문자열 잎이 없다", () => {
    for (const [key, leaf] of Object.entries(json.properties)) {
      expect(leaf.type, key).toBe("string");
      const uuid = leaf.format === "uuid" && UUID_PATTERN.test(String(leaf.pattern));
      const hex = leaf.pattern === "^[0-9a-f]{64}$";
      expect(uuid || hex, `${key} must be uuid-shaped or 64 lowercase hex`).toBe(true);
      expect(leaf.maxLength, key).toBeUndefined();
    }
    expect(json.properties.request_digest.pattern).toBe("^[0-9a-f]{64}$");
  });

  it("글을 실을 수 있는 키 · 모양을 거절한다 (answers · value · secret · provider_request_id · text · 중첩)", () => {
    const ok = ANSWER_LOCAL_REQUEST_JSON.request;
    expect(bridgeV1AnswerLocalRequestSchema.safeParse(ok).success).toBe(true);
    for (const key of ["answers", "value", "secret", "answer", "answer_text", "provider_request_id", "text", "extra"]) {
      expect(bridgeV1AnswerLocalRequestSchema.safeParse({ ...ok, [key]: "DO_NOT_STORE_SECRET_F2" }).success, key).toBe(false);
      expect(bridgeV1AnswerLocalRequestSchema.safeParse({ ...ok, [key]: { a: "DO_NOT_STORE_SECRET_F2" } }).success, `${key} object`).toBe(false);
    }
    for (const digest of ["", "DO_NOT_STORE_SECRET_F2", sha256("x").toUpperCase(), sha256("x").slice(1), `${sha256("x")}0`, `${sha256("x")}\n`, ` ${sha256("x")}`, "g".repeat(64)]) {
      expect(bridgeV1AnswerLocalRequestSchema.safeParse({ ...ok, request_digest: digest }).success, JSON.stringify(digest)).toBe(false);
    }
    for (const id of ["", "not-a-uuid", "DO_NOT_STORE_SECRET_F2", `${BRIDGE_ID} `]) {
      expect(bridgeV1AnswerLocalRequestSchema.safeParse({ ...ok, bridge_id: id }).success, JSON.stringify(id)).toBe(false);
      expect(bridgeV1AnswerLocalRequestSchema.safeParse({ ...ok, agent_task_id: id }).success, JSON.stringify(id)).toBe(false);
    }
  });

  it("정상 본문은 상한보다 훨씬 작다 (512바이트)", () => {
    expect(BRIDGE_ANSWER_LOCAL_MAX_BYTES).toBe(512);
    expect(Buffer.byteLength(JSON.stringify(ANSWER_LOCAL_REQUEST_JSON.request))).toBeLessThan(BRIDGE_ANSWER_LOCAL_MAX_BYTES / 2);
  });
});

describe("U1 응답 스키마", () => {
  it("answered · duplicate(step_id)와 stale(이유 셋)의 strict 합집합", () => {
    for (const [name, response] of Object.entries(ANSWER_LOCAL_REQUEST_JSON.responses)) {
      expect(bridgeV1AnswerLocalResponseSchema.parse(response), name).toEqual(response);
    }
    for (const bad of [
      { status: "answered" }, { status: "duplicate", step_id: "x" }, { status: "stale" }, { status: "stale", reason: "other" },
      { status: "stale", reason: "not_live", step_id: STEP_ID }, { status: "answered", step_id: STEP_ID, extra: 1 },
      { status: "not_found" }, { status: "invalid" }, { status: "busy" },
    ]) expect(bridgeV1AnswerLocalResponseSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
  });
});

describe("U1 Swift 기준 JSON", () => {
  it("요청이 스키마를 통과하고, 알려진 id의 digest를 node:crypto로 다시 계산해도 같다", () => {
    expect(bridgeV1AnswerLocalRequestSchema.parse(ANSWER_LOCAL_REQUEST_JSON.request)).toEqual(ANSWER_LOCAL_REQUEST_JSON.request);
    for (const known of ANSWER_LOCAL_REQUEST_JSON.known_ids) expect(sha256(known.provider_request_id), known.provider_request_id).toBe(known.request_digest);
    expect(ANSWER_LOCAL_REQUEST_JSON.request.request_digest).toBe(ANSWER_LOCAL_REQUEST_JSON.known_ids[0].request_digest);
    // 요청 본문에는 알려진 provider_request_id가 없다
    for (const known of ANSWER_LOCAL_REQUEST_JSON.known_ids) expect(JSON.stringify(ANSWER_LOCAL_REQUEST_JSON.request)).not.toContain(known.provider_request_id);
  });

  it("오류 본문은 v1 오류 코드만 쓴다 (새 코드 0)", () => {
    for (const [name, error] of Object.entries(ANSWER_LOCAL_REQUEST_JSON.errors)) {
      expect(apiErrorSchema.parse(error.body), name).toEqual(error.body);
    }
  });
});
