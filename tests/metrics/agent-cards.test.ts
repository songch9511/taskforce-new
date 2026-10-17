import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { AGENT_EVENTS } from "@/lib/metrics/agents";
import { loadAgentMetrics, type AgentMetrics } from "@/lib/metrics/load";

import { createCoordinatorDb } from "../coordinator/support";
import { sqlAdmin, type Query } from "../conversation/sql-admin";
import { agentPathLeaseFixtures } from "../db/agent-path-leases.scenarios";
import { answerQuestionFixture } from "../db/agent-questions-stop.scenarios";
import { answerLocalFixtures } from "../db/answer-local.scenarios";
import { asUser } from "../db/local-supabase";

// OA I-oa 7.3: 실제 마이그레이션(PGlite) 위에서 운영 TS(loadAgentMetrics)를 그대로 돌려, 에이전트 이벤트가 남긴 행이 카드 넷에 맞게 들어오는지 본다.
// 오라클은 계약 4장의 SQL 명세(percentile_disc · 짝 맞추기)를 직접 돌린 값이다: TS 계산(nearest-rank)과 같은 값이어야 한다.
// 시계: db_now()를 실제 now()로 둔다 (단계의 created_at = now() · 사건의 at = db_now()가 같은 시계가 되게).

const CANARY = { message: "CANARY_IOA_MESSAGE_9f2c", question: "CANARY_IOA_QUESTION_9f2c", answer: "CANARY_IOA_ANSWER_9f2c", summary: "CANARY_IOA_SUMMARY_9f2c", path: "CANARY_IOA_PATH_9f2c" };

let db: PGlite;
let admin: SupabaseClient;
let x: ReturnType<typeof answerLocalFixtures>;
let p: ReturnType<typeof agentPathLeaseFixtures>;
let report: AgentMetrics;
let logged: string;
let period: { from: Date; to: Date };

const rows = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows;

/**
 * PostgREST의 JSON 경로 문법(alias:col->>key · col->>key · col->key)을 같은 뜻의 SQL로 옮기는 시험용 덮개.
 * 운영 코드는 PostgREST 문법으로 select · 필터를 쓰고, sql-admin은 그 글자를 SQL에 그대로 넣기 때문에 JSON 경로만 옮겨 준다.
 */
function postgrestJson(query: Query): Query {
  const quote = (path: string) => path.replace(/(->>?)(\w+)/g, "$1'$2'");
  return (sql, params) => {
    const split = sql.indexOf(" from public.");
    if (!sql.startsWith("select ") || split < 0) return query(sql, params);
    const columns = sql
      .slice("select ".length, split)
      .split(", ")
      .map((column) => {
        const match = /^(?:(\w+):)?(\w+)((?:->>?\w+)+)$/.exec(column);
        if (!match) return column;
        const [, alias, base, path] = match;
        const last = [...path.matchAll(/->>?(\w+)/g)].pop()![1];
        return `${base}${quote(path)} as ${alias ?? last}`;
      });
    const rest = sql.slice(split).replace(/(\w+)((?:->>?\w+)+)/g, (_all, base: string, path: string) => `${base}${quote(path)}`);
    return query(`select ${columns.join(", ")}${rest}`, params);
  };
}

beforeAll(async () => {
  db = await createCoordinatorDb();
  await db.query("select set_config('app.now', '', false)");
  admin = sqlAdmin(postgrestJson(async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows));
  const handle = () => ({ query: async (sql: string, params?: unknown[]) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: <T>(user: string, fn: () => Promise<T>) => asUser(db, user, fn) });
  x = answerLocalFixtures(handle);
  p = agentPathLeaseFixtures(handle);
}, 120_000);
afterAll(() => db.close());
afterEach(() => vi.restoreAllMocks());

/** 메시지를 보내(전달 시작) Mac이 집어 가고(lease) 접수(accepted)한 대화 하나 */
async function acceptedWorld() {
  const w = await x.world();
  expect((await x.lease(w)).status).toBe("leased");
  await x.apply(w.user, x.event(w, "accepted"));
  return w;
}

const answerRecorded = async (user: string, task: string, answers: unknown) =>
  (await x.one("select public.answer_agent_question_recorded($1,$2,'request',$3::jsonb,false,null) as result", [user, task, JSON.stringify(answers)])).result as { status: string };

