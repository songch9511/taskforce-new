import { describe, expect, it } from "vitest";

import type { Claim } from "@/lib/pipeline/resolve";

import { changeEvents, projectAction, withClearedConfirmation } from "./project";

let n = 0;
const claim = (field: Claim["field"], value: string | null, day: string, over: Partial<Claim> = {}): Claim => ({
  id: `c${++n}`,
  field,
  value,
  occurredAt: new Date(`2025-09-${day}T10:00:00+09:00`),
  speakerRole: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  channel: "meeting",
  ...over,
});

const created = [claim("scope", "김대표에게 제안서 발송", "22"), claim("owner", "me", "22"), claim("status", "open", "22"), claim("due", "2025-09-26", "22")];

describe("projectAction", () => {
  it("판정 결과를 actions 행 값으로 만든다", () => {
    const p = projectAction("제목", created);
    expect(p).toMatchObject({
      title: "김대표에게 제안서 발송",
      owner: "me",
      due_date: "2025-09-26",
      due_at: "2025-09-26T23:59:59+09:00",
      status: "open",
      needs_confirmation: false,
      confirm_reasons: [],
    });
    expect(p.resolution.due.reason).toBe("처음 합의된 값");
  });

  it("담당이 불확실하거나 필드 확인이 필요하면 이유와 함께 확인 요청", () => {
    const p = projectAction("제목", [
      claim("owner", "unknown", "22"),
      claim("due", "2025-09-26", "22"),
      claim("due", "2025-09-29", "23", { directness: "reported", speakerRole: "third_party" }),
    ], ["판정 확인: NOT_MY_ACTION"]);
    expect(p.needs_confirmation).toBe(true);
    expect(p.confirm_reasons).toEqual(["판정 확인: NOT_MY_ACTION", "담당 확인", "기한 확인"]);
    expect(p.title).toBe("제목");
  });

  it("다른 사람 이름으로 넘어간 담당은 other", () => {
    expect(projectAction("t", [claim("owner", "태오", "22", { origin: "user" })]).owner).toBe("other");
  });
});

describe("changeEvents", () => {
  const before = projectAction("t", created);

  it("처음이면 created", () => {
    expect(changeEvents(null, before, "created").map((e) => e.type)).toEqual(["created"]);
    // 만들 때 확인 요청이었는지 남긴다 (지표 1: 자동 반영 / 확인 요청 구분)
    expect(changeEvents(null, before, "created")[0].after).toHaveProperty("needs_confirmation", before.needs_confirmation);
  });

  it("요청자의 연장은 규칙과 함께 due_changed", () => {
    const after = projectAction("t", [...created, claim("due", "2025-09-29", "24", { speakerRole: "counterpart", channel: "message" })]);
    expect(changeEvents(before, after, "updated")).toEqual([
      { type: "due_changed", before: { due: "2025-09-26" }, after: { due: "2025-09-29" }, rule: "rule0+rule4" },
    ]);
  });

  it("완료 · 취소 · 다시 열림", () => {
    const done = projectAction("t", [...created, claim("status", "done", "25")]);
    expect(changeEvents(before, done, "completed").map((e) => e.type)).toEqual(["completed"]);
    const reopened = projectAction("t", [...created, claim("status", "done", "25"), claim("status", "open", "26", { origin: "user" })]);
    expect(changeEvents(done, reopened, "updated").map((e) => [e.type, e.rule])).toEqual([["reopened", "user"]]);
  });

  it("바뀐 게 없는 반복은 merged, 아무 일 없는 갱신은 이벤트 없음", () => {
    expect(changeEvents(before, before, "duplicate").map((e) => e.type)).toEqual(["merged"]);
    expect(changeEvents(before, before, "updated")).toEqual([]);
  });
});

describe("withClearedConfirmation: AI가 확인 요청을 풀면 이벤트에 전후를 남긴다", () => {
  // 요청자의 추정 발언뿐이라 내용 · 담당 · 상태 확인이 남은 Action
  const tentative = (day: string) => ({ speakerRole: "counterpart" as const, certainty: "tentative" as const, day });
  const asked = [claim("scope", "견적서 발송", "22", tentative("22")), claim("owner", "me", "22", tentative("22")), claim("status", "open", "22", tentative("22"))];
  const acceptance = [claim("scope", "견적서 발송", "23"), claim("owner", "me", "23"), claim("status", "open", "23")];
  const stored = ["판정 확인: NOT_MY_ACTION"];

  it("사용자의 확정 약속으로 이유가 풀리면 merged 이벤트에 needs_confirmation · confirm_reasons 전후를 싣는다", () => {
    const beforeState = projectAction("t", asked, stored);
    const afterState = projectAction("t", [...asked, ...acceptance], []);
    expect(beforeState.confirm_reasons).toEqual(["판정 확인: NOT_MY_ACTION", "내용 확인", "담당 확인", "상태 확인"]);
    expect(afterState.confirm_reasons).toEqual([]);
    // 바뀐 필드가 없는 반복: 이미 있는 merged 이벤트에 싣는다 (이벤트가 둘이 되지 않는다)
    const events = withClearedConfirmation(changeEvents(beforeState, afterState, "duplicate"), beforeState, afterState);
    expect(events).toEqual([
      {
        type: "merged",
        before: { needs_confirmation: true, confirm_reasons: ["판정 확인: NOT_MY_ACTION", "내용 확인", "담당 확인", "상태 확인"] },
        after: { needs_confirmation: false, confirm_reasons: [] },
        rule: null,
      },
    ]);
  });

  it("값이 바뀐 이벤트가 있으면 그 첫 이벤트에 전후를 얹는다 (이력에 줄이 늘지 않고, 원래 값 키는 그대로). 일부만 풀려도 남긴다", () => {
    const beforeState = projectAction("t", asked, stored);
    const afterState = projectAction("t", [...asked, ...acceptance], ["병합 확인 (55%)"]);
    const changed: ReturnType<typeof changeEvents> = [
      { type: "due_changed", before: { due: null }, after: { due: "2025-09-26" }, rule: "rule0+rule4" },
      { type: "completed", before: { status: "open" }, after: { status: "done" }, rule: null },
    ];
    const events = withClearedConfirmation(changed, beforeState, afterState);
    expect(events.map((e) => e.type)).toEqual(["due_changed", "completed"]);
    expect(events[0]).toEqual({
      type: "due_changed",
      before: { due: null, needs_confirmation: true, confirm_reasons: ["판정 확인: NOT_MY_ACTION", "내용 확인", "담당 확인", "상태 확인"] },
      after: { due: "2025-09-26", needs_confirmation: true, confirm_reasons: ["병합 확인 (55%)"] },
      rule: "rule0+rule4",
    });
    // 두 번째 이벤트는 건드리지 않는다
    expect(events[1]).toEqual(changed[1]);
    // 이벤트가 하나도 없는 갱신(바뀐 값 없음)만 merged를 따로 만든다
    expect(withClearedConfirmation([], beforeState, afterState).map((e) => e.type)).toEqual(["merged"]);
  });

  it("풀린 이유가 없으면(이유가 그대로거나 늘기만 함) 이벤트를 바꾸지 않는다", () => {
    const beforeState = projectAction("t", asked, stored);
    const same = withClearedConfirmation(changeEvents(beforeState, beforeState, "duplicate"), beforeState, beforeState);
    expect(same).toEqual([{ type: "merged", before: null, after: null, rule: null }]);
    const clean = projectAction("t", created);
    const worse = projectAction("t", created, ["병합 확인 (55%)"]);
    expect(withClearedConfirmation([], clean, worse)).toEqual([]);
  });
});
