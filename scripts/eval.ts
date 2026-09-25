// 골든셋으로 추출 품질을 평가한다: npm run eval
//   npm run eval                  라벨 검사 + (키가 있으면) 추출 → 기계 검증 → Jev 판정 채점
//   npm run eval -- --case <id>   한 케이스만
//   npm run eval -- --no-judge    Jev 없이 추출 · 기계 검증만
//   npm run eval -- --labels      라벨 검사만 (CI처럼 키가 없을 때와 같음)
// 키(OPENROUTER_API_KEY, LLM_MODEL, JEV_MODEL)는 환경변수나 .env.local에서 읽는다.
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";

import { decide, jevConfigFromEnv } from "../src/lib/ai/jev";
import { completeJson, llmConfigFromEnv } from "../src/lib/ai/llm";
import { EXTRACT_PROMPT_VERSION } from "../src/lib/ai/prompts/extract";
import { JUDGE_PROMPT_VERSION } from "../src/lib/ai/prompts/judge";
import { findLabelErrors, goldenCaseSchema, type GoldenCase } from "../src/lib/eval/golden";
import { agreement, calibration, decisionTable, labeledItems, type JudgedItem } from "../src/lib/eval/judge-metrics";
import { scoreCase, totals, type CaseScore, type ScoredCandidate, type Totals } from "../src/lib/eval/score";
import { extractCandidates, type ActionCandidate } from "../src/lib/pipeline/extract";
import { judgeCandidate, type JudgeResult, type JudgeSource } from "../src/lib/pipeline/judge";
import { JUDGE_THRESHOLDS } from "../src/lib/pipeline/judge.config";
import { verifyCandidates, type VerifiedCandidate } from "../src/lib/pipeline/verify";

const ROOT = path.resolve(import.meta.dirname, "..");
const GOLDEN_DIR = path.join(ROOT, "evals/golden");
const RESULTS_DIR = path.join(ROOT, "evals/results");
const LLM_CONCURRENCY = 4;
const JEV_CONCURRENCY = 8;

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

const pct = (value: number | null) => (value === null ? "    -" : `${(value * 100).toFixed(1).padStart(5)}%`);

