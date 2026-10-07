import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, expect, it } from "vitest";
import { asUser, createLocalSupabase } from "./local-supabase";
let db: PGlite;
const user=randomUUID();
let connection:string;
beforeAll(async()=>{
  db=await createLocalSupabase();
  await db.query("insert into auth.users(id) values($1)",[user]);
  connection=(await db.query<{id:string}>("insert into connections(user_id,provider,external_account_id) values($1,'notion','pending-queue') returning id",[user])).rows[0].id;
},60_000);
afterAll(async()=>{await db?.close();});
const insert=async(external:string,version:string,status="pending",summary:object={budget_deferred:true,retryable:true,retry_at:"2020-01-01T00:00:00Z"},structured:object|null={snapshot:{title:"task"}})=>{
  return (await db.query<{id:string}>(`insert into sources(user_id,connection_id,kind,raw_text,external_id,external_version,processing_status,structured,processing_summary,created_at,occurred_at)
  values($1,$2,'task','preserved',$3,$4,$5,$6,$7,now()-interval '10 days',now()-interval '10 days'+$8::interval) returning id`,[user,connection,external,version,status,JSON.stringify(structured),JSON.stringify(summary),`${Number(version)} seconds`])).rows[0].id;
};
const pending=()=>db.query<{id:string}>("select * from pending_task_sources($1,$2,now()-interval '3 days')",[user,connection]);
it("over 20 superseded deferred versions do not starve a later due task",async()=>{
  for(let i=0;i<25;i++) {
    await insert(`superseded-${i}`,"1");
    await insert(`superseded-${i}`,"2","done",{});
  }
  const due=await insert("due","3");
  expect((await pending()).rows.map(r=>r.id)).toEqual([due]);
  expect((await db.query("select count(*)::int count from sources where raw_text='preserved'")).rows).toEqual([{count:51}]);
});
it("latest blocked/future/purged/in-flight versions suppress older eligible ones before limit",async()=>{
  await db.exec("truncate sources cascade");
  for(const name of ["blocked","future","purged","inflight"]) await insert(name,"1");
  await insert("blocked","2","pending",{budget_deferred:true,retryable:false});
  await insert("future","2","pending",{budget_deferred:true,retryable:true,retry_at:"2100-01-01T00:00:00Z"});
  const purged=await insert("purged","2");
  await db.query("update sources set structured=null where id=$1",[purged]);
  await insert("inflight","2","processing",{budget_deferred:true,retryable:true,retry_at:"2020-01-01T00:00:00Z",started_at:new Date().toISOString()});
  expect((await pending()).rows).toEqual([]);
});
it("queue is bounded and only service callers may execute",async()=>{
  await db.exec("truncate sources cascade");
  for(let i=0;i<25;i++) await insert(`due-${i}`,"1");
  expect((await pending()).rows).toHaveLength(20);
  await asUser(db,user,async()=>{await expect(pending()).rejects.toThrow(/permission denied/);});
});
