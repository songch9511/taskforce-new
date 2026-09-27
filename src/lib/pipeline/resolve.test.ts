import { describe, expect, it } from "vitest";

import { resolveAction, resolveField, type Claim } from "./resolve";

let n = 0;
const claim = (over: Partial<Claim> & Pick<Claim, "value" | "occurredAt">): Claim => ({
  id: `c${++n}`,
  field: "due",
  speakerRole: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  channel: "meeting",
  ...over,
});
const at = (day: string, time = "10:00") => new Date(`2025-09-${day}T${time}:00+09:00`);

describe("핵심 시나리오 (TRUTH_RULES 2장 표: 9/22 → 9/24)", () => {
  // 9/22 회의: 나 "금요일까지 제안서 보내드릴게요"
  const c922 = claim({ id: "c922", value: "2025-09-26", occurredAt: at("22") });
  // 9/23 내 메모: "제안서 월요일에 보내도 될 듯"
  const c923 = claim({ id: "c923", value: "2025-09-29", occurredAt: at("23", "21:00"), certainty: "tentative", audience: "private", channel: "note" });
  // 9/24 Slack: 김대표 "월요일에 받아도 괜찮아요"
  const c924 = claim({ id: "c924", value: "2025-09-29", occurredAt: at("24", "14:30"), speakerRole: "counterpart", channel: "message" });

  it("9/22: 기한 금요일", () => {
    expect(resolveField("due", [c922])).toMatchObject({ value: "2025-09-26", winningClaimId: "c922", needsConfirmation: false });
  });

  it("9/23: 내 메모는 금요일을 바꾸지 못하고 변경 가능성만 남긴다 (규칙 1 · 2)", () => {
    const r = resolveField("due", [c922, c923]);
    expect(r.value).toBe("2025-09-26");
    expect(r.rules).toContain(2);
    expect(r.risks).toEqual([{ kind: "tentative_change", claimId: "c923", value: "2025-09-29" }]);
  });

  it("9/24: 요청한 쪽이 연장을 수락해 월요일로 갱신 (규칙 0 + 4)", () => {
    const r = resolveField("due", [c922, c923, c924]);
    expect(r).toMatchObject({ value: "2025-09-29", winningClaimId: "c924", superseded: ["c922"], needsConfirmation: false });
    expect(r.rules).toEqual([0, 4]);
    expect(r.reason).toContain("결정권");
  });

  it("입력 순서와 상관없이 발언 시점으로 판정한다 (규칙 4)", () => {
    expect(resolveField("due", [c924, c922, c923]).value).toBe("2025-09-29");
  });
});

describe("규칙 0: 결정권", () => {
  it("내가 혼자 기한을 늦추면 반영하지 않고 위험 신호로 남긴다", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("22") });
    const later = claim({ value: "2025-09-30", occurredAt: at("24") });
    const r = resolveField("due", [first, later]);
    expect(r.value).toBe("2025-09-26");
    expect(r.risks).toEqual([{ kind: "unauthorized_change", claimId: later.id, value: "2025-09-30" }]);
  });

  it("내가 기한을 당기는 건 혼자서도 된다", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("22") });
    const earlier = claim({ value: "2025-09-25", occurredAt: at("23") });
    expect(resolveField("due", [first, earlier]).value).toBe("2025-09-25");
  });

  it("담당 변경은 넘기는 쪽과 받는 쪽이 모두 말해야 확정", () => {
    const mine = claim({ field: "owner", value: "me", occurredAt: at("22") });
    const handoff = claim({ field: "owner", value: "태오", occurredAt: at("23") });
    const oneSide = resolveField("owner", [mine, handoff]);
    expect(oneSide).toMatchObject({ value: "me", needsConfirmation: true, pending: [handoff.id] });

    const accepted = claim({ field: "owner", value: "태오", occurredAt: at("24"), speakerRole: "counterpart" });
    expect(resolveField("owner", [mine, handoff, accepted]).value).toBe("태오");
  });

  it("완료는 전달 확인으로, 취소는 요청한 쪽만", () => {
    const open = claim({ field: "status", value: "open", occurredAt: at("22") });
    const done = claim({ field: "status", value: "done", occurredAt: at("25") });
    expect(resolveField("status", [open, done]).value).toBe("done");

    const myDrop = claim({ field: "status", value: "dropped", occurredAt: at("25") });
    expect(resolveField("status", [open, myDrop])).toMatchObject({ value: "open", needsConfirmation: true });
    const theirDrop = claim({ field: "status", value: "dropped", occurredAt: at("25"), speakerRole: "counterpart" });
    expect(resolveField("status", [open, theirDrop]).value).toBe("dropped");
  });

  it("제3자의 변경은 확인이 필요하다", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("22") });
    const third = claim({ value: "2025-09-25", occurredAt: at("23"), speakerRole: "third_party" });
    expect(resolveField("due", [first, third])).toMatchObject({ value: "2025-09-26", needsConfirmation: true, pending: [third.id] });
  });
});

