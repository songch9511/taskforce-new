import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { agentTurnFixtures } from "./agent-turn-start.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";


export function questionFixture(overrides: Record<string, unknown> = {}) {
  return { provider_request_id: "request", kind: "input", structured: true, questions: [{ id: "choice", header: "Private header", text: "Private question", options: [{ label: "Private option", description: "Private description" }], multi_select: true, allow_other: true, secret: false }], ...overrides };
}
function malformedQuestions() {
  const q = questionFixture(), item = q.questions[0];
  return [
    {...q, provider_request_id:""}, {...q, provider_request_id:"x".repeat(201)},
    ...[["id",201],["header",201],["text",4001]].map(([key,n])=>({...q,questions:[{...item,[key]:"x".repeat(Number(n))}]})),
    ...[["label",501],["description",1001]].map(([key,n])=>({...q,questions:[{...item,options:[{label:"x",description:"x",[key]:"x".repeat(Number(n))}]}]})),
    {...q,questions:[item,item]}, {...q,questions:[{...item,options:Array(11).fill(item.options[0])}]},
    {...q,questions:Array.from({length:4},(_,i)=>({...item,id:String(i),text:"가".repeat(4000)}))},
    {...q, questions: []}, {...q, questions: Array(5).fill(item)}, {...q, questions: {}},
    {...q, structured: "true"}, {...q, kind: "other"}, {...q, provider_request_id: null}, {...q, extra: true},
    ...["id", "header", "text", "options", "multi_select", "allow_other", "secret"].map(key => ({...q, questions: [{...item, [key]: null}]})),
    {...q, questions: [{...item, extra: true}]}, {...q, questions: [{...item, options: [{label: "x"}]}]},
    {...q, questions: [{...item, options: [{label: 1, description: "x"}]}]},
    {...q, questions: [{...item, options: [{label: "x", description: "x", extra: true}]}]},
  ];
}

export const D1C2_MIGRATION = "20261116000000_agent_events.sql";
export function agentEventFixtures(db: () => ConversationAgentDb) {
  const base = agentTurnFixtures(db);
  return {
    ...base,
    async eventWorld(calling = true) {
      const w = await base.turnWorld();
      const r = await base.start(w.user, w.message);
      expect(r.status).toBe("started");
      const session = String((await base.one(`select agent_session_id from public.agent_tasks where id=$1`, [r.agent_task_id])).agent_session_id);
      if (calling) await base.updateRow("execution_steps", r.step_id!, { state: "calling", lease_owner: "event-fixture" });
      return { ...w, session, task: r.agent_task_id!, run: r.run_id!, step: r.step_id!, action: r.action_id!, turn: r.turn_seq! };
    },
    event(w: {session: string; task: string; turn: number}, type: string, overrides: Record<string, unknown> = {}) {
      return { adapter: "agent:codex", session_ref: { agent_session_id: w.session }, agent_task_id: w.task, event_id: randomUUID(), turn_seq: w.turn, type, payload: {}, observed_at: "2026-10-13T12:00:00Z", ...overrides };
    },
    async apply(user: string, event: Record<string, unknown>) {
      return (await base.one(`select public.apply_agent_event($1,$2::jsonb) as result`, [user, JSON.stringify(event)])).result as {status: string; applied: boolean; task_state?: string};
    },
    state(w: {task: string}) { return base.one(`select state,pending_question,last_live_state,last_event_seq::int as last_event_seq from public.agent_tasks where id=$1`, [w.task]); },
    events(w: {run: string}) { return base.q(`select external_event_id,turn_seq,payload from public.execution_events where run_id=$1 and type='agent' order by id`, [w.run]); },
  };
}

