import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe } from "vitest";

import { claudeAppChatsTests } from "./claude-app-chats.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => {
  db = await createLocalSupabase();
}, 300_000);
afterAll(async () => {
  await db?.close();
});

describe("Claude 데스크톱 대화 저장 (PGlite)", () => {
  claudeAppChatsTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (user, fn) => asUser(db, user, fn),
  }));
});
