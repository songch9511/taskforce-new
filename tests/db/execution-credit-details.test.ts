import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { loadCreditDetails, loadCredits } from "@/lib/execution/store";

import { pgliteAdmin } from "../execution/pglite-admin";
import { createLocalSupabase } from "./local-supabase";

// GET /api/v1/credits의 Usage & Credits(S3) 숫자(U2 Mac PR1) × 운영 마이그레이션 (PGlite). 운영 store.ts의 loadCreditDetails를 그대로 부른다:
// 읽기만 PostgREST 대신 작은 흉내(tests/execution/pglite-admin.ts)가 같은 뜻의 SQL로 옮긴다.
// 원장 상태는 실행기가 부르는 순서 그대로 SQL 함수로 만든다(execution-credits.test.ts와 같은 흐름): 예약만 · 정산 · 해제 · 정산 보류(A46).

const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;
const ARTIFACT = { title: "제안서 초안", body: "안녕하세요, 제안서를 보내드립니다.", model: "z-ai/glm-5.3-flash", prompt_version: "draft-v1" };
const MONTH_START = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1));

let db: PGlite;
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];

type Attempt = { generationId: string; model: string; usage: { prompt_tokens: number; completion_tokens: number; cost?: number } };
/** cost를 주지 않으면 비용을 모르는 시도 (A46) */
const attempt = (cost?: number): Attempt => ({
  generationId: `gen-${randomUUID()}`,
  model: "z-ai/glm-5.3-flash",
  usage: { prompt_tokens: 1200, completion_tokens: 400, ...(cost === undefined ? {} : { cost }) },
});

async function newUser(credits = 0) {
  const userId = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await db.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  if (credits) await db.query("select public.grant_credits($1, $2, $3)", [userId, credits, randomUUID()]);
  return userId;
}

/** 단계를 준비하고(pending이면) 지금 버전으로 begin_call */
async function gate(stepId: string, owner = "fn-1") {
  const step = await one<{ state: string; version: number }>("select state, version from public.execution_steps where id = $1", [stepId]);
  let version = step.version;
  if (step.state === "pending") {
    await db.query("select public.prepare_step($1, $2)", [stepId, version]);
    version += 1;
  }
  return (await one<{ g: { gate: string } }>("select public.begin_call($1, $2, $3) as g", [stepId, owner, version])).g.gate;
}

const complete = async (stepId: string, attempts: Attempt[], artifact: object | null, owner = "fn-1") =>
  (
    await one<{ ok: boolean }>("select public.complete_internal_step($1, $2, '{}', $3::jsonb, $4::jsonb, null) as ok", [
      stepId,
      owner,
      JSON.stringify(attempts),
      artifact === null ? null : JSON.stringify(artifact),
    ])
  ).ok;

/** 할 일(주면 그것) 하나에 run → 계획 단계 끝 → 초안 단계(추정치 20, pending)까지 */
async function draftRun(userId: string, actionId?: string) {
  const action = actionId ?? (await one<{ id: string }>("insert into public.actions (user_id, title) values ($1, '제안서 보내기') returning id", [userId])).id;
  const runId = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '제안서 초안 써 줘') as id", [userId, action])).id;
  const planId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1 and seq = 1", [runId])).id;
  expect(await gate(planId)).toBe("ok");
  const step = { kind: "draft", provider: "taskforce", tool: "draft", purpose: "draft-1", estimate_credits: 20 };
  const draftId = (await one<{ id: string }>("select public.append_step($1, 2, $2::jsonb) as id", [runId, JSON.stringify(step)])).id;
  expect(await complete(planId, [attempt(0.0007)], null)).toBe(true);
  return { actionId: action, runId, draftId };
}

const details = (userId: string, since = MONTH_START) => loadCreditDetails(pgliteAdmin(db), userId, since);

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(TEST_CLOCK);
  await db.query("update public.execution_controls set blocked = false where scope = 'global'");
}, 60_000);

