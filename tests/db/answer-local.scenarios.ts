import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// OA F2: 비밀값 질문을 그 세션의 Mac이 "여기서 답했다"고 표시하는 SQL 함수 answer_agent_question_locally (20261126000000_answer_agent_question_locally).
// 값은 서버로 오지 않는다: 인자는 (user, bridge, task, request_digest, adapters)뿐이다. 이 파일은 PGlite 시나리오 T1–T8이다 (실제 Postgres 경합 P1–P7은 tests/pg/answer-local.test.ts).

export const ANSWER_LOCAL_MIGRATION = "20261126000000_answer_agent_question_locally.sql";
/** 값이 서버에 닿지 않는다는 것을 보는 분명한 가짜 값 */
export const CANARY = "DO_NOT_STORE_SECRET_F2";
export const REQUEST = "request";
export const BOTH = ["agent:claude-code", "agent:codex"];
export const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");

export type LocalResult = { status: string; step_id?: string; reason?: string };
type Over = { user?: string; bridge?: string; task?: string; digest?: string; adapters?: string[] | null };

export function answerLocalFixtures(db: () => ConversationAgentDb) {
  const f = bridgeCommandFixtures(db);
  type World = Awaited<ReturnType<typeof f.questionWorld>>;
  const secretQuestion = (request = REQUEST) => answerQuestionFixture({ secret: true }, { provider_request_id: request });
  const x = {
    ...f,
    secretQuestion,
    /** 대화 run의 작업이 비밀값 질문 하나(request)를 기다린다. 연결은 bridge에 묶여 있고 adapter는 codex */
    secretWorld: (question: ReturnType<typeof answerQuestionFixture> = secretQuestion(), adapter = "agent:codex") => f.questionWorld(question, adapter),
    async local(w: Pick<World, "user" | "bridge" | "task">, over: Over = {}): Promise<LocalResult> {
      const adapters = over.adapters === undefined ? BOTH : over.adapters;
      return (await f.one("select public.answer_agent_question_locally($1,$2,$3,$4,$5::text[]) as result", [
        over.user ?? w.user, over.bridge ?? w.bridge, over.task ?? w.task, over.digest ?? sha256(REQUEST), adapters,
      ])).result as LocalResult;
    },
    /** 쓰기가 있었는지 보는 한 장: 답이 건드릴 수 있는 표 전부 (같으면 쓰기 0) */
    async all(user: string) {
      const tables = ["bridge_commands", "execution_steps", "execution_runs", "agent_tasks", "agent_sessions", "agent_connections", "conversation_messages", "conversations", "execution_events", "execution_intents", "metric_events"];
      const out: Record<string, unknown[]> = {};
      for (const table of tables) out[table] = await f.q(`select * from public.${table} where user_id=$1 order by 1`, [user]);
      return out;
    },
    async metrics(user: string) {
      return f.q("select type, props from public.metric_events where user_id=$1 and type='question_answered' order by id", [user]);
    },
    /** 이 사용자의 모든 행에서 글자를 찾는다 (jsonb 글자 그대로) */
    async occurrences(user: string, needles: string[]) {
      const found: string[] = [];
      const snapshot = JSON.stringify(await x.all(user));
      for (const needle of needles) if (snapshot.includes(needle)) found.push(needle);
      return found;
    },
  };
  return x;
}

