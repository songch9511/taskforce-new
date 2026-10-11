import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { URGENT_WINDOW_HOURS } from "@/lib/coordinator/coordinator.config";
import type { ImpactJudge, ManagementJudge } from "@/lib/coordinator/judgments";
import { supabaseCoordinatorReads } from "@/lib/coordinator/reads";
import { supabaseCoordinatorStore } from "@/lib/coordinator/store";
import { coordinatorPass } from "@/lib/coordinator/sweep";

import { adminOf, createCoordinatorDb, seed, setClock, T0 } from "./support";

// ARCH11: 변화 없는 24시간 → 코디네이터 모델 호출 0, 전송 0, 제안 0 (시계 고정). sync · 검색 · LLM 호출량은 따로 센다(여기서는 모두 0이어야 한다).
// 시계는 DB 시각(db_now = app.now)과 sweep의 now를 함께 한 시간씩 움직인다. 시스템 시계 · 시간대는 바꾸지 않는다.

let db: PGlite;
let s: ReturnType<typeof seed>;
beforeAll(async () => {
  db = await createCoordinatorDb();
  s = seed(db);
}, 60_000);
afterAll(() => db.close());

const WRITE_TABLES = ["execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_artifacts", "execution_usage", "claims", "evidence", "action_events", "judge_logs", "metric_events", "memory_items", "people", "work_contexts", "conversation_messages", "source_chunks", "credit_ledger"];
const counts = async () => Object.fromEntries(await Promise.all(WRITE_TABLES.map(async (t) => [t, await s.count(`select 1 from public.${t}`)])));

describe("ARCH11: 변화 없는 24시간 (시계 고정)", () => {
  it("사건이 없으면 매 시간 돌아도 모델 호출 0 · 전송 0 · 쓰기 0 · 집은 사건 0", async () => {
    const user = await s.user();
    await s.action(user, { dueAt: new Date(T0.getTime() + 3 * 86_400_000).toISOString() }); // 창 밖
    await s.action(user, { dueAt: null });
    const jev = vi.fn<ImpactJudge>();
    const management = vi.fn<ManagementJudge>();
    const sendOrSearch = vi.spyOn(globalThis, "fetch");
    const before = await counts();
    const admin = adminOf(db);
    let claimed = 0;
    for (let hour = 0; hour <= URGENT_WINDOW_HOURS; hour++) {
      const clock = new Date(T0.getTime() + hour * 3_600_000);
      await setClock(db, clock);
      const pass = await coordinatorPass({ store: supabaseCoordinatorStore(admin), reads: supabaseCoordinatorReads(admin), ports: { jev, management }, consumer: "fn-1", now: () => clock });
      expect(pass.errors).toBe(0);
      expect(pass.timers).toBe(0);
      claimed += pass.run!.claimed;
    }
    expect(claimed).toBe(0);
    expect(jev).not.toHaveBeenCalled();
    expect(management).not.toHaveBeenCalled();
    expect(sendOrSearch).not.toHaveBeenCalled();
    expect(await counts()).toEqual(before);
    expect(await s.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(0);
    sendOrSearch.mockRestore();
  });

  it("기한이 창 안으로 들어온 Action 하나만 timer 사건 1건(결정적 처리): 그래도 모델 0 · 전송 0 · 제안 0 · run/단계/Claim/Action 변화 0. 매 시간 돌아도 사건은 늘지 않는다", async () => {
    await setClock(db, T0);
    await db.query("delete from public.inbox_events");
    const user = await s.user();
    const soon = await s.action(user, { dueAt: new Date(T0.getTime() + 12 * 3_600_000).toISOString() }); // 12시간 뒤
    const later = await s.action(user, { dueAt: new Date(T0.getTime() + 5 * 86_400_000).toISOString() });
    const jev = vi.fn<ImpactJudge>();
    const management = vi.fn<ManagementJudge>();
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const actionsBefore = await s.one(`select string_agg(id::text || title || coalesce(due_at::text, '') || status || version::text || updated_at::text, ',' order by id) as a from public.actions`);
    const before = await counts();
    const admin = adminOf(db);
    const results: string[] = [];
    for (let hour = 0; hour <= URGENT_WINDOW_HOURS; hour++) {
      const clock = new Date(T0.getTime() + hour * 3_600_000);
      await setClock(db, clock);
      const pass = await coordinatorPass({ store: supabaseCoordinatorStore(admin), reads: supabaseCoordinatorReads(admin), ports: { jev, management }, consumer: "fn-1", now: () => clock });
      expect(pass.errors).toBe(0);
      if (pass.run!.finished) results.push(...Object.entries(pass.run!.results).filter(([, n]) => n > 0).map(([kind]) => kind));
    }
    expect(results).toEqual(["impact_recorded"]);
    const events = await s.q(`select type, refs, result_kind, result_evidence, result_ids, model_calls, jev_calls from public.inbox_events where user_id = $1`, [user]);
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ type: "timer_due", refs: { action_id: soon, kind: "due_window" }, result_kind: "impact_recorded", result_evidence: "deterministic_only", model_calls: 0, jev_calls: 0 });
    expect(events[0].refs).not.toMatchObject({ action_id: later });
    expect(jev).not.toHaveBeenCalled();
    expect(management).not.toHaveBeenCalled();
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(await counts()).toEqual(before);
    expect(await s.one(`select string_agg(id::text || title || coalesce(due_at::text, '') || status || version::text || updated_at::text, ',' order by id) as a from public.actions`)).toEqual(actionsBefore);
    fetchSpy.mockRestore();
  });

  it("제안 · 에이전트 · 의존 · pending_decisions 표는 만들지 않았다 (이 묶음 범위 밖: C3 · D1 · D6)", async () => {
    const tables = (await s.q(`select table_name from information_schema.tables where table_schema = 'public' and table_name = any ($1)`, [["suggestions", "agent_tasks", "agent_sessions", "action_dependencies", "pending_decisions", "bridges", "bridge_commands", "user_preferences"]]))
      .map((r) => r.table_name);
    expect(tables).toEqual([]);
  });
});
