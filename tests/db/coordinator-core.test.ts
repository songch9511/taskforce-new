import { PGlite } from "@electric-sql/pglite";
import { vector } from "@electric-sql/pglite-pgvector";
import { beforeAll, describe } from "vitest";

import { coordinatorCoreTests, coordinatorUpgradeTests } from "./coordinator-core.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 코디네이터 1 (20261110000000_coordinator_core, 구현 계획 C2) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/coordinator-core.test.ts
// (두 소비자 · 사용자별 직렬화 경합은 연결이 둘 이상 필요해 거기에만 있다).
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("코디네이터 사건 큐 (PGlite)", () => {
  coordinatorCoreTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 업그레이드 회귀는 새 PGlite를 마이그레이션 중간까지만 만든다 (위의 db와 따로)
coordinatorUpgradeTests(async () => {
  const fresh = new PGlite({ extensions: { vector } });
  return {
    exec: (sql) => fresh.exec(sql),
    query: async (sql, params) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
});
