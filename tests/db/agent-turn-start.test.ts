import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agentTurnStartTests, D1C1_MIGRATION } from "./agent-turn-start.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";
let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
describe("agent turn start (PGlite)", () => {
  agentTurnStartTests(() => ({ query: async (sql,params) => (await db.query<Record<string,unknown>>(sql,params)).rows, asUser: (user,fn) => asUser(db,user,fn) }));
});

describe("agent turn migration boundary", () => {
  const migration = readFileSync(path.resolve(__dirname,"../../supabase/migrations",D1C1_MIGRATION),"utf8");
  const sql = migration.split("\n").filter(line=>!line.trim().startsWith("--")).join("\n").trim();
  it("one transaction, bounded fail-fast locks and only the specified function replacements", () => {
    expect(sql.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(sql.endsWith("commit;")).toBe(true);
    expect(sql.match(/^begin;$/gm)).toHaveLength(1);
    expect(sql.match(/^commit;$/gm)).toHaveLength(1);
    for(const lock of sql.match(/^lock table .*;$/gm) ?? []) expect(lock).toMatch(/ nowait;$/);
    expect([...sql.matchAll(/create or replace function public\.([a-z_]+)/g)].map(m=>m[1]).sort()).toEqual(["append_step","finish_run","prepare_step","settle_step"]);
    expect(sql).not.toMatch(/create (?:or replace )?function public\.(?:create_run|begin_call|sweep_expire)\b/);
    expect(sql).not.toMatch(/create table|alter table public\.(?:execution_|agent_|conversations|conversation_messages)/);
  });
  it("keeps the coordinator supplied common metric block byte-for-byte", () => {
    // SHA-256 of handoffs/oa-metric-events-block.sql; the block belongs to the coordinator.
    const block = migration.match(/-- OA 공통 블록:[\s\S]*?with check \(user_id = \(select auth.uid\(\)\) and type in \('app_opened', 'assistant_opened'\)\);\n/)?.[0];
    expect(block).toBeDefined();
    expect(createHash("sha256").update(block!).digest("hex")).toBe("02361a1005df48755300b33abcc1aba2cb3df4ba33c2e1d19d861b2c8896f4ce");
  });
});
