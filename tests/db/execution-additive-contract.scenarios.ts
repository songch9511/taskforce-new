import { randomUUID } from "node:crypto";
import { readdir } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "./local-supabase";

// 0.2.0 실행 additive 확장 (20261109000000_execution_additive_contract, 구현 계획 C1): 저장 계약만 시험한다 — 새 열 · 새 CHECK 값 · 연결별 정책 표 ·
// 새 값이 실행으로 새지 않는 DB 쪽 입구(create_run · append_step) · 연결별 정책 행이 있어도 실행 허용 · begin_call · 승인 hash가 달라지지 않는 것 · ARCH06/07(범위가 gate에 닿지 않는다) ·
// 옛 행이 새 마이그레이션 뒤에도 그대로인 것. 실행기(src/lib/execution/executor.ts)가 새 goal · 단계 종류를 fail closed로 다루는 것은 tests/db/execution-additive-executor.test.ts.
// 같은 시나리오를 PGlite(tests/db/execution-additive-contract.test.ts)와 실제 Postgres(tests/pg/execution-additive-contract.test.ts)에서 돌린다. 동시성은 실제 Postgres 파일에만 있다.

export type Rows = Record<string, unknown>[];

export type ExecutionAdditiveDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

/** 런타임 계약 4장의 값 (기존 값 + 더한 값). 테스트의 기대값은 마이그레이션이 아니라 이 목록이다 */
export const GOALS = ["draft", "agent", "send", "followup"];
export const NEW_GOALS = ["agent", "send", "followup"];
export const STEP_KINDS = ["plan", "draft", "external", "agent_dispatch", "agent_message", "agent_cancel", "review", "check", "send", "observe"];
export const NEW_STEP_KINDS = ["agent_dispatch", "agent_message", "agent_cancel", "review", "check", "send", "observe"];
export const OUTCOMES = ["draft_ready", "needs_connection", "needs_input", "needs_capability", "review_failed", "agent_done"];
export const HOLD_REASONS = ["blocked", "actor", "needs_connection", "credit", "resource", "agent_unreachable"];

