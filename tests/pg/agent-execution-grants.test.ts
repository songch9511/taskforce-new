import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { agentGrantFixtures, agentExecutionGrantTests } from "../db/agent-execution-grants.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// Written only: the coordinator runs these against disposable PostgreSQL.
const DATABASE_URL=process.env.DATABASE_URL;
if(!DATABASE_URL)throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL databases.");
const DB_NAME=`taskforce_grants_${process.pid}_${Date.now()}`;
let admin:pg.Client, setup:pg.Client, a:pg.Client, b:pg.Client;
let aPid:number,bPid:number;
async function connect(database?:string){
  const url=new URL(DATABASE_URL!);if(database)url.pathname=`/${database}`;
  const client=new pg.Client({connectionString:url.toString()});await client.connect();await client.query("set statement_timeout='10s'");return client;
}
beforeAll(async()=>{
  admin=await connect();await admin.query(`create database ${DB_NAME}`);setup=await connect(DB_NAME);
  for(const sql of await supabaseSchemaScripts())await setup.query(sql);
  a=await connect(DB_NAME);b=await connect(DB_NAME);
  aPid=(await a.query<{pid:number}>("select pg_backend_pid() as pid")).rows[0].pid;
  bPid=(await b.query<{pid:number}>("select pg_backend_pid() as pid")).rows[0].pid;
},120_000);
afterEach(async()=>{await a?.query("rollback").catch(()=>{});await b?.query("rollback").catch(()=>{});});
afterAll(async()=>{
  await Promise.allSettled([a?.end(),b?.end(),setup?.end()]);
  if(admin){await admin.query(`drop database if exists ${DB_NAME} with (force)`);await admin.end();}
});
const db=(client:()=>pg.Client):()=>ConversationAgentDb=>()=>({query:async(sql,params)=>(await client().query(sql,params)).rows,asUser:async(user,fn)=>{await client().query("set role authenticated");await client().query("select set_config('request.jwt.claim.sub',$1,false)",[user]);try{return await fn();}finally{await client().query("reset role");await client().query("select set_config('request.jwt.claim.sub','',false)");}}});
const f=agentGrantFixtures(db(()=>setup)), fa=agentGrantFixtures(db(()=>a)), fb=agentGrantFixtures(db(()=>b));
const pending=<T,>(promise:Promise<T>)=>promise.then(value=>({value}),error=>({error}));
async function resolved<T>(promise:ReturnType<typeof pending<T>>){const result=await promise;if("error" in result)throw result.error;return result.value;}
async function blocked(waiter=bPid,blocker=aPid){
  for(let i=0;i<120;i++){
    if((await setup.query<{blocked:boolean}>("select $2::int=any(pg_blocking_pids($1)) as blocked",[waiter,blocker])).rows[0].blocked)return;
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  throw new Error("Expected demonstrated PostgreSQL row-lock wait");
}

describe("agent execution grants (PostgreSQL)",()=>{
  agentExecutionGrantTests(db(()=>setup));
  it.each(["lease","revoke"])("grant %s first serializes revocation with first delivery",async first=>{
    const w=await f.scopedWorld();await a.query("begin");await b.query("begin");
    if(first==="lease"){
      expect(await fa.lease(w)).toMatchObject({status:"leased"});
      const next=pending(b.query("delete from public.agent_execution_grants where user_id=$1",[w.user]));
      await blocked();await a.query("commit");await resolved(next);
    }else{
      await a.query("delete from public.agent_execution_grants where user_id=$1",[w.user]);
      const next=pending(fb.lease(w));await blocked();await a.query("commit");
      expect(await resolved(next)).toMatchObject({status:"withdrawn",reason:"write_gate_closed"});
    }
    await b.query("commit");
  });
});
