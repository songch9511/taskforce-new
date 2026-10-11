import { describe, expect, it } from "vitest";

import { MAX_CANDIDATES } from "./coordinator.config";
import {
  attributeResult,
  bundleChangeEffect,
  candidateKey,
  capCandidates,
  computeImpact,
  planArrivals,
  type Arrival,
  type Facts,
  type LiveRun,
  type RunDirective,
} from "./impact";
import type { Candidate } from "./types";

// 영향 계산 · 결과 귀속 (순수). [현재 실제] = reads.ts가 실제로 만드는 사실에서 나온 입력, [미래 fixture] = 원천(에이전트 · 회신)이 아직 없어 입력을 직접 만든 시험.

const id = (n: number, prefix = "aaaaaaaa") => `${prefix}-0000-4000-8000-${String(n).padStart(12, "0")}`;
const run = (n: number, extra: Partial<LiveRun> = {}): LiveRun => ({ id: id(n, "cccccccc"), actionId: id(1), contextId: null, bundleContextVersion: null, directiveVersion: 1, manifest: null, ...extra });

describe("[현재 실제] 영향 후보: 사건 종류별 (코드가 DB 사실로 정한다)", () => {
  it("원문 처리: 그 원문(같은 문서)에 근거한 Action은 확실한 후보, 멤버 범위도 확실, 살아 있는 run은 불확실한 후보 (재dispatch 없음 — 후보만)", () => {
    const facts: Facts = { kind: "source", source: { present: true, accessLost: false }, actionIds: [id(2), id(1)], contextIds: [id(9, "dddddddd")], liveRuns: [run(1)] };
    const impact = computeImpact(facts);
    expect(impact.kind).toBe("candidates");
    if (impact.kind !== "candidates") return;
    expect(impact.candidates).toEqual([
      { kind: "action", id: id(1), relation: "evidence", certainty: "certain" },
      { kind: "action", id: id(2), relation: "evidence", certainty: "certain" },
      { kind: "context", id: id(9, "dddddddd"), relation: "member", certainty: "certain" },
      { kind: "run", id: id(1, "cccccccc"), relation: "live_run", certainty: "uncertain" },
    ]);
  });

  it("증거 있는 stale만 stale이다: 원문 삭제 · 접근 상실 · 부모 삭제 · 버전 불일치 · 이미 처리됨. 나이로 stale을 만들지 않는다", () => {
    expect(computeImpact({ kind: "source", source: { present: false, accessLost: false }, actionIds: [], contextIds: [], liveRuns: [] })).toEqual({ kind: "stale", evidence: "source_deleted" });
    expect(computeImpact({ kind: "source", source: { present: true, accessLost: true }, actionIds: [id(1)], contextIds: [], liveRuns: [] })).toEqual({ kind: "stale", evidence: "source_access_lost" });
    expect(computeImpact({ kind: "message", message: { present: false, isUser: false }, selectedActionIds: [], selectedRunIds: [], dropped: 0 })).toEqual({ kind: "stale", evidence: "parent_deleted" });
    expect(computeImpact({ kind: "decision", present: false, actionId: null, liveRuns: [], runIds: [] })).toEqual({ kind: "stale", evidence: "parent_deleted" });
    expect(computeImpact({ kind: "context", context: { present: true, version: 5 }, eventVersion: 3, liveRuns: [run(1, { contextId: id(9), bundleContextVersion: 1 })], changedItemIds: null })).toEqual({
      kind: "stale",
      evidence: "version_mismatch",
    });
    const timer = (extra: Partial<Extract<Facts, { kind: "timer" }>["action"]>, eventDueEpoch: number | null = 1_000) =>
      computeImpact({ kind: "timer", action: { id: id(1), present: true, open: true, dueEpoch: 1_000, ...extra }, eventDueEpoch });
    expect(timer({ present: false })).toEqual({ kind: "stale", evidence: "parent_deleted" });
    expect(timer({ open: false })).toEqual({ kind: "stale", evidence: "already_handled" });
    expect(timer({ dueEpoch: 2_000 })).toEqual({ kind: "stale", evidence: "version_mismatch" });
    expect(timer({}, null)).toEqual({ kind: "rejected", evidence: "invalid_refs" });
    expect(timer({})).toEqual({ kind: "candidates", candidates: [{ kind: "action", id: id(1), relation: "due_window", certainty: "certain" }], truncated: 0, dropped: 0 });
  });

  it("사용자 메시지: 고른 대상(내 것으로 확인된 것)만 후보, 사용자가 아닌 행(답)은 거절, 후보 밖 고른 대상은 dropped로 센다", () => {
    expect(computeImpact({ kind: "message", message: { present: true, isUser: false }, selectedActionIds: [], selectedRunIds: [], dropped: 0 })).toEqual({ kind: "rejected", evidence: "invalid_refs" });
    const impact = computeImpact({ kind: "message", message: { present: true, isUser: true }, selectedActionIds: [id(1)], selectedRunIds: [id(2, "cccccccc")], dropped: 2 });
    expect(impact).toEqual({
      kind: "candidates",
      candidates: [
        { kind: "action", id: id(1), relation: "selected", certainty: "certain" },
        { kind: "run", id: id(2, "cccccccc"), relation: "selected", certainty: "certain" },
      ],
      truncated: 0,
      dropped: 2,
    });
    expect(computeImpact({ kind: "message", message: { present: true, isUser: true }, selectedActionIds: [], selectedRunIds: [], dropped: 0 })).toMatchObject({ kind: "candidates", candidates: [] });
  });

  it("지원하지 않는 종류(생산자 없음)는 not_handled", () => {
    expect(computeImpact({ kind: "unsupported" })).toEqual({ kind: "not_handled", evidence: "type_not_connected" });
  });
});

