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
const disputed = (c: Claim): Claim => ({ ...c, state: "disputed" });
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

  it("같은 시점의 내 일방적인 기한 연장은 채널이 높아도 반영하지 않는다", () => {
    const first = claim({ value: "2025-09-26", occurredAt: at("21") });
    const extension = claim({ value: "2025-09-30", occurredAt: at("22"), channel: "email" });
    const r = resolveField("due", [first, extension]);

    expect(r).toMatchObject({ value: "2025-09-26", winningClaimId: first.id, risks: [{ kind: "unauthorized_change", claimId: extension.id, value: extension.value }] });
  });

  it.each(["user", "tracker"] as const)("같은 시점의 %s 편집이 원문 발언보다 우선한다", (origin) => {
    const source = claim({ value: "2025-09-29", occurredAt: at("22"), speakerRole: "counterpart", channel: "email" });
    const edit = claim({ value: "2025-09-26", occurredAt: at("22"), origin, channel: "note" });
    const r = resolveField("due", [source, edit]);

    expect(r).toMatchObject({ value: edit.value, winningClaimId: edit.id, reason: origin === "tracker" ? "사용자가 할 일 도구에서 정함" : "사용자가 직접 정함" });
  });

  it.each(["user", "tracker"] as const)("같은 값을 재확인한 %s Claim이 같은 시점의 완료 발언을 막는다 (입력 순서 무관)", (origin) => {
    const open = claim({ field: "status", value: "open", occurredAt: at("21") });
    const reaffirmation = claim({ field: "status", value: "open", occurredAt: at("22"), origin, channel: "note" });
    const completion = claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "counterpart", channel: "email" });
    const expected = {
      value: "open",
      winningClaimId: reaffirmation.id,
      needsConfirmation: false,
      pending: [],
      reason: origin === "tracker" ? "사용자가 할 일 도구에서 정함" : "사용자가 직접 정함",
    };

    expect(resolveField("status", [open, reaffirmation, completion])).toMatchObject(expected);
    expect(resolveField("status", [open, completion, reaffirmation])).toMatchObject(expected);
  });

  it.each([[false], [true]])("제3자의 높은 채널이 취소를 확정하지 않는다 (입력 역순: %s)", (reverse) => {
    const thirdParty = claim({ field: "status", value: "dropped", occurredAt: at("22"), speakerRole: "third_party", channel: "email" });
    const counterpart = claim({ field: "status", value: "open", occurredAt: at("22"), speakerRole: "counterpart", channel: "meeting" });
    const r = resolveField("status", reverse ? [counterpart, thirdParty] : [thirdParty, counterpart]);

    expect(r).toMatchObject({ value: "open", winningClaimId: counterpart.id, needsConfirmation: true, pending: [thirdParty.id], rules: [0] });
  });

  it.each([[false], [true]])("제3자의 완료 발언이 같은 시점의 요청자 취소를 덮지 않는다 (입력 역순: %s)", (reverse) => {
    const thirdParty = claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "third_party", channel: "email" });
    const counterpart = claim({ field: "status", value: "dropped", occurredAt: at("22"), speakerRole: "counterpart", channel: "meeting" });
    const r = resolveField("status", reverse ? [counterpart, thirdParty] : [thirdParty, counterpart]);

    expect(r).toMatchObject({ value: "dropped", winningClaimId: counterpart.id, needsConfirmation: true, pending: [thirdParty.id], rules: [0] });
  });

  it("권한이 없는 초기 완료 Claim은 확인 전 Action을 완료하지 않는다", () => {
    const thirdParty = claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "third_party", channel: "email" });
    expect(resolveField("status", [thirdParty])).toMatchObject({
      value: null,
      winningClaimId: null,
      needsConfirmation: true,
      pending: [thirdParty.id],
      rules: [0],
    });
  });

  it("내가 혼자 취소한 초기 Claim은 확인 전 Action을 닫지 않는다", () => {
    const myDrop = claim({ field: "status", value: "dropped", occurredAt: at("22"), speakerRole: "me" });
    expect(resolveField("status", [myDrop])).toMatchObject({
      value: null,
      winningClaimId: null,
      needsConfirmation: true,
      pending: [myDrop.id],
      rules: [0],
    });
  });

  it.each([[false], [true]])("초기 종료 Claim이 모두 권한 없으면 닫힌 상태를 쓰지 않는다 (입력 역순: %s)", (reverse) => {
    const done = claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "third_party", channel: "email" });
    const dropped = claim({ field: "status", value: "dropped", occurredAt: at("22"), speakerRole: "third_party", channel: "meeting" });
    const r = resolveField("status", reverse ? [dropped, done] : [done, dropped]);

    expect(r).toMatchObject({ value: null, winningClaimId: null, needsConfirmation: true, rules: [0] });
    expect(new Set(r.pending)).toEqual(new Set([done.id, dropped.id]));
  });

  it("초기 요청자 완료는 권한이 있어 그대로 적용한다", () => {
    const done = claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "counterpart" });
    expect(resolveField("status", [done])).toMatchObject({ value: "done", winningClaimId: done.id, needsConfirmation: false });
  });

  it.each(["done", "dropped"] as const)("불명확한 발화자의 %s 발언이 같은 시점의 기존 상태를 바꾸지 않는다", (value) => {
    const mine = claim({ field: "status", value: "open", occurredAt: at("22"), channel: "meeting" });
    const unknown = claim({ field: "status", value, occurredAt: at("22"), speakerRole: "unknown", channel: "email" });
    const expected = { value: "open", winningClaimId: mine.id, needsConfirmation: true, pending: [unknown.id], rules: [0] };

    expect(resolveField("status", [mine, unknown])).toMatchObject(expected);
    expect(resolveField("status", [unknown, mine])).toMatchObject(expected);
  });
});

