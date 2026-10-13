import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { userClaims } from "../../src/lib/actions/user-claims";
import { claimToRow } from "../../src/lib/actions/rows";
import { agentEventFixtures, questionFixture } from "./agent-events.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

export const D1C2B_MIGRATION = "20261116120000_agent_questions_stop.sql";
export function answerQuestionFixture(item: Record<string, unknown> = {}, envelope: Record<string, unknown> = {}) {
  const q = questionFixture(envelope);
  return { ...q, questions: [{ ...q.questions[0], multi_select: false, allow_other: false, options: [{ label: "A", description: "Option A" }, { label: "B", description: "Option B" }], ...item }] };
}
export function agentQuestionsStopFixtures(db: () => ConversationAgentDb) {
  const f = agentEventFixtures(db);
  return {
    ...f,
    async questionWorld(question = answerQuestionFixture(), adapter = "agent:codex") {
      const base = await f.turnWorld();
      await f.updateRow("agent_connections", base.connection, { adapter });
      const r = await f.start(base.user,base.message);
      expect(r.status).toBe("started");
      const session = String((await f.one(`select agent_session_id from public.agent_tasks where id=$1`,[r.agent_task_id])).agent_session_id);
      const w = {...base,session,task:r.agent_task_id!,run:r.run_id!,step:r.step_id!,action:r.action_id!,turn:r.turn_seq!};
      await f.updateRow("execution_steps",w.step,{state:"calling",lease_owner:"question-fixture"});
      await f.apply(w.user, f.event(w, "question", { question, text: "Question card", adapter }));
      expect(await f.state(w)).toMatchObject({ state: "awaiting_answer" });
      return w;
    },
    async answer(user: string, task: string, request = "request", answers: unknown = { choice: "A" }, local = false) {
      return (await f.one(`select public.answer_agent_question($1,$2,$3,$4::jsonb,$5) as result`, [user, task, request, JSON.stringify(answers), local])).result as { status: string; step_id?: string };
    },
    async route(user: string, message: string, actions: string[] = [], contexts: string[] = []) {
      return (await f.one(`select public.route_agent_message($1,$2,'read_only',5,$3::uuid[],$4::uuid[]) as result`, [user, message, actions, contexts])).result as { status: string; reason?: string; step_id?: string };
    },
    async stop(user: string, session: string, surface = "assistant", scope: string | null = "turn") {
      return (await f.one(`select public.stop_agent_session($1,$2,$3,$4) as result`, [user, session, surface, scope])).result as { tasks: {agent_task_id: string; cancel: string; processes?: string}[] };
    },
    async done(user: string, action: string, status: "done" | "dropped" = "done") {
      const row = await f.one(`select * from public.actions where id=$1`, [action]);
      const claims = userClaims([{ field: "status", value: status }], new Date(), randomUUID).map(c => claimToRow(c, user, action, { sourceId: null, quote: null }));
      const result = await f.one(`select public.write_action($1,$2,$3,$4::jsonb,$5::jsonb,'[]',$6::jsonb) as written`, [user, action, row.version, JSON.stringify({ ...row, status }), JSON.stringify(claims), JSON.stringify([{ type: "user_edited", actor: "user", rule: "user", before: {status: row.status}, after: {status} }])]);
      expect(result.written).toBe(true);
    },
    answerSteps: (task: string) => f.q(`select id,state,body,args,intent_key,needs_approval from public.execution_steps where intent_key like $1`, [`%answer:${task}:%`]),
    cancelSteps: (user: string) => f.q(`select * from public.execution_steps where user_id=$1 and kind='agent_cancel'`, [user]),
  };
}

