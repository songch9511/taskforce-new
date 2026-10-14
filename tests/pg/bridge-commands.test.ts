import { readFile } from "node:fs/promises";
import path from "node:path";
import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { bridgeCommandFixtures } from "../db/bridge-commands.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// Written only: the coordinator runs these against disposable PostgreSQL.
const DATABASE_URL=process.env.DATABASE_URL;
if(!DATABASE_URL)throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL databases.");
const DB_NAME=`taskforce_bridge_${process.pid}_${Date.now()}`;
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
const db=(client:()=>pg.Client):()=>ConversationAgentDb=>()=>({query:async(sql,params)=>(await client().query(sql,params)).rows,asUser:async()=>{throw new Error("No application role needed for concurrency cases");}});
const f=bridgeCommandFixtures(db(()=>setup)), fa=bridgeCommandFixtures(db(()=>a)), fb=bridgeCommandFixtures(db(()=>b));
const pending=<T,>(promise:Promise<T>)=>promise.then(value=>({value}),error=>({error}));
async function resolved<T>(promise:ReturnType<typeof pending<T>>){const result=await promise;if("error" in result)throw result.error;return result.value;}
async function blocked(waiter=bPid,blocker=aPid){
  for(let i=0;i<120;i++){
    if((await setup.query<{blocked:boolean}>("select $2::int=any(pg_blocking_pids($1)) as blocked",[waiter,blocker])).rows[0].blocked)return;
    await new Promise(resolve=>setTimeout(resolve,20));
  }
  throw new Error("Expected demonstrated PostgreSQL row-lock wait");
}

