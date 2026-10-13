import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe } from "vitest";

import { actionNumbersAgentTurnTests, actionNumbersLockPrivilegeTests, actionNumbersTests, actionNumbersUpgradeTests } from "./action-numbers.scenarios";
import { freshPgliteForEachTest } from "./fresh-pglite";
import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 OA D4c-3a (20261120000000_action_numbers) — 이슈 번호 actions.number + 카운터 action_counters. PGlite.
// 같은 시나리오를 실제 Postgres로: tests/pg/action-numbers.test.ts (같은 사용자 동시 insert 경합 · 계정 삭제와의 잠금 순서는 연결이 둘 이상 필요해 거기에만 있다).
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

const appDb = () => ({
  query: async (sql: string, params?: unknown[]) => (await db.query<Record<string, unknown>>(sql, params)).rows,
  asUser: <T,>(userId: string, fn: () => Promise<T>) => asUser(db, userId, fn),
});

describe("이슈 번호 (PGlite)", () => {
  actionNumbersTests(appDb);
  actionNumbersAgentTurnTests(appDb);
});

// 업그레이드 · 소유자 권한 시험은 새 PGlite를 따로 만든다 (위의 db와 따로)
const freshDb = freshPgliteForEachTest();
const freshDatabase = async () => {
  const fresh = await freshDb(); // initdb만 된 빈 클러스터를 복제하고, 시험이 끝나면 닫는다
  return {
    exec: (sql: string) => fresh.exec(sql),
    query: async (sql: string, params?: unknown[]) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
};
actionNumbersUpgradeTests(freshDatabase);
actionNumbersLockPrivilegeTests(freshDatabase, "tf_numbers_nolock_owner");
