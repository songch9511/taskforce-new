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

  it("없는 인용은 null", () => {
    expect(quoteContext(text, "없는 말")).toBeNull();
  });
});
