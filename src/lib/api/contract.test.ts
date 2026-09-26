import { describe, expect, it } from "vitest";

import { createSourceRequestSchema, MAX_SOURCE_TEXT } from "./contract";

describe("createSourceRequestSchema", () => {
  it("최소 요청은 종류와 원문", () => {
    expect(createSourceRequestSchema.parse({ kind: "meeting", text: "  금요일까지 보내드릴게요 " })).toEqual({
      kind: "meeting",
      text: "금요일까지 보내드릴게요",
    });
  });

  it("시점은 시간대가 붙은 ISO 형식만 받는다", () => {
    expect(createSourceRequestSchema.safeParse({ kind: "note", text: "a", occurred_at: "2026-09-22T10:00:00+09:00" }).success).toBe(true);
    expect(createSourceRequestSchema.safeParse({ kind: "note", text: "a", occurred_at: "2026-09-22 10:00" }).success).toBe(false);
  });

  it.each([
    [{ kind: "chat", text: "a" }],
    [{ kind: "note", text: "   " }],
    [{ kind: "note", text: "a".repeat(MAX_SOURCE_TEXT + 1) }],
    [{ kind: "note", text: "a", external_url: "not a url" }],
  ])("잘못된 요청은 거부한다 %#", (body) => {
    expect(createSourceRequestSchema.safeParse(body).success).toBe(false);
  });
});
