import { describe, expect, it } from "vitest";
import { z } from "zod";

import type { JsonCompletionRequest } from "@/lib/ai/llm";
import { PLAN_PROMPT_VERSION } from "@/lib/ai/prompts/plan";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { buildExecutionContext } from "./context";
import { nextStepSchema, planModelResponseSchema, planNextStep, type PlanInput } from "./plan";

const context = buildExecutionContext({
  action: { title: "견적 회신", status: "open", owner: "me", due_date: null, counterpart: "박서준" },
  sources: [
    { id: "m", kind: "email", title: "견적 문의", occurredAt: new Date("2026-10-01T04:00:00Z"), provider: "gmail", purgeReason: null, text: "영상 2편 견적 부탁드립니다." },
    { id: "s", kind: "message", title: "#제작팀", occurredAt: new Date("2026-10-01T05:00:00Z"), provider: "slack", purgeReason: null, text: "내부 단가는 편당 500만 원" },
  ],
  evidence: [
    { sourceId: "m", quote: "영상 2편 견적 부탁드립니다." },
    { sourceId: "s", quote: "내부 단가는 편당 500만 원" },
  ],
});

const input: PlanInput = {
  request: "견적 회신 메일 초안 써 줘",
  now: new Date("2026-10-02T01:00:00Z"),
  user: { name: "김도윤" },
  context,
  history: [{ kind: "draft", status: "failed", brief: "견적 회신 메일", title: null }],
};

/** 받은 요청을 남기고 data를 그대로 돌려주는 가짜 LLM */
function fake(data: unknown, attempts = [{ generationId: "gen-1", model: "m", usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.0004 } }]) {
  const requests: JsonCompletionRequest<z.ZodType>[] = [];
  const complete = (async (request: JsonCompletionRequest<z.ZodType>) => {
    requests.push(request);
    return { data: request.schema.parse(data), model: "m", usage: attempts.at(-1)?.usage, attempts };
  }) as CompleteJson;
  return { complete, requests };
}

describe("planNextStep", () => {
  it("요청 · history · Slack을 뺀 자료를 보내고, 고른 단계와 원가 기록을 돌려준다", async () => {
    const { complete, requests } = fake({ reason: "초안 조각이 남음", step: { kind: "draft", brief: "박서준님께 견적 회신 메일" } });
    const result = await planNextStep(input, complete);
    expect(result).toMatchObject({
      step: { kind: "draft", brief: "박서준님께 견적 회신 메일" },
      reason: "초안 조각이 남음",
      model: "m",
      promptVersion: PLAN_PROMPT_VERSION,
      reasoningLimited: false,
    });
    expect(result.attempts).toEqual([{ generationId: "gen-1", model: "m", usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.0004 } }]);
    expect(requests[0].schemaName).toBe("next_step");
    expect(requests[0].user).toContain("견적 회신 메일 초안 써 줘");
    expect(requests[0].user).toContain('"status":"failed"');
    expect(requests[0].user).not.toContain("500만");
  });

  it("다른 단계 종류도 그대로 돌려준다", async () => {
    for (const step of [{ kind: "needs_connection", capability: "send_email" }, { kind: "ask_user", question: "금액은 얼마인가요?" }, { kind: "done" }]) {
      const { complete } = fake({ reason: "r", step });
      expect((await planNextStep(input, complete)).step).toEqual(step);
    }
  });

  it("attempts를 주지 않는 LLM(테스트 가짜 등)이면 빈 기록", async () => {
    const complete = (async (request: JsonCompletionRequest<z.ZodType>) => ({ data: request.schema.parse({ reason: "r", step: { kind: "done" } }), model: "m" })) as CompleteJson;
    expect((await planNextStep(input, complete)).attempts).toEqual([]);
  });
});

describe("다음 단계 스키마", () => {
  it("단계 종류마다 필요한 인자만 받는다", () => {
    expect(nextStepSchema.safeParse({ kind: "draft" }).success).toBe(false);
    expect(nextStepSchema.safeParse({ kind: "needs_connection", capability: "fax" }).success).toBe(false);
    expect(nextStepSchema.safeParse({ kind: "search_sources" }).success).toBe(false);
    expect(nextStepSchema.safeParse({ kind: "done" }).success).toBe(true);
  });

  it("구조화 출력용 JSON 스키마: 최상위 객체 안의 union, 변형마다 필수 필드 · 추가 필드 금지 (strict)", () => {
    const schema = z.toJSONSchema(planModelResponseSchema) as unknown as {
      type: string;
      required: string[];
      additionalProperties: boolean;
      properties: { step: { oneOf: { required: string[]; additionalProperties: boolean; properties: { kind: { const: string } } }[] } };
    };
    expect(schema).toMatchObject({ type: "object", required: ["reason", "step"], additionalProperties: false });
    const variants = schema.properties.step.oneOf;
    expect(variants.map((v) => v.properties.kind.const)).toEqual(["draft", "needs_connection", "ask_user", "done"]);
    for (const v of variants) {
      expect(v.additionalProperties).toBe(false);
      expect(v.required).toContain("kind");
    }
  });
});