describe("speaker_role이 unknown인 Claim", () => {
  const unresolved = (value: string, occurredAt: Date) =>
    claim({ field: "status", value, occurredAt, speakerRole: "unknown", channel: "email" });

  it("초기 값은 보여주되 확인을 요구한다", () => {
    const unknown = unresolved("done", at("22"));
    expect(resolveField("status", [unknown])).toMatchObject({
      value: "done",
      winningClaimId: unknown.id,
      needsConfirmation: true,
      pending: [unknown.id],
      rules: [0],
    });
  });

  it("기존 값을 나중 발언으로 바꾸지 않는다", () => {
    const open = claim({ field: "status", value: "open", occurredAt: at("21") });
    const unknown = unresolved("done", at("22"));
    expect(resolveField("status", [open, unknown])).toMatchObject({
      value: "open",
      winningClaimId: open.id,
      needsConfirmation: true,
      pending: [unknown.id],
      rules: [0],
    });
  });

  it("나중의 확정된 같은 값은 화자 불명 Claim의 확인을 대신한다", () => {
    const unknown = unresolved("done", at("22"));
    const known = claim({ field: "status", value: "done", occurredAt: at("23"), speakerRole: "counterpart" });
    expect(resolveField("status", [unknown, known])).toMatchObject({ value: "done", needsConfirmation: false, pending: [] });
  });

  it.each(["user", "tracker"] as const)("나중의 %s 확인이 이전 불확실성을 푼다", (origin) => {
    const unknown = unresolved("done", at("22"));
    const confirmation = claim({ field: "status", value: "done", occurredAt: at("23"), origin });
    expect(resolveField("status", [unknown, confirmation])).toMatchObject({ value: "done", needsConfirmation: false, pending: [] });
  });
});

