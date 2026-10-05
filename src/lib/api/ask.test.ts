import { AiBudgetError } from "@/lib/ai/budget-error";
import { describe, expect, it, vi } from "vitest";

import { ConsentRequiredError } from "@/lib/consent/gate";

import { handleAsk, type AskHandlerDeps } from "./ask";
import { apiErrorSchema, askResponseSchema, type AskResponse } from "./contract";

type User = { id: string };

const ANSWER: AskResponse = {
  answer: "금요일까지 제안서를 보내기로 했어요.",
  unknown: false,
  citations: [
    {
      action_id: "a1",
      source_id: "s1",
      source_title: "주간 회의",
      source_kind: "meeting",
      occurred_at: "2026-09-22T01:00:00.000Z",
      external_url: null,
      quote: "금요일까지 제안서 보내드릴게요",
    },
  ],
};

function setup(options: { user?: User | null; consent?: boolean; retryAt?: Date | null; answer?: () => Promise<AskResponse> } = {}) {
  const asked: string[] = [];
  const deps: AskHandlerDeps<User> = {
    authenticate: async () => (options.user === undefined ? { id: "u1" } : options.user),
    hasConsent: async () => options.consent ?? true,
    rateLimit: async () => options.retryAt ?? null,
    answer: async (_user, question) => {
      asked.push(question);
      return options.answer ? options.answer() : ANSWER;
    },
    now: () => new Date("2026-09-27T01:00:00Z"),
  };
  return { deps, asked };
}

const ask = (body: unknown) => new Request("http://localhost/api/v1/ask", { method: "POST", body: JSON.stringify(body) });

describe("POST /api/v1/ask", () => {
  it("질문을 다듬어 넘기고 답과 인용을 돌려준다", async () => {
    const { deps, asked } = setup();
    const response = await handleAsk(ask({ question: "  제안서 언제까지야? " }), deps);
    expect(response.status).toBe(200);
    expect(askResponseSchema.parse(await response.json())).toEqual(ANSWER);
    expect(asked).toEqual(["제안서 언제까지야?"]);
  });

  it.each([[{}], [{ question: "   " }], [{ question: "a".repeat(501) }]])("잘못된 질문은 400 %#", async (body) => {
    const { deps, asked } = setup();
    expect((await handleAsk(ask(body), deps)).status).toBe(400);
    expect(asked).toEqual([]);
  });

  it("외부 AI 처리 동의 전이면 409이고 모델을 부르지 않는다", async () => {
    const { deps, asked } = setup({ consent: false });
    const response = await handleAsk(ask({ question: "제안서?" }), deps);
    expect(response.status).toBe(409);
    expect(apiErrorSchema.parse(await response.json()).error).toEqual({ code: "conflict", message: "외부 AI 처리 동의가 필요해요." });
    expect(asked).toEqual([]);
  });

  it("횟수 한도에 차면 429와 Retry-After", async () => {
    const { deps, asked } = setup({ retryAt: new Date("2026-09-27T01:05:00Z") });
    const response = await handleAsk(ask({ question: "제안서?" }), deps);
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("300");
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("rate_limited");
    expect(asked).toEqual([]);
  });

  it("로그인하지 않았으면 401", async () => {
    expect((await handleAsk(ask({ question: "제안서?" }), setup({ user: null }).deps)).status).toBe(401);
  });

  it("답을 만들지 못하면 500, 로그에 질문을 남기지 않는다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { deps } = setup({
      answer: async () => {
        throw new Error("OpenRouter 요청 실패 (502)");
      },
    });
    const response = await handleAsk(ask({ question: "비밀 프로젝트 제안서 언제까지?" }), deps);
    expect(response.status).toBe(500);
    expect(log).toHaveBeenCalledWith("물어보기 실패:", "OpenRouter 요청 실패 (502)");
    expect(JSON.stringify(log.mock.calls)).not.toContain("비밀 프로젝트");
    log.mockRestore();
  });

  it("답을 만드는 도중에 동의를 철회하면(모델 호출 직전 확인) 409", async () => {
    const { deps } = setup({
      answer: async () => {
        throw new ConsentRequiredError();
      },
    });
    const response = await handleAsk(ask({ question: "제안서?" }), deps);
    expect(response.status).toBe(409);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("conflict");
  });
});

it("returns a stable exhaustion error without exposing backend details", async () => {
  const { deps } = setup({ answer: async () => { throw new AiBudgetError("ai_budget_exhausted"); } });
  const response = await handleAsk(ask({ question: "test" }), deps);
  expect(response.status).toBe(403);
  expect((await response.json()).error.code).toBe("ai_budget_exhausted");
  expect(response.headers.get("Retry-After")).toBeNull();
});
