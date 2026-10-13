import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe } from "vitest";
import { agentQuestionsStopTests } from "./agent-questions-stop.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
describe("agent questions and Stop (PGlite)", () => {
  agentQuestionsStopTests(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
});
