// 골든셋으로 추출 품질을 평가한다: npm run eval
//   npm run eval                  라벨 검사 + (키가 있으면) 추출 → 기계 검증 → Jev 판정 채점 + 물어보기(evals/ask) 채점
//   npm run eval -- --case <id>   한 케이스만
//   npm run eval -- --tag slack   태그가 붙은 케이스만 (물어보기는 건너뜀)
//   npm run eval -- --no-judge    Jev 없이 추출 · 기계 검증만
//   npm run eval -- --labels      라벨 검사만 (CI처럼 키가 없을 때와 같음)
//   npm run eval -- --draft       초안 골든셋(evals/draft, E1)만 채점 (--case로 그 세트의 케이스를 주면 저절로)
//   npm run eval -- --plan        다음 단계 골든셋(evals/plan, E2)만 채점
//   npm run eval -- --consult     대화 상담 골든셋(evals/consult, B2)만 채점: 실제 Jev(J1) + LLM(J2 · J7)로 respondToMessage
//   npm run eval -- --all         기존 채점 + E1 + E2 + 대화 상담 (기본 실행은 기존 채점만, E1 · E2 · 대화는 따로 보고 · 따로 저장)
//   npm run eval -- --llm-concurrency 2 --jev-concurrency 4  제공자 속도 제한이 있을 때 eval 호출량만 낮춤 (기본 4 · 8)
// 키(OPENROUTER_API_KEY, LLM_MODEL, JEV_MODEL)는 환경변수나 .env.local에서 읽는다.
import { randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";

import type { z } from "zod";

import { embed, embedConfigFromEnv } from "../src/lib/ai/embed";
import { decide, jevConfigFromEnv, type JevConfig } from "../src/lib/ai/jev";
import { DeadlineExceededError, INTERACTIVE_MAX_DURATION_S, interactiveDeadline } from "../src/lib/ai/deadline";
import { fetchGeneration, type Generation } from "../src/lib/ai/generation";
import { completeJson, llmAttemptsOf, llmConfigFromEnv, LlmError, type LlmAttempt, type LlmConfig } from "../src/lib/ai/llm";
import { ASK_PROMPT_VERSION } from "../src/lib/ai/prompts/ask";
import { DRAFT_PROMPT_VERSION } from "../src/lib/ai/prompts/draft";
import { DRAFT_JUDGE_PROMPT_VERSION, DRAFT_JUDGE_QUESTIONS, type DraftJudgeQuestionKey } from "../src/lib/ai/prompts/draft-judge";
import { PLAN_PROMPT_VERSION } from "../src/lib/ai/prompts/plan";
import { EXTRACT_PROMPT_VERSION } from "../src/lib/ai/prompts/extract";
import { projectAction } from "../src/lib/actions/project";
import { askCaseSchema, askContextOf, findAskLabelErrors, scoreAskCase, type AskCase, type AskScore } from "../src/lib/eval/ask-golden";
import { consultCaseSchema, consultInputOf, findConsultLabelErrors, scoreConsultCase, type ConsultCase, type ConsultScore } from "../src/lib/eval/consult-golden";
import { CONSULT_PROMPT_VERSION } from "../src/lib/ai/prompts/consult";
import { INTENT_PROMPT_VERSION } from "../src/lib/ai/prompts/intent";
import { MEMORY_EXTRACT_PROMPT_VERSION } from "../src/lib/ai/prompts/memory-extract";
import { respondToMessage, type TurnPlan } from "../src/lib/conversation/respond";
import { draftCaseSchema, draftJudgeState, draftTotals, findDraftLabelErrors, humanSample, scoreDraftCase, type DraftCase, type DraftScore } from "../src/lib/eval/draft-golden";
import { executionContextOf } from "../src/lib/eval/execution-golden";
import { findPlanLabelErrors, planCaseSchema, planTotals, scorePlanCase, type PlanCase, type PlanScore } from "../src/lib/eval/plan-golden";
import { writeDraft, type DraftResult } from "../src/lib/execution/draft";
import { planNextStep, type PlanResult } from "../src/lib/execution/plan";
import { findLabelErrors, goldenCaseSchema, type GoldenCase } from "../src/lib/eval/golden";
import { agreement, calibration, decisionTable, labeledItems, type JudgedItem } from "../src/lib/eval/judge-metrics";
import { scoreCase, totals, type CaseScore, type ScoredCandidate, type Totals } from "../src/lib/eval/score";
import { scoreSequence, sequenceTotals, type FinalAction, type SequenceScore } from "../src/lib/eval/sequence-score";
import { answerQuestion, type AskResult } from "../src/lib/pipeline/ask";
import { extractCandidates, type ActionCandidate, type CompleteJson } from "../src/lib/pipeline/extract";
import { judgeCandidate, judgePromptVersionForSource, type JudgeCandidate, type JudgeResult, type JudgeSource } from "../src/lib/pipeline/judge";
import { InMemoryActionStore, mergeJudged, withJudgeOwnership, type MergeOutcome } from "../src/lib/pipeline/merge";
import { resolveAction } from "../src/lib/pipeline/resolve";
import { runPipeline } from "../src/lib/pipeline/run";
import { JUDGE_THRESHOLDS } from "../src/lib/pipeline/judge.config";
import { verifyCandidates, type VerifiedCandidate } from "../src/lib/pipeline/verify";

const ROOT = path.resolve(import.meta.dirname, "..");
const GOLDEN_DIR = path.join(ROOT, "evals/golden");
const ASK_DIR = path.join(ROOT, "evals/ask");
const DRAFT_DIR = path.join(ROOT, "evals/draft");
const PLAN_DIR = path.join(ROOT, "evals/plan");
const CONSULT_DIR = path.join(ROOT, "evals/consult");
const RESULTS_DIR = path.join(ROOT, "evals/results");
const DEFAULT_LLM_CONCURRENCY = 4;
const DEFAULT_JEV_CONCURRENCY = 8;
const MAX_EVAL_CONCURRENCY = 16;

async function loadGolden(): Promise<{ cases: GoldenCase[]; failed: number }> {
  const files = (await readdir(GOLDEN_DIR)).filter((f) => f.endsWith(".json")).sort();
  const cases: GoldenCase[] = [];
  let failed = 0;

  for (const file of files) {
    const parsed = goldenCaseSchema.safeParse(JSON.parse(await readFile(path.join(GOLDEN_DIR, file), "utf8")));
    if (!parsed.success) {
      failed++;
      console.error(`✗ ${file}: 형식 오류\n${parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n")}`);
      continue;
    }
    const errors = findLabelErrors(parsed.data);
    if (errors.length > 0) {
      failed++;
      console.error(`✗ ${file}: 라벨 오류\n${errors.map((e) => `  - ${e}`).join("\n")}`);
      continue;
    }
    cases.push(parsed.data);
  }
  return { cases, failed };
}

/** 물어보기 골든셋 (evals/ask): 형식 · 라벨 검사 */
async function loadAskCases(): Promise<{ cases: AskCase[]; failed: number }> {
  const files = (await readdir(ASK_DIR).catch(() => [] as string[])).filter((f) => f.endsWith(".json")).sort();
  const cases: AskCase[] = [];
  let failed = 0;
  for (const file of files) {
    const parsed = askCaseSchema.safeParse(JSON.parse(await readFile(path.join(ASK_DIR, file), "utf8")));
    if (!parsed.success) {
      failed++;
      console.error(`✗ ask/${file}: 형식 오류\n${parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n")}`);
      continue;
    }
    const errors = findAskLabelErrors(parsed.data);
    if (errors.length > 0) {
      failed++;
      console.error(`✗ ask/${file}: 라벨 오류\n${errors.map((e) => `  - ${e}`).join("\n")}`);
      continue;
    }
    cases.push(parsed.data);
  }
  return { cases, failed };
}

/** 실행 골든셋 (evals/draft E1 · evals/plan E2): 형식 · 라벨 검사 */
async function loadExecutionSet<T>(dir: string, schema: z.ZodType<T>, findErrors: (golden: T) => string[]): Promise<{ cases: T[]; failed: number }> {
  const label = path.basename(dir);
  const files = (await readdir(dir).catch(() => [] as string[])).filter((f) => f.endsWith(".json")).sort();
  const cases: T[] = [];
  let failed = 0;
  for (const file of files) {
    const parsed = schema.safeParse(JSON.parse(await readFile(path.join(dir, file), "utf8")));
    if (!parsed.success) {
      failed++;
      console.error(`✗ ${label}/${file}: 형식 오류\n${parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n")}`);
      continue;
    }
    const errors = findErrors(parsed.data);
    if (errors.length > 0) {
      failed++;
      console.error(`✗ ${label}/${file}: 라벨 오류\n${errors.map((e) => `  - ${e}`).join("\n")}`);
      continue;
    }
    cases.push(parsed.data);
  }
  return { cases, failed };
}

async function mapLimit<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index]);
    }
  });
  await Promise.all(workers);
  return results;
}

