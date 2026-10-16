import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { agentDeliveryView } from "../../src/lib/agents/delivery";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import { functionBody } from "./bridge-device-name.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// OA F3: 에이전트 전달 정리. 결함 1(Done ↔ 답 교착)의 SQL 줄 셋과 결함 2(만료한 lease 전 prepared 회수)의 새 함수 expire_unleased_agent_messages.
// 같은 시나리오를 PGlite(tests/db/agent-delivery-fixes.test.ts)와 실제 Postgres(tests/pg/agent-delivery-fixes.test.ts)에서 돌린다. 경합 P1–P15는 실제 Postgres 파일에만 있다.

export const DELIVERY_FIXES_MIGRATION = "20261128000000_agent_delivery_fixes.sql";
const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
export const PAST = "2000-01-01T00:00:00Z";

export type Reclaim = { reclaimed: number; busy: number; sessions: { user_id: string; agent_session_id: string }[] };
const NOTHING: Reclaim = { reclaimed: 0, busy: 0, sessions: [] };

export function deliveryFixesFixtures(db: () => ConversationAgentDb) {
  const f = bridgeCommandFixtures(db);
  type World = Awaited<ReturnType<typeof f.world>>;
  const x = {
    ...f,
    expire: async (limit = 50) => (await f.one("select public.expire_unleased_agent_messages($1) as result", [limit])).result as Reclaim,
    /** Mac이 꺼진 동안의 세계: 세션 unreachable · 명령은 lease 전 · 메시지 만료 */
    async offlineWorld(expired: string | null = PAST) {
      const w = await f.world();
      await f.updateRow("agent_sessions", w.session, { status: "unreachable" });
      if (expired) await f.updateRow("conversation_messages", w.message, { delivery_expires_at: expired });
      return w;
    },
    /** 사용자 한 명의 같은 연결에 대화 하나와 만료한 lease 전 메시지 명령을 더 만든다 (후보 여럿) */
    async anotherOffline(w: World, expires: string) {
      const conversation = await f.agentConversation(w.user, w.connection, null);
      const message = String((await f.post(w.user, conversation, randomUUID(), "another task")).message_id);
      const started = await f.start(w.user, message);
      expect(started.status).toBe("started");
      const session = String((await f.one("select agent_session_id from public.agent_tasks where id=$1", [started.agent_task_id])).agent_session_id);
      await f.updateRow("agent_sessions", session, { status: "unreachable" });
      await f.updateRow("conversation_messages", message, { delivery_expires_at: expires });
      const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [started.step_id])).id);
      return { ...w, conversation, message, session, task: started.agent_task_id!, run: started.run_id!, step: started.step_id!, action: started.action_id!, command };
    },
    /** 시각 · id를 뺀 한 줄 요약: 회수한 것과 lease가 거둔 것을 견준다 */
    async oracle(w: Pick<World, "user" | "message" | "step" | "task" | "command" | "run">) {
      return {
        message: await f.one("select delivery_state, delivery_reason from public.conversation_messages where id=$1", [w.message]),
        step: await f.one("select state, receipt, version, lease_owner is null as unleased, lease_expires_at is null as no_deadline from public.execution_steps where id=$1", [w.step]),
        task: await f.one("select state, pending_question, answered_question, abandoned_question, cancel_requested_at is null as not_cancelled from public.agent_tasks where id=$1", [w.task]),
        command: await f.one("select kind, outcome, outcome_at is not null as settled, lease_owner is null as unleased from public.bridge_commands where id=$1", [w.command]),
        transitions: await f.q("select type, to_state from public.execution_events where run_id=$1 and step_id=$2 and type='step' order by id", [w.run, w.step]),
        intents: await f.count("select 1 from public.execution_intents where step_id=$1", [w.step]),
      };
    },
    metrics: (user: string) => f.count("select 1 from public.metric_events where user_id=$1", [user]),
    /** 읽기 모델이 쓰는 입력을 SQL에서 그대로 모아 서버의 순수 함수 agentDeliveryView로 보인다 (messages.ts deliveryViews와 같은 입력) */
    async shown(w: Pick<World, "user" | "message" | "run" | "session">) {
      const row = await f.one("select delivery_state, delivery_reason, refs from public.conversation_messages where id=$1", [w.message]);
      const step = await f.one("select state from public.execution_steps where run_id=$1 and kind='agent_message' and args->>'message_id'=$2 order by seq desc limit 1", [w.run, w.message]);
      const session = await f.one("select status from public.agent_sessions where id=$1", [w.session]);
      return agentDeliveryView({
        row: { state: row.delivery_state as "dispatched", reason: (row.delivery_reason as string | null) ?? null, refs: (row.refs as Record<string, unknown> | null) ?? null },
        stepState: step.state as "prepared",
        sessionStatus: session.status as "unreachable",
        titles: new Map(),
      });
    },
    requeue: async (w: Pick<World, "user" | "conversation">, ids: string[] | null) =>
      (await f.one("select public.requeue_agent_messages($1,$2,$3::uuid[]) as result", [w.user, w.conversation, ids])).result as { status: string; messages: { message_id: string; result: string; reason?: string }[] },
  };
  return x;
}

