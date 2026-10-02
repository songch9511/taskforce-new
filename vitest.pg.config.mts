import path from "node:path";

import { defineConfig } from "vitest/config";

// 실제 Postgres가 필요한 테스트 (npm run test:pg). DATABASE_URL이 가리키는 서버에 일회용 데이터베이스를 만들어 마이그레이션을 적용한다.
// CI는 check 작업의 postgres service(pgvector/pgvector:pg17)로 돌린다. DATABASE_URL 없이 돌리면 건너뛰지 않고 실패하며, 로컬에서 띄우는 방법을 알려 준다.
export default defineConfig({
  resolve: {
    alias: { "@": path.resolve(import.meta.dirname, "src") },
  },
  test: {
    environment: "node",
    include: ["tests/pg/**/*.test.ts"],
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 120_000,
  },
});
