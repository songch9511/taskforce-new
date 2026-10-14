import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { MAX_LIVE_EXTERNAL_TASKS } from "../../src/lib/execution/limits";
import { conversationAgentFixtures, type ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// Written for the coordinator's disposable PostgreSQL run; PGlite cannot prove these waits.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL databases.");
const DB_NAME = `taskforce_questions_stop_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let aPid: number;
let bPid: number;
async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '15s'");
  return client;
}
beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(DB_NAME);
  b = await connect(DB_NAME);
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);
afterEach(async () => {
  await a?.query("rollback").catch(() => {});
  await b?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});
const db = (): ConversationAgentDb => ({
  query: async (sql, params) => (await setup.query(sql, params)).rows,
  asUser: async <T,>(user: string, fn: () => Promise<T>) => {
    await setup.query("set role authenticated");
    await setup.query("select set_config('request.jwt.claim.sub', $1, false)", [user]);
    try { return await fn(); } finally {
      await setup.query("reset role");
      await setup.query("select set_config('request.jwt.claim.sub', '', false)");
    }
  },
});
const f = conversationAgentFixtures(db);
type Turn = { status: string; agent_task_id: string; action_id: string; run_id: string; step_id: string; turn_seq: number };
type Answer = { status: string; step_id?: string };
const start = async (client: pg.Client, user: string, message: string, actions: string[] = []) =>
  (await client.query<{ result: Turn }>(
    "select public.start_agent_turn($1,$2,$3::uuid[],'{}'::uuid[],'read_only',$4) as result",
    [user, message, actions, MAX_LIVE_EXTERNAL_TASKS],
  )).rows[0].result;
const answer = async (client: pg.Client, w: World, request = "request-1") =>
  (await client.query<{ result: Answer }>("select public.answer_agent_question($1,$2,$3,$4::jsonb,false) as result",
    [w.user, w.agent_task_id, request, JSON.stringify({ choice: "Yes" })])).rows[0].result;
const stop = async (client: pg.Client, w: World) =>
  (await client.query<{ result: { tasks: { agent_task_id: string; cancel: string }[] } }>(
    "select public.stop_agent_session($1,$2,'assistant',$3) as result",
    [w.user, w.session, w.adapter === "agent:claude-code" ? "turn_and_processes" : "turn"])).rows[0].result;
const apply = async (client: pg.Client, w: World, type: string, extra: Record<string, unknown> = {}) =>
  (await client.query<{ result: { status: string; applied: boolean } }>(
    "select public.apply_agent_event($1,$2::jsonb) as result", [w.user, JSON.stringify({
      adapter: w.adapter, session_ref: { agent_session_id: w.session }, agent_task_id: w.agent_task_id,
      event_id: randomUUID(), turn_seq: w.turn_seq, type, payload: {}, observed_at: new Date().toISOString(), ...extra,
    })])).rows[0].result;
async function question(w: World, request = "request-1") {
  expect(await apply(setup, w, "question", { text: "Choose", question: {
    provider_request_id: request, kind: "input", structured: true,
    questions: [{ id: "choice", header: "Choose", text: "Which?", options: [{ label: "Yes", description: "Proceed" }], multi_select: false, allow_other: true, secret: false }],
  } })).toMatchObject({ status: "applied", applied: true });
}
async function world(dispatched = false, adapter = "agent:codex") {
  const user = await f.user();
  const bridge = await f.bridge(user);
  const connection = await f.agentConnection(user, bridge, { adapter });
  const conversation = await f.agentConversation(user, connection);
  const message = String((await f.post(user, conversation, randomUUID(), "First turn")).message_id);
  const turn = await start(setup, user, message);
  expect(turn.status).toBe("started");
  const session = String((await f.one("select agent_session_id from public.conversations where id=$1", [conversation])).agent_session_id);
  const w = { user, connection, conversation, message, session, adapter, ...turn };
  if (!dispatched) {
    await f.updateRow("execution_steps", turn.step_id, { state: "calling", lease_owner: "fixture" });
    expect(await apply(setup, w, "progress")).toMatchObject({ status: "applied" });
  }
  return w;
}
type World = Awaited<ReturnType<typeof world>>;
async function done(client: pg.Client, w: World) {
  const claim = { id: randomUUID(), source_id: null, field: "status", value: "done", quote: null,
    occurred_at: new Date().toISOString(), speaker_role: "me", certainty: "firm", directness: "first_hand",
    audience: "shared", origin: "user", channel: "note", state: "active" };
  const result = await client.query<{ written: boolean }>(
    `select public.write_action($1,id,version,to_jsonb(actions)||'{"status":"done"}'::jsonb,$3::jsonb,'[]','[]') as written
       from public.actions where user_id=$1 and id=$2`, [w.user, w.action_id, JSON.stringify([claim])]);
  expect(result.rows).toEqual([{ written: true }]);
}
async function waitForBlock(blocker = aPid) {
  for (let i = 0; i < 100; i++) {
    const row = (await setup.query<{ blocked: boolean }>(
      "select $2::int = any(pg_blocking_pids($1)) as blocked", [bPid, blocker])).rows[0];
    if (row.blocked) return;
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  throw new Error("Expected B to demonstrably block on A via pg_blocking_pids");
}
const answerCount = (w: World, request = "request-1") => f.count(
  "select 1 from public.execution_steps where run_id=$1 and args->>'agent_task_id'=$2 and args->>'provider_request_id'=$3", [w.run_id, w.agent_task_id, request]);

// Attach a rejection handler immediately: a deadlock must fail its assertion, not escape as an unhandled rejection.
const pending = <T,>(promise: Promise<T>) => promise.then(value => ({ value }), error => ({ error }));
async function resolved<T>(promise: ReturnType<typeof pending<T>>) {
  const result = await promise;
  if ("error" in result) throw result.error;
  return result.value;
}

describe("Q2 one answer under real PostgreSQL contention", () => {
  for (const finish of ["commit", "rollback"] as const) {
    it(`Assistant and Review contend; first ${finish} leaves exactly one prepared answer`, async () => {
      const w = await world();
      await question(w);
      await a.query("begin");
      await b.query("begin");
      const first = await answer(a, w);
      expect(first.status).toBe("answered");
      const waiting = pending(answer(b, w));
      await waitForBlock();
      await a.query(finish);
      const second = await resolved(waiting);
      expect(second.status).toBe(finish === "commit" ? "duplicate" : "answered");
      if (finish === "commit") expect(second.step_id).toBe(first.step_id);
      await b.query("commit");
      expect(await answerCount(w)).toBe(1);
      expect(await f.one("select state,body from public.execution_steps where id=$1", [second.step_id])).toEqual({ state: "prepared", body: "" });
    });
  }
  it("a replaced request rejects the stale key while an independent question remains answerable", async () => {
    const w = await world();
    await question(w);
    const answered = await answer(setup, w);
    await f.updateRow("execution_steps", answered.step_id!, { state: "calling", lease_owner: "answer-fixture" });
    expect(await apply(setup, w, "accepted")).toMatchObject({ applied: true });
    await question(w, "request-2");
    const other = await world();
    await question(other);
    await a.query("begin");
    await b.query("begin");
    expect(await answer(a, w, "request-1")).toMatchObject({ status: "question_stale" });
    expect(await answer(b, other)).toMatchObject({ status: "answered" });
    await a.query("commit");
    await b.query("commit");
    expect(await answerCount(w)).toBe(1);
    expect(await answerCount(w, "request-2")).toBe(0);
    expect(await answerCount(other)).toBe(1);
    expect(await answer(setup, w, "request-2")).toMatchObject({ status: "answered" });
  });
});

describe("D3 Done and same-session start preserve lock order", () => {
  for (const doneFirst of [true, false]) {
    it(`Done first=${doneFirst}: both operations finish without session/Action inversion`, async () => {
      const w = await world();
      await apply(setup, w, "turn_completed");
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "Next turn")).message_id);
      await a.query("begin");
      await b.query("begin");
      if (doneFirst) {
        await a.query("select id from public.actions where id=$1 for update", [w.action_id]);
        const waiting = pending(start(b, w.user, message, [w.action_id]));
        // B has taken session and is waiting for A's Action; Done must never ask B for session.
        await waitForBlock();
        await done(a, w);
        await a.query("commit");
        expect(await resolved(waiting)).toMatchObject({ status: "not_sent" });
      } else {
        expect(await start(a, w.user, message, [w.action_id])).toMatchObject({ status: "started" });
        const waiting = pending(done(b, w));
        await waitForBlock();
        await a.query("commit");
        await resolved(waiting);
      }
      await b.query("commit");
      expect(await f.one("select state from public.execution_runs where id=$1", [w.run_id])).toEqual({ state: "stopped" });
      expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind='agent_cancel'", [w.run_id])).toBe(0);
      expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind in ('review','check')", [w.run_id])).toBe(0);
    });
  }
});

it("D2 Done A while B progresses in the same session preserves B run and task", async () => {
  const w = await world();
  await apply(setup, w, "turn_completed");
  const otherAction = await f.action(w.user);
  const message = String((await f.post(w.user, w.conversation, randomUUID(), "Work on B")).message_id);
  const second = await start(setup, w.user, message, [otherAction]);
  expect(second.status).toBe("started");
  await f.updateRow("execution_steps", second.step_id, { state: "calling", lease_owner: "fixture" });
  const other = { ...w, ...second, message };
  await a.query("begin");
  await b.query("begin");
  expect(await apply(a, other, "progress")).toMatchObject({ status: "applied" });
  // A keeps session/run B/task B locks: Done A must complete before A releases them.
  await done(b, w);
  await b.query("commit");
  await a.query("commit");
  expect(await f.one("select state from public.execution_runs where id=$1", [w.run_id])).toEqual({ state: "stopped" });
  expect(await f.one("select state from public.execution_runs where id=$1", [other.run_id])).toEqual({ state: "running" });
  expect(await f.one("select state,cancel_requested_at from public.agent_tasks where id=$1", [other.agent_task_id])).toEqual({ state: "running", cancel_requested_at: null });
  expect(await f.count("select 1 from public.execution_steps where run_id=any($1::uuid[]) and kind in ('agent_cancel','review','check')", [[w.run_id, other.run_id]])).toBe(0);
});

for (const opponent of ["event", "start", "stop"] as const) {
  for (const answerFirst of [true, false]) {
    it(`answer versus ${opponent}, answer first=${answerFirst}: serializes without lock inversion`, async () => {
      const w = await world();
      await question(w);
      const message = String((await f.post(w.user, w.conversation, randomUUID(), "Next message")).message_id);
      const other = (client: pg.Client) => opponent === "event"
        ? apply(client, w, "message", { text: "Still waiting" })
        : opponent === "start" ? start(client, w.user, message) : stop(client, w);
      await a.query("begin");
      await b.query("begin");
      if (answerFirst) expect(await answer(a, w)).toMatchObject({ status: "answered" });
      else await other(a);
      const waiting = pending<unknown>(answerFirst ? other(b) : answer(b, w));
      await waitForBlock();
      await a.query("commit");
      await resolved(waiting);
      await b.query("commit");
      expect(await answerCount(w)).toBe(opponent === "stop" && !answerFirst ? 0 : 1);
    });
  }
}

it("Stop waits for queued message before taking session, so concurrent start can finish", async () => {
  const w = await world();
  const message = String((await f.post(w.user, w.conversation, randomUUID(), "Queued message")).message_id);
  await a.query("begin");
  await b.query("begin");
  await a.query("select id from public.conversation_messages where id=$1 for update", [message]);
  const waiting = pending(stop(b, w));
  await waitForBlock();
  expect(await start(a, w.user, message)).toMatchObject({ status: "queued" });
  await a.query("commit");
  await resolved(waiting);
  await b.query("commit");
  expect(await f.one("select delivery_state from public.conversation_messages where id=$1", [message])).toEqual({ delivery_state: "cancelled" });
});


it("Stop rechecks a message posted during its scan with NOWAIT and leaves no partial writes", async () => {
  const w = await world();
  const holder = await connect(DB_NAME);
  try {
    const holderPid = (await holder.query<{pid:number}>("select pg_backend_pid() as pid")).rows[0].pid;
    await holder.query("begin");
    await holder.query("select id from public.agent_sessions where id=$1 for update", [w.session]);
    await a.query("begin");
    await a.query("select id from public.conversations where id=$1 for update", [w.conversation]);
    await b.query("begin");
    const waiting = pending(stop(b, w));
    await waitForBlock();
    const posted = await a.query<{message_id:string}>(
      "select * from public.conversation_post_message($1,$2,$3,'Concurrent message',$4::jsonb,75)",
      [w.user,w.conversation,randomUUID(),JSON.stringify({action_ids:[],run_ids:[],artifact_ids:[]})]);
    const message = posted.rows[0].message_id;
    await a.query("commit");
    await waitForBlock(holderPid);
    await setup.query("begin");
    await setup.query("select id from public.conversation_messages where id=$1 for update", [message]);
    await holder.query("commit");
    const outcome = await waiting;
    expect(outcome).toHaveProperty("error.code", "55P03");
    await b.query("rollback");
    expect(await f.one("select state from public.execution_runs where id=$1", [w.run_id])).toEqual({state:"running"});
    expect(await f.one("select cancel_requested_at from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual({cancel_requested_at:null});
    expect(await f.count("select 1 from public.metric_events where user_id=$1 and type='stop_requested'", [w.user])).toBe(0);
    await setup.query("commit");
    expect(await stop(b,w)).toMatchObject({tasks:[{agent_task_id:w.agent_task_id,cancel:"requested_only"}]});
    expect(await f.one("select delivery_state from public.conversation_messages where id=$1", [message])).toEqual({delivery_state:"cancelled"});
  } finally {
    await holder.query("rollback").catch(() => {});
    await holder.end();
    await setup.query("rollback").catch(() => {});
  }
});

for (const finish of ["stop", "done"] as const) {
  it(`${finish} confirms an unleased turn locally and immediately permits the next turn`, async () => {
    const w = await world(true);
    if (finish === "stop") expect(await stop(setup, w)).toMatchObject({ tasks: [{ agent_task_id: w.agent_task_id, cancel: "confirmed" }] });
    else await done(setup, w);
    expect(await f.one("select state from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual({ state: "cancelled" });
    expect(await f.one("select state from public.execution_steps where id=$1", [w.step_id])).toEqual({ state: "skipped" });
    expect(await f.one("select delivery_state from public.conversation_messages where id=$1", [w.message])).toEqual({ delivery_state: "cancelled" });
    expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind='agent_cancel'", [w.run_id])).toBe(0);
    expect(await f.one("select state, stopped_at is null as no_stop_time from public.execution_runs where id=$1", [w.run_id]))
      .toEqual({ state: "stopped", no_stop_time: finish === "done" });
    expect(await f.count("select 1 from public.inbox_events where user_id=$1 and dedup_key=$2", [w.user, `run_stop:${w.run_id}`]))
      .toBe(finish === "stop" ? 1 : 0);
    const message = String((await f.post(w.user, w.conversation, randomUUID(), "Next turn")).message_id);
    expect(await start(setup, w.user, message)).toMatchObject({ status: "started" });
  });
}

it("Stop does not lock completed user messages or agent event history", async () => {
  const w = await world();
  await apply(setup, w, "turn_completed");
  const message = String((await f.post(w.user, w.conversation, randomUUID(), "Current turn")).message_id);
  const current = await start(setup, w.user, message);
  expect(current.status).toBe("started");
  await a.query("begin");
  await b.query("begin");
  await a.query("select id from public.conversation_messages where conversation_id=$1 and id<>$2 for update", [w.conversation, message]);
  // A retains only history locks; Stop must finish while those locks are still held.
  expect(await stop(b, { ...w, ...current, message })).toMatchObject({ tasks: [{ agent_task_id: current.agent_task_id, cancel: "confirmed" }] });
  await b.query("commit");
  await a.query("commit");
  expect(await f.one("select delivery_state from public.conversation_messages where id=$1", [w.message])).toEqual({ delivery_state: "dispatched" });
});

for (const changed of ["run", "external", "closed", "connection"] as const) {
  it(`answer rechecks ${changed} after waiting for the session lock`, async () => {
    const w = await world();
    await question(w);
    await a.query("begin");
    await a.query("select id from public.agent_sessions where id=$1 for update", [w.session]);
    await b.query("begin");
    const waiting = pending(answer(b, w));
    await waitForBlock();
    if (changed === "run") await a.query("update public.execution_runs set state='stopped' where id=$1", [w.run_id]);
    else if (changed === "connection") await a.query("update public.agent_connections set status='error' where id=$1", [w.connection]);
    else await a.query("update public.agent_sessions set status=$2 where id=$1", [w.session, changed]);
    await a.query("commit");
    expect(await resolved(waiting)).toEqual({ status: "question_stale" });
    await b.query("commit");
    expect(await answerCount(w)).toBe(0);
    expect(await f.one("select pending_question is not null as still_open from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual({ still_open: true });
  });
}

it("Done fails atomically when an unleased origin is locked, then succeeds after the message transaction", async () => {
  const w = await world(true);
  await a.query("begin");
  await a.query("select id from public.conversation_messages where id=$1 for update", [w.message]);
  await b.query("begin");
  await expect(done(b, w)).rejects.toHaveProperty("code", "55P03");
  await b.query("rollback");
  expect(await f.one("select status from public.actions where id=$1", [w.action_id])).toEqual({ status: "open" });
  expect(await f.one("select state from public.execution_runs where id=$1", [w.run_id])).toEqual({ state: "running" });
  expect(await f.one("select state,cancel_requested_at from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual({ state: "dispatched", cancel_requested_at: null });
  expect(await start(a, w.user, w.message, [w.action_id])).toMatchObject({ status: "already_dispatched" });
  await a.query("commit");
  await done(b, w);
  expect(await f.one("select state from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual({ state: "cancelled" });
});

for (const finish of ["stop", "done"] as const) {
  it(`Claude Code ${finish} confirms an unleased answer and starts another issue in the same session`, async () => {
    const w = await world(false, "agent:claude-code");
    await question(w);
    const answered = await answer(setup, w);
    expect(answered.status).toBe("answered");
    expect(await f.one("select state,lease_owner,lease_expires_at from public.execution_steps where id=$1", [answered.step_id]))
      .toEqual({ state: "prepared", lease_owner: null, lease_expires_at: null });
    expect(await f.count("select 1 from public.execution_intents where step_id=$1", [answered.step_id])).toBe(0);
    expect(await f.count("select 1 from public.execution_events where step_id=$1 and type='step' and to_state='calling'", [answered.step_id])).toBe(0);
    if (finish === "stop") expect(await stop(setup, w)).toMatchObject({ tasks: [{ agent_task_id: w.agent_task_id, cancel: "confirmed" }] });
    else await done(setup, w);
    expect(await f.one("select state,pending_question,answered_question,abandoned_question from public.agent_tasks where id=$1", [w.agent_task_id]))
      .toEqual({ state: "cancelled", pending_question: null, answered_question: null, abandoned_question: [w.agent_task_id, "request-1"] });
    expect(await f.one("select state from public.execution_steps where id=$1", [answered.step_id])).toEqual({ state: "skipped" });
    expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind='agent_cancel'", [w.run_id])).toBe(0);
    expect(await f.count("select 1 from public.execution_events where run_id=$1 and payload->>'event_type'='question_denied' and payload->>'decision'='deny' and payload->'question_key'=$2::jsonb",
      [w.run_id, JSON.stringify([w.agent_task_id, "request-1"])])).toBe(1);
    const otherAction = await f.action(w.user);
    const message = String((await f.post(w.user, w.conversation, randomUUID(), "Work on another issue")).message_id);
    expect(await start(setup, w.user, message, [otherAction])).toMatchObject({ status: "started", action_id: otherAction });
  });
}

for (const adapter of ["agent:claude-code", "agent:codex"] as const) {
  it(`${adapter} Done rolls back on a locked answer message and cancels it after release`, async () => {
    const w = await world(false, adapter);
    await question(w);
    const message = String((await f.post(w.user, w.conversation, randomUUID(), "My answer")).message_id);
    const routed = (await setup.query<{ result: Answer }>(
      "select public.route_agent_message($1,$2,'read_only',$3,'{}'::uuid[],'{}'::uuid[]) as result",
      [w.user, message, MAX_LIVE_EXTERNAL_TASKS])).rows[0].result;
    expect(routed.status).toBe("answered");
    const beforeTask = await f.one("select state,pending_question,answered_question,abandoned_question,cancel_requested_at from public.agent_tasks where id=$1", [w.agent_task_id]);
    const beforeAction = await f.one("select status,version from public.actions where id=$1", [w.action_id]);
    const beforeMessage = await f.one("select delivery_state,refs from public.conversation_messages where id=$1", [message]);
    expect(beforeMessage).toMatchObject({ delivery_state: "dispatched", refs: { answer_for: [w.agent_task_id, "request-1"] } });
    await a.query("begin");
    await a.query("select id from public.conversation_messages where id=$1 for update", [message]);
    await b.query("begin");
    await expect(done(b, w)).rejects.toHaveProperty("code", "55P03");
    await b.query("rollback");
    expect(await f.one("select status,version from public.actions where id=$1", [w.action_id])).toEqual(beforeAction);
    expect(await f.one("select state from public.execution_runs where id=$1", [w.run_id])).toEqual({ state: "running" });
    expect(await f.one("select state,pending_question,answered_question,abandoned_question,cancel_requested_at from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual(beforeTask);
    expect(await f.one("select state from public.execution_steps where id=$1", [routed.step_id])).toEqual({ state: "prepared" });
    expect(await f.one("select delivery_state,refs from public.conversation_messages where id=$1", [message])).toEqual(beforeMessage);
    expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind='agent_cancel'", [w.run_id])).toBe(0);
    expect(await f.count("select 1 from public.execution_events where run_id=$1 and payload->>'event_type'='question_denied'", [w.run_id])).toBe(0);
    await a.query("commit");
    await done(b, w);
    expect(await f.one("select status from public.actions where id=$1", [w.action_id])).toEqual({ status: "done" });
    expect(await f.one("select state,stopped_at from public.execution_runs where id=$1", [w.run_id])).toEqual({ state: "stopped", stopped_at: null });
    expect(await f.one("select state,abandoned_question from public.agent_tasks where id=$1", [w.agent_task_id]))
      .toEqual({ state: adapter === "agent:claude-code" ? "cancelled" : "running", abandoned_question: [w.agent_task_id, "request-1"] });
    expect(await f.one("select state from public.execution_steps where id=$1", [routed.step_id])).toEqual({ state: "skipped" });
    expect(await f.one("select delivery_state,refs from public.conversation_messages where id=$1", [message]))
      .toEqual({ ...beforeMessage, delivery_state: "cancelled" });
    expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind='agent_cancel' and state='prepared'", [w.run_id]))
      .toBe(adapter === "agent:claude-code" ? 0 : 1);
  });
}