describe("규칙 1: 공유된 약속이 개인 메모를 이긴다", () => {
  it("메모와 다르면 위험 신호", () => {
    const shared = claim({ value: "2025-09-26", occurredAt: at("22") });
    const memo = claim({ value: "2025-09-29", occurredAt: at("23"), audience: "private", channel: "note" });
    const r = resolveField("due", [shared, memo]);
    expect(r.value).toBe("2025-09-26");
    expect(r.risks).toEqual([{ kind: "private_differs", claimId: memo.id, value: "2025-09-29" }]);
  });

  it("공유된 발언이 없으면 내 메모를 쓴다 (혼자 적은 할 일)", () => {
    const memo = claim({ value: "2025-09-29", occurredAt: at("23"), audience: "private", channel: "note" });
    expect(resolveField("due", [memo])).toMatchObject({ value: "2025-09-29", rules: [1], needsConfirmation: false });
  });
});

describe("규칙 2 · 3: 확정 · 직접 발언 우선", () => {
  it("추정만 있으면 보여주되 확인을 받는다", () => {
    const guess = claim({ value: "2025-09-29", occurredAt: at("23"), certainty: "tentative" });
    expect(resolveField("due", [guess])).toMatchObject({ value: "2025-09-29", rules: [2], needsConfirmation: true });
  });

  it("전해 들은 변경은 반영하지 않고 확인 목록으로", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("22") });
    const hearsay = claim({ value: "2025-09-29", occurredAt: at("23"), directness: "reported", speakerRole: "third_party" });
    const r = resolveField("due", [first, hearsay]);
    expect(r).toMatchObject({ value: "2025-09-26", needsConfirmation: true, pending: [hearsay.id] });
    expect(r.rules).toContain(3);
  });

  it("본인 발언이 들어오면 확정한다", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("22") });
    const hearsay = claim({ value: "2025-09-29", occurredAt: at("23"), directness: "reported", speakerRole: "third_party" });
    const direct = claim({ value: "2025-09-29", occurredAt: at("24"), speakerRole: "counterpart" });
    expect(resolveField("due", [first, hearsay, direct])).toMatchObject({ value: "2025-09-29", needsConfirmation: false });
  });
});

describe("규칙 5 · 6: 같은 시점", () => {
  it("같은 시점이면 서면 채널이 이긴다", () => {
    const meeting = claim({ value: "2025-09-26", occurredAt: at("22"), channel: "meeting" });
    const email = claim({ value: "2025-09-25", occurredAt: at("22"), channel: "email" });
    const r = resolveField("due", [meeting, email]);
    expect(r.value).toBe("2025-09-25");
    expect(r.rules).toEqual([5]);
  });

  it("채널까지 같으면 사용자에게 묻는다", () => {
    const a = claim({ value: "2025-09-26", occurredAt: at("22") });
    const b = claim({ value: "2025-09-25", occurredAt: at("22") });
    expect(resolveField("due", [a, b])).toMatchObject({ needsConfirmation: true, pending: [a.id, b.id], rules: [6] });
  });
});

