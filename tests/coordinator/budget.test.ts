import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { AiBudgetError } from "@/lib/ai/budget-error";
import { ConsentRequiredError } from "@/lib/consent/gate";
import { coordinateEvent } from "@/lib/coordinator/coordinate";
import { MAX_JEV_CALLS_PER_EVENT } from "@/lib/coordinator/coordinator.config";
import type { Facts } from "@/lib/coordinator/impact";
import type { ImpactJudge, ManagementJudge } from "@/lib/coordinator/judgments";
import { supabaseCoordinatorReads, type CoordinatorReads } from "@/lib/coordinator/reads";
import { supabaseCoordinatorStore, type CoordinatorStore } from "@/lib/coordinator/store";
import type { Candidate } from "@/lib/coordinator/types";

import { adminOf, advanceClock, createCoordinatorDb, seed, setClock, T0 } from "./support";

// 모델 호출 상한 (아키텍처 7.1 · I09): 관리(생성) 모델은 사건당 최대 1회, 호출 전에 DB에 예산을 먼저 잡는다. 모두 가짜 모델이다 — 실제 provider · Jev를 부르지 않는다.
// 현재 실제 데이터에는 "모델이 필요한 경로"가 없다(운영 배선은 포트를 주지 않는다 — docs/coordinator.md): 이 시험은 호출 경로가 상한 · 예약 · 후보 안 출력을 지키는지를 fake로만 본다.
// [현재 실제] = 실제 생산자가 만든 사건(source_revised) / [미래 fixture] = 생산자 없는 종류(reply_observed)를 후보 fixture로.

let db: PGlite;
let s: ReturnType<typeof seed>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  s = seed(db);
}, 60_000);
afterAll(() => db.close());
beforeEach(async () => {
  await setClock(db, T0);
  await db.query("delete from public.inbox_events");
  vi.spyOn(console, "error").mockImplementation(() => {});
});

const realStore = () => supabaseCoordinatorStore(adminOf(db));
const realReads = () => supabaseCoordinatorReads(adminOf(db));

/** 같은 문서의 두 revision: 두 번째 처리가 source_revised를 만든다. 첫 revision의 근거 Action 하나 + 살아 있는 run n개 */
async function revisedDocument(runs: number) {
  const user = await s.user();
  const connection = await s.connection(user);
  const action = await s.action(user);
  const v1 = await s.source(user, { kind: "doc", externalId: `page-${Math.random()}`, version: "v1", connection });
  await s.evidence(user, action, v1);
  await s.finishSource(v1);
  const runIds: string[] = [];
  for (let i = 0; i < runs; i++) runIds.push(await s.run(user, action));
  const v2 = await s.source(user, { kind: "doc", externalId: (await s.one(`select external_id from public.sources where id = $1`, [v1])).external_id as string, version: "v2", connection });
  await s.finishSource(v2);
  // 첫 revision의 source_processed 사건은 처리해 둔다
  const [first] = await realStore().claim("setup", 10);
  await realStore().finish(first, { kind: "no_impact", evidence: null, ids: {} });
  return { user, action, runIds: runIds.sort() };
}

const claimOne = async () => (await realStore().claim("fn-1", 10))[0];