/** 마이그레이션 파일 한 개의 주석을 뺀 SQL */
export const migrationSql = (file: string) => readFileSync(path.join(MIGRATIONS, file), "utf8").split("\n").filter((line) => !line.trim().startsWith("--")).join("\n");
/** 공백을 하나로, 줄 주석을 뺀 함수 본문 (적용된 prosrc와 파일 본문 모두에 쓴다) */
export const normalizeBody = (body: string) => body.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n").replace(/\s+/g, " ").trim();
export const fileBody = (file: string, name: string) => functionBody(readFileSync(path.join(MIGRATIONS, file), "utf8"), name);

export function deliveryFixesTests(db: () => ConversationAgentDb) {
  const f = deliveryFixesFixtures(db);

  describe("T1 새 함수 모양 · 색인", () => {
    it("invoker · search_path 비움 · lock_timeout 1s · (integer) → jsonb · service_role만", async () => {
      const rows = await f.q(`select pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result, prosecdef, proconfig,
        has_function_privilege('anon',p.oid,'execute') as anon, has_function_privilege('authenticated',p.oid,'execute') as app, has_function_privilege('service_role',p.oid,'execute') as server
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='expire_unleased_agent_messages'`);
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ args: "p_limit integer", result: "jsonb", prosecdef: false, anon: false, app: false, server: true });
      expect([...(rows[0].proconfig as string[])].sort()).toEqual(['lock_timeout=1s', 'search_path=""']);
      const user = await f.user();
      await db().asUser(user, async () => {
        await expect(f.q("select public.expire_unleased_agent_messages(1)")).rejects.toMatchObject({ code: "42501" });
      });
    });

    it("시퀀스 bridge_reclaim_scan_seq는 service_role만 쓴다 (anon · authenticated 거절)", async () => {
      const privilege = async (role: string, kind: string) => (await f.one("select has_sequence_privilege($1,'public.bridge_reclaim_scan_seq',$2) as ok", [role, kind])).ok;
      for (const kind of ["usage", "select"]) expect(await privilege("service_role", kind), `service_role ${kind}`).toBe(true);
      for (const role of ["anon", "authenticated"]) for (const kind of ["usage", "select", "update"]) expect(await privilege(role, kind), `${role} ${kind}`).toBe(false);
    });

    it("count_overdue_agent_step_leases: 읽기 전용 · service_role만 · 유예(초)를 넘겨 만료한 calling 에이전트 단계만 센다", async () => {
      const row = await f.one(`select pg_get_function_result(p.oid) as result, provolatile, prosecdef, proconfig, has_function_privilege('anon',p.oid,'execute') as anon,
        has_function_privilege('authenticated',p.oid,'execute') as app, has_function_privilege('service_role',p.oid,'execute') as server
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='count_overdue_agent_step_leases'`);
      expect(row).toMatchObject({ result: "integer", provolatile: "s", prosecdef: false, proconfig: ['search_path=""'], anon: false, app: false, server: true });
      const count = async (grace: number | null) => Number((await f.one("select public.count_overdue_agent_step_leases($1::integer) as n", [grace])).n);
      const w = await f.world();
      await f.lease(w);
      const [now0, now5] = [await count(0), await count(5)];
      await f.q("update public.execution_steps set lease_expires_at = public.db_now() - interval '100 seconds' where id=$1", [w.step]);
      expect(await count(0)).toBe(now0 + 1);
      expect(await count(5)).toBe(now5 + 1);
      expect(await count(null)).toBe(now0 + 1); // 유예 없음으로 본다
      expect(await count(3600)).toBe(now0); // 유예 안에서는 세지 않는다
      await f.q("update public.execution_runs set kind='task' where id=$1", [w.run]);
      expect(await count(0)).toBe(now0); // 대화 run의 에이전트 단계만 센다
      await f.q("update public.execution_runs set kind='conversation' where id=$1", [w.run]);
      await f.q("select public.sweep_agent_step_leases(null)");
      expect(await count(0)).toBe(now0); // 처리하면 더 이상 남지 않는다
      const user = await f.user();
      await db().asUser(user, async () => {
        await expect(f.q("select public.count_overdue_agent_step_leases(0)")).rejects.toMatchObject({ code: "42501" });
      });
    });

    it("p_limit이 null · 0 · 201이면 22023, 1 · 200은 받는다 (후보가 없으면 빈 결과)", async () => {
      for (const bad of [null, 0, 201, -1]) await expect(f.q("select public.expire_unleased_agent_messages($1::integer)", [bad]), String(bad)).rejects.toMatchObject({ code: "22023" });
      for (const good of [1, 200]) expect(await f.expire(good)).toEqual(NOTHING);
    });

    it("찾기 색인은 아직 lease되지 않은 message 명령만 담는 부분 색인 하나다", async () => {
      const rows = await f.q("select indexdef from pg_indexes where schemaname='public' and indexname='bridge_commands_unleased_message_idx'");
      expect(rows).toHaveLength(1);
      expect(String(rows[0].indexdef).replace(/\s+/g, " ")).toBe(
        "CREATE INDEX bridge_commands_unleased_message_idx ON public.bridge_commands USING btree (created_at) WHERE ((kind = 'message'::text) AND (lease_owner IS NULL) AND (outcome IS NULL))",
      );
    });
  });

  describe("T5 회수 기본", () => {
    it("Mac이 꺼진 동안 만료한 lease 전 prepared는 expired로 회수된다 (끝 상태는 lease가 거둔 것과 같은 함수의 결과, 지표 0 · intent 0)", async () => {
      const w = await f.offlineWorld();
      const metrics = await f.metrics(w.user);
      expect(await f.shown(w)).toEqual({ state: "queued" }); // 회수 전: DB 행이 dispatched/prepared/unreachable이라 보이는 값은 queued
      expect(await f.expire()).toEqual({ reclaimed: 1, busy: 0, sessions: [{ user_id: w.user, agent_session_id: w.session }] });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
      expect(await f.one("select state, receipt from public.execution_steps where id=$1", [w.step])).toEqual({ state: "failed", receipt: { never_sent: true, reason: "expired" } });
      expect(await f.one("select state, pending_question from public.agent_tasks where id=$1", [w.task])).toEqual({ state: "failed", pending_question: null });
      const command = await f.one("select outcome, outcome_at is not null as settled, lease_owner from public.bridge_commands where id=$1", [w.command]);
      expect(command).toEqual({ outcome: "withdrawn", settled: true, lease_owner: null });
      expect(await f.count("select 1 from public.execution_intents where step_id=$1", [w.step])).toBe(0);
      expect(await f.metrics(w.user)).toBe(metrics);
      expect(await f.shown(w)).toEqual({ state: "expired" }); // 회수 뒤: DB가 expired가 되어서야 expired로 보인다
    });

    it("세션이 bound여도 · 연결이 error여도 만료가 이긴다 (세션 · 연결 · gate는 보지 않는다)", async () => {
      const bound = await f.world();
      await f.updateRow("conversation_messages", bound.message, { delivery_expires_at: PAST });
      expect((await f.expire()).reclaimed).toBe(1);
      expect(await f.msg(bound.message)).toMatchObject({ delivery_state: "expired" });
      const broken = await f.world();
      await f.updateRow("agent_connections", broken.connection, { status: "error" });
      await f.updateRow("conversation_messages", broken.message, { delivery_expires_at: PAST });
      expect((await f.expire()).reclaimed).toBe(1);
      expect(await f.msg(broken.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
    });
  });

  describe("T6 회수하지 않는 것 (쓰기 0)", () => {
    const stays: [string, (w: Awaited<ReturnType<typeof f.world>>) => Promise<void>][] = [
      ["만료 전", async (w) => { await f.updateRow("conversation_messages", w.message, { delivery_expires_at: new Date(Date.now() + 3_600_000).toISOString() }); }],
      ["delivery_expires_at이 null", async (w) => { await f.updateRow("conversation_messages", w.message, { delivery_expires_at: null }); }],
      ["명령이 이미 lease됨(calling)", async (w) => { await f.lease(w); await f.updateRow("conversation_messages", w.message, { delivery_expires_at: PAST }); }],
      ["결과를 모르는 전달(unknown_outcome)", async (w) => {
        await f.lease(w);
        await f.updateRow("execution_steps", w.step, { lease_expires_at: PAST });
        await f.q("select public.sweep_agent_step_leases(now())");
        await f.updateRow("conversation_messages", w.message, { delivery_expires_at: PAST });
      }],
      ["메시지가 cancelled", async (w) => { await f.updateRow("conversation_messages", w.message, { delivery_state: "cancelled" }); }],
      ["메시지가 queued", async (w) => { await f.updateRow("conversation_messages", w.message, { delivery_state: "queued" }); }],
      ["메시지가 not_sent", async (w) => { await f.updateRow("conversation_messages", w.message, { delivery_state: "not_sent", delivery_reason: "session_closed" }); }],
      ["단계가 이미 failed", async (w) => { await f.updateRow("execution_steps", w.step, { state: "failed" }); }],
      ["단계가 이미 skipped", async (w) => { await f.updateRow("execution_steps", w.step, { state: "skipped" }); }],
      ["bridge가 폐기됨", async (w) => { await f.q("update public.bridges set status='revoked', revoked_at=now() where id=$1", [w.bridge]); }],
      ["연결의 bridge가 명령의 bridge와 다름", async (w) => { await f.updateRow("agent_connections", w.connection, { bridge_id: await f.bridge(w.user) }); }],
    ];
    it.each(stays)("%s", async (_name, arrange) => {
      const w = await f.world();
      await f.updateRow("conversation_messages", w.message, { delivery_expires_at: PAST });
      await arrange(w);
      const before = await f.snapshot(w);
      expect(await f.expire()).toEqual(NOTHING);
      expect(await f.snapshot(w)).toEqual(before);
      await f.updateRow("conversation_messages", w.message, { delivery_state: "cancelled" }); // 영구히 건너뛰는 후보를 같은 DB에 남기지 않는다 (뒤 시험의 한도 · 창 계산)
    });

    it("answer · cancel 명령은 message가 만료해도 회수하지 않는다 (message 명령만)", async () => {
      const w = await f.world();
      await f.lease(w);
      expect(await f.bridgeEvent(w, f.event(w, "question", { text: "Choose", question: answerQuestionFixture() }))).toMatchObject({ status: "applied" });
      const answered = await f.answer(w.user, w.task);
      expect(answered.status).toBe("answered");
      await f.updateRow("conversation_messages", w.message, { delivery_expires_at: PAST });
      const answerCommand = await f.one("select kind, lease_owner is null as unleased from public.bridge_commands where step_id=$1", [answered.step_id]);
      expect(answerCommand).toEqual({ kind: "answer", unleased: true });
      const before = await f.snapshot(w);
      expect(await f.expire()).toEqual(NOTHING);
      expect(await f.snapshot(w)).toEqual(before);
      await f.stop(w.user, w.session);
      const cancel = await f.one("select kind, lease_owner is null as unleased from public.bridge_commands where agent_task_id=$1 and kind='cancel'", [w.task]);
      expect(cancel).toEqual({ kind: "cancel", unleased: true });
      const afterStop = await f.snapshot(w);
      expect(await f.expire()).toEqual(NOTHING);
      expect(await f.snapshot(w)).toEqual(afterStop);
    });

    it("다른 사용자의 행이 섞여도 각자 것만 회수하고, 앱 역할은 남의 회수 결과를 볼 수 없다 (owner_all)", async () => {
      const a = await f.offlineWorld();
      const b = await f.offlineWorld();
      const quiet = await f.offlineWorld(new Date(Date.now() + 3_600_000).toISOString());
      const result = await f.expire();
      expect(result.reclaimed).toBe(2);
      expect(result.busy).toBe(0);
      expect([...result.sessions].sort((p, q) => p.agent_session_id.localeCompare(q.agent_session_id))).toEqual(
        [{ user_id: a.user, agent_session_id: a.session }, { user_id: b.user, agent_session_id: b.session }].sort((p, q) => p.agent_session_id.localeCompare(q.agent_session_id)),
      );
      expect(await f.msg(quiet.message)).toMatchObject({ delivery_state: "dispatched" });
      await db().asUser(b.user, async () => {
        expect(await f.q("select id from public.conversation_messages where id=$1", [a.message])).toEqual([]);
        expect(await f.q("select delivery_state from public.conversation_messages where id=$1", [b.message])).toEqual([{ delivery_state: "expired" }]);
      });
    });
  });

  describe("T7 lease가 거둔 것과 같다 (오라클)", () => {
    it("같은 fixture 둘: (가) 회수 (나) heartbeat로 세션을 되살린 뒤 lease → 시각 · id를 뺀 메시지 · 단계 · task · 명령 행이 같다", async () => {
      // (나)를 먼저 끝낸다: 되살린 세션에서 lease가 만료를 보고 거둔다 (B4 expired 모양). 그 뒤 (가)의 세계를 만들어 회수한다
      const leased = await f.offlineWorld();
      await f.heartbeat(leased);
      expect(await f.one("select status from public.agent_sessions where id=$1", [leased.session])).toEqual({ status: "bound" });
      expect(await f.lease(leased)).toEqual({ status: "withdrawn", reason: "expired" });
      const reclaimed = await f.offlineWorld();
      expect((await f.expire()).sessions).toEqual([{ user_id: reclaimed.user, agent_session_id: reclaimed.session }]);
      const [byReclaim, byLease] = [await f.oracle(reclaimed), await f.oracle(leased)];
      expect(byReclaim).toEqual(byLease);
      expect(byReclaim.message).toEqual({ delivery_state: "expired", delivery_reason: null });
      expect(byReclaim.step).toMatchObject({ state: "failed", receipt: { never_sent: true, reason: "expired" } });
      expect(byReclaim.transitions).not.toEqual([]);
    });
  });

  describe("T8 Send again 연결 (코드 변경 0)", () => {
    it("회수 전에는 개별은 not_eligible · 일괄에는 그 메시지가 없다 (지금 결함 고정), 회수 뒤에는 개별 requeued · 지표 한 줄 · 새 24시간", async () => {
      const w = await f.offlineWorld();
      expect(await f.requeue(w, [w.message])).toEqual({ status: "ok", messages: [{ message_id: w.message, result: "skipped", reason: "not_eligible" }] });
      expect(await f.requeue(w, null)).toEqual({ status: "ok", messages: [] });
      expect((await f.expire()).reclaimed).toBe(1);
      const before = Date.now();
      expect(await f.requeue(w, [w.message])).toEqual({ status: "ok", messages: [{ message_id: w.message, result: "requeued" }] });
      expect(await f.q("select props from public.metric_events where user_id=$1 and type='message_resent'", [w.user])).toEqual([{ props: { adapter: "agent:codex", from: "expired" } }]);
      const message = await f.msg(w.message);
      expect(message).toMatchObject({ delivery_state: "queued", delivery_reason: null });
      const expires = new Date(String(message.delivery_expires_at)).getTime();
      expect(expires).toBeGreaterThan(before + 23 * 3_600_000);
      expect(expires).toBeLessThan(Date.now() + 25 * 3_600_000);
    });

    it("회수 뒤 일괄 Send again은 그 메시지를 포함한다", async () => {
      const w = await f.offlineWorld();
      expect((await f.expire()).reclaimed).toBe(1);
      expect(await f.requeue(w, null)).toEqual({ status: "ok", messages: [{ message_id: w.message, result: "requeued" }] });
    });

    it("다시 대기한 메시지를 시작하면 새 task · 단계(intent message:<id>:1) · 명령 한 줄이 생긴다 (옛 task는 failed라 진행 중 칸이 비어 있다)", async () => {
      const w = await f.offlineWorld();
      expect((await f.expire()).reclaimed).toBe(1);
      expect((await f.requeue(w, [w.message])).messages[0].result).toBe("requeued");
      await f.heartbeat(w); // Mac이 돌아와 세션이 bound
      const started = await f.start(w.user, w.message);
      expect(started).toMatchObject({ status: "started", turn_seq: 2 });
      expect(started.step_id).not.toBe(w.step);
      expect(await f.one("select state, intent_key, purpose from public.execution_steps where id=$1", [started.step_id])).toMatchObject({ state: "prepared", purpose: `message:${w.message}:1` });
      expect(await f.count("select 1 from public.bridge_commands where step_id=$1 and kind='message'", [started.step_id])).toBe(1);
      expect(await f.one("select state from public.agent_tasks where id=$1", [w.task])).toEqual({ state: "failed" });
    });
  });

  describe("T9 읽기 모델은 DB를 보인다", () => {
    it("회수 전 queued · 회수 뒤 expired. 같은 세션 뒤 queued 메시지는 회수 전에는 진행 중 칸에 막혀 session_busy로 대기하고, 회수 뒤에는 바로 시작된다", async () => {
      const w = await f.offlineWorld();
      const later = String((await f.post(w.user, w.conversation, randomUUID(), "behind")).message_id);
      expect(await f.shown(w)).toEqual({ state: "queued" });
      const inProgress = "select 1 from public.agent_tasks where agent_session_id=$1 and state in ('dispatched','accepted','running','awaiting_answer','unreachable')";
      expect(await f.count(inProgress, [w.session])).toBe(1);
      await f.heartbeat(w); // Mac이 돌아와 세션 bound
      expect(await f.start(w.user, later)).toMatchObject({ status: "queued", reason: "session_busy" }); // 만료 뒤에도 회수 전에는 앞 task가 칸을 차지한다
      expect((await f.expire()).reclaimed).toBe(1);
      expect(await f.shown(w)).toEqual({ state: "expired" });
      expect(await f.count(inProgress, [w.session])).toBe(0);
      expect((await f.one("select public.next_bridge_agent_message($1,$2) as id", [w.user, w.session])).id).toBe(later);
      expect(await f.start(w.user, later)).toMatchObject({ status: "started", turn_seq: 2 });
    });
  });

  describe("T10 멱등 · 한도", () => {
    it("두 번째 회수는 0이고, 회수 뒤 lease는 stale/not_prepared이며 intent가 0이다", async () => {
      const w = await f.offlineWorld();
      expect((await f.expire()).reclaimed).toBe(1);
      expect(await f.expire()).toEqual(NOTHING);
      await f.heartbeat(w);
      expect(await f.lease(w)).toEqual({ status: "stale", reason: "not_prepared" });
      expect(await f.count("select 1 from public.execution_intents where step_id=$1", [w.step])).toBe(0);
    });

    it("p_limit보다 후보가 많으면 한 번에 limit개까지만 하고, 연속 호출이 창을 돌아 나머지를 한다 (한 창 안에서는 만료가 오래된 것부터)", async () => {
      // 같은 DB에 남은 다른 후보보다 앞서도록 아주 오래된 만료 시각을 쓴다
      const first = await f.offlineWorld("1990-01-01T00:00:00Z");
      const second = await f.anotherOffline(first, "1990-01-02T00:00:00Z");
      const third = await f.anotherOffline(first, "1990-01-03T00:00:00Z");
      const all = [first, second, third];
      const sizes: number[] = [];
      for (let call = 0; call < 2; call++) {
        const result = await f.expire(2);
        sizes.push(result.reclaimed);
        expect(result.reclaimed).toBeLessThanOrEqual(2);
        if (result.reclaimed === 2) expect(result.sessions.map((s) => s.agent_session_id).sort()).toEqual([first.session, second.session].sort()); // 첫 창 = 오래된 둘
      }
      expect(sizes.sort()).toEqual([1, 2]);
      for (const w of all) expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired" });
      expect(await f.expire(2)).toEqual(NOTHING);
    }, 60_000);
  });

  describe("T12 영구히 건너뛰는 후보가 뒤 후보를 막지 않는다 (창 돌리기)", () => {
    it("부적격(bridge 폐기) 후보 50개 + 적격 후보 1개: 연속 호출이 창을 돌아 적격 후보를 회수한다 (50개가 머리를 붙잡지 못한다)", async () => {
      const stuck: Awaited<ReturnType<typeof f.offlineWorld>>[] = [];
      for (let i = 0; i < 50; i++) stuck.push(await f.offlineWorld(new Date(Date.UTC(1990, 0, 1 + i)).toISOString()));
      await f.q("update public.bridges set status='revoked', revoked_at=now() where id = any($1::uuid[])", [stuck.map((w) => w.bridge)]);
      const eligible = await f.offlineWorld("1991-01-01T00:00:00Z"); // 만료가 가장 늦다: 한 창(50)에는 들어가지 못한다
      let reclaimed = 0;
      let calls = 0;
      while (!reclaimed && calls < 4) {
        calls++;
        const result = await f.expire(50);
        reclaimed += result.reclaimed;
        if (result.reclaimed) expect(result.sessions).toEqual([{ user_id: eligible.user, agent_session_id: eligible.session }]);
      }
      expect(reclaimed).toBe(1);
      expect(calls).toBeLessThanOrEqual(2); // 후보 51개 = 창 둘
      expect(await f.msg(eligible.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
      for (const w of stuck) {
        expect(await f.msg(w.message)).toMatchObject({ delivery_state: "dispatched" });
        await f.updateRow("conversation_messages", w.message, { delivery_state: "cancelled" }); // 시험 DB를 깨끗이
      }
    }, 120_000);
  });

  describe("T11 지표 · 로그 원천", () => {
    it("회수는 metric_events를 늘리지 않고, 본문은 metric_events · raise warning을 쓰지 않는다 (정적)", async () => {
      const w = await f.offlineWorld();
      const before = await f.metrics(w.user);
      await f.expire();
      expect(await f.metrics(w.user)).toBe(before);
      const source = String((await f.one("select prosrc from pg_proc where proname='expire_unleased_agent_messages'")).prosrc);
      expect(source).not.toMatch(/metric_events|raise\s+(warning|notice|info|log)/i);
    });
  });
}
