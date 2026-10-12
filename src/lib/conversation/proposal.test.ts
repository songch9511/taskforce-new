import { describe, expect, it } from "vitest";

import { adoptPlan, conversationLink, payloadHash, proposalFromModel, proposalIntact, reissueProposal } from "./proposal";

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