const sorted = <T extends string | null>(values: T[]) => [...values].sort((a, b) => String(a).localeCompare(String(b)));

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 */
export function additiveFixtures(db: () => ExecutionAdditiveDb) {
  const one = async (sql: string, params: unknown[] = []) => (await db().query(sql, params))[0];
  const id = async (sql: string, params: unknown[] = []) => (await one(sql, params)).id as string;
  const count = async (sql: string, params: unknown[] = []) => Number((await one(`select count(*)::int as n from (${sql}) x`, params)).n);
  return {
    one,
    id,
    count,
    async user(): Promise<string> {
      const userId = randomUUID();
      await db().query(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    connection: (userId: string, provider = "gmail") =>
      id(`insert into public.connections (user_id, provider, external_account_id) values ($1, $2, $3) returning id`, [userId, provider, randomUUID()]),
    action: (userId: string) => id(`insert into public.actions (user_id, title) values ($1, '제안서 쓰기') returning id`, [userId]),
    context: (userId: string, name = "Shape 출시 준비") => id(`insert into public.work_contexts (user_id, name, kind) values ($1, $2, 'project') returning id`, [userId, name]),
    conversation: (userId: string, contextId: string | null = null) =>
      id(`insert into public.conversations (user_id, context_id) values ($1, $2) returning id`, [userId, contextId]),
    /** 지금 코드가 하듯: create_run(첫 단계는 계획) */
    run: (userId: string, actionId: string) => id(`select public.create_run($1, $2, 'draft', '제안서 초안 써 줘') as id`, [userId, actionId]),
    firstStep: (runId: string) => id(`select id from public.execution_steps where run_id = $1 and seq = 1`, [runId]),
    /** 연결별 정책 한 줄 (서버가 쓰듯) */
    policy: (userId: string, connectionId: string, extra: { mode?: string; tools?: string[]; targets?: unknown[]; budget?: number } = {}) =>
      id(
        `insert into public.execution_connection_policies (user_id, connection_id, mode, allowed_tools, allowed_targets, standing_budget_credits)
         values ($1, $2, $3, $4, $5::jsonb, $6) returning id`,
        [userId, connectionId, extra.mode ?? "manual", extra.tools ?? [], JSON.stringify(extra.targets ?? []), extra.budget ?? 0],
      ),
  };
}

/** 에러 메시지가 정규식과 맞는지 (PGlite와 실제 Postgres 모두 같은 문구) */
const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

export function executionAdditiveTests(db: () => ExecutionAdditiveDb) {
  const f = additiveFixtures(db);
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);

  // ───────────────────────── 1) 새 열 ─────────────────────────
  describe("execution_runs 새 열 (conversation_id · context_id · directive_version · bundle_context_version)", () => {
    it("열의 모양: 형 · null 허용 · 기본값. 이 묶음에 없는 열(message_id · target_at · acceptance)은 없다 (agent_session_id는 D1a가 더했다 — tests/db/agent-gateway-core.scenarios.ts)", async () => {
      const columns = await q(
        `select column_name, data_type, is_nullable, column_default from information_schema.columns
          where table_schema = 'public' and table_name = 'execution_runs' and column_name = any ($1) order by column_name`,
        [["conversation_id", "context_id", "directive_version", "bundle_context_version"]],
      );
      expect(columns).toEqual([
        { column_name: "bundle_context_version", data_type: "integer", is_nullable: "YES", column_default: null },
        { column_name: "context_id", data_type: "uuid", is_nullable: "YES", column_default: null },
        { column_name: "conversation_id", data_type: "uuid", is_nullable: "YES", column_default: null },
        { column_name: "directive_version", data_type: "integer", is_nullable: "NO", column_default: "1" },
      ]);
      const absent = await q(
        `select column_name from information_schema.columns where table_schema = 'public' and table_name = 'execution_runs' and column_name = any ($1)`,
        [["message_id", "target_at", "acceptance"]],
      );
      expect(absent).toEqual([]);
    });

    it("지금 코드가 만든 run은 기본값이다: directive_version 1, 나머지 null. 첫 단계도 그대로(계획, 내부 효과)", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      expect(await f.one(`select goal, state, directive_version, conversation_id, context_id, bundle_context_version from public.execution_runs where id = $1`, [run])).toEqual({
        goal: "draft",
        state: "queued",
        directive_version: 1,
        conversation_id: null,
        context_id: null,
        bundle_context_version: null,
      });
      expect(await f.one(`select seq, kind, provider, tool, effect_class, state from public.execution_steps where run_id = $1`, [run])).toEqual({
        seq: 1, kind: "plan", provider: "taskforce", tool: "plan", effect_class: "internal", state: "pending",
      });
    });

    it("directive_version은 1 이상(null 불가), bundle_context_version은 null 또는 1 이상이다: 0 · 음수 거절, 큰 값 · null 허용", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const set = (column: string, value: number | null) => q(`update public.execution_runs set ${column} = $2 where id = $1`, [run, value]);
      for (const bad of [0, -1, -100]) {
        await rejects(set("directive_version", bad), /execution_runs_directive_version_check/);
        await rejects(set("bundle_context_version", bad), /execution_runs_bundle_context_version_check/);
      }
      await rejects(set("directive_version", null), /not-null constraint/);
      await set("directive_version", 7);
      await set("bundle_context_version", 3);
      await set("bundle_context_version", 2_147_483_647);
      await set("bundle_context_version", null);
      expect(await f.one(`select directive_version, bundle_context_version from public.execution_runs where id = $1`, [run])).toEqual({ directive_version: 7, bundle_context_version: null });
    });

    it("남의 대화 · 범위, 없는 id는 가리키지 못하고 내 것과 null은 된다 (부모와 (id, user_id) 복합 외래키)", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const run = await f.run(alice, await f.action(alice));
      const [aliceContext, bobContext] = [await f.context(alice), await f.context(bob)];
      const [aliceConversation, bobConversation] = [await f.conversation(alice), await f.conversation(bob)];
      const set = (column: string, value: string | null) => q(`update public.execution_runs set ${column} = $2 where id = $1`, [run, value]);

      await rejects(set("conversation_id", bobConversation), /execution_runs_conversation_fkey/);
      await rejects(set("context_id", bobContext), /execution_runs_context_fkey/);
      await rejects(set("conversation_id", randomUUID()), /execution_runs_conversation_fkey/);
      await rejects(set("context_id", randomUUID()), /execution_runs_context_fkey/);
      // 새 run을 만들면서 남의 것을 가리켜도 같다 (정책은 같은 사용자 것)
      await rejects(
        q(
          `insert into public.execution_runs (user_id, action_id, policy_id, goal, request, conversation_id, context_id)
           select user_id, action_id, policy_id, 'draft', 'x', $2, null from public.execution_runs where id = $1`,
          [run, bobConversation],
        ),
        /execution_runs_conversation_fkey/,
      );
      expect(await f.one(`select conversation_id, context_id from public.execution_runs where id = $1`, [run])).toEqual({ conversation_id: null, context_id: null });

      await set("conversation_id", aliceConversation);
      await set("context_id", aliceContext);
      expect(await f.one(`select conversation_id, context_id from public.execution_runs where id = $1`, [run])).toEqual({ conversation_id: aliceConversation, context_id: aliceContext });
      await set("conversation_id", null);
      await set("context_id", null);
    });

    it("대화를 지워도 run 기록은 남고 참조만 비운다 (상태 · 단계 · 이벤트 · 다른 열 그대로). 범위를 지우면 context_id만 비우고 bundle_context_version은 묶은 때의 기록으로 남는다", async () => {
      const user = await f.user();
      const [context, otherContext] = [await f.context(user), await f.context(user, "다른 범위")];
      const conversation = await f.conversation(user, context);
      const run = await f.run(user, await f.action(user));
      await q(`update public.execution_runs set conversation_id = $2, context_id = $3, bundle_context_version = 9, directive_version = 4 where id = $1`, [run, conversation, context]);
      const snapshot = () => q(`select to_jsonb(r) - 'conversation_id' - 'context_id' as r from public.execution_runs r where id = $1`, [run]);
      const events = () => f.count(`select 1 from public.execution_events where run_id = $1`, [run]);
      const before = { run: await snapshot(), events: await events(), steps: await q(`select * from public.execution_steps where run_id = $1`, [run]) };

      // 대화(그 대화의 범위 참조는 그대로) → 대화 참조만 비운다
      await q(`delete from public.conversations where id = $1`, [conversation]);
      expect(await f.one(`select conversation_id, context_id from public.execution_runs where id = $1`, [run])).toEqual({ conversation_id: null, context_id: context });
      // 범위 → context_id만 비운다. 묶은 때의 version 기록은 남는다
      await q(`delete from public.work_contexts where id = $1`, [context]);
      expect(await f.one(`select conversation_id, context_id, bundle_context_version, directive_version from public.execution_runs where id = $1`, [run])).toEqual({
        conversation_id: null,
        context_id: null,
        bundle_context_version: 9,
        directive_version: 4,
      });
      // 나머지는 한 글자도 바뀌지 않았다: run의 다른 열, 단계, 이벤트 수
      expect(await snapshot()).toEqual(before.run);
      expect(await q(`select * from public.execution_steps where run_id = $1`, [run])).toEqual(before.steps);
      expect(await events()).toBe(before.events);
      // 다른 범위는 영향이 없다
      expect(await f.count(`select 1 from public.work_contexts where id = $1`, [otherContext])).toBe(1);
    });

    it("앱은 새 열을 읽기만 한다 (RLS): 내 run의 값은 보이고 남의 run은 안 보이며, 쓰기는 권한이 없다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [conversation, context] = [await f.conversation(alice), await f.context(alice)];
      const run = await f.run(alice, await f.action(alice));
      await q(`update public.execution_runs set conversation_id = $2, context_id = $3, bundle_context_version = 2 where id = $1`, [run, conversation, context]);
      await db().asUser(alice, async () => {
        expect(await f.one(`select conversation_id, context_id, bundle_context_version, directive_version from public.execution_runs where id = $1`, [run])).toEqual({
          conversation_id: conversation, context_id: context, bundle_context_version: 2, directive_version: 1,
        });
        for (const column of ["conversation_id", "context_id", "bundle_context_version", "directive_version"]) {
          await rejects(q(`update public.execution_runs set ${column} = null where id = $1`, [run]), /permission denied/);
        }
      });
      await db().asUser(bob, async () => {
        expect(await q(`select conversation_id from public.execution_runs where id = $1`, [run])).toEqual([]);
      });
    });
  });

  // ───────────────────────── 2) CHECK 값 ─────────────────────────
  describe("CHECK 교체: 기존 값을 모두 두고 런타임 계약 4장의 값만 더했다", () => {
    /** 후보를 하나씩 써 보고 받아들인 값만 돌려준다 (거절은 CHECK 위반이어야 한다). 끝나면 원래 값으로 되돌린다 */
    async function accepted(table: "execution_runs" | "execution_steps", column: string, rowId: string, candidates: (string | null)[]) {
      const original = (await f.one(`select ${column} as v from public.${table} where id = $1`, [rowId])).v as string | null;
      const ok: (string | null)[] = [];
      for (const value of candidates) {
        try {
          await q(`update public.${table} set ${column} = $2 where id = $1`, [rowId, value]);
          ok.push(value);
        } catch (error) {
          expect(String((error as Error).message), `${column}=${String(value)}`).toMatch(new RegExp(`${table}_${column}_check`));
        }
      }
      await q(`update public.${table} set ${column} = $2 where id = $1`, [rowId, original]);
      return sorted(ok);
    }

    it("제약은 열마다 정확히 하나이고 이름이 정해져 있다 (옛 이름 없는 제약이 남지 않았다)", async () => {
      const rows = await q(
        `select c.conrelid::regclass::text as tbl, a.attname as col, c.conname
           from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
          where c.contype = 'c' and array_length(c.conkey, 1) = 1
            and ((c.conrelid = 'public.execution_runs'::regclass and a.attname in ('goal', 'hold_reason', 'outcome'))
              or (c.conrelid = 'public.execution_steps'::regclass and a.attname = 'kind'))
          order by 1, 2`,
      );
      expect(rows).toEqual([
        { tbl: "execution_runs", col: "goal", conname: "execution_runs_goal_check" },
        { tbl: "execution_runs", col: "hold_reason", conname: "execution_runs_hold_reason_check" },
        { tbl: "execution_runs", col: "outcome", conname: "execution_runs_outcome_check" },
        { tbl: "execution_steps", col: "kind", conname: "execution_steps_kind_check" },
      ]);
    });

    it("goal: draft(기존) + agent · send · followup만 받는다 — 검토 · 단계 이름 · 대소문자 변형 · 빈 값은 거절", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const junk = ["", "DRAFT", "Agent", "review", "check", "external", "plan", "execute", "dispatch"];
      expect(await accepted("execution_runs", "goal", run, [...GOALS, ...junk])).toEqual(sorted(GOALS));
      await rejects(q(`update public.execution_runs set goal = null where id = $1`, [run]), /not-null constraint/);
    });

    it("단계 종류: plan · draft · external(기존) + agent_dispatch · agent_message · agent_cancel · review · check · send · observe만 받는다", async () => {
      const user = await f.user();
      const step = await f.firstStep(await f.run(user, await f.action(user)));
      const junk = ["", "PLAN", "agent", "dispatch", "message", "cancel", "followup", "tool", "internal"];
      expect(await accepted("execution_steps", "kind", step, [...STEP_KINDS, ...junk])).toEqual(sorted(STEP_KINDS));
      await rejects(q(`update public.execution_steps set kind = null where id = $1`, [step]), /not-null constraint/);
    });

    it("outcome: draft_ready · needs_connection · needs_input(기존) + needs_capability · review_failed · agent_done · null만 받는다", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const junk = ["", "DRAFT_READY", "done", "failed", "agent_failed", "needs_approval", "agent_unreachable", "resource", "blocked"];
      expect(await accepted("execution_runs", "outcome", run, [null, ...OUTCOMES, ...junk])).toEqual(sorted([null, ...OUTCOMES]));
    });

    it("hold_reason: blocked · actor · needs_connection · credit(기존) + resource · agent_unreachable · null만 받는다 (outcome 값은 받지 않는다)", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const junk = ["", "BLOCKED", "agent_done", "review_failed", "needs_capability", "needs_input", "draft_ready", "waiting", "stopped", "approval"];
      expect(await accepted("execution_runs", "hold_reason", run, [null, ...HOLD_REASONS, ...junk])).toEqual(sorted([null, ...HOLD_REASONS]));
    });

    it("새 hold_reason · outcome 값을 써도 이벤트 트리거는 그대로 돈다 (hold가 바뀔 때만 이벤트 한 줄)", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const holds = () => q(`select from_state, to_state from public.execution_events where run_id = $1 and type = 'hold' order by id`, [run]);
      await q(`update public.execution_runs set hold_reason = 'resource' where id = $1`, [run]);
      await q(`update public.execution_runs set hold_reason = 'resource' where id = $1`, [run]); // 같은 값: 이벤트 없음
      await q(`update public.execution_runs set hold_reason = 'agent_unreachable', outcome = 'needs_capability' where id = $1`, [run]);
      expect(await holds()).toEqual([
        { from_state: null, to_state: "resource" },
        { from_state: "resource", to_state: "agent_unreachable" },
      ]);
    });
  });

  // ───────────────────────── 3) 실행 입구 ─────────────────────────
  describe("새 값은 실행으로 새지 않는다: create_run은 draft만, append_step은 plan · draft · external만", () => {
    it("create_run: agent · send · followup · 모르는 값 · 빈 값 · null은 거절하고 run · 단계 · 정책 · 이벤트를 한 줄도 만들지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const counts = async () => ({
        runs: await f.count(`select 1 from public.execution_runs where user_id = $1`, [user]),
        steps: await f.count(`select 1 from public.execution_steps where user_id = $1`, [user]),
        policies: await f.count(`select 1 from public.execution_policies where user_id = $1`, [user]),
        events: await f.count(`select 1 from public.execution_events where user_id = $1`, [user]),
      });
      for (const goal of [...NEW_GOALS, "bogus", "", "DRAFT", null]) {
        await rejects(q(`select public.create_run($1, $2, $3, 'x')`, [user, action, goal]), /아직 실행하지 않는다/);
      }
      expect(await counts()).toEqual({ runs: 0, steps: 0, policies: 0, events: 0 });
      await f.run(user, action);
      expect(await counts()).toEqual({ runs: 1, steps: 1, policies: 1, events: 2 });
    });

    it("create_run은 서명 · 열린 Action 확인 · 남의 Action 거절 · 예산 인자가 예전과 같다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const action = await f.action(alice);
      await rejects(q(`select public.create_run($1, $2, 'draft', 'x')`, [bob, action]), /open action not found/);
      await q(`update public.actions set status = 'done' where id = $1`, [action]);
      await rejects(q(`select public.create_run($1, $2, 'draft', 'x')`, [alice, action]), /open action not found/);
      const open = await f.action(alice);
      const run = await f.id(`select public.create_run($1, $2, 'draft', '예산', 50) as id`, [alice, open]);
      expect(await f.one(`select budget_credits, goal from public.execution_runs where id = $1`, [run])).toEqual({ budget_credits: 50, goal: "draft" });
      const signature = await f.one(`select pg_get_function_identity_arguments(p.oid) as args from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'create_run'`);
      expect(signature.args).toBe("p_user_id uuid, p_action_id uuid, p_goal text, p_request text, p_budget_credits integer");
    });

    it("append_step: 새 단계 종류는 거절하고 한 줄도 붙이지 않는다. plan · draft · external은 예전처럼 붙고 순번이 오른다", async () => {
      const user = await f.user();
      const run = await f.run(user, await f.action(user));
      const steps = () => f.count(`select 1 from public.execution_steps where run_id = $1`, [run]);
      const append = (seq: number, step: Record<string, unknown>) => q(`select public.append_step($1, $2, $3::jsonb) as id`, [run, seq, JSON.stringify(step)]);
      for (const kind of [...NEW_STEP_KINDS, "bogus", "", "PLAN"]) {
        await rejects(append(2, { kind, provider: "taskforce", tool: "draft", purpose: "draft" }), /아직 붙이지 않는다/);
      }
      await rejects(append(2, { provider: "taskforce", tool: "draft", purpose: "draft" }), /아직 붙이지 않는다/);
      expect(await steps()).toBe(1);

      expect((await append(2, { kind: "draft", provider: "taskforce", tool: "draft", purpose: "draft", estimate_credits: 20 }))[0].id).toEqual(expect.any(String));
      expect((await append(3, { kind: "plan", provider: "taskforce", tool: "plan", purpose: "plan" }))[0].id).toEqual(expect.any(String));
      expect((await append(4, { kind: "external", provider: "gmail", tool: "send", purpose: "send" }))[0].id).toEqual(expect.any(String));
      expect(await steps()).toBe(4);
      // 순번이 어긋나면 예전처럼 null (거절이 아니다)
      expect((await append(4, { kind: "draft", provider: "taskforce", tool: "draft", purpose: "draft" }))[0].id).toBeNull();
    });

    it("create_run · append_step 권한은 서버 전용 그대로다 (앱 · 익명 실행 불가, search_path 고정, 소유자 권한 아님)", async () => {
      const rows = await q(
        `select p.proname as name, has_function_privilege('anon', p.oid, 'execute') as anon, has_function_privilege('authenticated', p.oid, 'execute') as auth,
                has_function_privilege('service_role', p.oid, 'execute') as service, p.prosecdef as definer, p.proconfig as config
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname in ('create_run', 'append_step', 'execution_connection_policies_guard') order by p.proname`,
      );
      expect(rows.map((r) => r.name)).toEqual(["append_step", "create_run", "execution_connection_policies_guard"]);
      for (const row of rows) {
        expect(row, String(row.name)).toMatchObject({ anon: false, auth: false, service: true, definer: false });
        expect(row.config, String(row.name)).toContain('search_path=""');
      }
    });
  });

  // ───────────────────────── 4) 연결별 정책 표 ─────────────────────────
  describe("execution_connection_policies (최소형, 저장 계약)", () => {
    it("기본값: 가장 좁은 쪽 — manual · 허용 도구 없음 · 허용 대상 없음 · standing 예산 0 · version 1", async () => {
      const user = await f.user();
      const connection = await f.connection(user);
      const [row] = await q(`insert into public.execution_connection_policies (user_id, connection_id) values ($1, $2) returning *`, [user, connection]);
      expect(row).toMatchObject({ user_id: user, connection_id: connection, mode: "manual", allowed_tools: [], allowed_targets: [], standing_budget_credits: 0, version: 1 });
      expect(row.id).toEqual(expect.any(String));
      expect(row.created_at).toBeTruthy();
      expect(row.updated_at).toBeTruthy();
    });

    it("mode는 manual · auto · full만 (execution_policies.mode와 같은 값). 대소문자 변형 · 빈 값 · null 거절", async () => {
      const user = await f.user();
      for (const mode of ["manual", "auto", "full"]) {
        const connection = await f.connection(user);
        await f.policy(user, connection, { mode });
        expect((await f.one(`select mode from public.execution_connection_policies where connection_id = $1`, [connection])).mode).toBe(mode);
      }
      const connection = await f.connection(user);
      for (const bad of ["MANUAL", "Auto", "", "admin", "full_access"]) {
        await rejects(q(`insert into public.execution_connection_policies (user_id, connection_id, mode) values ($1, $2, $3)`, [user, connection, bad]), /violates check constraint/);
      }
      await rejects(q(`insert into public.execution_connection_policies (user_id, connection_id, mode) values ($1, $2, null)`, [user, connection]), /not-null constraint/);
      expect(await f.count(`select 1 from public.execution_connection_policies where connection_id = $1`, [connection])).toBe(0);
    });

    it("allowed_tools: 배열(비어 있어도 된다)만, NULL 원소 · 빈 문자열 원소 · null은 거절", async () => {
      const user = await f.user();
      const connection = await f.connection(user);
      const set = (value: string | null) => q(`insert into public.execution_connection_policies (user_id, connection_id, allowed_tools) values ($1, $2, $3::text[])`, [user, connection, value]);
      await rejects(set(null), /not-null constraint/);
      await rejects(set("{send,NULL}"), /execution_connection_policies_tools_valid/);
      await rejects(set("{send,\"\"}"), /execution_connection_policies_tools_valid/);
      expect(await f.count(`select 1 from public.execution_connection_policies where connection_id = $1`, [connection])).toBe(0);
      await set("{send,dispatch,send}");
      expect((await f.one(`select allowed_tools from public.execution_connection_policies where connection_id = $1`, [connection])).allowed_tools).toEqual(["send", "dispatch", "send"]);
    });

    it("allowed_targets: jsonb 배열만 (원소의 모양은 쓰는 단계가 정한다). 객체 · 문자열 · 숫자 · null 거절", async () => {
      const user = await f.user();
      const connection = await f.connection(user);
      const set = (value: string | null) => q(`insert into public.execution_connection_policies (user_id, connection_id, allowed_targets) values ($1, $2, $3::jsonb)`, [user, connection, value]);
      for (const bad of ["{}", '{"a":1}', '"x"', "1", "true", "null"]) await rejects(set(bad), /violates check constraint/);
      await rejects(set(null), /not-null constraint/);
      await set('[{"kind":"repo","ref":"taskforce"},"rule@example.com"]');
      expect((await f.one(`select allowed_targets from public.execution_connection_policies where connection_id = $1`, [connection])).allowed_targets).toEqual([{ kind: "repo", ref: "taskforce" }, "rule@example.com"]);
    });

    it("standing_budget_credits: 0 이상의 정수 — 음수 · null 거절. version은 1 이상 — 0 · 음수 · null 거절", async () => {
      const user = await f.user();
      const connection = await f.connection(user);
      const set = (column: string, value: number | null) => q(`insert into public.execution_connection_policies (user_id, connection_id, ${column}) values ($1, $2, $3)`, [user, connection, value]);
      for (const bad of [-1, -1000]) await rejects(set("standing_budget_credits", bad), /violates check constraint/);
      await rejects(set("standing_budget_credits", null), /not-null constraint/);
      for (const bad of [0, -1]) await rejects(set("version", bad), /violates check constraint/);
      await rejects(set("version", null), /not-null constraint/);
      await set("standing_budget_credits", 1000);
      expect(await f.count(`select 1 from public.execution_connection_policies where connection_id = $1`, [connection])).toBe(1);
    });

    it("연결 하나에 정책 하나: 같은 연결의 둘째 정책은 거절한다. 다른 연결은 된다", async () => {
      const user = await f.user();
      const [one, other] = [await f.connection(user), await f.connection(user)];
      await f.policy(user, one);
      await rejects(f.policy(user, one, { mode: "full" }), /duplicate key value violates unique constraint/);
      await f.policy(user, other);
      expect(await f.count(`select 1 from public.execution_connection_policies where user_id = $1`, [user])).toBe(2);
    });

    it("남의 연결 · 없는 연결은 가리키지 못한다 (복합 외래키). 남의 user_id로 내 연결을 가리켜도 같다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aliceConnection, bobConnection] = [await f.connection(alice), await f.connection(bob)];
      await rejects(f.policy(alice, bobConnection), /violates foreign key constraint/);
      await rejects(f.policy(bob, aliceConnection), /violates foreign key constraint/);
      await rejects(f.policy(alice, randomUUID()), /violates foreign key constraint/);
      await rejects(f.policy(randomUUID(), aliceConnection), /violates foreign key constraint/);
      expect(await f.count(`select 1 from public.execution_connection_policies where user_id in ($1, $2)`, [alice, bob])).toBe(0);
    });

    it("RLS: 앱은 자기 행만 읽고 쓰지 못한다 (owner_all 정책 + select 권한). 익명은 읽지도 못한다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aliceConnection, bobConnection] = [await f.connection(alice), await f.connection(bob)];
      const alicePolicy = await f.policy(alice, aliceConnection, { mode: "auto", tools: ["send"], budget: 5 });
      await f.policy(bob, bobConnection);

      const policies = await q(`select policyname, cmd, roles::text as roles from pg_policies where schemaname = 'public' and tablename = 'execution_connection_policies'`);
      expect(policies).toEqual([{ policyname: "owner_all", cmd: "ALL", roles: "{authenticated}" }]);
      expect(await f.one(`select relrowsecurity from pg_class where oid = 'public.execution_connection_policies'::regclass`)).toEqual({ relrowsecurity: true });

      await db().asUser(alice, async () => {
        expect(await q(`select id, user_id, mode from public.execution_connection_policies`)).toEqual([{ id: alicePolicy, user_id: alice, mode: "auto" }]);
        await rejects(q(`insert into public.execution_connection_policies (connection_id) values ($1)`, [aliceConnection]), /permission denied/);
        await rejects(q(`update public.execution_connection_policies set mode = 'full', version = version + 1 where id = $1`, [alicePolicy]), /permission denied/);
        await rejects(q(`delete from public.execution_connection_policies where id = $1`, [alicePolicy]), /permission denied/);
      });
      await db().asUser(bob, async () => {
        expect(await q(`select id from public.execution_connection_policies where id = $1`, [alicePolicy])).toEqual([]);
        expect(await q(`select id from public.execution_connection_policies`)).toHaveLength(1);
      });
      // 익명(anon)은 표 권한이 없다
      await q(`set role anon`);
      try {
        await rejects(q(`select * from public.execution_connection_policies`), /permission denied/);
      } finally {
        await q(`reset role`);
      }
      expect(await f.one(`select mode, version, standing_budget_credits from public.execution_connection_policies where id = $1`, [alicePolicy])).toEqual({ mode: "auto", version: 1, standing_budget_credits: 5 });
    });

    describe("version과 소유자: 몰래 바꾸거나 되돌리거나 건너뛰거나 옮기지 못한다", () => {
      async function row() {
        const user = await f.user();
        const connection = await f.connection(user);
        const policy = await f.policy(user, connection, { mode: "manual", tools: ["send"], targets: ["a@example.com"], budget: 10 });
        return { user, connection, policy };
      }
      const update = (policy: string, set: string, params: unknown[] = []) => q(`update public.execution_connection_policies set ${set} where id = $1 returning version`, [policy, ...params]);

      it("내용이 바뀌면 version은 정확히 + 1이어야 한다: 그대로 · 건너뜀 · 내림 · 같은 값 거절 (4개 내용 열 모두)", async () => {
        const { policy } = await row();
        const contents = [
          ["mode = 'auto'"],
          ["allowed_tools = '{send,dispatch}'"],
          ["allowed_targets = '[\"b@example.com\"]'::jsonb"],
          ["standing_budget_credits = 11"],
        ];
        for (const [change] of contents) {
          for (const bad of ["version = version", "version = version + 2", "version = version - 1", "version = 1"]) {
            await rejects(update(policy, `${change}, ${bad}`), /version은 내용이 바뀔 때 정확히 \+ 1/);
          }
          await rejects(update(policy, change), /version은 내용이 바뀔 때 정확히 \+ 1/);
        }
        expect(await f.one(`select mode, allowed_tools, allowed_targets, standing_budget_credits, version from public.execution_connection_policies where id = $1`, [policy])).toEqual({
          mode: "manual", allowed_tools: ["send"], allowed_targets: ["a@example.com"], standing_budget_credits: 10, version: 1,
        });
        for (const [i, [change]] of contents.entries()) {
          expect((await update(policy, `${change}, version = version + 1`))[0].version).toBe(i + 2);
        }
      });

      it("내용이 그대로면 version은 그대로이거나 + 1이다(승인을 무효로 만드는 올림). 건너뛰기 · 내림은 거절. 의미가 같은 jsonb 재기록은 내용 변경이 아니다", async () => {
        const { policy } = await row();
        await update(policy, "mode = mode"); // 아무것도 안 바뀜
        await update(policy, "allowed_targets = '[\"a@example.com\"]'::jsonb"); // 같은 값
        expect((await update(policy, "version = version + 1"))[0].version).toBe(2);
        await rejects(update(policy, "version = version + 2"), /version은 내용이 바뀔 때 정확히 \+ 1/);
        await rejects(update(policy, "version = version - 1"), /version은 내용이 바뀔 때 정확히 \+ 1/);
        expect((await f.one(`select version from public.execution_connection_policies where id = $1`, [policy])).version).toBe(2);
      });

      it("id · user_id · connection_id · created_at은 바꿀 수 없다 (정책을 다른 연결 · 다른 사용자에게 옮겨 권한이 번지지 않는다)", async () => {
        const { user, policy } = await row();
        const otherConnection = await f.connection(user);
        const other = await f.user();
        await rejects(update(policy, "connection_id = $2, version = version + 1", [otherConnection]), /바꿀 수 없다/);
        await rejects(update(policy, "user_id = $2, version = version + 1", [other]), /바꿀 수 없다|foreign key/);
        await rejects(update(policy, "id = $2", [randomUUID()]), /바꿀 수 없다/);
        await rejects(update(policy, "created_at = created_at - interval '1 day'"), /바꿀 수 없다/);
        expect((await f.one(`select version from public.execution_connection_policies where id = $1`, [policy])).version).toBe(1);
      });

      it("내용을 바꾸면 updated_at이 갱신된다 (기존 set_updated_at)", async () => {
        const { policy } = await row();
        await q(`update public.execution_connection_policies set updated_at = '2000-01-01' where id = $1`, [policy]);
        await update(policy, "mode = 'auto', version = version + 1");
        expect((await f.one(`select extract(year from updated_at)::int as y from public.execution_connection_policies where id = $1`, [policy])).y).toBeGreaterThan(2000);
      });
    });

    it("연결을 지우면 정책도 함께 지워지고, 같은 계정을 다시 연결해도 옛 정책을 물려받지 않는다. 다른 연결의 정책은 그대로", async () => {
      const user = await f.user();
      const [one, other] = [await f.connection(user), await f.connection(user)];
      await f.policy(user, one, { mode: "full", budget: 999 });
      const keep = await f.policy(user, other, { mode: "auto" });
      await q(`delete from public.connections where id = $1`, [one]);
      expect(await f.count(`select 1 from public.execution_connection_policies where connection_id = $1`, [one])).toBe(0);
      const again = await f.connection(user); // 다시 연결: 새 연결 id
      expect(await f.count(`select 1 from public.execution_connection_policies where connection_id = $1`, [again])).toBe(0);
      expect(await f.one(`select id, mode from public.execution_connection_policies where user_id = $1`, [user])).toEqual({ id: keep, mode: "auto" });
    });

    it("연결을 지워도 그 연결로 만든 실행 기록은 남는다: 단계는 connection_id만 비우고 상태 · 승인 · 이벤트는 그대로", async () => {
      const user = await f.user();
      const connection = await f.connection(user);
      const run = await f.run(user, await f.action(user));
      await f.policy(user, connection, { mode: "full" });
      await q(`update public.execution_steps set state = 'called', policy_version = 1, version = version + 1 where run_id = $1 and seq = 1`, [run]);
      const step = await f.id(
        `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, connection_id, state, policy_version)
         values ($1, $2, 2, 'external', 'gmail', 'send', 'send', $3, 'called', 1) returning id`,
        [user, run, connection],
      );
      await q(`insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', now())`, [user, step]);
      const events = await f.count(`select 1 from public.execution_events where run_id = $1`, [run]);
      await q(`delete from public.connections where id = $1`, [connection]);
      expect(await f.one(`select state, connection_id, version from public.execution_steps where id = $1`, [step])).toEqual({ state: "called", connection_id: null, version: 0 });
      expect(await f.count(`select 1 from public.execution_approvals where step_id = $1`, [step])).toBe(1);
      expect(await f.count(`select 1 from public.execution_events where run_id = $1`, [run])).toBe(events);
      expect(await f.count(`select 1 from public.execution_connection_policies where user_id = $1`, [user])).toBe(0);
    });
  });

  // ───────────────────────── 5) 연결별 정책은 실행 허용을 만들지 않는다 · 범위는 gate에 닿지 않는다 ─────────────────────────
  describe("저장 계약뿐: 연결별 정책 행 · 대화 · 범위 · 버전이 begin_call · 승인 hash · 정책 · Action을 바꾸지 않는다 (ARCH06 · ARCH07, I04 · I14)", () => {
    /**
     * 실행 가능한 모든 조건이 갖춰진 세계: 실행 주체 · 스위치 열림 · gmail.send 도구 · 수신자 허용 목록 · 연결 · 사용자 규칙 안의 수신자 · Manual 정책.
     * 이 세계에서 외부 단계는 승인 없이는 `not_approved`(승인 대기)다. 끝나면 전역 운영 표를 처음 상태로 되돌린다
     */
    async function world() {
      const user = await f.user();
      await q(`insert into public.execution_actors (user_id) values ($1)`, [user]);
      const connection = await f.connection(user, "gmail");
      const action = await f.action(user);
      const run = await f.run(user, action);
      const address = `rule-${user.slice(0, 8)}@example.com`;
      // 계획 단계는 끝난 것으로 둔다: begin_call은 앞 단계가 모두 called · skipped일 때만 다음 단계를 부른다
      await q(`update public.execution_steps set state = 'called', policy_version = 1, version = version + 1 where run_id = $1 and seq = 1`, [run]);
      const step = await f.id(
        `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, connection_id, recipients, body, args)
         values ($1, $2, 2, 'external', 'gmail', 'send', 'send', $3, $4::jsonb, '견적서 보내드립니다', '{"subject": "견적"}') returning id`,
        [user, run, connection, JSON.stringify([{ address, origin: "user" }])],
      );
      expect((await f.one(`select public.prepare_step($1, 0) as ok`, [step])).ok).toBe(true);
      await q(`insert into public.execution_tools (provider, tool, effect_class) values ('gmail', 'send', 'external') on conflict do nothing`);
      await q(`insert into public.execution_controls (scope, key, blocked) values ('provider', 'gmail', false) on conflict (scope, key) do update set blocked = false`);
      await q(`update public.execution_controls set blocked = false where scope = 'global'`);
      await q(`insert into public.execution_recipient_allowlist (address) values ($1) on conflict do nothing`, [address]);
      return { user, connection, action, run, step, address };
    }
    async function restoreGlobals(address: string) {
      await q(`update public.execution_controls set blocked = true where scope = 'global'`);
      await q(`delete from public.execution_controls where scope = 'provider' and key = 'gmail'`);
      await q(`delete from public.execution_tools where provider = 'gmail' and tool = 'send'`);
      await q(`delete from public.execution_recipient_allowlist where address = $1`, [address]);
    }

    const HASH_AT = "2026-10-02T00:00:00Z";
    type W = Awaited<ReturnType<typeof world>>;
    /** 같은 세계를 다시 관찰한다: begin_call을 한 번 부르고(승인이 없으면 같은 대기 상태), 판단에 쓰이는 모든 값을 읽는다 */
    async function observe(w: W) {
      const gate = (await f.one(`select public.begin_call($1, 'fn-observe', $2) as g`, [w.step, (await f.one(`select version from public.execution_steps where id = $1`, [w.step])).version])).g;
      return {
        gate,
        hash: (await f.one(`select public.approval_hash($1, $2::timestamptz) as h`, [w.step, HASH_AT])).h,
        auto: (await f.one(`select public.auto_allowed($1) as a`, [w.step])).a,
        userPolicy: await f.one(`select mode, auto_recipients, version from public.execution_policies where user_id = $1`, [w.user]),
        run: await f.one(`select state, hold_reason, outcome, stopped_at from public.execution_runs where id = $1`, [w.run]),
        steps: await q(`select seq, state, version, attempt, policy_version, needs_approval, intent_key, lease_owner from public.execution_steps where run_id = $1 order by seq`, [w.run]),
        intents: await f.count(`select 1 from public.execution_intents where user_id = $1`, [w.user]),
        action: await f.one(`select to_jsonb(a) as a from public.actions a where id = $1`, [w.action]),
        tools: await q(`select provider, tool, effect_class from public.execution_tools order by provider, tool`),
        controls: await q(`select scope, key, blocked from public.execution_controls order by scope, key`),
        allowlist: await q(`select address from public.execution_recipient_allowlist order by address`),
        approvals: await f.count(`select 1 from public.execution_approvals where user_id = $1`, [w.user]),
        ledger: await f.count(`select 1 from public.credit_ledger where user_id = $1`, [w.user]),
      };
    }

    it("연결별 정책 행이 있어도(Full · 큰 standing 예산 · 도구 · 대상 허용) 승인 대기는 승인 대기이고, 승인 hash · auto_allowed · 사용자 정책 · 단계 · 크레딧은 한 글자도 안 바뀐다. 내용을 바꾸고 version을 올려도 지워도 같다", async () => {
      const w = await world();
      try {
        const baseline = await observe(w);
        expect(baseline.gate).toEqual({ gate: "not_approved" });
        expect(baseline.auto).toBe(false);
        expect(baseline.run).toMatchObject({ state: "waiting_approval", hold_reason: null });
        expect(baseline.userPolicy).toMatchObject({ mode: "manual", version: 1 });

        // 다른 사용자의 연결별 정책도 영향이 없다
        const stranger = await f.user();
        await f.policy(stranger, await f.connection(stranger), { mode: "full", budget: 1_000_000 });

        const policy = await f.policy(w.user, w.connection, { mode: "full", tools: ["send", "dispatch", "gmail.send"], targets: [w.address, { kind: "repo" }], budget: 1_000_000 });
        expect(await observe(w)).toEqual(baseline);
        await q(`update public.execution_connection_policies set mode = 'auto', allowed_tools = '{}', standing_budget_credits = 0, version = version + 1 where id = $1`, [policy]);
        expect(await observe(w)).toEqual(baseline);
        await q(`update public.execution_connection_policies set version = version + 1 where id = $1`, [policy]);
        expect(await observe(w)).toEqual(baseline);
        await q(`delete from public.execution_connection_policies where id = $1`, [policy]);
        expect(await observe(w)).toEqual(baseline);
        // 연결별 정책의 쓰기는 실행 이벤트 · 크레딧 · 승인을 남기지 않는다
        expect(await f.count(`select 1 from public.execution_events where user_id = $1 and step_id is null and type = 'hold'`, [w.user])).toBe(0);
      } finally {
        await restoreGlobals(w.address);
      }
    });

    it("승인한 뒤 begin_call의 결과(검증한 그대로의 내용)도 연결별 정책이 있어도 같다: 사용자가 본 계획의 hash로만 통과한다", async () => {
      const w = await world();
      try {
        await f.policy(w.user, w.connection, { mode: "full", tools: ["send"], targets: [w.address], budget: 500 });
        const before = await observe(w);
        const shown = await f.one(`select hash, expires_at from public.show_plan($1, $2)`, [w.user, w.step]);
        // 연결별 정책이 hash에 들어가지 않는다: 같은 시각으로 계산한 hash가 정책이 없던 때와 같다
        expect(before.hash).toBe((await f.one(`select public.approval_hash($1, $2::timestamptz) as h`, [w.step, HASH_AT])).h);
        expect((await f.one(`select public.approve_step($1, $2, $3, $4) as ok`, [w.user, w.step, shown.hash, shown.expires_at])).ok).toBe(true);
        const opened = (await f.one(`select public.begin_call($1, 'fn-1', $2) as g`, [w.step, (await f.one(`select version from public.execution_steps where id = $1`, [w.step])).version])).g as Record<string, unknown>;
        expect(opened).toEqual({
          gate: "ok", marker: expect.any(String), provider: "gmail", tool: "send", connection: w.connection, recipients: [w.address], body: "견적서 보내드립니다", args: { subject: "견적" },
        });
        expect(await f.one(`select state from public.execution_steps where id = $1`, [w.step])).toEqual({ state: "calling" });
      } finally {
        await restoreGlobals(w.address);
      }
    });

    it("Full 연결 정책 + Auto 사용자 정책이어도 사용자 정책 규칙(auto_recipients)과 차단 스위치(Manual만)가 그대로 정한다: 연결 정책의 mode는 소비되지 않는다", async () => {
      const w = await world();
      try {
        await f.policy(w.user, w.connection, { mode: "full", budget: 1000 });
        // 사용자 정책을 Auto로(규칙 밖의 주소): 규칙 밖 주소는 승인 대기, 스위치는 mode auto가 막혀 있어 blocked
        await q(`update public.execution_policies set mode = 'auto', auto_recipients = '["other@example.com"]'::jsonb, version = version + 1 where user_id = $1`, [w.user]);
        await q(`update public.execution_steps set state = 'pending', version = version + 1 where id = $1`, [w.step]); // 정책 버전이 바뀌었으니 다시 준비
        expect((await f.one(`select public.prepare_step($1, $2) as ok`, [w.step, (await f.one(`select version from public.execution_steps where id = $1`, [w.step])).version])).ok).toBe(true);
        expect((await f.one(`select public.auto_allowed($1) as a`, [w.step])).a).toBe(false);
        const version = (await f.one(`select version from public.execution_steps where id = $1`, [w.step])).version;
        expect((await f.one(`select public.begin_call($1, 'fn-2', $2) as g`, [w.step, version])).g).toEqual({ gate: "blocked" });
        expect(await f.one(`select hold_reason from public.execution_runs where id = $1`, [w.run])).toEqual({ hold_reason: "blocked" });
      } finally {
        await restoreGlobals(w.address);
      }
    });

    it("ARCH06 · ARCH07: 범위 멤버십 · 보관 · 이동 · 기억 · context_version을 바꾸고 run의 대화 · 범위 · 버전 열을 어떻게 써도 begin_call · 정책 · 승인 hash · Action이 그대로다", async () => {
      const w = await world();
      try {
        const baseline = await observe(w);
        expect(baseline.gate).toEqual({ gate: "not_approved" });
        const [context, other] = [await f.context(w.user, "Shape"), await f.context(w.user, "다른 범위")];
        const conversation = await f.conversation(w.user, context);
        const source = await f.id(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'note', '메모', now()) returning id`, [w.user]);

        // 멤버십: 넣기 · 빼기(removed_at) · 옮기기 · 원문 · 사용자 승격 — B1 트리거가 context_version을 올린다
        await q(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'auto')`, [w.user, context, w.action]);
        expect(await observe(w)).toEqual(baseline);
        await q(`insert into public.context_members (user_id, context_id, member_kind, source_id, origin, confidence) values ($1, $2, 'source', $3, 'inferred', 0.6)`, [w.user, context, source]);
        await q(`update public.context_members set origin = 'user', confidence = null where context_id = $1 and member_kind = 'action'`, [context]);
        expect(await observe(w)).toEqual(baseline);
        await q(`update public.context_members set removed_at = now(), origin = 'user' where context_id = $1 and member_kind = 'action'`, [context]);
        await q(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`, [w.user, other, w.action]);
        expect(await observe(w)).toEqual(baseline);
        // 기억(명시 · 관찰) · 정정 · 보관 · 병합 대신 이름 바꾸기 · 직접 version 올림
        await q(`insert into public.memory_items (user_id, kind, scope_kind, context_id, subject, statement, origin, source_ref) values ($1, 'condition', 'context', $2, 'start', '디자인 확정 뒤 개발', 'explicit', $3::jsonb)`, [w.user, context, JSON.stringify({ message_id: randomUUID() })]);
        await q(`update public.work_contexts set name = 'Shape 2', context_version = context_version + 5 where id = $1`, [context]);
        await q(`update public.work_contexts set status = 'archived' where id = $1`, [other]);
        expect(await observe(w)).toEqual(baseline);

        // run의 출처 기록: 대화 · 범위 · 묶음 version · 지시 version을 어떻게 써도 판단은 같다 (자동 지시 변경 · 재개 없음)
        for (const [directive, bundle] of [[1, 1], [2, 7], [50, null], [3, 1_000_000]] as const) {
          await q(`update public.execution_runs set conversation_id = $2, context_id = $3, bundle_context_version = $4, directive_version = $5 where id = $1`, [w.run, conversation, context, bundle, directive]);
          const seen = await observe(w);
          expect(seen).toEqual(baseline);
        }
        expect(await f.one(`select directive_version from public.execution_runs where id = $1`, [w.run])).toEqual({ directive_version: 3 });
        // 범위와 대화를 지워도(참조만 비워진다) 같다
        await q(`delete from public.conversations where id = $1`, [conversation]);
        await q(`delete from public.work_contexts where id = $1`, [context]);
        expect(await observe(w)).toEqual(baseline);
        expect(await f.one(`select context_id, conversation_id, bundle_context_version, directive_version from public.execution_runs where id = $1`, [w.run])).toEqual({
          context_id: null, conversation_id: null, bundle_context_version: 1_000_000, directive_version: 3,
        });

        // 승인하면 예전과 같은 내용으로 통과한다 (범위는 입력이 아니다)
        const shown = await f.one(`select hash, expires_at from public.show_plan($1, $2)`, [w.user, w.step]);
        expect((await f.one(`select public.approve_step($1, $2, $3, $4) as ok`, [w.user, w.step, shown.hash, shown.expires_at])).ok).toBe(true);
        const version = (await f.one(`select version from public.execution_steps where id = $1`, [w.step])).version;
        expect((await f.one(`select public.begin_call($1, 'fn-1', $2) as g`, [w.step, version])).g).toMatchObject({ gate: "ok", provider: "gmail", tool: "send", recipients: [w.address] });
      } finally {
        await restoreGlobals(w.address);
      }
    });

    it("Action 완료 판정도 그대로다: 범위 · 출처 열이 채워진 run도 할 일이 끝나면 예전처럼 action_closed로 멈춘다 (열린 Action에서만 다음 단계)", async () => {
      const w = await world();
      try {
        const [context, conversation] = [await f.context(w.user), null as string | null];
        await q(`update public.execution_runs set context_id = $2, bundle_context_version = 4, conversation_id = $3 where id = $1`, [w.run, context, conversation]);
        await q(`update public.actions set status = 'done' where id = $1`, [w.action]);
        const version = (await f.one(`select version from public.execution_steps where id = $1`, [w.step])).version;
        expect((await f.one(`select public.begin_call($1, 'fn-1', $2) as g`, [w.step, version])).g).toEqual({ gate: "action_closed" });
        expect(await f.one(`select state, stopped_at from public.execution_runs where id = $1`, [w.run])).toEqual({ state: "stopped", stopped_at: null });
        // 할 일을 다시 열어도 멈춘 run은 이어 가지 않는다
        await q(`update public.actions set status = 'open' where id = $1`, [w.action]);
        expect((await f.one(`select public.begin_call($1, 'fn-1', $2) as g`, [w.step, version])).g).toEqual({ gate: "stopped" });
      } finally {
        await restoreGlobals(w.address);
      }
    });

    it("함수 본문 경계: 연결별 정책 표를 언급하는 함수는 그 표의 보호 트리거뿐이고, 실행 함수는 범위 · 대화 · 기억 표를 쓰지 않는다", async () => {
      const mentioning = await q(`select p.proname as name from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosrc like '%execution_connection_policies%' order by 1`);
      expect(mentioning).toEqual([{ name: "execution_connection_policies_guard" }]);
      const executionFunctions = await q(
        `select p.proname as name, p.prosrc as body from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and (p.proname like 'execution\\_%' or p.proname in ('create_run', 'append_step', 'prepare_step', 'begin_call', 'finish_run', 'settle_step', 'approval_hash', 'auto_allowed', 'approve_step', 'show_plan', 'stop_run',
                                                                                  'revoke_approval', 'mark_unknown', 'sweep_expire', 'readback_settle', 'complete_internal_step', 'write_execution_receipt'))`,
      );
      expect(executionFunctions.length).toBeGreaterThan(20);
      for (const row of executionFunctions) {
        expect(String(row.body), String(row.name)).not.toMatch(/work_contexts|context_members|memory_items|conversations|conversation_messages|context_version|bundle_context_version|directive_version|conversation_id|context_id/);
      }
    });
  });

  // ───────────────────────── 5-2) C1에 넣지 않은 것은 그대로다 ─────────────────────────
  describe("넣지 않은 것은 켜지지 않았다 (런타임 계약 4장의 나머지는 C2 · D1 · E1 몫)", () => {
    it("도구 · 스위치 행: 에이전트 · 검토 · 확인 · 관찰 도구와 에이전트 공급자 스위치 행이 없다 (목록 밖이라 begin_call이 막는 그대로)", async () => {
      expect(await f.count(`select 1 from public.execution_tools where provider like 'agent:%' or tool in ('dispatch', 'message', 'cancel', 'review', 'check', 'observe')`)).toBe(0);
      expect(await f.count(`select 1 from public.execution_controls where scope = 'provider' and key like 'agent:%'`)).toBe(0);
      expect(await q(`select provider, tool, effect_class from public.execution_tools order by provider, tool`)).toEqual([
        { provider: "taskforce", tool: "draft", effect_class: "internal" },
        { provider: "taskforce", tool: "plan", effect_class: "internal" },
      ]);
    });

    it("산출물 종류는 draft뿐이고 새 열이 없다. C1은 실행 이벤트 종류 · 열을 넓히지 않았다 (type 'agent'와 사건 봉투 열은 뒤의 D1a가 더했다 — tests/db/agent-gateway-core.scenarios.ts)", async () => {
      const kindCheck = await f.one(
        `select pg_get_constraintdef(c.oid) as def from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
          where c.conrelid = 'public.execution_artifacts'::regclass and c.contype = 'c' and a.attname = 'kind'`,
      );
      expect(String(kindCheck.def)).toMatch(/draft/);
      expect(String(kindCheck.def)).not.toMatch(/review|agent_result|message/);
      const added = await q(
        `select table_name, column_name from information_schema.columns where table_schema = 'public' and
           table_name = 'execution_artifacts' and column_name in ('directive_version', 'result_revision', 'attribution', 'superseded_at')`,
      );
      expect(added).toEqual([]);
    });

    it("C1의 새 표는 연결별 정책 하나뿐이다: 자원 잠금 · 의존 · 선호 표는 없다 (에이전트 세션 · 작업 표는 뒤의 D1a가 만들었다)", async () => {
      expect(await q(`select table_name from information_schema.tables where table_schema = 'public' and table_name in ('execution_resource_locks', 'action_dependencies', 'user_preferences')`)).toEqual([]);
    });
  });
}

// ───────────────────────── 6) 업그레이드 ─────────────────────────
const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");
export const C1_MIGRATION = "20261109000000_execution_additive_contract.sql";

export type FreshDb = {
  /** 여러 문장 스크립트 (마이그레이션) */
  exec: (sql: string) => Promise<unknown>;
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
};

/** Supabase 흉내 + C1 앞의 모든 마이그레이션 / C1 / 그 뒤의 마이그레이션 */
async function splitScripts() {
  const files = (await readdir(MIGRATIONS_DIR)).filter((file) => file.endsWith(".sql")).sort();
  const index = files.indexOf(C1_MIGRATION);
  expect(index, `${C1_MIGRATION}이 마이그레이션 목록에 있다`).toBeGreaterThan(0);
  const scripts = await supabaseSchemaScripts();
  return { before: scripts.slice(0, 2 + index), c1: scripts[2 + index], after: scripts.slice(3 + index) };
}

/**
 * 새 마이그레이션 전 상태에서 옛 행(draft run · 모든 종류 · 상태의 단계 · 기존 outcome/hold · 승인 · intent · 이벤트 · 사용자 정책 · 크레딧)을 만들고,
 * 전체 마이그레이션을 적용한 뒤에도 그대로인지 본다. 새 열은 기본값이어야 한다. 마지막 시나리오는 기대와 다른 제약이 있으면 아무것도 바꾸지 않고 실패하는 것(롤백)을 본다.
 */
export function executionUpgradeTests(fresh: () => Promise<FreshDb>) {
  const TABLES = [
    "execution_policies", "execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_events", "execution_controls",
    "execution_tools", "execution_actors", "execution_recipient_allowlist", "credit_accounts", "credit_ledger", "actions", "connections", "rate_limit_events",
  ];
  const NEW_RUN_KEYS = ["conversation_id", "context_id", "directive_version", "bundle_context_version"];
  // 뒤의 마이그레이션(20261113000000_agent_gateway_core, D1a)이 더한 열: 이 시험은 옛 열이 그대로인지만 본다
  const LATER_RUN_KEYS = ["kind", "agent_session_id", "reviewed_turn_seq"];
  const LATER_EVENT_KEYS = ["external_event_id", "external_seq", "directive_version", "turn_seq", "bridge_id", "payload"];

  describe("업그레이드 회귀 (새 마이그레이션 전 상태 → 전체 적용)", () => {
    it("옛 draft run · 단계 · outcome · hold · 승인 · intent · 이벤트 · 정책 · 크레딧이 그대로이고, 새 열은 기본값이며, 승인 hash는 같다", async () => {
      const { before, c1, after } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const one = async (sql: string, params: unknown[] = []) => (await db.query(sql, params))[0];
      const id = async (sql: string, params: unknown[] = []) => (await one(sql, params)).id as string;

      // 새 열이 없는 상태임을 확인한 뒤 옛 데이터를 만든다
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'execution_runs' and column_name = 'directive_version'`)).toEqual([]);
      const alice = randomUUID();
      const bob = randomUUID();
      for (const u of [alice, bob]) await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u, `${u}@example.com`]);
      await db.query(`insert into public.execution_actors (user_id) values ($1)`, [alice]);
      const connection = await id(`insert into public.connections (user_id, provider, external_account_id) values ($1, 'gmail', 'me@example.com') returning id`, [alice]);
      await db.query(`insert into public.execution_policies (user_id, mode, auto_recipients, version) values ($1, 'auto', '["rule@example.com"]', 3)`, [alice]);
      await db.query(`select public.grant_credits($1, 100, gen_random_uuid())`, [alice]);

      const runs: string[] = [];
      // run마다 (outcome, hold_reason, state): 옛 CHECK가 허용하던 값 전부
      const variants: [string | null, string | null, string][] = [
        ["draft_ready", null, "done"], ["needs_connection", null, "done"], ["needs_input", null, "done"],
        [null, "blocked", "running"], [null, "actor", "queued"], [null, "needs_connection", "waiting_approval"], [null, "credit", "running"], [null, null, "stopped"],
      ];
      for (const [outcome, hold, state] of variants) {
        const action = await id(`insert into public.actions (user_id, title) values ($1, '할 일') returning id`, [alice]);
        const run = await id(`select public.create_run($1, $2, 'draft', '초안 써 줘', 40) as id`, [alice, action]);
        await db.query(`update public.execution_runs set state = $2, hold_reason = $3, outcome = $4 where id = $1`, [run, state, hold, outcome]);
        runs.push(run);
      }
      // 단계: 모든 옛 종류 × 상태. 외부 단계는 연결 · 수신자가 있다
      const kinds: [string, string, string][] = [["plan", "taskforce", "plan"], ["draft", "taskforce", "draft"], ["external", "gmail", "send"]];
      const states = ["pending", "prepared", "calling", "called", "unknown_outcome", "failed", "skipped"];
      let seq = 10;
      const stepIds: string[] = [];
      for (const [kind, provider, tool] of kinds) {
        for (const state of states) {
          stepIds.push(
            await id(
              `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, effect_class, purpose, connection_id, recipients, body, state, policy_version, intent_key)
               values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, '본문', $11, $12, $13) returning id`,
              [
                alice, runs[0], seq++, kind, provider, tool, kind === "external" ? "external" : "internal", `${kind}-${state}`, kind === "external" ? connection : null,
                JSON.stringify(kind === "external" ? [{ address: "rule@example.com", origin: "user" }] : []), state, state === "pending" ? null : 3, state === "pending" ? null : `key-${kind}-${state}`,
              ],
            ),
          );
        }
      }
      await db.query(`insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', now() + interval '1 hour')`, [alice, stepIds[0]]);
      await db.query(`insert into public.execution_intents (intent_key, user_id, step_id) values ('key-external-called', $1, $2)`, [alice, stepIds[kinds.length * states.length - 4]]);
      // 다른 사용자의 run도 있다
      await db.query(`select public.create_run($1, $2, 'draft', '다른 사람')`, [bob, await id(`insert into public.actions (user_id, title) values ($1, '밥의 할 일') returning id`, [bob])]);

      const snapshot = async () => {
        const out: Record<string, Rows> = {};
        for (const table of TABLES) out[table] = await db.query(`select to_jsonb(t) as row from public.${table} t order by to_jsonb(t)::text`);
        return out;
      };
      const pure = async () => ({
        hashes: await db.query(`select s.id, public.approval_hash(s.id, '2026-10-02T00:00:00Z'::timestamptz) as hash, public.auto_allowed(s.id) as auto from public.execution_steps s order by s.id`),
      });
      const old = await snapshot();
      const oldPure = await pure();
      expect(old.execution_runs).toHaveLength(runs.length + 1);
      expect(old.execution_steps.length).toBeGreaterThan(20);

      for (const sql of [c1, ...after]) await db.exec(sql);

      const now = await snapshot();
      const without = (rows: Rows, keys: string[]) => rows.map((r) => ({ row: Object.fromEntries(Object.entries(r.row as Record<string, unknown>).filter(([key]) => !keys.includes(key))) }));
      for (const table of TABLES) {
        if (table === "execution_runs") continue;
        expect(table === "execution_events" ? without(now[table], LATER_EVENT_KEYS) : now[table], table).toEqual(old[table]);
      }
      // run: 옛 열은 그대로, 새 열은 기본값
      const strip = (rows: Rows) => without(rows, [...NEW_RUN_KEYS, ...LATER_RUN_KEYS]);
      expect(strip(now.execution_runs)).toEqual(strip(old.execution_runs));
      for (const r of now.execution_runs) {
        expect(r.row).toMatchObject({ conversation_id: null, context_id: null, directive_version: 1, bundle_context_version: null });
      }
      // 승인 hash · Auto 판단은 같은 값 (새 열 · 연결별 정책이 hash에 들어가지 않는다)
      expect((await pure()).hashes).toEqual(oldPure.hashes);
      // 옛 값은 새 제약 아래서도 그대로 쓸 수 있다
      await db.query(`update public.execution_runs set goal = goal, hold_reason = hold_reason, outcome = outcome`);
      await db.query(`update public.execution_steps set kind = kind`);
      expect((await db.query(`select count(*)::int as n from public.execution_connection_policies`))[0]).toEqual({ n: 0 });
    });

    it("기대와 다른 CHECK 제약(열마다 하나가 아닌 경우)이 있으면 마이그레이션은 아무것도 바꾸지 않고 실패한다 (롤백)", async () => {
      const { before, c1 } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      await db.query(`alter table public.execution_runs add constraint zz_extra_goal check (goal <> 'zz')`);
      await expect(db.exec(c1)).rejects.toThrow(/CHECK 제약이 2개다/);
      await db.exec("rollback");
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'execution_runs' and column_name in ('conversation_id', 'context_id', 'directive_version')`)).toEqual([]);
      expect(await db.query(`select 1 from information_schema.tables where table_name = 'execution_connection_policies'`)).toEqual([]);
      // 옛 제약이 그대로다: 새 goal은 아직 거절된다
      const user = randomUUID();
      await db.query(`insert into auth.users (id, email) values ($1, 'x@example.com')`, [user]);
      const action = (await db.query(`insert into public.actions (user_id, title) values ($1, 'x') returning id`, [user]))[0].id;
      await db.query(`select public.create_run($1, $2, 'draft', 'x')`, [user, action]);
      await expect(db.query(`insert into public.execution_runs (user_id, action_id, policy_id, goal, request) select user_id, action_id, policy_id, 'agent', 'x' from public.execution_runs`)).rejects.toThrow(/execution_runs_goal_check/);
    });
  });
}