function evalConcurrency(value: string | undefined, fallback: number, option: string): number {
  if (value === undefined) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_EVAL_CONCURRENCY) {
    throw new Error(`--${option} 값은 1~${MAX_EVAL_CONCURRENCY} 사이의 정수여야 합니다.`);
  }
  return parsed;
}

const pct = (value: number | null) => (value === null ? "    -" : `${(value * 100).toFixed(1).padStart(5)}%`);

function summaryRow(label: string, t: Totals): string {
  return [
    label.padEnd(16),
    pct(t.precision),
    pct(t.recall),
    pct(t.ownerAccuracy),
    String(t.falseAttributions).padStart(4),
    pct(t.dueAccuracy),
    `${t.truePositives}/${t.falsePositives}/${t.misses}`.padStart(9),
    String(t.hallucinated).padStart(4),
  ].join("  ");
}

function printDetails(score: CaseScore) {
  const lines = [
    ...score.falsePositives.map((f) => `    오탐[${f.kind}] "${f.candidate.quote}"`),
    ...score.misses.map((m) => `    누락 ${m.title} — "${m.quote}"`),
    ...score.fieldErrors.map(
      (e) => `    ${e.field === "due" ? "기한" : "담당"} 틀림 ${e.title}: 정답 ${e.expected ?? "없음"} / 추출 ${e.actual ?? "없음"}`,
    ),
    ...score.hallucinated.map((c) => `    환각 인용 "${c.quote}"`),
  ];
  if (lines.length > 0) console.log(`  ${score.caseId}\n${lines.join("\n")}`);
}

const sourceOf = (golden: GoldenCase): JudgeSource & { occurred_at: string; fromConnector?: boolean } => {
  const s = golden.sources[0];
  return {
    text: s.text,
    kind: s.kind,
    occurredAt: new Date(s.occurred_at),
    occurred_at: s.occurred_at,
    participants: s.participants,
    writtenByMe: s.written_by_me,
    fromConnector: s.from_connector,
  };
};

type CaseRun = {
  golden: GoldenCase;
  extracted: ActionCandidate[];
  verified: VerifiedCandidate[];
  dropped: ReturnType<typeof verifyCandidates>["dropped"];
  judged: { candidate: VerifiedCandidate; result: JudgeResult }[] | null;
};

/** 시도 기록의 원가: 응답의 usage.cost 합계, id가 없는(시간 초과) 시도 수, id는 있지만 비용이 없는 시도 수 */
function attemptCost(attempts: LlmAttempt[]): { cost: number; unconfirmed: number; noCost: number } {
  return {
    cost: attempts.reduce((sum, a) => sum + (a.usage?.cost ?? 0), 0),
    unconfirmed: attempts.filter((a) => a.generationId === null).length,
    noCost: attempts.filter((a) => a.generationId !== null && a.usage?.cost === undefined).length,
  };
}

/**
 * 응답의 비용을 generation 조회(generation.ts)로 확인한다 (A51). 생성 직후에는 404라 10초 간격으로 몇 번 더 묻는다.
 * 채점과 상관없는 확인이라 실패해도 eval을 실패로 두지 않는다.
 */
async function reconcileAttempts(apiKey: string, attempts: LlmAttempt[], concurrency: number) {
  const pending = new Map(attempts.filter((a) => a.generationId !== null).map((a) => [a.generationId!, a]));
  const found = new Map<string, Generation>();
  const failures: string[] = [];
  for (let round = 0; round < 6 && pending.size > 0; round++) {
    await new Promise((resolve) => setTimeout(resolve, 10_000));
    await mapLimit([...pending.keys()], concurrency, async (id) => {
      try {
        const lookup = await fetchGeneration({ apiKey }, id);
        if (lookup.status === "found") {
          found.set(id, lookup.generation);
          pending.delete(id);
        }
      } catch (error) {
        failures.push(error instanceof Error ? error.message : String(error));
        pending.delete(id);
      }
    });
  }
  const matched = [...found.entries()].filter(([id, g]) => {
    const cost = attempts.find((a) => a.generationId === id)?.usage?.cost;
    return cost !== undefined && Math.abs(cost - g.costUsd) < 1e-9;
  }).length;
  const providers: Record<string, number> = {};
  for (const g of found.values()) providers[g.provider ?? "?"] = (providers[g.provider ?? "?"] ?? 0) + 1;
  return { asked: found.size + pending.size + failures.length, found: found.size, notYet: pending.size, failed: failures.length, costMatched: matched, providers };
}

/**
 * 실행 eval: E2(다음 단계 고르기, evals/plan)와 E1(초안, evals/draft). 기존 추출 · 물어보기 숫자와 섞지 않고 따로 보고 · 따로 저장한다.
 * 기준(docs 계획 9장): E2 스키마 유효 ≥95% · 단계 종류 일치 ≥90%, E1 전 항목 ≥90% · 지어낸 사실 0 (+ 사람이 25% 표본을 본다).
 */
