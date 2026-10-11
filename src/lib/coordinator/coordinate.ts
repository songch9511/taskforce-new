import { CLAIM_BATCH, COORDINATOR_RETRY_DELAY_S, MAX_EVENTS_PER_RUN, RUN_TIME_BUDGET_MS } from "./coordinator.config";
import { computeImpact, type Impact } from "./impact";
import { runJudgments, type JudgmentPorts } from "./judgments";
import type { CoordinatorReads } from "./reads";
import { planModelWork } from "./routing";
import type { CoordinatorStore } from "./store";
import { INBOX_EVENT_TYPES, refsSchema, RESULT_KINDS, type Candidate, type ClaimedEvent, type FinishStatus, type InboxEventType, type Outcome, type ResultKind } from "./types";

// 사건 하나를 처리한다 (아키텍처 7.1): 귀속(DB에서 다시 확인) → 결정적 처리로 끝나는가 → 영향 후보(코드) → (필요할 때만, 예약한 뒤) 모델 판정 → 결과 기록.
// 쓰는 것은 inbox_events의 처리 결과(종류 + 근거 종류 + id)뿐이다: Action 값 · Claim · run · 단계 · 정책 · 승인을 만들거나 바꾸지 않는다 (I01 · I04 · I14).
// 자동 재dispatch · 새 run · 새 단계 · Action 완료는 이 모듈에 없다. 결과를 쓰는 소비자(제안 C3 · 게이트웨이 D1)는 뒤 단계다.
// 처리 쓰기는 coordinator_finish 한 번(한 문장, 멱등)이다. processed_at은 성공한 결과와 함께만 쓰이고, 예외로 끝나면 쓰이지 않는다 → 다시 집힌다.

export type CoordinatorDeps = {
  store: CoordinatorStore;
  reads: CoordinatorReads;
  /** 모델 포트 (주입). 없으면 모델을 부르지 않는다 */
  ports?: JudgmentPorts;
};

export type EventResult = { status: FinishStatus | "failed"; outcome?: Outcome };

const idsOf = (candidates: Candidate[], extra: Partial<Outcome["ids"]> = {}): Outcome["ids"] => {
  const ids: Outcome["ids"] = { ...extra };
  for (const [kind, key] of [["action", "action_ids"], ["context", "context_ids"], ["run", "run_ids"]] as const) {
    const list = candidates.filter((c) => c.kind === kind).map((c) => c.id);
    if (list.length > 0) ids[key] = list;
  }
  return ids;
};

/** 사건 하나의 처리 결과를 정한다 (DB 쓰기 없음: 읽기 + 예약뿐). 던지면 아직 처리되지 않은 것이다 */
export async function decideOutcome(deps: CoordinatorDeps, event: ClaimedEvent): Promise<Outcome> {
  if (!(INBOX_EVENT_TYPES as readonly string[]).includes(event.type)) return { kind: "rejected", evidence: "unknown_type", ids: {} };
  if (!refsSchema.safeParse(event.refs).success) return { kind: "rejected", evidence: "invalid_refs", ids: {} };

  const facts = await deps.reads.loadFacts(event);
  const impact: Impact = computeImpact(facts);
  if (impact.kind === "stale") return { kind: "stale", evidence: impact.evidence, ids: {} };
  if (impact.kind === "rejected") return { kind: "rejected", evidence: impact.evidence, ids: {} };
  if (impact.kind === "not_handled") return { kind: "not_handled", evidence: impact.evidence, ids: {} };

  const extra = { ...(impact.dropped > 0 ? { dropped_refs: impact.dropped } : {}), ...(impact.truncated > 0 ? { truncated: impact.truncated } : {}) };
  if (impact.candidates.length === 0) return { kind: "no_impact", evidence: "deterministic_only", ids: extra };

  // 모델 계획: 후보가 확실하면 판정 없이 영향이다. 불확실한 후보만, 포트가 있고 종류가 맞을 때만 모델에 간다 (호출 0이 기본)
  const ports = deps.ports ?? {};
  const uncertain = impact.candidates.filter((c) => c.certainty === "uncertain");
  const plan = planModelWork(event.type as InboxEventType, impact.candidates, { jev: Boolean(ports.jev), management: Boolean(ports.management) });
  const judged = plan.jev.length > 0 || plan.management ? await runJudgments({ store: deps.store, event, eventType: event.type, plan, uncertain, ports }) : null;

  if (judged?.kind === "not_judged") {
    // 예약을 쓴 뒤 못 판정했다: 다시 부르지 않고 결과로 닫는다. 모든 후보를 그대로 기록한다 (영향이 없다고 단정하지 않는다)
    return { kind: "not_judged", evidence: judged.evidence, ids: idsOf(impact.candidates, extra) };
  }
  if (judged?.kind === "judged") {
    // 확실한 후보 + 판정 뒤에도 남은 불확실한 후보
    const kept = [...impact.candidates.filter((c) => c.certainty === "certain"), ...judged.remaining];
    return { kind: kept.length > 0 ? "impact_recorded" : "no_impact", evidence: judged.evidence, ids: idsOf(kept, extra) };
  }
  return { kind: "impact_recorded", evidence: "deterministic_only", ids: idsOf(impact.candidates, extra) };
}