export function answerLocalTests(db: () => ConversationAgentDb) {
  const f = answerLocalFixtures(db);

  describe("T1 함수 모양", () => {
    it("invoker · search_path='' · lock_timeout=2s · jsonb 반환 · 인자 정확히 다섯 · 겹침 없음 · service_role만 실행", async () => {
      const rows = await f.q(
        `select p.prokind, p.prosecdef, p.proconfig, p.proretset, pg_get_function_result(p.oid) result, pg_get_function_identity_arguments(p.oid) args,
                has_function_privilege('anon', p.oid, 'execute') anon, has_function_privilege('authenticated', p.oid, 'execute') app, has_function_privilege('service_role', p.oid, 'execute') server,
                exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0) public_grant
           from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'answer_agent_question_locally'`,
      );
      expect(rows).toHaveLength(1);
      const row = rows[0];
      expect(row).toMatchObject({ prokind: "f", prosecdef: false, proretset: false, result: "jsonb", anon: false, app: false, server: true, public_grant: false });
      expect(row.args).toBe("p_user_id uuid, p_bridge_id uuid, p_agent_task_id uuid, p_request_digest text, p_adapters text[]");
      expect(row.proconfig).toEqual(expect.arrayContaining(['search_path=""', "lock_timeout=2s"]));
    });

    it("앱(authenticated)은 부를 수 없다 (RLS 밖의 서버 함수)", async () => {
      const w = await f.secretWorld();
      await db().asUser(w.user, async () => {
        await expect(f.q("select public.answer_agent_question_locally($1,$2,$3,$4,$5::text[])", [w.user, w.bridge, w.task, sha256(REQUEST), BOTH])).rejects.toMatchObject({ code: "42501" });
      });
    });
  });

  describe("T2 주인 bridge의 표시", () => {
    it("answered: 답 단계 args가 정확히 { agent_task_id, provider_request_id, answered_locally }, body 빈 글, 작업 running, 대화 줄, 주인 bridge에 answer 명령 한 줄", async () => {
      const w = await f.secretWorld();
      const pending = (await f.state(w)).pending_question;
      const result = await f.local(w);
      expect(result).toEqual({ status: "answered", step_id: expect.any(String) });
      const steps = await f.answerSteps(w.task);
      expect(steps).toHaveLength(1);
      expect(steps[0]).toMatchObject({ id: result.step_id, state: "prepared", body: "", needs_approval: false });
      expect(steps[0].args).toEqual({ agent_task_id: w.task, provider_request_id: REQUEST, answered_locally: true });
      expect(steps[0].intent_key).toBe(`answer:${w.task}:${REQUEST}:0`);
      expect(await f.one("select state,pending_question,answered_question from public.agent_tasks where id=$1", [w.task])).toEqual({ state: "running", pending_question: null, answered_question: pending });
      expect(await f.q("select text from public.conversation_messages where conversation_id=$1 and role='event'", [w.conversation])).toEqual([{ text: "Answered on this Mac" }]);
      expect(await f.q("select bridge_id,kind from public.bridge_commands where step_id=$1", [result.step_id])).toEqual([{ bridge_id: w.bridge, kind: "answer" }]);
    });

    it("혼합 질문(일반 + 비밀값)도 같다: 값 자리가 없는 표시 하나", async () => {
      const q = answerQuestionFixture(); q.questions.push({ ...q.questions[0], id: "secret", secret: true });
      const w = await f.secretWorld(q);
      const result = await f.local(w);
      expect(result.status).toBe("answered");
      expect((await f.answerSteps(w.task))[0].args).toEqual({ agent_task_id: w.task, provider_request_id: REQUEST, answered_locally: true });
    });

    it("다시 보내면 duplicate(같은 step)이고 아무것도 쓰지 않는다", async () => {
      const w = await f.secretWorld();
      const first = await f.local(w);
      const before = await f.all(w.user);
      expect(await f.local(w)).toEqual({ status: "duplicate", step_id: first.step_id });
      expect(await f.all(w.user)).toEqual(before);
      expect(await f.answerSteps(w.task)).toHaveLength(1);
    });
  });

  describe("T3 소유 · gate", () => {
    const cases: [string, (w: Awaited<ReturnType<typeof f.secretWorld>>) => Promise<Over>][] = [
      ["같은 사용자의 다른 bridge", async (w) => ({ bridge: await f.bridge(w.user) })],
      ["연결이 bridge에 묶여 있지 않음", async (w) => { await f.q("update public.agent_connections set bridge_id=null where id=$1", [w.connection]); return {}; }],
      ["bridge가 폐기됨(연결 · 세션은 그대로)", async (w) => { await f.q("update public.bridges set status='revoked', revoked_at=now() where id=$1", [w.bridge]); return {}; }],
      ["남의 작업", async () => ({ user: await f.user() })],
      ["없는 작업", async () => ({ task: "00000000-0000-4000-8000-000000000000" })],
      ["run이 대화가 아님", async (w) => { await f.updateRow("execution_runs", w.run, { kind: "task" }); return {}; }],
      ["adapter 목록 밖", async () => ({ adapters: ["agent:claude-code"] })],
      ["빈 adapter 목록", async () => ({ adapters: [] })],
      ["adapter 목록 null", async () => ({ adapters: null })],
    ];
    it.each(cases)("%s → not_found, 쓰기 0", async (_name, arrange) => {
      const w = await f.secretWorld();
      const over = await arrange(w);
      const before = await f.all(w.user);
      expect(await f.local(w, over)).toEqual({ status: "not_found" });
      expect(await f.all(w.user)).toEqual(before);
    });

    it.each(cases)("%s → 쓰기 길에 닿지 않는다: 잠그기 전에 거른다 (agent_tasks 쓰기를 터뜨리는 덫으로 확인)", async (_name, arrange) => {
      const w = await f.secretWorld();
      const over = await arrange(w);
      await f.q("begin");
      try {
        await f.q("create function public.tmp_f2_probe() returns trigger language plpgsql as $$ begin raise exception 'F2_PROBE_REACHED_WRITE_PATH'; end $$");
        await f.q("create trigger tmp_f2_probe before update on public.agent_tasks for each row execute function public.tmp_f2_probe()");
        expect(await f.local(w, over)).toEqual({ status: "not_found" });
      } finally {
        await f.q("rollback");
      }
    });

    const stale: [string, (w: Awaited<ReturnType<typeof f.secretWorld>>) => Promise<unknown>][] = [
      ["연결 error", async (w) => f.updateRow("agent_connections", w.connection, { status: "error" })],
      ["연결 revoked(bridge는 active)", async (w) => f.updateRow("agent_connections", w.connection, { status: "revoked" })],
      ["세션 external", async (w) => f.updateRow("agent_sessions", w.session, { status: "external" })],
      ["세션 closed", async (w) => f.updateRow("agent_sessions", w.session, { status: "closed" })],
      ["run 끝", async (w) => f.updateRow("execution_runs", w.run, { state: "stopped" })],
      ["취소 요청", async (w) => f.q("update public.agent_tasks set cancel_requested_at=now() where id=$1", [w.task])],
    ];
    it.each(stale)("%s → stale, 쓰기 0", async (_name, arrange) => {
      const w = await f.secretWorld();
      await arrange(w);
      const before = await f.all(w.user);
      expect(await f.local(w)).toEqual({ status: "stale", reason: "question_closed" });
      expect(await f.all(w.user)).toEqual(before);
    });
  });

  describe("T5 질문 모양", () => {
    it("비밀값 없는 input → stale/not_secret, 쓰기 0", async () => {
      const w = await f.secretWorld(answerQuestionFixture());
      const before = await f.all(w.user);
      expect(await f.local(w)).toEqual({ status: "stale", reason: "not_secret" });
      expect(await f.all(w.user)).toEqual(before);
    });

    it.each([false, true])("승인 질문(비밀값 표시 %s)은 이 길로 답할 수 없다: stale/not_secret, 쓰기 0 · lease 변화 0", async (secret) => {
      const w = await f.secretWorld(answerQuestionFixture({ secret }, { kind: "approval" }));
      const before = await f.all(w.user);
      expect(await f.local(w)).toEqual({ status: "stale", reason: "not_secret" });
      expect(await f.all(w.user)).toEqual(before);
    });

    it("digest가 다르면 stale/question_closed (쓰기 0)", async () => {
      const w = await f.secretWorld();
      const before = await f.all(w.user);
      for (const digest of [sha256("other"), sha256(CANARY), "0".repeat(64), "f".repeat(64)]) {
        expect(await f.local(w, { digest })).toEqual({ status: "stale", reason: "question_closed" });
      }
      expect(await f.all(w.user)).toEqual(before);
    });

    it.each([
      ["대문자", sha256(REQUEST).toUpperCase()],
      ["63자", sha256(REQUEST).slice(1)],
      ["65자", `${sha256(REQUEST)}0`],
      ["16진이 아님", `${"g".repeat(64)}`],
      ["빈 글", ""],
      ["앞뒤 공백", ` ${sha256(REQUEST)}`],
      ["줄 끝 개행", `${sha256(REQUEST)}\n`],
      ["카나리 글", CANARY],
    ])("모양이 틀린 digest(%s) → invalid, 쓰기 0", async (_name, digest) => {
      const w = await f.secretWorld();
      const before = await f.all(w.user);
      expect(await f.local(w, { digest })).toEqual({ status: "invalid" });
      expect(await f.all(w.user)).toEqual(before);
    });

    it("질문이 바뀐 뒤 옛 digest → stale/question_closed이고 새 질문의 답 단계는 0", async () => {
      const w = await f.secretWorld();
      const first = await f.local(w);
      expect(first.status).toBe("answered");
      await f.updateRow("agent_tasks", w.task, { state: "awaiting_answer", pending_question: { ...secretQuestionOf(w.task, "next"), asked_at: "2026-10-14T00:00:00Z" } });
      const before = await f.all(w.user);
      expect(await f.local(w)).toEqual({ status: "stale", reason: "question_closed" });
      expect(await f.all(w.user)).toEqual(before);
      expect((await f.answerSteps(w.task)).filter((s) => (s.args as { provider_request_id: string }).provider_request_id === "next")).toEqual([]);
      expect(await f.local(w, { digest: sha256("next") })).toMatchObject({ status: "answered" });
    });

    it("heartbeat가 끊겨 작업이 unreachable이면 stale/not_live (참고 이유), 쓰기 0", async () => {
      const w = await f.secretWorld();
      await f.updateRow("agent_tasks", w.task, { state: "unreachable", last_live_state: "awaiting_answer" });
      const before = await f.all(w.user);
      expect(await f.local(w)).toEqual({ status: "stale", reason: "not_live" });
      expect(await f.all(w.user)).toEqual(before);
      // 되살아난 뒤에는 같은 digest로 다시 표시할 수 있다
      await f.updateRow("agent_tasks", w.task, { state: "awaiting_answer" });
      expect((await f.local(w)).status).toBe("answered");
    });

    it("이미 답이 간 질문이 아니고 닫힌 작업이면(idle · failed · cancelled) stale/question_closed", async () => {
      for (const state of ["idle", "failed", "cancelled"]) {
        const w = await f.secretWorld();
        await f.updateRow("agent_tasks", w.task, { state, pending_question: null });
        expect(await f.local(w)).toEqual({ status: "stale", reason: "question_closed" });
      }
    });
  });

  describe("T6 지표", () => {
    it("answered마다 정확히 한 줄 question_answered {kind, adapter, answered_locally}", async () => {
      const w = await f.secretWorld();
      expect(await f.metrics(w.user)).toEqual([]);
      await f.local(w);
      expect(await f.metrics(w.user)).toEqual([{ type: "question_answered", props: { kind: "input", adapter: "agent:codex", answered_locally: true } }]);
    });

    it("duplicate · stale · not_found · invalid · 롤백된 not_found에는 지표가 없다", async () => {
      const w = await f.secretWorld();
      await f.local(w);
      expect(await f.metrics(w.user)).toHaveLength(1);
      await f.local(w); // duplicate
      await f.local(w, { digest: sha256("other") }); // stale
      await f.local(w, { bridge: await f.bridge(w.user) }); // not_found
      await f.local(w, { digest: "x" }); // invalid
      expect(await f.metrics(w.user)).toHaveLength(1);
      const plain = await f.secretWorld(answerQuestionFixture());
      await f.local(plain); // not_secret
      expect(await f.metrics(plain.user)).toEqual([]);
    });

    it("지표를 쓰지 못하면 답 단계 · 명령 · 대화 줄도 남지 않는다 (같은 트랜잭션)", async () => {
      const w = await f.secretWorld();
      const before = await f.all(w.user);
      await f.q("alter table public.metric_events add constraint tmp_f2_no_local check (not (type = 'question_answered' and props ? 'answered_locally')) not valid");
      try {
        await expect(f.local(w)).rejects.toThrow(/tmp_f2_no_local/);
      } finally {
        await f.q("alter table public.metric_events drop constraint tmp_f2_no_local");
      }
      expect(await f.all(w.user)).toEqual(before);
      expect(await f.answerSteps(w.task)).toEqual([]);
    });
  });

  describe("T7 전달 연결", () => {
    it("표시 뒤 주인 bridge의 lease는 { answered_locally: true, answers: null, answer_text: null }이고, 다른 bridge의 lease는 not_found. 남의 사용자는 RLS로 볼 수 없다", async () => {
      const w = await f.world();
      await f.lease(w);
      await f.bridgeEvent(w, f.event(w, "question", { text: "Answer on this Mac", question: answerQuestionFixture({ secret: true, options: [] }) }));
      const result = await f.local(w);
      expect(result.status).toBe("answered");
      const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [result.step_id])).id);
      const stranger = await f.bridge(w.user);
      expect(await f.lease({ ...w, bridge: stranger, command })).toMatchObject({ status: "not_found" });
      expect(await f.lease({ ...w, command })).toMatchObject({ status: "leased", command: { kind: "answer", answered_locally: true, answers: null, answer_text: null } });
      const other = await f.user();
      await db().asUser(other, async () => {
        expect(await f.q("select id from public.bridge_commands where id=$1", [command])).toEqual([]);
        expect(await f.q("select id from public.execution_steps where id=$1", [result.step_id])).toEqual([]);
      });
      await db().asUser(w.user, async () => {
        expect(await f.q("select id from public.bridge_commands where id=$1", [command])).toEqual([{ id: command }]);
      });
    });
  });

  describe("T8 카나리", () => {
    it("카나리 글과 그 SHA-256은 거절되는 요청으로만 닿고 어느 표에도 남지 않는다", async () => {
      const w = await f.secretWorld();
      await f.local(w, { digest: CANARY });
      await f.local(w, { digest: sha256(CANARY) });
      await f.local(w, { digest: CANARY.toUpperCase() });
      expect((await f.local(w)).status).toBe("answered");
      expect((await f.local(w)).status).toBe("duplicate");
      expect(await f.occurrences(w.user, [CANARY, sha256(CANARY)])).toEqual([]);
      expect(JSON.stringify(await f.answerSteps(w.task))).not.toContain("secret_value");
    });
  });
}

/** 질문 하나(secret)를 task의 열쇠로 만든다 (질문이 바뀐 뒤를 직접 행으로 흉내 낼 때) */
function secretQuestionOf(task: string, request: string) {
  const q = answerQuestionFixture({ secret: true }, { provider_request_id: request });
  return { ...q, question_key: [task, request] };
}
