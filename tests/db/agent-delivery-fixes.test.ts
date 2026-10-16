import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { DELIVERY_FIXES_MIGRATION, deliveryFixesFixtures, deliveryFixesTests, fileBody, normalizeBody } from "./agent-delivery-fixes.scenarios";
import { asUser, createLocalSupabase, supabaseSchemaScripts } from "./local-supabase";
import { openPglite } from "./pglite-template";

// OA F3: 에이전트 전달 정리 — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/agent-delivery-fixes.test.ts (경합 P1–P15 포함)
const QS = "20261116120000_agent_questions_stop.sql";
const BC = "20261118000000_bridge_commands.sql";
const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
const handleOf = (target: () => PGlite) => () => ({
  query: async (sql: string, params?: unknown[]) => (await target().query<Record<string, unknown>>(sql, params)).rows,
  asUser: <T,>(user: string, fn: () => Promise<T>) => asUser(target(), user, fn),
});
const handle = handleOf(() => db);

describe("에이전트 전달 정리 (PGlite)", () => {
  deliveryFixesTests(handle);
});

describe("T2 교체한 세 함수는 한 곳만 다르다 (T4 본문 동일성)", () => {
  const appliedBody = async (name: string) => normalizeBody(String((await deliveryFixesFixtures(handle).one("select prosrc from pg_proc where pronamespace='public'::regnamespace and proname=$1", [name])).prosrc));
  const cases: [string, string, string, string][] = [
    ["request_agent_task_cancel", QS, "if v_question is not null then",
      "perform 1 from public.agent_sessions where id = v_task.agent_session_id and user_id = p_user_id for key share nowait; perform 1 from public.conversation_messages where id = v_task.message_id and user_id = p_user_id for key share nowait;"],
    ["revoke_bridge", BC, "order by id for update loop", "perform 1 from public.conversation_messages where id=t.message_id and user_id=p_user_id for key share nowait;"],
    ["stop_agent_runs_on_user_claim", QS, "order by id for no key update loop", ""],
  ];
  it.each(cases)("%s: 새 본문 = 원본에서 기준 글자 뒤에 넣은 것(또는 치환한 것) 하나만 다르다 (T4a · T4b · T4d)", async (name, file, base, insert) => {
    const original = fileBody(file, name);
    expect(original.split(base).length - 1, "원본에 기준 글자가 정확히 한 번").toBe(1);
    const expected = name === "stop_agent_runs_on_user_claim"
      ? original.replace(base, "order by agent_session_id, id for no key update loop")
      : original.replace(base, `${base} ${insert}`);
    expect(fileBody(DELIVERY_FIXES_MIGRATION, name)).toBe(expected);
    // 실제로 적용된 본문도 파일과 같다
    expect(await appliedBody(name)).toBe(expected);
  });

  it("넣은 줄의 자리: request_agent_task_cancel은 질문 갈래 안 · 그 갈래의 첫 작업 행 갱신보다 앞, 갈래 밖(질문 없는 경로)에는 없다", async () => {
    const body = await appliedBody("request_agent_task_cancel");
    const branch = body.indexOf("if v_question is not null then");
    const session = body.indexOf("perform 1 from public.agent_sessions where id = v_task.agent_session_id and user_id = p_user_id for key share nowait;");
    const message = body.indexOf("perform 1 from public.conversation_messages where id = v_task.message_id and user_id = p_user_id for key share nowait;");
    const firstUpdate = body.indexOf("update public.agent_tasks", branch);
    expect(branch).toBeGreaterThan(0);
    expect(session).toBeGreaterThan(branch);
    expect(message).toBeGreaterThan(session);
    expect(firstUpdate).toBeGreaterThan(message);
    expect(body.split("for key share nowait").length - 1, "KS NOWAIT는 정확히 둘").toBe(2);
    expect(body.indexOf("for key share nowait")).toBeGreaterThan(branch); // 갈래 앞에는 하나도 없다
    // 갈래 안의 첫 `end if;`보다 앞: 같은 if 블록 안이다
    expect(body.indexOf("end if;", branch)).toBeGreaterThan(message);
  });

  it("revoke_bridge는 메시지 KS NOWAIT가 작업 고리 안에서 첫 쓰기 · request_agent_task_cancel 호출보다 앞이다", async () => {
    const body = await appliedBody("revoke_bridge");
    const loop = body.indexOf("order by id for update loop");
    const lock = body.indexOf("for key share nowait", loop);
    expect(loop).toBeGreaterThan(0);
    expect(lock).toBeGreaterThan(loop);
    expect(body.split("for key share nowait").length - 1).toBe(1);
    expect(body.indexOf("update public.agent_tasks", loop)).toBeGreaterThan(lock);
    expect(body.indexOf("public.request_agent_task_cancel", loop)).toBeGreaterThan(lock);
  });

  it("stop_agent_runs_on_user_claim의 run 고리는 agent_session_id, id 순이고, task 고리는 그대로 id 순이다", async () => {
    const body = await appliedBody("stop_agent_runs_on_user_claim");
    expect(body).toContain("order by agent_session_id, id for no key update loop");
    expect(body).not.toMatch(/order by id for no key update/);
    expect(body).toContain("and state in ('dispatched','accepted','running','awaiting_answer','unreachable') order by id loop");
  });
});