function summaryRow(label: string, t: Totals): string {
  return [
    label.padEnd(16),
    pct(t.precision),
    pct(t.recall),
    pct(t.ownerAccuracy),
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

const sourceOf = (golden: GoldenCase): JudgeSource & { occurred_at: string } => {
  const s = golden.sources[0];
  return { text: s.text, kind: s.kind, occurredAt: new Date(s.occurred_at), occurred_at: s.occurred_at, participants: s.participants };
};

type CaseRun = {
  golden: GoldenCase;
  extracted: ActionCandidate[];
  verified: VerifiedCandidate[];
  dropped: number;
  judged: { candidate: VerifiedCandidate; result: JudgeResult }[] | null;
};

async function main() {
  const { values } = parseArgs({
    options: { case: { type: "string" }, labels: { type: "boolean" }, "no-judge": { type: "boolean" } },
  });

  const { cases, failed } = await loadGolden();
  const actions = cases.reduce((n, c) => n + c.expected_actions.length, 0);
  const negatives = cases.reduce((n, c) => n + c.must_not_extract.length, 0);
  console.log(`골든셋 ${cases.length + failed}건 · 기대 Action ${actions}개 · 뽑으면 안 되는 문장 ${negatives}개`);
  if (failed > 0) {
    console.error(`${failed}건에 오류가 있습니다.`);
    process.exit(1);
  }
  if (values.labels) return;

  try {
    process.loadEnvFile(path.join(ROOT, ".env.local"));
  } catch {
    // .env.local이 없으면 환경변수만 쓴다 (CI)
  }
  if (!process.env.OPENROUTER_API_KEY || !process.env.LLM_MODEL) {
    console.log("OPENROUTER_API_KEY 또는 LLM_MODEL이 없어 추출 채점은 건너뜁니다.");
    return;
  }
  const llm = llmConfigFromEnv();
  const useJudge = !values["no-judge"];
  const jev = useJudge ? jevConfigFromEnv() : null;

  // Phase 1은 원문 하나짜리 케이스만 채점한다. 여러 원문이 이어지는 케이스는 Phase 2(매칭)에서 채점한다.
  const selected = cases.filter((c) => !values.case || c.id === values.case);
  const single = selected.filter((c) => c.sources.length === 1);
  const skipped = selected.length - single.length;
  if (single.length === 0) {
    console.error(values.case ? `원문 하나짜리 케이스 ${values.case}가 없습니다.` : "채점할 케이스가 없습니다.");
    process.exit(1);
  }

  console.log(
    `추출 ${llm.model} · ${EXTRACT_PROMPT_VERSION}` +
      (jev ? ` / 판정 ${jev.model} · ${JUDGE_PROMPT_VERSION}` : "") +
      ` · ${single.length}건 채점${skipped ? ` (시퀀스 ${skipped}건은 Phase 2)` : ""}\n`,
  );

  let llmCost = 0;
  let jevCost = 0;
  const errors: string[] = [];
  const judge = (candidate: { title: string; quote: string; due_text: string | null }, golden: GoldenCase) =>
    judgeCandidate(candidate, sourceOf(golden), golden.user, (request) => decide(jev!, request)).then((result) => {
      jevCost += result.cost ?? 0;
      return result;
    });

  // 1) 추출 → 기계 검증 → Jev 판정
  const runs = await mapLimit(single, LLM_CONCURRENCY, async (golden): Promise<CaseRun | null> => {
    const source = sourceOf(golden);
    try {
      const extracted = await extractCandidates(
        {
          text: source.text,
          kind: golden.sources[0].kind,
          occurredAt: source.occurredAt,
          identity: golden.user,
          participants: source.participants,
        },
        (request) => completeJson(llm, request),
      );
      llmCost += extracted.usage?.cost ?? 0;
      const verified = verifyCandidates(extracted.candidates, source);
      const judged = jev
        ? await Promise.all(verified.kept.map(async (candidate) => ({ candidate, result: await judge(candidate, golden) })))
        : null;
      return { golden, extracted: extracted.candidates, verified: verified.kept, dropped: verified.dropped.length, judged };
    } catch (error) {
      errors.push(`${golden.id}: ${error instanceof Error ? error.message : String(error)}`);
      return null;
    }
  });
  const done = runs.filter((r): r is CaseRun => r !== null);

  const stages: { label: string; pick: (run: CaseRun) => ScoredCandidate[] }[] = [
    { label: "추출만", pick: (r) => r.extracted },
    { label: "+ 기계 검증", pick: (r) => r.verified },
    ...(jev
      ? [
          { label: "+ Jev (자동+확인)", pick: (r: CaseRun) => r.judged!.filter((j) => j.result.decision !== "reject").map((j) => j.candidate) },
          { label: "+ Jev (자동만)", pick: (r: CaseRun) => r.judged!.filter((j) => j.result.decision === "auto").map((j) => j.candidate) },
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
      r.judged!.filter((j) => j.result.decision === "reject" && scoreCase(r.golden, [j.candidate]).truePositives > 0)
        .map((j) => `    ${r.golden.id}: "${j.candidate.quote}" (${j.result.reasons.join(", ")})`),
    );
    if (rejectedGood.length > 0) console.log(`\nJev가 기각했지만 정답이었던 것\n${rejectedGood.join("\n")}`);
  }

  const corrected = done.flatMap((r) => r.verified.filter((c) => c.due_check === "corrected"));
  const dropped = done.reduce((n, r) => n + r.dropped, 0);
  console.log(`\n기계 검증: 환각 인용 폐기 ${dropped}건 · 기한 코드 보정 ${corrected.length}건`);
  corrected.forEach((c) => console.log(`    "${c.due_text}": 모델 ${c.model_due ?? "없음"} → 코드 ${c.due}`));

  const header = ["단계".padEnd(16), "precision", "recall", "담당", "기한", "맞음/오탐/누락", "환각"].join("  ");
  console.log(`\n${header}`);
  const stageTotals = stages.map((stage) => {
    const t = totals(done.map((r) => scoreCase(r.golden, stage.pick(r))));
    console.log(summaryRow(stage.label, t));
    return { stage: stage.label, totals: t };
  });
  if (new Set(done.map((r) => r.golden.origin)).size > 1) {
    for (const origin of ["real", "synthetic"] as const) {
      const subset = done.filter((r) => r.golden.origin === origin);
      console.log(summaryRow(`${origin === "real" ? "실제" : "합성"} 원문`, totals(subset.map((r) => scoreCase(r.golden, finalStage.pick(r))))));
    }
  }

  // 2) Jev를 사람 라벨과 비교: 정답 Action과 함정 문장을 그대로 후보로 만들어 묻는다.
  let judgedItems: JudgedItem[] = [];
  if (jev) {
    const items = single.flatMap((golden) => labeledItems(golden).map((item) => ({ item, golden })));
    const judgedOrNull = await mapLimit(items, JEV_CONCURRENCY, async ({ item, golden }) => {
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

  console.log(`\n비용 약 $${(llmCost + jevCost).toFixed(3)} (추출 $${llmCost.toFixed(3)} · Jev $${jevCost.toFixed(4)})`);

  // 결과를 남겨 프롬프트 · 임계값을 바꾼 전후를 비교한다 (evals/results는 커밋하지 않음).
  await mkdir(RESULTS_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await writeFile(
    path.join(RESULTS_DIR, `${stamp}-${EXTRACT_PROMPT_VERSION}${jev ? `-${JUDGE_PROMPT_VERSION}` : ""}.json`),
    JSON.stringify(
      {
        at: new Date().toISOString(),
        models: { extract: llm.model, judge: jev?.model ?? null },
        promptVersions: { extract: EXTRACT_PROMPT_VERSION, judge: jev ? JUDGE_PROMPT_VERSION : null },
        thresholds: jev ? JUDGE_THRESHOLDS : null,
        stages: stageTotals,
        judgeAgreement: jev ? agreement(judgedItems) : null,
        cases: done.map((r) => ({ id: r.golden.id, origin: r.golden.origin, extracted: r.extracted, judged: r.judged ?? r.verified })),
        judgedLabels: judgedItems.map((j) => ({ caseId: j.caseId, kind: j.kind, quote: j.candidate.quote, labels: j.labels, result: j.result })),
        errors,
      },
      null,
      2,
    ),
  );

  if (errors.length > 0) {
    console.error(`\n${errors.length}건 호출 실패:\n${errors.map((e) => `  - ${e}`).join("\n")}`);
    process.exit(1);
  }
}

main();