describe("[현재 실제] source_revised: Jev 영향 판정 (J4) — 후보마다 한 번, 상한까지", () => {
  it("불확실한 후보(살아 있는 run)가 있고 포트가 있으면 후보 수만큼 Jev를 예약하고 부른다. 영향 없다고 본 후보는 결과에서 빠진다. 확실한 후보(Action)는 판정 없이 남는다", async () => {
    const { action, runIds } = await revisedDocument(2);
    const jev = vi.fn<ImpactJudge>(async ({ candidates }) => ({ affected: candidates.filter((c) => c.id === runIds[0]).map((c) => `${c.kind}:${c.id}`) }));
    const event = await claimOne();
    expect(event.type).toBe("source_revised");
    const { outcome, status } = await coordinateEvent({ store: realStore(), reads: realReads(), ports: { jev } }, event);
    expect(status).toBe("finished");
    expect(jev).toHaveBeenCalledTimes(1);
    expect(jev.mock.calls[0][0].candidates.map((c) => c.kind)).toEqual(["run", "run"]); // 확실한 Action은 보내지 않는다
    expect(outcome).toEqual({ kind: "impact_recorded", evidence: "jev_judged", ids: { action_ids: [action], run_ids: [runIds[0]] } });
    expect(await s.result(event.event_id)).toMatchObject({ processed: true, jev_calls: 2, model_calls: 0 });
  });

  it("후보가 모두 확실하면(살아 있는 run 없음) Jev 0회 — 포트가 있어도 예약조차 하지 않는다", async () => {
    const { action } = await revisedDocument(0);
    const jev = vi.fn<ImpactJudge>();
    const management = vi.fn<ManagementJudge>();
    const event = await claimOne();
    const { outcome } = await coordinateEvent({ store: realStore(), reads: realReads(), ports: { jev, management } }, event);
    expect(outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [action] } });
    expect(jev).not.toHaveBeenCalled();
    expect(management).not.toHaveBeenCalled();
    expect(await s.result(event.event_id)).toMatchObject({ jev_calls: 0, model_calls: 0 });
  });

  it("후보가 아예 없으면(근거 Action 없음) 영향 없음 · 호출 0", async () => {
    const user = await s.user();
    const connection = await s.connection(user);
    const v1 = await s.source(user, { kind: "doc", externalId: "lonely", version: "v1", connection });
    await s.finishSource(v1);
    const v2 = await s.source(user, { kind: "doc", externalId: "lonely", version: "v2", connection });
    await s.finishSource(v2);
    const jev = vi.fn<ImpactJudge>();
    const management = vi.fn<ManagementJudge>();
    for (let i = 0; i < 2; i++) await coordinateEvent({ store: realStore(), reads: realReads(), ports: { jev, management } }, await claimOne());
    expect(jev).not.toHaveBeenCalled();
    expect(management).not.toHaveBeenCalled();
  });

  it(`Jev 호출은 후보 수와 상한(${MAX_JEV_CALLS_PER_EVENT}) 중 작은 쪽까지다: 상한 밖 후보는 판정하지 못했으므로 배제하지 않고 그대로 기록한다`, async () => {
    const { runIds } = await revisedDocument(MAX_JEV_CALLS_PER_EVENT + 4);
    const jev = vi.fn<ImpactJudge>(async () => ({ affected: [] }));
    const event = await claimOne();
    const { outcome } = await coordinateEvent({ store: realStore(), reads: realReads(), ports: { jev } }, event);
    expect(jev.mock.calls[0][0].candidates).toHaveLength(MAX_JEV_CALLS_PER_EVENT);
    expect(await s.result(event.event_id)).toMatchObject({ jev_calls: MAX_JEV_CALLS_PER_EVENT });
    // 판정된 8개는 모두 "영향 없음"으로 빠지고, 판정하지 못한 4개만 남는다
    expect(outcome!.ids.run_ids).toHaveLength(4);
    expect(runIds).toEqual(expect.arrayContaining(outcome!.ids.run_ids!));
  });

  it("Jev 예산이 이미 차 있으면(앞선 시도가 썼다) 부르지 않고 not_judged(jev_budget_exhausted)로 닫는다 — 후보는 그대로 기록", async () => {
    const { action, runIds } = await revisedDocument(1);
    const jev = vi.fn<ImpactJudge>();
    const event = await claimOne();
    expect(await realStore().reserveJevCalls(event, MAX_JEV_CALLS_PER_EVENT, MAX_JEV_CALLS_PER_EVENT)).toBe(true);
    const { outcome } = await coordinateEvent({ store: realStore(), reads: realReads(), ports: { jev } }, event);
    expect(jev).not.toHaveBeenCalled();
    expect(outcome).toEqual({ kind: "not_judged", evidence: "jev_budget_exhausted", ids: { action_ids: [action], run_ids: runIds } });
  });

  it("모델이 후보 밖 객체를 고르면 출력 전체를 버린다 (model_output_rejected). 남의 Action · 없는 id는 결과에 들어가지 않는다", async () => {
    const other = await s.user();
    const bobAction = await s.action(other);
    const { runIds } = await revisedDocument(1);
    const jev = vi.fn<ImpactJudge>(async ({ candidates }) => ({ affected: [`run:${candidates[0].id}`, `action:${bobAction}`] }));
    const { outcome } = await coordinateEvent({ store: realStore(), reads: realReads(), ports: { jev } }, await claimOne());
    expect(outcome!.kind).toBe("not_judged");
    expect(outcome!.evidence).toBe("model_output_rejected");
    expect(JSON.stringify(outcome)).not.toContain(bobAction);
    expect(outcome!.ids.run_ids).toEqual(runIds); // 보수적으로 후보를 그대로 기록
  });
});

