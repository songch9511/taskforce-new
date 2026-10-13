import { createHash, randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { MAX_LIVE_EXTERNAL_TASKS } from "../../src/lib/execution/limits";
import { userCreatedAction } from "../../src/lib/actions/user-claims";
import { conversationAgentFixtures, type ConversationAgentDb } from "./conversation-agent-target.scenarios";

export const D1C1_MIGRATION = "20261115000000_agent_turn_start.sql";
export type TurnResult = { status: string; action_id?: string; run_id?: string; agent_task_id?: string; turn_seq?: number; step_id?: string; created_action?: boolean };
export function agentTurnFixtures(db: () => ConversationAgentDb) {
  const base = conversationAgentFixtures(db);
  const f = {
    ...base,
    start: async (user: string, message: string, actions: string[] = [], contexts: string[] = [], access = "read_only", liveLimit = MAX_LIVE_EXTERNAL_TASKS) =>
      (await base.one(`select public.start_agent_turn($1,$2,$3::uuid[],$4::uuid[],$5,$6) as result`, [user, message, actions, contexts, access, liveLimit])).result as TurnResult,
    async next(user: string, session: string): Promise<TurnResult> {
      const { id } = await base.one(`select public.next_queued_agent_message($1,$2) as id`, [user, session]);
      if (!id) return {status:"empty"};
      const message = await base.one(`select refs,selected from public.conversation_messages where id=$1`,[id]);
      const refs = message.refs as {agent_turn?: {action_ids?: string[]; context_ids?: string[]}};
      const chips = refs.agent_turn ?? message.selected as {action_ids?: string[]; context_ids?: string[]} | null;
      const result = await f.start(user,String(id),chips?.action_ids ?? [],chips?.context_ids ?? []);
      if (result.status === "not_found" || result.status === "already_dispatched") {
        return (await base.one(`select public.mark_agent_message_not_sent($1,$2,$3) as result`,[user,id,result.status])).result as TurnResult;
      }
      return result;
    },
    open: (user: string, session: string, action: string, budget: number | null = null) => base.id(`select public.open_agent_conversation_run($1,$2,$3,null,$4) as id`, [user, session, action, budget]),
    async turnWorld(bound = false) {
      const user = await base.user();
      const bridge = await base.bridge(user);
      const connection = await base.agentConnection(user, bridge, { adapter: "agent:codex" });
      const session = bound ? await base.session(user, connection) : null;
      const conversation = await base.agentConversation(user, connection, session);
      const message = String((await base.post(user, conversation, randomUUID(), "  First   line  \nFull original body")).message_id);
      return { user, bridge, connection, session, conversation, message };
    },
    async idle(result: TurnResult) {
      await base.updateRow("agent_tasks", result.agent_task_id!, { state: "idle" });
    },
  };
  return f;
}

export function agentTurnStartTests(db: () => ConversationAgentDb) {
  const f = agentTurnFixtures(db);
  const count = (table: string, user: string) => f.count(`select 1 from public.${table} where user_id=$1`, [user]);
  describe("agent turn start contract", () => {
    it("R1 direct agent messages create no approval input; task external steps still require approval", async () => {
      const w = await f.turnWorld(); const r = await f.start(w.user,w.message);
      expect(await f.one(`select needs_approval from public.execution_steps where id=$1`,[r.step_id])).toEqual({needs_approval:false});
      expect(await f.q(`select kind from public.coordinator_pending_inputs($1) where kind='approval'`,[w.user])).toEqual([]);
      const task = await f.run(w.user,r.action_id!);
      const step = await f.id(`select public.append_step($1,2,'{"kind":"external","provider":"gmail","tool":"send","purpose":"mail"}') as id`,[task]);
      await f.q(`select public.prepare_step($1,0)`,[step]);
      expect(await f.one(`select needs_approval from public.execution_steps where id=$1`,[step])).toEqual({needs_approval:true});
    });
    it.each(["done","dropped"])("R2 closed previous issue %s creates a new Action for chipless work", async status => {
      const w = await f.turnWorld(); const first = await f.start(w.user,w.message); await f.idle(first);
      await f.updateRow("actions",first.action_id!,{status});
      await f.q(`select public.stop_run($1,$2)`,[w.user,first.run_id]);
      const message = String((await f.post(w.user,w.conversation,randomUUID(),"new work")).message_id);
      const next = await f.start(w.user,message);
      expect(next).toMatchObject({status:"started",created_action:true,turn_seq:2});
      expect(next.action_id).not.toBe(first.action_id);
      expect(await count("actions",w.user)).toBe(2);
    });
    it("R3 deferred first messages create nothing until started and share one Action", async () => {
      const w = await f.turnWorld(true); await f.updateRow("agent_sessions",w.session!,{status:"external"});
      const second = String((await f.post(w.user,w.conversation,randomUUID(),"second message")).message_id);
      for(const message of [w.message,second]) expect(await f.start(w.user,message)).toMatchObject({status:"queued",reason:"session_external"});
      for(const table of ["actions","sources","claims","action_events","execution_runs","agent_tasks","metric_events"]) expect(await count(table,w.user)).toBe(0);
      await f.updateRow("agent_sessions",w.session!,{status:"bound"});
      const first = await f.next(w.user,w.session!); expect(first.status).toBe("started"); await f.idle(first);
      expect(await f.next(w.user,w.session!)).toMatchObject({status:"started",action_id:first.action_id,run_id:first.run_id,created_action:false,turn_seq:2});
      expect(await count("actions",w.user)).toBe(1);
    });
    it.each([false,true])("R3 FIFO prevents a newer message overtaking an older one (bound %s)", async bound => {
      const w = await f.turnWorld(bound);
      const newer = String((await f.post(w.user,w.conversation,randomUUID(),"newer")).message_id);
      expect(await f.start(w.user,newer)).toMatchObject({status:"queued",reason:"queue_order"});
      expect(await count("actions",w.user)).toBe(0);
      const first = await f.start(w.user,w.message); expect(first.status).toBe("started"); await f.idle(first);
      expect(await f.start(w.user,newer)).toMatchObject({status:"started",action_id:first.action_id,turn_seq:2});
    });
    it("R3 FIFO uses sequence within a conversation when transaction timestamps are reversed", async () => {
      const w = await f.turnWorld(true);
      const second = String((await f.post(w.user,w.conversation,randomUUID(),"later sequence")).message_id);
      await f.updateRow("conversation_messages",second,{created_at:"2020-01-01T00:00:00Z"});
      expect(await f.start(w.user,second)).toMatchObject({status:"queued",reason:"queue_order"});
      expect(await f.one(`select public.next_queued_agent_message($1,$2) as id`,[w.user,w.session])).toEqual({id:w.message});
      const first = await f.next(w.user,w.session!); await f.idle(first);
      expect(await f.next(w.user,w.session!)).toMatchObject({status:"started",action_id:first.action_id,turn_seq:2});
    });
    it("R4 a missing saved Action is marked not_found only during automatic resume", async () => {
      const w = await f.turnWorld(true);
      await f.updateRow("conversation_messages",w.message,{selected:{action_ids:[randomUUID()],run_ids:[],artifact_ids:[]}});
      const second = String((await f.post(w.user,w.conversation,randomUUID(),"valid next")).message_id);
      expect(await f.next(w.user,w.session!)).toEqual({status:"not_sent",reason:"not_found"});
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:"not_found"});
      expect((await f.next(w.user,w.session!)).status).toBe("started");
      expect(await f.msg(second)).toMatchObject({delivery_state:"dispatched"});
    });
    it("R4 a prior unknown outcome leaves the retry queue without a second dispatch", async () => {
      const w = await f.turnWorld(true); const first = await f.start(w.user,w.message); await f.idle(first);
      await f.updateRow("execution_steps",first.step_id!,{state:"unknown_outcome"});
      await f.updateRow("conversation_messages",w.message,{delivery_state:"not_sent",delivery_reason:"spawn_failed"});
      expect(await f.next(w.user,w.session!)).toEqual({status:"not_sent",reason:"already_dispatched"});
      expect(await f.one(`select public.next_queued_agent_message($1,$2) as id`,[w.user,w.session])).toEqual({id:null});
      expect(await count("agent_tasks",w.user)).toBe(1);
    });
    it("R4 unresolved referent does not block the queue and a selected referent delivers once", async () => {
      const w = await f.turnWorld(true); const actions = [await f.action(w.user),await f.action(w.user)];
      await f.updateRow("conversation_messages",w.message,{selected:{action_ids:actions,run_ids:[],artifact_ids:[]}});
      expect(await f.start(w.user,w.message,actions)).toEqual({status:"needs_referent",candidates:actions});
      const second = String((await f.post(w.user,w.conversation,randomUUID(),"plain")).message_id);
      const r = await f.next(w.user,w.session!); expect(r.status).toBe("started");
      expect(await f.msg(second)).toMatchObject({delivery_state:"dispatched"}); await f.idle(r);
      await f.q(`select public.set_agent_message_referent($1,$2,$3)`,[w.user,w.message,actions[1]]);
      expect(await f.next(w.user,w.session!)).toMatchObject({status:"started",action_id:actions[1],turn_seq:2});
      expect((await f.start(w.user,w.message)).status).toBe("already_dispatched");
    });
    it("R4 an invalid saved referent leaves the automatic queue", async () => {
      const w = await f.turnWorld(true); const action = await f.action(w.user);
      await f.updateRow("conversation_messages",w.message,{selected:{action_ids:[action],run_ids:[],artifact_ids:[]}});
      await f.updateRow("actions",action,{status:"done"});
      await f.next(w.user,w.session!);
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:"invalid_referent"});
      const next = String((await f.post(w.user,w.conversation,randomUUID(),"plain")).message_id);
      expect((await f.next(w.user,w.session!)).status).toBe("started");
      expect(await f.msg(next)).toMatchObject({delivery_state:"dispatched"});
    });
    it("R6 execution rows keep only the message reference and conversation id", async () => {
      const w = await f.turnWorld(); const r = await f.start(w.user,w.message);
      expect(await f.one(`select request,conversation_id from public.execution_runs where id=$1`,[r.run_id])).toEqual({request:"",conversation_id:w.conversation});
      expect(await f.one(`select body,args from public.execution_steps where id=$1`,[r.step_id])).toEqual({body:"",args:{message_id:w.message}});
    });
    it.each(["\n \t\n  real   request \nnext","\n \t\n"])("R8 first nonempty line names the Action and pending session: %j", async text => {
      const w = await f.turnWorld(); await f.updateRow("conversation_messages",w.message,{text});
      const r = await f.start(w.user,w.message); const title = text.includes("real") ? "real request" : "Untitled";
      expect(await f.one(`select title from public.actions where id=$1`,[r.action_id])).toEqual({title});
      expect(await f.one(`select display_name from public.agent_sessions where user_id=$1`,[w.user])).toEqual({display_name:title});
    });
    it("R7 SQL receives the live limit and resumes a deferred first turn without extra Actions", async () => {
      const w = await f.turnWorld();
      const session = await f.session(w.user,w.connection);
      const run = await f.agentRun(w.user,await f.action(w.user),{agent_session_id:session});
      const task = await f.task(w.user,run,session,{state:"running"});
      const before = await count("actions",w.user);
      const call = () => f.one(`select public.start_agent_turn($1,$2,'{}','{}','read_only',1) as result`,[w.user,w.message]);
      expect((await call()).result).toEqual({status:"queued",reason:"live_limit"});
      expect(await count("actions",w.user)).toBe(before);
      const pending = String((await f.one(`select agent_session_id from public.conversations where id=$1`,[w.conversation])).agent_session_id);
      expect(await f.one(`select display_name from public.agent_sessions where id=$1`,[pending])).toEqual({display_name:"First line"});
      await f.updateRow("agent_tasks",task,{state:"idle"});
      expect(await f.next(w.user,pending)).toMatchObject({status:"started",created_action:true});
      expect(await count("actions",w.user)).toBe(before+1);
    });
    it("R5 selector only returns an owned eligible message with no registry or writes", async () => {
      const w = await f.turnWorld(true); const other = await f.user();
      const before = await f.msg(w.message);
      expect(await f.one(`select public.next_queued_agent_message($1,$2) as id`,[other,w.session])).toEqual({id:null});
      expect(await f.one(`select public.next_queued_agent_message($1,$2) as id`,[w.user,w.session])).toEqual({id:w.message});
      expect(await f.msg(w.message)).toEqual(before);
      expect(await count("actions",w.user)).toBe(0);
      expect(await count("agent_tasks",w.user)).toBe(0);
      const body = String((await f.one(`select prosrc from pg_proc where proname='next_queued_agent_message'`)).prosrc);
      expect(body).not.toMatch(/agent:codex|agent:claude-code|start_agent_turn|for update|insert into|update public/i);
    });
    it("R8 duplicate chips select one Action or one context", async () => {
      const w = await f.turnWorld(); const action = await f.action(w.user);
      expect(await f.start(w.user,w.message,[action,action])).toMatchObject({status:"started",action_id:action});
      const other = await f.turnWorld(); const context = await f.context(other.user);
      const r = await f.start(other.user,other.message,[],[context,context]);
      expect(await f.q(`select context_id from public.context_members where action_id=$1`,[r.action_id])).toEqual([{context_id:context}]);
    });
    it("R8 closed session is not_sent with session_closed and creates no Action", async () => {
      const w = await f.turnWorld(true); await f.updateRow("agent_sessions",w.session!,{status:"closed"});
      expect(await f.start(w.user,w.message)).toEqual({status:"not_sent",reason:"session_closed"});
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:"session_closed"});
      expect(await count("actions",w.user)).toBe(0);
    });
    it("R8 conversation binding and first bound Action survive later turns; selected candidate is rechecked", async () => {
      const w = await f.turnWorld(); const first = await f.start(w.user,w.message); await f.idle(first);
      const session = (await f.one(`select agent_session_id from public.conversations where id=$1`,[w.conversation])).agent_session_id;
      const action = await f.action(w.user);
      const next = String((await f.post(w.user,w.conversation,randomUUID(),"next")).message_id);
      const second = await f.start(w.user,next,[action]); expect(second.status).toBe("started"); await f.idle(second);
      expect(await f.one(`select agent_session_id from public.conversations where id=$1`,[w.conversation])).toEqual({agent_session_id:session});
      expect(await f.one(`select bound_action_id from public.agent_sessions where id=$1`,[session])).toEqual({bound_action_id:first.action_id});
      const third = String((await f.post(w.user,w.conversation,randomUUID(),"choose")).message_id);
      await f.start(w.user,third,[first.action_id!,action]);
      await f.q(`select public.set_agent_message_referent($1,$2,$3)`,[w.user,third,action]);
      await f.updateRow("conversation_messages",third,{refs:{referent_candidates:[first.action_id],referent_action_id:action}});
      expect(await f.start(w.user,third)).toEqual({status:"not_sent",reason:"invalid_referent"});
      expect(await count("agent_tasks",w.user)).toBe(2);
    });
    it("T1 only conversation runs accept agent_message; other future kinds stay closed", async () => {
      const w = await f.turnWorld(true); const action = await f.action(w.user);
      const run = await f.open(w.user, w.session!, action); const task = await f.run(w.user, action);
      const append = (id: string, seq: number, kind: string) => f.id(`select public.append_step($1,$2,$3::jsonb) as id`, [id, seq, JSON.stringify({ kind, provider: "agent:codex", tool: "message", purpose: "message" })]);
      expect(await append(run, 1, "agent_message")).toEqual(expect.any(String));
      await expect(append(task, 2, "agent_message")).rejects.toThrow(/append_step/);
      for (const kind of ["plan", "draft", "external", "agent_dispatch", "agent_cancel", "review", "check", "send", "observe"]) await expect(append(run, 2, kind)).rejects.toThrow(/append_step/);
    });
    it("T2 conversation runs preserve create_run defaults, omit plan and reuse an open run", async () => {
      const w = await f.turnWorld(true); const action = await f.action(w.user);
      const task = await f.run(w.user, action); const run = await f.open(w.user, w.session!, action);
      const columns = "user_id,action_id,policy_id,budget_credits,state,hold_reason,outcome,directive_version,bundle_context_version,reviewed_turn_seq";
      expect(await f.one(`select ${columns} from public.execution_runs where id=$1`, [run])).toEqual(await f.one(`select ${columns} from public.execution_runs where id=$1`, [task]));
      expect(await f.count(`select 1 from public.execution_steps where run_id=$1`, [run])).toBe(0);
      expect(await f.open(w.user, w.session!, action)).toBe(run);
      await expect(f.open(w.user, w.session!, await f.action(w.user), 0)).rejects.toThrow();
    });
    it("T3 settled conversation remains open while settled task completes", async () => {
      const w = await f.turnWorld(); const started = await f.start(w.user, w.message);
      const task = await f.run(w.user, started.action_id!); const plan = await f.firstStep(task);
      await f.q(`select public.prepare_step($1,0)`, [plan]);
      for (const step of [started.step_id!, plan]) {
        await f.q(`update public.execution_steps set state='calling',lease_owner='fixture' where id=$1`, [step]);
        expect((await f.one(`select public.settle_step($1,'fixture','called','{}','draft_ready') as ok`, [step])).ok).toBe(true);
      }
      expect((await f.one(`select state from public.execution_runs where id=$1`, [started.run_id])).state).toBe("running");
      expect((await f.one(`select state from public.execution_runs where id=$1`, [task])).state).toBe("done");
    });
    it("T3 failed conversation step does not close the run; failed task still fails", async () => {
      const w = await f.turnWorld(); const r = await f.start(w.user,w.message);
      const task = await f.run(w.user,r.action_id!); const plan = await f.firstStep(task);
      await f.q(`select public.prepare_step($1,0)`,[plan]);
      for(const step of [r.step_id!,plan]) {
        await f.updateRow("execution_steps",step,{state:"calling",lease_owner:"fixture"});
        expect((await f.one(`select public.settle_step($1,'fixture','failed','{}') as ok`,[step])).ok).toBe(true);
      }
      expect((await f.one(`select state from public.execution_runs where id=$1`,[r.run_id])).state).toBe("running");
      expect((await f.one(`select state from public.execution_runs where id=$1`,[task])).state).toBe("failed");
    });
    it("T4 first turn creates one user Action with source-free event, original note, prepared intent and no call", async () => {
      const w = await f.turnWorld(); const r = await f.start(w.user, w.message);
      expect(r).toMatchObject({ status: "started", created_action: true, turn_seq: 1 });
      expect((await f.one(`select title from public.actions where id=$1`, [r.action_id])).title).toBe("First line");
      const { claims, projected } = userCreatedAction({title:"First line",dueDate:null,sourceId:null},new Date(),randomUUID);
      expect(await f.q(`select origin,field,value from public.claims where action_id=$1 order by field`,[r.action_id])).toEqual(claims.map(({origin,field,value})=>({origin,field,value})).sort((a,b)=>a.field.localeCompare(b.field)));
      expect(await f.one(`select title,owner,status,due_date,due_at,needs_confirmation,confirm_reasons,resolution from public.actions where id=$1`,[r.action_id])).toMatchObject(projected);
      expect(await f.one(`select type,actor,rule,source_id from public.action_events where action_id=$1`, [r.action_id])).toEqual({ type: "user_created", actor: "user", rule: "assistant_agent", source_id: null });
      expect(await f.one(`select kind,raw_text from public.sources where user_id=$1`, [w.user])).toEqual({ kind: "note", raw_text: "  First   line  \nFull original body" });
      expect(await f.one(`select kind,state,lease_owner,intent_key from public.execution_steps where id=$1`, [r.step_id])).toMatchObject({ kind: "agent_message", state: "prepared", lease_owner: null, intent_key: expect.stringContaining(`message:${w.message}`) });
      expect(await f.one(`select role,quote from public.evidence where action_id=$1`, [r.action_id])).toEqual({role:"created",quote:"  First   line  \nFull original body"});
      expect(await count("execution_intents", w.user)).toBe(0);
      expect(await f.one(`select status,external_session_id from public.agent_sessions where user_id=$1`, [w.user])).toEqual({ status: "bound", external_session_id: `pending:${w.conversation}` });
      expect((await f.start(w.user, w.message)).status).toBe("already_dispatched");
      for (const table of ["actions", "agent_sessions", "execution_runs", "agent_tasks"]) expect(await count(table, w.user)).toBe(1);
    });
    it("first-line title truncates at 80 characters; Action and note ids derive from message id", async () => {
      const w = await f.turnWorld();
      const text = "😀".repeat(90) + "\nsecond line";
      await f.updateRow("conversation_messages",w.message,{text});
      const r = await f.start(w.user,w.message);
      expect((await f.one(`select title from public.actions where id=$1`,[r.action_id])).title).toBe("😀".repeat(80));
      const uuidFor = (prefix: string) => {
        const hex = createHash("sha256").update(prefix + w.message).digest("hex").slice(0,32);
        return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
      };
      expect(r.action_id).toBe(uuidFor("tf:assistant_agent:action:"));
      expect(await f.one(`select id,raw_text from public.sources where user_id=$1`,[w.user])).toEqual({id:uuidFor("tf:assistant_agent:note:"),raw_text:text});
    });
    it("a pre-existing closed deterministic Action is never recreated", async () => {
      const w = await f.turnWorld();
      const action = String((await f.one(`select substr(encode(sha256(convert_to('tf:assistant_agent:action:' || $1::text, 'UTF8')), 'hex'),1,32)::uuid as id`,[w.message])).id);
      await f.q(`insert into public.actions(id,user_id,title,status) values($1,$2,'closed','done')`,[action,w.user]);
      expect(await f.start(w.user,w.message)).toEqual({status:"not_sent",reason:"invalid_referent"});
      expect(await count("actions",w.user)).toBe(1);
      for(const table of ["sources","agent_tasks","execution_runs"]) expect(await count(table,w.user)).toBe(0);
    });
    it("T5 multiple chips write candidates only; selecting a candidate dispatches exactly once", async () => {
      const w = await f.turnWorld(); const actions = await Promise.all([f.action(w.user), f.action(w.user), f.action(w.user), f.action(w.user)]);
      expect((await f.start(w.user, w.message, actions)).status).toBe("needs_referent");
      for (const table of ["agent_sessions", "execution_runs", "agent_tasks", "sources", "metric_events"]) expect(await count(table, w.user)).toBe(0);
      expect((await f.one(`select refs from public.conversation_messages where id=$1`, [w.message])).refs).toMatchObject({ referent_candidates: actions.slice(0,3) });
      await f.q(`select public.set_agent_message_referent($1,$2,$3)`, [w.user, w.message, actions[0]]);
      expect(await f.start(w.user, w.message, actions)).toMatchObject({ status: "started", action_id: actions[0], created_action: false });
      expect((await f.start(w.user, w.message, actions)).status).toBe("already_dispatched");
      expect(await count("agent_tasks", w.user)).toBe(1);
    });
    it("T6 A then B chip creates two runs; chipless next turn reuses B", async () => {
      const w = await f.turnWorld(); const a = await f.start(w.user, w.message); await f.idle(a);
      const bId = await f.action(w.user); const msg = String((await f.post(w.user,w.conversation,randomUUID(),"B")).message_id);
      const b = await f.start(w.user,msg,[bId]); expect(b).toMatchObject({ status: "started", action_id: bId, turn_seq: 2 }); expect(b.run_id).not.toBe(a.run_id); await f.idle(b);
      const next = String((await f.post(w.user,w.conversation,randomUUID(),"continue")).message_id);
      expect(await f.start(w.user,next)).toMatchObject({ status: "started", action_id: bId, run_id: b.run_id, turn_seq: 3 });
      expect(await count("execution_runs",w.user)).toBe(2);
    });
    it("T7 stop closes the run and next message uses same session with increasing sequence", async () => {
      const w = await f.turnWorld(); const a = await f.start(w.user,w.message); await f.idle(a);
      await f.q(`select public.stop_run($1,$2)`, [w.user,a.run_id]);
      const msg = String((await f.post(w.user,w.conversation,randomUUID(),"continue")).message_id); const b = await f.start(w.user,msg);
      expect(b).toMatchObject({ status: "started", action_id: a.action_id, turn_seq: 2 }); expect(b.run_id).not.toBe(a.run_id); expect(await count("agent_sessions",w.user)).toBe(1);
    });
    it("session busy/external queue without dispatch and oldest queued message resumes", async () => {
      const w = await f.turnWorld(true); const a = await f.start(w.user,w.message);
      const msg = String((await f.post(w.user,w.conversation,randomUUID(),"queued")).message_id);
      expect((await f.start(w.user,msg)).status).toBe("queued"); expect(await f.msg(msg)).toMatchObject({ delivery_state: "queued",delivery_reason: "session_busy" });
      await f.idle(a); await f.updateRow("agent_sessions",w.session!,{status:"external"});
      expect((await f.start(w.user,msg)).status).toBe("queued"); expect(await f.msg(msg)).toMatchObject({delivery_reason:"session_external"});
      await f.updateRow("agent_sessions",w.session!,{status:"bound"}); expect(await f.next(w.user,w.session!)).toMatchObject({status:"started",turn_seq:2,action_id:a.action_id});
    });
    it("T9 live limit counts active external tasks but excludes idle and awaiting_answer", async () => {
      const w = await f.turnWorld();
      const tasks: string[] = [];
      for (const state of ["dispatched", "accepted", "running", "unreachable", "running", "idle", "awaiting_answer"]) {
        const session = await f.session(w.user,w.connection);
        const run = await f.agentRun(w.user,await f.action(w.user),{agent_session_id:session});
        tasks.push(await f.task(w.user,run,session,{state,...(state === "unreachable" ? {last_live_state:"running"} : {}),...(state === "awaiting_answer" ? {pending_question:{question_id:"q1",kind:"input",text:"Which file?"}} : {})}));
      }
      expect((await f.start(w.user,w.message)).status).toBe("queued");
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"queued",delivery_reason:"live_limit"});
      await f.updateRow("agent_tasks",tasks[0],{state:"idle"});
      expect((await f.start(w.user,w.message)).status).toBe("started");
    });
    it("one active context creates user membership; archived or missing contexts leave new Action ungrouped", async () => {
      for (const kind of ["active", "archived", "missing"]) {
        const w = await f.turnWorld();
        const context = kind === "missing" ? randomUUID() : await f.context(w.user);
        if (kind === "archived") await f.updateRow("work_contexts",context,{status:"archived"});
        const r = await f.start(w.user,w.message,[],[context]);
        expect(r.status).toBe("started");
        const members = await f.q(`select context_id,origin,removed_at from public.context_members where action_id=$1`,[r.action_id]);
        expect(members).toEqual(kind === "active" ? [{context_id:context,origin:"user",removed_at:null}] : []);
      }
    });
    it("foreign context and invalid access fail before side effects; referent must be a candidate", async () => {
      const w = await f.turnWorld(); const other = await f.user();
      expect((await f.start(w.user,w.message,[],[await f.context(other)])).status).toBe("not_found");
      await expect(f.start(w.user,w.message,[],[],"invalid")).rejects.toThrow();
      for (const table of ["agent_sessions","actions","sources","execution_runs","agent_tasks"]) expect(await count(table,w.user)).toBe(0);
      const a = await f.action(w.user), b = await f.action(w.user), outside = await f.action(w.user);
      await f.start(w.user,w.message,[a,b]);
      await f.q(`select public.set_agent_message_referent($1,$2,$3)`,[w.user,w.message,outside]);
      expect((await f.one(`select refs->>'referent_action_id' as id from public.conversation_messages where id=$1`,[w.message])).id).toBeNull();
      expect((await f.start(w.user,w.message,[a,b])).status).toBe("needs_referent");
    });
    it("failed step retries use a fresh intent; unknown outcome never redispatches", async () => {
      for (const state of ["failed","unknown_outcome"]) {
        const w = await f.turnWorld(); const first = await f.start(w.user,w.message);
        await f.updateRow("execution_steps",first.step_id!,{state});
        await f.updateRow("agent_tasks",first.agent_task_id!,{state:"failed"});
        await f.updateRow("conversation_messages",w.message,{delivery_state:"not_sent",delivery_reason:"spawn_failed"});
        const retry = await f.start(w.user,w.message);
        if (state === "failed") {
          expect(retry).toMatchObject({status:"started",action_id:first.action_id,run_id:first.run_id,created_action:false,turn_seq:2});
          const before = await f.one(`select intent_key from public.execution_steps where id=$1`,[first.step_id]);
          const after = await f.one(`select intent_key from public.execution_steps where id=$1`,[retry.step_id]);
          expect(after.intent_key).not.toBe(before.intent_key);
        } else {
          expect(retry.status).not.toBe("started");
          expect(await count("agent_tasks",w.user)).toBe(1);
        }
        expect(await count("actions",w.user)).toBe(1);
      }
    });
    it("T10 not_sent records reason and read_only retry starts without external calls", async () => {
      const w = await f.turnWorld(); await f.q(`select public.mark_agent_message_not_sent($1,$2,'write_gate_closed')`,[w.user,w.message]);
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:"write_gate_closed"}); expect(await count("agent_tasks",w.user)).toBe(0);
      expect((await f.start(w.user,w.message)).status).toBe("started"); expect(await f.msg(w.message)).toMatchObject({delivery_state:"dispatched",delivery_reason:null});
    });
    it("not_sent reasons are constrained and cannot alter another user's message", async () => {
      const w = await f.turnWorld(); const other = await f.user();
      for(const reason of ["write_gate_closed","not_connected","sign_in_needed","unsupported"]) {
        await f.q(`select public.mark_agent_message_not_sent($1,$2,$3)`,[w.user,w.message,reason]);
        expect(await f.msg(w.message)).toMatchObject({delivery_state:"not_sent",delivery_reason:reason});
      }
      const before = await f.msg(w.message);
      await expect(f.q(`select public.mark_agent_message_not_sent($1,$2,'invalid')`,[w.user,w.message])).rejects.toThrow();
      await f.q(`select public.mark_agent_message_not_sent($1,$2,'not_connected')`,[other,w.message]);
      expect(await f.msg(w.message)).toEqual(before);
      expect(await count("agent_tasks",w.user)).toBe(0);
    });
    it("T11 tools are external and both provider controls blocked; create_run agent remains forbidden", async () => {
      expect(await f.q(`select provider,tool,effect_class from public.execution_tools where provider like 'agent:%' order by provider`)).toEqual([ {provider:"agent:claude-code",tool:"message",effect_class:"external"}, {provider:"agent:codex",tool:"message",effect_class:"external"} ]);
      expect(await f.q(`select scope,key,blocked from public.execution_controls where scope='provider' and key like 'agent:%' order by key`)).toEqual([{scope:"provider",key:"agent:claude-code",blocked:true},{scope:"provider",key:"agent:codex",blocked:true}]);
      const w = await f.turnWorld(); await expect(f.q(`select public.create_run($1,$2,'agent','')`,[w.user,await f.action(w.user)])).rejects.toThrow(/create_run/);
    });
    it("T11 registered message still cannot begin_call while its provider is blocked", async () => {
      const w = await f.turnWorld(); const r = await f.start(w.user, w.message);
      await f.q(`insert into public.execution_actors(user_id) values($1)`, [w.user]);
      await f.q(`update public.execution_controls set blocked=false where scope in ('global','mode')`);
      expect((await f.one(`select public.begin_call($1,'fixture',1) as result`, [r.step_id])).result).toEqual({ gate: "blocked" });
      expect((await f.one(`select state from public.execution_steps where id=$1`, [r.step_id])).state).toBe("prepared");
      expect(await count("execution_intents", w.user)).toBe(0);
    });
    it("T12 foreign chips among multiple candidates never leak refs or create a session", async () => {
      const w = await f.turnWorld(); const other = await f.user();
      const before = await f.one(`select refs from public.conversation_messages where id=$1`, [w.message]);
      expect((await f.start(w.user, w.message, [await f.action(w.user), await f.action(other)])).status).toBe("not_found");
      expect(await f.one(`select refs from public.conversation_messages where id=$1`, [w.message])).toEqual(before);
      expect(await count("agent_sessions", w.user)).toBe(0);
      await expect(f.open(w.user, (await f.turnWorld(true)).session!, await f.action(w.user))).rejects.toThrow(/session not found/);
    });
    it("T5 every in-progress state queues but idle permits a new turn", async () => {
      for (const state of ["dispatched", "accepted", "running", "awaiting_answer", "unreachable"]) {
        const w = await f.turnWorld(); const first = await f.start(w.user, w.message);
        await f.updateRow("agent_tasks", first.agent_task_id!, { state, pending_question: state === "awaiting_answer" ? {} : null, last_live_state: state === "unreachable" ? "running" : null });
        const next = String((await f.post(w.user, w.conversation, randomUUID(), "next")).message_id);
        expect((await f.start(w.user, next)).status).toBe("queued");
        expect(await f.msg(next)).toMatchObject({delivery_reason: "session_busy"});
        expect(await count("agent_tasks", w.user)).toBe(1);
      }
    });
    it("T12 invalid owner, target, expiration and foreign Action cause no writes", async () => {
      const w = await f.turnWorld(); const other = await f.user();
      expect((await f.start(other,w.message)).status).toBe("not_found");
      const c = await f.conversation(w.user); const m = await f.message(w.user,c); expect((await f.start(w.user,m)).status).toBe("wrong_target");
      const foreign = await f.action(other); expect((await f.start(w.user,w.message,[foreign])).status).toBe("not_found");
      expect(await count("agent_tasks",w.user)).toBe(0); expect(await count("agent_sessions",w.user)).toBe(0);
      await f.updateRow("conversation_messages",w.message,{delivery_expires_at:new Date(0).toISOString()}); expect((await f.start(w.user,w.message)).status).toBe("expired");
      expect(await count("execution_runs",w.user)).toBe(0);
    });
    it("closed Actions and mismatched conversation/session connection cannot start", async () => {
      const w = await f.turnWorld();
      const action = await f.action(w.user); await f.updateRow("actions",action,{status:"done"});
      expect(await f.start(w.user,w.message,[action])).toEqual({status:"not_sent",reason:"invalid_referent"});
      const otherConnection = await f.agentConnection(w.user,w.bridge,{adapter:"agent:codex"});
      const otherSession = await f.session(w.user,otherConnection);
      await f.updateRow("conversations",w.conversation,{agent_session_id:otherSession});
      expect((await f.start(w.user,w.message)).status).toBe("not_found");
      expect(await count("agent_tasks",w.user)).toBe(0);
      expect(await count("execution_runs",w.user)).toBe(0);
      expect(await count("sources",w.user)).toBe(0);
    });
    it("terminal delivery states and helper ownership guards preserve stored message", async () => {
      for (const state of ["dispatched","expired","cancelled"]) {
        const w = await f.turnWorld(); const other = await f.user();
        await f.updateRow("conversation_messages",w.message,{delivery_state:state});
        const before = await f.msg(w.message);
        expect((await f.start(w.user,w.message)).status).not.toBe("started");
        expect((await f.one(`select public.mark_agent_message_not_sent($1,$2,'not_connected') as result`,[other,w.message])).result).toEqual({status:"not_found"});
        await f.q(`select public.mark_agent_message_not_sent($1,$2,'not_connected')`,[w.user,w.message]);
        expect(await f.msg(w.message)).toEqual(before);
        expect(await count("agent_tasks",w.user)).toBe(0);
      }
    });
    it("next queued turn ignores expired messages and resumes oldest eligible message", async () => {
      const w = await f.turnWorld(true);
      await f.updateRow("conversation_messages",w.message,{delivery_expires_at:new Date(0).toISOString()});
      const older = String((await f.post(w.user,w.conversation,randomUUID(),"older")).message_id);
      const newer = String((await f.post(w.user,w.conversation,randomUUID(),"newer")).message_id);
      const started = await f.next(w.user,w.session!);
      expect(started.status).toBe("started");
      expect(await f.one(`select message_id from public.agent_tasks where id=$1`,[started.agent_task_id])).toEqual({message_id:older});
      expect(await f.msg(newer)).toMatchObject({delivery_state:"queued"});
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"queued"});
    });
    it("T12 all new functions are invoker, empty search_path, executable only by service_role", async () => {
      const names = ["open_agent_conversation_run","start_agent_turn","set_agent_message_referent","mark_agent_message_not_sent","next_queued_agent_message"];
      const rows = await f.q(`select p.proname,p.prosecdef,p.proconfig,has_function_privilege('anon',p.oid,'execute') as anon,has_function_privilege('authenticated',p.oid,'execute') as app,has_function_privilege('service_role',p.oid,'execute') as server from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any($1) order by p.proname`,[names]);
      expect(rows).toHaveLength(5); for(const row of rows) expect(row).toMatchObject({prosecdef:false,proconfig:['search_path=""'],anon:false,app:false,server:true});
    });
    it("T13 sending records adapter/access metric; props arrays are rejected", async () => {
      const w = await f.turnWorld(); await f.start(w.user,w.message);
      expect(await f.one(`select type,props from public.metric_events where user_id=$1`,[w.user])).toEqual({type:"agent_message_sent",props:{adapter:"agent:codex",access:"read_only"}});
      await expect(f.q(`insert into public.metric_events(user_id,type,props) values($1,'agent_message_sent','[]')`,[w.user])).rejects.toThrow(/metric_events_props_shape/);
      await db().asUser(w.user,async()=> {
        await f.q(`insert into public.metric_events(type) values('assistant_opened')`);
        await expect(f.q(`insert into public.metric_events(type) values('agent_message_sent')`)).rejects.toThrow(/row-level security/);
      });
    });
  });
}
