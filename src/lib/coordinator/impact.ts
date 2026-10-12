import { MAX_CANDIDATES } from "./coordinator.config";
import type { Candidate, CandidateKind, EvidenceKind } from "./types";

// 영향 계산 (순수). 영향받는 객체 후보는 코드가 소유권 + DB에서 읽은 실제 관계로 정한다 (reads.ts가 user_id로 좁혀 다시 확인한 사실만 들어온다).
// 모델(Jev · 생성)은 여기서 나온 후보 밖의 객체를 고르거나 바꾸지 못한다 (judgments.ts가 출력을 후보 집합으로 거른다).
// 자료 · 기억 변화는 context_version, 사용자 지시는 directive_version이다 — 섞거나 서로 파생하지 않는다 (DR06).
// 이 모듈은 아무것도 쓰지 않는다: 후보를 만들 뿐, 재dispatch · 새 run · 단계 · Claim · Action 완료를 만들지 않는다.

/** 살아 있는(queued · running · waiting_approval) run의 사실. manifest는 묶음에 든 항목 id (D1 이전에는 저장하지 않아 DB에서 읽으면 늘 null) */
export type LiveRun = {
  id: string;
  actionId: string;
  contextId: string | null;
  /** 묶음을 만들 때의 범위 version (없으면 묶음 없음) */
  bundleContextVersion: number | null;
  directiveVersion: number;
  manifest: string[] | null;
};

/** 코드가 DB에서 확인한 사실. 각 변형은 사건 종류 하나의 입력이다. 가리켰지만 확인하지 못한 객체(없음 · 남의 것)는 present false로 같게 다룬다 */
export type Facts =
  | { kind: "source"; source: { present: boolean; accessLost: boolean }; actionIds: string[]; contextIds: string[]; liveRuns: LiveRun[] }
  | { kind: "message"; message: { present: boolean; isUser: boolean }; selectedActionIds: string[]; selectedRunIds: string[]; dropped: number }
  | { kind: "decision"; present: boolean; actionId: string | null; liveRuns: LiveRun[]; runIds: string[] }
  | { kind: "context"; context: { present: boolean; version: number }; eventVersion: number | null; liveRuns: LiveRun[]; changedItemIds: string[] | null }
  | { kind: "timer"; action: { id: string; present: boolean; open: boolean; dueEpoch: number | null }; eventDueEpoch: number | null }
  // 시험 · 후속 레인의 사건(원천이 없는 종류): 후보를 직접 준다
  | { kind: "generic"; candidates: Candidate[]; stale?: StaleEvidence }
  | { kind: "unsupported" };

export type StaleEvidence = Extract<EvidenceKind, "source_deleted" | "source_access_lost" | "parent_deleted" | "version_mismatch" | "already_handled">;

export type Impact =
  | { kind: "stale"; evidence: StaleEvidence }
  | { kind: "rejected"; evidence: Extract<EvidenceKind, "invalid_refs" | "no_owned_refs"> }
  | { kind: "not_handled"; evidence: "type_not_connected" }
  | { kind: "candidates"; candidates: Candidate[]; truncated: number; dropped: number };

const KIND_ORDER: Record<CandidateKind, number> = { action: 0, context: 1, run: 2 };

