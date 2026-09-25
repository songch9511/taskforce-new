import { describe, expect, it } from "vitest";

import type { GoldenCase } from "./golden";
import { normalizeForMatch } from "@/lib/pipeline/text";

import { quotesOverlap, scoreCase, totals, type ScoredCandidate } from "./score";

const golden: GoldenCase = {
  id: "c1",
  origin: "synthetic",
  description: "테스트",
  user: { name: "나" },
  sources: [
    {
      id: "s1",
      kind: "meeting",
      occurred_at: "2025-09-22T10:00:00+09:00",
      text: "나: 네, 금요일까지 제안서 보내드릴게요.\n나: 회의록은 제가 오늘 정리할게요.\n김대표: 견적서는 박팀장이 드릴게요.\n김대표: 사무실을 옮겨요.",
    },
  ],
  expected_actions: [
    {
      title: "제안서 발송",
      owner: "me",
      due: "2025-09-26",
      status: "open",
      evidence: [{ source: "s1", quote: "금요일까지 제안서 보내드릴게요" }],
    },
    {
      title: "회의록 정리",
      owner: "me",
      due: "2025-09-22",
      status: "open",
      evidence: [{ source: "s1", quote: "회의록은 제가 오늘 정리할게요" }],
    },
  ],
  must_not_extract: [
    { source: "s1", quote: "견적서는 박팀장이 드릴게요", reason: "NOT_MY_ACTION" },
    { source: "s1", quote: "사무실을 옮겨요", reason: "INFO_ONLY" },
  ],
};

const candidate = (quote: string, extra: Partial<ScoredCandidate> = {}): ScoredCandidate => ({
  title: "t",
  quote,
  owner: "me",
  due: null,
  ...extra,
});

describe("quotesOverlap", () => {
  it("공백과 문장부호 차이를 무시한다", () => {
    expect(normalizeForMatch("네, 금요일까지!")).toBe("네금요일까지");
    expect(quotesOverlap("금요일까지 제안서 보내드릴게요.", "금요일까지제안서 보내드릴게요")).toBe(true);
  });

  it("한쪽이 다른 쪽을 포함하면 같은 구절이다", () => {
    expect(quotesOverlap("네, 금요일까지 제안서 보내드릴게요", "제안서 보내드릴게요")).toBe(true);
  });

  it("공통 구간이 짧으면 다른 구절이다", () => {
    expect(quotesOverlap("금요일까지 제안서 보내드릴게요", "견적서는 박팀장이 드릴게요")).toBe(false);
  });
});

describe("scoreCase", () => {
  it("정답과 짝지어 담당 · 기한을 채점하고 놓친 것을 센다", () => {
    const score = scoreCase(golden, [candidate("금요일까지 제안서 보내드릴게요", { due: "2025-09-26" })]);
    expect(score.truePositives).toBe(1);
    expect(score.ownerCorrect).toBe(1);
    expect(score.dueCorrect).toBe(1);
    expect(score.misses).toEqual([{ title: "회의록 정리", quote: "회의록은 제가 오늘 정리할게요" }]);
  });

  it("틀린 기한과 담당을 필드 오류로 남긴다", () => {
    const score = scoreCase(golden, [candidate("회의록은 제가 오늘 정리할게요", { owner: "unknown", due: "2025-09-23" })]);
    expect(score.truePositives).toBe(1);
    expect(score.ownerCorrect).toBe(0);
    expect(score.dueCorrect).toBe(0);
    expect(score.fieldErrors.map((e) => e.field)).toEqual(["owner", "due"]);
  });

  it("함정 문장을 뽑으면 사유별 오탐으로 센다", () => {
    const score = scoreCase(golden, [candidate("견적서는 박팀장이 드릴게요"), candidate("사무실을 옮겨요"), candidate("점심 먹기")]);
    expect(score.falsePositives.map((f) => f.kind)).toEqual(["NOT_MY_ACTION", "INFO_ONLY", "UNLABELED"]);
    expect(score.hallucinated.map((c) => c.quote)).toEqual(["점심 먹기"]);
  });

  it("같은 정답을 두 번 뽑으면 두 번째는 중복 오탐이다", () => {
    const score = scoreCase(golden, [
      candidate("금요일까지 제안서 보내드릴게요", { due: "2025-09-26" }),
      candidate("제안서 보내드릴게요", { due: "2025-09-26" }),
    ]);
    expect(score.truePositives).toBe(1);
    expect(score.falsePositives.map((f) => f.kind)).toEqual(["DUPLICATE"]);
  });
});

describe("totals", () => {
  it("precision · recall · 필드 정확도를 계산한다", () => {
    const score = scoreCase(golden, [
      candidate("금요일까지 제안서 보내드릴게요", { due: "2025-09-26" }),
      candidate("견적서는 박팀장이 드릴게요"),
    ]);
    const t = totals([score]);
    expect(t.precision).toBe(0.5);
    expect(t.recall).toBe(0.5);
    expect(t.ownerAccuracy).toBe(1);
    expect(t.dueAccuracy).toBe(1);
    expect(t.falsePositivesByKind.NOT_MY_ACTION).toBe(1);
  });

  it("후보가 없으면 precision은 계산하지 않는다", () => {
    expect(totals([scoreCase(golden, [])]).precision).toBeNull();
  });
});