/** 사건 하나를 처리해 기록한다. 처리 중 예외는 처리 완료로 기록하지 않고 실패(재시도 지연)로 남긴다 */
export async function coordinateEvent(deps: CoordinatorDeps, event: ClaimedEvent): Promise<EventResult> {
  let outcome: Outcome;
  try {
    outcome = await decideOutcome(deps, event);
  } catch (error) {
    console.error(JSON.stringify({ event: "coordinator_event_failed", type: event.type, attempts: event.attempts, error: error instanceof Error ? error.name : "unknown" }));
    await deps.store.fail(event, "decide_error", COORDINATOR_RETRY_DELAY_S).catch(() => false);
    return { status: "failed" };
  }
  try {
    return { status: await deps.store.finish(event, outcome), outcome };
  } catch (error) {
    console.error(JSON.stringify({ event: "coordinator_finish_failed", type: event.type, error: error instanceof Error ? error.name : "unknown" }));
    await deps.store.fail(event, "finish_error", COORDINATOR_RETRY_DELAY_S).catch(() => false);
    return { status: "failed" };
  }
}

export type RunSummary = {
  claimed: number;
  finished: number;
  already_finished: number;
  lost_claim: number;
  failed: number;
  results: Record<ResultKind, number>;
};

export const emptySummary = (): RunSummary => ({
  claimed: 0,
  finished: 0,
  already_finished: 0,
  lost_claim: 0,
  failed: 0,
  results: Object.fromEntries(RESULT_KINDS.map((k) => [k, 0])) as Record<ResultKind, number>,
});

/**
 * 집고 처리하기를 반복한다. batch 상한 두 개로 쌓인 사건이 한꺼번에 몰리지 않는다 (사건 수 MAX_EVENTS_PER_RUN · 시간 RUN_TIME_BUDGET_MS):
 * 한도에 닿으면 남은 사건은 그대로 두고 다음 호출이 이어 간다. 사용자마다 머리 하나씩만 집히므로 같은 사용자의 사건은 이 안에서도 순서대로다.
 */
export async function runCoordinator(
  deps: CoordinatorDeps,
  options: { consumer: string; maxEvents?: number; timeBudgetMs?: number; claimBatch?: number; now?: () => number },
): Promise<RunSummary & { more: boolean }> {
  const summary = emptySummary();
  const maxEvents = options.maxEvents ?? MAX_EVENTS_PER_RUN;
  const budget = options.timeBudgetMs ?? RUN_TIME_BUDGET_MS;
  const now = options.now ?? Date.now;
  const started = now();
  let more = false;
  while (summary.claimed < maxEvents) {
    if (now() - started >= budget) {
      more = true;
      break;
    }
    const batch = await deps.store.claim(options.consumer, Math.min(options.claimBatch ?? CLAIM_BATCH, maxEvents - summary.claimed));
    if (batch.length === 0) break;
    summary.claimed += batch.length;
    for (const event of batch) {
      const result = await coordinateEvent(deps, event);
      summary[result.status] += 1;
      if (result.outcome && result.status === "finished") summary.results[result.outcome.kind] += 1;
    }
    // 이번 호출의 상한에 닿았다: 더 있을 수 있다
    if (summary.claimed >= maxEvents) more = true;
  }
  return { ...summary, more };
}