describe("후보 상한 · 정렬 · 중복", () => {
  const cand = (kind: Candidate["kind"], n: number, certainty: Candidate["certainty"] = "certain"): Candidate => ({ kind, id: id(n), relation: "x", certainty });
  it("같은 (kind, id)는 하나(더 확실한 쪽), 종류 → id 순으로 항상 같은 순서", () => {
    const out = capCandidates([cand("run", 3), cand("action", 2), cand("action", 1, "uncertain"), cand("action", 1, "certain"), cand("context", 5)]);
    expect(out.candidates.map((c) => [c.kind, c.id, c.certainty])).toEqual([["action", id(1), "certain"], ["action", id(2), "certain"], ["context", id(5), "certain"], ["run", id(3), "certain"]]);
    const shuffled = capCandidates([cand("context", 5), cand("action", 1, "certain"), cand("run", 3), cand("action", 2)]);
    expect(shuffled.candidates).toEqual(out.candidates);
  });

  it("상한을 넘으면 앞에서 자르고 잘린 수를 센다 (결과가 무한히 커지지 않는다)", () => {
    const many = Array.from({ length: MAX_CANDIDATES + 7 }, (_, i) => cand("action", i + 1));
    const out = capCandidates(many);
    expect(out.candidates).toHaveLength(MAX_CANDIDATES);
    expect(out.truncated).toBe(7);
  });

  it("candidateKey는 kind:id", () => {
    expect(candidateKey({ kind: "run", id: "x" })).toBe("run:x");
  });
});

describe("묶음 manifest: 묶음 밖의 변화는 현재 결과를 무효화하지 않는다 (DR06, ARCH03)", () => {
  const ctx = id(9, "dddddddd");
  it("묶음이 없거나 이미 최신이면 닿지 않는다", () => {
    expect(bundleChangeEffect({ run: run(1, { contextId: ctx }), currentContextVersion: 4, changedItemIds: ["a"] })).toBe("no_bundle");
    expect(bundleChangeEffect({ run: run(1, { contextId: ctx, bundleContextVersion: 4 }), currentContextVersion: 4, changedItemIds: ["a"] })).toBe("up_to_date");
  });

  it("[미래 fixture] manifest를 알면: 바뀐 항목이 manifest 안일 때만 stale, 밖이면 outside_manifest(무효화 0)", () => {
    const r = run(1, { contextId: ctx, bundleContextVersion: 2, manifest: ["mem-1", "src-1"] });
    expect(bundleChangeEffect({ run: r, currentContextVersion: 4, changedItemIds: ["mem-1"] })).toBe("in_manifest");
    expect(bundleChangeEffect({ run: r, currentContextVersion: 4, changedItemIds: ["mem-99", "act-7"] })).toBe("outside_manifest");
  });

  it("[현재 실제] manifest를 저장하지 않아(null) 닿는지 단정하지 않는다: 후보로만 남고 어떤 것도 바꾸지 않는다", () => {
    const r = run(1, { contextId: ctx, bundleContextVersion: 2, manifest: null });
    expect(bundleChangeEffect({ run: r, currentContextVersion: 4, changedItemIds: null })).toBe("manifest_unknown");
    const impact = computeImpact({ kind: "context", context: { present: true, version: 4 }, eventVersion: 4, liveRuns: [r], changedItemIds: null });
    expect(impact).toMatchObject({ kind: "candidates", candidates: [{ kind: "run", id: r.id, relation: "bundle_stale", certainty: "uncertain" }] });
  });

  it("[미래 fixture] 같은 범위 변화라도 manifest 밖이면 후보 0 → 영향 없음", () => {
    const r = run(1, { contextId: ctx, bundleContextVersion: 2, manifest: ["mem-1"] });
    expect(computeImpact({ kind: "context", context: { present: true, version: 3 }, eventVersion: 3, liveRuns: [r], changedItemIds: ["mem-77"] })).toMatchObject({ kind: "candidates", candidates: [] });
  });
});

