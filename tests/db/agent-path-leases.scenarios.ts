import { randomUUID } from "node:crypto";
import { expect, it } from "vitest";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";
export function agentPathLeaseFixtures(db: () => ConversationAgentDb) {
  const f = bridgeCommandFixtures(db);
  const decision = (overrides: Record<string, unknown> = {}) => ({decision:"defer",reason:"manual_write",call_kind:"codex_file_change",access:"write",request_id:"request",workspace_real_path:"/w/proj",targets:[{real_path:"/w/proj/pricing.mdx",rel_path:"pricing.mdx"}],lease_op:"reserve",card_flags:[],...overrides});
  return {...f, decision,
    async live() { const w=await f.world(); await f.updateRow("agent_sessions",w.session,{workspace_ref:"/w/proj"}); await f.lease(w); await f.apply(w.user,f.event(w,"accepted")); return w; },
    async decide(w: {user:string;bridge:string;session:string;task:string;turn:number;mode:string}, patch:Record<string,unknown>={}) {
      return (await f.one("select public.decide_agent_tool_call($1,$2,$3,$4,$5,$6,$7::jsonb) result",[w.user,w.bridge,w.session,w.task,w.turn,w.mode,JSON.stringify(decision(patch))])).result as {status:string;decision?:string;reason?:string;lease_ids:string[];holder?:{action_number:number|null;rel_path:string}};
    },
    async competitor(w: Awaited<ReturnType<typeof f.world>>, sameSession = false) {
      const conversation=await f.agentConversation(w.user,w.connection,sameSession?w.session:null);
      const message=String((await f.post(w.user,conversation,randomUUID(),"Competing work")).message_id);
      const action=await f.action(w.user);
      const r=await f.start(w.user,message,[action]);
      expect(r.status).toBe("started");
      const session=String((await f.one("select agent_session_id from public.agent_tasks where id=$1",[r.agent_task_id])).agent_session_id);
      await f.updateRow("agent_sessions",session,{workspace_ref:"/w/proj"});
      await f.updateRow("agent_tasks",r.agent_task_id!,{state:"accepted"});
      return {...w,conversation,message,session,task:r.agent_task_id!,run:r.run_id!,step:r.step_id!,action:r.action_id!,turn:r.turn_seq!};
    },
    leases: (run:string) => f.q("select * from public.agent_path_leases where run_id=$1 order by path_key",[run]),
  };
}
export function agentPathLeaseTests(db: () => ConversationAgentDb) {
 const f=agentPathLeaseFixtures(db);
 it("T1 table, narrow FKs and service-only function privileges",async()=>{
  expect(await f.one("select to_regclass('public.agent_path_leases')::text name")).toEqual({name:"agent_path_leases"});
  expect(await f.q("select confrelid::regclass::text parent from pg_constraint where conrelid='public.agent_path_leases'::regclass and contype='f' order by parent")).toEqual([{parent:"auth.users"},{parent:"bridges"},{parent:"execution_runs"}]);
  const names=["agent_path_key","agent_write_gate_open","decide_agent_tool_call","answer_agent_approval","sweep_agent_path_leases","list_pending_path_conflict_stops","stop_agent_run_for_path_conflict","list_path_lease_notices","mark_path_lease_notices","list_path_conflicts","resolve_path_conflict","purge_agent_path_leases","agent_path_leases_task_state","agent_path_leases_run_end","agent_path_leases_session_external","agent_path_leases_on_artifact"];
  const rows=await f.q("select proname,prosecdef,proconfig,has_function_privilege('authenticated',p.oid,'execute') app,has_function_privilege('anon',p.oid,'execute') anon,has_function_privilege('service_role',p.oid,'execute') server from pg_proc p where pronamespace='public'::regnamespace and proname=any($1)",[names]);
  expect(rows).toHaveLength(names.length);for(const row of rows){expect(row).toMatchObject({prosecdef:false,app:false,anon:false,server:true});expect(row.proconfig).toContain('search_path=""');}
 });
 it.each(["relative","/w//x","/w/./x","/w/../x","/w/x/","/w/\n",`/${"x".repeat(1000)}`])("T2 invalid path %j",async path=>expect(await f.one("select public.agent_path_key($1) key",[path])).toEqual({key:null}));
 it("T2 P11 NFC and ASCII fold; non-ASCII case remains distinct",async()=>{
  expect(await f.one("select public.agent_path_key('/W/Proj/Café')=public.agent_path_key('/w/proj/Café') same,public.agent_path_key('/É')=public.agent_path_key('/é') nonascii")).toEqual({same:true,nonascii:false});
  const w=await f.live();expect(await f.decide(w,{call_kind:"claude_write",targets:[{real_path:"/w/proj2/x",rel_path:"x"}]})).toMatchObject({status:"not_found"});
  expect(await f.decide(w,{targets:[{real_path:"/w/proj2/x",rel_path:"x"}]})).toMatchObject({decision:"defer",lease_ids:[]});
 });
 it.each(["user","bridge","adapter"])("T3 foreign %s is write-free",async kind=>{
  const w=await f.live(), candidate={...w};if(kind==="user")candidate.user=await f.user();if(kind==="bridge")candidate.bridge=await f.bridge(w.user);
  expect(await f.decide(candidate,kind==="adapter"?{call_kind:"claude_write"}:{})).toEqual({status:"not_found"});expect(await f.leases(w.run)).toEqual([]);
 });
 it.each(["idle","cancelled","turn","stopped"])("T3/T5 %s downgrades allow",async state=>{
  const w=await f.live();if(state==="turn")w.turn++;else if(state==="stopped")await f.updateRow("execution_runs",w.run,{state:"stopped"});else await f.updateRow("agent_tasks",w.task,{state});
  expect(await f.decide(w,{decision:"allow",reason:"policy_auto",lease_op:"acquire"})).toMatchObject({decision:"deny",reason:"not_live"});expect(await f.leases(w.run)).toEqual([]);
 });
 it("T4/T5 reservation remains defer and same run acquire promotes only lease",async()=>{
  const w=await f.live();const first=await f.decide(w);expect(first).toMatchObject({decision:"defer",reason:"manual_write"});expect(first.lease_ids).toHaveLength(1);
  expect((await f.leases(w.run))[0]).toMatchObject({source:"requested",request_id:"request"});
  expect(await f.decide(w,{decision:"allow",reason:"policy_auto",lease_op:"acquire"})).toMatchObject({decision:"allow",lease_ids:first.lease_ids});expect((await f.leases(w.run))[0]).toMatchObject({source:"approved",expires_at:null});
 });
 it("T6 policy race makes no metric, lease or rate-limit writes",async()=>{
  const w=await f.live();expect(await f.decide({...w,mode:"full"})).toEqual({status:"policy_changed"});expect(await f.leases(w.run)).toEqual([]);expect(await f.q("select 1 from public.metric_events where user_id=$1 and type='tool_call_decided'",[w.user])).toEqual([]);expect(await f.q("select 1 from public.rate_limit_events where user_id=$1 and kind='bridge_decide'",[w.user])).toEqual([]);
 });
 it.each(["actor","global","provider","mode","tool"])("T7 closed %s gate denies",async gate=>{
  const w=await f.live();if(gate==="actor")await f.q("delete from public.execution_actors where user_id=$1",[w.user]);else if(gate==="tool")await f.q("delete from public.execution_tools where provider='agent:codex' and tool='message'");else await f.q("update public.execution_controls set blocked=true where scope=$1",[gate]);
  expect(await f.decide(w)).toMatchObject({decision:"deny",reason:"write_gate_closed"});if(gate==="tool")await f.q("insert into public.execution_tools(provider,tool,effect_class) values('agent:codex','message','external')");
 });
 it.each(["done","failed","stopped"])("T9 run %s releases lease",async state=>{
  const w=await f.live();await f.decide(w);await f.updateRow("execution_runs",w.run,{state});expect((await f.leases(w.run))[0]).toMatchObject({release_reason:"run_ended"});
 });
 it("T9 external releases leases",async()=>{const w=await f.live();await f.decide(w);await f.updateRow("agent_sessions",w.session,{status:"external"});expect((await f.leases(w.run))[0]).toMatchObject({release_reason:"session_external"});});
 it("T10 idle boundary and accepted renewal",async()=>{
  const w=await f.live();await f.decide(w,{lease_op:"acquire"});await f.updateRow("agent_tasks",w.task,{state:"idle"});
  expect(await f.one("select round(extract(epoch from(expires_at-public.db_now()))/60)::int minutes from public.agent_path_leases where run_id=$1",[w.run])).toEqual({minutes:30});
  await f.q("update public.agent_path_leases set expires_at=public.db_now()+interval '1 minute' where run_id=$1",[w.run]);await f.q("select public.sweep_agent_path_leases(500)");expect((await f.leases(w.run))[0].released_at).toBeNull();
  await f.updateRow("agent_tasks",w.task,{state:"accepted"});expect((await f.leases(w.run))[0].expires_at).toBeNull();
  await f.q("begin");
  try{await f.q("update public.agent_path_leases set expires_at=public.db_now() where run_id=$1",[w.run]);await f.q("select public.sweep_agent_path_leases(500)");expect((await f.leases(w.run))[0].release_reason).toBe("idle_expired");}finally{await f.q("rollback");}
 });
 it("T14 600th permitted, 601st denied, bridge buckets independent",async()=>{
  const w=await f.live();await f.q("insert into public.rate_limit_events(user_id,bridge_id,kind,created_at) select $1,$2,'bridge_decide',clock_timestamp() from generate_series(1,599)",[w.user,w.bridge]);expect(await f.decide(w)).toMatchObject({decision:"defer"});expect(await f.decide(w)).toMatchObject({decision:"deny",reason:"rate_limited"});const other=await f.bridge(w.user);expect(await f.one("select public.take_rate_limit($1,'bridge_decide',600,60,$2) retry",[w.user,other])).toEqual({retry:null});
 });
 it("T15 metrics omit commands, paths and ids and write once per decision",async()=>{
  const w=await f.live();await f.decide(w);const rows=await f.q("select props from public.metric_events where user_id=$1 and type='tool_call_decided'",[w.user]);expect(rows).toHaveLength(1);expect(rows[0].props).toMatchObject({decision:"defer",reason:"manual_write",adapter:"agent:codex"});expect(JSON.stringify(rows)).not.toContain("/w/");expect(JSON.stringify(rows)).not.toContain(w.run);
 });
 it("T16 retention keeps live and unresolved conflict rows",async()=>{
  const w=await f.live();await f.decide(w);expect(await f.one("select public.purge_agent_path_leases(now()-interval '30 days',500) n")).toEqual({n:0});await f.q("update public.agent_path_leases set released_at=now()-interval '31 days',release_reason='run_ended' where run_id=$1",[w.run]);expect(await f.one("select public.purge_agent_path_leases(now()-interval '30 days',500) n")).toEqual({n:1});
 });
 it("T1 RLS owner only, no app writes and user cascade",async()=>{
  const a=await f.live(),b=await f.live();await f.decide(a);await f.decide(b);const own=await f.leases(a.run);
  await db().asUser(a.user,async()=>{expect(await f.q("select id from public.agent_path_leases where run_id=any($1)",[[a.run,b.run]])).toEqual([{id:own[0].id}]);await expect(f.q("delete from public.agent_path_leases where id=$1",[own[0].id])).rejects.toMatchObject({code:"42501"});});
  await f.q("delete from auth.users where id=$1",[a.user]);expect(await f.leases(a.run)).toEqual([]);
 });
 it("T4 held path rolls back all acquisitions and deduplicates waiter",async()=>{
  const a=await f.live();
  const conv=await f.agentConversation(a.user,a.connection,null),msg=String((await f.post(a.user,conv,randomUUID(),"Competing task")).message_id),started=await f.start(a.user,msg);
  const task=String(started.agent_task_id),session=String((await f.one("select agent_session_id from public.agent_tasks where id=$1",[task])).agent_session_id);
  await f.updateRow("agent_sessions",session,{workspace_ref:"/w/proj"});await f.updateRow("agent_tasks",task,{state:"accepted"});
  const c={...a,session,task,run:String(started.run_id),turn:Number(started.turn_seq)};await f.decide(a);
  const targets=[{real_path:"/w/proj/a",rel_path:"a"},{real_path:"/w/proj/Pricing.mdx",rel_path:"Pricing.mdx"}];
  for(let n=0;n<2;n++)expect(await f.decide(c,{targets})).toMatchObject({decision:"deny",reason:"path_in_use",holder:{rel_path:"pricing.mdx"}});
  expect(await f.leases(c.run)).toEqual([]);expect((await f.leases(a.run))[0].waiter_run_ids).toEqual([c.run]);
 });
 it.each(["allow","deny"])("T8 %s modifies only matching reservation and emits once",async answer=>{
  const w=await f.live();await f.decide(w);await f.decide(w,{request_id:"other",targets:[{real_path:"/w/proj/other",rel_path:"other"}]});
  await f.decide(w,{decision:"allow",reason:"policy_auto",lease_op:"acquire",request_id:"unrelated-approved",targets:[{real_path:"/w/proj/approved",rel_path:"approved"}]});
  await f.q("insert into public.agent_path_leases(user_id,bridge_id,run_id,agent_session_id,workspace_ref,path_key,rel_path,source) values($1,$2,$3,$4,'/w/proj','/w/proj/observed','observed','observed')",[w.user,w.bridge,w.run,w.session]);
  await f.apply(w.user,f.event(w,"question",{text:"Approval",question:{provider_request_id:"request",kind:"approval",structured:true,questions:[{id:"approval",header:"Approval",text:"Allow?",options:[{label:"Allow",description:"Allow"},{label:"Deny",description:"Deny"}],multi_select:false,allow_other:false,secret:false}]}}));
  const call=()=>f.one("select public.answer_agent_approval($1,$2,'request',$3::jsonb) result",[w.user,w.task,JSON.stringify({approval:answer})]);
  expect((await call()).result).toMatchObject({status:"answered"});expect((await call()).result).toMatchObject({status:"duplicate"});
  const rows=await f.leases(w.run);expect(rows.find(r=>r.rel_path==="approved")).toMatchObject({source:"approved",released_at:null});expect(rows.find(r=>r.rel_path==="observed")).toMatchObject({source:"observed",released_at:null});expect(rows.find(r=>r.rel_path==="other")).toMatchObject({source:"requested",released_at:null});expect(rows.find(r=>r.rel_path==="pricing.mdx")).toMatchObject(answer==="allow"?{source:"approved",released_at:null}:{source:"requested",release_reason:"request_denied"});
  expect(await f.q("select props from public.metric_events where user_id=$1 and type='question_answered'",[w.user])).toEqual([{props:{kind:"approval",adapter:"agent:codex",decision:answer}}]);
 });
 it("T11 observed lease and same-run artifact do not conflict",async()=>{
  const w=await f.live();for(const path of ["pricing.mdx","other"])await f.apply(w.user,f.event(w,"artifact",{payload:{path,hash:"abc",summary:"File"}}));
  expect(await f.leases(w.run)).toHaveLength(2);expect((await f.leases(w.run))[0]).toMatchObject({source:"observed",request_id:null,conflict_run_id:null});
  expect(await f.q("select 1 from public.metric_events where user_id=$1 and type='path_conflict_found'",[w.user])).toEqual([]);
 });
 it("T12 external notices mark only matching version",async()=>{
  const w=await f.live();await f.decide(w);await f.updateRow("agent_sessions",w.session,{status:"external"});
  const rows=(await f.one("select public.list_path_lease_notices(500) result")).result as Record<string,unknown>[];const notices=rows.filter(r=>r.user_id===w.user);expect(notices).toHaveLength(1);expect(notices[0]).toMatchObject({text:"File locks released",originating_only:false});
  const stamp={lease_id:notices[0].lease_id,released_at:notices[0].released_at,conflict_at:notices[0].conflict_at,conflict_stop_at:notices[0].conflict_stop_at};
  await f.q("select public.mark_path_lease_notices($1::jsonb)",[JSON.stringify([stamp])]);const after=(await f.one("select public.list_path_lease_notices(500) result")).result as Record<string,unknown>[];expect(after.filter(r=>r.user_id===w.user)).toEqual([]);
 });
 it("T13 conflict list includes released rows and resolution CAS",async()=>{
  const w=await f.live(),later=await f.competitor(w);await f.decide(w);const lease=(await f.leases(w.run))[0];
  await f.q("update public.agent_path_leases set conflict_run_id=$2,conflict_at=now(),released_at=now(),release_reason='run_ended' where id=$1",[lease.id,later.run]);
  const current=(await f.leases(w.run))[0];expect(((await f.one("select public.list_path_conflicts($1,100) result",[w.user])).result as unknown[])).toHaveLength(1);
  expect((await f.one("select public.resolve_path_conflict($1,$2,'holder',-1) result",[w.user,lease.id])).result).toEqual({status:"stale"});
  expect((await f.one("select public.resolve_path_conflict($1,$2,'holder',$3) result",[w.user,lease.id,current.conflict_version])).result).toMatchObject({status:"resolved"});expect((await f.leases(w.run))[0].conflict_run_id).toBeNull();
 });

 it("T2 sibling folder, wildcard characters and root boundary use literal prefixes",async()=>{
  const w=await f.live();await f.updateRow("agent_connections",w.connection,{adapter:"agent:claude-code"});
  for(const real_path of ["/w/proj2/x","/w/proj","/w/proj/../x"]){expect(await f.decide(w,{call_kind:"claude_write",targets:[{real_path,rel_path:"x"}]})).toMatchObject({decision:"deny",reason:"outside_workspace"});}
  await f.updateRow("agent_sessions",w.session,{workspace_ref:"/w/p_%"});expect(await f.decide(w,{workspace_real_path:"/w/p_%",call_kind:"claude_write",targets:[{real_path:"/w/pAA/x",rel_path:"x"}]})).toMatchObject({decision:"deny",reason:"outside_workspace"});
 });
 it.each(["dispatched-leased","dispatched-unleased","unreachable-accepted","unreachable-dispatched"])("T3 %s live evidence",async kind=>{
  const w=await f.live();const dispatched=kind.includes("dispatched");
  await f.updateRow("agent_tasks",w.task,{state:kind.startsWith("unreachable")?"unreachable":"dispatched",last_live_state:kind.startsWith("unreachable")?(dispatched?"dispatched":"accepted"):null});
  if(dispatched)await f.updateRow("execution_steps",w.step,{state:kind.endsWith("unleased")?"prepared":"calling",lease_owner:kind.endsWith("unleased")?null:`bridge:${w.bridge}:fixture`});
  expect(await f.decide(w)).toMatchObject(kind.endsWith("unleased")?{decision:"deny",reason:"not_live"}:{decision:"defer",reason:"manual_write"});
 });
 it("T4 waiters cap at 20 and same-session different issue yields",async()=>{
  const a=await f.live();await f.decide(a,{lease_op:"acquire"});await f.updateRow("agent_tasks",a.task,{state:"idle"});const b=await f.competitor(a,true);
  await f.q("update public.agent_path_leases set waiter_run_ids=$2 where run_id=$1",[a.run,Array.from({length:20},()=>randomUUID())]);
  expect(await f.decide(b)).toMatchObject({decision:"deny",reason:"path_in_use"});expect(((await f.leases(a.run))[0].waiter_run_ids as string[])).toHaveLength(20);
 });
 it.each(["holder","later"])("T11/T13 same-account conflict stops later run and resolves %s",async keep=>{
  const a=await f.live(),b=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});
  await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[b.user,b.run,b.task,b.turn]);
  let lease=(await f.leases(a.run))[0];expect(lease).toMatchObject({conflict_run_id:b.run,conflict_stop_at:null});
  expect(await f.q("select props from public.metric_events where user_id=$1 and type='path_conflict_found'",[a.user])).toEqual([{props:{adapter:"agent:codex"}}]);
  expect((await f.one("select public.stop_agent_run_for_path_conflict($1,$2) result",[a.user,lease.id])).result).toMatchObject({status:"stopped"});
  expect(await f.one("select state,stopped_at from public.execution_runs where id=$1",[b.run])).toEqual({state:"stopped",stopped_at:null});
  expect((await f.one("select public.stop_agent_run_for_path_conflict($1,$2) result",[a.user,lease.id])).result).toMatchObject({status:"noop"});
  lease=(await f.leases(a.run))[0];expect(lease.conflict_stop_at).not.toBeNull();
  expect((await f.one("select public.list_path_conflicts($1,100) result",[a.user])).result).toMatchObject([{lease_id:lease.id,holder_run_id:a.run,conflict_run_id:b.run,released:false}]);
  expect((await f.one("select public.resolve_path_conflict($1,$2,$3,$4) result",[a.user,lease.id,keep,lease.conflict_version])).result).toEqual({status:"resolved"});
  expect((await f.leases(a.run))[0]).toMatchObject({conflict_run_id:null,conflict_at:null,conflict_stop_at:null,release_reason:keep==="later"?"conflict_resolved":null});
  expect(await f.q("select props from public.metric_events where user_id=$1 and type='path_conflict_resolved'",[a.user])).toEqual([{props:{keep}}]);
 });
 it("T11 same-path same-run inserts, pending and invalid artifacts",async()=>{
  const w=await f.live();for(let n=0;n<2;n++){
   await f.q("update public.agent_artifacts set superseded_at=now() where run_id=$1",[w.run]);
   await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[w.user,w.run,w.task,w.turn]);
  }
  expect(await f.leases(w.run)).toHaveLength(1);expect((await f.leases(w.run))[0].conflict_run_id).toBeNull();
  await f.updateRow("agent_sessions",w.session,{workspace_ref:"pending:fixture"});
  await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pending','hash','Changed')",[w.user,w.run,w.task,w.turn]);
  await f.updateRow("agent_sessions",w.session,{workspace_ref:"/w/proj"});
  await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'../outside','hash','Changed')",[w.user,w.run,w.task,w.turn]);
  expect(await f.leases(w.run)).toHaveLength(1);
 });
 it("T15 failed metric insert rolls back new lease and request bucket",async()=>{
  const w=await f.live();await f.q("alter table public.metric_events add constraint path_test_metric_failure check(type<>'tool_call_decided') not valid");
  try{await expect(f.decide(w)).rejects.toMatchObject({code:"23514"});expect(await f.leases(w.run)).toEqual([]);expect(await f.q("select 1 from public.rate_limit_events where user_id=$1 and kind='bridge_decide'",[w.user])).toEqual([]);}finally{await f.q("alter table public.metric_events drop constraint path_test_metric_failure");}
 });

 it("T1 lease CHECKs and partial unique fail atomically",async()=>{
  const w=await f.live();await f.decide(w);const lease=(await f.leases(w.run))[0];
  for(const patch of [{released_at:new Date().toISOString()},{release_reason:"run_ended"},{conflict_run_id:randomUUID()},{conflict_at:new Date().toISOString()},{conflict_stop_at:new Date().toISOString()},{conflict_run_id:w.run,conflict_at:new Date().toISOString()},{source:"observed"},{request_id:null}]){
    await expect(f.updateRow("agent_path_leases",String(lease.id),patch)).rejects.toMatchObject({code:"23514"});
  }
  await expect(f.q("update public.agent_path_leases set waiter_run_ids=$2::uuid[] where id=$1",[lease.id,Array.from({length:21},()=>randomUUID())])).rejects.toMatchObject({code:"23514"});
  await expect(f.q("insert into public.agent_path_leases(user_id,bridge_id,run_id,agent_session_id,workspace_ref,path_key,rel_path,source) values($1,$2,$3,$4,'/w/proj','/w/proj/pricing.mdx','pricing.mdx','observed')",[w.user,w.bridge,w.run,w.session])).rejects.toMatchObject({code:"23505"});
  await f.q("update public.agent_path_leases set released_at=now(),release_reason='request_denied' where id=$1",[lease.id]);expect((await f.decide(w)).lease_ids).not.toEqual([lease.id]);
 });
 it("T2 every control character and SQL NUL boundary",async()=>{
  for(const code of [...Array.from({length:31},(_,i)=>i+1),127])expect(await f.one("select public.agent_path_key($1) key",[`/w/${String.fromCharCode(code)}`])).toEqual({key:null});
  await expect(f.one("select public.agent_path_key(chr(0)) key")).rejects.toMatchObject({code:"54000"});
 });
 it.each(["error","revoked"])("T7 connection %s gate closes",async status=>{const w=await f.live();await f.updateRow("agent_connections",w.connection,{status});expect(await f.decide(w)).toMatchObject({decision:"deny",reason:"write_gate_closed"});});
 it("T7 D2a and path gate same fixtures",async()=>{
  const w=await f.world();expect(await f.one("select public.agent_write_gate_open($1,'agent:codex',$2) open",[w.user,w.mode])).toEqual({open:true});
  await f.q("update public.execution_controls set blocked=true where scope='provider' and key='agent:codex'");
  expect(await f.one("select public.agent_write_gate_open($1,'agent:codex',$2) open",[w.user,w.mode])).toEqual({open:false});
  expect(await f.lease(w)).toMatchObject({status:"withdrawn",reason:"write_gate_closed"});
 });
 it("T8 stale and invalid answer preserve reservation and metrics",async()=>{
  const w=await f.live();await f.decide(w);
  await f.apply(w.user,f.event(w,"question",{text:"Approval",question:{provider_request_id:"request",kind:"approval",structured:true,questions:[{id:"approval",header:"Approval",text:"Allow?",options:[{label:"Allow",description:"Allow"},{label:"Deny",description:"Deny"}],multi_select:false,allow_other:false,secret:false}]}}));
  const before=await f.leases(w.run);
  expect((await f.one("select public.answer_agent_approval($1,$2,'stale','{\"approval\":\"allow\"}') result",[w.user,w.task])).result).toEqual({status:"question_stale"});
  expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"other\"}') result",[w.user,w.task])).result).toEqual({status:"invalid_answer"});
  expect(await f.leases(w.run)).toEqual(before);expect(await f.q("select 1 from public.metric_events where user_id=$1 and type='question_answered'",[w.user])).toEqual([]);
 });
 it.each(["idle","failed","cancelled","unreachable"])("T9 task %s expiry rule",async state=>{
  const w=await f.live();await f.decide(w,{lease_op:"acquire"});await f.updateRow("agent_tasks",w.task,{state,last_live_state:state==="unreachable"?"accepted":null});
  const lease=(await f.leases(w.run))[0];if(state==="unreachable")expect(lease.expires_at).toBeNull();else expect(lease.expires_at).not.toBeNull();
 });
 it("T10 sweep limit and terminal-run backup",async()=>{
  const w=await f.live();await f.decide(w);await f.updateRow("execution_runs",w.run,{state:"stopped"});
  await f.q("update public.agent_path_leases set released_at=null,release_reason=null where run_id=$1",[w.run]);
  expect((await f.one("select public.sweep_agent_path_leases(0) result")).result).toEqual({expired:0,run_ended:0});
  await f.q("select public.sweep_agent_path_leases(500)");expect((await f.leases(w.run))[0].release_reason).toBe("run_ended");
 });
 it("T12 stale notice marks do not suppress newer release",async()=>{
  const w=await f.live();await f.decide(w);await f.updateRow("agent_sessions",w.session,{status:"external"});const lease=(await f.leases(w.run))[0];
  const stamp={lease_id:lease.id,released_at:lease.released_at,conflict_at:null,conflict_stop_at:null};
  await f.q("update public.agent_path_leases set released_at=released_at+interval '1 second' where id=$1",[lease.id]);
  expect(await f.one("select public.mark_path_lease_notices($1::jsonb) n",[JSON.stringify([stamp])])).toEqual({n:0});expect((await f.leases(w.run))[0].release_notified_at).toBeNull();
 });
 it("T15 approval metric failure rolls back answer and approval promotion",async()=>{
  const w=await f.live();await f.decide(w);await f.apply(w.user,f.event(w,"question",{text:"Approval",question:{provider_request_id:"request",kind:"approval",structured:true,questions:[{id:"approval",header:"Approval",text:"Allow?",options:[{label:"Allow",description:"Allow"},{label:"Deny",description:"Deny"}],multi_select:false,allow_other:false,secret:false}]}}));
  await f.q("alter table public.metric_events add constraint path_test_metric_failure check(type<>'question_answered') not valid");
  try{await expect(f.q("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"allow\"}')",[w.user,w.task])).rejects.toMatchObject({code:"23514"});expect((await f.leases(w.run))[0].source).toBe("requested");expect(await f.state(w)).toMatchObject({state:"awaiting_answer"});}finally{await f.q("alter table public.metric_events drop constraint path_test_metric_failure");}
 });
 it("T15 conflict metric failure rolls back artifact and conflict",async()=>{
  const a=await f.live(),b=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});
  await f.q("alter table public.metric_events add constraint path_test_metric_failure check(type<>'path_conflict_found') not valid");
  try{await expect(f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[b.user,b.run,b.task,b.turn])).rejects.toMatchObject({code:"23514"});expect((await f.leases(a.run))[0].conflict_run_id).toBeNull();expect(await f.q("select 1 from public.agent_artifacts where run_id=$1",[b.run])).toEqual([]);}finally{await f.q("alter table public.metric_events drop constraint path_test_metric_failure");}
 });
 it("T16 released unresolved conflict survives retention",async()=>{
  const a=await f.live(),b=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});await f.q("update public.agent_path_leases set released_at=now()-interval '31 days',release_reason='run_ended',conflict_run_id=$2,conflict_at=now() where run_id=$1",[a.run,b.run]);
  await f.q("select public.purge_agent_path_leases(now()-interval '30 days',500)");expect(await f.leases(a.run)).toHaveLength(1);
 });

 it("T11 artifact arriving after idle gets bounded lease expiry",async()=>{
  const w=await f.live();await f.apply(w.user,f.event(w,"turn_completed",{seq:10}));
  expect(await f.state(w)).toMatchObject({state:"idle"});
  await f.apply(w.user,f.event(w,"artifact",{seq:11,payload:{path:"late.mdx",hash:"late",summary:"Late artifact"}}));
  expect(await f.one("select round(extract(epoch from(expires_at-public.db_now()))/60)::int minutes from public.agent_path_leases where run_id=$1",[w.run])).toEqual({minutes:30});
 });

 it("T8 underlying stale-before-kind precedence",async()=>{
  const w=await f.questionWorld();
  expect((await f.one("select public.answer_agent_approval($1,$2,'old-request','{\"approval\":\"allow\"}') result",[w.user,w.task])).result).toEqual({status:"question_stale"});
 });

 it("T8 approval wrapper rolls back an otherwise valid input answer",async()=>{
  const w=await f.questionWorld({provider_request_id:"request",kind:"input",structured:true,questions:[{id:"approval",header:"Input",text:"Choose",options:[{label:"allow",description:"Option"}],multi_select:false,allow_other:false,secret:false}]});
  const before=await f.state(w);
  expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"allow\"}') result",[w.user,w.task])).result).toEqual({status:"invalid_answer"});
  expect(await f.state(w)).toEqual(before);expect(await f.answerSteps(w.task)).toEqual([]);
 });

 it.each(["decision","artifact"])("T4 absent insert winner is retryable for %s",async kind=>{
  const w=await f.live();
  await f.q("create function public.path_test_suppress_insert() returns trigger language plpgsql as $$ begin return null; end $$");
  await f.q("create trigger path_test_suppress_insert before insert on public.agent_path_leases for each row execute function public.path_test_suppress_insert()");
  try{
    if(kind==="decision")expect(await f.decide(w,{decision:"allow",reason:"policy_auto",lease_op:"acquire"})).toMatchObject({decision:"defer",reason:"server_busy",lease_ids:[]});
    else await expect(f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[w.user,w.run,w.task,w.turn])).rejects.toMatchObject({code:"55P03"});
    expect(await f.leases(w.run)).toEqual([]);expect(await f.q("select 1 from public.agent_artifacts where run_id=$1",[w.run])).toEqual([]);
  }finally{await f.q("drop trigger path_test_suppress_insert on public.agent_path_leases");await f.q("drop function public.path_test_suppress_insert()");}
 });


 it.each(["running","awaiting_answer"])("R2 live %s clears prior expiry",async state=>{
  const w=await f.live();await f.decide(w,{lease_op:"acquire"});await f.updateRow("agent_tasks",w.task,{state:"idle"});if(state==="awaiting_answer")await f.updateRow("agent_tasks",w.task,{pending_question:{...answerQuestionFixture(),question_key:[w.task,"request"],asked_at:"2026-10-13T12:00:00Z"}});await f.updateRow("agent_tasks",w.task,{state});expect((await f.leases(w.run))[0].expires_at).toBeNull();
 });
 it.each(["decision","artifact"])("R3 stale holder is reclaimed by %s before sweep",async kind=>{
  const a=await f.live(),b=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});await f.q("update public.agent_path_leases set expires_at=public.db_now()-interval '1 second' where run_id=$1",[a.run]);
  if(kind==="decision")expect(await f.decide(b)).toMatchObject({decision:"defer"});else await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[b.user,b.run,b.task,b.turn]);
  expect((await f.leases(a.run))[0]).toMatchObject({release_reason:"idle_expired",conflict_run_id:null});expect(await f.leases(b.run)).toHaveLength(1);
 });
 it.each(["done","external"])("R3/R15 %s artifacts create no lease",async kind=>{
  const w=await f.live();if(kind==="done")await f.updateRow("execution_runs",w.run,{state:"done"});else await f.updateRow("agent_sessions",w.session,{status:"external"});
  await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'late','hash','Changed')",[w.user,w.run,w.task,w.turn]);expect(await f.leases(w.run)).toEqual([]);
 });
 it.each([".GIT/config",".claude/settings.json",".codex/config.toml",".vscode/settings.json",".idea/x",".husky/x",".envrc",".mcp.json",".gitattributes",".gitmodules"])("R5 protected path %s defers",async path=>{
  const w=await f.live();expect(await f.decide(w,{decision:"allow",reason:"policy_auto",lease_op:"acquire",targets:[{real_path:`/w/proj/${path}`,rel_path:"fake"}]})).toMatchObject({decision:"defer",reason:"tool_config_write"});expect((await f.leases(w.run))[0].source).toBe("requested");
 });
 it("R6 containment preserves case and pending root is invalid",async()=>{
  const w=await f.live();await f.updateRow("agent_connections",w.connection,{adapter:"agent:claude-code"});expect(await f.decide(w,{call_kind:"claude_write",targets:[{real_path:"/w/PROJ/x",rel_path:"x"}]})).toMatchObject({decision:"deny",reason:"outside_workspace"});
  expect(await f.decide(w,{call_kind:"claude_write",workspace_real_path:"/w/PROJ"})).toMatchObject({decision:"deny",reason:"workspace_mismatch"});
  await f.updateRow("agent_sessions",w.session,{workspace_ref:"pending:fixture"});for(const workspace_real_path of ["/","/Users"])expect(await f.decide(w,{call_kind:"claude_write",workspace_real_path})).toMatchObject({decision:"deny",reason:"workspace_mismatch"});
 });
 it("R7 rel_path is derived from canonical real path",async()=>{const w=await f.live();await f.decide(w,{targets:[{real_path:"/w/proj/sub/Café",rel_path:"forged"}]});expect((await f.leases(w.run))[0].rel_path).toBe("sub/Café");});
 it.each(["idle","failed","cancelled"])("R8 %s releases unapproved reservations",async state=>{const w=await f.live();await f.decide(w);await f.updateRow("agent_tasks",w.task,{state});expect((await f.leases(w.run))[0].release_reason).toBe("request_denied");});
 it("R8 reserved holder is not an artifact conflict",async()=>{const a=await f.live(),b=await f.competitor(a);await f.decide(a);await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[b.user,b.run,b.task,b.turn]);expect((await f.leases(a.run))[0].conflict_run_id).toBeNull();});
 it("R10 NFC expansion denies decision and skips only artifact lease",async()=>{
  const w=await f.live(),path="क़".repeat(600);expect(await f.decide(w,{targets:[{real_path:`/w/proj/${path}`,rel_path:path}]})).toMatchObject({decision:"deny",reason:"path_too_long"});
  await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,$5,'hash','Changed')",[w.user,w.run,w.task,w.turn,path]);expect(await f.leases(w.run)).toEqual([]);
 });
 it("R12 noop stop leaves no stop marker or notice",async()=>{const a=await f.live(),b=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});const lease=(await f.leases(a.run))[0];await f.q("update public.agent_path_leases set conflict_run_id=$2,conflict_at=now() where id=$1",[lease.id,b.run]);await f.updateRow("execution_runs",b.run,{state:"done"});expect((await f.one("select public.stop_agent_run_for_path_conflict($1,$2) result",[a.user,lease.id])).result).toMatchObject({status:"noop"});expect((await f.leases(a.run))[0].conflict_stop_at).toBeNull();});
 it("R13 releases without recipients are already marked",async()=>{const w=await f.live();await f.decide(w);await f.updateRow("execution_runs",w.run,{state:"done"});expect((await f.leases(w.run))[0].release_notified_at).not.toBeNull();});
 it("R4 duplicate different answer and reused key fail closed",async()=>{
  const w=await f.live();await f.decide(w);await f.apply(w.user,f.event(w,"question",{text:"Approval",question:{provider_request_id:"request",kind:"approval",structured:true,questions:[{id:"approval",header:"Approval",text:"Allow?",options:[{label:"Allow",description:"Allow"},{label:"Deny",description:"Deny"}],multi_select:false,allow_other:false,secret:false}]}}));
  expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"allow\"}') result",[w.user,w.task])).result).toMatchObject({status:"answered"});expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"deny\"}') result",[w.user,w.task])).result).toEqual({status:"question_stale"});expect(await f.decide(w)).toMatchObject({decision:"deny",reason:"not_first_request"});const answered=(await f.one("select answered_question from public.agent_tasks where id=$1",[w.task])).answered_question;await f.updateRow("agent_tasks",w.task,{pending_question:answered,state:"awaiting_answer"});expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"allow\"}') result",[w.user,w.task])).result).toEqual({status:"question_stale"});
 });


 it.each(["external","closed"])("R15 session %s cannot decide",async status=>{const w=await f.live();await f.updateRow("agent_sessions",w.session,{status});expect(await f.decide(w,{decision:"allow",lease_op:"acquire"})).toMatchObject({decision:"deny",reason:"not_live"});});
 it("R15 pending workspace can bind a concrete two-level path",async()=>{const w=await f.live();await f.updateRow("agent_sessions",w.session,{workspace_ref:"pending:fixture"});expect(await f.decide(w)).toMatchObject({decision:"defer"});expect(await f.leases(w.run)).toHaveLength(1);});
 it("R15 third writer does not overwrite first conflict",async()=>{const a=await f.live(),b=await f.competitor(a),c=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});for(const w of [b,c])await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')",[w.user,w.run,w.task,w.turn]);expect((await f.leases(a.run))[0]).toMatchObject({conflict_run_id:b.run,conflict_version:1});});
 it("R15 stale conflict-stop acknowledgement cannot hide new notice",async()=>{const a=await f.live(),b=await f.competitor(a);await f.decide(a,{lease_op:"acquire"});const l=(await f.leases(a.run))[0];await f.q("update public.agent_path_leases set conflict_run_id=$2,conflict_at=now() where id=$1",[l.id,b.run]);const before=(await f.leases(a.run))[0];await f.one("select public.stop_agent_run_for_path_conflict($1,$2)",[a.user,l.id]);expect(await f.one("select public.mark_path_lease_notices($1::jsonb) n",[JSON.stringify([{lease_id:l.id,released_at:null,conflict_at:before.conflict_at,conflict_stop_at:null}])])).toEqual({n:0});});
 it("R17 Deny releases the row newly inserted by a late committed allow and preserves another run",async()=>{
  const a=await f.live(),b=await f.competitor(a);
  expect(await f.decide(a,{decision:"allow",reason:"policy_auto",request_id:"request",lease_op:"acquire"})).toMatchObject({decision:"allow"});
  await f.decide(b,{targets:[{real_path:"/w/proj/other",rel_path:"other"}],lease_op:"acquire"});
  expect((await f.leases(a.run))[0].request_id).toBe("request");
  await f.apply(a.user,f.event(a,"question",{text:"Approval",question:{provider_request_id:"request",kind:"approval",structured:true,questions:[{id:"approval",header:"Approval",text:"Allow?",options:[{label:"Allow",description:"Allow"},{label:"Deny",description:"Deny"}],multi_select:false,allow_other:false,secret:false}]}}));
  expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"deny\"}') result",[a.user,a.task])).result).toMatchObject({status:"answered"});expect((await f.leases(a.run))[0].release_reason).toBe("request_denied");expect((await f.leases(b.run))[0].released_at).toBeNull();
 });
 it("R13 notice query has a matching partial index",async()=>{
  await f.q("begin");try{await f.q("set local enable_seqscan=off");const plan=await f.q("explain select l.id from public.agent_path_leases l where release_notified_at is null and (released_at is not null or conflict_stop_at is not null) and exists(select 1 from public.agent_tasks t where t.user_id=l.user_id and ((l.released_at is not null and t.run_id=any(l.waiter_run_ids)) or (l.release_reason='session_external' and t.run_id=l.run_id) or (l.conflict_stop_at is not null and t.run_id in(l.run_id,l.conflict_run_id)))) order by acquired_at,id limit 500");expect(JSON.stringify(plan)).toContain("agent_path_leases_notices");}finally{await f.q("rollback");}
 });


 it("R10 normalized workspace and artifact display path are persisted",async()=>{
  const w=await f.live(),workspace="/w/"+"é".repeat(260);await f.updateRow("agent_sessions",w.session,{workspace_ref:workspace.normalize("NFC")});
  expect(await f.decide(w,{workspace_real_path:workspace,targets:[{real_path:workspace+"/x",rel_path:"x"}]})).toMatchObject({decision:"defer"});expect((await f.leases(w.run))[0].workspace_ref).toBe(workspace.normalize("NFC"));
  await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'Café','hash','Changed')",[w.user,w.run,w.task,w.turn]);expect((await f.leases(w.run)).find(l=>l.source==="observed")?.rel_path).toBe("Café");
 });

 it.each(["approved", "observed"])("S1 probe E/E2 reserve and Deny preserve an existing %s lease", async source => {
  const w = await f.live();
  if (source === "approved") await f.decide(w, { request_id: "old", lease_op: "acquire" });
  else await f.apply(w.user, f.event(w, "artifact", { payload: { path: "pricing.mdx", hash: "abc", summary: "File" } }));
  const original = (await f.leases(w.run))[0];
  await f.q("update public.agent_path_leases set expires_at=public.db_now()+interval '10 minutes' where id=$1", [original.id]);
  expect(await f.decide(w)).toMatchObject({ decision: "defer", lease_ids: [original.id] });
  expect((await f.leases(w.run))[0]).toMatchObject({ source, request_id: original.request_id, expires_at: null, released_at: null });
  await f.apply(w.user, f.event(w, "question", { text: "Approval", question: answerQuestionFixture({ id: "approval" }, { provider_request_id: "request", kind: "approval" }) }));
  expect((await f.one("select public.answer_agent_approval($1,$2,'request','{\"approval\":\"deny\"}') result", [w.user, w.task])).result).toMatchObject({ status: "answered" });
  expect((await f.leases(w.run))[0]).toMatchObject({ source, request_id: original.request_id, released_at: null });
 });
 it.each(["reserve", "acquire"])("S1 only requested leases are rebound on %s", async lease_op => {
  const w = await f.live();
  await f.decide(w, { request_id: "old" });
  const original = (await f.leases(w.run))[0];
  expect(await f.decide(w, { lease_op })).toMatchObject({ lease_ids: [original.id] });
  expect((await f.leases(w.run))[0]).toMatchObject({ source: lease_op === "acquire" ? "approved" : "requested", request_id: "request" });
 });
 it.each(["approved", "observed"])("S1 acquire also preserves an existing %s lease binding", async source => {
  const w = await f.live();
  if (source === "approved") await f.decide(w, { request_id: "old", lease_op: "acquire" });
  else await f.apply(w.user, f.event(w, "artifact", { payload: { path: "pricing.mdx", hash: "abc", summary: "File" } }));
  const original = (await f.leases(w.run))[0];
  expect(await f.decide(w, { request_id: "new", lease_op: "acquire" })).toMatchObject({ lease_ids: [original.id] });
  expect((await f.leases(w.run))[0]).toMatchObject({ source, request_id: original.request_id, released_at: null });
 });
 it("S2 probe F terminal conflicts cannot fill the stop candidate limit", async () => {
  const w = await f.live(), ended = await f.competitor(w), live = await f.competitor(w), other = await f.live();
  await f.decide(w, { targets: ["a", "b"].map(path => ({ real_path: `/w/proj/${path}`, rel_path: path })), lease_op: "acquire" });
  const [old, current] = await f.leases(w.run);
  await f.q("update public.agent_path_leases set conflict_run_id=$2,conflict_at=now()-interval '1 day',conflict_version=1 where id=$1", [old.id, ended.run]);
  await f.q("update public.agent_path_leases set conflict_run_id=$2,conflict_at=now(),conflict_version=1 where id=$1", [current.id, live.run]);
  const list = async (user: string | null, bridge: string | null, limit = 1) => (await f.one("select public.list_pending_path_conflict_stops($1,$2,$3) result", [user, bridge, limit])).result;
  for (const state of ["done", "failed", "stopped"]) {
    await f.updateRow("execution_runs", ended.run, { state });
    expect(await list(w.user, w.bridge)).toEqual([{ id: current.id, user_id: w.user }]);
  }
  for (const state of ["queued", "running", "waiting_approval"]) {
    await f.updateRow("execution_runs", live.run, { state });
    expect(await list(w.user, null)).toEqual([{ id: current.id, user_id: w.user }]);
    expect(await list(null, w.bridge)).toEqual([{ id: current.id, user_id: w.user }]);
  }
  expect(await list(other.user, w.bridge)).toEqual([]);
  expect(await list(w.user, other.bridge)).toEqual([]);
  expect(await list(w.user, w.bridge, 0)).toEqual([]);
  await f.q("update public.agent_path_leases set conflict_stop_at=now() where id=$1", [current.id]);
  expect(await list(w.user, w.bridge)).toEqual([]);
  expect((await f.leases(w.run))[0].conflict_stop_at).toBeNull();
 });
 it("S4 NFC-expanded workspace skips the lease but applies the artifact event", async () => {
  const w = await f.live(), workspace = "/w/" + "क़".repeat(250);
  expect(workspace.length).toBeLessThanOrEqual(500);
  expect(workspace.normalize("NFC").length).toBeGreaterThan(500);
  await f.updateRow("agent_sessions", w.session, { workspace_ref: workspace });
  expect(await f.apply(w.user, f.event(w, "artifact", { payload: { path: "x", hash: "abc", summary: "File" } }))).toMatchObject({ status: "applied" });
  expect(await f.q("select path from public.agent_artifacts where run_id=$1", [w.run])).toEqual([{ path: "x" }]);
  expect(await f.leases(w.run)).toEqual([]);
 });
 it("S6 a bound root workspace is rejected independently of pending depth", async () => {
  const w = await f.live();
  await f.updateRow("agent_sessions", w.session, { workspace_ref: "/" });
  expect(await f.decide(w, { workspace_real_path: "/", targets: [{ real_path: "/x", rel_path: "x" }] })).toMatchObject({ decision: "deny", reason: "workspace_mismatch" });
  expect(await f.leases(w.run)).toEqual([]);
 });
 it("S6 stop does not mark a newer conflict version for the same run", async () => {
  const w = await f.live(), later = await f.competitor(w);
  await f.decide(w, { lease_op: "acquire" });
  const lease = (await f.leases(w.run))[0];
  await f.q("update public.agent_path_leases set conflict_run_id=$2,conflict_at=now(),conflict_version=1 where id=$1", [lease.id, later.run]);
  await f.q("create function public.path_test_new_conflict_version() returns trigger language plpgsql as $$ begin update public.agent_path_leases set conflict_version=conflict_version+1 where conflict_run_id=new.id; return null; end $$");
  await f.q("create trigger path_test_new_conflict_version after update of state on public.execution_runs for each row when (new.state='stopped') execute function public.path_test_new_conflict_version()");
  try {
    expect((await f.one("select public.stop_agent_run_for_path_conflict($1,$2) result", [w.user, lease.id])).result).toMatchObject({ status: "stopped" });
    expect((await f.leases(w.run))[0]).toMatchObject({ conflict_run_id: later.run, conflict_version: 2, conflict_stop_at: null, release_notified_at: null });
  } finally {
    await f.q("drop trigger path_test_new_conflict_version on public.execution_runs");
    await f.q("drop function public.path_test_new_conflict_version()");
  }
 });
 it("S7 long s folds to the same key as ASCII s", async () => {
  expect(await f.one("select public.agent_path_key('/W/PROJ/ſrc') key")).toEqual({ key: "/w/proj/src" });
 });
 it.each([".githooks/pre-commit", ".cargo/config.toml", ".yarnrc.yml", ".npmrc", ".pre-commit-config.yaml", "lefthook.yml", ".huſky/pre-commit"])("S7 protected path %s always reserves", async path => {
  const w = await f.live();
  expect(await f.decide(w, { decision: "allow", reason: "policy_auto", lease_op: "acquire", targets: [{ real_path: `/w/proj/${path}`, rel_path: path }] })).toMatchObject({ decision: "defer", reason: "tool_config_write" });
  expect((await f.leases(w.run))[0]).toMatchObject({ source: "requested" });
 });
 it("S7 pending workspace rejects the home itself and accepts its subdirectory", async () => {
  const w = await f.live();
  await f.updateRow("agent_sessions", w.session, { workspace_ref: "pending:fixture" });
  for (const workspace_real_path of ["/Users/fixture-user", "/Users/क़"]) {
    expect(await f.decide(w, { workspace_real_path, targets: [{ real_path: `${workspace_real_path}/x`, rel_path: "x" }] })).toMatchObject({ decision: "deny", reason: "workspace_mismatch" });
  }
  expect(await f.leases(w.run)).toEqual([]);
  expect(await f.decide(w, { workspace_real_path: "/Users/fixture-user/project", targets: [{ real_path: "/Users/fixture-user/project/x", rel_path: "x" }] })).toMatchObject({ decision: "defer", reason: "manual_write" });
 });

}
