import { expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";
export function bridgeReviewTests(db: () => ConversationAgentDb) {
 const f=bridgeCommandFixtures(db);
 const answerWorld=async()=>{const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Choose",question:answerQuestionFixture()}));const a=await f.answer(w.user,w.task);const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[a.step_id])).id);return {...w,command,answerStep:a.step_id!};};
 it.each(["write_gate_closed","not_connected","adapter_disabled","unsupported","sign_in_needed","usage_limited","spawn_failed","not_received"])("review FIFO refuses automatic retry of %s",async reason=>{
  const w=await f.world();await f.lease(w,null);await f.updateRow("conversation_messages",w.message,{delivery_reason:reason});
  await f.post(w.user,w.conversation,randomUUID(),"Wait behind head");
  expect(await f.one("select public.next_bridge_agent_message($1,$2,false) as id",[w.user,w.session])).toEqual({id:null});
  expect(await f.one("select public.next_bridge_agent_message($1,$2,true) as id",[w.user,w.session])).toEqual({id:["write_gate_closed","not_connected","adapter_disabled"].includes(reason)?w.message:null});
 });
 it("review revoked live task is terminal and preserves uncertainty",async()=>{
  const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"accepted"));
  const result=(await f.one("select public.revoke_bridge($1,$2) as result",[w.user,w.bridge])).result;
  expect(result).toMatchObject({tasks:[{cancel:"requested_only"}]});
  expect(await f.one("select state,last_live_state,cancel_requested_at is not null as requested from public.agent_tasks where id=$1",[w.task])).toEqual({state:"cancelled",last_live_state:"accepted",requested:true});
  expect(await f.one("select status from public.agent_connections where id=$1",[w.connection])).toEqual({status:"revoked"});
 });
 it("review second heartbeat returns cached result without writes",async()=>{
  const w=await f.world();const first=await f.heartbeat(w);const before=await f.q("select xmin::text,* from public.bridges where id=$1",[w.bridge]);
  expect(await f.heartbeat(w,[{task_id:randomUUID(),process_alive:true,last_seq:0}])).toEqual({...first,throttled:true});
  expect(await f.q("select xmin::text,* from public.bridges where id=$1",[w.bridge])).toEqual(before);
 });
 it("review reported unknown readbacks do not remain immediately available",async()=>{
  const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01"});await f.q("select public.sweep_agent_step_leases(now())");await f.settle(w,"readback","unknown");expect((await f.list(w)).readbacks).toEqual([]);
 });
 it("review fanout has matching partial index",async()=>{
  expect(await f.q("select indexdef from pg_indexes where tablename='execution_events' and indexdef like '%fanout_pending%'" )).toEqual([expect.objectContaining({indexdef:expect.stringContaining("WHERE ((type = 'agent'::text)")})]);
 });
 it("review late answer progress preserves settlement",async()=>{const w=await answerWorld();await f.lease(w);await f.updateRow("execution_steps",w.answerStep,{lease_expires_at:"2000-01-01"});await f.q("select public.sweep_agent_step_leases(now())");await f.bridgeEvent(w,f.event(w,"progress"));expect(await f.one("select state from public.execution_steps where id=$1",[w.answerStep])).toEqual({state:"called"});});
 it("review not_received settles step without rewriting already running task",async()=>{
  const w=await f.world();await f.lease(w);await f.updateRow("agent_tasks",w.task,{state:"running"});
  const task=await f.one("select * from public.agent_tasks where id=$1",[w.task]),message=await f.msg(w.message);
  expect(await f.settle(w,"readback","not_received",true)).toEqual({status:"settled",task_state:"running"});
  expect(await f.one("select * from public.agent_tasks where id=$1",[w.task])).toEqual(task);expect(await f.msg(w.message)).toEqual(message);
  expect(await f.one("select state,receipt from public.execution_steps where id=$1",[w.step])).toEqual({state:"failed",receipt:{reason:"not_received"}});
  expect(await f.one("select outcome,outcome_at is not null as reported from public.bridge_commands where id=$1",[w.command])).toEqual({outcome:"not_received",reported:true});
 });
 it.each(["absent","expired","empty"])("review %s answer body expires and restores card",async reason=>{
  const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Choose",question:answerQuestionFixture({allow_other:true})}));
  const message=String((await f.post(w.user,w.conversation,randomUUID(),"Custom answer")).message_id);
  const answered=(await f.one("select public.answer_agent_question($1,$2,'request',$3::jsonb,false,$4) as result",[w.user,w.task,JSON.stringify({choice:"Custom answer"}),message])).result as {step_id:string};
  const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[answered.step_id])).id);
  if(reason==="absent")await f.q("delete from public.conversation_messages where id=$1",[message]);
  if(reason==="expired")await f.updateRow("conversation_messages",message,{delivery_expires_at:"2000-01-01"});
  if(reason==="empty")await f.updateRow("conversation_messages",message,{text:""});
  expect(await f.lease({...w,command})).toEqual({status:"withdrawn",reason:"expired"});
  expect(await f.one("select state,pending_question,answered_question from public.agent_tasks where id=$1",[w.task])).toMatchObject({state:"awaiting_answer",pending_question:expect.any(Object),answered_question:null});
 });
 it("review action closed records withdrawn outcome",async()=>{const w=await f.world();await f.q("update public.actions set status='done' where id=$1",[w.action]);expect(await f.lease(w)).toEqual({status:"withdrawn",reason:"action_closed"});expect(await f.one("select outcome from public.bridge_commands where id=$1",[w.command])).toEqual({outcome:"withdrawn"});});
 it("review replay rechecks current gate",async()=>{const w=await f.world();await f.lease(w);const before=await f.snapshot(w);expect(await f.lease(w,null)).toEqual({status:"stale",reason:"write_gate_closed"});expect(await f.snapshot(w)).toEqual(before);});
 it.each(["bridge_events","bridge_ack","bridge_poll"])("review device rate kind %s has independent bridge buckets",async kind=>{const w=await f.world(),other=await f.bridge(w.user);expect(await f.one("select public.take_rate_limit($1,$2,1,60,$3) as until",[w.user,kind,w.bridge])).toEqual({until:null});expect((await f.one("select public.take_rate_limit($1,$2,1,60,$3) as until",[w.user,kind,w.bridge])).until).not.toBeNull();expect(await f.one("select public.take_rate_limit($1,$2,1,60,$3) as until",[w.user,kind,other])).toEqual({until:null});});
 it("review exact readback received and not_received lifecycle M4 M5",async()=>{for(const result of ["received","not_received"]){const w=await f.world();await f.lease(w);expect(await f.settle(w,"readback",result,true)).toEqual({status:"settled",task_state:result==="received"?"accepted":"failed"});expect(await f.msg(w.message)).toMatchObject({delivery_state:result==="received"?"dispatched":"not_sent",delivery_reason:result==="received"?null:"not_received"});}});
 it("review exact answer not_received restoration M12",async()=>{const w=await answerWorld();const previous=(await f.one("select answered_question from public.agent_tasks where id=$1",[w.task])).answered_question;await f.lease(w);expect(await f.settle(w,"readback","not_received",true)).toEqual({status:"settled",task_state:"awaiting_answer"});expect(await f.one("select pending_question,answered_question from public.agent_tasks where id=$1",[w.task])).toEqual({pending_question:previous,answered_question:null});});
 it("review wrong task state does not lease M10",async()=>{const w=await f.world();await f.updateRow("agent_tasks",w.task,{state:"accepted"});const before=await f.snapshot(w);expect(await f.lease(w)).toEqual({status:"stale",reason:"wrong_state"});expect(await f.snapshot(w)).toEqual(before);});
 it("review sweep preserves non-conversation calling steps M8",async()=>{const w=await f.world();await f.lease(w);await f.updateRow("execution_runs",w.run,{kind:"task"});await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01"});const before=await f.snapshot(w);await f.q("select public.sweep_agent_step_leases(now())");expect(await f.snapshot(w)).toEqual(before);});
 it("review heartbeat kick bound is exactly five M15",async()=>{const w=await f.turnWorld(true);const sessions=[w.session!];for(let n=0;n<6;n++){const session=await f.session(w.user,w.connection);sessions.push(session);const conversation=await f.agentConversation(w.user,w.connection,session);await f.post(w.user,conversation,randomUUID(),"Queued");}const result=await f.heartbeat(w);expect(result.kick_session_ids).toEqual(sessions.sort().slice(0,5));});

 it("review five revoked live tasks do not consume future live slots",async()=>{
  const base=await f.world();await f.lease(base);await f.bridgeEvent(base,f.event(base,"accepted"));await f.q("select public.revoke_bridge($1,$2)",[base.user,base.bridge]);
  for(let n=0;n<5;n++){
   const bridge=await f.bridge(base.user),connection=await f.agentConnection(base.user,bridge,{adapter:"agent:codex"}),conversation=await f.agentConversation(base.user,connection,null);
   const message=String((await f.post(base.user,conversation,randomUUID(),"Next task")).message_id),turn=await f.start(base.user,message);
   expect(turn.status).toBe("started");
   if(n===4)break;
   const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[turn.step_id])).id);
   await f.lease({...base,bridge,command});await f.q("select public.revoke_bridge($1,$2)",[base.user,bridge]);
  }
 });
 it("review queued helper uses exact cross-conversation FIFO head",async()=>{
  const w=await f.world();await f.lease(w,null);await f.updateRow("conversation_messages",w.message,{seq:20});
  const conversation=await f.agentConversation(w.user,w.connection,w.session);await f.post(w.user,conversation,randomUUID(),"Later conversation");
  expect(await f.one("select public.next_queued_agent_message($1,$2) as id",[w.user,w.session])).toEqual({id:w.message});
  expect(await f.one("select public.next_bridge_agent_message($1,$2) as id",[w.user,w.session])).toEqual({id:null});
 });
 it("review heartbeat sweep ignores caller future clock",async()=>{
  const w=await f.world();await f.lease(w);await f.updateRow("bridges",w.bridge,{last_heartbeat_at:new Date().toISOString()});
  await f.q("select * from public.sweep_bridge_heartbeats(now()+interval '1 day',1000)");
  expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"bound"});
 });
 it("review heartbeat sweep isolates a failing bridge",async()=>{
  const bad=await f.world(),good=await f.world();await f.lease(bad);await f.lease(good);
  await f.q("update public.bridges set last_heartbeat_at='2000-01-01' where id=any($1)",[[bad.bridge,good.bridge]]);
  await f.q(`create function public.review_fail_bridge() returns trigger language plpgsql as $$ begin if new.id='${bad.session}'::uuid then raise exception 'review failure'; end if; return new; end $$`);
  await f.q("create trigger review_fail_bridge before update on public.agent_sessions for each row execute function public.review_fail_bridge()");
  try {await f.q("select * from public.sweep_bridge_heartbeats(now(),1000)");expect(await f.one("select status from public.agent_sessions where id=$1",[bad.session])).toEqual({status:"bound"});expect(await f.one("select status from public.agent_sessions where id=$1",[good.session])).toEqual({status:"unreachable"});}
  finally {await f.q("drop trigger review_fail_bridge on public.agent_sessions");await f.q("drop function public.review_fail_bridge()");}
 });

 it("review scoped fanout EXPLAIN uses partial index",async()=>{
  const w=await f.world();
  await f.q("insert into public.execution_events(user_id,run_id,type,bridge_id,external_event_id,payload) select $1,$2,'agent',$3,'explain:'||n,jsonb_build_object('fanout_pending',n=3000,'event_type','bridge_unreachable') from generate_series(1,3000) n",[w.user,w.run,w.bridge]);
  await f.q("analyze public.execution_events");
  const plan=await f.q("explain select id from public.execution_events where user_id=$1 and bridge_id=$2 and type='agent' and (payload->>'fanout_pending')='true' and payload->>'event_type' in ('bridge_unreachable','bridge_restored') order by at,id limit 50",[w.user,w.bridge]);
  expect(JSON.stringify(plan)).toContain("execution_events_bridge_fanout_pending_idx");
  console.info("FANOUT_EXPLAIN",JSON.stringify(plan));
 });

 it("review removed structured answers expire and restore card",async()=>{
  const w=await answerWorld();await f.q("update public.execution_steps set args=args-'answers' where id=$1",[w.answerStep]);
  await f.q("select public.prepare_step(id,version) from public.execution_steps where id=$1",[w.answerStep]);
  expect(await f.lease(w)).toEqual({status:"withdrawn",reason:"expired"});
  expect(await f.one("select state,pending_question,answered_question from public.agent_tasks where id=$1",[w.task])).toMatchObject({state:"awaiting_answer",pending_question:expect.any(Object),answered_question:null});
 });

 it("review failed bridge sweep returns no rolled-back earlier session rows",async()=>{
  const w=await f.world();await f.lease(w);const conversation=await f.agentConversation(w.user,w.connection,null);
  const message=String((await f.post(w.user,conversation,randomUUID(),"Second session")).message_id),turn=await f.start(w.user,message);
  const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[turn.step_id])).id);await f.lease({...w,command});
  const sessions=await f.q("select id from public.agent_sessions where connection_id=$1 order by id",[w.connection]);
  await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01"});
  await f.q(`create function public.review_fail_later_session() returns trigger language plpgsql as $$ begin if new.id='${sessions[1].id}'::uuid then raise exception 'review failure'; end if; return new; end $$`);
  await f.q("create trigger review_fail_later_session before update on public.agent_sessions for each row execute function public.review_fail_later_session()");
  try {const result=await f.q("select * from public.sweep_bridge_heartbeats(now(),1000)");expect(result.filter(row=>row.bridge_id===w.bridge)).toEqual([]);expect(await f.q("select status from public.agent_sessions where connection_id=$1",[w.connection])).toEqual([{status:"bound"},{status:"bound"}]);}
  finally {await f.q("drop trigger review_fail_later_session on public.agent_sessions");await f.q("drop function public.review_fail_later_session()");}
 });

 it.each(["done","stop","unreachable"])("review revoke cleans live tasks of already stopped %s run",async phase=>{
  const w=await f.world();await f.lease(w);
  if(phase==="unreachable")await f.updateRow("agent_tasks",w.task,{state:"unreachable",last_live_state:"accepted"});
  if(phase==="done")await f.done(w.user,w.action);else await f.stop(w.user,w.session);
  const runBefore=await f.one("select state,stopped_at from public.execution_runs where id=$1",[w.run]);
  const result=(await f.one("select public.revoke_bridge($1,$2) as result",[w.user,w.bridge])).result;
  expect(result).toMatchObject({tasks:[{cancel:"requested_only"}]});
  expect(await f.one("select state,last_live_state,cancel_requested_at is not null as requested from public.agent_tasks where id=$1",[w.task])).toEqual({state:"cancelled",last_live_state:phase==="unreachable"?"accepted":"dispatched",requested:true});
  expect(await f.one("select state,stopped_at from public.execution_runs where id=$1",[w.run])).toEqual(runBefore);
  expect(await f.count("select 1 from public.agent_tasks where user_id=$1 and state in ('dispatched','accepted','running','awaiting_answer','unreachable')",[w.user])).toBe(0);
 });

}