describe("state=disputed인 source Claim", () => {
  it("기존 근거가 없으면 후보 값을 보여주되 확인을 요구한다", () => {
    const candidate = disputed(claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "counterpart" }));
    expect(resolveField("status", [candidate])).toMatchObject({
      value: "done",
      winningClaimId: candidate.id,
      needsConfirmation: true,
      pending: [candidate.id],
      rules: [0],
    });
  });

  it.each([
    ["due", "2026-10-09", "2026-10-12"],
    ["status", "open", "done"],
    ["status", "open", "dropped"],
  ] as const)("%s disputed %s는 기존 값을 바꾸지 않는다", (field, existing, proposed) => {
    const known = claim({ field, value: existing, occurredAt: at("21"), speakerRole: "counterpart" });
    const candidate = disputed(
      claim({ field, value: proposed, occurredAt: at("22"), speakerRole: "counterpart", certainty: "firm", directness: "first_hand" }),
    );
    const r = resolveField(field, [known, candidate]);

    expect(candidate).toMatchObject({ certainty: "firm", directness: "first_hand", speakerRole: "counterpart" });
    expect(r).toMatchObject({
      value: existing,
      winningClaimId: known.id,
      needsConfirmation: true,
      pending: [candidate.id],
      rules: [0],
    });
  });

  it("나중의 확정된 같은 값은 disputed source Claim을 확인한다", () => {
    const candidate = disputed(claim({ field: "status", value: "done", occurredAt: at("22"), speakerRole: "counterpart" }));
    const known = claim({ field: "status", value: "done", occurredAt: at("23"), speakerRole: "counterpart" });
    expect(resolveField("status", [candidate, known])).toMatchObject({ value: "done", needsConfirmation: false, pending: [] });
  });

  it.each(["user", "tracker"] as const)("명시적인 %s Claim은 disputed 표시에 막히지 않는다", (origin) => {
    const known = claim({ field: "status", value: "open", occurredAt: at("21") });
    const edit = disputed(claim({ field: "status", value: "dropped", occurredAt: at("22"), origin }));
    expect(resolveField("status", [known, edit])).toMatchObject({ value: "dropped", winningClaimId: edit.id, needsConfirmation: false });
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

describe("실행 결과 Claim (origin: execution, field: artifact, docs/EXECUTION.md 9장)", () => {
  // 초안 receipt: 값은 산출물 id, 인용은 "초안 저장: …"
  const receipt = (occurredAt: Date) =>
    claim({ field: "artifact", value: "artifact-1", occurredAt, origin: "execution", audience: "private", channel: "note" });
  const open = [
    claim({ field: "scope", value: "제안서 보내기", occurredAt: at("22") }),
    claim({ field: "due", value: "2025-09-26", occurredAt: at("22") }),
    claim({ field: "owner", value: "me", occurredAt: at("22") }),
    claim({ field: "status", value: "open", occurredAt: at("22") }),
  ];

  it("어느 필드도 바꾸지 않는다: 초안은 완료가 아니다 (A38)", () => {
    expect(resolveAction([...open, receipt(at("24"))])).toEqual(resolveAction(open));
    expect(resolveAction([...open, receipt(at("24"))]).status.value).toBe("open");
  });

  it("사용자가 끝낸 할 일을 다시 열지 않는다, 그 뒤에 와도 (A57)", () => {
    const done = [...open, claim({ field: "status", value: "done", occurredAt: at("23"), origin: "user", channel: "note" })];
    const r = resolveAction([...done, receipt(at("25"))]);
    expect(r).toEqual(resolveAction(done));
    expect(r.status).toMatchObject({ value: "done", reason: "사용자가 직접 정함" });
  });

  it("확인 대기 · 위험 신호를 만들거나 풀지 않는다 (사용자 Claim이 아니다, A55)", () => {
    const pending = [...open, claim({ field: "due", value: "2025-09-29", occurredAt: at("23"), directness: "reported", speakerRole: "third_party" })];
    const before = resolveAction(pending);
    expect(before.due.needsConfirmation).toBe(true);
    expect(resolveAction([...pending, receipt(at("24"))])).toEqual(before);
  });

  it("artifact Claim만 있으면 모든 필드가 근거 없음이다", () => {
    const r = resolveAction([receipt(at("24"))]);
    for (const field of ["due", "scope", "owner", "status"] as const) expect(r[field]).toMatchObject({ value: null, winningClaimId: null, reason: "근거 없음" });
  });
});
