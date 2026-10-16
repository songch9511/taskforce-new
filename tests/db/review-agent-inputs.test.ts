import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe } from "vitest";
import { asUser, createLocalSupabase } from "./local-supabase";
import { reviewAgentInputsTests } from "./review-agent-inputs.scenarios";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

describe("review_agent_inputs (PGlite)", () => {
  reviewAgentInputsTests(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
});
