// 골든셋으로 추출 품질을 평가한다: npm run eval
// Phase 0에서는 골든셋 형식과 라벨만 검증한다. 추출기는 Phase 1에서 붙인다.
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { findLabelErrors, goldenCaseSchema } from "../src/lib/eval/golden";

const GOLDEN_DIR = path.resolve(import.meta.dirname, "../evals/golden");

async function main() {
  const files = (await readdir(GOLDEN_DIR)).filter((f) => f.endsWith(".json")).sort();
  let failed = 0;
  let actions = 0;
  let negatives = 0;

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
    actions += parsed.data.expected_actions.length;
    negatives += parsed.data.must_not_extract.length;
  }

  console.log(`골든셋 ${files.length}건 · 기대 Action ${actions}개 · 뽑으면 안 되는 문장 ${negatives}개`);
  if (failed > 0) {
    console.error(`${failed}건에 오류가 있습니다.`);
    process.exit(1);
  }
  console.log("추출기가 아직 없습니다. Phase 1에서 precision / recall / 담당·기한 정확도를 여기에 출력합니다.");
}

main();
