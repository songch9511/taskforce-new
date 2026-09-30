import { describe, expect, it } from "vitest";

import type { JevDecision } from "@/lib/ai/jev";

import type { CompleteJson } from "./extract";
import type { Decide } from "./judge";
import { runPipeline } from "./run";

const input = {
  text: "김대표: 제안서 보고 싶어요.\n나: 네, 금요일까지 제안서 보내드릴게요.\n김대표: 견적서는 박팀장이 드릴게요.",
  kind: "meeting" as const,
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
  identity: { name: "나", aliases: [], emails: [] },
};

const raw = (quote: string, due: string | null = null) => ({
  signal: "commitment",
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
    statement_certainty: { type: "choice", choice: "firm", probabilities: {} },
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

describe("runPipeline의 작성자", () => {
  it("사용자가 쓴 원문이면 판정 state에 written_by_me를 넘긴다", async () => {
    const states: unknown[] = [];
    const recording: Decide = async (request) => {
      states.push(request.state);
      return decide(request);
    };
    await runPipeline({ ...input, writtenByMe: true }, { complete, decide: recording });
    expect(states).toHaveLength(2);
    expect(states.every((s) => (s as { source: { written_by_me?: boolean } }).source.written_by_me === true)).toBe(true);
  });
});

describe("runPipeline의 메일 인용", () => {
  const mail = {
    ...input,
    kind: "email" as const,
    fromConnector: true,
    text: "제목: Re: 견적서\n\n네, 금요일까지 제안서 보내드릴게요.\n\n2026년 10월 14일 (수) 오후 2:05, 김대표 <k@x.example>님이 작성:\n\n> 견적서는 박팀장이 드릴게요.",
    participants: { from: { name: "나" }, to: [{ name: "김대표" }] },
  };

  it("메일이면 인용된 옛 메일에만 있는 후보는 Jev에 묻기 전에 버린다", async () => {
    let asked = 0;
    const counting: Decide = async (request) => {
      asked++;
      return decide(request);
    };
    const result = await runPipeline(mail, { complete, decide: counting });
    expect(result.judged.map((j) => j.candidate.quote)).toEqual(["금요일까지 제안서 보내드릴게요"]);
    // 원문에 없는 인용 하나 + 인용된 옛 메일에만 있는 후보 하나
    expect(result.droppedCount).toBe(2);
    // 이유별 개수와 기록용 후보 (인용이 원문에 없는 후보는 기록에 남기지 않는다)
    expect(result.summary.droppedByReason).toEqual({ quoteNotFound: 1, quotedHistory: 1 });
    expect(result.droppedQuotedHistory.map((c) => c.quote)).toEqual(["견적서는 박팀장이 드릴게요"]);
    expect(asked).toBe(1);
  });

  it("직접 붙여 넣은 메일이면 인용 속 후보도 그대로 Jev에 묻는다", async () => {
    const result = await runPipeline({ ...mail, fromConnector: false }, { complete, decide });
    expect(result.judged.map((j) => j.candidate.quote)).toEqual(["금요일까지 제안서 보내드릴게요", "견적서는 박팀장이 드릴게요"]);
    expect(result.droppedCount).toBe(1);
    expect(result.droppedQuotedHistory).toEqual([]);
    expect(result.summary.droppedByReason).toEqual({ quoteNotFound: 1, quotedHistory: 0 });
  });

  it("같은 원문이라도 메일이 아니면 이 규칙을 쓰지 않는다", async () => {
    const result = await runPipeline({ ...mail, kind: "note" }, { complete, decide });
    expect(result.judged.map((j) => j.candidate.quote)).toEqual(["금요일까지 제안서 보내드릴게요", "견적서는 박팀장이 드릴게요"]);
    expect(result.droppedCount).toBe(1);
  });
});
