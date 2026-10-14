import { createHash, randomUUID } from "node:crypto";
import { expect, it } from "vitest";
import { bridgeV1AckResponseSchema, bridgeV1CommandsResponseSchema } from "../../src/lib/api/contract";
import { agentQuestionsStopFixtures, answerQuestionFixture } from "./agent-questions-stop.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

type Result = { status: string; reason?: string; command?: Record<string, unknown>; lease_expires_at?: string; task_state?: string };
export function bridgeCommandFixtures(db: () => ConversationAgentDb) {
  const f = agentQuestionsStopFixtures(db);
  return {
    ...f,
    async world() {
      const w = await f.eventWorld(false);
      await f.q("insert into public.execution_actors(user_id) values($1) on conflict do nothing", [w.user]);
      await f.q("update public.execution_controls set blocked=false");
      const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [w.step])).id);
      const mode = String((await f.one("select mode from public.execution_policies where user_id=$1", [w.user])).mode);
      return { ...w, command, mode };
    },
    async lease(w: {user:string;bridge:string;command:string;mode:string}, access: string | null = "read_only"): Promise<Result> {
      return (await f.one("select public.lease_bridge_command($1,$2,$3,$4,$5) as result", [w.user,w.bridge,w.command,access,w.mode])).result as Result;
    },
    async settle(w: {user:string;bridge:string;command:string}, op: string, result: string | null = null, ended = false): Promise<Result> {
      return (await f.one("select public.settle_bridge_command($1,$2,$3,$4,$5,$6) as result", [w.user,w.bridge,w.command,op,result,ended])).result as Result;
    },
    async bridgeEvent(w: {user:string;bridge:string}, event: Record<string, unknown>): Promise<Result> {
      return (await f.one("select public.apply_bridge_event($1,$2,$3::jsonb) as result", [w.user,w.bridge,JSON.stringify(event)])).result as Result;
    },
    async list(w: {user:string;bridge:string}, after = 0) {
      return (await f.one("select public.list_bridge_commands($1,$2,$3,50) as result", [w.user,w.bridge,after])).result as {commands: Record<string,unknown>[];readbacks: Record<string,unknown>[];next_cursor:number};
    },
    async heartbeat(w: {user:string;bridge:string}, tasks: Record<string,unknown>[] = []) {
      return (await f.one("select public.bridge_heartbeat($1,$2,$3::jsonb) as result", [w.user,w.bridge,JSON.stringify(tasks)])).result as {revived_session_ids:string[];kick_session_ids:string[];unknown_task_ids:string[];missing_task_ids:string[];pending_commands:number};
    },
    async snapshot(w: {user:string}) {
      return Promise.all(["bridge_commands","execution_steps","agent_tasks","conversation_messages","execution_intents"].map(table => f.q(`select * from public.${table} where user_id=$1 order by 1`,[w.user])));
    },
  };
}
export function bridgeCommandTests(db: () => ConversationAgentDb) {
  const f = bridgeCommandFixtures(db);
  it("B1 columns, parent FKs and service-only RPC privileges", async () => {
    expect(await f.one("select to_regclass('public.bridge_commands')::text as name")).toEqual({name:"bridge_commands"});
    expect(await f.q("select confrelid::regclass::text as parent from pg_constraint where conrelid='public.bridge_commands'::regclass and contype='f' order by parent")).toEqual([{parent:"auth.users"},{parent:"bridges"},{parent:"execution_steps"}]);
    expect((await f.q("select column_name from information_schema.columns where table_schema='public' and table_name='bridge_commands' order by ordinal_position")).map(r=>r.column_name)).toEqual(["id","user_id","bridge_id","step_id","agent_task_id","cursor","kind","lease_owner","leased_at","outcome","outcome_at","created_at"]);
    const names = ["register_bridge","revoke_bridge","bridge_heartbeat","sweep_bridge_heartbeats","sweep_agent_step_leases","list_bridge_commands","lease_bridge_command","settle_bridge_command","apply_bridge_event","next_unbound_agent_messages","bridge_redelivery_candidates","purge_bridge_commands"];
    const rows = await f.q("select proname,prosecdef,proconfig,has_function_privilege('anon',p.oid,'execute') as anon,has_function_privilege('authenticated',p.oid,'execute') as app,has_function_privilege('service_role',p.oid,'execute') as server from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname=any($1) order by proname",[names]);
    expect(rows).toHaveLength(names.length);
    for(const row of rows) expect(row).toMatchObject({prosecdef:false,proconfig:['search_path=""'],anon:false,app:false,server:true});
  });
  it("R-L5 lease Action lookup has no row lock (static only)",async()=>{
    const row=await f.one("select pg_get_functiondef('public.lease_bridge_command(uuid,uuid,uuid,text,text)'::regprocedure) as definition");
    const actionLookup=String(row.definition).match(/select 1 from public\.actions[^;]+/i)?.[0];
    expect(actionLookup).toBeDefined();expect(actionLookup).not.toMatch(/for\s+(share|update|no key update|key share)/i);
  });
  it("B1 RLS exposes own metadata only; application writes and secret hash reads are denied", async () => {
    const a = await f.world(), b = await f.world();
    await db().asUser(a.user, async () => {
      expect(await f.q("select id from public.bridge_commands where id=any($1)",[[a.command,b.command]])).toEqual([{id:a.command}]);
      for(const sql of ["update public.bridge_commands set outcome=null where id=$1","delete from public.bridge_commands where id=$1","insert into public.bridge_commands(id) values($1)"]) await expect(f.q(sql,[a.command])).rejects.toMatchObject({code:"42501"});
      await expect(f.q("select secret_hash from public.bridges where id=$1",[a.bridge])).rejects.toMatchObject({code:"42501"});
    });
  });
  it("B1/B2 start creates one metadata command and preparing again does not duplicate it", async () => {
    const w=await f.world();
    expect(await f.one("select kind,lease_owner,leased_at,outcome,outcome_at from public.bridge_commands where id=$1",[w.command])).toEqual({kind:"message",lease_owner:null,leased_at:null,outcome:null,outcome_at:null});
    await f.updateRow("execution_steps",w.step,{state:"failed"});
    await f.updateRow("execution_steps",w.step,{state:"prepared"});
    expect(await f.count("select 1 from public.bridge_commands where step_id=$1",[w.step])).toBe(1);
    const list=await f.list(w);
    expect(list.commands).toHaveLength(1);
    expect(JSON.stringify(list)).not.toContain("Full original body");
    await expect(f.updateRow("bridge_commands",w.command,{kind:"dispatch"})).rejects.toMatchObject({code:"23514"});
    await expect(f.updateRow("bridge_commands",w.command,{lease_owner:"orphan"})).rejects.toMatchObject({code:"23514"});
    await expect(f.updateRow("bridge_commands",w.command,{outcome:"sent"})).rejects.toMatchObject({code:"23514"});
  });
  it("B3 lease is atomic, replay preserves marker and deadline, and Stop prepares cancel", async () => {
    const w=await f.world(), run=await f.one("select state from public.execution_runs where id=$1",[w.run]);
    const leased=await f.lease(w);expect(leased.status).toBe("leased");
    expect(bridgeV1AckResponseSchema.parse(leased)).toEqual(leased);
    expect(leased.command).toMatchObject({id:w.command,kind:"message",step_id:w.step,message:{id:w.message,text:"  First   line  \nFull original body"}});
    const command=await f.one("select lease_owner,leased_at,created_at from public.bridge_commands where id=$1",[w.command]);
    expect(command.lease_owner).toBe(`bridge:${w.bridge}:${w.command}`);expect(command.leased_at).not.toBeNull();
    expect(await f.one("select state,lease_owner from public.execution_steps where id=$1",[w.step])).toEqual({state:"calling",lease_owner:command.lease_owner});
    expect(await f.count("select 1 from public.execution_intents where step_id=$1",[w.step])).toBe(1);
    expect(await f.one("select state from public.execution_runs where id=$1",[w.run])).toEqual(run);
    const before=await f.snapshot(w), replay=await f.lease(w);expect(replay).toEqual({...leased,status:"replay"});expect(await f.snapshot(w)).toEqual(before);
    expect(await f.lease({...w,mode:w.mode==="manual"?"auto":"manual"},null)).toEqual({status:"stale",reason:"write_gate_closed"});expect(await f.snapshot(w)).toEqual(before);
    expect((await f.list(w)).commands[0]).toMatchObject({id:w.command,leased_by_me:true});
    expect(await f.stop(w.user,w.session)).toMatchObject({tasks:[{agent_task_id:w.task,cancel:"requested_only"}]});
    const cancel=await f.one("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task]);
    await f.q("update public.execution_controls set blocked=true");
    expect(await f.lease({...w,command:String(cancel.id)},null)).toMatchObject({status:"leased",command:{kind:"cancel"}});
    expect(await f.q("select 1 from public.bridge_commands c join public.execution_steps s on s.id=c.step_id where s.state='prepared' and c.lease_owner is not null")).toEqual([]);
  });
  it("B3 old calling commands cannot starve a newer cancel past the cursor",async()=>{
    const w=await f.world();await f.lease(w);
    const conversation=await f.agentConversation(w.user,w.connection,null);
    const message=String((await f.post(w.user,conversation,randomUUID(),"Second task")).message_id);
    const started=await f.start(w.user,message);
    const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[started.step_id])).id);
    await f.lease({...w,command});await f.stop(w.user,w.session);
    const cancel=String((await f.one("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).id);
    const first=(await f.one("select public.list_bridge_commands($1,$2,0,2) as result",[w.user,w.bridge])).result as {next_cursor:number};
    const next=(await f.one("select public.list_bridge_commands($1,$2,$3,2) as result",[w.user,w.bridge,first.next_cursor])).result as {commands:{id:string}[]};
    expect(next.commands[0].id).toBe(cancel);expect(next.commands).toHaveLength(2);
  });
  it("B9 unknown readback acknowledgement rotates the bounded recovery list",async()=>{
    const w=await f.world(),commands=[w.command];await f.lease(w);
    for(let n=0;n<2;n++){
      const conversation=await f.agentConversation(w.user,w.connection,null);
      const message=String((await f.post(w.user,conversation,randomUUID(),"Another task")).message_id);
      const started=await f.start(w.user,message);
      const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[started.step_id])).id);
      await f.lease({...w,command});commands.push(command);
    }
    await f.q("update public.execution_steps set lease_expires_at='2000-01-01' where user_id=$1 and state='calling'",[w.user]);
    await f.q("select public.sweep_agent_step_leases(now())");
    const list=async()=>(await f.one("select public.list_bridge_commands($1,$2,0,2) as result",[w.user,w.bridge])).result as {readbacks:{command_id:string}[]};
    const first=await list();expect(first.readbacks).toHaveLength(2);
    for(const item of first.readbacks)await f.settle({...w,command:item.command_id},"readback","unknown");
    expect((await list()).readbacks[0].command_id).toBe(commands[2]);
  });
  it.each(["stop","done"])("B2 %s before lease confirms cancellation without a cancel command",async finish=>{
    const w=await f.world();
    if(finish==="stop") expect(await f.stop(w.user,w.session)).toMatchObject({tasks:[{cancel:"confirmed"}]});else await f.done(w.user,w.action);
    expect(await f.q("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).toEqual([]);
    expect(await f.state(w)).toMatchObject({state:"cancelled"});
  });
  it.each(["bridge","user"])("B4 foreign %s lease/settle cannot mutate command or related state", async kind=>{
    const w=await f.world();await f.lease(w);const before=await f.snapshot(w);
    const foreign=kind==="bridge"?{...w,bridge:await f.bridge(w.user)}:{...w,user:await f.user()};
    expect(await f.lease(foreign)).toMatchObject({status:"not_found"});
    expect(["stale","not_found"]).toContain((await f.settle(foreign,"readback","received")).status);
    expect(await f.snapshot(w)).toEqual(before);
  });
  it("B5 foreign bridge settlement is write-free independently of lease",async()=>{
    const w=await f.world();await f.lease(w);const before=await f.snapshot(w);
    expect(await f.settle({...w,bridge:await f.bridge(w.user)},"readback","received")).toEqual({status:"not_found"});
    expect(await f.snapshot(w)).toEqual(before);
  });
  it.each(["access","actor","global","provider","mode","tool"])("B4 closed %s gate withdraws before delivery with no intent",async gate=>{
    const w=await f.world();
    if(gate==="actor")await f.q("delete from public.execution_actors where user_id=$1",[w.user]);
    if(["global","provider","mode"].includes(gate))await f.q("update public.execution_controls set blocked=true where scope=$1",[gate]);
    if(gate==="tool")await f.q("delete from public.execution_tools where provider='agent:codex' and tool='message'");
    expect(await f.lease(w,gate==="access"?null:"read_only")).toMatchObject({status:"withdrawn",reason:"write_gate_closed"});
    expect(await f.one("select state,receipt from public.execution_steps where id=$1",[w.step])).toMatchObject({state:"failed",receipt:{never_sent:true,reason:"write_gate_closed"}});
    expect(await f.state(w)).toMatchObject({state:"failed"});expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:"write_gate_closed"});
    expect(await f.count("select 1 from public.execution_intents where step_id=$1",[w.step])).toBe(0);
    if(gate==="tool")await f.q("insert into public.execution_tools(provider,tool,effect_class) values('agent:codex','message','external') on conflict do nothing");
  });
  it.each(["unreachable","policy"])("B4 %s stale rejection is write-free",async reason=>{
    const w=await f.world();if(reason==="unreachable")await f.updateRow("agent_sessions",w.session,{status:"unreachable"});
    const before=await f.snapshot(w);
    expect(await f.lease({...w,mode:reason==="policy"?(w.mode==="manual"?"auto":"manual"):w.mode})).toMatchObject({status:"stale",reason:reason==="policy"?"policy_changed":"heartbeat_first"});
    expect(await f.snapshot(w)).toEqual(before);
  });
  it.each(["expired","not_connected","session_closed","session_external"])("B4 %s withdraws with exact delivery reason",async reason=>{
    const w=await f.world();
    if(reason==="expired")await f.updateRow("conversation_messages",w.message,{delivery_expires_at:"2000-01-01T00:00:00Z"});
    if(reason==="not_connected")await f.updateRow("agent_connections",w.connection,{status:"error"});
    if(reason.startsWith("session_"))await f.updateRow("agent_sessions",w.session,{status:reason.slice(8)});
    expect(await f.lease(w)).toMatchObject({status:"withdrawn",reason});
    expect(await f.msg(w.message)).toMatchObject({delivery_state:reason==="expired"?"expired":"not_sent",delivery_reason:reason});
  });
  it("B5 decline before lease has no external effect",async()=>{
    const w=await f.world();expect(await f.settle(w,"decline","unsupported_kind")).toMatchObject({status:"withdrawn",reason:"unsupported"});
    expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:"unsupported"});
    expect(await f.count("select 1 from public.execution_intents where step_id=$1",[w.step])).toBe(0);
  });
  it.each(["received","not_received","unknown"])("B5/B9 readback %s never dispatches another step",async result=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});
    await f.q("select public.sweep_agent_step_leases(now())");
    expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"unknown_outcome"});
    const listing=await f.list(w);
    expect(bridgeV1CommandsResponseSchema.parse({...listing,server_time:new Date().toISOString()})).toMatchObject(listing);
    expect(listing.readbacks).toEqual([expect.objectContaining({command_id:w.command,kind:"message"})]);
    if(result==="not_received")await expect(f.settle(w,"readback",result,false)).rejects.toMatchObject({code:"22023"});
    expect(await f.settle(w,"readback",result,true)).toMatchObject({status:"settled"});
    expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:result==="received"?"called":result==="not_received"?"failed":"unknown_outcome"});
    expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind='agent_message'",[w.run])).toBe(1);
    expect(await f.count("select 1 from public.execution_intents where user_id=$1",[w.user])).toBe(1);
    expect(await f.count("select 1 from public.bridge_commands where user_id=$1",[w.user])).toBe(1);
  });
  it("B6 only the owning bridge reattaches expired lease and records duplicate-safe event",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    const event=f.event(w,"accepted"),before=await f.snapshot(w);
    expect(await f.bridgeEvent({...w,bridge:await f.bridge(w.user)},event)).toMatchObject({status:"wrong_bridge"});expect(await f.snapshot(w)).toEqual(before);
    expect(await f.bridgeEvent(w,event)).toMatchObject({status:"applied",task_state:"accepted"});
    expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"called"});
    expect(await f.q("select bridge_id from public.execution_events where run_id=$1 and external_event_id=$2",[w.run,event.event_id])).toEqual([{bridge_id:w.bridge}]);
    const after=await f.snapshot(w);expect(await f.bridgeEvent(w,event)).toMatchObject({status:"duplicate"});expect(await f.snapshot(w)).toEqual(after);
  });
  it("B6 rejected invalid event leaves expired lease and ledger unchanged",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    const before=await f.snapshot(w),events=await f.events(w);
    await expect(f.bridgeEvent(w,f.event(w,"accepted",{payload:{text:"not permitted"}}))).rejects.toMatchObject({code:"22023"});
    expect(await f.snapshot(w)).toEqual(before);expect(await f.events(w)).toEqual(events);
  });
  it("B6 rejected adapter attribution cannot leave reattachment audit events",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    const before=await f.snapshot(w),events=await f.q("select * from public.execution_events where run_id=$1 order by id",[w.run]);
    expect(await f.bridgeEvent(w,f.event(w,"accepted",{adapter:"agent:claude-code"}))).toMatchObject({status:"not_found"});
    expect(await f.snapshot(w)).toEqual(before);expect(await f.q("select * from public.execution_events where run_id=$1 order by id",[w.run])).toEqual(events);
  });
  it("B6 task identity permits optional turn_seq during expired lease reattachment",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    expect(await f.bridgeEvent(w,f.event(w,"accepted",{turn_seq:undefined}))).toMatchObject({status:"applied",task_state:"accepted"});
    expect(await f.one("select state from public.execution_steps where id=$1",[w.step])).toEqual({state:"called"});
  });
  it("B7 heartbeat affects own sessions and leases only and leaves task reconciliation to events",async()=>{
    const w=await f.world(),other=await f.world();await f.lease(w);await f.lease(other);
    await f.updateRow("agent_sessions",w.session,{status:"unreachable"});await f.updateRow("agent_tasks",w.task,{state:"unreachable",last_live_state:"dispatched"});await f.updateRow("agent_sessions",other.session,{status:"unreachable"});
    const otherBefore=await f.snapshot(other);
    const beat=await f.heartbeat(w,[{task_id:w.task,process_alive:true,last_seq:0},{task_id:other.task,process_alive:true,last_seq:0}]);
    expect(beat.revived_session_ids).toContain(w.session);expect(beat.unknown_task_ids).toEqual([other.task]);
    expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"bound"});expect(await f.state(w)).toMatchObject({state:"unreachable"});
    expect(await f.snapshot(other)).toEqual(otherBefore);expect(await f.one("select status from public.agent_sessions where id=$1",[other.session])).toEqual({status:"unreachable"});
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01"});
    expect((await f.heartbeat(w)).missing_task_ids).toContain(w.task);
  });
  it("B7 heartbeat cannot revive or extend another bridge of the same user",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("agent_sessions",w.session,{status:"unreachable"});
    const before=await f.snapshot(w),bridge=await f.bridge(w.user);
    const result=await f.heartbeat({...w,bridge},[{task_id:w.task,process_alive:true,last_seq:0}]);
    expect(result.revived_session_ids).toEqual([]);expect(result.unknown_task_ids).toEqual([w.task]);
    expect(await f.snapshot(w)).toEqual(before);expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"unreachable"});
  });
  it("B6 reattachment requires the retained command lease owner",async()=>{
    const w=await f.world();await f.lease(w);await f.updateRow("execution_steps",w.step,{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    await f.updateRow("bridge_commands",w.command,{lease_owner:`bridge:${await f.bridge(w.user)}:${w.command}`});
    const before=await f.snapshot(w);
    expect(await f.bridgeEvent(w,f.event(w,"accepted"))).toMatchObject({status:"step_not_calling"});expect(await f.snapshot(w)).toEqual(before);
  });
  it.each(["idle","prepared","calling"])("B8 disconnect preserves %s semantics; heartbeat alone never advances task",async phase=>{
    const w=await f.world();
    if(phase!=="prepared")await f.lease(w);
    if(phase==="idle"){await f.bridgeEvent(w,f.event(w,"accepted"));await f.bridgeEvent(w,f.event(w,"turn_completed"));}
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await f.q("select * from public.sweep_bridge_heartbeats(now(),50)");
    const expected=phase==="idle"?"idle":phase==="prepared"?"dispatched":"unreachable";
    expect(await f.state(w)).toMatchObject({state:expected});expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"unreachable"});
    const before=await f.snapshot(w);await f.heartbeat(w);expect(await f.snapshot(w)).toEqual(before);
  });
  it("B8 bounded disconnect sweep advances beyond already unreachable bridges",async()=>{
    await f.q("update public.bridges set last_heartbeat_at=now()");
    const worlds=[await f.world(),await f.world(),await f.world()];
    for(const w of worlds){await f.lease(w);await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});}
    for(let n=0;n<worlds.length;n++)await f.q("select * from public.sweep_bridge_heartbeats(now(),1)");
    for(const w of worlds)expect(await f.state(w)).toMatchObject({state:"unreachable"});
  });
  it("B7/B8 lifecycle fanout descriptors survive retries without copying text",async()=>{
    const w=await f.world();await f.lease(w);
    await f.updateRow("bridges",w.bridge,{last_heartbeat_at:"2000-01-01T00:00:00Z"});
    await f.q("select * from public.sweep_bridge_heartbeats(now(),50)");
    await f.heartbeat(w);
    const rows=await f.q("select bridge_id,external_event_id,payload from public.execution_events where run_id=$1 and payload->>'event_type' in ('bridge_unreachable','bridge_restored') order by id",[w.run]);
    expect(rows).toHaveLength(2);
    expect(rows.map(row=>row.payload)).toEqual(["bridge_unreachable","bridge_restored"].map(event_type=>({event_type,agent_session_id:w.session,agent_task_id:w.task,turn_seq:w.turn,fanout_pending:true})));
    for(const row of rows){expect(row.bridge_id).toBe(w.bridge);expect(row.external_event_id).toMatch(/^bridge-(unreachable|restored):/);}
    await f.heartbeat(w);
    expect(await f.q("select bridge_id,external_event_id,payload from public.execution_events where run_id=$1 and payload->>'event_type' in ('bridge_unreachable','bridge_restored') order by id",[w.run])).toEqual(rows);
  });
  it.each([false,true])("B12 revocation leased=%s preserves confirmed versus requested stop",async leased=>{
    const w=await f.world();if(leased)await f.lease(w);
    const result=(await f.one("select public.revoke_bridge($1,$2) as result",[w.user,w.bridge])).result;
    expect(result).toMatchObject({status:"revoked",tasks:[{agent_task_id:w.task,cancel:leased?"requested_only":"confirmed"}]});
    expect(await f.one("select status,secret_hash from public.bridges where id=$1",[w.bridge])).toEqual({status:"revoked",secret_hash:null});
    expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"closed"});
    expect(await f.one("select state,stopped_at from public.execution_runs where id=$1",[w.run])).toEqual({state:"stopped",stopped_at:null});
    expect(await f.q("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).toEqual([]);
  });
  it("B11/B12 registration rotates hashes, requires explicit reactivate, and keeps closed sessions closed",async()=>{
    const w=await f.world(),ref=String((await f.one("select device_ref from public.bridges where id=$1",[w.bridge])).device_ref);
    const report={adapters:{"agent:codex":{installed:true,version:"1",signed_in:"yes",managed_settings:false}}};
    const register=async(reactivate=false)=>(await f.one("select public.register_bridge($1,$2,$3,'1',$4::jsonb,$5::text[],$6) as result",[w.user,ref,createHash("sha256").update(randomUUID()).digest("hex"),JSON.stringify(report),["agent:codex"],reactivate])).result;
    expect(await register()).toMatchObject({status:"rotated",bridge_id:w.bridge});
    const old=await f.one("select secret_hash from public.bridges where id=$1",[w.bridge]);await register();expect(await f.one("select secret_hash from public.bridges where id=$1",[w.bridge])).not.toEqual(old);
    await f.q("select public.revoke_bridge($1,$2)",[w.user,w.bridge]);expect(await register()).toMatchObject({status:"revoked"});expect(await register(true)).toMatchObject({status:"reactivated"});
    expect(await f.one("select status from public.agent_sessions where id=$1",[w.session])).toEqual({status:"closed"});
  });
  it("B2/B5 answer command closes abandoned request without restoring card",async()=>{
    const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Choose",question:answerQuestionFixture()}));
    const answer=await f.answer(w.user,w.task);expect(answer.status).toBe("answered");
    const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[answer.step_id])).id);
    expect(await f.lease({...w,command})).toMatchObject({status:"leased",command:{kind:"answer",provider_request_id:"request",answers:{choice:"A"}}});
    expect(await f.settle({...w,command},"request_closed")).toMatchObject({status:"settled"});
    expect(await f.one("select pending_question,answered_question,abandoned_question from public.agent_tasks where id=$1",[w.task])).toEqual({pending_question:null,answered_question:null,abandoned_question:[w.task,"request"]});
  });
  it("B5 identical request_closed retry is write-free and can repair fanout",async()=>{
    const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Choose",question:answerQuestionFixture()}));
    const answer=await f.answer(w.user,w.task);
    const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[answer.step_id])).id);
    await f.lease({...w,command});
    const result=await f.settle({...w,command},"request_closed"),before=await f.snapshot(w);
    expect(await f.settle({...w,command},"request_closed")).toEqual(result);
    expect(await f.snapshot(w)).toEqual(before);
    expect(await f.settle({...w,command},"readback","received",true)).toEqual({status:"stale"});
    expect(await f.settle({...w,command,bridge:await f.bridge(w.user)},"request_closed")).toEqual({status:"not_found"});
  });
  it("B5 request_closed leaves the running turn able to complete",async()=>{
    const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Choose",question:answerQuestionFixture()}));
    const answer=await f.answer(w.user,w.task);
    const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[answer.step_id])).id);
    await f.lease({...w,command});await f.settle({...w,command},"request_closed");
    expect(await f.bridgeEvent(w,f.event(w,"turn_completed"))).toMatchObject({status:"applied",task_state:"idle"});
    expect(await f.one("select state from public.execution_steps where id=$1",[answer.step_id])).toEqual({state:"failed"});
  });
  it("B5 answer received readback preserves reducer lifecycle through next question",async()=>{
    const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Choose",question:answerQuestionFixture()}));
    const answer=await f.answer(w.user,w.task);
    const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[answer.step_id])).id);
    await f.lease({...w,command});
    expect(await f.settle({...w,command},"readback","received",true)).toMatchObject({status:"settled",task_state:"running"});
    expect(await f.bridgeEvent(w,f.event(w,"question",{text:"Next",question:answerQuestionFixture({}, {provider_request_id:"next"})}))).toMatchObject({status:"applied",task_state:"awaiting_answer"});
    expect(await f.one("select answered_question,pending_question->>'provider_request_id' as request from public.agent_tasks where id=$1",[w.task])).toEqual({answered_question:null,request:"next"});
  });
  it.each(["sent","task_unknown"])("B5 cancel complete %s settles only the authorized cancellation",async result=>{
    const w=await f.world();await f.lease(w);await f.stop(w.user,w.session);
    const command=String((await f.one("select id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task])).id);
    await f.lease({...w,command},null);
    const before=await f.snapshot(w);expect(await f.settle({...w,command},"readback","received",true)).toEqual({status:"stale"});
    const after=await f.snapshot(w);expect(after.slice(1)).toEqual(before.slice(1));
    expect(after[0]).toEqual(before[0].map(row=>row.id===command?{...row,outcome:"unknown",outcome_at:expect.any(Date)}:row));
    expect(await f.settle({...w,command},"complete",result)).toMatchObject({status:"settled"});
    expect(await f.state(w)).toMatchObject({state:result==="task_unknown"?"cancelled":"dispatched"});
    expect(await f.one("select outcome,outcome_at is not null as timed from public.bridge_commands where id=$1",[command])).toEqual({outcome:result,timed:true});
  });
  it("B5 unknown cancel can be safely repeated and completed after lease expiry",async()=>{
    const w=await f.world();await f.lease(w);await f.stop(w.user,w.session);
    const row=await f.one("select id,step_id from public.bridge_commands where agent_task_id=$1 and kind='cancel'",[w.task]);
    await f.lease({...w,command:String(row.id)},null);await f.updateRow("execution_steps",String(row.step_id),{lease_expires_at:"2000-01-01T00:00:00Z"});await f.q("select public.sweep_agent_step_leases(now())");
    expect(await f.settle({...w,command:String(row.id)},"complete","sent")).toMatchObject({status:"settled"});
    expect(await f.one("select state from public.execution_steps where id=$1",[row.step_id])).toEqual({state:"called"});
  });
  it("B4 closed Action is withdrawn before lease without coordinator Stop or stopped_at",async()=>{
    const w=await f.world();await f.updateRow("actions",w.action,{status:"done"});
    expect(await f.lease(w)).toMatchObject({status:"withdrawn",reason:"action_closed"});
    expect(await f.one("select state,stopped_at from public.execution_runs where id=$1",[w.run])).toEqual({state:"stopped",stopped_at:null});
    expect(await f.state(w)).toMatchObject({state:"cancelled"});expect(await f.msg(w.message)).toMatchObject({delivery_state:"cancelled"});
    expect(await f.q("select 1 from public.inbox_events where user_id=$1 and type='run_stop'",[w.user])).toEqual([]);
  });
  it.each(["revoked","no_bridge","task_run"])("B2 trigger omits %s routes",async kind=>{
    const w=await f.turnWorld();
    if(kind==="revoked")await f.updateRow("bridges",w.bridge,{status:"revoked",revoked_at:new Date().toISOString()});
    if(kind==="no_bridge")await f.updateRow("agent_connections",w.connection,{bridge_id:null});
    const result=await f.start(w.user,w.message);expect(result.status).toBe("started");
    if(kind==="task_run"){
      await f.q("delete from public.bridge_commands where step_id=$1",[result.step_id]);await f.updateRow("execution_runs",result.run_id!,{kind:"task"});
      await f.updateRow("execution_steps",result.step_id!,{state:"failed"});await f.updateRow("execution_steps",result.step_id!,{state:"prepared"});
    }
    expect(await f.q("select id from public.bridge_commands where user_id=$1",[w.user])).toEqual([]);
  });
  it("B10 three queued messages resume FIFO once through heartbeat and turn completion",async()=>{
    const base=await f.turnWorld(true);await f.updateRow("agent_sessions",base.session!,{status:"unreachable"});
    const ids=[base.message];
    for(const text of ["second","third"])ids.push(String((await f.post(base.user,base.conversation,randomUUID(),text)).message_id));
    for(const id of ids)expect(await f.start(base.user,id)).toMatchObject({status:"queued",reason:"session_busy"});
    expect((await f.heartbeat(base)).kick_session_ids).toContain(base.session);
    await f.q("insert into public.execution_actors(user_id) values($1) on conflict do nothing",[base.user]);await f.q("update public.execution_controls set blocked=false");
    let previousCursor=0;
    for(const message of ids){
      const turn=await f.next(base.user,base.session!);expect(turn.status).toBe("started");
      const row=await f.one("select id,cursor from public.bridge_commands where step_id=$1",[turn.step_id]);expect(Number(row.cursor)).toBeGreaterThan(previousCursor);previousCursor=Number(row.cursor);
      const mode=String((await f.one("select mode from public.execution_policies where user_id=$1",[base.user])).mode);
      const w={...base,session:base.session!,task:turn.agent_task_id!,turn:turn.turn_seq!,command:String(row.id),mode};
      expect(await f.lease(w)).toMatchObject({status:"leased",command:{message:{id:message}}});
      expect(await f.bridgeEvent(w,f.event(w,"accepted"))).toMatchObject({status:"applied"});expect(await f.bridgeEvent(w,f.event(w,"turn_completed"))).toMatchObject({task_state:"idle"});
    }
    expect(await f.next(base.user,base.session!)).toEqual({status:"empty"});expect(await f.count("select 1 from public.bridge_commands where user_id=$1",[base.user])).toBe(3);
  });
  it("B2/B5 locally answered secret has no value in the answer payload",async()=>{
    const w=await f.world();await f.lease(w);await f.bridgeEvent(w,f.event(w,"question",{text:"Answer on this Mac",question:answerQuestionFixture({secret:true,options:[]})}));
    const answer=await f.answer(w.user,w.task,"request",null,true);expect(answer.status).toBe("answered");
    const command=String((await f.one("select id from public.bridge_commands where step_id=$1",[answer.step_id])).id);
    expect(await f.lease({...w,command})).toMatchObject({status:"leased",command:{kind:"answer",answered_locally:true,answers:null,answer_text:null}});
  });
  it("B11 bounded redelivery rotates past blocked heads and excludes unreachable sessions",async()=>{
    const worlds=[await f.world(),await f.world(),await f.world(),await f.world()];
    await f.q("begin");
    try {
      await f.q("update public.conversation_messages set delivery_reason='invalid_referent' where delivery_state='not_sent'");
      for(const w of worlds)await f.lease(w,null);
      await f.updateRow("agent_sessions",worlds[3].session,{status:"unreachable"});
      await f.q("create or replace function public.db_now() returns timestamptz language sql stable set search_path='' as $$ select current_setting('app.now')::timestamptz $$");
      const seen=new Set<string>(),base=Date.now();
      for(let n=0;n<3;n++){
        await f.q("select set_config('app.now',$1,false)",[new Date(base+n*60_000).toISOString()]);
        const rows=await f.q("select * from public.bridge_redelivery_candidates(1)");
        expect(rows).toHaveLength(1);seen.add(String(rows[0].conversation_id));
      }
      expect([...seen].sort()).toEqual(worlds.slice(0,3).map(w=>w.conversation).sort());
    } finally {await f.q("rollback");}
  });
  it("B1 retention removes only old terminal commands",async()=>{
    const w=await f.world(),unknown=await f.world();await f.lease(unknown);await f.updateRow("execution_steps",unknown.step,{state:"unknown_outcome"});
    await f.stop(w.user,w.session);for(const x of [w,unknown])await f.updateRow("bridge_commands",x.command,{created_at:"2000-01-01T00:00:00Z"});
    await f.q("select public.purge_bridge_commands('2001-01-01',1000)");
    expect(await f.q("select id from public.bridge_commands where id=any($1)",[[w.command,unknown.command]])).toEqual([{id:unknown.command}]);
  });
}
