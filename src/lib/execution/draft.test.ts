import { describe, expect, it } from "vitest";
import type { z } from "zod";

import type { JsonCompletionRequest } from "@/lib/ai/llm";
import { DRAFT_PROMPT_VERSION } from "@/lib/ai/prompts/draft";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { buildExecutionContext } from "./context";
import { draftModelResponseSchema, writeDraft } from "./draft";

const context = buildExecutionContext({
  action: { title: "일정 변경 회신", status: "open", owner: "me", due_date: "2026-10-05", counterpart: "최유나" },
  sources: [
    {
      id: "m",
      kind: "email",
      title: "일정 변경 요청",
      occurredAt: new Date("2026-10-01T00:40:00Z"),
      provider: "gmail",
      purgeReason: null,
      text: "납품일을 10월 16일로 미룰 수 있을까요?",
      participants: { from: { name: "최유나", email: "yuna@example.com" } },
    },
    { id: "s", kind: "message", title: "#제작팀", occurredAt: new Date("2026-10-01T01:15:00Z"), provider: "slack", purgeReason: null, text: "마진이 18%라 할인은 어렵습니다" },
  ],
  evidence: [
    { sourceId: "m", quote: "납품일을 10월 16일로 미룰 수 있을까요?" },
    { sourceId: "s", quote: "마진이 18%라 할인은 어렵습니다" },
  ],
});

const draft = { title: "Re: 일정 변경 요청", to: ["최유나 <yuna@example.com>"], body: "유나님, 납품일을 10월 16일로 변경하겠습니다.\n김도윤 드림" };

describe("writeDraft", () => {
  it("요청 · 지시 · Slack을 뺀 자료로 초안을 받고 원가 기록을 돌려준다", async () => {
    const requests: JsonCompletionRequest<z.ZodType>[] = [];
    const attempts = [{ generationId: "gen-9", model: "m", usage: { prompt_tokens: 100, completion_tokens: 50, cost: 0.001 } }];
    const complete = (async (request: JsonCompletionRequest<z.ZodType>) => {
      requests.push(request);
      return { data: request.schema.parse(draft), model: "m", usage: attempts[0].usage, attempts, reasoningLimited: true };
    }) as CompleteJson;

    const result = await writeDraft(
      { request: "유나님께 일정 변경 확인 메일 초안 써 줘", brief: "납품일 10월 16일 변경 확인", now: new Date("2026-10-02T01:00:00Z"), user: { name: "김도윤" }, context },
      complete,
    );
    expect(result).toEqual({ draft, model: "m", promptVersion: DRAFT_PROMPT_VERSION, usage: attempts[0].usage, attempts, reasoningLimited: true });
    expect(requests[0].schemaName).toBe("draft");
    expect(requests[0].user).toContain("유나님께 일정 변경 확인 메일 초안 써 줘");
    expect(requests[0].user).toContain("납품일 10월 16일 변경 확인");
    expect(requests[0].user).toContain("yuna@example.com");
    expect(requests[0].user).not.toContain("18%");
    expect(requests[0].user).not.toContain("마진");
  });

  it("지시가 없으면 brief를 null로 보낸다", async () => {
    const requests: JsonCompletionRequest<z.ZodType>[] = [];
    const complete = (async (request: JsonCompletionRequest<z.ZodType>) => {
      requests.push(request);
      return { data: request.schema.parse(draft), model: "m" };
    }) as CompleteJson;
    const result = await writeDraft({ request: "메일 초안 써 줘", brief: null, now: new Date(), user: { name: "김도윤" }, context }, complete);
    expect(requests[0].user).toContain('"brief":null');
    expect(result.attempts).toEqual([]);
  });

  it("받는 사람은 배열, 제목 · 본문은 글이어야 한다", () => {
    expect(draftModelResponseSchema.safeParse({ title: "t", to: "a@example.com", body: "b" }).success).toBe(false);
    expect(draftModelResponseSchema.safeParse({ title: "t", to: [], body: "b" }).success).toBe(true);
  });
});
