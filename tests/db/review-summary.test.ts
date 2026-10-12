import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite-pgvector";
import { beforeAll, describe } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";
import { reviewSummaryTests, reviewSummaryUpgradeTests } from "./review-summary.scenarios";

// 0.2.0 C3 (20261111000000_review_summary) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/review-summary.test.ts
// (같은 하루 묶음 동시 노출 · 동시 Clear · 동시 전이는 연결이 둘 이상 필요해 거기에만 있다).
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("제안 · 복귀 요약 · Clear (PGlite)", () => {
  reviewSummaryTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 업그레이드 · 되돌리기 회귀는 새 PGlite를 마이그레이션 중간까지만 만든다 (위의 db와 따로)
reviewSummaryUpgradeTests(async () => {
  const fresh = new PGlite({ extensions: { vector } });
  return {
    exec: (sql) => fresh.exec(sql),
    query: async (sql, params) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
});