describe("E1 발생 → 카드: 남은 행 수와 카드 값이 같다", () => {
  beforeAll(async () => {
    // 1) 보내기 → lease → 접수 → 턴 끝, 그리고 Stop
    const a = await acceptedWorld();
    await x.apply(a.user, x.event(a, "turn_completed"));
    const b = await acceptedWorld();
    await x.stop(b.user, b.session);
    // 2) 질문 셋: 카드 답(route) · 자유 글 답(지표 0) · 비밀값 로컬 답. 글 카나리를 질문 · 메시지 · 답에 넣는다
    const route = await x.questionWorld(answerQuestionFixture({ allow_other: true, header: CANARY.question, text: CANARY.question }));
    expect((await answerRecorded(route.user, route.task, { choice: CANARY.answer })).status).toBe("answered");
    const free = await x.questionWorld(answerQuestionFixture({ allow_other: true }));
    const freeMessage = String((await x.post(free.user, free.conversation, randomUUID(), CANARY.message)).message_id);
    expect((await x.route(free.user, freeMessage)).status).toBe("answered");
    const secret = await x.secretWorld();
    expect((await x.local(secret)).status).toBe("answered");
    // 3) 답 없이 닫힌 질문(이슈 Done → run stopped gate action_closed)과 지금 열린 질문
    const closed = await x.questionWorld();
    await x.done(closed.user, closed.action);
    await x.questionWorld();
    // 4) 충돌: 한 이슈가 path를 쥐고 다른 이슈의 산출물이 건드려 멈춘 뒤 해소 (path_conflict_found → path_conflict_resolved)
    const holder = await p.live();
    const decision = await p.decide(holder, { lease_op: "acquire", targets: [{ real_path: `/w/proj/${CANARY.path}.mdx`, rel_path: `${CANARY.path}.mdx` }] });
    expect(decision.status).toBe("decided");
    const later = await p.competitor(holder);
    await p.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,$5,'hash',$6)", [later.user, later.run, later.task, later.turn, `${CANARY.path}.mdx`, CANARY.summary]);
    const lease = (await p.leases(holder.run))[0];
    expect(lease.conflict_run_id).toBe(later.run);
    await p.one("select public.stop_agent_run_for_path_conflict($1,$2) result", [holder.user, lease.id]);
    await p.one("select public.resolve_path_conflict($1,$2,'holder',$3) result", [holder.user, lease.id, lease.conflict_version]);

    period = { from: new Date(Date.now() - 3_600_000), to: new Date(Date.now() + 3_600_000) };
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    const out = vi.spyOn(console, "log").mockImplementation(() => {});
    report = await loadAgentMetrics(admin, period);
    logged = JSON.stringify([log.mock.calls, info.mock.calls, out.mock.calls]);
    vi.restoreAllMocks();
  }, 240_000);

  it("읽기가 모두 성공해 카드 넷이 있다 (로그 0)", () => {
    expect(report.usage).not.toBeNull();
    expect(report.delivery).not.toBeNull();
    expect(report.questions).not.toBeNull();
    expect(report.stops).not.toBeNull();
    expect(logged).toBe("[[],[],[]]");
  });

  it("① type별 수 · 사용자 수가 metric_events와 같고, 질문 답 셋과 충돌이 보인다", async () => {
    const usage = report.usage!;
    for (const spec of AGENT_EVENTS) {
      const [oracle] = await rows<{ n: number; users: number }>("select count(*)::int n, count(distinct user_id)::int users from public.metric_events where type = $1", [spec.type]);
      const card = usage.types.find((t) => t.type === spec.type)!;
      expect([spec.type, card.n, card.users]).toEqual([spec.type, oracle.n, oracle.users]);
    }
    const n = (type: string) => usage.types.find((t) => t.type === type)!;
    expect(n("agent_message_sent").n).toBeGreaterThanOrEqual(8);
    // 질문 답 지표는 route 답 하나 + 비밀값 로컬 답 하나 (자유 글 답은 지표 0)
    expect(n("question_answered").n).toBe(2);
    expect(n("question_answered").dims.find((d) => d.key === "answered_locally")!.values).toEqual([
      { value: "(없음)", n: 1 },
      { value: "true", n: 1 },
    ]);
    expect(n("stop_requested").n).toBe(1);
    expect(n("tool_call_decided").n).toBe(1);
    expect(n("path_conflict_found").n).toBe(1);
    expect(n("path_conflict_resolved")).toMatchObject({ n: 1 });
    expect(n("path_conflict_resolved").dims[0].values).toEqual([{ value: "holder", n: 1 }]);
    expect(n("tool_call_decided").numeric!.n).toBe(1);
    // 모르는 type 0 · assistant_opened는 남기는 곳이 없어 0
    expect(usage.unknown).toEqual({ types: 0, events: 0 });
    expect(n("assistant_opened").n).toBe(0);
    expect(usage.empty).toBe(false);
  });

  it("에이전트에게 맡겨 생긴 이슈(user_created · rule assistant_agent) 수가 action_events와 같다", async () => {
    const [oracle] = await rows<{ n: number; users: number }>("select count(*)::int n, count(distinct user_id)::int users from public.action_events where type = 'user_created' and rule = 'assistant_agent'");
    expect(oracle.n).toBeGreaterThan(0);
    expect(report.usage!.agentIssues).toEqual(oracle);
  });

  it("② 지연: 단계 수 · 집어 간 수 · 접수 수 · 대기 수가 단계 사건과 같고, p50 · p95가 SQL 명세(percentile_disc)와 같다", async () => {
    const groups = report.delivery!.groups;
    const oracle = await rows<{ kind: string; adapter: string; n: number; leased: number; accepted: number; waiting: number; never_leased: number; lease_p50: number | null; lease_p95: number | null; accept_p50: number | null; accept_p95: number | null; le3: number }>(
      `with s as (
         select s.id, s.provider as adapter, s.created_at,
                case when s.kind = 'agent_cancel' then 'cancel' when s.purpose like 'answer:%' then 'answer' else 'message' end as kind
           from public.execution_steps s join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id
          where r.kind = 'conversation' and s.kind in ('agent_message','agent_cancel')
       ), e as (
         select step_id,
                min(at) filter (where to_state = 'calling' and gate = 'bridge_lease') as leased_at,
                min(at) filter (where to_state = 'called') as called_at,
                min(at) filter (where to_state in ('failed','skipped')) as ended_at
           from public.execution_events where type = 'step' and step_id in (select id from s) group by step_id
       )
       select kind, adapter, count(*)::int as n, count(leased_at)::int as leased, count(called_at)::int as accepted,
              count(*) filter (where leased_at is null and ended_at is null)::int as waiting,
              count(*) filter (where leased_at is null and ended_at is not null)::int as never_leased,
              (percentile_disc(0.5) within group (order by extract(epoch from leased_at - created_at)))::float8 as lease_p50,
              (percentile_disc(0.95) within group (order by extract(epoch from leased_at - created_at)))::float8 as lease_p95,
              (percentile_disc(0.5) within group (order by extract(epoch from called_at - created_at)))::float8 as accept_p50,
              (percentile_disc(0.95) within group (order by extract(epoch from called_at - created_at)))::float8 as accept_p95,
              count(*) filter (where leased_at - created_at <= interval '3 s')::int as le3
         from s left join e on e.step_id = s.id group by 1, 2 order by 1, 2`,
    );
    expect(oracle.length).toBeGreaterThan(0);
    // 카드는 message → answer → cancel 순서 (SQL은 글자 순서라 같은 순서로 맞춘다)
    const order = ["message", "answer", "cancel"];
    oracle.sort((a, b) => order.indexOf(a.kind) - order.indexOf(b.kind) || (a.adapter < b.adapter ? -1 : 1));
    expect(groups.map((g) => [g.kind, g.adapter])).toEqual(oracle.map((o) => [o.kind, o.adapter]));
    const near = (actual: number | null, expected: number | null) => {
      if (expected === null) expect(actual).toBeNull();
      else expect(Math.abs(actual! - expected)).toBeLessThan(0.002);
    };
    for (const [i, g] of groups.entries()) {
      const o = oracle[i];
      expect(g).toMatchObject({ n: o.n, waiting: o.waiting, neverLeased: o.never_leased, anomalies: 0 });
      expect([g.lease.n, g.accept.n]).toEqual([o.leased, o.accepted]);
      expect(g.buckets.le3).toBe(o.le3);
      near(g.lease.p50, o.lease_p50);
      near(g.lease.p95, o.lease_p95);
      near(g.accept.p50, o.accept_p50);
      near(g.accept.p95, o.accept_p95);
    }
    // 메시지 단계는 집어 가고 접수까지 갔다 (lease 때 gate bridge_lease, 접수 때 called)
    expect(groups.find((g) => g.kind === "message")!.lease.n).toBeGreaterThanOrEqual(1);
    expect(groups.find((g) => g.kind === "message")!.accept.n).toBeGreaterThanOrEqual(1);
    // 답 단계가 셋(route · 자유 글 · 로컬)
    expect(groups.find((g) => g.kind === "answer")!.n).toBe(3);
  });

  it("② 전달 결과: 대화 메시지의 전달 상태별 수가 conversation_messages와 같다", async () => {
    const oracle = await rows<{ state: string; n: number }>("select delivery_state as state, count(*)::int n from public.conversation_messages where delivery_state is not null group by 1");
    const byState = new Map<string, number>();
    for (const r of report.delivery!.results) byState.set(r.state, (byState.get(r.state) ?? 0) + r.n);
    expect(Object.fromEntries(byState)).toEqual(Object.fromEntries(oracle.map((o) => [o.state, o.n])));
    const commands = await rows<{ kind: string; outcome: string | null; n: number }>("select kind, outcome, count(*)::int n from public.bridge_commands group by 1, 2");
    const sum = (list: { n: number }[]) => list.reduce((total, r) => total + r.n, 0);
    expect(sum(report.delivery!.commands)).toBe(sum(commands));
    expect(report.delivery!.commandsClamped).toBe(false);
  });

  it("③ 질문 → 답: 길 셋 각 1 · 열린 질문 1 · 답 없이 닫힘 1, 기다린 시간이 SQL 명세와 같다", async () => {
    const card = report.questions!;
    const path = (name: string) => card.groups.filter((g) => g.path === name).reduce((total, g) => total + g.n, 0);
    expect({ route: path("route"), message: path("message"), local: path("local"), open: path("unanswered_open"), closed: path("unanswered_closed") }).toEqual({ route: 1, message: 1, local: 1, open: 1, closed: 1 });
    expect(card.asked).toBe(5);
    expect(card.anomalies).toBe(0);
    const oracle = await rows<{ path: string; n: number; wait_p50: number | null; wait_p95: number | null }>(
      `with q as (
         select e.at as asked_at, e.payload->'question_key'->>0 as task_id, e.payload->'question_key'->>1 as request_id
           from public.execution_events e
          where e.type = 'agent' and e.payload->>'event_type' = 'question' and e.payload->>'status' = 'applied'
       ), a as (
         select s.args->>'agent_task_id' as task_id, s.args->>'provider_request_id' as request_id, min(s.created_at) as answered_at,
                bool_or(s.args->>'answer_message_id' is not null) as via_message, bool_or(s.args->>'answered_locally' = 'true') as local
           from public.execution_steps s where s.kind = 'agent_message' and s.purpose like 'answer:%' group by 1, 2
       )
       select case when a.task_id is null then 'unanswered' when a.local then 'local' when a.via_message then 'message' else 'route' end as path,
              count(*)::int as n,
              (percentile_disc(0.5) within group (order by extract(epoch from a.answered_at - q.asked_at)))::float8 as wait_p50,
              (percentile_disc(0.95) within group (order by extract(epoch from a.answered_at - q.asked_at)))::float8 as wait_p95
         from q left join a using (task_id, request_id) group by 1 order by 1`,
    );
    expect(Object.fromEntries(oracle.map((o) => [o.path, o.n]))).toEqual({ local: 1, message: 1, route: 1, unanswered: 2 });
    for (const o of oracle.filter((r) => r.path !== "unanswered")) {
      const g = card.groups.find((group) => group.path === o.path)!;
      expect(Math.abs(g.wait.p50! - o.wait_p50!)).toBeLessThan(0.002);
      expect(Math.abs(g.wait.p95! - o.wait_p95!)).toBeLessThan(0.002);
    }
    // 답 없음 둘: 지금 열린 질문(awaiting_answer) 하나와 Done으로 닫힌 하나
    const open = await rows<{ n: number }>("select count(*)::int n from public.agent_tasks where state = 'awaiting_answer' and pending_question is not null");
    expect(open[0].n).toBeGreaterThanOrEqual(1);
  });

  it("④ 멈춤: Done(action_closed) 1 · 충돌로 멈춤(path_conflict) 1 · 끝난 턴 · 지금 값이 행과 같고 열린 충돌은 0", async () => {
    const card = report.stops!;
    const oracle = await rows<{ gate: string | null; n: number }>(
      `select e.gate, count(*)::int n from public.execution_events e join public.execution_runs r on r.id = e.run_id and r.user_id = e.user_id
        where e.type = 'run' and e.to_state = 'stopped' and r.kind = 'conversation' group by 1`,
    );
    // Stop 버튼(stop_agent_session)은 작업을 취소하고 stop_run으로 run도 닫는다 (gate stop) — 계약 4.4의 "run은 닫지 않는다"는 틀렸다
    expect(Object.fromEntries(oracle.map((o) => [o.gate, o.n]))).toEqual({ stop: 1, action_closed: 1, path_conflict: 1 });
    expect(card.stopped).toEqual([
      { gate: "stop", n: 1 },
      { gate: "action_closed", n: 1 },
      { gate: "path_conflict", n: 1 },
      { gate: "session_deleted", n: 0 },
      { gate: "other", n: 0 },
    ]);
    const [turns] = await rows<{ n: number }>("select count(*)::int n from public.execution_events where type = 'agent' and payload->>'event_type' = 'turn_completed' and payload->>'status' = 'applied'");
    expect(turns.n).toBeGreaterThanOrEqual(1);
    expect(card.turnsCompleted).toBe(turns.n);
    const [counts] = await rows<{ unknown_outcome: number; unreachable: number; awaiting: number; conflicts: number }>(
      `select (select count(*)::int from public.execution_steps s join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id where r.kind = 'conversation' and s.kind in ('agent_message','agent_cancel') and s.state = 'unknown_outcome') as unknown_outcome,
              (select count(*)::int from public.agent_tasks where state = 'unreachable') as unreachable,
              (select count(*)::int from public.agent_tasks where state = 'awaiting_answer') as awaiting,
              (select count(*)::int from public.agent_path_leases where conflict_run_id is not null) as conflicts`,
    );
    const [overdue] = await rows<{ n: number }>("select public.count_overdue_agent_step_leases(5)::int n");
    expect(card.now).toEqual({ overdueLeases: overdue.n, unknownOutcome: counts.unknown_outcome, unreachable: counts.unreachable, awaitingAnswer: counts.awaiting, openConflicts: 0, oldestConflictAgeS: null });
    expect(counts.conflicts).toBe(0);
  });
});

