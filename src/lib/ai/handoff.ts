import "server-only";

import { z } from "zod";

import type { HandoffAssessment } from "@/lib/api/contract";
import type { SupabaseClient } from "@supabase/supabase-js";
import { assertConsent, ConsentRequiredError, withConsentGate } from "@/lib/consent/gate";
import { consentCheck } from "@/lib/consent/store";
import type { CompleteJson } from "@/lib/pipeline/extract";

import { budgetFetch } from "./budget";
import { AiBudgetError } from "./budget-error";
import { DeadlineExceededError } from "./deadline";
import { HandoffGenerationError } from "./handoff-error";
import { decide, JevError, jevConfigFromEnv, type JevDecision, type JevQuestion } from "./jev";
import { completeJson, LlmError, llmConfigFromEnv } from "./llm";
import {
  HANDOFF_PLAN_V1_SYSTEM_PROMPT,
  HANDOFF_RUBRIC_VERSION,
  HANDOFF_V1_QUESTIONS,
  HANDOFF_V1_SYSTEM_PROMPT,
  handoffPlanV1UserPrompt,
} from "./prompts/handoff-v1";

const planText = z.string().trim().min(1).max(500);
export const handoffPlanSchema = z.object({
  goal: planText,
  steps: z.array(planText).min(1).max(8),
  deliverables: z.array(planText).min(1).max(8),
  checks: z.array(planText).min(1).max(8),
  questions: z.array(planText).max(8),
}).strict();
export type HandoffPlan = z.infer<typeof handoffPlanSchema>;

const PLAN_CONTEXT_MAX_CHARS = 48_000;
const JEV_LLM_RESERVE_MS = 20_000;
const JEV_MAX_MS = 20_000;

export type HandoffModelDeps = {
  decide: (request: { state: unknown; questions: Record<string, JevQuestion> }) => Promise<JevDecision>;
  complete: CompleteJson;
};

/** Both model calls share the AI budget and check consent immediately before each call. */
export function handoffModelDepsFromEnv(admin: SupabaseClient, userId: string, deadline: number): HandoffModelDeps {
  const budgetedFetch = budgetFetch(admin, userId);
  const checkConsent = consentCheck(admin, userId);
  const guardedFetch: typeof fetch = async (input, init) => {
    await assertConsent(checkConsent);
    return budgetedFetch(input, init);
  };
  const jevDeadline = Math.min(deadline - JEV_LLM_RESERVE_MS, Date.now() + JEV_MAX_MS);
  const jev = { ...jevConfigFromEnv(), model: "typesafe/jev-1.13", fetch: guardedFetch, deadline: jevDeadline };
  const llm = { ...llmConfigFromEnv(), fetch: guardedFetch, deadline };
  return withConsentGate<HandoffModelDeps>(
    {
      decide: (request) => decide(jev, request),
      complete: (request) => completeJson(llm, request),
    },
    checkConsent,
  );
}

function inUnitInterval(value: number): boolean {
  return Number.isFinite(value) && value >= 0 && value <= 1;
}

function choiceFor(decision: JevDecision, key: string, allowed: readonly string[]): string {
  const answer = decision.answers[key];
  if (!answer || answer.type !== "choice" || !allowed.includes(answer.choice)) throw new HandoffGenerationError("assessment");
  if (answer.confidence !== undefined && !inUnitInterval(answer.confidence)) throw new HandoffGenerationError("assessment");

  const probabilityKeys = Object.keys(answer.probabilities);
  if (probabilityKeys.length === 0 || probabilityKeys.some((candidate) => !allowed.includes(candidate))) {
    throw new HandoffGenerationError("assessment");
  }
  if (
    !Object.hasOwn(answer.probabilities, answer.choice) ||
    Object.values(answer.probabilities).some((probability) => !inUnitInterval(probability)) ||
    Math.abs(Object.values(answer.probabilities).reduce((total, probability) => total + probability, 0) - 1) > 0.02
  ) {
    throw new HandoffGenerationError("assessment");
  }
  return answer.choice;
}

export function handoffAssessmentFromDecision(decision: JevDecision): HandoffAssessment {
  const expected = Object.keys(HANDOFF_V1_QUESTIONS).sort();
  const actual = Object.keys(decision.answers).sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new HandoffGenerationError("assessment");
  }
  const model = z.string().trim().min(1).max(200).safeParse(decision.model);
  if (!model.success) throw new HandoffGenerationError("assessment");

  return {
    effort: choiceFor(decision, "effort", ["low", "medium", "high", "unknown"]) as HandoffAssessment["effort"],
    difficulty: choiceFor(decision, "difficulty", ["low", "medium", "high", "unknown"]) as HandoffAssessment["difficulty"],
    context: choiceFor(decision, "context", ["sufficient", "needs_clarification"]) as HandoffAssessment["context"],
    model: model.data,
    rubric_version: HANDOFF_RUBRIC_VERSION,
  };
}