/** [미래 fixture] 생산자 없는 종류의 사건: 읽기를 가로채 후보를 직접 준다 */
function fixtureReads(candidates: Candidate[]): CoordinatorReads {
  const real = realReads();
  return { loadFacts: async (e) => (e.type === "reply_observed" ? ({ kind: "generic", candidates } satisfies Facts) : real.loadFacts(e)) };
}
const uncertain = (n: number): Candidate => ({ kind: "run", id: `cccccccc-0000-4000-8000-${String(n).padStart(12, "0")}`, relation: "fixture", certainty: "uncertain" });
const key = (c: Candidate) => `${c.kind}:${c.id}`;

async function replyEvent() {
  const user = await s.user();
  const event = await s.event(user, "reply_observed", `reply-${Math.random()}`, { kind: "requirement_change" });
  return { user, event };
}

describe("[미래 fixture] 관리(생성) 모델: 사건당 최대 1회, 호출 전에 예약", () => {
  it("불확실한 후보가 있고 포트가 있으면 정확히 한 번 부른다. 예약이 먼저 commit되고(model_calls 1) 결과는 후보 안에서만 받는다", async () => {
    await replyEvent();
    const candidates = [uncertain(1), uncertain(2), uncertain(3)];
    const seen: number[] = [];
    const management = vi.fn<ManagementJudge>(async ({ candidates: sent }) => {
      // 부르는 순간 DB에는 이미 예약이 있다
      seen.push(Number((await s.one(`select model_calls from public.inbox_events where processed_at is null`)).model_calls));
      return { affected: [key(sent[0]), key(sent[2])], reason_code: "requirement_changed" };
    });
    const event = await claimOne();
    const { outcome } = await coordinateEvent({ store: realStore(), reads: fixtureReads(candidates), ports: { management } }, event);
    expect(management).toHaveBeenCalledTimes(1);
    expect(seen).toEqual([1]);
    expect(outcome).toEqual({ kind: "impact_recorded", evidence: "management_judged", ids: { run_ids: [candidates[0].id, candidates[2].id] } });
    expect(await s.result(event.event_id)).toMatchObject({ model_calls: 1, jev_calls: 0 });
  });

  it("호출 뒤 처리 기록 전에 프로세스가 죽었다 → 다시 집힌 시도는 모델을 다시 부르지 않는다: not_judged(model_call_unknown). 총 호출 1회", async () => {
    const { event: eventId } = await replyEvent();
    const management = vi.fn<ManagementJudge>(async ({ candidates }) => ({ affected: [key(candidates[0])], reason_code: "ok" }));
    const real = realStore();
    let die = true;
    const dying: CoordinatorStore = { ...real, finish: async (e, o) => { if (die) { die = false; throw new Error("프로세스 종료"); } return real.finish(e, o); } };
    const reads = fixtureReads([uncertain(1)]);
    expect((await coordinateEvent({ store: dying, reads, ports: { management } }, await claimOne())).status).toBe("failed");
    expect(await s.result(eventId)).toMatchObject({ processed: false, model_calls: 1 });
    await advanceClock(db, 61_000);
    const retry = await claimOne();
    expect(retry.model_calls).toBe(1);
    const { outcome } = await coordinateEvent({ store: dying, reads, ports: { management } }, retry);
    expect(outcome).toEqual({ kind: "not_judged", evidence: "model_call_unknown", ids: { run_ids: [uncertain(1).id] } });
    expect(management).toHaveBeenCalledTimes(1);
  });

  it("예약 응답을 잃어(DB엔 예약됨) 소비자가 모른 채 죽어도 부르지 않았고, 다시 집힌 시도도 부르지 않는다 (호출 0)", async () => {
    const { event: eventId } = await replyEvent();
    const management = vi.fn<ManagementJudge>();
    const real = realStore();
    let lose = true;
    const lossy: CoordinatorStore = { ...real, reserveModelCall: async (e) => { const ok = await real.reserveModelCall(e); if (lose) { lose = false; throw new Error("응답 유실"); } return ok; } };
    const reads = fixtureReads([uncertain(1)]);
    expect((await coordinateEvent({ store: lossy, reads, ports: { management } }, await claimOne())).status).toBe("failed");
    await advanceClock(db, 61_000);
    const { outcome } = await coordinateEvent({ store: lossy, reads, ports: { management } }, await claimOne());
    expect(outcome).toMatchObject({ kind: "not_judged", evidence: "model_call_unknown" });
    expect(management).not.toHaveBeenCalled();
    expect(await s.result(eventId)).toMatchObject({ processed: true, model_calls: 1 });
  });

  it("lease를 잃은 소비자는 예약하지 못해 모델을 부르지 못한다 (늦은 소비자)", async () => {
    const { event: eventId } = await replyEvent();
    const management = vi.fn<ManagementJudge>();
    const [stale] = await realStore().claim("fn-old", 10);
    await s.expire(eventId);
    const result = await coordinateEvent({ store: realStore(), reads: fixtureReads([uncertain(1)]), ports: { management } }, stale);
    expect(management).not.toHaveBeenCalled();
    expect(result.status).toBe("lost_claim");
  });

  it("후보가 없거나 모두 확실하면 호출 0 (사건은 있어도)", async () => {
    await replyEvent();
    const management = vi.fn<ManagementJudge>();
    const certain: Candidate = { ...uncertain(1), certainty: "certain" };
    const first = await coordinateEvent({ store: realStore(), reads: fixtureReads([]), ports: { management } }, await claimOne());
    expect(first.outcome).toMatchObject({ kind: "no_impact" });
    await replyEvent();
    const second = await coordinateEvent({ store: realStore(), reads: fixtureReads([certain]), ports: { management } }, await claimOne());
    expect(second.outcome).toMatchObject({ kind: "impact_recorded", evidence: "deterministic_only" });
    expect(management).not.toHaveBeenCalled();
  });

  it("일일 AI 원가 한도 · 동의 철회 · 모델 오류는 not_judged로 닫고 다시 부르지 않는다. 모델 출력이 후보 밖이면 버린다", async () => {
    const cases: [string, ManagementJudge, string][] = [
      ["ai_budget", async () => { throw new AiBudgetError("ai_user_daily_budget_exhausted"); }, "ai_budget"],
      ["consent_missing", async () => { throw new ConsentRequiredError(); }, "consent_missing"],
      ["model_error", async () => { throw new Error("provider 500"); }, "model_error"],
      ["foreign output", async () => ({ affected: ["run:cccccccc-0000-4000-8000-0000000000ff"], reason_code: "ok" }), "model_output_rejected"],
      ["bad reason", async ({ candidates }) => ({ affected: [key(candidates[0])], reason_code: "한글 까닭 문장" }), "model_output_rejected"],
    ];
    for (const [label, impl, evidence] of cases) {
      const { event: eventId } = await replyEvent();
      const management = vi.fn<ManagementJudge>(impl);
      const { outcome } = await coordinateEvent({ store: realStore(), reads: fixtureReads([uncertain(1)]), ports: { management } }, await claimOne());
      expect(outcome, label).toEqual({ kind: "not_judged", evidence, ids: { run_ids: [uncertain(1).id] } });
      expect(management, label).toHaveBeenCalledTimes(1);
      expect(await s.result(eventId), label).toMatchObject({ processed: true, model_calls: 1 });
    }
  });

  it("Jev와 관리 모델이 모두 필요한 종류(회신)도 관리 모델은 한 번: Jev가 배제한 후보는 관리 모델에 보내지 않는다", async () => {
    const { event: eventId } = await replyEvent();
    const candidates = [uncertain(1), uncertain(2), uncertain(3)];
    const jev = vi.fn<ImpactJudge>(async () => ({ affected: [key(candidates[0]), key(candidates[1])] }));
    const management = vi.fn<ManagementJudge>(async ({ candidates: sent }) => ({ affected: [key(sent[1])], reason_code: "scope_changed" }));
    const { outcome } = await coordinateEvent({ store: realStore(), reads: fixtureReads(candidates), ports: { jev, management } }, await claimOne());
    expect(jev).toHaveBeenCalledTimes(1);
    expect(management).toHaveBeenCalledTimes(1);
    expect(management.mock.calls[0][0].candidates.map((c) => c.id)).toEqual([candidates[0].id, candidates[1].id]);
    expect(outcome).toEqual({ kind: "impact_recorded", evidence: "management_judged", ids: { run_ids: [candidates[1].id] } });
    expect(await s.result(eventId)).toMatchObject({ model_calls: 1, jev_calls: 3 });
  });
});

describe("포트가 없으면(운영 배선) 모델 호출 경로 자체가 없다", () => {
  it("source_revised에 불확실한 후보가 있어도 포트 없이 결정적으로 기록하고 끝난다 (model_calls · jev_calls 0)", async () => {
    const { action, runIds } = await revisedDocument(2);
    const event = await claimOne();
    const { outcome } = await coordinateEvent({ store: realStore(), reads: realReads() }, event);
    expect(outcome).toEqual({ kind: "impact_recorded", evidence: "deterministic_only", ids: { action_ids: [action], run_ids: runIds } });
    expect(await s.result(event.event_id)).toMatchObject({ model_calls: 0, jev_calls: 0 });
  });
});