describe("E2 글 카나리: 카드에도 로그에도 글이 없다", () => {
  it("메시지 · 질문 · 답 · 산출물 요약 · 경로에 넣은 카나리가 report와 로그에 0이다 (DB에는 있다)", async () => {
    // 카나리가 실제로 남아 있다 (시험이 비어 있지 않다)
    const stored = await rows<{ hits: number }>(
      `select (select count(*) from public.conversation_messages where text like '%' || $1 || '%')::int
            + (select count(*) from public.execution_steps where args::text like '%' || $2 || '%')::int
            + (select count(*) from public.agent_artifacts where summary like '%' || $3 || '%')::int
            + (select count(*) from public.agent_path_leases where rel_path like '%' || $4 || '%')::int
            + (select count(*) from public.agent_tasks where answered_question::text like '%' || $5 || '%' or pending_question::text like '%' || $5 || '%')::int as hits`,
      [CANARY.message, CANARY.answer, CANARY.summary, CANARY.path, CANARY.question],
    );
    expect(stored[0].hits).toBeGreaterThanOrEqual(5);
    const json = JSON.stringify(report);
    for (const canary of Object.values(CANARY)) {
      expect(json, canary).not.toContain(canary);
      expect(logged, canary).not.toContain(canary);
    }
  });
});

