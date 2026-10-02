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
  ] as [string, string, string[]][])("클라이언트는 %s를 부를 수 없다 (서버 전용 RPC)", async (_, sql, params) => {
    const values = params.map((p) => (p === "run" ? runId : p === "step" ? stepId : p));
    await asUser(db, ALICE, async () => {
      await expect(db.query(sql, values)).rejects.toThrow(/permission denied/);
    });
  });
});
