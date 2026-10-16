import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, vi } from "vitest";

import { freshPgliteForEachTest } from "./fresh-pglite";
import { asUser, createLocalSupabase } from "./local-supabase";
import { bodyEqualityTests, organizeCardTests, organizeMoveTests, organizeUpgradeTests } from "./issue-organize.scenarios";

// 시나리오가 서버 코드(src/lib/context/member-writes.ts · src/lib/conversation/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 OA D4c-2 · D4c-3b (20261125000000_issue_organize) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/issue-organize.test.ts (동시성 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

const appDb = () => ({
  query: async (sql: string, params?: unknown[]) => (await db.query<Record<string, unknown>>(sql, params)).rows,
  asUser: <T,>(userId: string, fn: () => Promise<T>) => asUser(db, userId, fn),
});

describe("이슈 정리 (PGlite)", () => {
  bodyEqualityTests();
  organizeMoveTests(appDb);
  organizeCardTests(appDb);
});

// 업그레이드 시험은 새 PGlite를 따로 만든다 (위의 db와 따로)
const freshDb = freshPgliteForEachTest();
organizeUpgradeTests(async () => {
  const fresh = await freshDb();
  return {
    exec: (sql: string) => fresh.exec(sql),
    query: async (sql: string, params?: unknown[]) => (await fresh.query<Record<string, unknown>>(sql, params)).rows,
  };
});
