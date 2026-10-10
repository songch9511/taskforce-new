import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, vi } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";
import { memoryWritesTests } from "./memory-writes.scenarios";

// 시나리오가 서버 코드(src/lib/context/memory-writes.ts · src/lib/conversation/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 기억 쓰기 (20261107000000_memory_writes, B3) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/memory-writes.test.ts (동시성 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("기억 쓰기 (PGlite)", () => {
  memoryWritesTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});
