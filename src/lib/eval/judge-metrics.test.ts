import { describe, expect, it } from "vitest";

import type { JudgeResult, JudgeSignals } from "@/lib/pipeline/judge";

import type { GoldenCase } from "./golden";
import { agreement, calibration, decisionTable, labeledItems, type JudgedItem } from "./judge-metrics";

const golden: GoldenCase = {
  id: "c1",
  origin: "synthetic",
  description: "테스트",
  user: { name: "나", aliases: [], emails: [] },
  sources: [{ id: "s1", kind: "meeting", occurred_at: "2025-09-22T10:00:00+09:00", text: "가나다 라마바 사아자 차카타 파하" }],
  expected_actions: [
    { title: "A", owner: "me", status: "open", evidence: [{ source: "s1", quote: "가나다" }] },
    { title: "B", owner: "unknown", status: "open", evidence: [{ source: "s1", quote: "라마바" }] },
  ],
  must_not_extract: [
    { source: "s1", quote: "사아자", reason: "NOT_MY_ACTION" },
    { source: "s1", quote: "차카타", reason: "TENTATIVE" },
    { source: "s1", quote: "파하", reason: "ALREADY_DONE" },
  ],
};

function result(overrides: Partial<JudgeSignals>, decision: JudgeResult["decision"] = "auto"): JudgeResult {
  return {
    decision,
    reasons: [],
    promptVersion: "judge-v1",
    model: "m",
    signals: {
      is_my_commitment: 0.9,
      is_actionable: 0.9,
      already_done: 0.1,
      certainty: { choice: "firm", probabilities: {} },
      speaker_role: { choice: "me", probabilities: {} },
      directness: { choice: "first_hand", probabilities: {} },
      audience: { choice: "shared", probabilities: {} },
      ...overrides,
    },
  };
}

describe("labeledItems", () => {
  it("정답은 긍정 라벨, 함정은 사유에 맞는 질문만 부정 라벨을 단다", () => {
    const items = labeledItems(golden);
    expect(items.map((i) => [i.kind, i.labels])).toEqual([
      ["ACTION", { is_my_commitment: true, firm: true, is_actionable: true, already_done: false }],
      ["ACTION", { is_actionable: true, already_done: false }],
      ["NOT_MY_ACTION", { is_my_commitment: false }],
      ["TENTATIVE", { firm: false }],
      ["ALREADY_DONE", { already_done: true }],
    ]);
  });
});

describe("Jev 지표", () => {
  const [a, b, notMine, tentative, done] = labeledItems(golden);
  const judged: JudgedItem[] = [
    { ...a, result: result({}) },
    { ...b, result: result({ is_my_commitment: 0.5 }, "confirm") },
    { ...notMine, result: result({ is_my_commitment: 0.7 }, "confirm") },
    { ...tentative, result: result({ certainty: { choice: "tentative", probabilities: {} } }, "confirm") },
    { ...done, result: result({ already_done: 0.95 }, "reject") },
  ];

  it("질문별 일치율", () => {
    const byQuestion = Object.fromEntries(agreement(judged).map((a) => [a.question, [a.agree, a.n]]));
    expect(byQuestion).toEqual({
      is_my_commitment: [1, 2], // 사아자를 0.7로 내 약속이라고 봄
      is_actionable: [2, 2],
      already_done: [3, 3],
      firm: [2, 2],
    });
  });

  it("확률 구간별 실제 정답률", () => {
    const bins = calibration(judged, "is_my_commitment");
    expect(bins.find((b) => b.from === 0.6)).toMatchObject({ n: 1, actualRate: 0 });
    expect(bins.find((b) => b.from === 0.8)).toMatchObject({ n: 1, meanProbability: 0.9, actualRate: 1 });
    expect(bins.find((b) => b.from === 0)).toMatchObject({ n: 0, actualRate: null });
  });

  it("라벨 종류별 판정 분포", () => {
    const table = decisionTable(judged);
    expect(table.ACTION).toEqual({ auto: 1, confirm: 1, reject: 0 });
    expect(table.ALREADY_DONE).toEqual({ auto: 0, confirm: 0, reject: 1 });
    expect(table.INFO_ONLY).toEqual({ auto: 0, confirm: 0, reject: 0 });
  });
});
