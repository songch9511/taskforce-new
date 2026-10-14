import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agentEventFixtures } from "./agent-events.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
const f = agentEventFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

describe("agent artifacts ownership and frozen draft table", () => {
  it("keeps execution_artifacts draft-only and required fields unchanged", async () => {
    const columns = await f.q(`select column_name,is_nullable from information_schema.columns where table_schema='public' and table_name='execution_artifacts'`);
    for (const name of ["marker", "model", "prompt_version", "step_id"]) expect(columns).toContainEqual({ column_name: name, is_nullable: "NO" });
    for (const name of ["path", "hash", "summary", "superseded_at", "turn_seq"]) expect(columns.some(c => c.column_name === name)).toBe(false);
    const constraints = await f.q(`select pg_get_constraintdef(oid) as definition from pg_constraint where conrelid='public.execution_artifacts'::regclass`);
    expect(constraints.some(c => String(c.definition).includes("UNIQUE (step_id)"))).toBe(true);
    expect(constraints.some(c => String(c.definition).includes("draft") && !String(c.definition).includes("agent"))).toBe(true);
  });
  it("owner reads, other user sees nothing, only server can write", async () => {
    const w = await f.eventWorld(), other = await f.user();
    await f.apply(w.user, f.event(w, "artifact", { payload: { path: "a", hash: "h", summary: "s" } }));
    await asUser(db, w.user, async () => {
      expect(await f.q(`select path from public.agent_artifacts where run_id=$1`, [w.run])).toEqual([{path:"a"}]);
      for (const sql of ["update public.agent_artifacts set summary='x'", "delete from public.agent_artifacts", "insert into public.agent_artifacts default values"]) await expect(f.q(sql)).rejects.toThrow(/permission denied/);
    });
    await asUser(db, other, async () => { expect(await f.q(`select * from public.agent_artifacts where run_id=$1`, [w.run])).toEqual([]); });
    expect(await f.q(`select polname,polcmd from pg_policy where polrelid='public.agent_artifacts'::regclass`)).toEqual([{polname:"owner_all",polcmd:"*"}]);
    expect(await f.q(`select relrowsecurity from pg_class where oid='public.agent_artifacts'::regclass`)).toEqual([{relrowsecurity:true}]);
    for (const privilege of ["select", "insert", "update", "delete"]) {
      expect(await f.one(`select has_table_privilege('service_role','public.agent_artifacts',$1) as server,has_table_privilege('anon','public.agent_artifacts',$1) as anon,has_table_privilege('authenticated','public.agent_artifacts',$1) as app`, [privilege])).toEqual({server:true,anon:false,app:privilege === "select"});
    }
    const constraints = await f.q(`select pg_get_constraintdef(oid) as definition from pg_constraint where conrelid='public.agent_artifacts'::regclass`);
    expect(constraints.some(c => String(c.definition) === "UNIQUE (id, user_id)")).toBe(true);
    const columns = await f.q(`select column_name from information_schema.columns where table_schema='public' and table_name='agent_artifacts'`);
    expect(columns.map(c => c.column_name).sort()).toEqual(["id","user_id","run_id","agent_task_id","turn_seq","path","content_hash","summary","superseded_at","created_at"].sort());
  });
  it("composite parents reject cross-owner run/task and enforce bounds", async () => {
    const w = await f.eventWorld(), other = await f.eventWorld();
    const insert = (run: string, task: string, path = "a", summary = "s", turn = 1) => f.q(`insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values ($1,$2,$3,$4,$5,'h',$6)`, [w.user,run,task,turn,path,summary]);
    await expect(insert(other.run,w.task)).rejects.toThrow(/foreign key/);
    await expect(insert(w.run,other.task)).rejects.toThrow(/foreign key/);
    for (const [path, summary, turn] of [["","s",1],["x".repeat(1001),"s",1],["a","s".repeat(2001),1],["a","s",0]] as const) await expect(insert(w.run,w.task,path,summary,turn)).rejects.toThrow(/check constraint/);
    await insert(w.run,w.task,"x".repeat(1000),"s".repeat(2000));
  });
});

it("R2 artifact task/run composite FK and lookup indexes match ownership policy", async () => {
  const w=await f.eventWorld();
  const run=await f.agentRun(w.user,await f.action(w.user),{agent_session_id:w.session});
  await expect(f.q(`insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,1,'x','h','s')`,[w.user,run,w.task])).rejects.toThrow(/foreign key/);
});

it("R2 artifact indexes and authenticated owner policy",async()=>{
  const indexes=await f.q(`select indexdef from pg_indexes where schemaname='public' and tablename='agent_artifacts'`);
  for(const column of ["user_id","agent_task_id","run_id"]) expect(indexes.some(row=>new RegExp(`\\(${column}(?:,|\\))`).test(String(row.indexdef)))).toBe(true);
  const policy=await f.one(`select roles,qual from pg_policies where schemaname='public' and tablename='agent_artifacts'`);
  expect(policy.roles).toEqual(["authenticated"]);
  expect(String(policy.qual)).toMatch(/SELECT auth.uid\(\)/);
});
