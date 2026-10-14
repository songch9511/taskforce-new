import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { bridgeCommandFixtures } from "../db/bridge-commands.scenarios";
import { answerQuestionFixture } from "../db/agent-questions-stop.scenarios";
import { agentPathLeaseTests } from "../db/agent-path-leases.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// Written only in OA D3c-2; the coordinator runs these against disposable PostgreSQL.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL.");
const DB_NAME = `taskforce_path_leases_${process.pid}_${Date.now()}`;
let admin: pg.Client, setup: pg.Client, a: pg.Client, b: pg.Client;
let aPid: number, bPid: number;
async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '10s'");
  return client;
}
beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(DB_NAME); b = await connect(DB_NAME);
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);
afterEach(async () => {
  await a?.query("rollback").catch(() => {});
  await b?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) { await admin.query(`drop database if exists ${DB_NAME} with (force)`); await admin.end(); }
});
const db = (client: () => pg.Client): (() => ConversationAgentDb) => () => ({
  query: async (sql, params) => (await client().query(sql, params)).rows,
  asUser: async (user, fn) => {
    await client().query("set role authenticated");
    await client().query("select set_config('request.jwt.claim.sub',$1,false)", [user]);
    try { return await fn(); } finally {
      await client().query("reset role");
      await client().query("select set_config('request.jwt.claim.sub','',false)");
    }
  },
});
const f = bridgeCommandFixtures(db(() => setup));
const fa = bridgeCommandFixtures(db(() => a)), fb = bridgeCommandFixtures(db(() => b));
describe("agent path lease behavior on PostgreSQL", () => { agentPathLeaseTests(db(() => setup)); });
type World = Awaited<ReturnType<typeof f.world>>;
type Decision = { status: string; decision?: string; reason?: string; lease_ids?: string[] };
const pending = <T,>(promise: Promise<T>) => promise.then(value => ({ value }), error => ({ error }));
async function resolved<T>(promise: ReturnType<typeof pending<T>>) {
  const result = await promise; if ("error" in result) throw result.error; return result.value;
}
async function expectBWaitsForA() {
  for (let i = 0; i < 100; i++) {
    const rows = (await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [bPid])).rows;
    if (rows[0].blockers.includes(aPid)) {
      expect((await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [aPid])).rows[0].blockers).toEqual([]);
      return;
    }
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  throw new Error("Expected B to wait for A without reciprocal blocking");
}
async function world(adapter = "agent:codex", mode = "auto") {
  const w = await f.world();
  if (adapter !== "agent:codex") await f.updateRow("agent_connections", w.connection, { adapter });
  await f.lease(w);
  await f.bridgeEvent(w, f.event(w, "accepted", { adapter }));
  await f.updateRow("agent_sessions", w.session, { workspace_ref: "/w/proj", external_session_id: randomUUID() });
  await f.q("update public.execution_policies set mode=$2 where user_id=$1", [w.user, mode]);
  return { ...w, mode };
}
async function peer(w: World, adapter = "agent:codex") {
  const conversation = await f.agentConversation(w.user, w.connection);
  const message = String((await f.post(w.user, conversation, randomUUID(), "Independent task")).message_id);
  const turn = await f.start(w.user, message);
  expect(turn.status).toBe("started");
  const task = turn.agent_task_id!, run = turn.run_id!, step = turn.step_id!, action = turn.action_id!;
  const session = String((await f.one("select agent_session_id from public.agent_tasks where id=$1", [task])).agent_session_id);
  const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [step])).id);
  const second = { ...w, conversation, message, task, run, step, action, session, command, turn: turn.turn_seq! };
  await f.lease(second);
  await f.bridgeEvent(second, f.event(second, "accepted", { adapter }));
  await f.updateRow("agent_sessions", session, { workspace_ref: "/w/proj", external_session_id: randomUUID() });
  return second;
}
async function decide(client: pg.Client, w: World, paths = ["pricing.mdx"], reserve = false) {
  const decision = {
    decision: reserve ? "defer" : "allow", reason: reserve ? "manual_write" : "policy_auto",
    call_kind: "codex_file_change", access: "write", request_id: "request",
    workspace_real_path: "/w/proj", targets: paths.map(rel_path => ({ real_path: `/w/proj/${rel_path}`, rel_path })),
    lease_op: reserve ? "reserve" : "acquire", card_flags: [], server_ms: 0,
  };
  return (await client.query<{ result: Decision }>("select public.decide_agent_tool_call($1,$2,$3,$4,$5,$6,$7::jsonb) as result",
    [w.user, w.bridge, w.session, w.task, w.turn, w.mode, JSON.stringify(decision)])).rows[0].result;
}
const active = (w: World) => f.q("select run_id,path_key from public.agent_path_leases where user_id=$1 and released_at is null order by path_key", [w.user]);
async function artifact(client: pg.Client, w: World, file = "pricing.mdx") {
  return client.query("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,$5,'hash','')",
    [w.user, w.run, w.task, w.turn, file]);
}
async function answer(client: pg.Client, w: World, value: "allow" | "deny") {
  return (await client.query<{ result: { status: string } }>("select public.answer_agent_approval($1,$2,'request',$3::jsonb) as result",
    [w.user, w.task, JSON.stringify({ approval: value })])).rows[0].result;
}
async function stopConflict(client: pg.Client, w: World, lease: string) {
  return (await client.query<{ result: { status: string } }>("select public.stop_agent_run_for_path_conflict($1,$2) as result", [w.user, lease])).rows[0].result;
}

