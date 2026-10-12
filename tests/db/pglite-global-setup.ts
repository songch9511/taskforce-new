import { readdirSync, statSync, unlinkSync } from "node:fs";
import path from "node:path";

import { supabaseSchemaScripts } from "./local-supabase";
import { clusterTemplate, PGLITE_TEMPLATE_CACHE_DIR, templatesEnabled } from "./pglite-template";

/** 오래된 템플릿 캐시(마이그레이션이 바뀌기 전 것)를 지운다: 7일 지난 .tar, 1시간 지난 .tmp. 실패해도 무시 */
function prune() {
  try {
    for (const name of readdirSync(PGLITE_TEMPLATE_CACHE_DIR)) {
      const file = path.join(PGLITE_TEMPLATE_CACHE_DIR, name);
      const age = Date.now() - statSync(file).mtimeMs;
      if ((name.endsWith(".tar") && age > 7 * 86_400_000) || (name.endsWith(".tmp") && age > 3_600_000)) unlinkSync(file);
    }
  } catch {
    // 캐시 디렉터리가 아직 없을 수 있다
  }
}

// vitest globalSetup: 테스트 워커가 뜨기 전에 PGlite 템플릿(빈 클러스터 · 마이그레이션 적용 클러스터)을 한 번만 만든다.
// 워커 수십 개가 동시에 같은 템플릿을 처음부터 만드는 일을 막는다. 실패해도 시험은 막히지 않는다(각 시험이 예전처럼 처음부터 만든다).
export default async function setup() {
  if (!templatesEnabled()) return;
  prune();
  try {
    await clusterTemplate([]);
    await clusterTemplate(await supabaseSchemaScripts());
  } catch {
    // 템플릿 없이 진행
  }
}
