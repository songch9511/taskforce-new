import { describe, expect, it } from "vitest";

import type { GoldenCase } from "./golden";
import { scoreSequence, sequenceTotals, type FinalAction } from "./sequence-score";

const golden: GoldenCase = {
  id: "seq",
  origin: "synthetic",
  description: "t",
  user: { name: "나", aliases: [], emails: [] },
  sources: [
    { id: "s1", kind: "meeting", occurred_at: "2025-09-22T10:00:00+09:00", text: "금요일까지 제안서 보내드릴게요. 견적서는 수요일까지 드릴게요. 참고로 사무실 이전" },
    { id: "s2", kind: "message", occurred_at: "2025-09-24T10:00:00+09:00", text: "제안서는 월요일에 받아도 괜찮아요" },
  ],
  expected_actions: [
    {
      title: "제안서 발송",
      owner: "me",
      due: "2025-09-29",
      status: "open",
      evidence: [
        { source: "s1", quote: "금요일까지 제안서 보내드릴게요" },
        { source: "s2", quote: "제안서는 월요일에 받아도 괜찮아요" },
      ],
    },
    { title: "견적서 발송", owner: "me", due: "2025-09-24", status: "open", evidence: [{ source: "s1", quote: "견적서는 수요일까지 드릴게요" }] },
  ],
  must_not_extract: [{ source: "s1", quote: "참고로 사무실 이전", reason: "INFO_ONLY" }],
};

const action = (id: string, quotes: string[], due: string | null, status = "open", owner = "me"): FinalAction => ({ id, title: id, quotes, due, status, owner });

describe("scoreSequence", () => {
  it("정답마다 Action 하나, 필드가 맞으면 정답", () => {
    const s = scoreSequence(golden, [
      action("a1", ["금요일까지 제안서 보내드릴게요", "제안서는 월요일에 받아도 괜찮아요"], "2025-09-29"),
      action("a2", ["견적서는 수요일까지 드릴게요"], "2025-09-24"),
    ]);
    expect(s).toMatchObject({ correct: 2, splits: [], misses: [], extras: [], fieldErrors: [] });
  });

  it("같은 약속이 둘로 갈라지면 split, 기한이 안 바뀌었으면 필드 오류", () => {
    const split = scoreSequence(golden, [
      action("a1", ["금요일까지 제안서 보내드릴게요"], "2025-09-26"),
      action("a2", ["제안서는 월요일에 받아도 괜찮아요"], "2025-09-29"),
      action("a3", ["견적서는 수요일까지 드릴게요"], "2025-09-26"),
    ]);
    expect(split.splits).toEqual([{ title: "제안서 발송", actions: 2 }]);
    expect(split.fieldErrors).toEqual([{ title: "견적서 발송", field: "due", expected: "2025-09-24", actual: "2025-09-26" }]);
    expect(split.correct).toBe(0);
  });

  it("다른 약속을 하나로 합치면 over-merge, 함정은 사유별 extra", () => {
    const s = scoreSequence(golden, [
      action("a1", ["금요일까지 제안서 보내드릴게요", "견적서는 수요일까지 드릴게요"], "2025-09-29"),
      action("a9", ["참고로 사무실 이전"], null),
    ]);
    expect(s.overMerged.map((o) => o.title)).toEqual(["제안서 발송", "견적서 발송"]);
    expect(s.extras).toEqual([{ title: "a9", kind: "INFO_ONLY" }]);
  });

  it("합계와 병합 정확도", () => {
    const t = sequenceTotals([scoreSequence(golden, [action("a1", ["금요일까지 제안서 보내드릴게요"], "2025-09-29")])]);
    expect(t).toMatchObject({ expected: 2, correct: 1, accuracy: 0.5, misses: 1 });
  });
});
