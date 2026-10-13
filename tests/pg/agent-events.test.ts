import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { MAX_LIVE_EXTERNAL_TASKS } from "../../src/lib/execution/limits";
import { conversationAgentFixtures, type ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 작성만: 잠금 경합은 실제 PG의 별도 연결과 pg_stat_activity로 증명한다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL databases.");
const DB_NAME = `taskforce_agent_events_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
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
type Turn = { status: string; agent_task_id: string; run_id: string; step_id: string; turn_seq: number };
type Applied = { status: string; applied: boolean; task_state?: string };
const start = async (client: pg.Client, user: string, message: string) =>
  (await client.query<{ result: Turn }>(
    "select public.start_agent_turn($1,$2,'{}'::uuid[],'{}'::uuid[],'read_only',$3) as result",
    [user, message, MAX_LIVE_EXTERNAL_TASKS],
  )).rows[0].result;
const apply = async (client: pg.Client, user: string, event: Record<string, unknown>) =>
  (await client.query<{ result: Applied }>("select public.apply_agent_event($1,$2::jsonb) as result", [user, JSON.stringify(event)])).rows[0].result;
async function world() {
  const user = await f.user();
  const bridge = await f.bridge(user);
  const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
  const conversation = await f.agentConversation(user, connection);
  const message = String((await f.post(user, conversation, randomUUID(), "first turn")).message_id);
  const turn = await start(setup, user, message);
  expect(turn.status).toBe("started");
  const session = String((await f.one("select agent_session_id from public.conversations where id=$1", [conversation])).agent_session_id);
  // Bridge dispatch remains closed: fixtures alone establish the calling lease.
  await f.updateRow("execution_steps", turn.step_id, { state: "calling", lease_owner: "event-fixture" });
  const nextMessage = String((await f.post(user, conversation, randomUUID(), "next turn")).message_id);
  return { user, connection, conversation, message, nextMessage, session, ...turn };
}
type World = Awaited<ReturnType<typeof world>>;
const envelope = (w: World, type: string, extra: Record<string, unknown> = {}) => ({
  adapter: "agent:codex", session_ref: { agent_session_id: w.session }, agent_task_id: w.agent_task_id,
  event_id: randomUUID(), turn_seq: w.turn_seq, type, payload: {}, observed_at: new Date().toISOString(), ...extra,
});
async function waitForLockWait() {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null; blocked: boolean }>(
      "select wait_event_type, cardinality(pg_blocking_pids(pid)) > 0 as blocked from pg_stat_activity where pid=$1", [bPid],
    );
    if (rows[0]?.wait_event_type === "Lock" && rows[0].blocked) return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("Second connection did not demonstrably wait on a PostgreSQL lock");
}
async function expectFinished(w: World) {
  expect(await f.q("select state, pending_question from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual([{ state: "idle", pending_question: null }]);
  expect(await f.q("select state from public.execution_steps where id=$1", [w.step_id])).toEqual([{ state: "called" }]);
  expect(await f.q("select state from public.execution_runs where id=$1", [w.run_id])).toEqual([{ state: "running" }]);
  expect(await f.count("select 1 from public.execution_steps where run_id=$1 and kind in ('review','check')", [w.run_id])).toBe(0);
}

describe("D1c-2 E11 actual PostgreSQL event concurrency", () => {
  for (const finish of ["commit", "rollback"] as const) {
    it(`same event waits for ${finish}, then commits exactly one application`, async () => {
      const w = await world();
      const event = envelope(w, "accepted");
      await a.query("begin");
      await b.query("begin");
      expect(await apply(a, w.user, event)).toMatchObject({ status: "applied", applied: true });
      const waiting = apply(b, w.user, event);
      await waitForLockWait();
      await a.query(finish);
      expect(await waiting).toMatchObject({ status: finish === "commit" ? "duplicate" : "applied", applied: finish !== "commit" });
      await b.query("commit");
      expect(await f.count("select 1 from public.execution_events where run_id=$1 and external_event_id=$2", [w.run_id, event.event_id])).toBe(1);
      expect(await f.q("select state from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual([{ state: "accepted" }]);
      expect(await f.q("select state, version from public.execution_steps where id=$1", [w.step_id])).toEqual([{ state: "called", version: 2 }]);
    });
  }
  for (const first of ["accepted", "turn_completed"] as const) {
    it(`${first} first: concurrent completion/acceptance settles called and idle without reopening the task`, async () => {
      const w = await world();
      await a.query("begin");
      await b.query("begin");
      await apply(a, w.user, envelope(w, first));
      const waiting = apply(b, w.user, envelope(w, first === "accepted" ? "turn_completed" : "accepted"));
      await waitForLockWait();
      await a.query("commit");
      await waiting;
      await b.query("commit");
      await expectFinished(w);
      expect(await f.count("select 1 from public.execution_events where run_id=$1 and type='agent'", [w.run_id])).toBe(2);
    });
  }
  for (const [eventFirst, otherConversation] of [[true, false], [false, false], [true, true], [false, true]]) {
    it(`start_agent_turn versus completion, event first=${eventFirst}, other conversation=${otherConversation}: serializes and starts turn 2 once`, async () => {
      const w = await world();
      if (otherConversation) {
        await f.updateRow("conversation_messages", w.nextMessage, { delivery_state: "cancelled" });
        const conversation = await f.agentConversation(w.user, w.connection, w.session);
        w.nextMessage = String((await f.post(w.user, conversation, randomUUID(), "same session elsewhere")).message_id);
      }
      await a.query("begin");
      await b.query("begin");
      if (eventFirst) await apply(a, w.user, envelope(w, "turn_completed"));
      else expect(await start(a, w.user, w.nextMessage)).toMatchObject({ status: "queued" });
      const waiting = eventFirst ? start(b, w.user, w.nextMessage) : apply(b, w.user, envelope(w, "turn_completed"));
      await waitForLockWait();
      await a.query("commit");
      const result = await waiting;
      await b.query("commit");
      if (eventFirst) expect(result.status).toBe("started");
      else expect(await start(setup, w.user, w.nextMessage)).toMatchObject({ status: "started", turn_seq: 2 });
      expect(await f.q("select turn_seq, state from public.agent_tasks where agent_session_id=$1 order by turn_seq", [w.session])).toEqual([
        { turn_seq: 1, state: "idle" }, { turn_seq: 2, state: "dispatched" },
      ]);
    });
  }
  for (const type of ["message", "question"] as const) {
    for (const sharedMessage of [true, false]) {
      it(`${type} waits before session lock while start holds ${sharedMessage ? "the original message" : "the conversation"}: no lock inversion`, async () => {
        const w = await world();
        await apply(setup, w.user, envelope(w, "accepted"));
        await apply(setup, w.user, envelope(w, "progress"));
        const event = envelope(w, type, { text: "Agent text", ...(type === "question" ? { question: {
          provider_request_id: "thread:turn:item", kind: "input", structured: true,
          questions: [{ id: "choice", header: "Choose", text: "Which?", options: [], multi_select: false, allow_other: true, secret: false }],
        } } : {}) });
        // A caller retry may have requeued the original message while this turn is still live.
        if (sharedMessage) await f.updateRow("conversation_messages", w.message, { delivery_state: "queued" });
        await a.query("begin");
        await b.query("begin");
        // Hold the real start path's first lock, then let event ingestion reach it.
        await a.query(sharedMessage
          ? "select id from public.conversation_messages where id=$1 for update"
          : "select id from public.conversations where id=$1 for update", [sharedMessage ? w.message : w.conversation]);
        const waiting = apply(b, w.user, event);
        await waitForLockWait();
        expect(await start(a, w.user, sharedMessage ? w.message : w.nextMessage)).toMatchObject({ status: "queued" });
        await a.query("commit");
        expect(await waiting).toMatchObject({ status: "applied", applied: true });
        await b.query("commit");
        expect(await f.count("select 1 from public.conversation_messages where conversation_id=$1 and external_event_id=$2", [w.conversation, `agent-message:${w.run_id}:${createHash("sha256").update(String(event.event_id)).digest("hex")}`])).toBe(1);
        expect(await f.q("select state from public.agent_tasks where id=$1", [w.agent_task_id])).toEqual([{ state: type === "question" ? "awaiting_answer" : "running" }]);
      });
    }
  }
});

it("migration table locks fail NOWAIT while an ingestion transaction holds a table lock", async () => {
  const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations/20261116000000_agent_events.sql"), "utf8")
    .split("\n").filter((line) => !line.trim().startsWith("--")).join("\n");
  const locks = sql.match(/^lock table [^;]+;/gim) ?? [];
  expect(locks.map(statement => statement.match(/lock table\s+(public\.\w+)/i)![1])).toEqual(["public.execution_runs", "public.agent_tasks"]);
  for (const statement of locks) expect(statement).toMatch(/nowait/i);
  for (const statement of locks) {
    const table = statement.match(/lock table\s+(public\.\w+)/i)![1];
    await a.query("begin");
    await a.query(`select 1 from ${table} limit 1`);
    await b.query("begin");
    await b.query("set local lock_timeout='5s'");
    const attempt = b.query(statement).then(() => ({ code: "success" }), (error: { code: string }) => ({ code: error.code }));
    expect(await Promise.race([attempt, new Promise((resolve) => setTimeout(() => resolve({ code: "waited" }), 1000))])).toEqual({ code: "55P03" });
    await a.query("commit");
    await b.query("rollback");
  }
});

for (const type of ["progress", "message", "question", "artifact"] as const) {
  for (const activityFirst of [true, false]) {
  it(`unordered ${type} activityFirst=${activityFirst} acceptance versus low-seq accepted serializes monotonically`, async () => {
    const w=await world();
    const extra=type==="message"?{text:"Reply"}:type==="question"?{text:"Ask",question:{provider_request_id:"request",kind:"input",structured:true,questions:[{id:"q",header:"Question",text:"Which?",options:[],multi_select:false,allow_other:true,secret:false}]}}:type==="artifact"?{payload:{path:"x",hash:"h",summary:"s"}}:{};
    await a.query("begin");await b.query("begin");
    const activity = envelope(w,type,{seq:10,external_task_id:"provider-task",...extra});
    const accepted = envelope(w,"accepted",{seq:1,external_task_id:"provider-task"});
    expect(await apply(a,w.user,activityFirst ? activity : accepted)).toMatchObject({applied:true});
    const waiting=apply(b,w.user,activityFirst ? accepted : activity);
    await waitForLockWait();await a.query("commit");
    expect(await waiting).toMatchObject({status:activityFirst ? "ignored" : "applied",applied:!activityFirst});await b.query("commit");
    expect(await f.one(`select state,external_task_id,last_event_seq::int as seq from public.agent_tasks where id=$1`,[w.agent_task_id])).toEqual({state:type==="progress"?"running":type==="question"?"awaiting_answer":"accepted",external_task_id:"provider-task",seq:10});
    expect(await f.one(`select state,receipt from public.execution_steps where id=$1`,[w.step_id])).toMatchObject({state:"called",receipt:{ack_level:"agent",external_task_id:"provider-task"}});
  });
  }
}
for(const finish of ["commit","rollback"] as const){
  it(`external task identity race after ${finish} has one atomic binding`,async()=>{
    const w=await world();
    await a.query("begin");await b.query("begin");
    expect(await apply(a,w.user,envelope(w,"accepted",{external_task_id:"first"}))).toMatchObject({applied:true});
    const waiting=apply(b,w.user,envelope(w,"accepted",{external_task_id:"second"}));
    await waitForLockWait();await a.query(finish);
    expect(await waiting).toMatchObject({status:finish==="commit"?"conflict":"applied",applied:finish==="rollback"});await b.query("commit");
    const id=finish==="commit"?"first":"second";
    expect(await f.one(`select external_task_id from public.agent_tasks where id=$1`,[w.agent_task_id])).toEqual({external_task_id:id});
    expect(await f.one(`select receipt from public.execution_steps where id=$1`,[w.step_id])).toMatchObject({receipt:{external_task_id:id}});
    expect(await f.count(`select 1 from public.execution_events where run_id=$1 and type='agent'`,[w.run_id])).toBe(1);
  });
}

it("same-session external id collision between different tasks rolls back second acceptance",async()=>{
  const w=await world();
  await apply(setup,w.user,envelope(w,"turn_completed"));
  const next=await start(setup,w.user,w.nextMessage);
  expect(next.status).toBe("started");
  await f.updateRow("execution_steps",next.step_id,{state:"calling",lease_owner:"fixture"});
  const second={...w,...next};
  await a.query("begin");await b.query("begin");
  await apply(a,w.user,envelope(w,"accepted",{external_task_id:"shared"}));
  const waiting=apply(b,w.user,envelope(second,"accepted",{external_task_id:"shared"}));
  await waitForLockWait();await a.query("commit");
  expect(await waiting).toMatchObject({status:"conflict",applied:false});await b.query("commit");
  expect(await f.one(`select state,external_task_id from public.agent_tasks where id=$1`,[next.agent_task_id])).toEqual({state:"dispatched",external_task_id:null});
  expect(await f.one(`select state from public.execution_steps where id=$1`,[next.step_id])).toEqual({state:"calling"});
  expect(await f.count(`select 1 from public.execution_events where run_id=$1 and payload->>'agent_task_id'=$2 and type='agent'`,[next.run_id,next.agent_task_id])).toBe(0);
});
