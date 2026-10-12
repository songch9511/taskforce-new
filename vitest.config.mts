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
    include: ["src/**/*.test.ts", "tests/**/*.test.ts"],
    // 실제 Postgres가 필요한 테스트는 npm run test:pg (vitest.pg.config.mts)
    exclude: [...configDefaults.exclude, "tests/pg/**"],
  },
});
