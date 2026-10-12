import { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";
import { reviewSummaryTests } from "./review-summary.scenarios";

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
