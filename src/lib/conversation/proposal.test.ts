import { createHash } from "node:crypto";

import { describe, expect, it } from "vitest";

import type { OrganizeTarget, ProposalPayloadV2 } from "@/lib/api/contract";

import { adoptPlan, conversationLink, newProposal, payloadHash, proposalFromModel, proposalIntact, reissueProposal } from "./proposal";

// 제안 · 채택 (런타임 계약 2장, A41). B2의 제안은 create_action뿐이고 run · modify · stop 제안은 만들지 않는다.

let n = 0;
const newId = () => `eeeeeeee-0000-4000-8000-${String(++n).padStart(12, "0")}`;

describe("proposal", () => {
  it("payload_hash는 내용이 같으면 같고 다르면 다르다", () => {
    const a = payloadHash({ kind: "create_action", title: "Shape 출시 준비" });
    expect(a).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(payloadHash({ kind: "create_action", title: "Shape 출시 준비" })).toBe(a);
    expect(payloadHash({ kind: "create_action", title: "Shape 출시" })).not.toBe(a);
  });

  it("모델 제안: 빈 제목 · 200자 넘는 제목 · 열린 할 일과 같은 제목(공백 · 문장부호 무시)은 내지 않는다", () => {
    expect(proposalFromModel(null, [], newId)).toBeNull();
    expect(proposalFromModel({ title: "  " }, [], newId)).toBeNull();
    expect(proposalFromModel({ title: "가".repeat(201) }, [], newId)).toBeNull();
    expect(proposalFromModel({ title: "견적서 보내기!" }, ["견적서  보내기"], newId)).toBeNull();
    const made = proposalFromModel({ title: " Shape   출시 준비 " }, ["견적서 보내기"], newId)!;
    expect(made.payload).toEqual({ kind: "create_action", title: "Shape 출시 준비" });
    expect(made.ref).toEqual({ id: expect.any(String), kind: "create_action", payload_hash: payloadHash(made.payload), state: "open" });
  });

  it("다시 낸 제안은 같은 내용 · 새 id", () => {
    const payload = { kind: "create_action" as const, title: "Shape 출시 준비" };
    const first = reissueProposal(payload, newId);
    const second = reissueProposal(payload, newId);
    expect(first.ref.payload_hash).toBe(second.ref.payload_hash);
    expect(first.ref.id).not.toBe(second.ref.id);
  });

  it("저장된 내용이 hash와 다르거나 비었으면 채택할 수 없다", () => {
    const payload = { kind: "create_action" as const, title: "Shape 출시 준비" };
    const ref = { kind: "create_action" as const, payload_hash: payloadHash(payload) };
    expect(proposalIntact(ref, payload)).toBe(true);
    expect(proposalIntact(ref, { ...payload, title: "다른 제목" })).toBe(false);
    expect(proposalIntact(ref, null)).toBe(false);
    expect(proposalIntact({ kind: "run" as never, payload_hash: ref.payload_hash }, payload)).toBe(false);
  });

  it("채택 계획: 사용자 Claim(제목 · 나 · 열림)만, 기한 없음, 근거 = note 원문의 채택한 한 줄, user_created 이벤트", () => {
    const plan = adoptPlan({
      userId: "11111111-0000-4000-8000-000000000001",
      conversationId: "cccccccc-0000-4000-8000-000000000001",
      adoptMessageId: "dddddddd-0000-4000-8000-000000000003",
      proposalMessageId: "dddddddd-0000-4000-8000-000000000002",
      proposal: { id: "fafafafa-0000-4000-8000-000000000002", payload_hash: "sha256:x" },
      payload: { kind: "create_action", title: "Shape 출시 준비" },
      now: new Date("2026-10-10T01:00:00Z"),
      newId,
    });
    expect(plan.note.external_url).toBe(conversationLink("cccccccc-0000-4000-8000-000000000001", "dddddddd-0000-4000-8000-000000000003"));
    expect(plan.note.raw_text).toBe("Shape 출시 준비");
    expect(plan.claims.map((c) => c.field)).toEqual(["scope", "owner", "status"]);
    expect(plan.claims.every((c) => c.origin === "user" && c.channel === "note" && c.source_id === plan.note.id)).toBe(true);
    expect(plan.action).toMatchObject({ title: "Shape 출시 준비", owner: "me", status: "open", due_date: null, due_at: null, needs_confirmation: false, embedding: null });
    expect(plan.events).toEqual([expect.objectContaining({ type: "user_created", actor: "user", rule: "user", source_id: plan.note.id })]);
  });
});