async function runExecutionEvals(
  llm: LlmConfig,
  jev: JevConfig | null,
  planCases: PlanCase[],
  draftCases: DraftCase[],
  llmConcurrency: number,
  jevConcurrency: number,
): Promise<string[]> {
  if (planCases.length + draftCases.length === 0) return [];
  const errors: string[] = [];
  const allAttempts: LlmAttempt[] = [];
  let jevCost = 0;
  // 다시 물은 시도까지 모두 모은다 (성공이면 결과의 attempts, 실패면 오류에 붙은 기록)
  const complete =
    (attempts: LlmAttempt[]): CompleteJson =>
    (request) =>
      completeJson(llm, request).then(
      (result) => {
        attempts.push(...(result.attempts ?? []));
        return result;
      },
      (error: unknown) => {
        attempts.push(...llmAttemptsOf(error));
        throw error;
      },
    );
  const pct = (n: number, d: number) => `${d ? ((n / d) * 100).toFixed(1) : "-"}% (${n}/${d})`;
  const verdict = (ok: boolean) => (ok ? "통과" : "미달");

  // E2: 다음 단계
  type PlanRun = { golden: PlanCase; result: PlanResult | null; score: PlanScore; attempts: LlmAttempt[]; invalidReason?: string };
  const planRuns = (
    await mapLimit(planCases, llmConcurrency, async (golden): Promise<PlanRun | null> => {
      const attempts: LlmAttempt[] = [];
      try {
        const result = await planNextStep(
          { request: golden.request, now: new Date(golden.now), user: golden.user, context: executionContextOf(golden), history: golden.history },
          complete(attempts),
        );
        allAttempts.push(...attempts);
        return { golden, result, score: scorePlanCase(golden, result.step), attempts };
      } catch (error) {
        allAttempts.push(...attempts);
        // 다시 물어도 형식이 깨진 답(스키마 실패)은 채점에 넣고, 호출 실패(HTTP · 시간 초과)는 오류로 센다
        if (error instanceof LlmError && error.retryable && error.kind !== "timeout") {
          return { golden, result: null, score: scorePlanCase(golden, null), attempts, invalidReason: error.message };
        }
        errors.push(`${golden.id} 다음 단계: ${error instanceof Error ? error.message : String(error)}`);
        return null;
      }
    })
  ).filter((r): r is PlanRun => r !== null);

  if (planRuns.length > 0) {
    console.log(`\nE2 다음 단계 (${PLAN_PROMPT_VERSION}, ${llm.model})`);
    for (const { golden, result, score, invalidReason, attempts } of planRuns) {
      const got = result ? result.step.kind + (result.step.kind === "needs_connection" ? `(${result.step.capability})` : "") : `스키마 실패 (${invalidReason})`;
      const expected = golden.expect.kind + (golden.expect.capability ? `(${golden.expect.capability})` : "");
      const notes = [attempts.length > 1 ? `시도 ${attempts.length}` : null, score.capabilityCorrect === false ? "capability 다름" : null, score.argsPresent ? null : "인자 빔"].filter(Boolean);
      console.log(`  ${score.kindCorrect ? "✓" : "✗"} ${golden.id.padEnd(36)} 기대 ${expected} / 결과 ${got}${notes.length ? ` (${notes.join(", ")})` : ""}`);
      if (!score.kindCorrect && result) console.log(`      이유: ${result.reason}`);
    }
    const t = planTotals(planRuns.map((r) => r.score));
    console.log(`  기대 → 결과   draft  needs  ask  done  실패`);
    for (const [kind, row] of Object.entries(t.confusion)) {
      if (Object.values(row).some((n) => n > 0)) {
        console.log(`  ${kind.padEnd(16)} ${[row.draft, row.needs_connection, row.ask_user, row.done, row.invalid].map((n) => String(n).padStart(5)).join(" ")}`);
      }
    }
    console.log(
      `스키마 유효 ${pct(t.schemaValid, t.n)} · 단계 종류 일치 ${pct(t.kindCorrect, t.n)} · capability ${t.capabilityCorrect}/${t.capabilityJudged}` +
        ` · 다시 물은 케이스 ${planRuns.filter((r) => r.attempts.length > 1).length}건` +
        ` → 기준(≥95% · ≥90%) ${verdict(t.n > 0 && t.schemaValid / t.n >= 0.95 && t.kindCorrect / t.n >= 0.9)}`,
    );
  }

  // E1: 초안
  type DraftRun = { golden: DraftCase; result: DraftResult; score: DraftScore; excludedSlack: number; attempts: LlmAttempt[] };
  const draftRuns = (
    await mapLimit(draftCases, llmConcurrency, async (golden): Promise<DraftRun | null> => {
      const attempts: LlmAttempt[] = [];
      try {
        const context = executionContextOf(golden);
        const result = await writeDraft(
          { request: golden.request, brief: golden.brief, now: new Date(golden.now), user: golden.user, context },
          complete(attempts),
        );
        let answers: Record<DraftJudgeQuestionKey, number> | null = null;
        if (jev) {
          const decision = await decide(jev, { state: draftJudgeState(golden, context.material, result.draft), questions: DRAFT_JUDGE_QUESTIONS });
          jevCost += decision.usage?.cost ?? 0;
          answers = Object.fromEntries(
            Object.keys(DRAFT_JUDGE_QUESTIONS).map((key) => {
              const answer = decision.answers[key];
              return [key, answer.type === "noul" ? answer.noul : 0];
            }),
          ) as Record<DraftJudgeQuestionKey, number>;
        }
        allAttempts.push(...attempts);
        return { golden, result, score: scoreDraftCase(golden, context.material, result.draft, answers), excludedSlack: context.excluded.slack, attempts };
      } catch (error) {
        allAttempts.push(...attempts);
        // E1에는 스키마 기준이 없어(E2와 다름) 다시 물어도 형식이 깨진 초안도 호출 실패로 센다: 다시 돌린다
        errors.push(`${golden.id} 초안: ${error instanceof Error ? error.message : String(error)}`);
        return null;
      }
    })
  ).filter((r): r is DraftRun => r !== null);

  if (draftRuns.length > 0) {
    console.log(`\nE1 초안 (${DRAFT_PROMPT_VERSION}, ${llm.model}${jev ? ` / 채점 ${jev.model} · ${DRAFT_JUDGE_PROMPT_VERSION}` : " / Jev 없음: 기계 대조만"})`);
    const short = { source_facts_only: "원문 사실", recipients_correct: "받는 사람", matches_request: "요청 일치" } as const;
    for (const { golden, score, excludedSlack } of draftRuns) {
      const failed = [
        ...(score.jev ? (Object.keys(short) as DraftJudgeQuestionKey[]).filter((k) => !score.jev![k]).map((k) => `${short[k]} 아니오(${score.probabilities![k].toFixed(2)})`) : []),
        score.slackFree ? null : `Slack 글자 ${score.slackLeaks.length}조각`,
        score.forbidden.length ? `금지어 ${score.forbidden.join(", ")}` : null,
        score.unknownContacts.length ? `자료에 없는 주소 ${score.unknownContacts.join(", ")}` : null,
        score.jev && score.jev.recipients_correct !== score.recipientsMachine ? `받는 사람 기계 대조 ${score.recipientsMachine ? "맞음" : "틀림"}` : null,
      ].filter(Boolean);
      const ok = !score.fabricated && score.slackFree && (!score.jev || Object.values(score.jev).every(Boolean));
      console.log(`  ${ok ? "✓" : "✗"} ${golden.id.padEnd(36)}${excludedSlack ? ` (Slack 근거 ${excludedSlack}개 뺌)` : ""}${failed.length ? ` ${failed.join(" · ")}` : ""}`);
    }
    const t = draftTotals(
      draftRuns.map((r) => r.score),
      draftRuns.map((r) => r.golden),
    );
    const rate = (value: number | null) => (value === null ? "-" : `${(value * 100).toFixed(1)}%`);
    const itemsPass = Object.values(t.rates).every((value) => value === null || value >= 0.9);
    console.log(
      `원문 사실만 ${rate(t.rates.source_facts_only)} · 받는 사람 ${rate(t.rates.recipients_correct)} · 요청 일치 ${rate(t.rates.matches_request)}` +
        ` · Slack 글자 없음 ${rate(t.rates.slack_free)} (Slack 섞인 케이스 ${t.slackCases}건 중) · 지어낸 사실 ${t.fabricated}건` +
        ` · 받는 사람 기계 대조 ${t.recipientsMachine}/${t.n}` +
        ` → 기준(전 항목 ≥90% · 지어낸 사실 0 · Slack 글자 0) ${verdict(itemsPass && t.fabricated === 0 && t.slackLeaked === 0 && jev !== null)}`,
    );
    // 표본은 고른 케이스 전체에서 정한다: 호출이 실패한 케이스가 있어도 표본이 바뀌지 않게
    const sample = humanSample(draftCases).map((g) => g.id);
    console.log(`사람 검토 표본 (25%): ${sample.join(", ")}`);
    for (const run of draftRuns.filter((r) => sample.includes(r.golden.id))) {
      const d = run.result.draft;
      console.log(`\n  ── ${run.golden.id}\n  제목: ${d.title}\n  받는 사람: ${d.to.join(", ") || "(없음)"}\n${d.body.split("\n").map((line) => `  | ${line}`).join("\n")}`);
    }
  }

  const cost = attemptCost(allAttempts);
  console.log(
    `\n실행 eval 비용 약 $${(cost.cost + jevCost).toFixed(4)} (LLM $${cost.cost.toFixed(4)}, 다시 물은 시도 포함 ${allAttempts.length}회 · Jev $${jevCost.toFixed(4)})` +
      ` · generation id 없는 시도 ${cost.unconfirmed}회 · 비용 없는 응답 ${cost.noCost}회`,
  );
  console.log("generation 조회로 비용 확인 중 (생성 직후는 404라 10초씩 기다림)...");
  const reconcile = await reconcileAttempts(llm.apiKey, allAttempts, jevConcurrency).catch((error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }));
  if ("error" in reconcile) console.log(`  조회 실패: ${reconcile.error}`);
  else {
    console.log(
      `  찾음 ${reconcile.found}/${reconcile.asked} · 응답 usage.cost와 같음 ${reconcile.costMatched} · 아직 없음 ${reconcile.notYet} · 조회 오류 ${reconcile.failed}` +
        ` · 공급자 ${Object.entries(reconcile.providers).map(([name, n]) => `${name} ${n}`).join(", ")}`,
    );
  }

  await mkdir(RESULTS_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await writeFile(
    path.join(RESULTS_DIR, `${stamp}-execution-${PLAN_PROMPT_VERSION}-${DRAFT_PROMPT_VERSION}.json`),
    JSON.stringify(
      {
        at: new Date().toISOString(),
        models: { llm: llm.model, judge: jev?.model ?? null },
        promptVersions: { plan: PLAN_PROMPT_VERSION, draft: DRAFT_PROMPT_VERSION, draftJudge: jev ? DRAFT_JUDGE_PROMPT_VERSION : null },
        plan: planRuns.map((r) => ({ id: r.golden.id, expect: r.golden.expect, step: r.result?.step ?? null, reason: r.result?.reason ?? null, score: r.score, attempts: r.attempts })),
        planTotals: planTotals(planRuns.map((r) => r.score)),
        draft: draftRuns.map((r) => ({ id: r.golden.id, draft: r.result.draft, score: r.score, attempts: r.attempts })),
        draftTotals: draftTotals(
          draftRuns.map((r) => r.score),
          draftRuns.map((r) => r.golden),
        ),
        cost: { ...cost, jev: jevCost },
        reconcile,
        errors,
      },
      null,
      2,
    ),
  );
  return errors;
}