describe("agent path lease concurrency", () => {
  it.each([false, true])("P1 two Auto writes have exactly one owner, reversed=%s", async reverse => {
    const first = await world(), second = await peer(first);
    const [holder, waiter] = reverse ? [second, first] : [first, second];
    await a.query("begin"); await b.query("begin");
    expect(await decide(a, holder)).toMatchObject({ decision: "allow" });
    const next = pending(decide(b, waiter));
    await expectBWaitsForA(); await a.query("commit");
    expect(await resolved(next)).toMatchObject({ decision: "deny", reason: "path_in_use" });
    await b.query("commit");
    expect(await active(first)).toEqual([{ run_id: holder.run, path_key: "/w/proj/pricing.mdx" }]);
  });

  it("P2 reversed Codex target sets serialize in path-key order without partial reservations", async () => {
    // The bridge rate bucket also serializes these calls; the static guard test proves key ordering.
    const first = await world("agent:codex", "manual"), second = await peer(first, "agent:codex");
    await a.query("begin"); await b.query("begin");
    expect(await decide(a, first, ["a", "b"], true)).toMatchObject({ decision: "defer", reason: "manual_write" });
    const next = pending(decide(b, second, ["b", "a"], true));
    await expectBWaitsForA(); await a.query("commit");
    expect(await resolved(next)).toMatchObject({ decision: "deny", reason: "path_in_use" });
    await b.query("commit");
    expect(await active(first)).toEqual(["a", "b"].map(file => ({ run_id: first.run, path_key: `/w/proj/${file}` })));
  });

  it.each(["stop", "done"])("P3 decision first then %s releases every lease", async end => {
    const w = await world(); await a.query("begin"); await b.query("begin");
    expect(await decide(a, w)).toMatchObject({ decision: "allow" });
    const next = pending<unknown>(end === "stop" ? fb.stop(w.user, w.session) : fb.done(w.user, w.action));
    await expectBWaitsForA(); await a.query("commit"); await resolved(next); await b.query("commit");
    expect(await active(w)).toEqual([]);
    expect((await f.one("select state from public.execution_runs where id=$1", [w.run])).state).toBe("stopped");
  });
  it.each(["stop", "done"])("P3 %s first makes waiting decision not_live", async end => {
    const w = await world(); await a.query("begin"); await b.query("begin");
    if (end === "stop") await fa.stop(w.user, w.session); else await fa.done(w.user, w.action);
    const next = pending(decide(b, w));
    await expectBWaitsForA(); await a.query("commit");
    expect(await resolved(next)).toMatchObject({ decision: "deny", reason: "not_live" });
    await b.query("commit"); expect(await active(w)).toEqual([]);
  });

  it("P4 decision before Open in Terminal is released by the session trigger", async () => {
    const w = await world(); await a.query("begin"); await b.query("begin");
    expect(await decide(a, w)).toMatchObject({ decision: "allow" });
    await a.query("update public.agent_tasks set state='idle' where id=$1", [w.task]);
    const next = pending(b.query<{ result: { status: string } }>("select public.open_agent_session_external($1,$2) as result", [w.user, w.session]));
    await expectBWaitsForA(); await a.query("commit");
    expect((await resolved(next)).rows[0].result.status).toBe("external"); await b.query("commit");
    expect(await active(w)).toEqual([]);
    expect((await f.one("select release_reason from public.agent_path_leases where run_id=$1", [w.run])).release_reason).toBe("session_external");
  });
  it("P4 Open in Terminal first cannot acquire an external-session lease", async () => {
    const w = await world(); await f.updateRow("agent_tasks", w.task, { state: "idle" });
    await a.query("begin"); await b.query("begin");
    await a.query("select public.open_agent_session_external($1,$2)", [w.user, w.session]);
    const next = pending(decide(b, w)); await expectBWaitsForA(); await a.query("commit");
    expect(await resolved(next)).toMatchObject({ decision: "deny", reason: "not_live" });
    await b.query("commit"); expect(await active(w)).toEqual([]);
  });

  it.each(["accepted", "running", "awaiting_answer"].flatMap(liveState => ["renewal", "sweep"].map(first => ({ liveState, first }))))("P5 $liveState renewal with $first first keeps expiry consistent", async ({ liveState, first }) => {
    const w = await world(); await decide(setup, w);
    await f.updateRow("agent_tasks", w.task, { state: "idle" });
    if (liveState === "awaiting_answer") await f.updateRow("agent_tasks", w.task, {
      pending_question: { ...answerQuestionFixture(), question_key: [w.task, "request"], asked_at: "2026-10-13T12:00:00Z" },
    });
    await f.q("update public.agent_path_leases set expires_at=public.db_now()-interval '1 second' where run_id=$1", [w.run]);
    await a.query("begin"); await b.query("begin");
    if (first === "renewal") {
      await a.query("update public.agent_tasks set state=$2 where id=$1", [w.task, liveState]);
      await b.query("select public.sweep_agent_path_leases(500)");
      await a.query("commit"); await b.query("commit");
      expect(await active(w)).toHaveLength(1);
      expect((await f.one("select expires_at from public.agent_path_leases where run_id=$1", [w.run])).expires_at).toBeNull();
    } else {
      await a.query("select public.sweep_agent_path_leases(500)");
      const next = pending(b.query("update public.agent_tasks set state=$2 where id=$1", [w.task, liveState]));
      await expectBWaitsForA(); await a.query("commit"); await resolved(next); await b.query("commit");
      expect(await active(w)).toEqual([]);
    }
    expect((await f.state(w)).state).toBe(liveState);
  });

  it("P5 first event of a new turn can be progress and renews the prior lease", async () => {
    const w = await world();
    const lease = (await decide(setup, w)).lease_ids![0];
    expect(await f.bridgeEvent(w, f.event(w, "turn_completed"))).toMatchObject({ task_state: "idle" });
    expect((await f.one("select expires_at from public.agent_path_leases where id=$1", [lease])).expires_at).not.toBeNull();
    const message = String((await f.post(w.user, w.conversation, randomUUID(), "Continue work")).message_id);
    const turn = await f.start(w.user, message);
    expect(turn).toMatchObject({ status: "started", run_id: w.run });
    const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [turn.step_id])).id);
    const next = { ...w, message, task: turn.agent_task_id!, step: turn.step_id!, turn: turn.turn_seq!, command };
    expect(await f.lease(next)).toMatchObject({ status: "leased" });
    expect(await f.bridgeEvent(next, f.event(next, "progress"))).toMatchObject({ status: "applied", task_state: "running" });
    expect(await f.one("select expires_at,released_at from public.agent_path_leases where id=$1", [lease])).toEqual({ expires_at: null, released_at: null });
  });

  it.each(["decision", "artifact"])("P6 %s first produces one owner and a conflict or yield", async first => {
    const holder = await world(), later = await peer(holder);
    await a.query("begin"); await b.query("begin");
    if (first === "decision") {
      await decide(a, holder);
      const next = pending(artifact(b, later)); await expectBWaitsForA(); await a.query("commit");
      await resolved(next); await b.query("commit");
      expect((await f.one("select conflict_run_id from public.agent_path_leases where run_id=$1", [holder.run])).conflict_run_id).toBe(later.run);
    } else {
      await artifact(a, later);
      const next = pending(decide(b, holder)); await expectBWaitsForA(); await a.query("commit");
      expect(await resolved(next)).toMatchObject({ decision: "deny", reason: "path_in_use" }); await b.query("commit");
    }
    expect(await active(holder)).toHaveLength(1);
  });

  it.each(["allow", "deny"] as const)("P7 approval %s first then Stop leaves no orphan lease", async value => {
    const w = await world("agent:codex", "manual"); await decide(setup, w, ["pricing.mdx"], true);
    await f.bridgeEvent(w, f.event(w, "question", { question: answerQuestionFixture({ id: "approval" }, { kind: "approval" }), text: "Approval" }));
    await a.query("begin"); await b.query("begin"); expect(await answer(a, w, value)).toMatchObject({ status: "answered" });
    const next = pending(fb.stop(w.user, w.session)); await expectBWaitsForA(); await a.query("commit"); await resolved(next); await b.query("commit");
    expect(await active(w)).toEqual([]);
  });
  it("P7 Stop first makes a waiting approval stale and keeps the reservation released", async () => {
    const w = await world("agent:codex", "manual"); await decide(setup, w, ["pricing.mdx"], true);
    await f.bridgeEvent(w, f.event(w, "question", { question: answerQuestionFixture({ id: "approval" }, { kind: "approval" }), text: "Approval" }));
    await a.query("begin"); await b.query("begin"); await fa.stop(w.user, w.session);
    const next = pending(answer(b, w, "allow")); await expectBWaitsForA(); await a.query("commit");
    expect(await resolved(next)).toMatchObject({ status: "question_stale" }); await b.query("commit"); expect(await active(w)).toEqual([]);
  });

  it("P8 run no-key-update lock returns defer/server_busy within one second", async () => {
    const w = await world(); await a.query("begin");
    await a.query("select id from public.execution_runs where id=$1 for no key update", [w.run]);
    const started = performance.now(); const result = await decide(b, w); const elapsed = performance.now() - started;
    expect(result).toMatchObject({ status: "decided", decision: "defer", reason: "server_busy" });
    expect(elapsed).toBeGreaterThanOrEqual(200); expect(elapsed).toBeLessThan(1000);
    await a.query("rollback"); expect(await active(w)).toEqual([]);
  });

  it.each(["done", "stop"])("P9 conflict stop first versus %s stops the run once without deadlock", async end => {
    const holder = await world(), later = await peer(holder);
    const lease = (await decide(setup, holder)).lease_ids![0]; await artifact(setup, later);
    await a.query("begin"); await b.query("begin");
    expect(await stopConflict(a, later, lease)).toMatchObject({ status: "stopped" });
    const next = pending<unknown>(end === "done" ? fb.done(later.user, later.action) : fb.stop(later.user, later.session));
    await expectBWaitsForA(); await a.query("commit"); await resolved(next); await b.query("commit");
    expect(await stopConflict(setup, later, lease)).toMatchObject({ status: "noop" });
    expect((await f.one("select state from public.execution_runs where id=$1", [later.run])).state).toBe("stopped");
  });
  it.each(["done", "stop"])("P9 %s first makes the waiting conflict stop a noop", async end => {
    const holder = await world(), later = await peer(holder);
    const lease = (await decide(setup, holder)).lease_ids![0]; await artifact(setup, later);
    await a.query("begin"); await b.query("begin");
    if (end === "done") await fa.done(later.user, later.action); else await fa.stop(later.user, later.session);
    const next = pending(stopConflict(b, later, lease));
    await expectBWaitsForA(); await a.query("commit");
    expect(await resolved(next)).toMatchObject({ status: "noop" }); await b.query("commit");
    expect((await f.one("select state from public.execution_runs where id=$1", [later.run])).state).toBe("stopped");
    expect((await f.one("select conflict_stop_at from public.agent_path_leases where id=$1", [lease])).conflict_stop_at).toBeNull();
    const notices = (await f.one("select public.list_path_lease_notices(500) result")).result as { lease_id: string; originating_only: boolean }[];
    expect(notices.filter(notice => notice.lease_id === lease && notice.originating_only)).toEqual([]);
  });
  it("P9 an unrelated Action row lock cannot block conflict stop", async () => {
    const holder = await world(), later = await peer(holder);
    const lease = (await decide(setup, holder)).lease_ids![0]; await artifact(setup, later);
    await a.query("begin"); await a.query("select id from public.actions where id=$1 for update", [later.action]);
    await b.query("begin"); await b.query("set local lock_timeout='500ms'");
    expect(await stopConflict(b, later, lease)).toMatchObject({ status: "stopped" });
    await b.query("commit"); await a.query("commit");
    expect(await f.one("select state,stopped_at from public.execution_runs where id=$1", [later.run])).toEqual({ state: "stopped", stopped_at: null });
  });

  it("P11 two resolutions of one conflict version serialize and only one succeeds", async () => {
    const holder = await world(), later = await peer(holder);
    const lease = (await decide(setup, holder)).lease_ids![0];
    await artifact(setup, later);
    const version = (await f.one("select conflict_version from public.agent_path_leases where id=$1", [lease])).conflict_version;
    expect(Number.isInteger(Number(version))).toBe(true);
    await a.query("begin"); await b.query("begin");
    const sql = "select public.resolve_path_conflict($1,$2,$3,$4) result";
    expect((await a.query(sql, [holder.user, lease, "holder", version])).rows[0].result).toMatchObject({ status: "resolved" });
    const next = pending(b.query(sql, [holder.user, lease, "later", version]));
    await expectBWaitsForA(); await a.query("commit");
    expect((await resolved(next)).rows[0].result).toMatchObject({ status: "stale" });
    await b.query("commit");
    expect(await active(holder)).toEqual([{ run_id: holder.run, path_key: "/w/proj/pricing.mdx" }]);
    expect((await f.one("select conflict_run_id from public.agent_path_leases where id=$1", [lease])).conflict_run_id).toBeNull();
    expect(await f.q("select id from public.metric_events where user_id=$1 and type='path_conflict_resolved'", [holder.user])).toHaveLength(1);
  });

  it("P12 a conflict version changed during the run-lock wait cannot receive the old stop marker", async () => {
    const holder = await world(), later = await peer(holder);
    const lease = (await decide(setup, holder)).lease_ids![0];
    await artifact(setup, later);
    const before = await f.one("select conflict_run_id,conflict_version from public.agent_path_leases where id=$1", [lease]);
    await a.query("begin"); await b.query("begin");
    await a.query("select id from public.execution_runs where id=$1 for no key update", [later.run]);
    const next = pending(stopConflict(b, later, lease));
    await expectBWaitsForA();
    await a.query("update public.agent_path_leases set conflict_version=conflict_version+1 where id=$1", [lease]);
    await a.query("commit");
    expect(await resolved(next)).toMatchObject({ status: "stopped" });
    await b.query("commit");
    expect(await f.one("select conflict_run_id,conflict_version,conflict_stop_at,release_notified_at from public.agent_path_leases where id=$1", [lease])).toEqual({
      conflict_run_id: later.run, conflict_version: Number(before.conflict_version) + 1, conflict_stop_at: null, release_notified_at: null,
    });
    expect((await f.one("select state from public.execution_runs where id=$1", [later.run])).state).toBe("stopped");
  });

  it.each(["rate_limit_events", "metric_events", "agent_sessions", "execution_runs", "agent_tasks", "agent_artifacts", "bridges"])("P10 migration fails NOWAIT on a conflicting %s lock", async table => {
    const sql = await readFile(path.join(process.cwd(), "supabase/migrations/20261123000000_agent_path_leases.sql"), "utf8");
    const prefix = sql.slice(0, sql.indexOf("create table public.agent_path_leases"));
    expect(prefix).toMatch(/lock table public\.rate_limit_events, public\.metric_events in access exclusive mode nowait/i);
    expect(prefix).toMatch(/lock table public\.bridges, public\.agent_sessions, public\.execution_runs, public\.agent_tasks, public\.agent_artifacts in share row exclusive mode nowait/i);
    await a.query("begin");
    await a.query(`lock table public.${table} in ${["rate_limit_events", "metric_events"].includes(table) ? "access share" : "row exclusive"} mode`);
    await expect(b.query(prefix)).rejects.toMatchObject({ code: "55P03" });
  });
});
