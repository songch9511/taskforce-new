import { describe, expect, it } from "vitest";

import type { ActionCandidate } from "./extract";
import { verifyCandidates } from "./verify";

const source = {
  text: "김대표: 제안서 보고 싶어요.\n나: 네, 금요일까지 제안서 보내드릴게요.\n나: 회의록은 다음 주 초에 정리할게요.",
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
};

const candidate = (extra: Partial<ActionCandidate>): ActionCandidate => ({
  title: "제안서 발송",
  quote: "금요일까지 제안서 보내드릴게요",
  owner: "me",
  owner_confidence: 0.9,
  counterpart: null,
  due_text: "금요일까지",
  due: "2025-09-26",
  due_confidence: 0.9,
  rationale: "",
  ...extra,
});

describe("verifyCandidates", () => {
  it("원문에 없는 인용은 버린다", () => {
    const result = verifyCandidates([candidate({ quote: "월요일까지 제안서 보내드릴게요" })], source);
    expect(result.kept).toEqual([]);
    expect(result.dropped.map((d) => d.reason)).toEqual(["QUOTE_NOT_FOUND"]);
  });

  it("코드 계산과 같은 기한은 그대로 둔다", () => {
    expect(verifyCandidates([candidate({})], source).kept[0]).toMatchObject({ due: "2025-09-26", due_check: "match" });
  });

  it("모델이 요일을 틀리면 코드 값으로 바꾸고 원래 값을 남긴다", () => {
    const kept = verifyCandidates([candidate({ due: "2025-09-27" })], source).kept[0];
    expect(kept).toMatchObject({ due: "2025-09-26", model_due: "2025-09-27", due_check: "corrected" });
  });

  it("모델이 날짜를 못 냈어도 코드가 계산할 수 있으면 채운다", () => {
    expect(verifyCandidates([candidate({ due: null })], source).kept[0]).toMatchObject({ due: "2025-09-26", due_check: "corrected" });
  });

  it("코드가 모르는 표현이면 모델 값을 그대로 둔다", () => {
    const kept = verifyCandidates(
      [candidate({ quote: "회의록은 다음 주 초에 정리할게요", due_text: "다음 주 초", due: null })],
      source,
    ).kept[0];
    expect(kept).toMatchObject({ due: null, due_check: "unresolved" });
  });

  it("기한 표현이 없으면 none", () => {
    expect(verifyCandidates([candidate({ due_text: null, due: null })], source).kept[0].due_check).toBe("none");
  });
});
