import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";
import { memoryHistoryTests } from "./memory-history.scenarios";

// 기억의 정정 · 잊기 이력 (PGlite). 같은 시나리오를 실제 Postgres로: tests/pg/memory-history.test.ts
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("memory_items 정정 · 잊기 이력 (PGlite)", () => {
  memoryHistoryTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});