describe("T2 지문 · 되돌리기 (T4c)", () => {
  const fingerprint = async (target: PGlite) => {
    const rows = async (sql: string) => JSON.stringify((await target.query(sql)).rows);
    return {
      tables: await rows("select table_name from information_schema.tables where table_schema = 'public' order by 1"),
      columns: await rows("select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position"),
      functions: await rows("select p.oid::regprocedure::text as sig, md5(pg_get_functiondef(p.oid)) as def, p.proacl::text as acl, p.proconfig::text as config from pg_proc p where p.pronamespace = 'public'::regnamespace order by 1"),
      triggers: await rows("select c.relname, t.tgname, md5(pg_get_triggerdef(t.oid)) as def from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal order by 1, 2"),
      constraints: await rows("select conrelid::regclass::text as tbl, conname, md5(pg_get_constraintdef(oid)) as def from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2"),
      indexes: await rows("select tablename, indexname, indexdef from pg_indexes where schemaname = 'public' order by 1, 2"),
      policies: await rows("select tablename, policyname, md5(coalesce(qual, '') || coalesce(with_check, '')) as def from pg_policies where schemaname = 'public' order by 1, 2"),
    };
  };
  const original = (file: string, name: string) => {
    const match = readFileSync(path.join(MIGRATIONS, file), "utf8").match(new RegExp(`create function public\\.${name}\\([^)]*\\)[\\s\\S]*?\\$\\$;`));
    if (!match) throw new Error(`${name} not found in ${file}`);
    return match[0].replace(/^create function/, "create or replace function");
  };

  it("이 마이그레이션은 새 함수 하나와 색인 하나를 더하고 세 함수의 본문만 바꾼다: 그 밖의 함수 · 권한 · proconfig · 표 · 열 · 트리거 · 제약 · 정책이 그대로이고, 머리의 되돌리기를 실행하면 앞 지문으로 완전히 돌아간다", async () => {
    const sql = readFileSync(path.join(MIGRATIONS, DELIVERY_FIXES_MIGRATION), "utf8");
    const scripts = await supabaseSchemaScripts();
    const before = scripts.filter((script) => script !== sql);
    expect(before).toHaveLength(scripts.length - 1);
    const clone = await openPglite(before);
    try {
      const baseline = await fingerprint(clone);
      await clone.exec(sql);
      const after = await fingerprint(clone);
      type Fn = { sig: string; def: string; acl: string; config: string };
      const oldFns = JSON.parse(baseline.functions) as Fn[];
      const newFns = JSON.parse(after.functions) as Fn[];
      expect(newFns.filter((fn) => !oldFns.some((old) => old.sig === fn.sig)).map((fn) => fn.sig)).toEqual(["expire_unleased_agent_messages(integer)"]);
      expect(oldFns.filter((old) => !newFns.some((fn) => fn.sig === old.sig))).toEqual([]);
      const changed = oldFns.filter((old) => newFns.find((fn) => fn.sig === old.sig)!.def !== old.def).map((old) => old.sig).sort();
      expect(changed).toEqual(["request_agent_task_cancel(uuid,uuid)", "revoke_bridge(uuid,uuid)", "stop_agent_runs_on_user_claim()"]);
      for (const old of oldFns) {
        const next = newFns.find((fn) => fn.sig === old.sig)!;
        expect({ acl: next.acl, config: next.config }, old.sig).toEqual({ acl: old.acl, config: old.config });
      }
      for (const key of ["tables", "columns", "triggers", "constraints", "policies"] as const) expect(after[key], key).toBe(baseline[key]);
      const addedIndexes = (JSON.parse(after.indexes) as { indexname: string }[]).filter((index) => !(JSON.parse(baseline.indexes) as { indexname: string }[]).some((old) => old.indexname === index.indexname));
      expect(addedIndexes.map((index) => index.indexname)).toEqual(["bridge_commands_unleased_message_idx"]);
      const revert = /^-- 되돌리기: (drop function public\.expire_unleased_agent_messages\(integer\);) (drop index public\.bridge_commands_unleased_message_idx;)\s*$/m.exec(sql);
      expect(revert, "머리 주석에 되돌리기 문장").not.toBeNull();
      await clone.exec(`${revert![1]} ${revert![2]}`);
      for (const [file, name] of [[QS, "request_agent_task_cancel"], [QS, "stop_agent_runs_on_user_claim"], [BC, "revoke_bridge"]] as const) await clone.exec(original(file, name));
      expect(await fingerprint(clone)).toEqual(baseline);
    } finally {
      await clone.close();
    }
  }, 120_000);
});

