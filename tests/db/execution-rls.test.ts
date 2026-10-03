import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 실행 코어(20261021000000_execution_core)의 권한: 앱은 자기 정책 · run · step · 승인을 읽기만 한다.
// 쓰기와 RPC는 서버(service role)만, 운영 표(intent · 스위치 · 도구 · 허용 목록 · 이벤트)는 클라이언트가 읽지도 못한다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const ACTION = "11111111-1111-4111-8111-111111111111";

let db: PGlite;
let runId: string;
let stepId: string;

const OWNER_TABLES = ["execution_policies", "execution_runs", "execution_steps", "execution_approvals"];
/** 이 마이그레이션의 함수 중 이름이 execution_으로 시작하지 않는 것 (execution_* 은 카탈로그에서 이름으로 찾는다) */
const CORE_FUNCTIONS = [
  "db_now", "norm_address", "norm_addresses", "auto_allowed", "approval_hash", "create_run", "append_step", "prepare_step", "begin_call",
  "finish_run", "settle_step", "mark_unknown", "sweep_expire", "readback_settle", "show_plan", "approve_step", "revoke_approval", "stop_run",
];
/** 실행 표를 쓰는 다른 마이그레이션의 함수 (20261024000000_execution_text_retention: 끝난 run의 글 지우기) */
const RETENTION_FUNCTIONS = ["purge_expired_execution_text"];
const HELPER_FUNCTIONS = [
  "execution_hold", "execution_recipients_valid", "execution_retry_internal", "execution_runs_log", "execution_skip", "execution_steps_log",
  "execution_steps_replan",
];
const SERVER_TABLES = ["execution_intents", "execution_controls", "execution_tools", "execution_actors", "execution_recipient_allowlist", "execution_events"];

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  await db.query("insert into public.actions (id, user_id, title) values ($1, $2, '제안서 쓰기')", [ACTION, ALICE]);
  // 서버가 하듯: run을 만들고 계획 단계를 calling까지 (intent · 이벤트 행이 생긴다), 승인 행 하나
  await db.query("insert into public.execution_actors (user_id) values ($1)", [ALICE]);
  await db.query("update public.execution_controls set blocked = false where scope = 'global'");
  runId = (await db.query<{ id: string }>("select public.create_run($1, $2, 'draft', '초안 써 줘') as id", [ALICE, ACTION])).rows[0].id;
  stepId = (await db.query<{ id: string }>("select id from public.execution_steps where run_id = $1", [runId])).rows[0].id;
  await db.query("select public.prepare_step($1, 0)", [stepId]);
  const { rows } = await db.query<{ g: { gate: string } }>("select public.begin_call($1, 'fn-1', 1) as g", [stepId]);
  expect(rows[0].g.gate).toBe("ok");
  await db.query("insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', now() + interval '1 hour')", [ALICE, stepId]);
  await db.query("insert into public.execution_recipient_allowlist (address) values ('rule@example.com')");
}, 60_000);

