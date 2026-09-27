import { describe, expect, it } from "vitest";

import { quoteContext, quoteInText } from "./text";

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