// ─── D4c-2: 이동 · 삭제 · 병합 제안 ───
const target = (n: number, overrides: Partial<OrganizeTarget> = {}): OrganizeTarget => ({
  action_id: `aaaaaaaa-0000-4000-8000-${String(n).padStart(12, "0")}`,
  number: n,
  title: `이슈 ${n}`,
  version: 2,
  contexts: [{ id: "c1c1c1c1-0000-4000-8000-000000000001", name: "Launch" }],
  open_sessions: 1,
  evidence_count: 3,
  ...overrides,
});
const ctxRef = (n: number, name = "Launch", version = 3) => ({ id: `c1c1c1c1-0000-4000-8000-${String(n).padStart(12, "0")}`, name, version });

describe("proposal hash: 종류별 (D4c-2)", () => {
  it("create_action은 B2와 같은 값이다 (JSON.stringify({ kind, title })의 sha256)", () => {
    const legacy = `sha256:${createHash("sha256").update(JSON.stringify({ kind: "create_action", title: "Shape 출시 준비" })).digest("hex")}`;
    expect(payloadHash({ kind: "create_action", title: "Shape 출시 준비" })).toBe(legacy);
  });

  it("삭제: 대상 id · version이 같으면 같은 확인 — 제목 · 번호 · 프로젝트 이름 · 세션 수는 hash에 넣지 않고, 순서도 무관(id 오름차순)", () => {
    const a = payloadHash({ kind: "delete", targets: [target(1), target(2)] });
    expect(payloadHash({ kind: "delete", targets: [target(2), target(1)] })).toBe(a);
    expect(payloadHash({ kind: "delete", targets: [target(1, { title: "다른 제목", number: 9, open_sessions: 0, evidence_count: 0, contexts: [] }), target(2)] })).toBe(a);
    expect(payloadHash({ kind: "delete", targets: [target(1, { version: 3 }), target(2)] })).not.toBe(a);
    expect(payloadHash({ kind: "delete", targets: [target(1)] })).not.toBe(a);
  });

  it("병합: 어느 쪽이 남는지가 hash에 든다. 종류가 다르면 같은 대상이어도 다르다", () => {
    const merge = payloadHash({ kind: "merge", from: target(1), into: target(2) });
    expect(payloadHash({ kind: "merge", from: target(2), into: target(1) })).not.toBe(merge);
    expect(payloadHash({ kind: "delete", targets: [target(1), target(2)] })).not.toBe(merge);
    expect(payloadHash({ kind: "merge", from: target(1, { title: "x" }), into: target(2) })).toBe(merge);
  });

  it("이동: 대상 · 출발 · 도착 범위 id. 범위 이름 · version은 hash에 넣지 않는다 (채택할 때 다시 읽는다)", () => {
    const move = payloadHash({ kind: "move", targets: [target(1)], from: ctxRef(1, "A"), to: ctxRef(2, "B") });
    expect(payloadHash({ kind: "move", targets: [target(1)], from: ctxRef(1, "이름이 바뀜", 9), to: ctxRef(2, "B") })).toBe(move);
    expect(payloadHash({ kind: "move", targets: [target(1)], from: null, to: ctxRef(2, "B") })).not.toBe(move);
    expect(payloadHash({ kind: "move", targets: [target(1)], from: ctxRef(1, "A"), to: ctxRef(3, "C") })).not.toBe(move);
  });

  it("proposalIntact: 종류 · hash가 모두 맞아야 한다. 새 종류도 같은 규칙", () => {
    const payloads: ProposalPayloadV2[] = [
      { kind: "delete", targets: [target(1)] },
      { kind: "merge", from: target(1), into: target(2) },
      { kind: "move", targets: [target(1)], from: null, to: ctxRef(1) },
    ];
    for (const payload of payloads) {
      const { ref } = newProposal(payload, newId);
      expect(ref).toMatchObject({ kind: payload.kind, state: "open", payload_hash: payloadHash(payload) });
      expect(proposalIntact(ref, payload)).toBe(true);
      expect(proposalIntact({ ...ref, kind: payload.kind === "delete" ? "merge" : "delete" }, payload)).toBe(false);
      expect(proposalIntact({ ...ref, payload_hash: "sha256:other" }, payload)).toBe(false);
      expect(proposalIntact(ref, null)).toBe(false);
    }
    const delta: ProposalPayloadV2 = { kind: "delete", targets: [target(1, { version: 9 })] };
    expect(proposalIntact(newProposal({ kind: "delete", targets: [target(1)] }, newId).ref, delta)).toBe(false);
  });

  it("reissue는 같은 종류 · 새 id", () => {
    const payload: ProposalPayloadV2 = { kind: "delete", targets: [target(1)] };
    const first = newProposal(payload, newId);
    const again = reissueProposal(payload, newId);
    expect(again.ref.id).not.toBe(first.ref.id);
    expect(again.ref).toMatchObject({ kind: "delete", payload_hash: first.ref.payload_hash, state: "open" });
  });
});