/**
 * 대화 상담 골든셋 (evals/consult, B2): 실제 Jev(J1 의도) + LLM(J2 답 · J7 기억 후보)로 respondToMessage를 돌려 채점한다.
 * 기록 읽기(retrieve)는 케이스의 할 일 · 기억 · 원문이다. 동의 확인 · 저장은 하지 않는다 (DB 없음). 마감은 운영 route와 같다. 결과는 evals/results에 따로 남긴다.
 */
async function runConsultEvals(llm: LlmConfig, jev: JevConfig, cases: ConsultCase[], concurrency: number): Promise<string[]> {
  if (cases.length === 0) return [];
  const errors: string[] = [];
  type ConsultRun = { golden: ConsultCase; plan: TurnPlan; score: ConsultScore };
  const runs = (
    await mapLimit(cases, concurrency, async (golden): Promise<ConsultRun | null> => {
      const { input, context, ids } = consultInputOf(golden);
      // 운영 route와 같은 마감 (사용자가 기다리는 요청: LLM은 첫 호출부터 추론량 제한, Jev · LLM 모두 실행 한도 안에)
      const deadline = interactiveDeadline(INTERACTIVE_MAX_DURATION_S);
      try {
        const plan = await respondToMessage(input, {
          decide: (request) => decide({ ...jev, deadline }, request),
          complete: (request) => completeJson({ ...llm, deadline }, request),
          retrieve: async () => context,
          newId: randomUUID,
        });
        return { golden, plan, score: scoreConsultCase(golden, plan, ids) };
      } catch (error) {
        errors.push(`${golden.id} 대화: ${error instanceof Error ? error.message : String(error)}`);
        return null;
      }
    })
  ).filter((r): r is ConsultRun => r !== null);

  console.log(`
대화 상담 (${INTENT_PROMPT_VERSION} · ${CONSULT_PROMPT_VERSION} · ${MEMORY_EXTRACT_PROMPT_VERSION}, LLM ${llm.model} · Jev ${jev.model})`);
  for (const { golden, plan, score } of runs) {
    const failed = Object.entries(score.checks).filter(([, ok]) => ok === false).map(([key]) => key);
    console.log(`  ${score.pass ? "✓" : "✗"} ${golden.id} [${golden.maps_to.join(" ")}] 의도 ${plan.intent.kind}(${plan.intent.confidence.toFixed(2)}) · ${plan.route}${failed.length ? ` · 미달: ${failed.join(", ")}` : ""}`);
  }
  const passed = runs.filter((r) => r.score.pass).length;
  const cost = runs.reduce((n, r) => n + r.plan.summary.cost, 0);
  console.log(`통과 ${passed}/${cases.length} · 호출 실패 ${errors.length}건 · 비용 약 $${cost.toFixed(4)}`);

  await mkdir(RESULTS_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await writeFile(
    path.join(RESULTS_DIR, `${stamp}-consult-${INTENT_PROMPT_VERSION}-${CONSULT_PROMPT_VERSION}-${MEMORY_EXTRACT_PROMPT_VERSION}.json`),
    JSON.stringify(
      {
        at: new Date().toISOString(),
        models: { llm: llm.model, judge: jev.model },
        promptVersions: { intent: INTENT_PROMPT_VERSION, consult: CONSULT_PROMPT_VERSION, memoryExtract: MEMORY_EXTRACT_PROMPT_VERSION },
        cases: runs.map((r) => ({ id: r.golden.id, maps_to: r.golden.maps_to, score: r.score, reply: r.plan.reply.text, segments: r.plan.reply.segments, summary: r.plan.summary })),
        passed,
        total: cases.length,
        errors,
      },
      null,
      2,
    ),
  );
  return errors;
}

async function main() {
  const { values } = parseArgs({
    options: {
      case: { type: "string" },
      tag: { type: "string" },
      labels: { type: "boolean" },
      "no-judge": { type: "boolean" },
      draft: { type: "boolean" },
      plan: { type: "boolean" },
      all: { type: "boolean" },
      consult: { type: "boolean" },
      "llm-concurrency": { type: "string" },
      "jev-concurrency": { type: "string" },
    },
  });
  const llmConcurrency = evalConcurrency(values["llm-concurrency"], DEFAULT_LLM_CONCURRENCY, "llm-concurrency");
  const jevConcurrency = evalConcurrency(values["jev-concurrency"], DEFAULT_JEV_CONCURRENCY, "jev-concurrency");

  const { cases, failed } = await loadGolden();
  const actions = cases.reduce((n, c) => n + c.expected_actions.length, 0);
  const negatives = cases.reduce((n, c) => n + c.must_not_extract.length, 0);
  console.log(`골든셋 ${cases.length + failed}건 · 기대 Action ${actions}개 · 뽑으면 안 되는 문장 ${negatives}개`);
  const ask = await loadAskCases();
  const answerable = ask.cases.filter((c) => !c.expect.unknown).length;
  console.log(`물어보기 골든셋 ${ask.cases.length + ask.failed}건 · 답할 수 있는 질문 ${answerable}개 · 원문에 답이 없는 질문 ${ask.cases.length - answerable}개`);
  const draftSet = await loadExecutionSet(DRAFT_DIR, draftCaseSchema, findDraftLabelErrors);
  const planSet = await loadExecutionSet(PLAN_DIR, planCaseSchema, findPlanLabelErrors);
  const expectedKinds = Object.entries(Object.groupBy(planSet.cases, (c) => c.expect.kind)).map(([kind, list]) => `${kind} ${list?.length ?? 0}`);
  console.log(
    `초안 골든셋(E1) ${draftSet.cases.length + draftSet.failed}건 · Slack 섞인 케이스 ${draftSet.cases.filter((c) => c.tags?.includes("slack")).length}건` +
      ` / 다음 단계 골든셋(E2) ${planSet.cases.length + planSet.failed}건 · 기대 ${expectedKinds.join(" · ")}`,
  );
  const consultSet = await loadExecutionSet(CONSULT_DIR, consultCaseSchema, findConsultLabelErrors);
  const consultMaps = [...new Set(consultSet.cases.flatMap((c) => c.maps_to))].sort();
  console.log(`대화 상담 골든셋(B2) ${consultSet.cases.length + consultSet.failed}건 · 기준 ${consultMaps.join(" ")}`);
  const labelFailures = failed + ask.failed + draftSet.failed + planSet.failed + consultSet.failed;
  if (labelFailures > 0) {
    console.error(`${labelFailures}건에 오류가 있습니다.`);
    process.exit(1);
  }
  if (values.labels) return;

  try {
    process.loadEnvFile(path.join(ROOT, ".env.local"));
  } catch {
    // .env.local이 없으면 환경변수만 쓴다 (CI)
  }
  if (values.consult && (!process.env.OPENROUTER_API_KEY || !process.env.LLM_MODEL || !process.env.JEV_MODEL)) {
    console.log("OPENROUTER_API_KEY · LLM_MODEL · JEV_MODEL 중 없는 값이 있어 대화 상담 채점은 건너뜁니다.");
    return;
  }
  if (!process.env.OPENROUTER_API_KEY || !process.env.LLM_MODEL) {
    console.log("OPENROUTER_API_KEY 또는 LLM_MODEL이 없어 추출 채점은 건너뜁니다.");
    return;
  }
  const llm = llmConfigFromEnv();
  const consultPicked = values.consult || values.all ? consultSet.cases.filter((c) => !values.case || c.id === values.case) : [];
  // 대화 상담은 J1(Jev)이 꼭 필요하다 (--consult는 --no-judge와 상관없이 Jev를 쓴다)
  const runConsult = () => runConsultEvals(llm, jevConfigFromEnv(), consultPicked, llmConcurrency);
  if (values.consult) {
    if (consultPicked.length === 0) {
      console.error(values.case ? `대화 케이스 ${values.case}가 없습니다.` : "채점할 대화 케이스가 없습니다.");
      process.exit(1);
    }
    const consultErrors = await runConsult();
    if (consultErrors.length > 0) {
      console.error(`\n${consultErrors.length}건 호출 실패:\n${consultErrors.map((e) => `  - ${e}`).join("\n")}`);
      process.exit(1);
    }
    return;
  }
  const useJudge = !values["no-judge"];
  const jev = useJudge ? jevConfigFromEnv() : null;

  // 실행 eval(E1 · E2)은 --draft · --plan · --all이거나 --case가 그 세트의 케이스일 때만. 기본 실행(기존 채점)은 그대로다.
  const pick = <T extends { id: string; tags?: string[] }>(items: T[]) =>
    items.filter((c) => (!values.case || c.id === values.case) && (!values.tag || c.tags?.includes(values.tag)));
  const caseIn = (items: { id: string }[]) => Boolean(values.case) && items.some((c) => c.id === values.case);
  const runDraft = Boolean(values.all || values.draft || caseIn(draftSet.cases));
  const runPlan = Boolean(values.all || values.plan || caseIn(planSet.cases));
  const runExisting = values.all ? !caseIn(draftSet.cases) && !caseIn(planSet.cases) : !runDraft && !runPlan;
  const planPicked = runPlan ? pick(planSet.cases) : [];
  const draftPicked = runDraft ? pick(draftSet.cases) : [];
  const runExecution = () => runExecutionEvals(llm, jev, planPicked, draftPicked, llmConcurrency, jevConcurrency);
  const runExecutionOnly = async () => {
    if (planPicked.length + draftPicked.length === 0) {
      console.error(values.tag ? `태그 ${values.tag}가 붙은 실행 케이스가 없습니다.` : "채점할 케이스가 없습니다.");
      process.exit(1);
    }
    const executionErrors = await runExecution();
    if (executionErrors.length > 0) {
      console.error(`\n${executionErrors.length}건 호출 실패:\n${executionErrors.map((e) => `  - ${e}`).join("\n")}`);
      process.exit(1);
    }
  };
  if (!runExisting) return runExecutionOnly();

  // 원문 하나짜리 케이스는 추출 품질을, 여러 원문이 이어지는 케이스는 매칭 · 병합 품질을 본다 (시퀀스는 Jev가 필요).
  const selected = cases.filter((c) => (!values.case || c.id === values.case) && (!values.tag || c.tags?.includes(values.tag)));
  const single = selected.filter((c) => c.sources.length === 1);
  const sequences = selected.filter((c) => c.sources.length > 1);
  const judgePromptVersions = [...new Set(selected.flatMap((golden) => golden.sources.map((source) =>
    judgePromptVersionForSource({ kind: source.kind, writtenByMe: source.written_by_me }),
  )))].sort();
  // 물어보기 케이스에는 태그가 없다: --tag를 주면 건너뛴다.
  const askSelected = values.tag ? [] : ask.cases.filter((c) => !values.case || c.id === values.case);
  // --all인데 기존 세트에 고를 케이스가 없으면(예: --all --tag done-trap) 실행 eval만 돌린다
  if (selected.length === 0 && askSelected.length === 0 && planPicked.length + draftPicked.length > 0) return runExecutionOnly();
  if (selected.length === 0 && askSelected.length === 0) {
    const caseExists = values.case && [...cases, ...ask.cases].some((c) => c.id === values.case);
    console.error(
      values.case && !caseExists
        ? `케이스 ${values.case}가 없습니다.`
        : values.tag
          ? values.case
            ? `케이스 ${values.case}에 태그 ${values.tag}가 없습니다.`
            : `태그 ${values.tag}가 붙은 케이스가 없습니다.`
          : "채점할 케이스가 없습니다.",
    );
    process.exit(1);
  }

  console.log(
    `추출 ${llm.model} · ${EXTRACT_PROMPT_VERSION}` +
      (jev ? ` / 판정 ${jev.model} · ${judgePromptVersions.join(" + ")}` : "") +
      ` · 원문 하나 ${single.length}건` +
      (sequences.length ? ` · 시퀀스 ${sequences.length}건${jev ? "" : " (Jev가 없어 건너뜀)"}` : "") +
      "\n",
  );

  let llmCost = 0;
  let jevCost = 0;
  const errors: string[] = [];
  const judge = (candidate: JudgeCandidate, golden: GoldenCase) =>
    judgeCandidate(candidate, sourceOf(golden), golden.user, (request) => decide(jev!, request)).then((result) => {
      jevCost += result.cost ?? 0;
      return result;
    });

  // 1) 추출 → 기계 검증 → Jev 판정
  const runs = await mapLimit(single, llmConcurrency, async (golden): Promise<CaseRun | null> => {
    const source = sourceOf(golden);
    try {
      const extracted = await extractCandidates(
        {
          text: source.text,
          kind: golden.sources[0].kind,
          occurredAt: source.occurredAt,
          identity: golden.user,
          participants: source.participants,
          writtenByMe: source.writtenByMe,
        },
        (request) => completeJson(llm, request),
      );
      llmCost += extracted.usage?.cost ?? 0;
      const verified = verifyCandidates(extracted.candidates, source);
      const judged = jev
        ? await Promise.all(verified.kept.map(async (candidate) => ({ candidate, result: await judge(candidate, golden) })))
        : null;
      return { golden, extracted: extracted.candidates, verified: verified.kept, dropped: verified.dropped, judged };
    } catch (error) {
      errors.push(`${golden.id}: ${error instanceof Error ? error.message : String(error)}`);
      return null;
    }
  });
  const done = runs.filter((r): r is CaseRun => r !== null);

  // 원문 하나 채점은 새 약속(commitment)만 본다. 변화 발언(update · completion · cancellation)은 시퀀스 채점에서 본다.
  const commitments = <T extends { signal: string }>(items: T[]) => items.filter((c) => c.signal === "commitment");
  // autoOnly: "자동만" 단계는 확인 요청이 맞는 정답(needs_review)을 다르게 센다 (score.ts).
  const stages: { label: string; pick: (run: CaseRun) => ScoredCandidate[]; autoOnly?: boolean }[] = [
    { label: "추출만", pick: (r) => commitments(r.extracted) },
    { label: "+ 기계 검증", pick: (r) => commitments(r.verified) },
    ...(jev
      ? [
          {
            label: "+ Jev (자동+확인)",
            pick: (r: CaseRun) => commitments(r.judged!.filter((j) => j.result.decision !== "reject").map((j) => withJudgeOwnership(j.candidate, j.result))),
          },
          {
            label: "+ Jev (자동만)",
            pick: (r: CaseRun) => commitments(r.judged!.filter((j) => j.result.decision === "auto").map((j) => withJudgeOwnership(j.candidate, j.result))),
            autoOnly: true,
          },
        ]
      : []),
  ];
  const finalStage = stages[jev ? 2 : 1];
  const finalScores = done.map((r) => scoreCase(r.golden, finalStage.pick(r)));

  console.log(`케이스별 (${finalStage.label})`);
  finalScores.forEach((s) =>
    console.log(
      `  ${s.caseId.padEnd(36)} 맞음 ${s.truePositives} · 오탐 ${s.falsePositives.length} · 누락 ${s.misses.length}` +
        (s.fieldErrors.length ? ` · 필드 오류 ${s.fieldErrors.length}` : ""),
    ),
  );
  console.log(`\n틀린 것 (${finalStage.label})`);
  finalScores.forEach(printDetails);

  if (jev) {
    const rejectedGood = done.flatMap((r) =>
      r.judged!.filter((j) => j.candidate.signal === "commitment" && j.result.decision === "reject" && scoreCase(r.golden, [j.candidate]).truePositives > 0)
        .map((j) => `    ${r.golden.id}: "${j.candidate.quote}" (${j.result.reasons.join(", ")})`),
    );
    if (rejectedGood.length > 0) console.log(`\nJev가 기각했지만 정답이었던 것\n${rejectedGood.join("\n")}`);
  }

  const corrected = done.flatMap((r) => r.verified.filter((c) => c.due_check === "corrected"));
  const droppedBy = (reason: "QUOTE_NOT_FOUND" | "QUOTED_HISTORY") => done.reduce((n, r) => n + r.dropped.filter((d) => d.reason === reason).length, 0);
  console.log(`\n기계 검증: 환각 인용 폐기 ${droppedBy("QUOTE_NOT_FOUND")}건 · 인용된 옛 메일 속 후보 폐기 ${droppedBy("QUOTED_HISTORY")}건 · 기한 코드 보정 ${corrected.length}건`);
  corrected.forEach((c) => console.log(`    "${c.due_text}": 모델 ${c.model_due ?? "없음"} → 코드 ${c.due}`));

  const header = ["단계".padEnd(16), "precision", "recall", "담당", "남의 일→me", "기한", "맞음/오탐/누락", "환각"].join("  ");
  console.log(`\n${header}`);
  const stageTotals = stages.map((stage) => {
    const t = totals(done.map((r) => scoreCase(r.golden, stage.pick(r), { autoOnly: stage.autoOnly })));
    console.log(summaryRow(stage.label, t));
    if (t.falsePositivesByKind.REVIEW_EXPECTED > 0) console.log(`  └ 확인 요청이 맞는데 자동 반영 ${t.falsePositivesByKind.REVIEW_EXPECTED}건`);
    return { stage: stage.label, totals: t };
  });
  if (new Set(done.map((r) => r.golden.origin)).size > 1) {
    for (const origin of ["real", "synthetic"] as const) {
      const subset = done.filter((r) => r.golden.origin === origin);
      console.log(summaryRow(`${origin === "real" ? "실제" : "합성"} 원문`, totals(subset.map((r) => scoreCase(r.golden, finalStage.pick(r))))));
    }
  }
  // 원문 종류 묶음별 (예: #slack). 회의록 숫자와 섞지 않고 따로 본다.
  const tagsOf = (items: { golden: GoldenCase }[]) => [...new Set(items.flatMap((r) => r.golden.tags ?? []))].sort();
  for (const tag of tagsOf(done)) {
    const subset = done.filter((r) => r.golden.tags?.includes(tag));
    console.log(summaryRow(`#${tag}`, totals(subset.map((r) => scoreCase(r.golden, finalStage.pick(r))))));
  }

  // 2) Jev를 사람 라벨과 비교: 정답 Action과 함정 문장을 그대로 후보로 만들어 묻는다.
  let judgedItems: JudgedItem[] = [];
  if (jev) {
    const items = single.flatMap((golden) => labeledItems(golden).map((item) => ({ item, golden })));
    const judgedOrNull = await mapLimit(items, jevConcurrency, async ({ item, golden }) => {
      try {
        return { ...item, result: await judge(item.candidate, golden) };
      } catch (error) {
        errors.push(`${item.caseId} 라벨 판정: ${error instanceof Error ? error.message : String(error)}`);
        return null;
      }
    });
    judgedItems = judgedOrNull.filter((j): j is JudgedItem => j !== null);

    console.log(`\nJev 사람 라벨 일치율 (정답 Action + 함정 문장 ${judgedItems.length}개)`);
    for (const a of agreement(judgedItems)) console.log(`  ${a.question.padEnd(18)} ${pct(a.rate)}  (${a.agree}/${a.n})`);

    console.log(`\n판정 분포 (임계값: 자동 ≥ ${JUDGE_THRESHOLDS.accept}, 기각 < ${JUDGE_THRESHOLDS.reject})`);
    console.log(`  ${"라벨".padEnd(14)} 자동  확인  기각`);
    for (const [kind, row] of Object.entries(decisionTable(judgedItems))) {
      const n = row.auto + row.confirm + row.reject;
      if (n > 0) console.log(`  ${kind.padEnd(14)} ${String(row.auto).padStart(4)}  ${String(row.confirm).padStart(4)}  ${String(row.reject).padStart(4)}`);
    }

    for (const question of ["is_my_commitment", "is_actionable", "already_done"] as const) {
      console.log(`\n보정 표: ${question} (확률 구간 · 건수 · 평균 확률 · 실제 비율)`);
      for (const bin of calibration(judgedItems, question)) {
        console.log(`  ${bin.from.toFixed(1)}~${bin.to.toFixed(1)}  ${String(bin.n).padStart(3)}  ${pct(bin.meanProbability)}  ${pct(bin.actualRate)}`);
      }
    }
  }

  // 3) 시퀀스: 원문을 시간순으로 파이프라인 + 병합에 넣고, 남은 Action을 정답과 비교한다.
  type SequenceRun = { golden: GoldenCase; score: SequenceScore; finals: FinalAction[]; outcomes: (MergeOutcome & { source: string })[] };
  let sequenceRuns: SequenceRun[] = [];
  let sequenceCost = 0;
  if (jev && sequences.length > 0) {
    const embedConfig = embedConfigFromEnv();
    const runsOrNull = await mapLimit(sequences, llmConcurrency, async (golden): Promise<SequenceRun | null> => {
      try {
        const store = new InMemoryActionStore();
        let claimSeq = 0;
        const mergeDeps = {
          embed: async (texts: string[]) => (await embed(embedConfig, texts)).vectors,
          decide: (request: Parameters<typeof decide>[1]) => decide(jev, request),
          newId: () => `c${++claimSeq}`,
        };
        const outcomes: SequenceRun["outcomes"] = [];
        for (const s of [...golden.sources].sort((a, b) => a.occurred_at.localeCompare(b.occurred_at))) {
          const occurredAt = new Date(s.occurred_at);
          const result = await runPipeline(
            { text: s.text, kind: s.kind, occurredAt, identity: golden.user, participants: s.participants, writtenByMe: s.written_by_me, fromConnector: s.from_connector },
            { complete: (request) => completeJson(llm, request), decide: (request) => decide(jev, request) },
          );
          sequenceCost += result.summary.cost;
          const merged = await mergeJudged(store, result.judged, { id: s.id, text: s.text, kind: s.kind, occurredAt }, golden.user, mergeDeps);
          outcomes.push(...merged.map((o) => ({ ...o, source: s.id })));
        }
        const finals: FinalAction[] = store.all().map((a) => {
          const state = resolveAction(a.claims);
          // 확인 요청 여부는 앱과 같은 계산(projectAction: 저장된 판정 · 병합 이유 + 담당 · 필드 확인)으로 본다.
          const { confirm_reasons } = projectAction(a.title, a.claims, a.confirmReasons);
          return {
            id: a.id,
            title: a.title,
            quotes: a.evidence.map((e) => e.quote),
            due: state.due.value,
            status: state.status.value,
            owner: state.owner.value,
            confirmReasons: confirm_reasons,
          };
        });
        return { golden, score: scoreSequence(golden, finals), finals, outcomes };
      } catch (error) {
        errors.push(`${golden.id} 시퀀스: ${error instanceof Error ? error.message : String(error)}`);
        return null;
      }
    });
    sequenceRuns = runsOrNull.filter((r): r is SequenceRun => r !== null);

    console.log("\n시퀀스 (여러 원문 → 매칭 · 병합 · 진실 판정)");
    for (const { score, finals } of sequenceRuns) {
      console.log(`  ${score.caseId.padEnd(36)} 맞음 ${score.correct}/${score.expected} · Action ${finals.length}개`);
      const lines = [
        ...score.splits.map((x) => `    갈라짐 ${x.title} (Action ${x.actions}개)`),
        ...score.overMerged.map((x) => `    잘못 합침 ${x.title}`),
        ...score.misses.map((x) => `    누락 ${x.title}`),
        ...score.extras.map((x) => `    오탐[${x.kind}]${x.pending ? "(확인 요청)" : "(자동)"} ${x.title}`),
        ...score.fieldErrors.map((x) => `    ${x.field} 틀림 ${x.title}: 정답 ${x.expected ?? "없음"} / 결과 ${x.actual ?? "없음"}`),
        ...score.pendingReview.map((x) => `    확인 요청 남음 ${x.title} (${x.reasons.join(", ")})`),
      ];
      if (lines.length) console.log(lines.join("\n"));
    }
    const mergeLine = (label: string, runs: SequenceRun[]) => {
      const t = sequenceTotals(runs.map((r) => r.score));
      return (
        `${label} ${pct(t.accuracy)} (${t.correct}/${t.expected}) · 갈라짐 ${t.splits} · 잘못 합침 ${t.overMerged} · 누락 ${t.misses}` +
        ` · 오탐 ${t.extras}(자동 ${t.extrasAuto}) · 필드 오류 ${t.fieldErrors} · 확인 요청 남음 ${t.pendingReview}`
      );
    };
    console.log(`\n${mergeLine("병합 정확도", sequenceRuns)}`);
    for (const tag of tagsOf(sequenceRuns)) {
      console.log(`  ${mergeLine(`#${tag}`, sequenceRuns.filter((r) => r.golden.tags?.includes(tag)))}`);
    }
  }

  // 4) 물어보기: 케이스의 Action · 원문을 검색 결과로 주고(검색 자체는 DB 테스트가 본다) 답 · 인용 검증 · 모름을 채점한다.
  //    LLM은 앱의 질문(v1/ask/route.ts, 실행 한도 INTERACTIVE_MAX_DURATION_S)과 같게 마감을 두고 첫 호출부터 추론량을 제한한다.
  let askCost = 0;
  // 호출이 실패한 질문(시간 초과 포함): 통과하지 못한 것으로 세어 분모에 넣는다 (앱에서도 답을 받지 못한다)
  const askFailed: { golden: AskCase; error: string; deadline: boolean }[] = [];
  const askRuns = (
    await mapLimit(askSelected, llmConcurrency, async (golden): Promise<{ golden: AskCase; result: AskResult; score: AskScore } | null> => {
      const deadline = interactiveDeadline(INTERACTIVE_MAX_DURATION_S);
      try {
        const result = await answerQuestion(
          golden.question,
          {
            embed: async (texts) => texts.map(() => []),
            retrieve: async () => askContextOf(golden),
            complete: (request) => completeJson({ ...llm, deadline }, request),
          },
          new Date(golden.asked_at),
        );
        askCost += result.summary.cost;
        return { golden, result, score: scoreAskCase(golden, result) };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        errors.push(`${golden.id} 물어보기: ${message}`);
        askFailed.push({ golden, error: message, deadline: error instanceof DeadlineExceededError });
        return null;
      }
    })
  ).filter((r): r is { golden: AskCase; result: AskResult; score: AskScore } => r !== null);
  if (askRuns.length + askFailed.length > 0) {
    console.log(`\n물어보기 (${ASK_PROMPT_VERSION})`);
    for (const { golden, result, score } of askRuns) {
      const expected = golden.expect.unknown ? "모름" : "답함";
      const got = result.unknown ? "모름" : `답함 · 인용 ${score.citations}`;
      const notes = [
        score.unknownCorrect ? null : "모름 판정 틀림",
        score.citedExpected === false ? "기대 원문 인용 없음" : null,
        score.answerContains === false ? "답에 기대한 말 없음" : null,
        score.answerExcludes === false ? "답에 들어가면 안 되는 말 있음" : null,
        score.dropped > 0 ? `가짜 인용 폐기 ${score.dropped}` : null,
      ].filter(Boolean);
      console.log(`  ${score.pass ? "✓" : "✗"} ${golden.id.padEnd(28)} 기대 ${expected} / 결과 ${got}${notes.length ? ` (${notes.join(", ")})` : ""}`);
    }
    for (const { golden, error } of askFailed) console.log(`  ✗ ${golden.id.padEnd(28)} 호출 실패 (${error})`);
    const passed = askRuns.filter((r) => r.score.pass).length;
    const answerableRuns = askRuns.filter((r) => !r.golden.expect.unknown);
    const unknownRuns = askRuns.filter((r) => r.golden.expect.unknown);
    const answerableFailed = askFailed.filter((f) => !f.golden.expect.unknown).length;
    const timedOut = askFailed.filter((f) => f.deadline || f.error.includes("시간 초과")).length;
    const rate = (n: number, d: number) => `${pct(d ? n / d : null)} (${n}/${d})`;
    console.log(
      `통과 ${rate(passed, askRuns.length + askFailed.length)} · 호출 실패 ${askFailed.length}건(마감 · 시간 초과 ${timedOut})` +
        ` · 답할 수 있는 질문에 검증된 인용으로 답함 ${rate(answerableRuns.filter((r) => !r.result.unknown && r.score.citedExpected).length, answerableRuns.length + answerableFailed)}` +
        ` · 답이 없는 질문에 모른다고 함 ${rate(unknownRuns.filter((r) => r.result.unknown).length, unknownRuns.length + askFailed.length - answerableFailed)}` +
        ` · 가짜 인용 폐기 ${askRuns.reduce((n, r) => n + r.score.dropped, 0)}건`,
    );
  }

  console.log(
    `\n비용 약 $${(llmCost + jevCost + sequenceCost + askCost).toFixed(3)} (추출 $${llmCost.toFixed(3)} · Jev $${jevCost.toFixed(4)} · 시퀀스 $${sequenceCost.toFixed(3)} · 물어보기 $${askCost.toFixed(3)})`,
  );

  // 결과를 남겨 프롬프트 · 임계값을 바꾼 전후를 비교한다 (evals/results는 커밋하지 않음).
  await mkdir(RESULTS_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await writeFile(
    path.join(RESULTS_DIR, `${stamp}-${EXTRACT_PROMPT_VERSION}${jev ? `-${judgePromptVersions.join("+")}` : ""}.json`),
    JSON.stringify(
      {
        at: new Date().toISOString(),
        models: { extract: llm.model, judge: jev?.model ?? null },
        promptVersions: { extract: EXTRACT_PROMPT_VERSION, judge: jev ? judgePromptVersions : null, ask: ASK_PROMPT_VERSION },
        thresholds: jev ? JUDGE_THRESHOLDS : null,
        stages: stageTotals,
        judgeAgreement: jev ? agreement(judgedItems) : null,
        tag: values.tag ?? null,
        sequences: sequenceRuns.map((r) => ({ id: r.golden.id, tags: r.golden.tags ?? [], score: r.score, finals: r.finals, outcomes: r.outcomes })),
        cases: done.map((r) => ({ id: r.golden.id, origin: r.golden.origin, tags: r.golden.tags ?? [], extracted: r.extracted, judged: r.judged ?? r.verified })),
        judgedLabels: judgedItems.map((j) => ({ caseId: j.caseId, kind: j.kind, quote: j.candidate.quote, labels: j.labels, result: j.result })),
        ask: askRuns.map((r) => ({
          id: r.golden.id,
          score: r.score,
          answer: r.result.answer,
          unknown: r.result.unknown,
          citations: r.result.citations,
          reasoningLimited: r.result.summary.reasoningLimited,
        })),
        errors,
      },
      null,
      2,
    ),
  );

  if (runDraft || runPlan) errors.push(...(await runExecution()));
  // 대화 상담은 J1(Jev)이 꼭 필요하다: --no-judge면 건너뛴다
  if (values.all && !values["no-judge"]) errors.push(...(await runConsult()));
  else if (values.all) console.log("--no-judge라 대화 상담 채점은 건너뜁니다 (J1 의도 분류에 Jev가 필요).");

  if (errors.length > 0) {
    console.error(`\n${errors.length}건 호출 실패:\n${errors.map((e) => `  - ${e}`).join("\n")}`);
    process.exit(1);
  }
}

main();
