import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { coordinateEvent, runCoordinator } from "@/lib/coordinator/coordinate";
import { COORDINATOR_MAX_ATTEMPTS, MAX_EVENTS_PER_RUN } from "@/lib/coordinator/coordinator.config";
import { supabaseCoordinatorReads, type CoordinatorReads } from "@/lib/coordinator/reads";
import { supabaseCoordinatorStore, type CoordinatorStore } from "@/lib/coordinator/store";

import { adminOf, advanceClock, createCoordinatorDb, seed, setClock, T0 } from "./support";

// 사건 처리 파이프라인 (PGlite + 운영 store · reads 코드 그대로): 생산자 트리거가 쌓은 사건을 집어 DB 사실로 다시 확인하고 결과를 기록한다.
// [현재 실제] = 지금 코드의 실제 성공 경로가 만든 사건 / [미래 fixture] = 원천이 없어 직접 만든 사건.
// 이 파일의 어디서도 모델 포트를 주지 않거나(운영 배선과 같다), 주더라도 가짜다: 실제 provider · Jev를 부르지 않는다.

let db: PGlite;
let s: ReturnType<typeof seed>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  s = seed(db);
}, 60_000);
afterAll(() => db.close());

beforeEach(async () => {
  await setClock(db, T0);
  // 집기는 모든 사용자를 훑는다: 앞 시나리오의 사건을 비운다
  await db.query("delete from public.inbox_events");
});

const store = () => supabaseCoordinatorStore(adminOf(db));
const reads = () => supabaseCoordinatorReads(adminOf(db));
const deps = () => ({ store: store(), reads: reads() });
const claimAll = async (consumer = "fn-1", limit = 50) => store().claim(consumer, limit);

/** 사건 하나를 집어 처리한다 (그 사용자의 머리 사건) */
async function processOne(userId?: string) {
  const [event] = (await claimAll()).filter((e) => !userId || e.user_id === userId);
  expect(event).toBeTruthy();
  const result = await coordinateEvent(deps(), event);
  return { event, result };
}

describe("[현재 실제] 원문 처리 완료 → 영향 후보 기록", () => {
  it("그 원문에 근거한 Action만 후보로 기록된다 (다른 원문의 Action · 남의 Action 제외). 모델 호출 0, Action · Claim 값은 그대로", async () => {
    const user = await s.user();
    const other = await s.user();
    const mine = await s.action(user, { title: "내 일" });
    const unrelated = await s.action(user, { title: "다른 원문의 일" });
    const theirs = await s.action(other, { title: "남의 일" });
    const source = await s.source(user);
    const elsewhere = await s.source(user);
    await s.evidence(user, mine, source);
    await s.evidence(user, unrelated, elsewhere);
    const before = await s.one(`select count(*)::int as c, max(version)::int as v, string_agg(title || due_at::text, ',' order by id) as t from public.actions`);
    await s.finishSource(source);

    const { result } = await processOne(user);
    expect(result.status).toBe("finished");
    expect(result.outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [mine] } });
    expect(JSON.stringify(result.outcome)).not.toContain(theirs);
    expect(JSON.stringify(result.outcome)).not.toContain(unrelated);
    // 코디네이터는 Action 값 · Claim을 만들지 않는다
    expect(await s.one(`select count(*)::int as c, max(version)::int as v, string_agg(title || due_at::text, ',' order by id) as t from public.actions`)).toEqual(before);
    expect(await s.count(`select 1 from public.claims`)).toBe(0);
  });

  it("살아 있는 run은 불확실한 후보로 기록만 한다: 새 run · 새 단계 · 상태 변화 0 (자동 재dispatch 없음)", async () => {
    const user = await s.user();
    const action = await s.action(user);
    const source = await s.source(user);
    await s.evidence(user, action, source);
    const run = await s.run(user, action);
    const snapshot = () => s.one(`select (select count(*)::int from public.execution_runs) as runs, (select count(*)::int from public.execution_steps) as steps, (select string_agg(state, ',' order by id) from public.execution_runs) as run_states, (select string_agg(state || version, ',' order by id) from public.execution_steps) as step_states`);
    const before = await snapshot();
    await s.finishSource(source);
    const { result } = await processOne(user);
    expect(result.outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [action], run_ids: [run] } });
    expect(await snapshot()).toEqual(before);
  });

  it("후보가 없으면 영향 없음 (모델 호출 대상도 없다)", async () => {
    const user = await s.user();
    const source = await s.source(user);
    await s.finishSource(source);
    const { result } = await processOne(user);
    expect(result.outcome).toEqual({ kind: "no_impact", evidence: "deterministic_only", ids: {} });
  });

  it("[증거 있는 stale] 사건이 쌓인 뒤 원문이 지워졌으면 stale(source_deleted), 접근을 잃었으면 stale(source_access_lost). 처리 결과는 기록되고 processed다", async () => {
    const user = await s.user();
    const gone = await s.source(user);
    const lost = await s.source(user);
    await s.finishSource(gone);
    await s.finishSource(lost);
    await db.query("delete from public.sources where id = $1", [gone]);
    await db.query("update public.sources set access_lost_at = now() where id = $1", [lost]);
    const first = await processOne(user);
    expect(first.result.outcome).toMatchObject({ kind: "stale", evidence: "source_deleted", ids: {} });
    const second = await processOne(user);
    expect(second.result.outcome).toMatchObject({ kind: "stale", evidence: "source_access_lost" });
    expect(await s.result(first.event.event_id)).toMatchObject({ processed: true, result_kind: "stale", result_evidence: "source_deleted" });
  });

  it("같은 문서의 새 revision(source_revised): 문서 전체의 근거 Action이 후보다 (이전 revision에서 나온 Action 포함)", async () => {
    const user = await s.user();
    const connection = await s.connection(user);
    const action = await s.action(user);
    const v1 = await s.source(user, { kind: "doc", externalId: "page-1", version: "v1", connection });
    await s.evidence(user, action, v1);
    await s.finishSource(v1);
    const v2 = await s.source(user, { kind: "doc", externalId: "page-1", version: "v2", connection });
    await s.finishSource(v2);
    const first = await processOne(user);
    expect(first.event.type).toBe("source_processed");
    const second = await processOne(user);
    expect(second.event.type).toBe("source_revised");
    expect(second.result.outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [action] } });
  });
});