describe("bridge command concurrency",()=>{
  it.each(["stop","lease"])("P1 %s first serializes Stop with lease",async first=>{
    const w=await f.world();await a.query("begin");await b.query("begin");
    if(first==="stop"){
      expect(await fa.stop(w.user,w.session)).toMatchObject({tasks:[{cancel:"confirmed"}]});
      const next=pending(fb.lease(w));await blocked();await a.query("commit");expect(await resolved(next)).toMatchObject({status:"stale"});
    }else{
      expect(await fa.lease(w)).toMatchObject({status:"leased"});const next=pending(fb.stop(w.user,w.session));await blocked();await a.query("commit");expect(await resolved(next)).toMatchObject({tasks:[{cancel:"requested_only"}]});
    }
    await b.query("commit");expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).toBe(first==="stop"?0:1);
  });
  it("P2 Action lock alone does not block lease (R-L5)",async()=>{
    const w=await f.world();await a.query("begin");await a.query("select id from public.actions where id=$1 for update",[w.action]);
    await b.query("begin");await b.query("set local lock_timeout='500ms'");
    expect(await fb.lease(w)).toMatchObject({status:"leased"});await b.query("commit");await fa.done(w.user,w.action);await a.query("commit");
    expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).toBe(1);
  });
  it("P2 Done holds run and lease waits there before observing cancellation",async()=>{
    const w=await f.world();await a.query("begin");await fa.done(w.user,w.action);await b.query("begin");
    const next=pending(fb.lease(w));await blocked();await a.query("commit");expect(await resolved(next)).toMatchObject({status:"stale"});await b.query("commit");
    expect(await f.state(w)).toMatchObject({state:"cancelled"});
  });
  it("P3 Done cancel insertion cannot wait for session FK KEY SHARE (R-L6)",async()=>{
    const w=await f.world();await f.lease(w);
    await a.query("begin");await a.query("select id from public.actions where id=$1 for update",[w.action]);
    await b.query("begin");await b.query("select id from public.agent_sessions where id=$1 for update",[w.session]);
    const waiting=pending(b.query("select id from public.actions where id=$1 for share",[w.action]));await blocked();
    await a.query("set local lock_timeout='750ms'");await fa.done(w.user,w.action);await a.query("commit");await resolved(waiting);await b.query("commit");
    expect(await f.count("select 1 from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).toBe(1);
  });
  it("P4 simultaneous leases produce one intent and identical replay marker",async()=>{
    const w=await f.world();await a.query("begin");await b.query("begin");
    const first=await fa.lease(w),next=pending(fb.lease(w));await blocked();await a.query("commit");const second=await resolved(next);await b.query("commit");
    expect(first.status).toBe("leased");expect(second).toEqual({...first,status:"replay"});expect(await f.count("select 1 from public.execution_intents where step_id=$1",[w.step])).toBe(1);
  });
  it("P5 sweep skips locked leased step and later expires it without another command",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});
    await a.query("begin");await a.query("select id from public.execution_steps where id=$1 for update",[w.step]);
    await b.query("select public.sweep_agent_step_leases(now())");expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"calling"});
    await a.query("commit");await b.query("select public.sweep_agent_step_leases(now())");expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"unknown_outcome"});
    expect(await f.count("select 1 from public.bridge_commands where step_id=$1",[w.step])).toBe(1);
  });
  it("P5 reattachment and sweep serialize on the original step",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    await a.query("begin");expect(await fa.bridgeEvent(w,f.event(w,"accepted"))).toMatchObject({status:"applied"});
    await b.query("select public.sweep_agent_step_leases(now())");await a.query("commit");
    expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"called"});expect(await f.state(w)).toMatchObject({state:"accepted"});
  });
  it.each(["heartbeat","sweep"])("P6 %s first leaves heartbeat revival consistent",async first=>{
    const w=await f.world();await f.lease(w);await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});await a.query("begin");
    if(first==="heartbeat"){
      await fa.heartbeat(w);await b.query("select * from public.sweep_bridge_heartbeats(now(),50)");await a.query("commit");
    }else{
      await a.query("select * from public.sweep_bridge_heartbeats(now(),50)");await b.query("begin");const next=pending(fb.heartbeat(w));await blocked();await a.query("commit");await resolved(next);await b.query("commit");
    }
    expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"bound"});
    expect(await f.state(w)).toMatchObject({state:first==="heartbeat"?"dispatched":"unreachable"});
  });
  it.each(["lease","event","heartbeat"])("P7 revoke serializes %s and no delivery follows committed revocation",async op=>{
    const w=await f.world();if(op!=="lease")await f.lease(w);
    await a.query("begin");await a.query("select public.revoke_bridge($1,$2)",[w.user,w.bridge]);await b.query("begin");
    const next=pending<unknown>(op==="lease"?fb.lease(w):op==="event"?fb.bridgeEvent(w,f.event(w,"accepted")):fb.heartbeat(w));
    // A revoked bridge can be rejected by a committed-state check before taking row locks.
    await a.query("commit");await resolved(next);await b.query("commit");
    expect((await f.lease(w)).status).not.toBe("leased");expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"closed"});
  });
  it("P8 event waits on message-first lease and then settles the same intent",async()=>{
    const w=await f.world();await a.query("begin");await b.query("begin");expect(await fa.lease(w)).toMatchObject({status:"leased"});
    const next=pending(fb.bridgeEvent(w,f.event(w,"accepted")));await blocked();await a.query("commit");expect(await resolved(next)).toMatchObject({status:"applied"});await b.query("commit");
    expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"called"});expect(await f.count("select 1 from public.execution_intents where step_id=$1",[w.step])).toBe(1);
  });
  it.each(["bridges","rate_limit_events","agent_connections","execution_steps"])("P9 migration fails immediately if %s conflicts",async table=>{
    const sql=await readFile(path.join(process.cwd(),"supabase/migrations/20261118000000_bridge_commands.sql"),"utf8");
    const prefix=sql.slice(0,sql.indexOf("alter table public.bridges"));expect(prefix).toMatch(/lock table public\.bridges, public\.rate_limit_events in access exclusive mode nowait/);expect(prefix).toMatch(/lock table public\.agent_connections in share row exclusive mode nowait/);expect(prefix).toMatch(/lock table public\.execution_steps in share row exclusive mode nowait/);
    await a.query("begin");await a.query(`lock table public.${table} in ${["bridges","rate_limit_events"].includes(table)?"access share":"row exclusive"} mode`);
    await expect(b.query(prefix)).rejects.toMatchObject({code:"55P03"});
  });
  it.each(["external","closed"])("P10 heartbeat does not lock %s sessions",async status=>{
    const w=await f.world(), excluded=await f.session(w.user,w.connection,{status});
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await a.query("begin");await a.query("select id from public.agent_sessions where id=$1 for update",[excluded]);
    await b.query("begin");await b.query("set local lock_timeout='500ms'");
    expect(await fb.heartbeat(w)).toMatchObject({revived_session_ids:[]});
    await b.query("commit");await a.query("commit");
  });
  it.each(["idle","failed","cancelled","completed"])("P10 heartbeat does not lock historical %s runs, tasks or steps",async state=>{
    const w=await f.world();await f.updateRow("agent_tasks",w.task,{state});
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await a.query("begin");await a.query("select id from public.execution_runs where id=$1 for no key update",[w.run]);
    await a.query("select id from public.agent_tasks where id=$1 for update",[w.task]);
    await a.query("select id from public.execution_steps where id=$1 for update",[w.step]);
    await b.query("begin");await b.query("set local lock_timeout='500ms'");
    expect(await fb.heartbeat(w)).toMatchObject({unknown_task_ids:[],missing_task_ids:[]});
    await b.query("commit");await a.query("commit");
  });
  it("P10 unknown and missing task lookup leaves foreign task rows unlocked",async()=>{
    const w=await f.world(),other=await f.world();await f.lease(w);
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await a.query("begin");await a.query("select id from public.agent_tasks where id=$1 for update",[other.task]);
    await b.query("begin");await b.query("set local lock_timeout='500ms'");
    expect(await fb.heartbeat(w,[{task_id:other.task,process_alive:true,last_seq:0}])).toMatchObject({unknown_task_ids:[other.task],missing_task_ids:[w.task]});
    await b.query("commit");await a.query("commit");
  });
  it("P11 throttled heartbeat returns the previous result without waiting on a bridge lock or writing",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    const first=await f.heartbeat(w),before=await f.one("select to_jsonb(b) as row from public.bridges b where id=$1",[w.bridge]);
    const state=await f.snapshot(w),events=await f.q("select * from public.execution_events where user_id=$1 order by id",[w.user]);
    await a.query("begin");await a.query("select id from public.bridges where id=$1 for no key update",[w.bridge]);
    await b.query("begin");await b.query("set local lock_timeout='500ms'");
    expect(await fb.heartbeat(w,[{task_id:w.task,process_alive:true,last_seq:99}])).toEqual({...first,throttled:true});
    await b.query("commit");await a.query("commit");
    expect(await f.one("select to_jsonb(b) as row from public.bridges b where id=$1",[w.bridge])).toEqual(before);
    expect(await f.snapshot(w)).toEqual(state);expect(await f.q("select * from public.execution_events where user_id=$1 order by id",[w.user])).toEqual(events);
  });
  it("P11 concurrent heartbeat rechecks the cache after its lock wait",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await a.query("begin");const first=await fa.heartbeat(w);
    const before=await fa.one("select to_jsonb(b) as row from public.bridges b where id=$1",[w.bridge]);
    const step=await fa.one("select lease_expires_at from public.execution_steps where id=$1",[w.step]);
    await b.query("begin");const second=pending(fb.heartbeat(w,[{task_id:w.task,process_alive:true,last_seq:99}]));
    await blocked();await a.query("commit");
    expect(await resolved(second)).toEqual({...first,throttled:true});await b.query("commit");
    expect(await f.one("select to_jsonb(b) as row from public.bridges b where id=$1",[w.bridge])).toEqual(before);
    expect(await f.one("select lease_expires_at from public.execution_steps where id=$1",[w.step])).toEqual(step);
  });
  it.each(["heartbeat","register"])("P12 %s connection update is compatible with FK key-share locks",async op=>{
    const w=await f.world();await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    const report=JSON.stringify({adapters:{"agent:codex":{installed:true,version:"0.114.0",signed_in:"yes",managed_settings:false}}});
    await a.query("begin");await a.query("select id from public.agent_connections where id=$1 for key share",[w.connection]);
    await b.query("begin");await b.query("set local lock_timeout='500ms'");
    if(op==="heartbeat")await b.query("select public.bridge_heartbeat($1,$2,'[]',$3::jsonb)",[w.user,w.bridge,report]);
    else {
      const {device_ref}=await f.one("select device_ref from public.bridges where id=$1",[w.bridge]);
      await b.query("select public.register_bridge($1,$2,$3,'1',$4::jsonb,$5::text[],false)",[w.user,device_ref,"a".repeat(64),report,["agent:codex"]]);
    }
    await b.query("commit");await a.query("commit");
    expect(await f.one("select status from public.agent_connections where id=$1",[w.connection])).toEqual({status:"active"});
  });
  it.each([["bridge_events",120],["bridge_ack",240],["bridge_poll",90]] as const)("P13 %s admits exactly one concurrent final-slot request",async(kind,max)=>{
    const w=await f.world();
    await setup.query("insert into public.rate_limit_events(user_id,bridge_id,kind,created_at) select $1,$2,$3,clock_timestamp() from generate_series(1,$4::int)",[w.user,w.bridge,kind,max-1]);
    const sql="select public.take_rate_limit($1,$2,$3,60,$4) as retry_at",args=[w.user,kind,max,w.bridge];
    await a.query("begin");expect((await a.query(sql,args)).rows[0].retry_at).toBeNull();
    await b.query("begin");const second=pending(b.query(sql,args));await blocked();await a.query("commit");
    expect((await resolved(second)).rows[0].retry_at).toBeInstanceOf(Date);await b.query("commit");
    expect(await f.count("select 1 from public.rate_limit_events where user_id=$1 and bridge_id=$2 and kind=$3",[w.user,w.bridge,kind])).toBe(max);
  });
  it("P14 concurrent new registrations admit only the tenth active bridge",async()=>{
    const user=await f.user();for(let n=0;n<9;n++)await f.bridge(user);
    const sql="select public.register_bridge($1,$2,$3,'1',$4::jsonb,'{}'::text[],false) as result";
    const args=(device:string)=>[user,device,"a".repeat(64),JSON.stringify({adapters:{}})];
    await a.query("begin");expect((await a.query(sql,args("new-first"))).rows[0].result).toMatchObject({status:"registered"});
    await b.query("begin");const second=pending(b.query(sql,args("new-second")));await blocked();await a.query("commit");
    expect((await resolved(second)).rows[0].result).toEqual({status:"too_many_bridges"});await b.query("commit");
    expect(await f.count("select 1 from public.bridges where user_id=$1 and status='active'",[user])).toBe(10);
    expect(await f.count("select 1 from public.bridges where user_id=$1 and device_ref='new-second'",[user])).toBe(0);
  });
  it.each(["new", "reactivate"])("P16 %s registration wins the last slot against the other activation",async first=>{
    const user=await f.user(),revoked=await f.bridge(user);
    await f.q("select public.revoke_bridge($1,$2)",[user,revoked]);
    const device=String((await f.one("select device_ref from public.bridges where id=$1",[revoked])).device_ref);
    for(let n=0;n<9;n++)await f.bridge(user);
    const sql="select public.register_bridge($1,$2,$3,'1',$4::jsonb,'{}'::text[],$5) as result";
    const args=(kind:string)=>[user,kind==="new"?"new-last-slot":device,"a".repeat(64),JSON.stringify({adapters:{}}),kind==="reactivate"];
    await a.query("begin");
    expect((await a.query(sql,args(first))).rows[0].result).toMatchObject({status:first==="new"?"registered":"reactivated"});
    await b.query("begin");const second=pending(b.query(sql,args(first==="new"?"reactivate":"new")));
    await blocked();await a.query("commit");
    expect((await resolved(second)).rows[0].result).toEqual({status:"too_many_bridges"});await b.query("commit");
    expect(await f.count("select 1 from public.bridges where user_id=$1 and status='active'",[user])).toBe(10);
    expect(await f.one("select status from public.bridges where id=$1",[revoked])).toEqual({status:first==="new"?"revoked":"active"});
    expect(await f.count("select 1 from public.bridges where user_id=$1 and device_ref='new-last-slot'",[user])).toBe(first==="new"?1:0);
  });
  it.each(["live","reported-terminal"])("P15 heartbeat retains the %s run lock",async kind=>{
    const w=await f.world();
    if(kind==="reported-terminal")await f.updateRow("agent_tasks",w.task,{state:"completed"});
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await a.query("begin");await a.query("select id from public.execution_runs where id=$1 for no key update",[w.run]);
    await b.query("begin");const heartbeat=pending(fb.heartbeat(w,kind==="reported-terminal"?[{task_id:w.task,process_alive:false,last_seq:0}]:[]));
    await blocked();await a.query("commit");expect(await resolved(heartbeat)).toMatchObject({unknown_task_ids:[]});await b.query("commit");
  });
});
