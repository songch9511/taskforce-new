import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, expect, it } from "vitest";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
const withdrawn = randomUUID(), consented = randomUUID();
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
beforeEach(async () => {
  await db.exec("delete from auth.users");
  await db.query("insert into auth.users(id) values($1),($2)", [withdrawn, consented]);
  await db.query("insert into profiles(user_id,display_name,ai_consent_at) values($1,'Withdrawn',null),($2,'Consented',now())", [withdrawn, consented]);
});
afterAll(async () => { await db?.close(); });
const candidates = () => db.query<{ id: string }>("select id from ai_budget_retry_candidates(now()-interval '1 day',50)");

it("50 older withdrawn budget pauses do not starve a consented source or erase retained data", async () => {
  await db.query(`insert into sources(user_id,kind,raw_text,occurred_at,created_at,processing_status,processing_summary)
    select $1,'note','retained',now()-interval '4 days',now()-interval '4 days','pending',
    jsonb_build_object('budget_deferred',true,'retryable',true,'retry_at',now()-interval '1 day') from generate_series(1,50)`, [withdrawn]);
  const { rows } = await db.query<{ id: string }>(`insert into sources(user_id,kind,raw_text,occurred_at,created_at,processing_status,processing_summary)
    values($1,'note','eligible',now()-interval '3 days',now()-interval '3 days','pending',
    jsonb_build_object('budget_deferred',true,'retryable',true,'retry_at',now()-interval '1 day')) returning id`, [consented]);
  await db.exec("set role service_role");
  try { expect((await candidates()).rows).toEqual(rows); } finally { await db.exec("reset role"); }
  expect((await db.query("select count(*)::integer n from sources where raw_text='retained'")).rows).toEqual([{ n: 50 }]);
  await db.query("update profiles set ai_consent_at=null where user_id=$1", [consented]);
  expect((await candidates()).rows).toEqual([]);
});

it("future, manual, completed and purged pauses do not take batch slots", async () => {
  await db.query(`insert into sources(user_id,kind,raw_text,occurred_at,created_at,processing_status,processing_summary,raw_text_purged_at)
    select $1,'note','',now(),now()-interval '3 days',status,summary,purged from (values
    ('pending',jsonb_build_object('budget_deferred',true,'retryable',true,'retry_at',now()+interval '1 day'),null::timestamptz),
    ('pending',jsonb_build_object('budget_deferred',true,'retryable',false),null::timestamptz),
    ('done',jsonb_build_object('budget_deferred',true,'retryable',true,'retry_at',now()-interval '1 day'),null::timestamptz),
    ('pending',jsonb_build_object('budget_deferred',true,'retryable',true,'retry_at',now()-interval '1 day'),now())
    ) v(status,summary,purged)`, [consented]);
  expect((await candidates()).rows).toEqual([]);
});

it("denies anonymous and authenticated callers access to cross-account source text", async () => {
  await asUser(db, consented, async () => {
    await expect(candidates()).rejects.toThrow(/permission denied/);
  });
  await db.exec("set role anon");
  try { await expect(candidates()).rejects.toThrow(/permission denied/); } finally { await db.exec("reset role"); }
});