/** 같은 (kind, id)는 하나로(더 확실한 쪽), id 순으로 정렬해 항상 같은 순서로, 상한을 넘으면 자르고 잘린 수를 센다 */
export function capCandidates(candidates: Candidate[], max = MAX_CANDIDATES): { candidates: Candidate[]; truncated: number } {
  const byKey = new Map<string, Candidate>();
  for (const candidate of candidates) {
    const key = candidateKey(candidate);
    const previous = byKey.get(key);
    if (!previous || (previous.certainty === "uncertain" && candidate.certainty === "certain")) byKey.set(key, candidate);
  }
  const sorted = [...byKey.values()].sort((a, b) => KIND_ORDER[a.kind] - KIND_ORDER[b.kind] || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { candidates: sorted.slice(0, max), truncated: Math.max(0, sorted.length - max) };
}

export const candidateKey = (candidate: Pick<Candidate, "kind" | "id">) => `${candidate.kind}:${candidate.id}`;

const action = (id: string, relation: string, certainty: Candidate["certainty"] = "certain"): Candidate => ({ kind: "action", id, relation, certainty });
const context = (id: string, relation: string, certainty: Candidate["certainty"] = "certain"): Candidate => ({ kind: "context", id, relation, certainty });
const run = (id: string, relation: string, certainty: Candidate["certainty"] = "uncertain"): Candidate => ({ kind: "run", id, relation, certainty });

/**
 * 묶음 변화가 살아 있는 run의 현재 결과에 닿는가 (DR06 stale 판정):
 *  - 묶음이 없거나(bundle_context_version null) 이미 최신 범위 version이면 닿지 않는다.
 *  - manifest를 알고(D1 이후) 바뀐 항목이 manifest 밖이면 현재 결과를 무효화하지 않는다 (outside_manifest).
 *  - manifest 안이면 닿는다. manifest를 모르면(지금 DB는 저장하지 않는다) 닿는지 단정하지 않고 후보로만 남긴다 (manifest_unknown) — 어느 쪽이든 재dispatch하지 않는다.
 */
export type BundleEffect = "no_bundle" | "up_to_date" | "outside_manifest" | "in_manifest" | "manifest_unknown";
export function bundleChangeEffect(input: { run: LiveRun; currentContextVersion: number; changedItemIds: string[] | null }): BundleEffect {
  const { run } = input;
  if (run.bundleContextVersion === null) return "no_bundle";
  if (run.bundleContextVersion >= input.currentContextVersion) return "up_to_date";
  if (run.manifest === null || input.changedItemIds === null) return "manifest_unknown";
  const manifest = new Set(run.manifest);
  return input.changedItemIds.some((id) => manifest.has(id)) ? "in_manifest" : "outside_manifest";
}

/** 사건 하나의 영향 후보. facts는 reads.ts(또는 시험)가 준 사실이다 */
export function computeImpact(facts: Facts): Impact {
  switch (facts.kind) {
    case "unsupported":
      return { kind: "not_handled", evidence: "type_not_connected" };

    case "generic":
      if (facts.stale) return { kind: "stale", evidence: facts.stale };
      return { kind: "candidates", ...capCandidates(facts.candidates), dropped: 0 };

    case "source": {
      if (!facts.source.present) return { kind: "stale", evidence: "source_deleted" };
      if (facts.source.accessLost) return { kind: "stale", evidence: "source_access_lost" };
      const { candidates, truncated } = capCandidates([
        ...facts.actionIds.map((id) => action(id, "evidence")),
        ...facts.contextIds.map((id) => context(id, "member")),
        ...facts.liveRuns.map((r) => run(r.id, "live_run")),
      ]);
      return { kind: "candidates", candidates, truncated, dropped: 0 };
    }

    case "message": {
      if (!facts.message.present) return { kind: "stale", evidence: "parent_deleted" };
      if (!facts.message.isUser) return { kind: "rejected", evidence: "invalid_refs" };
      const { candidates, truncated } = capCandidates([
        ...facts.selectedActionIds.map((id) => action(id, "selected")),
        ...facts.selectedRunIds.map((id) => run(id, "selected", "certain")),
      ]);
      return { kind: "candidates", candidates, truncated, dropped: facts.dropped };
    }

    case "decision": {
      if (!facts.present) return { kind: "stale", evidence: "parent_deleted" };
      const { candidates, truncated } = capCandidates([
        ...(facts.actionId ? [action(facts.actionId, "decided")] : []),
        ...facts.runIds.map((id) => run(id, "decided", "certain")),
        ...facts.liveRuns.map((r) => run(r.id, "live_run")),
      ]);
      return { kind: "candidates", candidates, truncated, dropped: 0 };
    }

    case "context": {
      if (!facts.context.present) return { kind: "stale", evidence: "parent_deleted" };
      // 더 새 범위 version의 사건이 따로 있다: 이 사건의 변화는 그쪽이 현재 상태에서 다시 계산한다
      if (facts.eventVersion !== null && facts.eventVersion < facts.context.version) return { kind: "stale", evidence: "version_mismatch" };
      // manifest 밖의 변화는 현재 결과를 무효화하지 않는다. manifest를 모르면(지금) 단정하지 않고 후보로만 남긴다
      const stale = facts.liveRuns.filter((r) => {
        const effect = bundleChangeEffect({ run: r, currentContextVersion: facts.context.version, changedItemIds: facts.changedItemIds });
        return effect === "manifest_unknown" || effect === "in_manifest";
      });
      const { candidates, truncated } = capCandidates(stale.map((r) => run(r.id, "bundle_stale")));
      return { kind: "candidates", candidates, truncated, dropped: 0 };
    }

    case "timer": {
      if (!facts.action.present) return { kind: "stale", evidence: "parent_deleted" };
      if (!facts.action.open) return { kind: "stale", evidence: "already_handled" };
      if (facts.eventDueEpoch === null) return { kind: "rejected", evidence: "invalid_refs" };
      if (facts.action.dueEpoch !== facts.eventDueEpoch) return { kind: "stale", evidence: "version_mismatch" };
      return { kind: "candidates", candidates: [action(facts.action.id, "due_window")], truncated: 0, dropped: 0 };
    }
  }
}

// ───────────────────────── 결과 귀속 · 도착 순서 (ARCH14, 런타임 계약 5장) ─────────────────────────
// 에이전트 결과는 "어느 지시의 결과인가"로 귀속한다. 도착 순서(observed_at · 먼저 옴)는 최신성의 증거가 아니다.
// 지금은 에이전트 결과를 만드는 원천이 없어(D1) 이 함수는 fixture로만 시험한다 — 연결되지 않았다.

export type RunDirective = { id: string; directiveVersion: number; expectedResultRevision: number };
export type AgentResult = { id: string; directiveVersion: number | null; resultRevision: number | null };
export type Attribution = "current" | "superseded" | "unattributed";

export function attributeResult(run: RunDirective, result: AgentResult): Attribution {
  // 지시 회차가 없으면 어느 지시의 결과인지 모른다: 현재 결과로 올리지 않는다
  if (result.directiveVersion === null) return "unattributed";
  // 현재 지시보다 낮으면 옛 지시의 결과, 높으면 이 run이 알지 못하는 회차(귀속 불가)
  if (result.directiveVersion < run.directiveVersion) return "superseded";
  if (result.directiveVersion > run.directiveVersion) return "unattributed";
  // 같은 지시 안에서도 수정 요청 전 결과(낮은 revision)는 새 결과가 아니다 (A38). revision이 없으면 귀속 불가
  if (result.resultRevision === null) return "unattributed";
  if (result.resultRevision < run.expectedResultRevision) return "superseded";
  if (result.resultRevision > run.expectedResultRevision) return "unattributed";
  return "current";
}

export type Arrival =
  | { kind: "requirement_change"; id: string }
  | { kind: "result"; result: AgentResult };

export type ArrivalPlan = {
  /** 요구 변경이 도착했다: acceptance 재평가 · 결정 요청으로 간다 (자동 재dispatch가 아니다). 사용자 결정은 routing.ts */
  reevaluateAcceptance: boolean;
  results: { id: string; attribution: Attribution; promote: boolean }[];
  /** 현재 결과로 검토 · 전달할 결과 id. 요구 변경과 같은 묶음에 도착했거나 귀속 못 한 결과는 올리지 않는다 */
  deliverAsCurrent: string[];
};

/** 같은 run에 요구 변경과 결과가 함께 도착한 묶음의 처리 계획. 입력 순서와 상관없이 같은 결과다 (도착 순서로 승자를 정하지 않는다) */
export function planArrivals(run: RunDirective, arrivals: Arrival[]): ArrivalPlan {
  const requirementChange = arrivals.some((a) => a.kind === "requirement_change");
  const results = arrivals
    .flatMap((a) => (a.kind === "result" ? [a.result] : []))
    .map((result) => {
      const attribution = attributeResult(run, result);
      // 요구 변경이 같이 왔으면 지금 지시(acceptance)의 결과도 변경 전 기준으로 만들어진 것이라 현재 결과로 올리지 않는다
      return { id: result.id, attribution, promote: attribution === "current" && !requirementChange };
    })
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return { reevaluateAcceptance: requirementChange, results, deliverAsCurrent: results.filter((r) => r.promote).map((r) => r.id) };
}
