import path from "node:path";

import { configDefaults, defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "src") },
  },
  test: {
    environment: "node",
    // PGlite 시험 DB 템플릿(빈 클러스터 · 마이그레이션 적용 클러스터)을 워커가 뜨기 전에 한 번만 만든다 (tests/db/pglite-template.ts)
    globalSetup: ["./tests/db/pglite-global-setup.ts"],
    // 동시에 도는 worker 수 상한: PGlite 시험 프로세스는 각각 RSS 0.6–1GB의 WASM 힙을 쥔다. 기본값(코어 수 − 1, 8코어 개발 머신에서 7개)이면 합산 RSS가 3.5GB를 넘고
    // 메모리가 이미 포화인 머신에서는 압축기 과부하로 전체가 멈춘다(측정: handoffs 노트). 3으로 두면 같은 묶음에서 합산 RSS 약 2.6GB, 압축 페이지 수 0, 시간은 같다.
    // CI(4 vCPU)의 기본값도 3이라 CI 동작은 같다. 시험 제한 시간은 기본값 그대로다.
    maxWorkers: 3,
    include: ["src/**/*.test.ts", "tests/**/*.test.ts"],
    // 실제 Postgres가 필요한 테스트는 npm run test:pg (vitest.pg.config.mts)
    exclude: [...configDefaults.exclude, "tests/pg/**"],
  },
});