describe("[현재 실제] 대화 메시지 · 사용자 결정 · 범위 version · 기한 창", () => {
  it("사용자 메시지: 고른 대상 중 내 것으로 확인된 것만 후보, 남의 id는 dropped_refs로 세고 결과에 나오지 않는다. 메시지 글은 읽지 않는다", async () => {
    const user = await s.user();
    const other = await s.user();
    const mine = await s.action(user);
    const theirs = await s.action(other);
    const run = await s.run(user, mine);
    const conversation = await s.conversation(user);
    await s.message(user, conversation, { action_ids: [mine, theirs], run_ids: [run] });
    // 읽은 열 목록을 모은다: 글(text · raw_text · quote · title)을 고르지 않는다
    const selected: string[] = [];
    const admin = adminOf(db);
    const spy = { ...admin, from: (table: string) => {
      const builder = admin.from(table);
      const original = builder.select.bind(builder);
      builder.select = ((columns?: string, options?: never) => (selected.push(`${table}:${columns ?? "*"}`), original(columns, options))) as never;
      return builder;
    } } as unknown as typeof admin;
    const result = await coordinateEvent({ store: store(), reads: supabaseCoordinatorReads(spy) }, (await claimAll())[0]);
    expect(result.outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [mine], run_ids: [run], dropped_refs: 1 } });
    expect(JSON.stringify(result.outcome)).not.toContain(theirs);
    expect(selected.length).toBeGreaterThan(0);
    for (const columns of selected) expect(columns, columns).not.toMatch(/\b(text|raw_text|quote|title|value_text|statement|body)\b|\*/);
  });

  it("사용자 Action 결정(decision_made): 그 Action이 후보. 결정은 이미 일어난 사실이라 Action 값을 바꾸지 않는다", async () => {
    const user = await s.user();
    const action = await s.action(user);
    await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_confirmed', 'user')`, [user, action]);
    const { result } = await processOne(user);
    expect(result.outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [action] } });
  });

  it("실행 승인 · 멈춤 결정: run과 그 Action이 후보", async () => {
    const user = await s.user();
    const action = await s.action(user);
    const run = await s.run(user, action);
    const step = (await s.one(`select id from public.execution_steps where run_id = $1`, [run])).id as string;
    await db.query(`insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', public.db_now() + interval '1 hour')`, [user, step]);
    const approval = await processOne(user);
    expect(approval.result.outcome).toMatchObject({ kind: "impact_recorded", ids: { action_ids: [action], run_ids: [run] } });
    await db.query(`select public.stop_run($1, $2)`, [user, run]);
    const stop = await processOne(user);
    expect(stop.result.outcome).toMatchObject({ kind: "impact_recorded", ids: { action_ids: [action], run_ids: [run] } });
  });

  it("범위 version: 같은 범위에서 시작한 살아 있는 run이 묶음 version보다 새 범위 version이면 후보로 기록만 (manifest를 몰라 단정하지 않는다). 더 새 version 사건이 따로 있는 옛 사건은 stale(version_mismatch)", async () => {
    const user = await s.user();
    const action = await s.action(user);
    const context = await s.context(user);
    const run = await s.run(user, action, { contextId: context, bundleContextVersion: 1 });
    await db.query(`select public.bump_context_versions(array[$1::uuid])`, [context]); // v2
    await db.query(`select public.bump_context_versions(array[$1::uuid])`, [context]); // v3
    const before = await s.one(`select state, directive_version, bundle_context_version from public.execution_runs where id = $1`, [run]);
    const old = await processOne(user);
    expect(old.event.refs).toMatchObject({ context_version: 2 });
    expect(old.result.outcome).toMatchObject({ kind: "stale", evidence: "version_mismatch" });
    const latest = await processOne(user);
    expect(latest.result.outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { run_ids: [run] } });
    // context_version과 directive_version은 섞이지 않는다: run의 지시 버전 · 묶음 버전은 그대로, 어떤 것도 재dispatch되지 않는다
    expect(await s.one(`select state, directive_version, bundle_context_version from public.execution_runs where id = $1`, [run])).toEqual(before);
    expect(await s.count(`select 1 from public.execution_steps`)).toBeGreaterThanOrEqual(1);
  });

  it("기한 창 timer: 기한이 그대로면 후보, Action이 닫혔으면 stale(already_handled), 기한이 바뀌었으면 stale(version_mismatch), 지워졌으면 stale(parent_deleted)", async () => {
    const user = await s.user();
    const due = new Date(T0.getTime() + 6 * 3_600_000).toISOString();
    const ok = await s.action(user, { dueAt: due });
    const closed = await s.action(user, { dueAt: due });
    const moved = await s.action(user, { dueAt: due });
    const deleted = await s.action(user, { dueAt: due });
    expect(await store().enqueueDueTimers(24 * 3600, 100)).toBe(4);
    await db.query(`update public.actions set status = 'done' where id = $1`, [closed]);
    await db.query(`update public.actions set due_at = due_at + interval '1 hour' where id = $1`, [moved]);
    await db.query(`delete from public.actions where id = $1`, [deleted]);
    const results = new Map<string, unknown>();
    for (let i = 0; i < 4; i++) {
      const [event] = await claimAll();
      const { outcome } = await coordinateEvent(deps(), event);
      results.set(String((event.refs as { action_id: string }).action_id), outcome);
    }
    expect(results.get(ok)).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [ok] } });
    expect(results.get(closed)).toMatchObject({ kind: "stale", evidence: "already_handled" });
    expect(results.get(moved)).toMatchObject({ kind: "stale", evidence: "version_mismatch" });
    expect(results.get(deleted)).toMatchObject({ kind: "stale", evidence: "parent_deleted" });
  });
});

