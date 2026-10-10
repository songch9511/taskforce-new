import { describe, expect, it } from "vitest";

import { normalizeSelected, resolveReferent, type Target } from "./referent";

// 지시 대상 규칙 1–4 (런타임 계약 2장, A34): 순서대로 하나만, 둘 이상이면 후보 ≤ 3개로 묻는다. 제목 유사도로 고르지 않는다.

const action = (id: string, title = id): Target => ({ kind: "action", id, title });
const proposal = { messageId: "m1", proposalId: "p1", payloadHash: "sha256:x", title: "Shape 출시 준비" };

describe("resolveReferent", () => {
  it("채택은 직전 답의 열린 제안만 (규칙 2). 없으면 none (다른 Action으로 넘어가지 않는다)", () => {
    expect(resolveReferent({ selected: [], previousProposal: proposal, linkedOpenActions: [], wants: "proposal" })).toEqual({ kind: "proposal", proposal });
    expect(resolveReferent({ selected: [action("a1")], previousProposal: null, linkedOpenActions: [{ id: "a2", title: "x" }], wants: "proposal" })).toEqual({ kind: "none" });
  });

  it("규칙 1: 앱이 고른 대상이 하나면 그것 (대화에 연결된 할 일보다 먼저)", () => {
    expect(resolveReferent({ selected: [action("a1")], previousProposal: null, linkedOpenActions: [{ id: "a2", title: "b" }, { id: "a3", title: "c" }], wants: "work" })).toEqual({
      kind: "target",
      target: action("a1"),
      rule: 1,
    });
  });

  it("규칙 1: 앱이 고른 대상이 둘 이상이면 3개까지 들어 묻는다", () => {
    const four = ["a1", "a2", "a3", "a4"].map((id) => action(id));
    expect(resolveReferent({ selected: four, previousProposal: null, linkedOpenActions: [], wants: "work" })).toEqual({ kind: "ask", candidates: four.slice(0, 3) });
  });

  it("규칙 3 · 4: 대화에 연결된 열린 할 일이 하나면 그것, 둘 이상이면 묻는다 (같은 id는 한 번, 대소문자 무시)", () => {
    expect(resolveReferent({ selected: [], previousProposal: null, linkedOpenActions: [{ id: "A1", title: "x" }, { id: "a1", title: "x" }], wants: "work" })).toEqual({
      kind: "target",
      target: { kind: "action", id: "A1", title: "x" },
      rule: 3,
    });
    const linked = ["a1", "a2", "a3", "a4"].map((id) => ({ id, title: id }));
    expect(resolveReferent({ selected: [], previousProposal: null, linkedOpenActions: linked, wants: "work" })).toEqual({
      kind: "ask",
      candidates: linked.slice(0, 3).map((a) => ({ kind: "action", ...a })),
    });
  });

  it("대상이 없으면 none", () => {
    expect(resolveReferent({ selected: [], previousProposal: proposal, linkedOpenActions: [], wants: "work" })).toEqual({ kind: "none" });
  });
});

describe("normalizeSelected (같은 제출 비교, Codex P2)", () => {
  it("소문자 · 중복 제거 · 정렬: 순서 · 중복 · 대소문자만 다르면 같다. 없으면 빈 목록 셋", () => {
    const A = "AAAAAAAA-0000-4000-8000-000000000001";
    const b = "bbbbbbbb-0000-4000-8000-000000000002";
    expect(normalizeSelected({ action_ids: [b, A, A.toLowerCase()] })).toEqual({ action_ids: [A.toLowerCase(), b], run_ids: [], artifact_ids: [] });
    expect(normalizeSelected({ action_ids: [A.toLowerCase(), b] })).toEqual(normalizeSelected({ action_ids: [b, A] }));
    expect(normalizeSelected(undefined)).toEqual({ action_ids: [], run_ids: [], artifact_ids: [] });
  });
});
