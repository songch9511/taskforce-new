import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, vi } from "vitest";

import { contextMembersTests } from "./context-members.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// 시나리오가 서버 코드(src/lib/context/member-writes.ts · src/lib/context/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 S3b 멤버십 쓰기 (20261108000000_context_member_user_writes) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/context-members.test.ts (동시성 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("멤버십 쓰기 (PGlite)", () => {
  contextMembersTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});