describe("resolveAction", () => {
  it("필드마다 따로 판정하고, 근거가 없는 필드는 비운다", () => {
    const state = resolveAction([
      claim({ field: "scope", value: "제안서 초안", occurredAt: at("22") }),
      claim({ field: "due", value: "2025-09-26", occurredAt: at("22") }),
    ]);
    expect(state.scope.value).toBe("제안서 초안");
    expect(state.due.value).toBe("2025-09-26");
    expect(state.owner).toMatchObject({ value: null, reason: "근거 없음" });
  });
});

describe("사용자가 직접 고친 값", () => {
  it("그 시점까지의 발언보다 우선하고, 이유를 남긴다", () => {
    const promise = claim({ value: "2025-09-26", occurredAt: at("22") });
    const edit = claim({ value: "2025-10-01", occurredAt: at("23"), origin: "user", channel: "note" });
    expect(resolveField("due", [promise, edit])).toMatchObject({ value: "2025-10-01", winningClaimId: edit.id, reason: "사용자가 직접 정함", superseded: [promise.id] });
  });

  it("그 뒤 요청자의 유효한 변경은 다시 반영된다", () => {
    const edit = claim({ value: "2025-10-01", occurredAt: at("23"), origin: "user", channel: "note" });
    const extension = claim({ value: "2025-10-03", occurredAt: at("24"), speakerRole: "counterpart" });
    expect(resolveField("due", [edit, extension]).value).toBe("2025-10-03");
  });

  it("사용자가 지운(취소한) 일은 상대 확인 없이도 취소된다", () => {
    const open = claim({ field: "status", value: "open", occurredAt: at("22") });
    const deleted = claim({ field: "status", value: "dropped", occurredAt: at("23"), origin: "user" });
    expect(resolveField("status", [open, deleted])).toMatchObject({ value: "dropped", needsConfirmation: false });
  });

  it("사용자가 확인한 뒤에는 그 전의 확인 대기를 다시 묻지 않는다", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("22") });
    const hearsay = claim({ value: "2025-09-29", occurredAt: at("23"), directness: "reported", speakerRole: "third_party" });
    expect(resolveField("due", [first, hearsay]).needsConfirmation).toBe(true);
    const confirmed = claim({ value: "2025-09-26", occurredAt: at("23", "18:00"), origin: "user" });
    expect(resolveField("due", [first, hearsay, confirmed])).toMatchObject({ value: "2025-09-26", needsConfirmation: false, pending: [] });
  });
});

describe("할 일 도구에서 사용자가 고친 값 (origin: tracker)", () => {
  it("내가 기한을 늦춰도 반영된다: 대화 속 약속이었다면 규칙 0으로 막혔을 변경", () => {
    const assigned = claim({ value: "2025-09-26", occurredAt: at("22"), speakerRole: "counterpart", channel: "task" });
    const selfExtension = claim({ value: "2025-09-30", occurredAt: at("23"), channel: "task" });
    expect(resolveField("due", [assigned, selfExtension])).toMatchObject({ value: "2025-09-26", risks: [{ kind: "unauthorized_change" }] });

    const tracked = { ...selfExtension, origin: "tracker" as const };
    expect(resolveField("due", [assigned, tracked])).toMatchObject({ value: "2025-09-30", reason: "사용자가 할 일 도구에서 정함", risks: [] });
  });

  it("내가 고친 제목은 확인 없이 반영된다", () => {
    const first = claim({ field: "scope", value: "UI 시안 공유", occurredAt: at("22"), speakerRole: "counterpart", channel: "task" });
    const renamed = claim({ field: "scope", value: "UI 레이아웃 시안 공유", occurredAt: at("23"), channel: "task", origin: "tracker" });
    expect(resolveField("scope", [first, renamed])).toMatchObject({ value: "UI 레이아웃 시안 공유", needsConfirmation: false });
  });

  it("다른 사람이 담당을 바꾸면 여전히 확인을 받는다 (넘기는 쪽 · 받는 쪽)", () => {
    const mine = claim({ field: "owner", value: "me", occurredAt: at("22"), speakerRole: "counterpart", channel: "task" });
    const reassigned = claim({ field: "owner", value: "other", occurredAt: at("23"), speakerRole: "counterpart", channel: "task" });
    expect(resolveField("owner", [mine, reassigned])).toMatchObject({ value: "me", needsConfirmation: true, pending: [reassigned.id] });
  });
});
