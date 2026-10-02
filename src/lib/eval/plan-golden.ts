import { z } from "zod";

import { PLAN_CAPABILITIES, type PlanCapability } from "@/lib/ai/prompts/plan";
import type { NextStep, NextStepKind } from "@/lib/execution/plan";

import { executionCaseBaseSchema, findExecutionLabelErrors } from "./execution-golden";

// 다음 단계 골든셋 (evals/plan/*.json, eval E2). 한 케이스 = 요청 + Action · 근거 원문(합성) + 지금까지의 단계(history) + 기대 단계 종류.
// 채점: 스키마 유효(구조화 출력이 zod를 통과) · 단계 종류 일치. 통과: ≥95% · ≥90%. needs_connection의 capability는 참고로 센다.

const kinds = ["draft", "needs_connection", "ask_user", "done"] as const satisfies readonly NextStepKind[];
const capabilities = Object.keys(PLAN_CAPABILITIES) as [PlanCapability, ...PlanCapability[]];

export const planCaseSchema = executionCaseBaseSchema.extend({
  /** 이 실행에서 이미 지난 단계 (오래된 것부터) */
  history: z
    .array(
      z.object({
        kind: z.literal("draft"),
        status: z.enum(["called", "failed"]),
        brief: z.string().min(1),
        /** 만든 초안의 제목 (실패면 null) */
        title: z.string().min(1).nullable().default(null),
      }),
    )
    .default([]),
  expect: z.object({
    kind: z.enum(kinds),
    /** needs_connection일 때 맞는 기능 */
    capability: z.enum(capabilities).optional(),
  }),
});

export type PlanCase = z.infer<typeof planCaseSchema>;

export function findPlanLabelErrors(golden: PlanCase): string[] {
  const errors = findExecutionLabelErrors(golden);
  const { kind, capability } = golden.expect;
  if (kind === "needs_connection" && !capability) errors.push("needs_connection에는 capability가 필요합니다");
  if (kind !== "needs_connection" && capability) errors.push("capability는 needs_connection에만 둡니다");
  if (kind === "done" && !golden.history.some((h) => h.status === "called")) errors.push("done은 성공한 초안이 history에 있을 때만 맞습니다");
  for (const h of golden.history) {
    if (h.status === "called" && !h.title) errors.push("성공한 초안에는 title이 필요합니다");
    if (h.status === "failed" && h.title) errors.push("실패한 초안에는 title을 두지 않습니다");
  }
  return errors;
}

export type PlanScore = {
  caseId: string;
  expected: NextStepKind;
  /** 모델이 고른 단계. 스키마에 맞는 답을 받지 못했으면 null */
  actual: NextStepKind | null;
  schemaValid: boolean;
  kindCorrect: boolean;
  /** needs_connection을 맞게 골랐을 때 capability도 맞았나 (그 밖은 null) */
  capabilityCorrect: boolean | null;
  /** draft의 brief · ask_user의 question이 비지 않았나 */
  argsPresent: boolean;
};

export function scorePlanCase(golden: PlanCase, step: NextStep | null): PlanScore {
  const expected = golden.expect.kind;
  const kindCorrect = step?.kind === expected;
  return {
    caseId: golden.id,
    expected,
    actual: step?.kind ?? null,
    schemaValid: step !== null,
    kindCorrect,
    capabilityCorrect: kindCorrect && step?.kind === "needs_connection" ? step.capability === golden.expect.capability : null,
    argsPresent: step === null ? false : step.kind === "draft" ? step.brief.trim().length > 0 : step.kind === "ask_user" ? step.question.trim().length > 0 : true,
  };
}

export type PlanTotals = {
  n: number;
  schemaValid: number;
  kindCorrect: number;
  capabilityCorrect: number;
  capabilityJudged: number;
  /** 기대 종류 → 고른 종류(스키마 실패는 "invalid") 건수 */
  confusion: Record<NextStepKind, Record<NextStepKind | "invalid", number>>;
};

export function planTotals(scores: PlanScore[]): PlanTotals {
  const row = () => ({ draft: 0, needs_connection: 0, ask_user: 0, done: 0, invalid: 0 });
  const confusion = { draft: row(), needs_connection: row(), ask_user: row(), done: row() };
  for (const s of scores) confusion[s.expected][s.actual ?? "invalid"]++;
  const judged = scores.filter((s) => s.capabilityCorrect !== null);
  return {
    n: scores.length,
    schemaValid: scores.filter((s) => s.schemaValid).length,
    kindCorrect: scores.filter((s) => s.kindCorrect).length,
    capabilityCorrect: judged.filter((s) => s.capabilityCorrect).length,
    capabilityJudged: judged.length,
    confusion,
  };
}
