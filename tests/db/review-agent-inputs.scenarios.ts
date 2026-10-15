import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { agentPathLeaseFixtures } from "./agent-path-leases.scenarios";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// OA D4b-s: Review 입력 연결 (읽기 전용 SQL 함수 review_agent_inputs). 같은 시나리오를 PGlite(tests/db/review-agent-inputs.test.ts)와 실제 Postgres(tests/pg/review-agent-inputs.test.ts)에서 돌린다.
// 시드는 기존 D1·D3c-2 fixture를 쓴다: 직접 행(agentWorld)으로 조건 표를 보고, 실제 흐름(live · competitor · decide)으로 충돌 version을 본다.

export const REVIEW_AGENT_INPUTS_MIGRATION = "20261124000000_review_agent_inputs.sql";
export const BOTH = ["agent:claude-code", "agent:codex"];
export const SECRET = "비밀 질문 문구";
/** 질문한 시각의 기본값: 어느 시계로 읽어도 과거다 (asked_at은 DB 시각으로 잘리므로 기본 시험이 시계에 기대지 않게) */
export const ASKED = "2026-01-02T03:04:05Z";

export type InputRow = { kind: string; item_ref: string; action_id: string; run_id: string; version: string; created_at: string; due_at: string | null; detail: Record<string, unknown> };

export function reviewAgentInputsFixtures(db: () => ConversationAgentDb) {
  const f = agentPathLeaseFixtures(db);
  type World = Awaited<ReturnType<typeof f.agentWorld>>;
  const inputs = async (user: string, adapters: string[] | null = BOTH) =>
    // 함수는 scalar jsonb 하나(배열)를 돌려준다 — PostgREST db-max-rows가 행 수에 걸려도 잘리지 않는다. 시험은 읽기 쉽게 종류 · 열쇠 순으로 줄 세운다
    ((await f.one("select public.review_agent_inputs($1, $2::text[]) as result", [user, adapters])).result as InputRow[]).slice().sort((a, b) => (a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : a.item_ref < b.item_ref ? -1 : a.item_ref > b.item_ref ? 1 : 0));
  const question = (task: string, request = "req-1", over: { kind?: string; secrets?: boolean[]; asked_at?: string } = {}) => ({
    question_key: [task, request], provider_request_id: request, kind: over.kind ?? "input", structured: true,
    questions: (over.secrets ?? [false]).map((secret, i) => ({ id: `q${i}`, header: SECRET, text: SECRET, options: [], multi_select: false, allow_other: true, secret })),
    asked_at: over.asked_at ?? ASKED,
  });
  const x = {
    ...f, inputs, question, BOTH,
    /** 대화 run의 작업이 질문을 기다린다 (task의 열린 질문 하나) */
    async ask(w: World, over: Parameters<typeof question>[2] = {}, request = "req-1") {
      await f.updateRow("agent_tasks", w.task, { state: "awaiting_answer", pending_question: question(w.task, request, over) });
      return w;
    },
    /** 다른 run(세션)에서 질문을 기다리는 작업 하나 (열린 질문의 열쇠 = 작업 id) */
    async asking(user: string, o: { run: string; session: string }, over: Parameters<typeof question>[2] = {}, request = "req-1") {
      const id = randomUUID();
      await f.task(user, o.run, o.session, { id, turn_seq: 1, state: "awaiting_answer", pending_question: question(id, request, over) });
      return id;
    },
    /** 같은 사용자의 다른 이슈에서 도는 대화 run (다른 세션) */
    async otherRun(w: World) {
      const action = await f.action(w.user);
      const session = await f.session(w.user, w.connection, { bound_action_id: action });
      const run = await f.agentRun(w.user, action, { agent_session_id: session });
      return { action, session, run };
    },
    /** 턴 n개를 가진 대화: turns[i] = { state, artifacts } (첫 턴은 world의 작업을 쓴다) */
    async turns(w: World, spec: { state: string; artifacts: number }[]) {
      const tasks: string[] = [];
      for (const [i, turn] of spec.entries()) {
        const task = i === 0 ? w.task : await f.task(w.user, w.run, w.session, { turn_seq: i + 1, state: "idle" });
        if (turn.state === "awaiting_answer") await f.updateRow("agent_tasks", task, { state: turn.state, pending_question: question(task, `t${i + 1}`) });
        else await f.updateRow("agent_tasks", task, { state: turn.state });
        for (let n = 0; n < turn.artifacts; n++) {
          await f.insertRow("agent_artifacts", { user_id: w.user, run_id: w.run, agent_task_id: task, turn_seq: i + 1, path: `t${i + 1}-${n}.md`, content_hash: "hash", summary: "요약", created_at: `2026-10-13T0${i + 1}:0${n}:00Z` });
        }
        tasks.push(task);
      }
      return tasks;
    },
    /** holder run이 path를 쥐고 later run이 충돌한 lease 하나 (직접 행) */
    async conflictWorld(over: Record<string, unknown> = {}) {
      const w = await f.agentWorld();
      const later = await x.otherRun(w);
      const lease = await f.insertRow("agent_path_leases", {
        user_id: w.user, bridge_id: w.bridge, run_id: w.run, agent_session_id: w.session, workspace_ref: "/w/proj", path_key: `/w/proj/${randomUUID()}.mdx`, rel_path: "pricing.mdx",
        source: "observed", conflict_run_id: later.run, conflict_at: "2026-10-13T09:00:00Z", conflict_version: 1, ...over,
      });
      return { ...w, later, lease };
    },
    async countAll(user: string) {
      const tables = ["actions", "execution_runs", "agent_tasks", "agent_artifacts", "agent_path_leases", "metric_events", "execution_events"];
      const counts: string[] = [];
      for (const t of tables) counts.push(`${t}=${await f.count(`select 1 from public.${t} where user_id=$1`, [user])}`); // 한 연결에서 차례로 (실제 Postgres 연결은 동시에 하나만 부른다)
      return counts.join(",");
    },
  };
  return x;
}