export function agentEventTests(db: () => ConversationAgentDb) {
  const f = agentEventFixtures(db);
  describe("agent event application", () => {
    it("E1 duplicate is write-free; reversed seq and foreign turn are recorded without applying", async () => {
      const w = await f.eventWorld();
      const e = f.event(w, "accepted", { seq: 5 });
      expect(await f.apply(w.user, e)).toMatchObject({ status: "applied", applied: true });
      const before = await f.state(w);
      expect(await f.apply(w.user, e)).toMatchObject({ status: "duplicate", applied: false });
      expect(await f.state(w)).toEqual(before);
      for (const extra of [{ seq: 4 }, { seq: 5 }, { seq: 9, turn_seq: w.turn + 1 }]) {
        expect(await f.apply(w.user, f.event(w, "progress", extra))).toMatchObject({ status: "late", applied: false });
        expect(await f.state(w)).toEqual(before);
      }
      expect(await f.events(w)).toHaveLength(4);
    });
    it("E2 foreign user, session and adapter cannot write events", async () => {
      const w = await f.eventWorld();
      const other = await f.user();
      const session = await f.session(w.user, w.connection);
      for (const [user, extra] of [[other, {}], [w.user, { session_ref: { agent_session_id: session } }], [w.user, { adapter: "agent:claude-code" }]] as const) {
        expect(await f.apply(user, f.event(w, "accepted", extra))).toMatchObject({ status: "not_found", applied: false });
      }
      expect(await f.events(w)).toEqual([]);
      expect(await f.state(w)).toMatchObject({ state: "dispatched" });
    });
    it.each(["step", "run"])("E2 rejects corrupt cross-run %s attribution", async kind => {
      const w = await f.eventWorld();
      const session = await f.session(w.user, w.connection);
      const run = await f.agentRun(w.user, await f.action(w.user), { agent_session_id: session });
      if (kind === "step") await f.updateRow("agent_tasks", w.task, { step_id: await f.step(w.user, run) });
      else await f.updateRow("agent_tasks", w.task, { run_id: run });
      expect(await f.apply(w.user, f.event(w, "accepted"))).toMatchObject({ applied: false });
      expect(await f.events(w)).toEqual([]);
      expect(await f.state(w)).toMatchObject({ state: "dispatched" });
    });
    it("E3 acceptance settles calling step without closing run; progress advances running", async () => {
      const w = await f.eventWorld();
      const action = await f.one(`select * from public.actions where id=$1`, [w.action]);
      expect(await f.apply(w.user, f.event(w, "accepted"))).toMatchObject({ status: "applied", task_state: "accepted" });
      expect(await f.one(`select state,lease_owner from public.execution_steps where id=$1`, [w.step])).toEqual({ state: "called", lease_owner: null });
      expect(await f.one(`select state from public.execution_runs where id=$1`, [w.run])).toEqual({ state: "running" });
      expect(await f.apply(w.user, f.event(w, "progress"))).toMatchObject({ task_state: "running" });
      expect(await f.one(`select * from public.actions where id=$1`, [w.action])).toEqual(action);
    });
    it("E3 prepared acceptance remains retryable after a calling lease", async () => {
      const w = await f.eventWorld(false); const e = f.event(w, "accepted");
      expect(await f.apply(w.user, e)).toMatchObject({ status: "step_not_calling", applied: false });
      expect(await f.state(w)).toMatchObject({ state: "dispatched" });
      expect(await f.events(w)).toEqual([]);
      await f.updateRow("execution_steps", w.step, { state: "calling", lease_owner: "event-fixture" });
      expect(await f.apply(w.user, e)).toMatchObject({ status: "applied", applied: true });
    });
    it("E4 reply is stored only in originating conversation, truncated at UTF-8 boundary", async () => {
      const w = await f.eventWorld(); const other = await f.agentConversation(w.user, w.connection, w.session);
      const e = f.event(w, "message", { text: "😀".repeat(9000) });
      expect(await f.apply(w.user, e)).toMatchObject({ applied: true });
      const rows = await f.q(`select conversation_id,text,content from public.conversation_messages where conversation_id=$1 and role='assistant'`, [w.conversation]);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ conversation_id: w.conversation, text: "😀".repeat(8192), content: { kind: "reply", truncated: true } });
      expect(await f.messages(other)).toEqual([]);
      expect((await f.events(w))[0].payload).not.toHaveProperty("text");
      expect(await f.state(w)).toMatchObject({ state: "accepted" });
    });
    it.each([{ text: "private" }, { body: "private" }, { unexpected: 1 }])("E4 SQL rejects unallowed message payload %j atomically", async payload => {
      const w = await f.eventWorld();
      await expect(f.apply(w.user, f.event(w, "message", { text: "reply", payload }))).rejects.toThrow(/apply_agent_event:/);
      expect(await f.events(w)).toEqual([]);
      expect(await f.messages(w.conversation)).toHaveLength(1);
    });
    it.each(["input", "approval"])("E4/E5 question %s stores separate structure and only metadata in events", async kind => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "accepted"));
      await f.apply(w.user, f.event(w, "progress"));
      const other = await f.agentConversation(w.user, w.connection, w.session);
      const question = questionFixture({ kind });
      const event = f.event(w, "question", { question, text: "😀".repeat(9000) });
      expect(await f.apply(w.user, event)).toMatchObject({ applied: true, task_state: "awaiting_answer" });
      const pending = (await f.state(w)).pending_question;
      expect(pending).toEqual({ ...question, question_key: [w.task, question.provider_request_id], asked_at: event.observed_at });
      const rows = await f.q(`select text,content from public.conversation_messages where conversation_id=$1 and role='assistant'`, [w.conversation]);
      expect(rows).toEqual([{ text: "😀".repeat(8192), content: { author: { adapter: "agent:codex", kind: "agent" }, turn_seq: w.turn, kind: "question", truncated: true } }]);
      expect(await f.messages(other)).toEqual([]);
      const ledger = (await f.events(w)).find(row => row.external_event_id === event.event_id)!.payload;
      expect(ledger).toMatchObject({ kind, question_key: [w.task, question.provider_request_id] });
      expect(Object.keys(ledger as object).sort()).toEqual(["agent_task_id", "event_type", "kind", "question_count", "question_key", "status"]);
      expect(JSON.stringify(ledger)).not.toContain("Private");
      expect(await f.apply(w.user, event)).toMatchObject({ status: "duplicate", applied: false });
      expect(await f.apply(w.user, f.event(w, "question", { question: questionFixture({ provider_request_id: "another" }), text: "Other question" }))).toMatchObject({ status: "question_conflict", applied: false });
      expect((await f.state(w)).pending_question).toEqual(pending);
      expect(await f.apply(w.user, f.event(w, "turn_completed"))).toMatchObject({ applied: false });
      expect(await f.state(w)).toMatchObject({ state: "awaiting_answer", pending_question: pending });
    });
    it.each(malformedQuestions())("E5 rejects malformed separate question and direct pending_question CHECK %#", async question => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "accepted"));
      await f.apply(w.user, f.event(w, "progress"));
      const before = await f.state(w), events = await f.events(w);
      await expect(f.apply(w.user, f.event(w, "question", { question, text: "Ask" }))).rejects.toThrow(/apply_agent_event:/);
      await expect(f.updateRow("agent_tasks", w.task, { pending_question: { ...question, question_key: [w.task, "request"], asked_at: "2026-10-13T12:00:00Z" } })).rejects.toThrow(/check constraint/);
      expect(await f.state(w)).toEqual(before);
      expect(await f.events(w)).toEqual(events);
    });
    it.each([
      { question_key: [randomUUID(), "request"] }, { question_key: "task:request" }, { question_key: ["task"] },
      { question_key: ["task", "other"] }, { asked_at: null }, { extra: "private" },
    ])("E5 direct pending CHECK rejects malformed generated metadata %j", async extra => {
      const w = await f.eventWorld();
      await expect(f.updateRow("agent_tasks", w.task, { pending_question: { ...questionFixture(), question_key: [w.task, "request"], asked_at: "2026-10-13T12:00:00Z", ...extra } })).rejects.toThrow(/check constraint/);
      expect((await f.state(w)).pending_question).toBeNull();
    });
    it("E5 accepts four questions and rejects text nested in payload", async () => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "accepted")); await f.apply(w.user, f.event(w, "progress"));
      const question = questionFixture();
      question.questions = Array.from({length:4}, (_, i) => ({ ...question.questions[0], id: String(i) }));
      await expect(f.apply(w.user, f.event(w, "question", { text: "Ask", payload: question }))).rejects.toThrow(/apply_agent_event:/);
      expect(await f.apply(w.user, f.event(w, "question", { question, text: "Ask" }))).toMatchObject({ applied: true });
    });
    it("E6 turn completion is idle without review/check steps or Action mutations", async () => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "accepted"));
      const action = await f.one(`select * from public.actions where id=$1`, [w.action]);
      expect(await f.apply(w.user, f.event(w, "turn_completed"))).toMatchObject({ applied: true, task_state: "idle" });
      expect(await f.q(`select kind from public.execution_steps where run_id=$1`, [w.run])).toEqual([{ kind: "agent_message" }]);
      expect(await f.one(`select state from public.execution_runs where id=$1`, [w.run])).toEqual({ state: "running" });
      expect(await f.one(`select * from public.actions where id=$1`, [w.action])).toEqual(action);
      await f.apply(w.user, f.event(w, "accepted"));
      expect(await f.state(w)).toMatchObject({ state: "idle" });
    });
    it.each(["sign_in_needed", "usage_limited", "spawn_failed", "version_unsupported"])("E7 pre-accept failure %s settles step and delivery together", async reason => {
      const w = await f.eventWorld();
      expect(await f.apply(w.user, f.event(w, "failed", { payload: { reason } }))).toMatchObject({ applied: true, task_state: "failed" });
      expect(await f.one(`select state from public.execution_steps where id=$1`, [w.step])).toEqual({ state: "failed" });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "not_sent", delivery_reason: reason });
      expect(await f.one(`select state from public.execution_runs where id=$1`, [w.run])).toEqual({ state: "running" });
    });
    it("E7 accepted failure leaves called delivery and conversation run open", async () => {
      const w = await f.eventWorld(); await f.apply(w.user, f.event(w, "accepted"));
      expect(await f.apply(w.user, f.event(w, "failed", { payload: { reason: "agent_error" } }))).toMatchObject({ task_state: "failed" });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "dispatched" });
      expect(await f.one(`select state from public.execution_steps where id=$1`, [w.step])).toEqual({ state: "called" });
      expect(await f.one(`select state from public.execution_runs where id=$1`, [w.run])).toEqual({ state: "running" });
    });
    it("E8 unreachable restores live state; original replay is duplicate; idle stays idle", async () => {
      const w = await f.eventWorld(); await f.apply(w.user, f.event(w, "accepted"));
      const progress = f.event(w, "progress"); await f.apply(w.user, progress);
      expect(await f.apply(w.user, f.event(w, "unreachable"))).toMatchObject({ task_state: "unreachable" });
      expect(await f.state(w)).toMatchObject({ last_live_state: "running" });
      expect(await f.apply(w.user, f.event(w, "reconcile"))).toMatchObject({ task_state: "running" });
      expect(await f.apply(w.user, progress)).toMatchObject({ status: "duplicate", applied: false });
      await f.apply(w.user, f.event(w, "turn_completed"));
      await f.apply(w.user, f.event(w, "unreachable"));
      expect(await f.state(w)).toMatchObject({ state: "idle" });
    });
    it("E9 binds pending session and refuses existing real session identity", async () => {
      const w = await f.eventWorld(); const external = randomUUID();
      const occupied = await f.session(w.user, w.connection, { external_session_id: external });
      const before = await f.one(`select * from public.agent_sessions where id=$1`, [w.session]);
      expect(await f.apply(w.user, f.event(w, "session_bound", { payload: { external_session_id: external } }))).toMatchObject({ status: "conflict", applied: false });
      expect(await f.one(`select * from public.agent_sessions where id=$1`, [w.session])).toEqual(before);
      expect(await f.one(`select agent_session_id from public.agent_tasks where id=$1`, [w.task])).toEqual({ agent_session_id: w.session });
      expect(occupied).not.toBe(w.session);
      expect(await f.apply(w.user, f.event(w, "session_bound", { payload: { external_session_id: "actual", workspace_ref: "repo" } }))).toMatchObject({ applied: true });
      expect(await f.one(`select external_session_id,workspace_ref from public.agent_sessions where id=$1`, [w.session])).toEqual({ external_session_id: "actual", workspace_ref: "repo" });
    });
    it("E10 artifacts keep turn attribution and supersede only the same run/path without body", async () => {
      const w = await f.eventWorld();
      for (const [path, hash] of [["src/a.ts", "a"], ["src/b.ts", "b"], ["src/a.ts", "c"]]) {
        expect(await f.apply(w.user, f.event(w, "artifact", { payload: { path, hash, summary: "Changed module" } }))).toMatchObject({ applied: true });
      }
      const rows = await f.q(`select path,content_hash as hash,summary,turn_seq,superseded_at is not null as superseded from public.agent_artifacts where run_id=$1 order by path,hash`, [w.run]);
      expect(rows).toEqual([
        { path: "src/a.ts", hash: "a", summary: "Changed module", turn_seq: w.turn, superseded: true },
        { path: "src/a.ts", hash: "c", summary: "Changed module", turn_seq: w.turn, superseded: false },
        { path: "src/b.ts", hash: "b", summary: "Changed module", turn_seq: w.turn, superseded: false },
      ]);
      for (const payload of [{ path: "x", hash: "h", summary: "s", body: "private" }, { path: "x", hash: "h", summary: "s".repeat(2001) }]) {
        await expect(f.apply(w.user, f.event(w, "artifact", { payload }))).rejects.toThrow(/apply_agent_event:/);
      }
      await expect(f.q(`update public.agent_artifacts set turn_seq=0 where run_id=$1`, [w.run])).rejects.toThrow();
      expect(await f.events(w)).toHaveLength(3);
    });
    it("E6 completion before acceptance converges to idle and called", async () => {
      const w = await f.eventWorld();
      expect(await f.apply(w.user, f.event(w, "turn_completed"))).toMatchObject({ task_state: "idle", applied: true });
      await f.apply(w.user, f.event(w, "accepted"));
      expect(await f.state(w)).toMatchObject({ state: "idle" });
      expect(await f.one(`select state from public.execution_steps where id=$1`, [w.step])).toEqual({ state: "called" });
    });
    it("E2 deleted origin message never leaks reply to a different conversation", async () => {
      const w = await f.eventWorld();
      await f.q(`delete from public.conversation_messages where id=$1`, [w.message]);
      expect(await f.apply(w.user, f.event(w, "message", { text: "reply" }))).toMatchObject({ applied: false });
      expect(await f.messages(w.conversation)).toEqual([]);
      expect(await f.events(w)).toEqual([]);
    });
    it("external task identity resolves exactly within the supplied session", async () => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "message", { text: "First activity", external_task_id: "provider-task" }));
      expect(await f.apply(w.user, f.event(w, "accepted", { agent_task_id: undefined, external_task_id: "provider-task" }))).toMatchObject({ status: "ignored", applied: false });
      expect(await f.apply(w.user, f.event(w, "progress", { external_task_id: "wrong" }))).toMatchObject({ applied: false });
      expect(await f.state(w)).toMatchObject({ state: "accepted" });
    });
    it("cancelled applies without cancel_requested_at", async () => {
      const w = await f.eventWorld();
      expect(await f.apply(w.user, f.event(w, "cancelled"))).toMatchObject({ task_state: "cancelled", applied: true });
      expect(await f.one(`select cancel_requested_at from public.agent_tasks where id=$1`, [w.task])).toEqual({ cancel_requested_at: null });
    });
    it.each([
      { type: "unknown" }, { seq: -1 }, { turn_seq: 0 }, { observed_at: "invalid" },
      { payload: [] }, { type: "failed", payload: { reason: "unknown" } },
      { type: "progress", text: "must not be copied" },
    ])("SQL rejects malformed envelope %j without writes", async extra => {
      const w = await f.eventWorld();
      await expect(f.apply(w.user, f.event(w, "accepted", extra))).rejects.toThrow(/apply_agent_event:/);
      expect(await f.events(w)).toEqual([]);
      expect(await f.state(w)).toMatchObject({ state: "dispatched" });
    });
    it.each([
      [false, "accepted"], [false, "running"], [false, "idle"],
      [true, "dispatched"], [false, "failed"], [true, "failed"],
    ] as const)("E8 reconcile cannot invent state accepted=%s reported=%s", async (accepted, state) => {
      const w = await f.eventWorld();
      if (accepted) await f.apply(w.user, f.event(w, "accepted"));
      await f.apply(w.user, f.event(w, "unreachable"));
      const before = await f.state(w);
      const step = await f.one(`select * from public.execution_steps where id=$1`, [w.step]);
      const message = await f.msg(w.message);
      expect(await f.apply(w.user, f.event(w, "reconcile", { payload: { state } }))).toMatchObject({ status: "reconcile_conflict", applied: false });
      expect(await f.state(w)).toEqual(before);
      expect(await f.one(`select * from public.execution_steps where id=$1`, [w.step])).toEqual(step);
      expect(await f.msg(w.message)).toEqual(message);
      expect(await f.apply(w.user, f.event(w, "reconcile", { payload: { state: accepted ? "accepted" : "dispatched" } }))).toMatchObject({ applied: true, task_state: accepted ? "accepted" : "dispatched" });
      if (!accepted) {
        expect(await f.apply(w.user, f.event(w, "failed", { payload: { reason: "spawn_failed" } }))).toMatchObject({ applied: true, task_state: "failed" });
        expect(await f.msg(w.message)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "spawn_failed" });
      }
    });
    it("E4 same provider event id on different runs retains both replies in one conversation", async () => {
      const w = await f.eventWorld();
      const shared = "provider-reused-event";
      await f.apply(w.user, f.event(w, "message", { event_id: shared, text: "First run" }));
      await f.apply(w.user, f.event(w, "turn_completed"));
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "new issue")).message_id);
      const next = await f.start(w.user, message, [await f.action(w.user)]);
      expect(next.status).toBe("started");
      await f.updateRow("execution_steps", next.step_id!, {state:"calling",lease_owner:"fixture"});
      const second = { ...w, task: next.agent_task_id!, turn: next.turn_seq!, run: next.run_id! };
      expect(second.run).not.toBe(w.run);
      expect(await f.apply(w.user, f.event(second, "message", { event_id: shared, text: "Second run" }))).toMatchObject({ applied: true });
      expect(await f.q(`select text from public.conversation_messages where conversation_id=$1 and role='assistant' order by seq`, [w.conversation])).toEqual([{ text: "First run" }, { text: "Second run" }]);
      for (const world of [w, second]) expect((await f.events(world)).filter(row => row.external_event_id === shared)).toHaveLength(1);
    });
    it("E10 delayed prior-turn artifact cannot supersede the newer turn at the same path", async () => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "turn_completed"));
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "next turn")).message_id);
      const next = await f.start(w.user, message);
      expect(next.status).toBe("started");
      expect(next.run_id).toBe(w.run);
      await f.updateRow("execution_steps", next.step_id!, {state:"calling",lease_owner:"fixture"});
      const second = { ...w, task: next.agent_task_id!, turn: next.turn_seq! };
      expect(await f.apply(w.user, f.event(second, "artifact", { payload: { path: "src/x", hash: "new", summary: "New version" } }))).toMatchObject({ applied: true });
      await f.apply(w.user, f.event(w, "artifact", { payload: { path: "src/x", hash: "old", summary: "Old version" } }));
      expect(await f.q(`select content_hash as hash,turn_seq from public.agent_artifacts where run_id=$1 and path='src/x' and superseded_at is null`, [w.run])).toEqual([{ hash: "new", turn_seq: second.turn }]);
    });
    it.each(["message", "unreachable"])("E9 taskless raw id reused after %s resolves the supplied new turn", async firstType => {
      const w = await f.eventWorld();
      const eventId = "reused-session-observation";
      await f.apply(w.user, f.event(w, firstType, { event_id: eventId, ...(firstType === "message" ? {text:"First reply"} : {}) }));
      if (firstType === "unreachable") await f.apply(w.user, f.event(w, "reconcile"));
      await f.apply(w.user, f.event(w, "turn_completed"));
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "new issue")).message_id);
      const next = await f.start(w.user, message, [await f.action(w.user)]);
      expect(next.status).toBe("started");
      expect(next.run_id).not.toBe(w.run);
      const second = {...w, task:next.agent_task_id!, turn:next.turn_seq!, run:next.run_id!};
      const event = f.event(second, "unreachable", {agent_task_id:undefined, event_id:eventId});
      expect(await f.apply(w.user, event)).toMatchObject({status:"applied",applied:true,task_state:"unreachable"});
      expect(await f.state(w)).toMatchObject({state:"idle"});
      expect(await f.state(second)).toMatchObject({state:"unreachable",last_live_state:"dispatched"});
      expect((await f.events(second)).filter(row => row.external_event_id === eventId)).toHaveLength(1);
      expect(await f.apply(w.user, event)).toMatchObject({status:"duplicate",applied:false});
    });
    it("E9 session-only duplicate after a later run resolves the original event", async () => {
      const w = await f.eventWorld();
      const bound = f.event(w, "session_bound", { agent_task_id: undefined, turn_seq: undefined, payload: { external_session_id: "bound-session" } });
      expect(await f.apply(w.user, bound)).toMatchObject({ applied: true });
      await f.apply(w.user, f.event(w, "turn_completed"));
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "new issue")).message_id);
      const next = await f.start(w.user, message, [await f.action(w.user)]);
      expect(next.status).toBe("started");
      expect(await f.apply(w.user, bound)).toMatchObject({ status: "duplicate", applied: false });
      expect(await f.q(`select run_id from public.execution_events where user_id=$1 and type='agent' and external_event_id=$2`, [w.user, bound.event_id])).toEqual([{ run_id: w.run }]);
    });
    it("E8 replay accepted/progress while unreachable restores latest live state only on reconcile", async () => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "unreachable"));
      const accepted = f.event(w, "accepted"), progress = f.event(w, "progress");
      expect(await f.apply(w.user, accepted)).toMatchObject({ applied: true });
      expect(await f.state(w)).toMatchObject({ state: "unreachable", last_live_state: "accepted" });
      expect(await f.apply(w.user, progress)).toMatchObject({ applied: true });
      expect(await f.state(w)).toMatchObject({ state: "unreachable", last_live_state: "running" });
      expect(await f.apply(w.user, f.event(w, "reconcile"))).toMatchObject({ task_state: "running" });
      expect(await f.apply(w.user, accepted)).toMatchObject({ status: "duplicate", applied: false });
      expect(await f.apply(w.user, progress)).toMatchObject({ status: "duplicate", applied: false });
    });
    it("SQL payload bytes match JSONB spaces at 4096/4097 and count Unicode code points", async () => {
      const w = await f.eventWorld();
      const payload = { path: 'src/"a,b:c".ts', hash: "h", summary: "가".repeat(1300) };
      const bytes = Number((await f.one(`select octet_length($1::jsonb::text) as bytes`, [JSON.stringify(payload)])).bytes);
      payload.summary += "x".repeat(4096 - bytes);
      expect(await f.apply(w.user, f.event(w, "artifact", { payload }))).toMatchObject({ applied: true });
      await expect(f.apply(w.user, f.event(w, "artifact", { payload: { ...payload, summary: payload.summary + "x" } }))).rejects.toThrow(/apply_agent_event:/);
      expect(await f.apply(w.user, f.event(w, "artifact", { event_id: "🙂".repeat(200), payload: { path: "🙂".repeat(600), hash: "h", summary: "ok" } }))).toMatchObject({ applied: true });
      await expect(f.apply(w.user, f.event(w, "progress", { event_id: "🙂".repeat(201) }))).rejects.toThrow(/apply_agent_event:/);
      expect(await f.events(w)).toHaveLength(2);
    });
    it("R2 final ledger metadata is checked again at 4KB",async()=>{
      const w=await f.eventWorld();
      const payload={path:"🙂".repeat(1000),hash:"h",summary:""};
      expect(Number((await f.one(`select octet_length($1::jsonb::text) as n`,[JSON.stringify(payload)])).n)).toBeLessThanOrEqual(4096);
      await expect(f.apply(w.user,f.event(w,"artifact",{payload}))).rejects.toMatchObject({code:"22023"});
      expect(await f.events(w)).toEqual([]);
      expect(await f.q(`select * from public.agent_artifacts where run_id=$1`,[w.run])).toEqual([]);
    });
    it.each(malformedQuestions().slice(0,10))("R2 direct question CHECK bounds %#",async question=>{
      const w=await f.eventWorld();
      await expect(f.updateRow("agent_tasks",w.task,{pending_question:{...question,question_key:[w.task,question.provider_request_id],asked_at:"2026-10-13T12:00:00Z"}})).rejects.toThrow(/check constraint/);
    });
    it.each(["accepted", "progress", "message", "question", "artifact"])("R2 first %s binds external id, settles acceptance, and accepts later low-seq ack", async type => {
      const w = await f.eventWorld();
      expect(await f.one(`select external_task_id from public.agent_tasks where id=$1`, [w.task])).toEqual({external_task_id:null});
      const extra = type === "question" ? {question:questionFixture(),text:"Ask"} : type === "message" ? {text:"Reply"} : type === "artifact" ? {payload:{path:"x",hash:"h",summary:"s"}} : {};
      expect(await f.apply(w.user, f.event(w,type,{seq:10,external_task_id:"provider-task",...extra}))).toMatchObject({applied:true});
      expect(await f.one(`select state,receipt from public.execution_steps where id=$1`,[w.step])).toMatchObject({state:"called",receipt:{ack_level:"agent",external_task_id:"provider-task"}});
      expect(await f.one(`select external_task_id from public.agent_tasks where id=$1`,[w.task])).toEqual({external_task_id:"provider-task"});
      const before = await f.state(w);
      expect(await f.apply(w.user,f.event(w,"accepted",{seq:1,external_task_id:"provider-task"}))).toMatchObject({status:"ignored",applied:false});
      expect(await f.state(w)).toEqual(before);
      expect(await f.apply(w.user,f.event(w,"accepted",{external_task_id:"other"}))).toMatchObject({status:"conflict",applied:false});
      expect(await f.state(w)).toEqual(before);
    });
    it.each(["progress", "message", "question", "artifact"])("R2 late first %s still proves acceptance after unreachable", async type => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "unreachable", { seq: 10 }));
      const extra = type === "question" ? { question: questionFixture(), text: "Ask" } : type === "message" ? { text: "Reply" } : type === "artifact" ? { payload: { path: "x", hash: "h", summary: "s" } } : {};
      expect(await f.apply(w.user, f.event(w, type, { seq: 9, external_task_id: "first-activity", ...extra }))).toMatchObject({ status: "late" });
      expect(await f.state(w)).toMatchObject({ state: "unreachable", last_live_state: "accepted", last_event_seq: 10, pending_question: null });
      expect(await f.one(`select state,receipt from public.execution_steps where id=$1`, [w.step])).toMatchObject({ state: "called", receipt: { ack_level: "agent", external_task_id: "first-activity" } });
      expect(await f.q(`select * from public.agent_artifacts where run_id=$1`, [w.run])).toEqual([]);
    });
    it.each(["progress", "message", "question", "artifact"])("R2 late first %s requires calling lease before any writes", async type => {
      const w = await f.eventWorld(false);
      await f.apply(w.user, f.event(w, "unreachable", { seq: 10 }));
      const extra = type === "question" ? { question: questionFixture(), text: "Ask" } : type === "message" ? { text: "Reply" } : type === "artifact" ? { payload: { path: "x", hash: "h", summary: "s" } } : {};
      const before = await f.events(w);
      expect(await f.apply(w.user, f.event(w, type, { seq: 9, external_task_id: "unbound", ...extra }))).toMatchObject({ status: "step_not_calling", applied: false });
      expect(await f.events(w)).toEqual(before);
      expect(await f.one(`select external_task_id from public.agent_tasks where id=$1`, [w.task])).toEqual({ external_task_id: null });
      expect(await f.q(`select * from public.conversation_messages where conversation_id=$1 and role='assistant'`, [w.conversation])).toEqual([]);
    });
    it("R2 external id resolves without preseed and is unique within session",async()=>{
      const w=await f.eventWorld();
      await f.apply(w.user,f.event(w,"accepted",{external_task_id:"bound"}));
      expect(await f.apply(w.user,f.event(w,"progress",{agent_task_id:undefined,external_task_id:"bound"}))).toMatchObject({applied:true});
      await f.apply(w.user,f.event(w,"turn_completed"));
      const message=String((await f.post(w.user,w.conversation,randomUUID(),"next")).message_id);
      const next=await f.start(w.user,message);
      await f.updateRow("execution_steps",next.step_id!,{state:"calling",lease_owner:"fixture"});
      const second={...w,task:next.agent_task_id!,turn:next.turn_seq!};
      expect(await f.apply(w.user,f.event(second,"accepted",{external_task_id:"bound"}))).toMatchObject({status:"conflict",applied:false});
      await expect(f.updateRow("agent_tasks",second.task,{external_task_id:"bound"})).rejects.toThrow(/unique/);
      expect(await f.state(second)).toMatchObject({state:"dispatched"});
    });
    it("R2 preaccept cancellation settles failed receipt and cancelled delivery",async()=>{
      const w=await f.eventWorld();
      await f.apply(w.user,f.event(w,"cancelled"));
      expect(await f.one(`select state,receipt,lease_owner from public.execution_steps where id=$1`,[w.step])).toMatchObject({state:"failed",receipt:{cancelled:true},lease_owner:null});
      expect(await f.msg(w.message)).toMatchObject({delivery_state:"cancelled"});
    });
    it("R2 accepted question needs no progress; repeated running progress is ignored with monotone heartbeat",async()=>{
      const w=await f.eventWorld();
      await f.apply(w.user,f.event(w,"accepted"));
      expect(await f.apply(w.user,f.event(w,"question",{question:questionFixture(),text:"Ask"}))).toMatchObject({task_state:"awaiting_answer",applied:true});
      const v=await f.eventWorld();
      await f.apply(v.user,f.event(v,"accepted"));await f.apply(v.user,f.event(v,"progress"));
      const repeat=f.event(v,"progress",{seq:20,observed_at:"2099-10-14T12:00:00Z"});
      expect(await f.apply(v.user,repeat)).toMatchObject({status:"ignored",applied:false});
      const seen=await f.one(`select last_seen_at from public.agent_tasks where id=$1`,[v.task]);
      expect(new Date(String(seen.last_seen_at)).toISOString()).toBe("2099-10-14T12:00:00.000Z");
      await f.apply(v.user,f.event(v,"message",{text:"Older clock",observed_at:"2020-01-01T00:00:00Z"}));
      expect(await f.one(`select last_seen_at from public.agent_tasks where id=$1`,[v.task])).toEqual(seen);
      expect(await f.apply(v.user,repeat)).toMatchObject({status:"duplicate"});
    });
    it.each([{}, {reason:"agent_error"}])("R2 postaccept failure accepts optional agent reason %j",async payload=>{
      const w=await f.eventWorld();await f.apply(w.user,f.event(w,"accepted"));
      expect(await f.apply(w.user,f.event(w,"failed",{payload}))).toMatchObject({applied:true,task_state:"failed"});
    });
    it("R3 postaccept preaccept reasons are recorded as conflict without state changes", async () => {
      const w = await f.eventWorld();
      await f.apply(w.user, f.event(w, "accepted", { seq: 1 }));
      const snapshot = async () => Promise.all([
        f.one(`select * from public.agent_tasks where id=$1`, [w.task]),
        f.one(`select * from public.execution_steps where id=$1`, [w.step]),
        f.one(`select * from public.execution_runs where id=$1`, [w.run]),
        f.one(`select * from public.agent_sessions where id=$1`, [w.session]),
        f.one(`select * from public.conversation_messages where id=$1`, [w.message]),
      ]);
      const before = await snapshot();
      for (const reason of ["sign_in_needed", "usage_limited", "spawn_failed", "version_unsupported"]) {
        const event = f.event(w, "failed", {
          payload: { reason }, seq: 2, external_task_id: "must-not-bind",
          observed_at: "2099-10-14T12:00:00Z",
        });
        const previousEvents = await f.events(w);
        expect(await f.apply(w.user, event)).toEqual({ status: "conflict", applied: false, task_state: "accepted" });
        const events = await f.events(w);
        expect(events).toHaveLength(previousEvents.length + 1);
        expect(events).toEqual(expect.arrayContaining(previousEvents));
        expect(events.find(row => row.external_event_id === event.event_id)).toEqual({
          external_event_id: event.event_id, turn_seq: w.turn,
          payload: { event_type: "failed", status: "conflict", agent_task_id: w.task, reason },
        });
        expect(await snapshot()).toEqual(before);
        expect(await f.apply(w.user, event)).toEqual({ status: "duplicate", applied: false, task_state: "accepted" });
        expect(await f.events(w)).toEqual(events);
        expect(await snapshot()).toEqual(before);
      }
    });
    it.each([{}, {reason:"agent_error"}])("R2 preaccept failure rejects postaccept reason %j",async payload=>{
      const w=await f.eventWorld();
      await expect(f.apply(w.user,f.event(w,"failed",{payload}))).rejects.toMatchObject({code:"22023"});
      expect(await f.events(w)).toEqual([]);
    });
    it.each([{seq:0},{observed_at:"October 13, 2026"},{observed_at:"2026-10-13"}])("R2 rejects nonpositive seq or non ISO instant %j",async extra=>{
      const w=await f.eventWorld();await expect(f.apply(w.user,f.event(w,"accepted",extra))).rejects.toMatchObject({code:"22023"});
      expect(await f.events(w)).toEqual([]);
    });
    it("R2 session_bound bypasses turn and seq late and same identity replay is ignored",async()=>{
      const w=await f.eventWorld();await f.apply(w.user,f.event(w,"accepted",{seq:10}));
      const extra={seq:1,turn_seq:w.turn+99,payload:{external_session_id:"real"}};
      expect(await f.apply(w.user,f.event(w,"session_bound",extra))).toMatchObject({applied:true});
      expect(await f.apply(w.user,f.event(w,"session_bound",extra))).toMatchObject({status:"ignored",applied:false});
      expect(await f.state(w)).toMatchObject({last_event_seq:10});
    });
    it.each([false,true])("R2 late message saved after idle but not after not_sent=%s",async failed=>{
      const w=await f.eventWorld();
      if(failed) await f.apply(w.user,f.event(w,"failed",{seq:10,payload:{reason:"spawn_failed"}}));
      else {await f.apply(w.user,f.event(w,"accepted"));await f.apply(w.user,f.event(w,"turn_completed",{seq:10}));}
      const e=f.event(w,"message",{seq:1,text:"Late reply"});
      expect(await f.apply(w.user,e)).toMatchObject({status:"late",applied:false});
      expect(await f.q(`select text from public.conversation_messages where conversation_id=$1 and role='assistant'`,[w.conversation])).toEqual(failed?[]:[{text:"Late reply"}]);
      expect(await f.apply(w.user,e)).toMatchObject({status:"duplicate"});
    });
    it.each(["accepted","turn_completed","failed","cancelled"])("R2 repeated %s is ignored and same event is write-free",async type=>{
      const w=await f.eventWorld();
      const payload=type==="failed"?{reason:"spawn_failed"}:{};
      await f.apply(w.user,f.event(w,type,{payload}));
      const e=f.event(w,type,{payload});
      expect(await f.apply(w.user,e)).toMatchObject({status:"ignored",applied:false});
      const rows=await f.events(w);
      expect(await f.apply(w.user,e)).toMatchObject({status:"duplicate",applied:false});
      expect(await f.events(w)).toEqual(rows);
    });
    it.each(["failed","cancelled"])("R2 guard %s clears pending question",async type=>{
      const w=await f.eventWorld();await f.apply(w.user,f.event(w,"accepted"));await f.apply(w.user,f.event(w,"progress"));
      await f.apply(w.user,f.event(w,"question",{text:"Ask",question:questionFixture()}));
      expect((await f.state(w)).pending_question).not.toBeNull();
      await f.apply(w.user,f.event(w,type,{payload:type==="failed"?{reason:"agent_error"}:{}}));
      expect(await f.state(w)).toMatchObject({state:type,pending_question:null});
    });
    it.each(["conversation_run","provider","message","session","connection","lease"])("R2 guard rejects corrupt %s without writes",async kind=>{
      const w=await f.eventWorld(false);
      const policy=(await f.one(`select policy_version from public.execution_steps where id=$1`,[w.step])).policy_version;
      if(kind==="conversation_run") await f.updateRow("execution_runs",w.run,{kind:"task"});
      if(kind==="provider") await f.updateRow("execution_steps",w.step,{provider:"agent:claude-code"});
      if(kind==="message") await f.updateRow("execution_steps",w.step,{args:{message_id:randomUUID()}});
      if(kind==="lease") await f.updateRow("execution_steps",w.step,{lease_owner:null});
      if(kind==="session"||kind==="connection") {
        const connection=kind==="connection"?await f.agentConnection(w.user,await f.bridge(w.user),{adapter:"agent:codex"}):w.connection;
        const session=await f.session(w.user,connection);
        const conversation=await f.agentConversation(w.user,connection,kind==="session"?session:w.session);
        const message=String((await f.post(w.user,conversation,randomUUID(),"other")).message_id);
        await f.updateRow("agent_tasks",w.task,{message_id:message});
        await f.updateRow("execution_steps",w.step,{args:{message_id:message}});
      }
      await f.updateRow("execution_steps",w.step,{state:"calling",lease_owner:kind==="lease"?null:"fixture",policy_version:policy});
      expect(await f.apply(w.user,f.event(w,"accepted"))).toMatchObject({applied:false});
      expect(await f.events(w)).toEqual([]);
      expect(await f.state(w)).toMatchObject({state:"dispatched"});
    });
    it("E12 pending-question CHECK helper is immutable invoker and service-only", async () => {
      expect(await f.q(`select p.prosecdef,p.provolatile,p.proconfig,has_function_privilege('anon',p.oid,'execute') as anon,has_function_privilege('authenticated',p.oid,'execute') as app,has_function_privilege('service_role',p.oid,'execute') as server from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='agent_pending_question_valid'`)).toEqual([{ prosecdef: false, provolatile: "i", proconfig: ['search_path=""'], anon: false, app: false, server: true }]);
    });
    it("E12 RPC is invoker with empty search_path and service_role-only execute", async () => {
      const rows = await f.q(`select p.prosecdef,p.proconfig,has_function_privilege('anon',p.oid,'execute') as anon,has_function_privilege('authenticated',p.oid,'execute') as app,has_function_privilege('service_role',p.oid,'execute') as server from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='apply_agent_event'`);
      expect(rows).toEqual([{ prosecdef: false, proconfig: ['search_path=""'], anon: false, app: false, server: true }]);
    });
  });
}