describe("실행 코어 RLS · 권한", () => {
  it("사용자는 자기 정책 · run · step · 승인을 읽는다", async () => {
    await asUser(db, ALICE, async () => {
      for (const table of OWNER_TABLES) {
        const { rows } = await db.query(`select * from public.${table}`);
        expect(rows.length, table).toBeGreaterThan(0);
      }
    });
  });

  it("다른 사용자의 정책 · run · step · 승인은 보이지 않는다", async () => {
    await asUser(db, BOB, async () => {
      for (const table of OWNER_TABLES) {
        expect((await db.query(`select * from public.${table}`)).rows, table).toHaveLength(0);
      }
    });
  });

  it("클라이언트는 정책 · run · step · 승인을 만들거나 고치거나 지울 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query("insert into public.execution_policies (user_id) values ($1)", [ALICE])).rejects.toThrow(/permission denied/);
      await expect(
        db.query("insert into public.execution_runs (user_id, action_id, policy_id, goal, request) select $1, $2, id, 'draft', 'x' from public.execution_policies", [
          ALICE,
          ACTION,
        ]),
      ).rejects.toThrow(/permission denied/);
      await expect(db.query("update public.execution_runs set state = 'done' where id = $1", [runId])).rejects.toThrow(/permission denied/);
      await expect(db.query("update public.execution_steps set state = 'called' where id = $1", [stepId])).rejects.toThrow(/permission denied/);
      await expect(db.query("delete from public.execution_steps where id = $1", [stepId])).rejects.toThrow(/permission denied/);
      await expect(
        db.query("insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', now())", [ALICE, stepId]),
      ).rejects.toThrow(/permission denied/);
      await expect(db.query("update public.execution_approvals set revoked_at = null")).rejects.toThrow(/permission denied/);
      await expect(db.query("update public.execution_policies set mode = 'full'")).rejects.toThrow(/permission denied/);
    });
  });

  it("운영 표(intent · 스위치 · 도구 · 실행 주체 · 수신자 허용 목록 · 이벤트)는 클라이언트가 읽지도 쓰지도 못한다", async () => {
    const counts = await db.query<{ n: number }>(
      `select (select count(*) from public.execution_intents) + (select count(*) from public.execution_events) + (select count(*) from public.execution_actors) as n`,
    );
    expect(Number(counts.rows[0].n)).toBeGreaterThan(0); // 서버에서는 행이 있다
    for (const role of ["authenticated", "anon"]) {
      await db.exec(`set role ${role}; select set_config('request.jwt.claim.sub', '${ALICE}', false);`);
      try {
        for (const table of SERVER_TABLES) {
          await expect(db.query(`select * from public.${table}`), `${role} ${table}`).rejects.toThrow(/permission denied/);
        }
        await expect(db.query("update public.execution_controls set blocked = false")).rejects.toThrow(/permission denied/);
        await expect(db.query("insert into public.execution_actors (user_id) values ($1)", [BOB])).rejects.toThrow(/permission denied/);
        await expect(db.query("insert into public.execution_recipient_allowlist (address) values ('x@example.com')")).rejects.toThrow(/permission denied/);
      } finally {
        await db.exec("reset role; select set_config('request.jwt.claim.sub', '', false);");
      }
    }
  });

  it("실행 코어 · 실행의 글 정리 함수는 모두 서버 전용이다: 카탈로그의 모든 함수에 anon · authenticated 실행 권한이 없고 service_role만 있다", async () => {
    const { rows } = await db.query<{ name: string; anon: boolean; authenticated: boolean; service_role: boolean }>(
      `select p.proname as name,
              has_function_privilege('anon', p.oid, 'execute') as anon,
              has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
              has_function_privilege('service_role', p.oid, 'execute') as service_role
       from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and (p.proname like 'execution\\_%' or p.proname = any ($1))
       order by p.proname`,
      [[...CORE_FUNCTIONS, ...RETENTION_FUNCTIONS]],
    );
    expect(rows.map((r) => r.name)).toEqual([...CORE_FUNCTIONS, ...RETENTION_FUNCTIONS, ...HELPER_FUNCTIONS].sort());
    for (const row of rows) expect(row, row.name).toEqual({ name: row.name, anon: false, authenticated: false, service_role: true });

    // 모두 search_path = ''. 소유자 권한(security definer)은 이벤트 기록 트리거 둘뿐이다 (정리 함수 · 바꿔 만든 계획 동결 트리거는 호출자 권한)
    const settings = await db.query<{ name: string; definer: boolean; config: string[] | null }>(
      `select p.proname as name, p.prosecdef as definer, p.proconfig as config
       from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and (p.proname like 'execution\\_%' or p.proname = any ($1))`,
      [[...CORE_FUNCTIONS, ...RETENTION_FUNCTIONS]],
    );
    for (const row of settings.rows) expect(row.config, row.name).toContain('search_path=""');
    expect(settings.rows.filter((r) => r.definer).map((r) => r.name).sort()).toEqual(["execution_runs_log", "execution_steps_log"]);
  });

  it("service_role은 RPC로 run을 만들고 단계를 준비 · 부른다 (트리거 · 검사 함수가 service_role 권한으로 돈다)", async () => {
    const action = (await db.query<{ id: string }>("insert into public.actions (user_id, title) values ($1, '다른 할 일') returning id", [ALICE])).rows[0].id;
    await db.exec("set role service_role");
    try {
      const run = (await db.query<{ id: string }>("select public.create_run($1, $2, 'draft', '초안') as id", [ALICE, action])).rows[0].id;
      const step = (await db.query<{ id: string }>("select id from public.execution_steps where run_id = $1", [run])).rows[0].id;
      await db.query("select public.prepare_step($1, 0)", [step]);
      expect((await db.query<{ g: { gate: string } }>("select public.begin_call($1, 'fn-2', 1) as g", [step])).rows[0].g.gate).toBe("ok");
      const events = await db.query("select 1 from public.execution_events where run_id = $1", [run]);
      expect(events.rows.length).toBeGreaterThan(0);
    } finally {
      await db.exec("reset role");
    }
  });

  it.each([
    ["create_run", "select public.create_run($1, $2, 'draft', 'x')", [ALICE, ACTION]],
    ["append_step", "select public.append_step($1, 2, '{}')", ["run"]],
    ["prepare_step", "select public.prepare_step($1, 0)", ["step"]],
    ["begin_call", "select public.begin_call($1, 'fn', 0)", ["step"]],
    ["settle_step", "select public.settle_step($1, 'fn-1', 'called', '{}')", ["step"]],
    ["mark_unknown", "select public.mark_unknown($1, 'fn-1')", ["step"]],
    ["finish_run", "select public.finish_run($1)", ["run"]],
    ["sweep_expire", "select public.sweep_expire()", []],
    ["readback_settle", "select public.readback_settle($1, '{}')", ["step"]],
    ["show_plan", "select * from public.show_plan($1, $2)", [ALICE, "step"]],
    ["approve_step", "select public.approve_step($1, $2, 'h', now())", [ALICE, "step"]],
    ["revoke_approval", "select public.revoke_approval($1, $2)", [ALICE, "step"]],
    ["stop_run", "select public.stop_run($1, $2)", [ALICE, "run"]],
    ["approval_hash", "select public.approval_hash($1, now())", ["step"]],
    ["auto_allowed", "select public.auto_allowed($1)", ["step"]],
    ["db_now", "select public.db_now()", []],
    ["purge_expired_execution_text", "select public.purge_expired_execution_text(now() + interval '1 day')", []],
  ] as [string, string, string[]][])("클라이언트는 %s를 부를 수 없다 (서버 전용 RPC)", async (_, sql, params) => {
    const values = params.map((p) => (p === "run" ? runId : p === "step" ? stepId : p));
    await asUser(db, ALICE, async () => {
      await expect(db.query(sql, values)).rejects.toThrow(/permission denied/);
    });
  });
});
