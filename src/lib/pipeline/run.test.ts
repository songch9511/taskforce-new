import { describe, expect, it } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";

import type { CompleteJson } from "./extract";
import type { Decide } from "./judge";
import { runPipeline } from "./run";

const input = {
  text: "김대표: 제안서 보고 싶어요.\n나: 네, 금요일까지 제안서 보내드릴게요.\n김대표: 견적서는 박팀장이 드릴게요.",
  kind: "meeting" as const,
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
  userName: "나",
};

const raw = (quote: string, due: string | null = null) => ({
  rationale: "",
  title: quote,
  quote,
  owner: "me",
  owner_confidence: 0.9,
  counterpart: null,
  due_text: due ? "금요일까지" : null,
  due,
  due_confidence: due ? 0.9 : null,
});

const complete = (async () => ({
  model: "test/llm",
  usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.001 },
  data: {
    candidates: [
      raw("금요일까지 제안서 보내드릴게요", "2025-09-27"), // 요일을 틀림 → 코드가 고친다
      raw("견적서는 박팀장이 드릴게요"),
      raw("월요일에 미팅 잡을게요"), // 원문에 없음 → 버린다
    ],
  },
})) as CompleteJson;

function answers(my: number): JevDecision["answers"] {
  return {
    is_my_commitment: { type: "noul", noul: my },
    is_actionable: { type: "noul", noul: 0.95 },
    already_done: { type: "noul", noul: 0.05 },
    certainty: { type: "choice", choice: "firm", probabilities: {} },
    speaker_role: { type: "choice", choice: "me", probabilities: {} },
    directness: { type: "choice", choice: "first_hand", probabilities: {} },
    audience: { type: "choice", choice: "shared", probabilities: {} },
  };
}

const decide: Decide = async (request) => {
  const quote = (request.state as { candidate: { quote: string } }).candidate.quote;
  return { model: "test/jev", answers: answers(quote.includes("박팀장") ? 0.1 : 0.95), usage: { input_tokens: 1, cost: 0.0001 } };
};

describe("runPipeline", () => {
  it("추출 → 기계 검증 → Jev 판정을 거쳐 후보와 요약을 돌려준다", async () => {
    const result = await runPipeline(input, { complete, decide });

    expect(result.judged.map((j) => [j.candidate.quote, j.judge.decision])).toEqual([
      ["금요일까지 제안서 보내드릴게요", "auto"],
      ["견적서는 박팀장이 드릴게요", "reject"],
    ]);
    expect(result.judged[0].candidate).toMatchObject({ due: "2025-09-26", due_check: "corrected" });
    expect(result.summary).toMatchObject({
      extracted: 3,
      dropped: 1,
      auto: 1,
      confirm: 0,
      reject: 1,
      dueCorrected: 1,
      models: { extract: "test/llm", judge: "test/jev" },
    });
    expect(result.summary.cost).toBeCloseTo(0.0012);
  });
});