export function agentQuestionsStopTests(db: () => ConversationAgentDb) {
  const f = agentQuestionsStopFixtures(db);
  describe("questions", () => {
    it.each([
      ["single", answerQuestionFixture(), {choice:"A"}],
      ["multiple", answerQuestionFixture({multi_select:true}), {choice:["A","B"]}],
      ["Other", answerQuestionFixture({allow_other:true}), {choice:"Other answer"}],
      ["approval allow", answerQuestionFixture({}, {kind:"approval"}), {choice:"allow"}],
      ["approval deny", answerQuestionFixture({}, {kind:"approval"}), {choice:"deny"}],
    ])("Q1 accepts %s with one prepared delivery and no body copy", async (_name, question, answers) => {
      const w = await f.questionWorld(question as ReturnType<typeof answerQuestionFixture>);
      const pending = (await f.state(w)).pending_question;
      const result = await f.answer(w.user, w.task, "request", answers);
      expect(result.status).toBe("answered");
      const steps = await f.answerSteps(w.task);
      expect(steps).toHaveLength(1);
      expect(steps[0]).toMatchObject({id:result.step_id,state:"prepared",body:"",needs_approval:false,args:{agent_task_id:w.task,provider_request_id:"request",answers}});
      expect(steps[0].intent_key).toBe(`answer:${w.task}:request:0`);
      expect(await f.one(`select state,pending_question,answered_question from public.agent_tasks where id=$1`,[w.task])).toEqual({state:"running",pending_question:null,answered_question:pending});
      expect(await f.q(`select 1 from public.conversation_messages where conversation_id=$1 and role='event'`,[w.conversation])).toHaveLength(1);
      expect(JSON.stringify(await f.events(w))).not.toContain("Other answer");
      expect(await f.one(`select request from public.execution_runs where id=$1`,[w.run])).toEqual({request:""});
    });
    it.each([null, [], {}, {choice:"Z"}, {choice:["A"]}, {choice:1}, {choice:"A",extra:"B"}])("Q1 invalid single shape %# is write-free", async answers => {
      const w = await f.questionWorld(); const before = await f.state(w);
      expect(await f.answer(w.user,w.task,"request",answers)).toEqual({status:"invalid_answer"});
      expect(await f.answerSteps(w.task)).toEqual([]); expect(await f.state(w)).toEqual(before);
    });
    it("Q1 enforces multi labels, complete ids, approval choices, character and UTF-8 limits", async () => {
      const cases = [
        [answerQuestionFixture({multi_select:true}), {choice:["Z"]}],
        [answerQuestionFixture({multi_select:true}), {choice:["A","A"]}],
        [answerQuestionFixture({multi_select:true}), {choice:"A"}],
        [answerQuestionFixture({}, {kind:"approval"}), {choice:"A"}],
        [answerQuestionFixture({allow_other:true}), {choice:"x".repeat(2001)}],
        [answerQuestionFixture({allow_other:true}), {choice:"가".repeat(1500)}],
      ] as const;
      for (const [question, answers] of cases) {
        const w = await f.questionWorld(question);
        expect(await f.answer(w.user,w.task,"request",answers)).toEqual({status:"invalid_answer"});
        expect(await f.answerSteps(w.task)).toEqual([]);
      }
      const q = answerQuestionFixture(); q.questions.push({...q.questions[0],id:"second"});
      const w = await f.questionWorld(q);
      expect(await f.answer(w.user,w.task)).toEqual({status:"invalid_answer"});
      expect(await f.answer(w.user,w.task,"request",{choice:"A",second:"B"})).toMatchObject({status:"answered"});
    });
    it("Q1 secret requires local acknowledgement and persists zero secret values", async () => {
      const w = await f.questionWorld(answerQuestionFixture({secret:true}));
      expect(await f.answer(w.user,w.task,"request",null)).toEqual({status:"secret_requires_local"});
      for(const answers of [{choice:"DO_NOT_STORE_SECRET"},{choice:["DO_NOT_STORE_SECRET"]}]) {
        expect(await f.answer(w.user,w.task,"request",answers,true)).toEqual({status:"invalid_answer"});
        expect(await f.answer(w.user,w.task,"request",answers,false)).toEqual({status:"secret_requires_local"});
      }
      expect(await f.answerSteps(w.task)).toEqual([]);
      expect(await f.answer(w.user,w.task,"request",null,true)).toMatchObject({status:"answered"});
      expect((await f.answerSteps(w.task))[0]).toMatchObject({body:"",args:{agent_task_id:w.task,provider_request_id:"request",answered_locally:true}});
      const messages = await f.messages(w.conversation);
      expect(messages.some(m=>m.role === "event" && m.text === "Answered on this Mac")).toBe(true);
      const ledger = await f.q(`select payload from public.execution_events where user_id=$1`,[w.user]);
      expect(JSON.stringify([messages,ledger,await f.answerSteps(w.task),await f.state(w)])).not.toContain("DO_NOT_STORE_SECRET");
    });
    it("Q1 mixed secret envelope accepts only one local empty acknowledgement", async () => {
      const q = answerQuestionFixture(); q.questions.push({...q.questions[0],id:"secret",secret:true});
      const w = await f.questionWorld(q);
      expect(await f.answer(w.user,w.task,"request",{choice:"A"},true)).toEqual({status:"invalid_answer"});
      expect(await f.answer(w.user,w.task,"request",{},true)).toMatchObject({status:"answered"});
      const args = (await f.answerSteps(w.task))[0].args;
      expect(args).toEqual({agent_task_id:w.task,provider_request_id:"request",answered_locally:true});
    });
    it("Q1 answered question CHECK rejects malformed structure and foreign task key", async () => {
      const w = await f.questionWorld(); const pending = (await f.state(w)).pending_question as Record<string, unknown>;
      for(const answered_question of [{...pending,questions:[]},{...pending,question_key:[randomUUID(),"request"]}]) {
        await expect(f.updateRow("agent_tasks",w.task,{answered_question})).rejects.toThrow(/check constraint/);
      }
      expect(await f.one(`select answered_question from public.agent_tasks where id=$1`,[w.task])).toEqual({answered_question:null});
    });
    it.each(["idle","failed","cancelled"])("Q2 closed %s task rejects an old question", async state => {
      const w = await f.questionWorld();
      await f.updateRow("agent_tasks",w.task,{state,pending_question:null});
      expect(await f.answer(w.user,w.task)).toEqual({status:"question_stale"});
      expect(await f.answerSteps(w.task)).toEqual([]);
    });
    it("Q2 stale keys deliver nothing; a matching retry returns the original step", async () => {
      const w = await f.questionWorld();
      expect(await f.answer(w.user,w.task,"old")).toEqual({status:"question_stale"});
      expect(await f.answerSteps(w.task)).toEqual([]);
      const first = await f.answer(w.user,w.task);
      expect(await f.answer(w.user,w.task)).toEqual({status:"duplicate",step_id:first.step_id});
      expect(await f.answerSteps(w.task)).toHaveLength(1);
      await f.updateRow("agent_tasks",w.task,{state:"awaiting_answer",pending_question:{...answerQuestionFixture({}, {provider_request_id:"next"}),question_key:[w.task,"next"],asked_at:"2026-10-14T00:00:00Z"}});
      expect(await f.answer(w.user,w.task)).toEqual({status:"question_stale"});
      expect(await f.answerSteps(w.task)).toHaveLength(1);
    });
    it.each(["two","choice","secret","approval"])("Q3/Q4 free text queues %s without answering", async kind => {
      const q = answerQuestionFixture({allow_other:kind!=="choice",secret:kind==="secret"},{kind:kind==="approval"?"approval":"input"});
      if(kind==="two") q.questions.push({...q.questions[0],id:"second"});
      const w = await f.questionWorld(q);
      const message = String((await f.post(w.user,w.conversation,randomUUID(),kind === "approval" ? "allow" : "A")).message_id);
      expect(await f.route(w.user,message)).toMatchObject({status:"queued",reason:"question_open"});
      expect(await f.msg(message)).toMatchObject({delivery_state:"queued",delivery_reason:"question_open"});
      expect(await f.answerSteps(w.task)).toEqual([]);
      expect(await f.state(w)).toMatchObject({state:"awaiting_answer"});
    });
    it.each(["foreign action","missing action","foreign context"])("Q3 queued question preserves chip validation for %s", async kind => {
      const w = await f.questionWorld(); const other = await f.user();
      const message = String((await f.post(w.user,w.conversation,randomUUID(),"queued task")).message_id);
      const before = await f.one(`select * from public.conversation_messages where id=$1`,[message]);
      const actions = kind === "foreign action" ? [await f.action(other)] : kind === "missing action" ? [randomUUID()] : [];
      const contexts = kind === "foreign context" ? [await f.context(other)] : [];
      expect(await f.route(w.user,message,actions,contexts)).toEqual({status:"not_found"});
      expect(await f.one(`select * from public.conversation_messages where id=$1`,[message])).toEqual(before);
      expect(await f.answerSteps(w.task)).toEqual([]);
    });
    it("Q3 queued question normalizes duplicate owned chips", async () => {
      const w = await f.questionWorld();
      const action = await f.action(w.user), context = await f.context(w.user);
      const message = String((await f.post(w.user,w.conversation,randomUUID(),"queued task")).message_id);
      expect(await f.route(w.user,message,[action,action],[context,context])).toMatchObject({status:"queued",reason:"question_open"});
      expect((await f.one(`select refs from public.conversation_messages where id=$1`,[message])).refs).toMatchObject({agent_turn:{action_ids:[action],context_ids:[context]}});
    });
    it("Q3 one allow_other input routes once and attributes the message", async () => {
      const w = await f.questionWorld(answerQuestionFixture({allow_other:true}));
      const message = String((await f.post(w.user,w.conversation,randomUUID(),"free answer")).message_id);
      expect(await f.route(w.user,message)).toMatchObject({status:"answered"});
      expect(await f.msg(message)).toMatchObject({delivery_state:"dispatched"});
      expect((await f.one(`select refs from public.conversation_messages where id=$1`,[message])).refs).toHaveProperty("answer_for");
      expect((await f.answerSteps(w.task))[0].args).toEqual({agent_task_id:w.task,provider_request_id:"request",answer_message_id:message});
      await f.route(w.user,message); expect(await f.answerSteps(w.task)).toHaveLength(1);
    });
    it("Q3 with no pending question uses ordinary turn dispatch", async () => {
      const w = await f.turnWorld();
      expect(await f.route(w.user,w.message)).toMatchObject({status:"started"});
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"dispatched"});
      expect(await f.q(`select 1 from public.execution_steps where user_id=$1 and intent_key like '%answer:%'`,[w.user])).toEqual([]);
    });
    it("Q3 expired and cancelled messages cannot answer an open question", async () => {
      for(const state of ["expired","cancelled"]) {
        const w = await f.questionWorld(answerQuestionFixture({allow_other:true}));
        const message = String((await f.post(w.user,w.conversation,randomUUID(),"old answer")).message_id);
        await f.updateRow("conversation_messages",message,{delivery_state:state});
        expect(await f.route(w.user,message)).toEqual({status:"already_dispatched"});
        expect(await f.answerSteps(w.task)).toEqual([]);
        expect(await f.state(w)).toMatchObject({state:"awaiting_answer"});
      }
    });
    it.each(["progress","message","accepted"])("Q5 delayed %s before the question cannot acknowledge its answer", async type => {
      const w = await f.eventWorld();
      await f.apply(w.user,f.event(w,"question",{seq:10,question:answerQuestionFixture(),text:"Question"}));
      const pending = (await f.state(w)).pending_question;
      const result = await f.answer(w.user,w.task);
      await f.updateRow("execution_steps",result.step_id!,{state:"calling",lease_owner:"answer-fixture"});
      expect(await f.apply(w.user,f.event(w,type,{seq:9,...(type === "message" ? {text:"Delayed reply"} : {})}))).toMatchObject({status:"late",applied:false});
      expect(await f.one(`select state from public.execution_steps where id=$1`,[result.step_id])).toEqual({state:"calling"});
      expect(await f.apply(w.user,f.event(w,"failed",{seq:11,payload:{reason:"agent_error"}}))).toMatchObject({applied:true,task_state:"awaiting_answer"});
      expect(await f.state(w)).toMatchObject({pending_question:pending});
    });
    it("Q5 accepted answer then agent failure closes task without restoring delivered question", async () => {
      const w = await f.questionWorld(); const result = await f.answer(w.user,w.task);
      await f.updateRow("execution_steps",result.step_id!,{state:"calling",lease_owner:"answer-fixture"});
      expect(await f.apply(w.user,f.event(w,"accepted"))).toMatchObject({applied:true});
      expect(await f.one(`select state from public.execution_steps where id=$1`,[result.step_id])).toEqual({state:"called"});
      expect(await f.apply(w.user,f.event(w,"failed",{payload:{reason:"agent_error"}}))).toMatchObject({applied:true,task_state:"failed"});
      expect(await f.one(`select pending_question,answered_question from public.agent_tasks where id=$1`,[w.task])).toEqual({pending_question:null,answered_question:null});
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"dispatched"});
    });
    it("Q5 prepared answer failures and acceptance stay retryable until leased", async () => {
      const w = await f.questionWorld(); const result = await f.answer(w.user,w.task);
      for(const type of ["accepted","failed"]) {
        expect(await f.apply(w.user,f.event(w,type,{payload:type === "failed" ? {reason:"agent_error"} : {}}))).toMatchObject({status:"step_not_calling",applied:false});
      }
      expect(await f.one(`select state from public.execution_steps where id=$1`,[result.step_id])).toEqual({state:"prepared"});
      expect(await f.state(w)).toMatchObject({state:"running",pending_question:null});
    });
    it("Q2 Stop closes question answer eligibility", async () => {
      const w = await f.questionWorld(); await f.stop(w.user,w.session);
      expect(await f.answer(w.user,w.task)).toEqual({status:"question_stale"});
      expect(await f.answerSteps(w.task)).toEqual([]);
    });
    it("Q5 retry after failed answer creates a new numbered step and preserves the failed delivery", async () => {
      const w = await f.questionWorld();
      const first = await f.answer(w.user,w.task);
      await f.updateRow("execution_steps",first.step_id!,{state:"calling",lease_owner:"answer-fixture"});
      expect(await f.apply(w.user,f.event(w,"failed",{payload:{reason:"agent_error"}}))).toMatchObject({applied:true});
      const retry = await f.answer(w.user,w.task,"request",{choice:"B"});
      expect(retry).toMatchObject({status:"answered"});
      const steps = await f.answerSteps(w.task);
      expect(steps).toHaveLength(2);
      expect(steps).toEqual(expect.arrayContaining([
        expect.objectContaining({id:first.step_id,state:"failed",intent_key:`answer:${w.task}:request:0`,args:expect.objectContaining({answers:{choice:"A"}})}),
        expect.objectContaining({id:retry.step_id,state:"prepared",intent_key:`answer:${w.task}:request:1`,args:expect.objectContaining({answers:{choice:"B"}})}),
      ]));
      expect(await f.answer(w.user,w.task)).toEqual({status:"duplicate",step_id:retry.step_id});
      expect(await f.q(`select text from public.conversation_messages where conversation_id=$1 and role='event'`,[w.conversation])).toEqual([{text:"B"}]);
      expect(await f.state(w)).toMatchObject({state:"running",pending_question:null});
      await f.updateRow("execution_steps",retry.step_id!,{state:"calling",lease_owner:"second-answer-fixture"});
      expect(await f.apply(w.user,f.event(w,"failed",{payload:{reason:"agent_error"}}))).toMatchObject({applied:true,task_state:"awaiting_answer"});
      const third = await f.answer(w.user,w.task);
      expect(third).toMatchObject({status:"answered"});
      const attempts = await f.answerSteps(w.task);
      expect(attempts).toHaveLength(3);
      expect(attempts).toEqual(expect.arrayContaining([
        expect.objectContaining({id:first.step_id,state:"failed",intent_key:`answer:${w.task}:request:0`}),
        expect.objectContaining({id:retry.step_id,state:"failed",intent_key:`answer:${w.task}:request:1`}),
        expect.objectContaining({id:third.step_id,state:"prepared",intent_key:`answer:${w.task}:request:2`}),
      ]));
      expect(await f.answer(w.user,w.task)).toEqual({status:"duplicate",step_id:third.step_id});
    });
    it("Q5 failed answer delivery restores the exact pending question", async () => {
      const w = await f.questionWorld(); const pending = (await f.state(w)).pending_question;
      const result = await f.answer(w.user,w.task);
      await f.updateRow("execution_steps",result.step_id!,{state:"calling",lease_owner:"answer-fixture"});
      expect(await f.apply(w.user,f.event(w,"failed",{payload:{reason:"agent_error"}}))).toMatchObject({applied:true});
      expect(await f.one(`select state,pending_question,answered_question from public.agent_tasks where id=$1`,[w.task])).toEqual({state:"awaiting_answer",pending_question:pending,answered_question:null});
      expect(await f.one(`select state from public.execution_steps where id=$1`,[result.step_id])).toEqual({state:"failed"});
    });
  });
  describe("review 2 regressions", () => {
    it.each(["stop", "done"])("7-1 N1/N1b Claude Code %s confirms an undelivered answer and releases the session", async operation => {
      for (const state of ["pending", "prepared"]) for (const unreachable of [false, true]) {
        const w = await f.questionWorld(answerQuestionFixture(), "agent:claude-code");
        const answer = await f.answer(w.user, w.task);
        if (state === "pending") await f.updateRow("execution_steps", answer.step_id!, { state });
        if (unreachable) await f.apply(w.user, f.event(w, "unreachable", { adapter: "agent:claude-code" }));
        if (operation === "stop") expect(await f.stop(w.user, w.session)).toEqual({ tasks: [{ agent_task_id: w.task, cancel: "confirmed" }] });
        else await f.done(w.user, w.action);
        expect(await f.one(`select state,pending_question,answered_question,abandoned_question from public.agent_tasks where id=$1`, [w.task]))
          .toEqual({ state: "cancelled", pending_question: null, answered_question: null, abandoned_question: [w.task, "request"] });
        expect(await f.one(`select state from public.execution_steps where id=$1`, [answer.step_id])).toEqual({ state: "skipped" });
        expect(await f.cancelSteps(w.user)).toEqual([]);
        expect((await f.events(w)).filter(e => (e.payload as { event_type?: string }).event_type === "question_denied").map(e => e.payload))
          .toEqual([{ event_type: "question_denied", agent_task_id: w.task, question_key: [w.task, "request"], decision: "deny" }]);
        const message = String((await f.post(w.user, w.conversation, randomUUID(), "Work on another issue")).message_id);
        expect(await f.route(w.user, message, [await f.action(w.user)])).toMatchObject({ status: "started" });
      }
    });
    it.each(["stop", "done"])("7-2 N5 %s cancels the undelivered free-text answer and retains its reference", async operation => {
      for (const adapter of ["agent:codex", "agent:claude-code"]) {
        const w = await f.questionWorld(answerQuestionFixture({ allow_other: true }), adapter);
        const message = String((await f.post(w.user, w.conversation, randomUUID(), "My answer")).message_id);
        const answer = await f.route(w.user, message);
        expect(answer.status).toBe("answered");
        if (operation === "stop") await f.stop(w.user, w.session);
        else await f.done(w.user, w.action);
        expect(await f.one(`select delivery_state,refs->'answer_for' as answer_for from public.conversation_messages where id=$1`, [message]))
          .toEqual({ delivery_state: "cancelled", answer_for: [w.task, "request"] });
        expect(await f.one(`select abandoned_question from public.agent_tasks where id=$1`, [w.task])).toEqual({ abandoned_question: [w.task, "request"] });
        expect(await f.one(`select state from public.execution_steps where id=$1`, [answer.step_id])).toEqual({ state: "skipped" });
      }
    });
    it.each(["lease owner", "lease expiry", "intent", "calling history", "calling"])("7-1/2 preserves answer delivery with %s evidence", async evidence => {
      for (const operation of ["stop", "done"]) for (const adapter of ["agent:codex", "agent:claude-code"]) {
        const w = await f.questionWorld(answerQuestionFixture({ allow_other: true }), adapter);
        const message = String((await f.post(w.user, w.conversation, randomUUID(), "My answer")).message_id);
        const answer = await f.route(w.user, message);
        expect(answer.status).toBe("answered");
        if (evidence === "lease owner") await f.updateRow("execution_steps", answer.step_id!, { lease_owner: "bridge" });
        if (evidence === "lease expiry") await f.updateRow("execution_steps", answer.step_id!, { lease_expires_at: "2099-01-01T00:00:00Z" });
        if (evidence === "intent") await f.q(`insert into public.execution_intents(user_id,step_id,intent_key) select user_id,id,intent_key from public.execution_steps where id=$1`, [answer.step_id]);
        if (evidence === "calling history" || evidence === "calling") {
          await f.updateRow("execution_steps", answer.step_id!, { state: "calling", lease_owner: "bridge" });
          if (evidence === "calling history") await f.updateRow("execution_steps", answer.step_id!, { state: "prepared", lease_owner: null });
        }
        if (operation === "stop") expect((await f.stop(w.user, w.session)).tasks[0].cancel).toBe("requested_only");
        else await f.done(w.user, w.action);
        expect(await f.one(`select state,step_id,answered_question is not null as answered,abandoned_question from public.agent_tasks where id=$1`, [w.task]))
          .toEqual({ state: "running", step_id: answer.step_id, answered: true, abandoned_question: null });
        expect(await f.one(`select state from public.execution_steps where id=$1`, [answer.step_id])).toEqual({ state: evidence === "calling" ? "calling" : "prepared" });
        expect(await f.msg(message)).toMatchObject({ delivery_state: "dispatched" });
        expect((await f.cancelSteps(w.user)).map(s => s.state)).toEqual(["prepared"]);
      }
    });
    it.each(["2020-01-01T00:00:00Z", "2099-01-01T00:00:00Z"])("7-3 P-K uses server ordering despite bridge observed_at=%s", async observed_at => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "accepted"));
      const before = String((await f.post(w.user, w.conversation, randomUUID(), "Instruction before question")).message_id);
      expect(await f.route(w.user, before)).toEqual({ status: "queued", reason: "session_busy" });
      await f.apply(w.user, f.event(w, "question", { observed_at, question: answerQuestionFixture({ allow_other: true }), text: "Question?" }));
      expect(await f.route(w.user, before)).toEqual({ status: "queued", reason: "question_open" });
      expect((await f.one(`select public.answer_agent_question($1,$2,'request',$3::jsonb,false,$4) as result`,
        [w.user, w.task, JSON.stringify({ choice: "Instruction before question" }), before])).result).toEqual({ status: "invalid_answer" });
      expect(await f.answerSteps(w.task)).toEqual([]);
      const after = String((await f.post(w.user, w.conversation, randomUUID(), "Answer after question")).message_id);
      expect(await f.route(w.user, after)).toMatchObject({ status: "answered" });
      expect(await f.msg(before)).toMatchObject({ delivery_state: "queued", delivery_reason: "question_open" });
    });
    it.each([{}, "task:request", [], ["task"], ["task", "request", "extra"], [null, "request"], ["task", null], ["task", 3], ["task", ""], ["task", "x".repeat(201)]])("7-4 rejects malformed abandoned question %#", async key => {
      const w = await f.questionWorld();
      const value = Array.isArray(key) && key[0] === "task" ? [w.task, ...key.slice(1)] : key;
      await expect(f.q(`update public.agent_tasks set abandoned_question=$2::jsonb where id=$1`, [w.task, JSON.stringify(value)])).rejects.toThrow(/check constraint/);
      expect(await f.one(`select abandoned_question from public.agent_tasks where id=$1`, [w.task])).toEqual({ abandoned_question: null });
    });
    it("7-4 accepts only this task's abandoned question key or SQL null", async () => {
      const w = await f.questionWorld();
      await expect(f.updateRow("agent_tasks", w.task, { abandoned_question: [randomUUID(), "request"] })).rejects.toThrow(/check constraint/);
      await f.updateRow("agent_tasks", w.task, { abandoned_question: [w.task, "request"] });
      expect(await f.one(`select abandoned_question from public.agent_tasks where id=$1`, [w.task])).toEqual({ abandoned_question: [w.task, "request"] });
      await f.updateRow("agent_tasks", w.task, { abandoned_question: null });
      await expect(f.q(`update public.agent_tasks set abandoned_question='null'::jsonb where id=$1`, [w.task])).rejects.toThrow(/check constraint/);
    });
  });
  describe("review 3 regressions", () => {
    for (const operation of ["stop", "done"]) {
      it.each(["turn_completed", "failed", "progress", "cancelled"])(`8-1 N9/N9b ${operation} accepts %s after abandoning an unleased Codex answer`, async type => {
        for (const acceptedAnswer of [false, true]) {
          const w = await f.questionWorld(answerQuestionFixture({ allow_other: true }));
          let calledStep = w.step;
          const request = acceptedAnswer ? "second-request" : "request";
          if (acceptedAnswer) {
            const first = await f.answer(w.user, w.task);
            calledStep = first.step_id!;
            await f.updateRow("execution_steps", calledStep, { state: "calling", lease_owner: "bridge" });
            expect(await f.apply(w.user, f.event(w, "question", {
              question: answerQuestionFixture({ allow_other: true }, { provider_request_id: request }), text: "Next question",
            }))).toMatchObject({ applied: true, task_state: "awaiting_answer" });
          }
          const answerMessage = acceptedAnswer
            ? String((await f.post(w.user, w.conversation, randomUUID(), "My answer")).message_id) : null;
          const answer = answerMessage ? await f.route(w.user, answerMessage) : await f.answer(w.user, w.task, request);
          expect(answer.status).toBe("answered");
          if (operation === "stop") expect((await f.stop(w.user, w.session)).tasks)
            .toEqual([{ agent_task_id: w.task, cancel: "requested_only", processes: "may_continue" }]);
          else await f.done(w.user, w.action);
          expect(await f.apply(w.user, f.event(w, type, { seq: 40, payload: type === "failed" ? { reason: "agent_error" } : {} })))
            .toEqual({ status: type === "progress" ? "ignored" : "applied", applied: type !== "progress",
              task_state: type === "turn_completed" ? "idle" : type === "progress" ? "running" : type });
          expect(await f.one(`select step_id,answered_question,abandoned_question from public.agent_tasks where id=$1`, [w.task]))
            .toEqual({ step_id: calledStep, answered_question: null, abandoned_question: [w.task, request] });
          expect(await f.one(`select state from public.execution_steps where id=$1`, [answer.step_id])).toEqual({ state: "skipped" });
          expect(await f.one(`select state from public.execution_steps where id=$1`, [calledStep])).toEqual({ state: "called" });
          if (answerMessage) expect(await f.one(`select delivery_state,refs->'answer_for' as answer_for from public.conversation_messages where id=$1`, [answerMessage]))
            .toEqual({ delivery_state: "cancelled", answer_for: [w.task, request] });
          const next = String((await f.post(w.user, w.conversation, randomUUID(), "Work on another issue")).message_id);
          const action = await f.action(w.user);
          if (type === "progress") {
            expect(await f.route(w.user, next, [action])).toEqual({ status: "queued", reason: "session_busy" });
            expect((await f.cancelSteps(w.user)).map(s => s.state)).toEqual(["prepared"]);
            expect(await f.apply(w.user, f.event(w, "cancelled", { seq: 41 }))).toMatchObject({ applied: true, task_state: "cancelled" });
          }
          expect((await f.cancelSteps(w.user)).map(s => s.state)).toEqual(["skipped"]);
          expect(await f.route(w.user, next, [action])).toMatchObject({ status: "started" });
        }
      });
    }
    it.each(["idle", "completed", "failed", "cancelled"])("8-1 terminal %s abandons only the undelivered answer and restores the last called step", async state => {
      const w = await f.questionWorld();
      const answer = await f.answer(w.user, w.task);
      if (state === "cancelled") expect(await f.apply(w.user, f.event(w, "cancelled"))).toMatchObject({ applied: true, task_state: state });
      else await f.updateRow("agent_tasks", w.task, { state });
      expect(await f.one(`select state,step_id,answered_question,abandoned_question from public.agent_tasks where id=$1`, [w.task]))
        .toEqual({ state, step_id: w.step, answered_question: null, abandoned_question: [w.task, "request"] });
      expect(await f.one(`select state from public.execution_steps where id=$1`, [answer.step_id])).toEqual({ state: "skipped" });
      const next = String((await f.post(w.user, w.conversation, randomUUID(), "Next turn")).message_id);
      expect(await f.route(w.user, next, [await f.action(w.user)])).toMatchObject({ status: "started" });
    });
    it.each(["lease owner", "lease expiry", "intent", "calling history", "calling"])("8-1 terminal cleanup preserves answer reference with %s evidence", async evidence => {
      const w = await f.questionWorld();
      const answer = await f.answer(w.user, w.task);
      if (evidence === "lease owner") await f.updateRow("execution_steps", answer.step_id!, { lease_owner: "bridge" });
      if (evidence === "lease expiry") await f.updateRow("execution_steps", answer.step_id!, { lease_expires_at: "2099-01-01T00:00:00Z" });
      if (evidence === "intent") await f.q(`insert into public.execution_intents(user_id,step_id,intent_key) select user_id,id,intent_key from public.execution_steps where id=$1`, [answer.step_id]);
      if (evidence === "calling history" || evidence === "calling") {
        await f.updateRow("execution_steps", answer.step_id!, { state: "calling", lease_owner: "bridge" });
        if (evidence === "calling history") await f.updateRow("execution_steps", answer.step_id!, { state: "prepared", lease_owner: null });
      }
      const before = await f.one(`select step_id,answered_question,abandoned_question from public.agent_tasks where id=$1`, [w.task]);
      const step = await f.one(`select * from public.execution_steps where id=$1`, [answer.step_id]);
      await f.updateRow("agent_tasks", w.task, { state: "cancelled" });
      expect(await f.one(`select step_id,answered_question,abandoned_question from public.agent_tasks where id=$1`, [w.task])).toEqual(before);
      expect(await f.one(`select * from public.execution_steps where id=$1`, [answer.step_id])).toEqual(step);
    });
  });
  describe("independent review regressions", () => {
    it.each([["stop",false],["stop",true],["done",false],["done",true]] as const)("6-7 late questions cannot reopen a Codex card after %s (unreachable=%s)", async (operation,unreachable) => {
      const w = await f.questionWorld();
      if (unreachable) await f.apply(w.user,f.event(w,"unreachable"));
      if (operation === "stop") await f.stop(w.user,w.session);
      else await f.done(w.user,w.action);
      for (const request of ["request","next-request"]) {
        const result = await f.apply(w.user,f.event(w,"question",{
          seq:20,question:answerQuestionFixture({}, {provider_request_id:request}),text:"Late question",
        }));
        expect(result).toMatchObject({status:"late",applied:false});
        expect(await f.one(`select pending_question,abandoned_question from public.agent_tasks where id=$1`,[w.task]))
          .toEqual({pending_question:null,abandoned_question:[w.task,"request"]});
      }
      expect(await f.q(`select 1 from public.conversation_messages where conversation_id=$1 and text='Late question'`,[w.conversation])).toEqual([]);
      expect(await f.apply(w.user,f.event(w,"cancelled",{seq:21}))).toMatchObject({applied:true,task_state:"cancelled"});
    });
    it.each(["done", "delete"])("P-A/A2 %s uses its own gate without a user Stop decision", async operation => {
      const w = await f.eventWorld();
      if (operation === "done") await f.done(w.user,w.action);
      else await f.q(`delete from public.agent_sessions where id=$1`,[w.session]);
      expect(await f.one(`select state,stopped_at from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped",stopped_at:null});
      expect(await f.q(`select gate from public.execution_events where run_id=$1 and type='run' and to_state='stopped'`,[w.run])).toEqual([{gate:operation === "done" ? "action_closed" : "session_deleted"}]);
      expect(await f.q(`select 1 from public.inbox_events where user_id=$1 and dedup_key like 'run_stop:%'`,[w.user])).toEqual([]);
    });
    it.each(["running", "question"])("P-B/B2 account deletion removes %s conversation runs", async kind => {
      const w = kind === "question" ? await f.questionWorld(answerQuestionFixture({allow_other:true}),"agent:claude-code") : await f.eventWorld();
      await f.post(w.user,w.conversation,randomUUID(),"queued");
      await f.q(`delete from auth.users where id=$1`,[w.user]);
      for (const table of ["execution_runs","execution_steps","agent_tasks","conversation_messages"])
        expect(await f.q(`select 1 from public.${table} where user_id=$1`,[w.user])).toEqual([]);
    });
    it("P-C wrong_target precedes delivery-state checks", async () => {
      const user = await f.user(), conversation = await f.insertRow("conversations",{user_id:user});
      const message = String((await f.post(user,conversation,randomUUID(),"hello")).message_id);
      const before = await f.msg(message);
      expect(await f.route(user,message)).toEqual({status:"wrong_target"});
      expect(await f.msg(message)).toEqual(before);
    });
    it.each(["another conversation", "before question"])("P-D/K free text from %s remains queued", async kind => {
      const w = await f.eventWorld();
      await f.apply(w.user,f.event(w,"accepted"));
      const conversation = kind === "another conversation" ? await f.agentConversation(w.user,w.connection,w.session) : w.conversation;
      if (kind === "another conversation") await f.apply(w.user,f.event(w,"question",{question:answerQuestionFixture({allow_other:true}),text:"Question?"}));
      const message = String((await f.post(w.user,conversation,randomUUID(),"unrelated instruction")).message_id);
      if (kind === "before question") await f.apply(w.user,f.event(w,"question",{question:answerQuestionFixture({allow_other:true}),text:"Question?"}));
      expect(await f.route(w.user,message)).toEqual({status:"queued",reason:"question_open"});
      expect(await f.msg(message)).toMatchObject({delivery_state:"queued",delivery_reason:"question_open"});
      expect(await f.answerSteps(w.task)).toEqual([]);
      expect(await f.state(w)).toMatchObject({state:"awaiting_answer"});
    });
    it("P-E prepared answer failure stays unacknowledged and unreachable preserves the delivery", async () => {
      const w = await f.questionWorld(); const answer = await f.answer(w.user,w.task);
      expect(await f.apply(w.user,f.event(w,"failed",{payload:{reason:"agent_error"}}))).toMatchObject({status:"step_not_calling",applied:false});
      expect(await f.apply(w.user,f.event(w,"unreachable"))).toMatchObject({applied:true,task_state:"unreachable"});
      expect(await f.one(`select state from public.execution_steps where id=$1`,[answer.step_id])).toEqual({state:"prepared"});
      expect(await f.state(w)).toMatchObject({state:"unreachable",last_live_state:"running",pending_question:null});
    });
    it("P-F Stop skips a prepared answer and confirmed cancellation clears the remaining cancel", async () => {
      const w = await f.questionWorld(); const answer = await f.answer(w.user,w.task);
      await f.stop(w.user,w.session);
      expect(await f.one(`select state from public.execution_steps where id=$1`,[answer.step_id])).toEqual({state:"skipped"});
      expect(await f.apply(w.user,f.event(w,"cancelled"))).toMatchObject({applied:true,task_state:"cancelled"});
      expect(await f.q(`select 1 from public.execution_steps where run_id=$1 and state='prepared'`,[w.run])).toEqual([]);
      expect((await f.cancelSteps(w.user)).map(s=>s.state)).toEqual(["skipped"]);
    });
    it.each(["turn_completed", "failed"])("6-1 terminal %s clears the prepared cancel ledger", async type => {
      const w = await f.eventWorld(); await f.apply(w.user,f.event(w,"accepted"));
      await f.stop(w.user,w.session);
      expect((await f.cancelSteps(w.user)).map(s=>s.state)).toEqual(["prepared"]);
      expect(await f.apply(w.user,f.event(w,type,{payload:type === "failed" ? {reason:"agent_error"} : {}}))).toMatchObject({applied:true,task_state:type === "failed" ? "failed" : "idle"});
      expect((await f.cancelSteps(w.user)).map(s=>s.state)).toEqual(["skipped"]);
    });
    it.each(["agent:codex", "agent:claude-code"])("P-G/I Stop discards %s unreachable questions", async adapter => {
      const w = await f.questionWorld(answerQuestionFixture(),adapter);
      await f.apply(w.user,f.event(w,"unreachable",{adapter}));
      expect((await f.stop(w.user,w.session)).tasks).toEqual([adapter === "agent:claude-code" ? {agent_task_id:w.task,cancel:"confirmed"} : {agent_task_id:w.task,cancel:"requested_only",processes:"may_continue"}]);
      expect(await f.one(`select pending_question,abandoned_question from public.agent_tasks where id=$1`,[w.task])).toEqual({pending_question:null,abandoned_question:[w.task,"request"]});
      expect(await f.answer(w.user,w.task)).toEqual({status:"question_stale"});
    });
    it("P-I Done discards Claude Code question and confirms cancellation", async () => {
      const w = await f.questionWorld(answerQuestionFixture(),"agent:claude-code");
      await f.done(w.user,w.action);
      expect(await f.state(w)).toMatchObject({state:"cancelled",pending_question:null});
      expect(await f.cancelSteps(w.user)).toEqual([]);
      expect((await f.events(w)).map(e=>e.payload)).toContainEqual(expect.objectContaining({event_type:"question_denied",question_key:[w.task,"request"],decision:"deny"}));
    });
    it.each([
      [answerQuestionFixture({multi_select:true}), {choice:[]}],
      [answerQuestionFixture({allow_other:true}), {choice:" \t\n "}],
    ])("P-J empty selection or whitespace Other is write-free %#", async (question,answers) => {
      const w = await f.questionWorld(question); const before = await f.state(w);
      expect(await f.answer(w.user,w.task,"request",answers)).toEqual({status:"invalid_answer"});
      expect(await f.state(w)).toEqual(before); expect(await f.answerSteps(w.task)).toEqual([]);
    });
    it.each(["stop", "done"])("P-L/M/N %s confirms an unleased pending/prepared turn and releases the session", async operation => {
      for (const state of ["pending","prepared"]) for (const unreachable of [false,true]) {
        const w = await f.eventWorld(false);
        if (state === "pending") await f.updateRow("execution_steps",w.step,{state:"pending"});
        if (unreachable) await f.apply(w.user,f.event(w,"unreachable"));
        if (operation === "stop") expect(await f.stop(w.user,w.session)).toEqual({tasks:[{agent_task_id:w.task,cancel:"confirmed"}]});
        else await f.done(w.user,w.action);
        expect(await f.state(w)).toMatchObject({state:"cancelled",pending_question:null});
        expect(await f.msg(w.message)).toMatchObject({delivery_state:"cancelled"});
        expect(await f.cancelSteps(w.user)).toEqual([]);
        const step = await f.one(`select state,version from public.execution_steps where id=$1`,[w.step]);
        expect(step.state).toBe("skipped");
        expect((await f.one(`select public.begin_call($1,'review-worker',$2) as result`,[w.step,step.version])).result).toEqual({gate:"stale"});
        const message = String((await f.post(w.user,w.conversation,randomUUID(),"next turn")).message_id);
        expect(await f.route(w.user,message,[await f.action(w.user)])).toMatchObject({status:"started"});
      }
    });
    it("6-6 external Stop preserves queued and not_sent messages byte-for-byte", async () => {
      const w = await f.eventWorld();
      const queued = String((await f.post(w.user,w.conversation,randomUUID(),"queued")).message_id);
      const notSent = String((await f.post(w.user,w.conversation,randomUUID(),"not sent")).message_id);
      await f.updateRow("conversation_messages",notSent,{delivery_state:"not_sent",delivery_reason:"not_connected"});
      await f.updateRow("agent_sessions",w.session,{status:"external"});
      const before = await Promise.all([f.msg(queued),f.msg(notSent)]);
      expect(await f.stop(w.user,w.session)).toEqual({tasks:[]});
      expect(await Promise.all([f.msg(queued),f.msg(notSent)])).toEqual(before);
      expect(await f.cancelSteps(w.user)).toEqual([]);
      expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped"});
    });
    it.each(["allow", "deny"])("6-8 approval %s uses the public event label", async choice => {
      const w = await f.questionWorld(answerQuestionFixture({}, {kind:"approval"}));
      expect(await f.answer(w.user,w.task,"request",{choice})).toMatchObject({status:"answered"});
      expect(await f.q(`select text from public.conversation_messages where conversation_id=$1 and role='event'`,[w.conversation])).toEqual([{text:choice === "allow" ? "Allowed" : "Denied"}]);
    });
    it.each([
      ["external", "queued", "session_external"],
      ["closed", "not_sent", "session_closed"],
      ["unreachable", "queued", "session_busy"],
      ["inactive connection", "not_sent", "not_connected"],
    ])("6-8 route respects %s instead of answering", async (guard,status,reason) => {
      const w = await f.questionWorld(answerQuestionFixture({allow_other:true}));
      const message = String((await f.post(w.user,w.conversation,randomUUID(),"answer text")).message_id);
      if (guard === "inactive connection") await f.updateRow("agent_connections",w.connection,{status:"error"});
      else await f.updateRow("agent_sessions",w.session,{status:guard});
      const before = await f.state(w);
      expect(await f.route(w.user,message)).toEqual({status,reason});
      expect(await f.msg(message)).toMatchObject({delivery_state:status,delivery_reason:reason});
      expect(await f.state(w)).toEqual(before); expect(await f.answerSteps(w.task)).toEqual([]);
    });
    it.each(["run stopped", "external", "closed", "inactive connection"])("6-8 answer rejects %s without a delivery", async guard => {
      const w = await f.questionWorld();
      if (guard === "run stopped") await f.q(`select public.stop_run($1,$2)`,[w.user,w.run]);
      else if (guard === "inactive connection") await f.updateRow("agent_connections",w.connection,{status:"error"});
      else await f.updateRow("agent_sessions",w.session,{status:guard});
      const before = await f.state(w);
      expect(await f.answer(w.user,w.task)).toEqual({status:"question_stale"});
      expect(await f.state(w)).toEqual(before); expect(await f.answerSteps(w.task)).toEqual([]);
    });
  });
  describe("Stop and Done", () => {
    it("S1 session Stop cancels queues across conversations and prepares one cancel", async () => {
      const w = await f.eventWorld(); await f.apply(w.user,f.event(w,"accepted"));
      const other = await f.agentConversation(w.user,w.connection,w.session);
      const run = await f.open(w.user,w.session,await f.action(w.user));
      const messages = [String((await f.post(w.user,w.conversation,randomUUID(),"queued")).message_id),String((await f.post(w.user,other,randomUUID(),"not sent")).message_id)];
      await f.updateRow("conversation_messages",messages[1],{delivery_state:"not_sent",delivery_reason:"not_connected"});
      expect(await f.stop(w.user,w.session)).toEqual({tasks:[{agent_task_id:w.task,cancel:"requested_only",processes:"may_continue"}]});
      expect(await f.one(`select cancel_requested_at is not null as requested from public.agent_tasks where id=$1`,[w.task])).toEqual({requested:true});
      for(const id of [w.run,run]) expect(await f.one(`select state from public.execution_runs where id=$1`,[id])).toEqual({state:"stopped"});
      for(const id of messages) expect(await f.msg(id)).toMatchObject({delivery_state:"cancelled"});
      for(const id of [w.conversation,other]) expect((await f.messages(id)).some(m=>m.role === "event")).toBe(true);
      const steps = await f.cancelSteps(w.user); expect(steps).toHaveLength(1);
      expect(steps[0]).toMatchObject({state:"prepared",body:"",needs_approval:false});
      expect(String(steps[0].intent_key)).toContain(`cancel:${w.task}`);
      expect(await f.one(`select props from public.metric_events where user_id=$1 and type='stop_requested'`,[w.user])).toEqual({props:{surface:"assistant"}});
      await f.stop(w.user,w.session); expect(await f.cancelSteps(w.user)).toHaveLength(1);
    });
    it.each(["agent:claude-code","agent:codex"])("S1 pending %s preserves adapter cancellation semantics", async adapter => {
      const w = await f.questionWorld(answerQuestionFixture(),adapter);
      const result = await f.stop(w.user,w.session,"session_panel",adapter==="agent:codex"?"turn":"turn_and_processes");
      expect(result.tasks[0]).toMatchObject({agent_task_id:w.task,cancel:adapter==="agent:claude-code"?"confirmed":"requested_only"});
      if(adapter==="agent:claude-code") {
        expect(await f.state(w)).toMatchObject({state:"cancelled",pending_question:null});
        expect(await f.cancelSteps(w.user)).toHaveLength(0);
        const events = await f.events(w);
        expect(events.map(e=>e.payload)).toContainEqual(expect.objectContaining({event_type:"question_denied",decision:"deny",question_key:[w.task,"request"]}));
        expect(JSON.stringify(events)).not.toContain("Private question");
      } else expect(await f.cancelSteps(w.user)).toHaveLength(1);
    });
    it("S1 Stop still prepares cancellation for an active task on an already stopped run", async () => {
      const w = await f.eventWorld(); await f.apply(w.user,f.event(w,"accepted"));
      await f.q(`select public.stop_run($1,$2)`,[w.user,w.run]);
      expect(await f.stop(w.user,w.session)).toEqual({tasks:[{agent_task_id:w.task,cancel:"requested_only",processes:"may_continue"}]});
      const steps = await f.cancelSteps(w.user); expect(steps).toHaveLength(1);
      expect(steps[0]).toMatchObject({state:"prepared",intent_key:`cancel:${w.task}`,needs_approval:false});
      expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped"});
    });
    it("S2 external Stop closes run with zero cancellation", async () => {
      const w = await f.eventWorld(); await f.updateRow("agent_sessions",w.session,{status:"external"});
      expect(await f.stop(w.user,w.session)).toEqual({tasks:[]});
      expect(await f.cancelSteps(w.user)).toEqual([]);
      expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped"});
      expect(await f.one(`select cancel_requested_at from public.agent_tasks where id=$1`,[w.task])).toEqual({cancel_requested_at:null});
    });
    it.each(["done","dropped"] as const)("D1 user Claim %s stops its run and cancels the live turn without review", async status => {
      const w = await f.eventWorld(); await f.done(w.user,w.action,status);
      expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped"});
      expect(await f.cancelSteps(w.user)).toHaveLength(1);
      expect(await f.q(`select kind from public.execution_steps where run_id=$1 and kind not in ('agent_message','agent_cancel')`,[w.run])).toEqual([]);
      expect(await f.q(`select 1 from public.claims where action_id=$1 and origin='user' and field='status' and value=$2`,[w.action,status])).toHaveLength(1);
    });
    it("D2 Done A preserves running B in the same session; idle A gets no cancel", async () => {
      const w = await f.eventWorld(); await f.apply(w.user,f.event(w,"turn_completed"));
      const action = await f.action(w.user), message = String((await f.post(w.user,w.conversation,randomUUID(),"B")).message_id);
      const b = await f.start(w.user,message,[action]); expect(b.status).toBe("started");
      await f.done(w.user,w.action);
      expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped"});
      expect(await f.one(`select state from public.execution_runs where id=$1`,[b.run_id])).toEqual({state:"running"});
      expect(await f.one(`select state,cancel_requested_at from public.agent_tasks where id=$1`,[b.agent_task_id])).toEqual({state:"dispatched",cancel_requested_at:null});
      expect(await f.cancelSteps(w.user)).toEqual([]);
    });
    it("D1 source claims, other fields and open projections do not cancel", async () => {
      for (const kind of ["source", "field", "open"]) {
        const w = await f.eventWorld();
        const row = await f.one(`select * from public.actions where id=$1`,[w.action]);
        const source = kind === "source" ? await f.insertRow("sources",{user_id:w.user,kind:"note",raw_text:"source",occurred_at:new Date().toISOString()}) : null;
        const claim = {...claimToRow(userClaims([{field:kind === "field" ? "scope" : "status",value:"done"}],new Date(),randomUUID)[0],w.user,w.action,{sourceId:source,quote:source ? "source" : null}),origin:kind === "source" ? "source" : "user"};
        expect((await f.one(`select public.write_action($1,$2,$3,$4::jsonb,$5::jsonb) as written`,[w.user,w.action,row.version,JSON.stringify({...row,status:kind === "open" ? "open" : "done"}),JSON.stringify([claim])])).written).toBe(true);
        expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"running"});
        expect(await f.cancelSteps(w.user)).toEqual([]);
      }
    });
    it("C1 session deletion stops open runs before clearing session identity", async () => {
      const w = await f.eventWorld();
      await f.q(`delete from public.agent_sessions where id=$1`,[w.session]);
      expect(await f.one(`select state,agent_session_id from public.execution_runs where id=$1`,[w.run])).toEqual({state:"stopped",agent_session_id:null});
    });
    it("P1 foreign callers cannot answer, route or Stop owned work", async () => {
      const w = await f.questionWorld(), other = await f.user(); const before = await f.state(w);
      expect(await f.answer(other,w.task)).toEqual({status:"not_found"});
      expect(await f.route(other,w.message)).toEqual({status:"not_found"});
      await f.stop(other,w.session);
      expect(await f.state(w)).toEqual(before); expect(await f.cancelSteps(w.user)).toEqual([]); expect(await f.answerSteps(w.task)).toEqual([]);
      await expect(f.stop(w.user,w.session,"invalid")).rejects.toThrow();
      await expect(f.stop(w.user,w.session,"assistant","invalid")).rejects.toThrow();
      expect(await f.one(`select state from public.execution_runs where id=$1`,[w.run])).toEqual({state:"running"});
    });
    it("P1 new RPCs are invoker with empty search_path and service_role-only execute", async () => {
      const names = ["answer_agent_question","route_agent_message","stop_agent_session","request_agent_task_cancel","stop_agent_runs_on_user_claim","stop_agent_runs_before_session_delete","skip_terminal_agent_task_steps","execution_steps_replan","purge_expired_execution_text","append_step","prepare_step","apply_agent_event"];
      const rows = await f.q(`select p.proname,p.prosecdef,p.proconfig,has_function_privilege('anon',p.oid,'execute') as anon,has_function_privilege('authenticated',p.oid,'execute') as app,has_function_privilege('service_role',p.oid,'execute') as server from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any($1)`,[names]);
      expect(rows).toHaveLength(names.length);
      for(const row of rows) expect(row).toMatchObject({prosecdef:false,proconfig:['search_path=""'],anon:false,app:false,server:true});
    });
  });
}
