import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, vi } from "vitest";

import { conversationsTests } from "./conversations-v2.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// 시나리오가 서버 코드(src/lib/conversation/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 대화 v2 (20261106000000_conversations_v2) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/conversations-v2.test.ts (동시성 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("대화 v2 (PGlite)", () => {
  conversationsTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});
