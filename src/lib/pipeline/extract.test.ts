import { describe, expect, it } from "vitest";

import { buildExtractUserPrompt, calendarAround, kstDate } from "@/lib/ai/prompts/extract";

import { extractCandidates, type CompleteJson } from "./extract";

const input = {
  text: "나: 금요일까지 제안서 보내드릴게요.",
  kind: "meeting" as const,
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
  userName: "나",
};

function fakeComplete(candidates: unknown[]): CompleteJson {
  return (async () => ({ data: { candidates }, model: "test/model" })) as CompleteJson;
}

const raw = {
  rationale: "사용자가 약속함",
  title: " 제안서 발송 ",
  quote: "금요일까지 제안서 보내드릴게요",
  owner: "me",
  owner_confidence: 0.9,
  counterpart: "김대표",
  due_text: "금요일까지",
  due: "2025-09-26",
  due_confidence: 0.8,
};

describe("extractCandidates", () => {
  it("모델 응답을 정리해 후보로 돌려준다", async () => {
    const result = await extractCandidates(input, fakeComplete([raw]));
    expect(result.model).toBe("test/model");
    expect(result.promptVersion).toMatch(/^extract-v\d+$/);
    expect(result.candidates).toEqual([
      {
        rationale: "사용자가 약속함",
        title: "제안서 발송",
        quote: "금요일까지 제안서 보내드릴게요",
        owner: "me",
        owner_confidence: 0.9,
        counterpart: "김대표",
        due_text: "금요일까지",
        due: "2025-09-26",
        due_confidence: 0.8,
      },
    ]);
  });

  it("날짜가 아닌 due는 버리고 신뢰도를 0~1로 자른다", async () => {
    const result = await extractCandidates(
      input,
      fakeComplete([{ ...raw, due: "2025-02-30", due_confidence: 0.7, owner_confidence: 1.4, counterpart: " " }]),
    );
    expect(result.candidates[0]).toMatchObject({ due: null, due_confidence: null, owner_confidence: 1, counterpart: null });
  });

  it("제목이나 인용이 빈 후보는 버린다", async () => {
    const result = await extractCandidates(input, fakeComplete([{ ...raw, quote: "  " }, { ...raw, title: "" }]));
    expect(result.candidates).toEqual([]);
  });
});

describe("추출 프롬프트", () => {
  it("한국 시간으로 날짜와 요일을 계산한다", () => {
    // UTC로는 9/21 일요일 밤이지만 한국 시간으로는 9/22 월요일
    expect(kstDate(new Date("2025-09-21T16:00:00Z"))).toEqual({ iso: "2025-09-22", weekday: "월" });
  });

  it("작성일이 속한 주의 월요일부터 달력을 만든다", () => {
    const calendar = calendarAround(new Date("2025-09-24T09:00:00+09:00")).split("\n");
    expect(calendar[0]).toBe("이번 주: 09-22(월) 09-23(화) 09-24(수) 09-25(목) 09-26(금) 09-27(토) 09-28(일)");
    expect(calendar[1]).toMatch(/^다음 주: 09-29\(월\)/);
  });

  it("일요일에 쓴 원문은 그 주 월요일부터 센다", () => {
    expect(calendarAround(new Date("2025-09-28T09:00:00+09:00"))).toMatch(/^이번 주: 09-22\(월\)/);
  });

  it("사용자 이름 · 작성 시점 · 원문을 담는다", () => {
    const prompt = buildExtractUserPrompt(input);
    expect(prompt).toContain("사용자 이름: 나");
    expect(prompt).toContain("작성 시점: 2025-09-22 (월)");
    expect(prompt).toContain(input.text);
  });
});
