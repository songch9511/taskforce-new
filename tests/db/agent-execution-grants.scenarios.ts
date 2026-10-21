import { expect, it } from "vitest";
import { agentPathLeaseFixtures } from "./agent-path-leases.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

export function agentGrantFixtures(db: () => ConversationAgentDb) {
  const f = agentPathLeaseFixtures(db);
  return { ...f, async scopedWorld(adapter = "agent:claude-code") {
    const base = await f.turnWorld();
    await f.updateRow("agent_connections", base.connection, { adapter });
    const r = await f.start(base.user, base.message);
    expect(r.status).toBe("started");
    const session = String((await f.one("select agent_session_id from public.agent_tasks where id=$1", [r.agent_task_id])).agent_session_id);
    await f.q("update public.execution_controls set blocked=false");
    await f.q("insert into public.agent_execution_grants(user_id,adapter) values($1,'agent:claude-code')", [base.user]);
    const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [r.step_id])).id);
    const mode = String((await f.one("select mode from public.execution_policies where user_id=$1", [base.user])).mode);
    return { ...base, session, task:r.agent_task_id!, run:r.run_id!, step:r.step_id!, action:r.action_id!, turn:r.turn_seq!, command, mode };
  }};
}
export function agentExecutionGrantTests(db: () => ConversationAgentDb) {
  const f = agentGrantFixtures(db);
  it("Claude grant opens exact adapter only; generic begin_call remains actor-gated", async () => {
    const w = await f.scopedWorld();
    for (const [adapter, allowed] of [["agent:claude-code",true],["agent:codex",false],["taskforce",false]] as const) {
      expect(await f.one("select public.agent_execution_allowed($1,$2) allowed",[w.user,adapter])).toEqual({allowed});
    }
    expect(await f.one("select public.agent_execution_allowed($1,'agent:claude-code') allowed",[await f.user()])).toEqual({allowed:false});
    const run = await f.run(w.user,w.action);
    const step = String((await f.one("select id from public.execution_steps where run_id=$1 order by seq limit 1",[run])).id);
    await f.q("select public.prepare_step($1,0)",[step]);
    const version = (await f.one("select version from public.execution_steps where id=$1",[step])).version;
    expect((await f.one("select public.begin_call($1,'grant-test',$2) result",[step,version])).result).toEqual({gate:"actor"});
    expect(await f.lease(w)).toMatchObject({status:"leased",command:{adapter:"agent:claude-code"}});
    expect(await f.lease(w)).toMatchObject({status:"replay"});
  });
  it("grant allows path decision and revocation denies decisions/readback while Stop/cancel still work",async()=>{
    const w=await f.scopedWorld(); await f.lease(w);
    await f.apply(w.user,f.event(w,"accepted",{adapter:"agent:claude-code"}));
    await f.updateRow("agent_sessions",w.session,{workspace_ref:"/w/proj"});
    expect(await f.decide(w,{call_kind:"claude_write"})).toMatchObject({decision:"defer",reason:"manual_write"});
    await f.q("delete from public.agent_execution_grants where user_id=$1",[w.user]);
    expect(await f.decide(w,{call_kind:"claude_write"})).toMatchObject({decision:"deny",reason:"write_gate_closed"});
    await f.stop(w.user,w.session);
    const cancel=String((await f.one("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).id);
    expect(await f.lease({...w,command:cancel},null)).toMatchObject({status:"leased",command:{kind:"cancel"}});
    expect((await f.leases(w.run)).every(row=>row.released_at!==null)).toBe(true);
  });
  it("revocation denies replay before bridge acceptance",async()=>{
    const w=await f.scopedWorld();await f.lease(w);
    await f.q("delete from public.agent_execution_grants where user_id=$1",[w.user]);
    expect(await f.lease(w)).toEqual({status:"stale",reason:"write_gate_closed"});
  });
  it.each(["grant","global","provider","mode","tool"])("scoped lease still denies closed %s",async gate=>{
    const w=await f.scopedWorld();
    if(gate==="grant")await f.q("delete from public.agent_execution_grants where user_id=$1",[w.user]);
    else if(gate==="tool")await f.q("delete from public.execution_tools where provider='agent:claude-code' and tool='message'");
    else await f.q("update public.execution_controls set blocked=true where scope=$1",[gate]);
    try { expect(await f.lease(w)).toMatchObject({status:"withdrawn",reason:"write_gate_closed"}); }
    finally { if(gate==="tool")await f.q("insert into public.execution_tools(provider,tool,effect_class) values('agent:claude-code','message','external')"); }
  });
  it("Claude grant does not lease a Codex command",async()=>{
    const w=await f.scopedWorld("agent:codex");
    expect(await f.lease(w)).toMatchObject({status:"withdrawn",reason:"write_gate_closed"});
  });
  it("legacy execution actor remains supported",async()=>{const w=await f.world();expect(await f.lease(w)).toMatchObject({status:"leased"});});
  it("grants are service-owned with RLS and no self-grant/helper execution",async()=>{
    const w=await f.scopedWorld();
    expect(await f.one("select relrowsecurity enabled from pg_class where oid='public.agent_execution_grants'::regclass")).toEqual({enabled:true});
    for(const role of ["anon","authenticated"]){
      expect(await f.one("select has_table_privilege($1,'public.agent_execution_grants','INSERT,UPDATE,DELETE,SELECT') permitted",[role])).toEqual({permitted:false});
      expect(await f.one("select has_function_privilege($1,'public.agent_execution_allowed(uuid,text)','EXECUTE') permitted",[role])).toEqual({permitted:false});
    }
    expect(await f.one("select prosecdef,proconfig,has_function_privilege('service_role',oid,'execute') permitted from pg_proc where oid='public.agent_execution_allowed(uuid,text)'::regprocedure")).toEqual({prosecdef:false,proconfig:['search_path=""'],permitted:true});
    await db().asUser(w.user,async()=>{await expect(f.q("insert into public.agent_execution_grants(user_id,adapter) values($1,'agent:codex')",[w.user])).rejects.toMatchObject({code:"42501"});});
    await expect(f.q("insert into public.agent_execution_grants(user_id,adapter) values($1,'taskforce')",[w.user])).rejects.toMatchObject({code:"23514"});
  });
}