describe("[미래 fixture] 결과 귀속 · 도착 순서 (ARCH14): 원천(에이전트 · 회신)이 아직 없어 입력을 직접 만든다 — 연결되지 않았다", () => {
  const directive: RunDirective = { id: id(1, "cccccccc"), directiveVersion: 3, expectedResultRevision: 2 };

  it("귀속은 지시 회차와 수정 회차로만 정한다: 낮은 회차는 옛 결과, 회차가 없거나 모르는 회차는 귀속 불가, 정확히 맞아야 현재", () => {
    const r = (directiveVersion: number | null, resultRevision: number | null) => attributeResult(directive, { id: "r", directiveVersion, resultRevision });
    expect(r(3, 2)).toBe("current");
    expect(r(2, 2)).toBe("superseded");
    expect(r(3, 1)).toBe("superseded");
    expect(r(null, 2)).toBe("unattributed");
    expect(r(4, 2)).toBe("unattributed");
    expect(r(3, null)).toBe("unattributed");
    expect(r(3, 3)).toBe("unattributed");
  });

  it("요구 변경과 옛 결과가 같이 도착: 요구 변경은 acceptance 재평가로, 옛 결과는 현재 결과로 전달 0. 어느 쪽이 먼저 와도 같다", () => {
    const change: Arrival = { kind: "requirement_change", id: "chg" };
    const old: Arrival = { kind: "result", result: { id: "old", directiveVersion: 2, resultRevision: 2 } };
    const same: Arrival = { kind: "result", result: { id: "same", directiveVersion: 3, resultRevision: 2 } };
    const a = planArrivals(directive, [change, old, same]);
    const b = planArrivals(directive, [same, old, change]);
    const c = planArrivals(directive, [old, change, same]);
    expect(a).toEqual(b);
    expect(a).toEqual(c);
    expect(a.reevaluateAcceptance).toBe(true);
    expect(a.deliverAsCurrent).toEqual([]);
    expect(a.results).toEqual([
      { id: "old", attribution: "superseded", promote: false },
      { id: "same", attribution: "current", promote: false },
    ]);
  });

  it("요구 변경이 없으면 현재 지시 · 현재 회차로 귀속된 결과만 전달한다. 도착 순서(나중에 온 옛 결과)로 최신을 정하지 않는다", () => {
    const current: Arrival = { kind: "result", result: { id: "fresh", directiveVersion: 3, resultRevision: 2 } };
    const lateOld: Arrival = { kind: "result", result: { id: "stale", directiveVersion: 1, resultRevision: 1 } };
    const unknown: Arrival = { kind: "result", result: { id: "unknown", directiveVersion: null, resultRevision: null } };
    for (const order of [[current, lateOld, unknown], [lateOld, unknown, current], [unknown, current, lateOld]]) {
      const plan = planArrivals(directive, order);
      expect(plan.reevaluateAcceptance).toBe(false);
      expect(plan.deliverAsCurrent).toEqual(["fresh"]);
      expect(plan.results.find((x) => x.id === "unknown")).toMatchObject({ attribution: "unattributed", promote: false });
    }
  });
});
