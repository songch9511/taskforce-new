import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, vi } from "vitest";

import { contextLayerTests } from "./context-layer.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// 시나리오가 서버 코드(src/lib/context/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 맥락층 (20261104000000_context_layer) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/context-layer.test.ts (동시성 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);

describe("맥락층 (PGlite)", () => {
  contextLayerTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});
