import path from "node:path";

import { configDefaults, defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "src") },
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts", "tests/**/*.test.ts"],
    // 실제 Postgres가 필요한 테스트는 npm run test:pg (vitest.pg.config.mts)
    exclude: [...configDefaults.exclude, "tests/pg/**"],
  },
});
