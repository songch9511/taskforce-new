import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { loadPendingDecisions, matchPendingVersion } from "@/lib/coordinator/pending";

import { advanceClock, createExecutionDb, Driver, FakeProvider, resetExecutionDb, uid, USER } from "../execution/driver";
import { adminOf, queryOf } from "./support";

// A39 (결정 목록 단위 + 두 기기): 승인 대기 · 확인 요청 · 실패한 run이 같은 업무에 동시에 생기고, 다른 기기에서 하나를 처리한다.
// pending_decisions는 서버 계산값이다(표 없음). [현재 실제] 원천 3가지(승인 대기 단계 · run needs_input/review_failed · Action 확인 요청)를 실제 DB 함수로 읽는다.
// 열기/계산/읽기는 해결 · 승인 · Action 완료가 아니다: 계산을 여러 번 해도 어떤 표도 바뀌지 않는다.

let db: PGlite;
let driver: Driver;
const NOW = new Date("2026-10-02T00:00:00Z"); // 실행 시험 시계 (createExecutionDb)

beforeAll(async () => {
  db = await createExecutionDb();
}, 60_000);
afterAll(() => db.close());
beforeEach(async () => {
  await resetExecutionDb(db);
  driver = new Driver(db, "fn-1", new FakeProvider(db));
});

const one = async (sql: string, params: unknown[] = []) => (await db.query<Record<string, unknown>>(sql, params)).rows[0];
const load = (now: Date = NOW) => loadPendingDecisions(adminOf(db), USER, now);

/** 열린 Action + Manual 정책 + 승인이 필요한 외부 단계 n개를 준비한다 (외부로는 보내지 않는다) */
async function approvalRun(name: string, steps = 1, extra: { dueAt?: string; confirm?: boolean } = {}) {
  const action = uid(`action-${name}`);
  await db.query("insert into public.actions (id, user_id, title, due_at, needs_confirmation) values ($1, $2, '견적서 보내기', $3, $4)", [action, USER, extra.dueAt ?? null, extra.confirm ?? false]);
  await db.query(`insert into public.execution_policies (user_id, mode, auto_recipients) values ($1, 'manual', '[]') on conflict (user_id) do update set mode = 'manual'`, [USER]);
  const run = uid(name);
  await db.query(`insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request) select $1, $2, $3, p.id, 'draft', '견적서 보내 줘' from public.execution_policies p where p.user_id = $2`, [run, USER, action]);
  const stepIds: string[] = [];
  for (let i = 1; i <= steps; i++) {
    const step = uid(`${name}-s${i}`);
    stepIds.push(step);
    await db.query(
      `insert into public.execution_steps (id, user_id, run_id, seq, kind, provider, tool, purpose, connection_id, recipients, body, args)
       values ($1, $2, $3, $4, 'external', 'fake', 'send', $5, $6, $7::jsonb, '견적서 보내드립니다', '{"subject": "견적"}')`,
      [step, USER, run, i, `send-${i}`, uid("conn-1"), JSON.stringify([{ address: "other@example.com", origin: "user" }])],
    );
    // 준비 단계: 정책 평가로 needs_approval이 정해진다 (Manual이라 승인이 필요하다)
    const row = await one("select version from public.execution_steps where id = $1", [step]);
    expect((await one("select public.prepare_step($1, $2) as ok", [step, row.version])).ok).toBe(true);
  }
  return { action, run, steps: stepIds };
}

