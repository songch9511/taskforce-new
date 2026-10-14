import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe } from "vitest";
import { agentPathLeaseTests } from "./agent-path-leases.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";
let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
describe("agent path leases (PGlite)", () => {
  agentPathLeaseTests(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
});