describe("권한 경계: refs는 권한 증거가 아니다 (service role에서 user_id + 실제 소유를 다시 확인)", () => {
  it("남의 원문 · 메시지 · 행동 · 범위 · 승인을 가리키는 위조 사건은 후보를 만들지 못한다: 모두 '없음'으로 닫히고 남의 id가 결과에 나오지 않는다", async () => {
    const alice = await s.user();
    const bob = await s.user();
    const bobAction = await s.action(bob);
    const bobSource = await s.source(bob);
    await s.evidence(bob, bobAction, bobSource);
    await s.finishSource(bobSource);
    const bobContext = await s.context(bob);
    const bobRun = await s.run(bob, bobAction);
    const bobStep = (await s.one(`select id from public.execution_steps where run_id = $1`, [bobRun])).id as string;
    const bobMessage = await s.message(bob, await s.conversation(bob));
    await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_confirmed', 'user')`, [bob, bobAction]);
    const bobActionEvent = (await s.one(`select id from public.action_events where user_id = $1`, [bob])).id as string;
    await db.query("delete from public.inbox_events where user_id = $1", [bob]);
    // Alice의 사건으로 위조해 쌓는다
    const forged: [string, Record<string, unknown>][] = [
      ["source_processed", { source_id: bobSource }],
      ["source_revised", { source_id: bobSource }],
      ["user_message", { message_id: bobMessage }],
      ["decision_made", { action_event_id: bobActionEvent, action_id: bobAction, kind: "user_confirmed" }],
      ["decision_made", { step_id: bobStep, run_id: bobRun, kind: "approval" }],
      ["decision_made", { run_id: bobRun, action_id: bobAction, kind: "stop" }],
      ["memory_changed", { context_id: bobContext, context_version: 1 }],
      ["timer_due", { action_id: bobAction, kind: "due_window" }],
    ];
    for (const [i, [type, refs]] of forged.entries()) await s.event(alice, type, `forged-${i}`, refs);
    const outcomes: unknown[] = [];
    for (let i = 0; i < forged.length; i++) outcomes.push((await processOne(alice)).result.outcome);
    for (const outcome of outcomes) {
      expect(outcome).toMatchObject({ kind: expect.stringMatching(/^(stale|rejected)$/), ids: {} });
      const text = JSON.stringify(outcome);
      for (const secret of [bobAction, bobSource, bobContext, bobRun, bobStep, bobMessage]) expect(text).not.toContain(secret);
    }
    // Bob 쪽에는 아무것도 쓰지 않았다
    expect(await s.count(`select 1 from public.inbox_events where user_id = $1 and processed_at is not null`, [bob])).toBe(0);
  });

  it("알 수 없는 종류 · 모양이 틀린 refs(직접 쓴 행)는 거절로 닫히고, 생산자 없는 종류는 not_handled — 어느 쪽도 후보 0, 모델 0", async () => {
    const user = await s.user();
    await s.event(user, "timer", "unknown-type", {}); // A2가 허용하던 이름 모양만 맞는 종류
    await s.event(user, "user_message", "empty-refs", {});
    for (const type of ["reply_observed", "agent_event", "dependency_changed", "connection_changed", "bridge_unreachable"]) await s.event(user, type, `future-${type}`, {});
    const outcomes: { kind: string; evidence: string | null }[] = [];
    for (let i = 0; i < 7; i++) {
      const { result } = await processOne(user);
      outcomes.push({ kind: result.outcome!.kind, evidence: result.outcome!.evidence });
    }
    expect(outcomes[0]).toEqual({ kind: "rejected", evidence: "unknown_type" });
    expect(outcomes[1]).toEqual({ kind: "stale", evidence: "parent_deleted" });
    expect(outcomes.slice(2)).toEqual(Array(5).fill({ kind: "not_handled", evidence: "type_not_connected" }));
  });
});