export function reviewAgentInputsTests(db: () => ConversationAgentDb) {
  const f = reviewAgentInputsFixtures(db);

  describe("T1 함수 모양", () => {
    it("stable · invoker · search_path='' · service_role만 실행 · 본문에 쓰기와 행 잠금이 없다", async () => {
      const row = await f.one(
        `select p.prokind, p.provolatile, p.prosecdef, p.proretset, p.proconfig, pg_get_function_result(p.oid) result, pg_get_functiondef(p.oid) def,
                has_function_privilege('anon', p.oid, 'execute') anon, has_function_privilege('authenticated', p.oid, 'execute') app, has_function_privilege('service_role', p.oid, 'execute') server
           from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'review_agent_inputs'`,
      );
      expect(row).toMatchObject({ prokind: "f", provolatile: "s", prosecdef: false, proretset: false, anon: false, app: false, server: true });
      expect(row.proconfig).toEqual(['search_path=""']);
      // 반환은 scalar jsonb 하나다 (TABLE이면 PostgREST db-max-rows가 행을 자른다)
      expect(row.result).toBe("jsonb");
      expect(String(row.def)).not.toMatch(/\b(insert|update|delete|truncate|nextval|set_config)\b/i);
      expect(String(row.def)).not.toMatch(/\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/i);
    });

    it("앱(authenticated)·익명은 부를 수 없다 (RLS 밖의 서버 함수)", async () => {
      const w = await f.agentWorld();
      await db().asUser(w.user, async () => {
        await expect(f.q("select public.review_agent_inputs($1, $2::text[])", [w.user, f.BOTH])).rejects.toMatchObject({ code: "42501" });
      });
    });

    it("부르는 것은 아무것도 쓰지 않는다 (표 행 수 · 지표가 그대로)", async () => {
      const w = await f.agentWorld();
      await f.ask(w);
      const before = await f.countAll(w.user);
      expect(await f.inputs(w.user)).toHaveLength(1);
      expect(await f.inputs(w.user)).toHaveLength(1);
      expect(await f.countAll(w.user)).toBe(before);
    });
  });

  describe("T2 질문 셋", () => {
    it("input → agent_question, approval → agent_approval, 비밀값 하나라도 → agent_secret_question (항목 열쇠 · version · ref · 시각)", async () => {
      const input = await f.ask(await f.agentWorld());
      const approval = await f.ask(await f.agentWorld(), { kind: "approval" });
      const secret = await f.ask(await f.agentWorld(), { secrets: [false, true] });
      for (const [w, kind, secrets] of [[input, "agent_question", false], [approval, "agent_approval", false], [secret, "agent_secret_question", true]] as const) {
        const rows = await f.inputs(w.user);
        expect(rows, kind).toHaveLength(1);
        expect(rows[0], kind).toMatchObject({
          kind, item_ref: w.task, action_id: w.action, run_id: w.run, version: `question:${w.task}:req-1`, due_at: null,
          detail: { task_id: w.task, session_id: w.session, provider_request_id: "req-1", adapter: "agent:claude-code", bridge_id: w.bridge },
        });
        expect(new Date(rows[0].created_at).toISOString(), kind).toBe("2026-01-02T03:04:05.000Z");
        expect(secrets).toBe(kind === "agent_secret_question");
        expect(Object.keys(rows[0].detail).sort()).toEqual(["adapter", "bridge_id", "provider_request_id", "session_id", "task_id"]);
        // 질문 글 · 헤더는 결과에 없다
        expect(JSON.stringify(rows)).not.toContain(SECRET);
      }
    });

    it("질문 1–4개가 섞여도 한 항목이다. 비밀값이 없으면 agent_question, 승인은 비밀값 표시와 상관없이 approval 질문 종류를 따른다", async () => {
      const four = await f.ask(await f.agentWorld(), { secrets: [false, false, false, false] });
      expect((await f.inputs(four.user)).map((r) => r.kind)).toEqual(["agent_question"]);
      const lateSecret = await f.ask(await f.agentWorld(), { secrets: [false, false, false, true] });
      expect((await f.inputs(lateSecret.user)).map((r) => r.kind)).toEqual(["agent_secret_question"]);
      const approvalWithFlag = await f.ask(await f.agentWorld(), { kind: "approval", secrets: [true] });
      expect((await f.inputs(approvalWithFlag.user)).map((r) => r.kind)).toEqual(["agent_approval"]);
    });

    it("질문이 교체되면 같은 항목(task)에 다른 version이다 (옛 화면은 stale)", async () => {
      const w = await f.ask(await f.agentWorld(), {}, "req-1");
      const first = (await f.inputs(w.user))[0];
      await f.ask(w, {}, "req-2");
      const second = (await f.inputs(w.user))[0];
      expect([second.item_ref, second.version]).toEqual([first.item_ref, `question:${w.task}:req-2`]);
      expect(second.version).not.toBe(first.version);
    });

    it("열린 질문이 없으면 0: 한 번도 없었거나, 답한 뒤 answered_question만 남았거나", async () => {
      const w = await f.agentWorld();
      expect(await f.inputs(w.user)).toEqual([]);
      const answered = await f.questionWorld(answerQuestionFixture(), "agent:codex");
      expect(await f.inputs(answered.user)).toHaveLength(1);
      expect((await f.answer(answered.user, answered.task, "request", { choice: "A" })).status).toBe("answered");
      expect(await f.one("select pending_question is null cleared, answered_question is not null answered from public.agent_tasks where id=$1", [answered.task])).toEqual({ cleared: true, answered: true });
      expect(await f.inputs(answered.user)).toEqual([]);
    });

    it.each(["done", "dropped"])("Action이 %s이면 0", async (status) => {
      const w = await f.ask(await f.agentWorld());
      await f.updateRow("actions", w.action, { status });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("남의 행은 0: 두 사용자의 질문이 섞이지 않는다", async () => {
      const a = await f.ask(await f.agentWorld());
      const b = await f.ask(await f.agentWorld());
      expect((await f.inputs(a.user)).map((r) => r.item_ref)).toEqual([a.task]);
      expect((await f.inputs(b.user)).map((r) => r.item_ref)).toEqual([b.task]);
      expect(await f.inputs(randomUUID())).toEqual([]);
    });

    it("p_adapters 밖 adapter의 세션 질문은 0 (답 route와 같은 gate): 빈 배열 · null도 0, 켜진 adapter면 나온다", async () => {
      const w = await f.ask(await f.agentWorld()); // 연결 adapter = agent:claude-code
      expect(await f.inputs(w.user, ["agent:codex"])).toEqual([]);
      expect(await f.inputs(w.user, [])).toEqual([]);
      expect(await f.inputs(w.user, null)).toEqual([]);
      expect(await f.inputs(w.user, ["agent:claude-code"])).toHaveLength(1);
      await f.updateRow("agent_connections", w.connection, { adapter: "agent:codex" });
      expect(await f.inputs(w.user, ["agent:claude-code"])).toEqual([]);
      expect((await f.inputs(w.user, ["agent:codex"]))[0].detail).toMatchObject({ adapter: "agent:codex" });
    });

    it("Taskforce가 맡긴 작업(kind='task')의 질문은 0 (Q15)", async () => {
      const w = await f.ask(await f.agentWorld());
      await f.updateRow("execution_runs", w.run, { kind: "task" });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("bridge가 지워진 연결은 bridge_id가 null이고 항목은 그대로다", async () => {
      const w = await f.ask(await f.agentWorld());
      await f.q("delete from public.bridges where id=$1", [w.bridge]);
      const rows = await f.inputs(w.user);
      expect(rows).toHaveLength(1);
      expect(rows[0].detail).toMatchObject({ task_id: w.task, bridge_id: null });
    });

    it("asked_at은 Mac 시계 값이라 DB 시각보다 늦으면 DB 시각으로 자른다. 과거는 그대로", async () => {
      const w = await f.ask(await f.agentWorld(), { asked_at: "2099-01-01T00:00:00Z" });
      const [row] = await f.inputs(w.user);
      const at = new Date(row.created_at).getTime();
      expect(at).toBeLessThanOrEqual(Date.now() + 1_000);
      expect(at).toBeGreaterThan(Date.now() - 600_000);
      await f.ask(w, { asked_at: "2026-02-03T04:05:06Z" });
      expect(new Date((await f.inputs(w.user))[0].created_at).toISOString()).toBe("2026-02-03T04:05:06.000Z");
    });

    it("due_at은 Action의 기한이다 (C2와 같은 긴급 판단 입력)", async () => {
      const w = await f.ask(await f.agentWorld());
      await f.updateRow("actions", w.action, { due_at: "2026-11-01T00:00:00Z" });
      expect(new Date((await f.inputs(w.user))[0].due_at!).toISOString()).toBe("2026-11-01T00:00:00.000Z");
    });
  });

  describe("T3 결과 준비 (AC-24)", () => {
    const idle = (artifacts: number) => ({ state: "idle", artifacts });

    it("AC-24: 같은 세션 × 이슈에서 산출물 있는 턴 셋 → 행 하나 (last_turn_seq=3, 개수 n=3)", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(1), idle(1), idle(1)]);
      const rows = await f.inputs(w.user);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        kind: "result_ready", item_ref: w.run, action_id: w.action, run_id: w.run, version: `result:${w.run}:0:3:3`,
        detail: { session_id: w.session, reviewed_turn_seq: 0, last_turn_seq: 3 },
      });
      // created_at = 산출물 중 가장 이른 시각, changed_at = 가장 늦은 시각
      expect(new Date(rows[0].created_at).toISOString()).toBe("2026-10-13T01:00:00.000Z");
      expect(new Date(String(rows[0].detail.changed_at)).toISOString()).toBe("2026-10-13T03:00:00.000Z");
      expect(Object.keys(rows[0].detail).sort()).toEqual(["changed_at", "last_turn_seq", "reviewed_turn_seq", "session_id"]);
    });

    it("산출물이 없는 턴만 있으면 0", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(0), idle(0)]);
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it.each(["running", "dispatched", "accepted", "awaiting_answer"])("마지막 턴 작업이 %s이면 0, 턴이 idle로 끝나면 다시 나온다", async (state) => {
      const w = await f.agentWorld();
      const [, second] = await f.turns(w, [idle(1), { state, artifacts: 0 }]);
      const results = async () => (await f.inputs(w.user)).filter((r) => r.kind === "result_ready").map((r) => r.item_ref); // awaiting_answer는 질문 항목을 따로 만든다
      expect(await results()).toEqual([]);
      await f.updateRow("agent_tasks", second, { state: "idle" });
      expect(await results()).toEqual([w.run]);
    });

    it("마지막이 아닌 턴이 idle이 아니어도 마지막 턴이 idle이면 나온다 (마지막 턴만 본다)", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [{ state: "completed", artifacts: 1 }, idle(0)]);
      expect((await f.inputs(w.user)).map((r) => r.kind)).toEqual(["result_ready"]);
    });

    it("현재 산출물만 센다: 교체된(superseded) 산출물뿐이면 0, 일부만 교체되면 개수가 줄어 version이 바뀐다", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(2)]);
      const before = (await f.inputs(w.user))[0].version;
      expect(before).toBe(`result:${w.run}:0:1:2`);
      const [first] = await f.q("select id from public.agent_artifacts where run_id=$1 order by created_at limit 1", [w.run]);
      await f.updateRow("agent_artifacts", String(first.id), { superseded_at: "2026-10-13T10:00:00Z" });
      expect((await f.inputs(w.user))[0].version).toBe(`result:${w.run}:0:1:1`);
      await f.q("update public.agent_artifacts set superseded_at=now() where run_id=$1", [w.run]);
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("reviewed_turn_seq 이하 턴의 산출물은 이미 검토했다: 마지막 턴까지 봤으면 0, 둘째 턴까지 봤으면 셋째 턴 산출물만 센다", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(1), idle(1), idle(1)]);
      await f.updateRow("execution_runs", w.run, { reviewed_turn_seq: 2 });
      const [row] = await f.inputs(w.user);
      expect(row.version).toBe(`result:${w.run}:2:3:1`);
      expect(row.detail).toMatchObject({ reviewed_turn_seq: 2, last_turn_seq: 3 });
      await f.updateRow("execution_runs", w.run, { reviewed_turn_seq: 3 });
      expect(await f.inputs(w.user)).toEqual([]);
      await f.updateRow("execution_runs", w.run, { reviewed_turn_seq: 9 });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("검토한 뒤 새 턴이 산출물을 남기면 같은 항목이 다시 나오고 version만 바뀐다", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(1)]);
      const first = (await f.inputs(w.user))[0];
      await f.updateRow("execution_runs", w.run, { reviewed_turn_seq: 1 });
      expect(await f.inputs(w.user)).toEqual([]);
      const task = await f.task(w.user, w.run, w.session, { turn_seq: 2, state: "idle" });
      await f.insertRow("agent_artifacts", { user_id: w.user, run_id: w.run, agent_task_id: task, turn_seq: 2, path: "next.md", content_hash: "hash", summary: "새 결과" });
      const again = (await f.inputs(w.user))[0];
      expect(again.item_ref).toBe(first.item_ref);
      expect(again.version).toBe(`result:${w.run}:1:2:1`);
    });

    it.each(["done", "failed", "stopped"])("run이 끝 상태(%s)이면 0", async (state) => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(1)]);
      await f.updateRow("execution_runs", w.run, { state });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it.each(["done", "dropped"])("Action이 %s이면 0", async (status) => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(1)]);
      await f.updateRow("actions", w.action, { status });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("대화 run만 본다 (kind='task'는 0). 결과 준비는 p_adapters로 거르지 않는다", async () => {
      const w = await f.agentWorld();
      await f.turns(w, [idle(1)]);
      expect((await f.inputs(w.user, [])).map((r) => r.kind)).toEqual(["result_ready"]);
      expect((await f.inputs(w.user, null)).map((r) => r.kind)).toEqual(["result_ready"]);
      await f.updateRow("execution_runs", w.run, { kind: "task" });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("남의 산출물은 0", async () => {
      const a = await f.agentWorld();
      const b = await f.agentWorld();
      await f.turns(a, [idle(1)]);
      expect(await f.inputs(b.user)).toEqual([]);
      expect(await f.inputs(a.user)).toHaveLength(1);
    });
  });

  describe("T4 경로 충돌", () => {
    it("충돌 → 행 하나: 항목 열쇠는 lease, Action · run은 늦게 쓴 쪽, ref에 holder", async () => {
      const w = await f.conflictWorld();
      const rows = await f.inputs(w.user);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({
        kind: "path_conflict", item_ref: w.lease, action_id: w.later.action, run_id: w.later.run, version: `conflict:${w.lease}:1`,
        detail: { lease_id: w.lease, conflict_version: 1, holder_action_id: w.action, holder_run_id: w.run, later_run_id: w.later.run, released: false, stopped: false },
      });
      expect(new Date(rows[0].created_at).toISOString()).toBe("2026-10-13T09:00:00.000Z");
      expect(JSON.stringify(rows)).not.toContain("pricing.mdx");
    });

    it("해제됐지만 해소 전이면 그대로 나온다 (released true). 해소(충돌 열이 빔) 뒤에는 0", async () => {
      const w = await f.conflictWorld();
      await f.updateRow("agent_path_leases", w.lease, { released_at: "2026-10-13T10:00:00Z", release_reason: "run_ended" });
      const [row] = await f.inputs(w.user);
      expect(row).toMatchObject({ item_ref: w.lease, version: `conflict:${w.lease}:1`, detail: { released: true } });
      await f.q("update public.agent_path_leases set conflict_run_id=null, conflict_at=null where id=$1", [w.lease]);
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("멈춤 표시(conflict_stop_at)는 stopped true", async () => {
      const w = await f.conflictWorld({ conflict_stop_at: "2026-10-13T09:01:00Z" });
      expect((await f.inputs(w.user))[0].detail).toMatchObject({ stopped: true });
    });

    it("conflict_version이 오르면 같은 항목이 다른 version이다 (옛 화면은 stale)", async () => {
      const w = await f.conflictWorld();
      const first = (await f.inputs(w.user))[0];
      await f.q("update public.agent_path_leases set conflict_version=conflict_version+1 where id=$1", [w.lease]);
      const again = (await f.inputs(w.user))[0];
      expect([again.item_ref, again.version]).toEqual([first.item_ref, `conflict:${w.lease}:2`]);
    });

    it("늦게 쓴 run의 Action이 닫히면 0, holder의 Action이 닫혀도 늦게 쓴 쪽 항목은 남는다", async () => {
      const w = await f.conflictWorld();
      await f.updateRow("actions", w.action, { status: "done" });
      expect(await f.inputs(w.user)).toHaveLength(1);
      await f.updateRow("actions", w.later.action, { status: "dropped" });
      expect(await f.inputs(w.user)).toEqual([]);
    });

    it("p_adapters로 거르지 않는다. 남의 충돌은 0", async () => {
      const w = await f.conflictWorld();
      const other = await f.conflictWorld();
      expect((await f.inputs(w.user, [])).map((r) => r.kind)).toEqual(["path_conflict"]);
      expect((await f.inputs(w.user, null)).map((r) => r.item_ref)).toEqual([w.lease]);
      expect((await f.inputs(other.user)).map((r) => r.item_ref)).toEqual([other.lease]);
    });

    it("같은 fixture에서 list_path_conflicts와 lease 집합이 같다 (해제된 충돌 포함). Action이 닫힌 쪽만 이 함수에서 빠진다", async () => {
      const w = await f.conflictWorld();
      const second = await f.otherRun(w);
      const third = await f.otherRun(w);
      const lease2 = await f.insertRow("agent_path_leases", { user_id: w.user, bridge_id: w.bridge, run_id: w.run, agent_session_id: w.session, workspace_ref: "/w/proj", path_key: `/w/proj/${randomUUID()}`, rel_path: "a", source: "observed", conflict_run_id: second.run, conflict_at: "2026-10-13T09:10:00Z", conflict_version: 3, released_at: "2026-10-13T09:20:00Z", release_reason: "run_ended" });
      const lease3 = await f.insertRow("agent_path_leases", { user_id: w.user, bridge_id: w.bridge, run_id: w.run, agent_session_id: w.session, workspace_ref: "/w/proj", path_key: `/w/proj/${randomUUID()}`, rel_path: "b", source: "observed", conflict_run_id: third.run, conflict_at: "2026-10-13T09:30:00Z", conflict_version: 1 });
      const listed = async () => (((await f.one("select public.list_path_conflicts($1, 500) result", [w.user])).result as { lease_id: string }[]).map((r) => r.lease_id)).sort();
      expect((await f.inputs(w.user)).map((r) => r.item_ref).sort()).toEqual([w.lease, lease2, lease3].sort());
      expect((await f.inputs(w.user)).map((r) => r.item_ref).sort()).toEqual(await listed());
      await f.updateRow("actions", third.action, { status: "done" });
      expect(await listed()).toContain(lease3);
      expect((await f.inputs(w.user)).map((r) => r.item_ref)).not.toContain(lease3);
    });
  });

  describe("T6 개수 상한 없음 (PostgREST db-max-rows)", () => {
    it("입력이 1,001개여도 모두 나온다. 호출 결과는 항상 행 하나(scalar jsonb 배열)라 행 수 상한에 걸리지 않는다", async () => {
      const w = await f.conflictWorld();
      await f.q(
        `insert into public.agent_path_leases (user_id, bridge_id, run_id, agent_session_id, workspace_ref, path_key, rel_path, source, conflict_run_id, conflict_at, conflict_version)
         select $1, $2, $3, $4, '/w/proj', '/w/proj/bulk-' || g, 'bulk-' || g, 'observed', $5, '2026-10-13T09:00:00Z', 1 from generate_series(1, 1000) g`,
        [w.user, w.bridge, w.run, w.session, w.later.run],
      );
      const rows = await f.inputs(w.user);
      expect(rows).toHaveLength(1001);
      expect(new Set(rows.map((r) => r.item_ref)).size).toBe(1001);
      expect(rows.every((r) => r.kind === "path_conflict")).toBe(true);
      // 같은 호출을 행으로 세면 하나다 (set-returning이면 1,001행이고 max-rows에 잘린다)
      expect(await f.count("select public.review_agent_inputs($1, $2::text[]) as result", [w.user, f.BOTH])).toBe(1);
    });

    it("입력이 없으면 빈 배열이다 (null이 아니다)", async () => {
      const w = await f.agentWorld();
      expect((await f.one("select public.review_agent_inputs($1, $2::text[]) as result", [w.user, f.BOTH])).result).toEqual([]);
      expect((await f.one("select public.review_agent_inputs($1, null) as result", [w.user])).result).toEqual([]);
    });
  });

  describe("T5 실제 흐름: 해소 SQL 연결", () => {
    async function realConflict() {
      const a = await f.live(), b = await f.competitor(a);
      await f.decide(a, { decision: "allow", reason: "policy_auto", lease_op: "acquire" });
      await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')", [b.user, b.run, b.task, b.turn]);
      return { a, b };
    }
    const conflictVersion = (row: InputRow) => Number(row.version.split(":")[2]);

    it("항목 version의 conflict_version으로 해소 → resolved + path_conflict_resolved 한 줄, 항목이 사라진다", async () => {
      const { a, b } = await realConflict();
      const [row] = await f.inputs(a.user);
      expect(row).toMatchObject({ kind: "path_conflict", action_id: b.action, run_id: b.run, detail: { holder_run_id: a.run, later_run_id: b.run, released: false, stopped: false } });
      expect(row.version).toBe(`conflict:${row.item_ref}:1`);
      expect((await f.one("select public.resolve_path_conflict($1,$2,'holder',$3) result", [a.user, row.item_ref, conflictVersion(row)])).result).toEqual({ status: "resolved" });
      expect(await f.q("select props from public.metric_events where user_id=$1 and type='path_conflict_resolved'", [a.user])).toEqual([{ props: { keep: "holder" } }]);
      expect(await f.inputs(a.user)).toEqual([]);
    });

    it("해소 뒤 같은 lease에 새 충돌이 생기면 항목이 새 version으로 다시 나오고, 옛 version으로 해소하면 stale (지표 0)", async () => {
      const { a, b } = await realConflict();
      const [first] = await f.inputs(a.user);
      await f.one("select public.resolve_path_conflict($1,$2,'holder',$3) result", [a.user, first.item_ref, conflictVersion(first)]);
      await f.q("update public.agent_artifacts set superseded_at=now() where run_id=$1", [b.run]);
      await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash2','Changed again')", [b.user, b.run, b.task, b.turn]);
      const [again] = await f.inputs(a.user);
      expect(again.item_ref).toBe(first.item_ref);
      expect(again.version).toBe(`conflict:${first.item_ref}:2`);
      const metrics = () => f.count("select 1 from public.metric_events where user_id=$1 and type='path_conflict_resolved'", [a.user]);
      expect(await metrics()).toBe(1);
      expect((await f.one("select public.resolve_path_conflict($1,$2,'later',$3) result", [a.user, first.item_ref, conflictVersion(first)])).result).toEqual({ status: "stale" });
      expect(await metrics()).toBe(1);
      expect(await f.inputs(a.user)).toHaveLength(1);
    });
  });
}
