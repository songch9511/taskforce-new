// 골든셋으로 추출 품질을 평가한다: npm run eval
//   npm run eval                 라벨 검사 + (키가 있으면) 추출 채점
//   npm run eval -- --case <id>  한 케이스만
//   npm run eval -- --labels     라벨 검사만 (CI처럼 키가 없을 때와 같음)
// 키(OPENROUTER_API_KEY, LLM_MODEL)는 환경변수나 .env.local에서 읽는다.
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";

import { completeJson, llmConfigFromEnv } from "../src/lib/ai/llm";
import { EXTRACT_PROMPT_VERSION } from "../src/lib/ai/prompts/extract";
import { findLabelErrors, goldenCaseSchema, type GoldenCase } from "../src/lib/eval/golden";
import { scoreCase, totals, type CaseScore, type Totals } from "../src/lib/eval/score";
import { extractCandidates } from "../src/lib/pipeline/extract";

const ROOT = path.resolve(import.meta.dirname, "..");
const GOLDEN_DIR = path.join(ROOT, "evals/golden");
const RESULTS_DIR = path.join(ROOT, "evals/results");
const CONCURRENCY = 4;

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

const pct = (value: number | null) => (value === null ? "  -  " : `${(value * 100).toFixed(1).padStart(5)}%`);

function summaryRow(label: string, t: Totals): string {
  return [
    label.padEnd(10),
    String(t.cases).padStart(4),
    pct(t.precision),
    pct(t.recall),
    pct(t.ownerAccuracy),
    pct(t.dueAccuracy),
    `${t.truePositives}/${t.falsePositives}/${t.misses}`.padStart(10),
    String(t.hallucinated).padStart(4),
  ].join("  ");
}

function printDetails(score: CaseScore) {
  const lines = [
    ...score.falsePositives.map((f) => `    오탐[${f.kind}] "${f.candidate.quote}"`),
    ...score.misses.map((m) => `    누락 ${m.title} — "${m.quote}"`),
    ...score.fieldErrors.map((e) => `    ${e.field === "due" ? "기한" : "담당"} 틀림 ${e.title}: 정답 ${e.expected ?? "없음"} / 추출 ${e.actual ?? "없음"}`),
    ...score.hallucinated.map((c) => `    환각 인용 "${c.quote}"`),
  ];
  if (lines.length > 0) console.log(`  ${score.caseId}\n${lines.join("\n")}`);
}

async function main() {
  const { values } = parseArgs({ options: { case: { type: "string" }, labels: { type: "boolean" } } });

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
  const config = llmConfigFromEnv();

  // Phase 1은 원문 하나짜리 케이스만 채점한다. 여러 원문이 이어지는 케이스는 Phase 2(매칭)에서 채점한다.
  const selected = cases.filter((c) => !values.case || c.id === values.case);
  const single = selected.filter((c) => c.sources.length === 1);
  const skipped = selected.length - single.length;
  if (single.length === 0) {
    console.error(values.case ? `원문 하나짜리 케이스 ${values.case}가 없습니다.` : "채점할 케이스가 없습니다.");
    process.exit(1);
  }

  console.log(`모델 ${config.model} · 프롬프트 ${EXTRACT_PROMPT_VERSION} · ${single.length}건 채점${skipped ? ` (시퀀스 ${skipped}건은 Phase 2)` : ""}\n`);

  let cost = 0;
  const errors: string[] = [];
  const runs = await mapLimit(single, CONCURRENCY, async (golden) => {
    const source = golden.sources[0];
    try {
      const result = await extractCandidates(
        { text: source.text, kind: source.kind, occurredAt: new Date(source.occurred_at), userName: golden.user.name },
        (request) => completeJson(config, request),
      );
      cost += result.usage?.cost ?? 0;
      return { golden, candidates: result.candidates, score: scoreCase(golden, result.candidates) };
    } catch (error) {
      errors.push(`${golden.id}: ${error instanceof Error ? error.message : String(error)}`);
      return null;
    }
  });

  const done = runs.filter((r) => r !== null);
  const scores = done.map((r) => r.score);

  console.log("케이스별");
  for (const run of done) {
    const s = run.score;
    console.log(
      `  ${run.golden.id.padEnd(36)} 맞음 ${s.truePositives} · 오탐 ${s.falsePositives.length} · 누락 ${s.misses.length}` +
        (s.fieldErrors.length ? ` · 필드 오류 ${s.fieldErrors.length}` : ""),
    );
  }

  console.log("\n틀린 것");
  scores.forEach(printDetails);

  const header = ["구분".padEnd(10), "건수", "precision", "recall", "담당 정확도", "기한 정확도", "맞음/오탐/누락", "환각"].join("  ");
  const overall = totals(scores);
  console.log(`\n${header}`);
  console.log(summaryRow("전체", overall));
  for (const origin of ["real", "synthetic"] as const) {
    const subset = done.filter((r) => r.golden.origin === origin).map((r) => r.score);
    if (subset.length > 0) console.log(summaryRow(origin === "real" ? "실제 원문" : "합성 원문", totals(subset)));
  }
  const kinds = Object.entries(overall.falsePositivesByKind).filter(([, n]) => n > 0);
  if (kinds.length > 0) console.log(`\n오탐 사유: ${kinds.map(([k, n]) => `${k} ${n}`).join(" · ")}`);
  console.log(`비용 약 $${cost.toFixed(3)}`);

  // 결과를 남겨 프롬프트를 바꾼 전후를 비교한다 (evals/results는 커밋하지 않음).
  await mkdir(RESULTS_DIR, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  await writeFile(
    path.join(RESULTS_DIR, `${stamp}-${EXTRACT_PROMPT_VERSION}.json`),
    JSON.stringify(
      {
        at: new Date().toISOString(),
        model: config.model,
        promptVersion: EXTRACT_PROMPT_VERSION,
        totals: overall,
        cases: done.map((r) => ({ id: r.golden.id, origin: r.golden.origin, candidates: r.candidates, score: r.score })),
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
