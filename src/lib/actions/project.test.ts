import { describe, expect, it } from "vitest";

import type { Claim } from "@/lib/pipeline/resolve";

import { changeEvents, projectAction } from "./project";

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