describe("[현재 실제] 승인 대기 · 확인 요청 · 실패한 run이 같은 업무에 동시에 생겼다", () => {
  it("(action, kind)로 묶이고 읽음은 결정이 아니다: 계산을 여러 번 해도 어떤 표도 바뀌지 않는다", async () => {
    const a = await approvalRun("r1", 2, { confirm: true });
    const groups = await load();
    // 같은 업무라도 종류가 다르면 따로 묶이고, 같은 종류는 한 묶음이다. 순서는 오래 기다린 묶음 먼저(안정)
    expect(groups.map((g) => [g.kind, g.items.length, g.actionId]).sort()).toEqual([["approval", 2, a.action], ["confirm", 1, a.action]]);
    expect(groups.find((g) => g.kind === "approval")!.items.map((i) => i.stepId).sort()).toEqual([...a.steps].sort());

    const snapshot = async () =>
      one(`select
        (select count(*)::int from public.actions) as actions, (select string_agg(version::text || status || needs_confirmation::text || updated_at::text, ',' order by id) from public.actions) as action_state,
        (select string_agg(state || version::text || coalesce(needs_approval::text, ''), ',' order by id) from public.execution_steps) as steps,
        (select string_agg(state || coalesce(outcome, ''), ',' order by id) from public.execution_runs) as runs,
        (select count(*)::int from public.execution_approvals) as approvals, (select count(*)::int from public.action_events) as action_events,
        (select count(*)::int from public.claims) as claims, (select count(*)::int from public.inbox_events) as inbox`);
    const before = await snapshot();
    for (let i = 0; i < 3; i++) expect(await load()).toEqual(groups);
    expect(await snapshot()).toEqual(before);
    expect((before as { inbox: number }).inbox).toBe(0);
  });

  it("다른 기기에서 승인하면 그 항목이 목록에서 사라지고(옛 version은 gone), 나머지 항목과 확인 요청은 그대로다", async () => {
    const a = await approvalRun("r2", 2, { confirm: true });
    const before = await load();
    const approvals = before.find((g) => g.kind === "approval")!;
    const seen = approvals.items[0];
    const other = approvals.items.find((i) => i.id !== seen.id)!;
    // 기기 B: 계획을 보고 승인한다 (실제 approve_step)
    const shown = await driver.showPlan(seen.stepId!);
    expect(await driver.approve(seen.stepId!, shown)).toBe(true);
    const after = await load();
    expect(matchPendingVersion(after, { itemId: seen.id, version: seen.version })).toBe("gone");
    expect(matchPendingVersion(after, { itemId: other.id, version: other.version })).toBe("current");
    expect(after.map((g) => [g.kind, g.items.length]).sort()).toEqual([["approval", 1], ["confirm", 1]]);
    // 실제 approve_step이 같은 트랜잭션에서 사건을 남겼다 (decision_made 승인). 읽기(계산)는 사건을 만들지 않았다
    expect((await db.query("select refs from public.inbox_events where type = 'decision_made'")).rows).toEqual([{ refs: { step_id: seen.stepId, run_id: a.run, kind: "approval" } }]);
    // 승인을 철회하면 같은 항목이 같은 version으로 돌아온다 (같은 계획이므로)
    await driver.revoke(seen.stepId!);
    const restored = await load();
    expect(matchPendingVersion(restored, { itemId: seen.id, version: seen.version })).toBe("current");
    expect(a.steps).toContain(seen.stepId);
  });

  it("계획이 바뀌면(다시 계획 → 단계 version 상승) 옛 version으로 본 항목은 stale이다", async () => {
    const a = await approvalRun("r3", 1);
    const [group] = await load();
    const seen = group.items[0];
    expect(group.kind).toBe("approval");
    // 계획 변경: 본문을 고치면 pending으로 되돌아가고 version이 오른다. 다시 준비하면 다시 승인 대기
    await db.query("update public.execution_steps set body = '금액을 바꾼 견적서' where id = $1", [a.steps[0]]);
    expect(await load()).toEqual([]); // pending이라 아직 승인 요청이 아니다
    const row = await one("select version from public.execution_steps where id = $1", [a.steps[0]]);
    await db.query("select public.prepare_step($1, $2)", [a.steps[0], row.version]);
    const after = await load();
    expect(matchPendingVersion(after, { itemId: seen.id, version: seen.version })).toBe("stale");
  });

  it("긴급(기한 24시간 안)은 앞선다. 기한이 먼 묶음은 오래 기다려도 긴급 뒤다", async () => {
    await approvalRun("far", 1, { dueAt: new Date(NOW.getTime() + 10 * 86_400_000).toISOString() });
    await advanceClock(db, 60_000);
    await approvalRun("near", 1, { dueAt: new Date(NOW.getTime() + 2 * 3_600_000).toISOString() });
    const groups = await load();
    expect(groups.map((g) => g.actionId)).toEqual([uid("action-near"), uid("action-far")]);
    expect(groups.map((g) => g.urgent)).toEqual([true, false]);
  });

  it("run이 needs_input / review_failed로 끝났고 그 Action이 열려 있으면 결정 대기. 더 새 run이 있거나 멈추거나 Action이 닫히면 사라진다", async () => {
    const a = await approvalRun("r4", 0);
    await db.query("update public.execution_runs set state = 'done', outcome = 'needs_input' where id = $1", [a.run]);
    const b = await approvalRun("r5", 0);
    await db.query("update public.execution_runs set state = 'done', outcome = 'review_failed' where id = $1", [b.run]);
    expect((await load()).map((g) => g.kind).sort()).toEqual(["review_failed", "run_input"]);
    // 더 새 run이 같은 Action에 생기면 옛 결과는 결정이 아니다
    await advanceClock(db, 1000);
    await db.query(`insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request) select $1, $2, $3, p.id, 'draft', '다시' from public.execution_policies p where p.user_id = $2`, [uid("r4-again"), USER, a.action]);
    expect((await load()).map((g) => g.kind)).toEqual(["review_failed"]);
    // Action을 닫으면 사라진다
    await db.query("update public.actions set status = 'done' where id = $1", [b.action]);
    expect(await load()).toEqual([]);
  });

  it("확인 요청(needs_confirmation)은 사용자가 확인하면(Action version이 오르고 요청이 풀림) 사라진다. 지운 Action의 항목도 사라진다", async () => {
    const a = await approvalRun("r6", 0, { confirm: true });
    const [group] = await load();
    const seen = group.items[0];
    expect(group.kind).toBe("confirm");
    await db.query("update public.actions set needs_confirmation = false, version = version + 1 where id = $1", [a.action]);
    expect(matchPendingVersion(await load(), { itemId: seen.id, version: seen.version })).toBe("gone");
    await db.query("update public.actions set needs_confirmation = true, version = version + 1 where id = $1", [a.action]);
    // 다시 확인 요청이 생겼지만 version이 달라 옛 화면의 행동은 stale이다
    expect(matchPendingVersion(await load(), { itemId: seen.id, version: seen.version })).toBe("stale");
    await db.query("delete from public.actions where id = $1", [a.action]);
    expect(await load()).toEqual([]);
  });

  it("남의 항목은 보이지 않는다 (소유권은 모든 조인의 user_id로 확인)", async () => {
    await approvalRun("mine", 1, { confirm: true });
    const other = "00000000-0000-0000-0000-0000000000b2";
    await db.query("insert into auth.users (id, email) values ($1, 'other@example.com')", [other]);
    expect(await loadPendingDecisions(adminOf(db), other, NOW)).toEqual([]);
    expect((await load()).length).toBeGreaterThan(0);
    expect(queryOf(db)).toBeTruthy();
  });
});
