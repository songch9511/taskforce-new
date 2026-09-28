import { describe, expect, it } from "vitest";

import { findQuoteSpan, quoteContext, quoteInText } from "./text";

const text = ["a: 1", "b: 2", "c: 3", "나: 금요일까지 제안서", "보내드릴게요.", "d: 4", "e: 5"].join("\n");

describe("quoteInText", () => {
  it("공백 · 문장부호를 무시하고 찾는다", () => {
    expect(quoteInText("금요일까지  제안서 보내드릴게요!", text)).toBe(true);
    expect(quoteInText("월요일까지", text)).toBe(false);
    expect(quoteInText(" ", text)).toBe(false);
  });

  it("'...'로 이은 조각은 순서대로 모두 있어야 한다", () => {
    expect(quoteInText("b: 2 ... 금요일까지 제안서", text)).toBe(true);
    expect(quoteInText("금요일까지 제안서 … b: 2", text)).toBe(false);
    expect(quoteInText("b: 2 ... 없는 말", text)).toBe(false);
  });
});

describe("quoteContext", () => {
  it("인용이 걸친 줄 앞뒤를 잘라 준다", () => {
    expect(quoteContext(text, "금요일까지 제안서 보내드릴게요", 1)).toBe("c: 3\n나: 금요일까지 제안서\n보내드릴게요.\nd: 4");
  });

  it("긴 문단을 자를 때도 인용이 남는다 (앞쪽을 조금 더)", () => {
    const long = `${"가".repeat(5000)} 금요일까지 제안서 보내드릴게요. ${"나".repeat(5000)}`;
    const context = quoteContext(long, "금요일까지 제안서 보내드릴게요", 4, 300)!;
    expect(context).toContain("금요일까지 제안서 보내드릴게요");
    expect(context.startsWith("…") && context.endsWith("…")).toBe(true);
    expect(context.indexOf("금요일")).toBeGreaterThan(90);
    expect(context.length).toBeLessThanOrEqual(302);
  });

  it("없는 인용은 null", () => {
    expect(quoteContext(text, "없는 말")).toBeNull();
  });

  it("10줄보다 길게 걸친 인용은 maxSpan을 늘렸을 때만 찾는다 (기본 동작은 그대로)", () => {
    // 짧은 줄 15개에 걸친 인용 + 앞뒤 한 줄씩
    const span = Array.from({ length: 15 }, (_, i) => `줄${i + 1}`);
    const long = ["앞", "", ...span, "뒤"].join("\n");
    const quote = span.join("\n");
    expect(quoteInText(quote, long)).toBe(true);
    expect(quoteContext(long, quote, 1)).toBeNull();
    expect(quoteContext(long, quote, 1, 1500, Infinity)).toBe(["", ...span, "뒤"].join("\n"));
    expect(quoteContext(long, quote, 1, 1500, 13)).toBeNull();
    // 10줄 안의 인용은 늘려도 같은 결과
    expect(quoteContext(text, "금요일까지 제안서 보내드릴게요", 1, 1500, Infinity)).toBe(quoteContext(text, "금요일까지 제안서 보내드릴게요", 1));
    expect(quoteContext(long, "없는 말", 1, 1500, Infinity)).toBeNull();
  });
});

describe("findQuoteSpan", () => {
  it("공백 · 문장부호 · 대소문자 차이를 무시하고, 원문에 있는 그대로의 구간을 돌려준다", () => {
    const span = findQuoteSpan(text, "금요일까지  제안서 보내드릴게요!");
    expect(span).toEqual({ start: text.indexOf("금요일"), end: text.indexOf("보내드릴게요") + "보내드릴게요".length, quote: "금요일까지 제안서\n보내드릴게요" });
    expect(text.slice(span!.start, span!.end)).toBe(span!.quote);
    expect(findQuoteSpan("Please SEND the deck by Friday.", "send the deck")?.quote).toBe("SEND the deck");
  });

  it("모델이 바꾼 글자가 아니라 원문의 글자를 돌려준다 (따옴표 · 말줄임표 모양 등)", () => {
    const source = "박팀장: “견적서는 월요일에 받아도 괜찮아요…”";
    expect(findQuoteSpan(source, '"견적서는 월요일에 받아도 괜찮아요..."')?.quote).toBe("견적서는 월요일에 받아도 괜찮아요");
  });

  it("떨어진 구절을 '...'로 이어 붙인 인용은 받지 않는다 (quoteInText는 받는다)", () => {
    const stitched = "b: 2 ... 금요일까지 제안서";
    expect(quoteInText(stitched, text)).toBe(true);
    expect(findQuoteSpan(text, stitched)).toBeNull();
  });

  it("원문에 없거나 비어 있으면 null", () => {
    expect(findQuoteSpan(text, "월요일까지")).toBeNull();
    expect(findQuoteSpan(text, " ... ")).toBeNull();
    expect(findQuoteSpan("", "금요일")).toBeNull();
  });

  it("정규화로 길이가 바뀌는 글자(İ → i̇)가 있어도 위치가 맞는다", () => {
    const source = "İstanbul: 금요일까지 보낼게요";
    expect(findQuoteSpan(source, "금요일까지 보낼게요")?.quote).toBe("금요일까지 보낼게요");
    expect(findQuoteSpan(source, "İSTANBUL 금요일")?.quote).toBe("İstanbul: 금요일");
  });
});