describe("T3 Done 결과 불변 (마이그레이션 앞 · 뒤 끝 상태가 같다)", () => {
  const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;
  const TIME = /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?/g;
  const plain = (value: unknown) => JSON.parse(JSON.stringify(value).replace(UUID, "<id>").replace(TIME, "<time>"));

  async function endStates(target: () => PGlite) {
    const f = deliveryFixesFixtures(handleOf(target));
    const out: Record<string, unknown> = {};
    const finish = async (name: string, w: { user: string; run: string; task: string; action: string }) => {
      await f.done(w.user, w.action);
      out[name] = plain({
        run: await f.one("select state from public.execution_runs where id=$1", [w.run]),
        task: await f.one("select state, last_live_state, pending_question is null as no_pending, answered_question is null as no_answered, abandoned_question is not null as abandoned, cancel_requested_at is not null as cancel_requested, external_task_id is null as no_external from public.agent_tasks where id=$1", [w.task]),
        steps: await f.q("select seq, kind, state, receipt, needs_approval, purpose like 'cancel:%' as is_cancel from public.execution_steps where run_id=$1 order by seq", [w.run]),
        commands: await f.q("select kind, outcome, outcome_at is not null as settled, lease_owner is null as unleased from public.bridge_commands where user_id=$1 order by cursor", [w.user]),
        messages: await f.q("select role, delivery_state, delivery_reason from public.conversation_messages where user_id=$1 order by created_at, seq", [w.user]),
        events: await f.q("select type, to_state, payload->>'event_type' as event_type, payload->>'decision' as decision from public.execution_events where run_id=$1 order by id", [w.run]),
        metrics: await f.q("select type, count(*)::int as n from public.metric_events where user_id=$1 group by type order by type", [w.user]),
        claims: await f.q("select field, value, origin, count(*)::int as n from public.claims where action_id=$1 group by field, value, origin order by field, value, origin", [w.action]),
        actionEvents: await f.q("select type, count(*)::int as n from public.action_events where action_id=$1 group by type order by type", [w.action]),
      });
    };
    // 1) 질문 없음
    const plainWorld = await f.world();
    await f.lease(plainWorld);
    expect(await f.bridgeEvent(plainWorld, f.event(plainWorld, "accepted"))).toMatchObject({ status: "applied" });
    await finish("no question", plainWorld);
    // 2) 질문 있음 — Codex 취소 단계 갈래 · Claude Code 거절 갈래
    for (const adapter of ["agent:codex", "agent:claude-code"]) {
      await finish(`question ${adapter}`, await f.questionWorld(answerQuestionFixture(), adapter));
    }
    // 3) lease 전 답 (답 명령이 아직 Mac에 가지 않음) — 두 adapter
    for (const adapter of ["agent:codex", "agent:claude-code"]) {
      const w = await f.questionWorld(answerQuestionFixture(), adapter);
      expect((await f.answer(w.user, w.task)).status).toBe("answered");
      await finish(`answer before lease ${adapter}`, w);
    }
    // 4) lease 전 dispatched
    await finish("dispatched before lease", await f.world());
    return out;
  }

  it("질문 없음 · 질문 있음(Codex · Claude Code) · lease 전 답(둘) · lease 전 dispatched 여섯 경로의 끝 상태가 마이그레이션 앞 · 뒤에 같다", async () => {
    const sql = readFileSync(path.join(MIGRATIONS, DELIVERY_FIXES_MIGRATION), "utf8");
    const scripts = await supabaseSchemaScripts();
    const clone = await openPglite(scripts.filter((script) => script !== sql));
    try {
      const before = await endStates(() => clone);
      const after = await endStates(() => db);
      expect(Object.keys(after)).toHaveLength(6);
      expect(after).toEqual(before);
      for (const [name, state] of Object.entries(after)) expect((state as { run: unknown }).run, name).toEqual({ state: "stopped" });
    } finally {
      await clone.close();
    }
  }, 120_000);
});