describe("재시도 · crash · 응답 유실 · 늦은 소비자 · 삭제", () => {
  async function oneEvent() {
    const user = await s.user();
    const source = await s.source(user);
    await s.finishSource(source);
    return { user, eventId: (await s.one(`select id from public.inbox_events where user_id = $1`, [user])).id as string };
  }

  it("처리 중 예외(crash): processed_at을 쓰지 않고 실패 기록 + 재시도 지연. 지연 뒤 다시 집혀 한 번만 처리된다 (attempts 2)", async () => {
    const { user, eventId } = await oneEvent();
    const flaky: CoordinatorReads = { loadFacts: vi.fn().mockRejectedValueOnce(new Error("DB 연결 끊김")).mockImplementation((e) => reads().loadFacts(e)) };
    vi.spyOn(console, "error").mockImplementation(() => {});
    const [event] = await claimAll();
    expect(await coordinateEvent({ store: store(), reads: flaky }, event)).toEqual({ status: "failed" });
    expect(await s.result(eventId)).toMatchObject({ processed: false, result_kind: null, attempts: 1 });
    expect(await s.one(`select last_error_kind from public.inbox_events where id = $1`, [eventId])).toEqual({ last_error_kind: "decide_error" });
    // 지연 동안은 다시 집히지 않는다
    expect(await claimAll()).toEqual([]);
    await advanceClock(db, 61_000);
    const [again] = await claimAll();
    expect(again.attempts).toBe(2);
    expect((await coordinateEvent({ store: store(), reads: flaky }, again)).status).toBe("finished");
    expect(await s.result(eventId)).toMatchObject({ processed: true, attempts: 2 });
    expect(await claimAll()).toEqual([]);
    expect(user).toBeTruthy();
    vi.restoreAllMocks();
  });

  it("응답 유실 (commit된 처리의 응답이 사라짐): 다시 처리하지 않고 사건은 processed 하나. 재시도 finish는 already_finished", async () => {
    const { eventId } = await oneEvent();
    const real = store();
    let lost = true;
    const lossy: CoordinatorStore = { ...real, finish: async (event, outcome) => { const status = await real.finish(event, outcome); if (lost) { lost = false; throw new Error("응답 유실"); } return status; } };
    vi.spyOn(console, "error").mockImplementation(() => {});
    const [event] = await claimAll();
    expect((await coordinateEvent({ store: lossy, reads: reads() }, event)).status).toBe("failed");
    // DB에는 처리가 있다 (실패 기록은 이미 끝난 사건에는 아무것도 하지 않는다)
    expect(await s.result(eventId)).toMatchObject({ processed: true, result_kind: "no_impact" });
    expect(await claimAll()).toEqual([]);
    expect(await real.finish(event, { kind: "no_impact", evidence: null, ids: {} })).toBe("already_finished");
    vi.restoreAllMocks();
  });

  it("commit 전 응답 유실 (처리가 DB에 닿지 못함): 사건은 처리 전으로 남아 다시 처리되고 결과는 하나다", async () => {
    const { eventId } = await oneEvent();
    const real = store();
    let lost = true;
    const lossy: CoordinatorStore = { ...real, finish: async (event, outcome) => { if (lost) { lost = false; throw new Error("연결 끊김"); } return real.finish(event, outcome); } };
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await coordinateEvent({ store: lossy, reads: reads() }, (await claimAll())[0])).status).toBe("failed");
    expect(await s.result(eventId)).toMatchObject({ processed: false });
    await advanceClock(db, 61_000);
    expect((await coordinateEvent({ store: lossy, reads: reads() }, (await claimAll())[0])).status).toBe("finished");
    expect(await s.count(`select 1 from public.inbox_events where id = $1 and processed_at is not null`, [eventId])).toBe(1);
    vi.restoreAllMocks();
  });

  it("늦은(만료된) 소비자: 새 소비자가 집어 끝낸 뒤 옛 소비자가 처리하려 하면 lost_claim (던지지 않는다). 결과는 새 소비자의 것 하나", async () => {
    const { eventId } = await oneEvent();
    const [oldEvent] = await claimAll("fn-old");
    await s.expire(eventId);
    const [freshEvent] = await claimAll("fn-new");
    expect((await coordinateEvent(deps(), freshEvent)).status).toBe("finished");
    expect((await coordinateEvent(deps(), oldEvent)).status).toBe("lost_claim");
    expect(await s.result(eventId)).toMatchObject({ processed: true, attempts: 2 });
  });

  it("계정이 삭제되면 집은 사건의 처리는 lost_claim이고 사건도 사라진다 (삭제 · 권한 상실)", async () => {
    const { user, eventId } = await oneEvent();
    const [event] = await claimAll();
    await db.query("delete from auth.users where id = $1", [user]);
    expect((await coordinateEvent(deps(), event)).status).toBe("lost_claim");
    expect(await s.count(`select 1 from public.inbox_events where id = $1`, [eventId])).toBe(0);
  });

  it("끝내 처리하지 못하는 사건(poison)은 시도를 다 쓰면 죽은 사건이 되고, 같은 사용자의 다음 사건을 막지 않는다 (처리된 것으로 세지 않는다)", async () => {
    const user = await s.user();
    const poison = await s.event(user, "timer_due", "poison", { action_id: await s.action(user) });
    const next = await s.event(user, "user_message", "next", {});
    const real = reads();
    const broken: CoordinatorReads = { loadFacts: async (event) => { if (event.dedup_key === "poison") throw new Error("고칠 수 없는 오류"); return real.loadFacts(event); } };
    vi.spyOn(console, "error").mockImplementation(() => {});
    for (let attempt = 1; attempt <= COORDINATOR_MAX_ATTEMPTS; attempt++) {
      const [event] = await claimAll();
      expect(event.event_id).toBe(poison);
      expect((await coordinateEvent({ store: store(), reads: broken }, event)).status).toBe("failed");
      await advanceClock(db, 61_000);
    }
    const [after] = await claimAll();
    expect(after.event_id).toBe(next);
    expect(await s.result(poison)).toMatchObject({ processed: false, dead: true, attempts: COORDINATOR_MAX_ATTEMPTS });
    vi.restoreAllMocks();
  });

  it("같은 사건을 한 번 더 적재해도(store.enqueue) 하나다. 생산자 트리거가 쌓은 사건과 같은 키여도 하나다", async () => {
    const user = await s.user();
    const source = await s.source(user);
    await s.finishSource(source);
    const again = await store().enqueue({ user_id: user, type: "source_processed", dedup_key: `source:${source}`, refs: { source_id: source } });
    expect(again.created).toBe(false);
    expect(await s.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(1);
  });
});

