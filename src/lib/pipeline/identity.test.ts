import { describe, expect, it } from "vitest";

import { describeIdentity, findNameVariants, isUser, userNameForms, userPosition, type Participants, type UserIdentity } from "./identity";

const me: UserIdentity = { name: "송청혁", aliases: ["Daniel"], emails: ["me@taskforcelabs.dev"] };

describe("userNameForms", () => {
  it("이름 · 별칭 · 성을 뺀 이름", () => {
    expect(userNameForms(me)).toEqual(["송청혁", "청혁", "daniel"]);
  });
});

describe("isUser", () => {
  it("이메일은 대소문자를 무시하고, 이름은 별칭까지 본다", () => {
    expect(isUser({ email: "ME@taskforcelabs.dev" }, me)).toBe(true);
    expect(isUser({ name: "청혁" }, me)).toBe(true);
    expect(isUser({ name: "daniel" }, me)).toBe(true);
    expect(isUser({ name: "준서", email: "j@x.com" }, me)).toBe(false);
    expect(isUser(undefined, me)).toBe(false);
  });
});

describe("userPosition", () => {
  const other = { name: "김대표", email: "ceo@x.com" };
  it.each<[Participants, string]>([
    [{ from: { email: "me@taskforcelabs.dev" }, to: [other] }, "sender"],
    [{ from: other, to: [{ email: "me@taskforcelabs.dev" }] }, "sole_recipient"],
    [{ from: other, to: [{ email: "me@taskforcelabs.dev" }, { email: "b@x.com" }] }, "recipient"],
    [{ from: other, to: [{ email: "b@x.com" }], cc: [{ email: "me@taskforcelabs.dev" }] }, "cc_only"],
    [{ attendees: [other, { name: "청혁" }] }, "attendee"],
    [{ attendees: [other] }, "unknown"],
  ])("%# → %s", (participants, expected) => {
    expect(userPosition(me, participants)).toBe(expected);
  });

  it("관련자 정보가 없으면 unknown", () => {
    expect(userPosition(me, undefined)).toBe("unknown");
  });
});

describe("findNameVariants", () => {
  const text = "- [ ] 청영님 - UX 기획 진행\n- [ ] 청혁님 - 리뷰\n- [ ] 준서님 - 툴 개발\n태오: 네\n대표님 요청";

  it("사용자 이름과 한 글자만 다른 이름을 찾는다", () => {
    expect(findNameVariants(text, me)).toEqual(["청영"]);
  });

  it("관련자 목록에 있는 다른 사람 이름은 오타로 보지 않는다", () => {
    expect(findNameVariants(text, me, { attendees: [{ name: "청영" }] })).toEqual([]);
  });

  it("별칭에 넣으면 더 이상 후보가 아니다", () => {
    expect(findNameVariants(text, { ...me, aliases: ["청영"] })).toEqual([]);
  });

  it("두 글자 이상 다르거나 길이가 다르면 후보가 아니다", () => {
    expect(findNameVariants("태오님, 박하은님, 대표님", { name: "도윤", aliases: [], emails: [] })).toEqual([]);
  });
});

describe("describeIdentity", () => {
  it("관련자와 사용자 위치, 이름 주의를 적는다", () => {
    const text = describeIdentity(me, { from: { name: "김대표", email: "ceo@x.com" }, cc: [{ email: "me@taskforcelabs.dev" }] }, ["청영"]);
    expect(text).toContain("사용자의 다른 이름: Daniel");
    expect(text).toContain("보낸 사람: 김대표 <ceo@x.com>");
    expect(text).toContain("사용자의 위치: 참조로만 받음");
    expect(text).toContain("'청영'");
  });
});