function boundedContext(markdown: string): string {
  if (markdown.length <= PLAN_CONTEXT_MAX_CHARS) return markdown;
  return `${markdown.slice(0, PLAN_CONTEXT_MAX_CHARS)}\n\n[The deterministic context was truncated at the input limit.]`;
}

export function composeAssistedHandoff(markdown: string, plan: HandoffPlan): string {
  // The generated goal reflects the context language without letting a long quoted source excerpt dominate it.
  const korean = /[가-힣]/u.test(plan.goal);
  const labels = korean
    ? { title: "# AI에게 넘길 실행 초안 (검토 필요)", goal: "### 목표", steps: "### 단계", deliverables: "### 결과물", checks: "### 완료 기준", questions: "### 먼저 확인할 질문", appendix: "## 참고 문맥 (아래 Taskforce 문서는 원문 그대로 유지)" }
    : { title: "# AI handoff draft (review required)", goal: "### Goal", steps: "### Steps", deliverables: "### Deliverables", checks: "### Completion checks", questions: "### Questions to clarify first", appendix: "## Reference context (the Taskforce document below is unchanged)" };
  const sections = [
    labels.title,
    `${labels.goal}\n${plan.goal}`,
    [labels.steps, ...plan.steps.map((step, index) => `${index + 1}. ${step}`)].join("\n"),
    [labels.deliverables, ...plan.deliverables.map((item) => `- ${item}`)].join("\n"),
    [labels.checks, ...plan.checks.map((item) => `- ${item}`)].join("\n"),
    ...(plan.questions.length ? [[labels.questions, ...plan.questions.map((item) => `- ${item}`)].join("\n")] : []),
  ];
  return `${sections.join("\n\n")}\n\n${labels.appendix}\n\n---\n\n${markdown}`;
}

/** Assess only the deterministic, already bounded handoff document; never pass raw source text to model code. */
export async function generateAssistedHandoff(markdown: string, deps: HandoffModelDeps): Promise<{ markdown: string; assessment: HandoffAssessment }> {
  let stage: HandoffGenerationError["stage"] = "assessment";
  try {
    const context = boundedContext(markdown);
    const questions = Object.fromEntries(Object.entries(HANDOFF_V1_QUESTIONS).map(([key, question]) => [key, {
      ...question,
      instructions: `${HANDOFF_V1_SYSTEM_PROMPT}\n\n${question.instructions}`,
    }]));
    const decision = await deps.decide({ state: { deterministic_task_context: context }, questions });
    const assessment = handoffAssessmentFromDecision(decision);

    stage = "plan";
    const generated = await deps.complete({
      system: HANDOFF_PLAN_V1_SYSTEM_PROMPT,
      user: handoffPlanV1UserPrompt(context, assessment),
      schemaName: "handoff_execution_plan",
      schema: handoffPlanSchema,
      maxTokens: 1800,
    });
    const plan = handoffPlanSchema.parse(generated.data);
    if ((assessment.context === "needs_clarification" || assessment.effort === "unknown" || assessment.difficulty === "unknown") && plan.questions.length === 0) {
      throw new HandoffGenerationError("plan");
    }
    return { markdown: composeAssistedHandoff(markdown, plan), assessment };
  } catch (error) {
    if (error instanceof HandoffGenerationError || error instanceof AiBudgetError || error instanceof DeadlineExceededError || error instanceof ConsentRequiredError) throw error;
    if (error instanceof JevError || error instanceof LlmError) throw new HandoffGenerationError(stage);
    throw new HandoffGenerationError(stage);
  }
}

export async function generateAssistedHandoffFromEnv(
  markdown: string,
  admin: SupabaseClient,
  userId: string,
  deadline: number,
): Promise<{ markdown: string; assessment: HandoffAssessment }> {
  try {
    const result = await generateAssistedHandoff(markdown, handoffModelDepsFromEnv(admin, userId, deadline));
    await assertConsent(consentCheck(admin, userId));
    return result;
  } catch (error) {
    if (error instanceof HandoffGenerationError || error instanceof AiBudgetError || error instanceof DeadlineExceededError || error instanceof ConsentRequiredError) throw error;
    throw new HandoffGenerationError("assessment");
  }
}
