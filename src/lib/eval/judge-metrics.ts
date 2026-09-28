import type { JudgeCandidate, JudgeDecision, JudgeResult } from "@/lib/pipeline/judge";

import type { GoldenCase } from "./golden";

// Jev가 사람 라벨과 얼마나 맞는지 본다. 추출기가 뽑은 후보만으로는 오탐이 적어 부정 라벨이 모자라므로,
// 골든셋의 정답 Action(긍정)과 함정 문장(부정)을 그대로 후보로 만들어 Jev에 묻는다.

export type LabelKind = "ACTION" | "NOT_MY_ACTION" | "INFO_ONLY" | "TENTATIVE" | "ALREADY_DONE";

/** 질문별 사람 라벨. 라벨로 알 수 없는 질문은 비워 둔다. */
export type HumanLabels = {
  is_my_commitment?: boolean;
  is_actionable?: boolean;
  already_done?: boolean;
  /** certainty가 firm이어야 하는가 */
  firm?: boolean;
};

export type LabeledItem = {
  caseId: string;
  kind: LabelKind;
  candidate: JudgeCandidate;
  labels: HumanLabels;
};

export function labeledItems(golden: GoldenCase): LabeledItem[] {
  const positives: LabeledItem[] = golden.expected_actions.map((action) => ({
    caseId: golden.id,
    kind: "ACTION",
    candidate: { title: action.title, quote: action.evidence[0].quote, due_text: null },
    labels: {
      // 담당이 unknown인 정답은 "내 약속인가"를 사람도 확정하지 못한 것이라 채점하지 않는다.
      ...(action.owner === "me" ? { is_my_commitment: true, firm: true } : {}),
      is_actionable: true,
      already_done: false,
    },
  }));

  const negatives: LabeledItem[] = golden.must_not_extract.map((trap) => ({
    caseId: golden.id,
    kind: trap.reason,
    candidate: { title: trap.quote, quote: trap.quote, due_text: null },
    labels:
      trap.reason === "NOT_MY_ACTION"
        ? { is_my_commitment: false }
        : trap.reason === "INFO_ONLY"
          ? { is_actionable: false }
          : trap.reason === "TENTATIVE"
            ? { firm: false }
            : { already_done: true },
  }));

  return [...positives, ...negatives];
}

export type JudgedItem = LabeledItem & { result: JudgeResult };

export type Agreement = { question: keyof HumanLabels; n: number; agree: number; rate: number | null };

/** 질문별 사람 라벨 일치율. noul은 0.5를 기준으로, certainty는 firm인지로 비교한다. */
export function agreement(items: JudgedItem[]): Agreement[] {
  const predict: Record<keyof HumanLabels, (r: JudgeResult) => boolean> = {
    is_my_commitment: (r) => r.signals.is_my_commitment >= 0.5,
    is_actionable: (r) => r.signals.is_actionable >= 0.5,
    already_done: (r) => r.signals.already_done >= 0.5,
    firm: (r) => r.signals.certainty.choice === "firm",
  };
  return (Object.keys(predict) as (keyof HumanLabels)[]).map((question) => {
    const labeled = items.filter((item) => item.labels[question] !== undefined);
    const agree = labeled.filter((item) => predict[question](item.result) === item.labels[question]).length;
    return { question, n: labeled.length, agree, rate: labeled.length ? agree / labeled.length : null };
  });
}

export type CalibrationBin = { from: number; to: number; n: number; meanProbability: number | null; actualRate: number | null };

/** 확률 구간별 실제 정답률. 잘 보정되었다면 meanProbability와 actualRate가 비슷하다. */
export function calibration(
  items: JudgedItem[],
  question: "is_my_commitment" | "is_actionable" | "already_done",
  edges: number[] = [0, 0.2, 0.4, 0.6, 0.8, 1],
): CalibrationBin[] {
  const labeled = items.filter((item) => item.labels[question] !== undefined);
  return edges.slice(0, -1).map((from, i) => {
    const to = edges[i + 1];
    const last = i === edges.length - 2;
    const inBin = labeled.filter((item) => {
      const p = item.result.signals[question];
      return p >= from && (last ? p <= to : p < to);
    });
    const mean = (values: number[]) => (values.length ? values.reduce((a, b) => a + b, 0) / values.length : null);
    return {
      from,
      to,
      n: inBin.length,
      meanProbability: mean(inBin.map((item) => item.result.signals[question])),
      actualRate: mean(inBin.map((item) => (item.labels[question] ? 1 : 0))),
    };
  });
}

/** 라벨 종류별로 자동 반영 / 확인 요청 / 기각이 몇 건씩 나왔는지 */
export function decisionTable(items: JudgedItem[]): Record<LabelKind, Record<JudgeDecision, number>> {
  const kinds: LabelKind[] = ["ACTION", "NOT_MY_ACTION", "INFO_ONLY", "TENTATIVE", "ALREADY_DONE"];
  const table = Object.fromEntries(kinds.map((k) => [k, { auto: 0, confirm: 0, reject: 0 }])) as Record<
    LabelKind,
    Record<JudgeDecision, number>
  >;
  for (const item of items) table[item.kind][item.result.decision]++;
  return table;
}