describe("E3 다른 사용자 행이 섞여도 수는 전체 합이고 사용자 수는 고유 수다", () => {
  it("사용자를 하나 더 만들어 같은 type 두 줄을 넣으면 수 +2, 사용자 수 +1", async () => {
    const before = report.usage!.types.find((t) => t.type === "session_renamed")!;
    const user = await x.user();
    await x.q("insert into public.metric_events(user_id,type,props) values ($1,'session_renamed','{\"adapter\":\"agent:codex\"}'), ($1,'session_renamed','{\"adapter\":\"agent:codex\"}')", [user]);
    const after = (await loadAgentMetrics(admin, { from: period.from, to: period.to })).usage!.types.find((t) => t.type === "session_renamed")!;
    expect([after.n, after.users]).toEqual([before.n + 2, before.users + 1]);
    expect(after.adapters).toEqual([{ value: "agent:codex", n: before.n + 2 }]);
  });
});

describe("E4 지금 열린 충돌의 수와 나이", () => {
  it("해소하지 않은 충돌이 하나 생기면 열린 충돌 1, 나이는 0 이상이다", async () => {
    const holder = await p.live();
    await p.decide(holder, { lease_op: "acquire" });
    const later = await p.competitor(holder);
    await p.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','요약')", [later.user, later.run, later.task, later.turn]);
    const stops = (await loadAgentMetrics(admin, { from: period.from, to: new Date(Date.now() + 60_000) })).stops!;
    expect(stops.now.openConflicts).toBe(1);
    expect(stops.now.oldestConflictAgeS).toBeGreaterThanOrEqual(0);
    expect(stops.now.oldestConflictAgeS).toBeLessThan(120);
  });
});