describe("loadCreditDetails × 원장 (Usage & Credits 숫자)", () => {
  it("지급 기록이 없으면 모두 0", async () => {
    expect(await details(await newUser())).toEqual({
      running_runs: 0,
      settling: { steps: 0, reserved: 0, action_ids: [] },
      used: { credits: 0, since: MONTH_START.toISOString() },
    });
  });

  it("예약만(초안을 부르는 중): 진행 중 run 1, 정산 보류 0, 사용 0. lease가 끝나 다시 준비된 단계(prepared)도 예약을 쥔 채 진행 중이다", async () => {
    const user = await newUser(100);
    const { draftId } = await draftRun(user);
    expect(await gate(draftId)).toBe("ok");
    expect(await details(user)).toMatchObject({ running_runs: 1, settling: { steps: 0, reserved: 0, action_ids: [] }, used: { credits: 0 } });

    await db.query("select public.mark_unknown($1, 'fn-1')", [draftId]); // 응답 없음 → 다시 준비 (예약 그대로)
    expect(await one("select state from public.execution_steps where id = $1", [draftId])).toEqual({ state: "prepared" });
    expect((await details(user)).running_runs).toBe(1);
  });

  it("정산: 예약이 닫히고 사용 = 정산 크레딧(원가 올림). 해제한 나머지는 어디에도 세지 않는다", async () => {
    const user = await newUser(100);
    const { draftId } = await draftRun(user);
    expect(await gate(draftId)).toBe("ok");
    expect(await complete(draftId, [attempt(0.0023)], ARTIFACT)).toBe(true); // ceil(2.3) = 3, 17 해제
    expect(await details(user)).toMatchObject({ running_runs: 0, settling: { steps: 0, reserved: 0, action_ids: [] }, used: { credits: 3 } });
    expect(await loadCredits(pgliteAdmin(db), user)).toEqual({ available: 97, reserved: 0, rate_version: "c3-v1" });
  });

  it("해제: 부르는 중에 멈춘 run이 실패로 끝나면 예약은 모두 해제되고 사용 0", async () => {
    const user = await newUser(100);
    const { runId, draftId } = await draftRun(user);
    expect(await gate(draftId)).toBe("ok");
    await db.query("select public.stop_run($1, $2)", [user, runId]);
    // 멈춰도 부르던 단계는 끝까지 예약을 쥔다 (진행 중)
    expect((await details(user)).running_runs).toBe(1);
    await db.query("select public.settle_step($1, 'fn-1', 'failed', '{\"error\": \"rejected\"}')", [draftId]);
    expect(await details(user)).toMatchObject({ running_runs: 0, settling: { steps: 0, reserved: 0 }, used: { credits: 0 } });
    expect(await loadCredits(pgliteAdmin(db), user)).toEqual({ available: 100, reserved: 0, rate_version: "c3-v1" });
  });

  it("정산 보류(A46): 끝낸 초안의 원가가 미확정이면 settling에 예약 · 할 일 id(같은 할 일은 한 번). 진행 중 예약 = reserved - settling.reserved", async () => {
    const user = await newUser(100);
    const first = await draftRun(user);
    const second = await draftRun(user, first.actionId); // 같은 할 일의 다른 run
    const other = await draftRun(user);
    for (const run of [first, second]) {
      expect(await gate(run.draftId)).toBe("ok");
      expect(await complete(run.draftId, [attempt()], ARTIFACT)).toBe(true); // 비용을 모른다 → 정산하지 않고 예약을 둔다
    }
    expect(await gate(other.draftId)).toBe("ok"); // 부르는 중인 run 하나

    const result = await details(user);
    expect(result).toMatchObject({ running_runs: 1, settling: { steps: 2, reserved: 40, action_ids: [first.actionId] }, used: { credits: 0 } });
    const totals = await loadCredits(pgliteAdmin(db), user);
    expect(totals.reserved).toBe(60);
    expect(totals.reserved - result.settling.reserved).toBe(20); // "Held for 1 running task"

    // sweep이 비용을 확정하면 그 자리에서 정산 · 해제된다
    for (const run of [first, second]) {
      const usage = await one<{ id: number }>("select id::int from public.execution_usage where step_id = $1", [run.draftId]);
      await db.query("select public.reconcile_usage($1, 0.0012)", [usage.id]);
    }
    expect(await details(user)).toMatchObject({ running_runs: 1, settling: { steps: 0, reserved: 0, action_ids: [] }, used: { credits: 4 } });
  });

  it("사용은 since 이후의 정산만 센다 (지난달 정산은 빠진다)", async () => {
    const user = await newUser(100);
    for (const cost of [0.004, 0.006]) {
      const { draftId } = await draftRun(user);
      expect(await gate(draftId)).toBe("ok");
      expect(await complete(draftId, [attempt(cost)], ARTIFACT)).toBe(true);
    }
    // 첫 정산을 지난달로 옮긴다 (원장 시각은 DB now()라 테스트 시계로 바꿀 수 없다)
    await db.query(
      "update public.credit_ledger set created_at = $2 where id = (select min(id) from public.credit_ledger where user_id = $1 and kind = 'settle')",
      [user, new Date(MONTH_START.getTime() - 1000).toISOString()],
    );
    expect((await details(user)).used).toEqual({ credits: 6, since: MONTH_START.toISOString() });
    expect((await details(user, new Date(MONTH_START.getTime() - 60_000))).used.credits).toBe(10);
  });

  it("다른 사용자의 원장 · 단계 · run은 섞이지 않는다", async () => {
    const me = await newUser(100);
    const other = await newUser(100);
    const { draftId } = await draftRun(other);
    expect(await gate(draftId)).toBe("ok");
    expect(await complete(draftId, [attempt()], ARTIFACT)).toBe(true);
    expect(await details(me)).toMatchObject({ running_runs: 0, settling: { steps: 0, reserved: 0, action_ids: [] }, used: { credits: 0 } });
    expect((await details(other)).settling.steps).toBe(1);
  });
});