describe("batch 상한: 쌓인 사건이 한꺼번에 몰리지 않는다 (사건 수 · 시간)", () => {
  it(`한 번 돌 때 최대 ${MAX_EVENTS_PER_RUN}건만 집고, 남은 것은 그대로 두고 more로 알린다. 다음 호출이 이어 간다`, async () => {
    const users: string[] = [];
    for (let i = 0; i < 12; i++) users.push(await s.user());
    // 12명 × 10건 = 120건. 머리만 집히므로 한 번의 집기는 최대 12건이고 사건 수 상한으로 끊긴다
    for (const user of users) for (let n = 0; n < 10; n++) await s.event(user, "user_message", `k${n}`, {});
    const first = await runCoordinator(deps(), { consumer: "fn-1" });
    expect(first.claimed).toBe(MAX_EVENTS_PER_RUN);
    expect(first.finished).toBe(MAX_EVENTS_PER_RUN);
    expect(first.more).toBe(true);
    expect(await s.count(`select 1 from public.inbox_events where processed_at is null`)).toBe(120 - MAX_EVENTS_PER_RUN);
    const second = await runCoordinator(deps(), { consumer: "fn-1" });
    expect(second.claimed).toBe(MAX_EVENTS_PER_RUN);
    const third = await runCoordinator(deps(), { consumer: "fn-1" });
    expect(third.claimed).toBe(120 - 2 * MAX_EVENTS_PER_RUN);
    expect(third.more).toBe(false);
    expect(await s.count(`select 1 from public.inbox_events where processed_at is null`)).toBe(0);
  });

  it("시간 예산이 지나면 새 사건을 집지 않는다 (시작한 사건은 끝낸다)", async () => {
    const user = await s.user();
    await s.event(user, "user_message", "a", {});
    let tick = 0;
    const summary = await runCoordinator(deps(), { consumer: "fn-1", timeBudgetMs: 10, now: () => (tick += 100) });
    expect(summary.claimed).toBe(0);
    expect(summary.more).toBe(true);
    expect(await s.count(`select 1 from public.inbox_events where processed_at is null`)).toBe(1);
  });
});

describe("사용자별 순서: 같은 사용자의 사건은 쌓인 순서대로 처리된다 (같은 시각 포함, 두 소비자가 번갈아도)", () => {
  it("한 사용자의 5건을 소비자 둘이 번갈아 집어도 처리 순서는 쌓인 순서다", async () => {
    const user = await s.user();
    const ids: string[] = [];
    for (let n = 0; n < 5; n++) ids.push(await s.event(user, "user_message", `k${n}`, {})); // 모두 같은 시각(고정 시계)
    const order: string[] = [];
    for (let i = 0; i < 5; i++) {
      const [event] = await store().claim(i % 2 === 0 ? "fn-a" : "fn-b", 10);
      const result = await coordinateEvent(deps(), event);
      expect(result.status).toBe("finished");
      order.push(event.event_id);
    }
    expect(order).toEqual(ids);
  });
});
