import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { DeadlineExceededError, INTERACTIVE_MAX_DURATION_S, RESPONSE_MARGIN_MS } from "@/lib/ai/deadline";
import { askDepsFromEnv } from "@/lib/api/ask-store";
import { answerQuestion } from "@/lib/pipeline/ask";

import { maxDuration, POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "u1" } })) }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/api/ask-store", () => ({ askDepsFromEnv: vi.fn(() => ({ deps: "ask" })), askRateLimit: vi.fn(async () => null) }));
vi.mock("@/lib/pipeline/ask", () => ({
  answerQuestion: vi.fn(async () => ({ answer: "금요일까지예요.", unknown: false, citations: [], summary: {} })),
}));

const QUESTION = "제안서 언제까지 보내기로 했지?";
const ask = () => POST(new Request("https://api.example.dev/api/v1/ask", { method: "POST", body: JSON.stringify({ question: QUESTION }) }));

beforeEach(() => {
  vi.clearAllMocks();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("POST /api/v1/ask", () => {
  it("실행 한도는 사용자가 기다리는 요청의 한도와 같다 (앱도 그만큼 기다린다)", () => {
    expect(maxDuration).toBe(INTERACTIVE_MAX_DURATION_S);
  });

  it("요청을 받자마자 정한 마감을 임베딩 · LLM deps에 넘긴다", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1_000_000);
    const response = await ask();
    expect(response.status).toBe(200);
    expect(askDepsFromEnv).toHaveBeenCalledWith({ admin: true }, "u1", 1_000_000 + INTERACTIVE_MAX_DURATION_S * 1000 - RESPONSE_MARGIN_MS);
    expect(vi.mocked(answerQuestion).mock.calls[0]).toEqual([QUESTION, { deps: "ask" }]);
  });

  it("마감 안에 끝내지 못하면 500과 함께 셀 수 있는 deadline_exceeded 한 줄을 남긴다 (질문은 남기지 않는다)", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(1_000_000);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.mocked(answerQuestion).mockImplementationOnce(async () => {
      now.mockReturnValue(1_000_000 + 52_000);
      throw new DeadlineExceededError("llm", "응답 시간 초과 (26초)");
    });
    const response = await ask();
    expect(response.status).toBe(500);
    const marker = log.mock.calls.find(([line]) => typeof line === "string" && line.includes("deadline_exceeded"));
    expect(JSON.parse(marker![0] as string)).toEqual({ event: "deadline_exceeded", route: "ask", stage: "llm", elapsed_ms: 52_000 });
    expect(JSON.stringify(log.mock.calls)).not.toContain(QUESTION);
  });
});
