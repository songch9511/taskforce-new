import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe } from "vitest";

import { actionNumbersTests, actionNumbersUpgradeTests } from "./action-numbers.scenarios";
import { freshPgliteForEachTest } from "./fresh-pglite";
import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 OA D4c-3a (20261120000000_action_numbers) — 이슈 번호 actions.number + 카운터 action_counters. PGlite.
// 같은 시나리오를 실제 Postgres로: tests/pg/action-numbers.test.ts (같은 사용자 동시 insert 경합은 연결이 둘 이상 필요해 거기에만 있다).
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("이슈 번호 (PGlite)", () => {
  actionNumbersTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 업그레이드 시험은 새 PGlite를 마이그레이션 직전까지만 만든다 (위의 db와 따로)
const freshDb = freshPgliteForEachTest();
actionNumbersUpgradeTests(async () => {
  const fresh = await freshDb(); // initdb만 된 빈 클러스터를 복제하고, 시험이 끝나면 닫는다
  return {
    exec: (sql) => fresh.exec(sql),
    query: async (sql, params) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
});
