import { describe, expect, it } from "vitest";

import {
  addressedToUser,
  describeIdentity,
  findNameVariants,
  isUser,
  quoteSpeaker,
  speakerRole,
  userNameForms,
  userPosition,
  type Participants,
  type UserIdentity,
} from "./identity";

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

describe("quoteSpeaker", () => {
  const dm = ["[DM · 박지훈]", "박지훈: 아 경쟁사 건은 안 하셔도 돼요! 대표님이 이미 받으셨대요", "송청혁: 넵 알겠습니다"].join("\n");

  it("인용 줄의 이름표가 관련자나 사용자면 그 이름을 돌려준다", () => {
    expect(quoteSpeaker(dm, "경쟁사 건은 안 하셔도 돼요", me, { attendees: [{ name: "박지훈" }, { name: "송청혁" }] })).toBe("박지훈");
    expect(quoteSpeaker(dm, "넵 알겠습니다", me)).toBe("송청혁");
  });

  it("관련자 목록이 없어도 원문에서 화자 표로 두 번 이상 쓰인 이름은 믿는다", () => {
    const kakao = ["[신예린] 카피 3개 더 가능하실까요?", "[나] 이번 주는 어렵겠어요", "[신예린] 넵 알겠어요"].join("\n");
    expect(quoteSpeaker(kakao, "카피 3개 더 가능하실까요", me)).toBe("신예린");
  });

  it("머리글 · 시각 · 한 번만 나온 이름표는 화자로 읽지 않는다", () => {
    expect(quoteSpeaker("제목: 제안서 일정\n금요일까지 보내드릴게요", "제안서 일정", me)).toBeNull();
    expect(quoteSpeaker("10:30 회의 시작\n11:00 끝", "회의 시작", me)).toBeNull();
    expect(quoteSpeaker(dm, "대표님이 이미 받으셨대요", me)).toBeNull();
    expect(quoteSpeaker(dm, "없는 문장", me)).toBeNull();
  });

  it("같은 구절이 다른 사람의 줄에도 있거나 ...로 두 사람의 줄을 이으면 모른다", () => {
    const chat = ["박지훈: 넵 확인했어요", "송청혁: 넵 월요일에 드릴게요"].join("\n");
    const people = { attendees: [{ name: "박지훈" }, { name: "송청혁" }] };
    expect(quoteSpeaker(chat, "넵", me, people)).toBeNull();
    expect(quoteSpeaker(chat, "확인했어요 ... 월요일에 드릴게요", me, people)).toBeNull();
    expect(quoteSpeaker(chat, "월요일에 드릴게요", me, people)).toBe("송청혁");
  });

  it("두 번 나와도 머리글 · 메일 주소 · 글머리 이름표는 화자가 아니다", () => {
    const memo = ["참고: 장소는 역삼", "참고: 주차 불가", "m@x.com: 금요일까지 보내드릴게요", "m@x.com: 네"].join("\n");
    expect(quoteSpeaker(memo, "장소는 역삼", me)).toBeNull();
    expect(quoteSpeaker(memo, "금요일까지 보내드릴게요", me)).toBeNull();
  });

  it("한 조각이 두 사람의 줄에 걸치면 모른다", () => {
    const chat = ["박지훈: 초안 부탁드려요", "송청혁: 넵 할게요"].join("\n");
    expect(quoteSpeaker(chat, "부탁드려요 송청혁 넵 할게요", me, { attendees: [{ name: "박지훈" }] })).toBeNull();
  });

  it("이름표 없이 이어지는 줄은 메시지 첫 줄의 화자다", () => {
    const multi = ["[DM · 박지훈]", "박지훈: 지호님", "금요일까지 초안 부탁드려요", "송청혁: 넵"].join("\n");
    expect(quoteSpeaker(multi, "금요일까지 초안 부탁드려요", me, { attendees: [{ name: "박지훈" }] })).toBe("박지훈");
    expect(quoteSpeaker("[DM · 박지훈]\n금요일까지 초안 부탁드려요", "초안 부탁드려요", me)).toBeNull();
  });
});

describe("addressedToUser", () => {
  it("인용 줄에 @사용자 이름(별칭 · 성을 뺀 이름 포함)이 있으면 참", () => {
    const text = "최유나: @청혁 이거 금요일까지 될까요?\n최유나: @Daniel 이것도요";
    expect(addressedToUser(text, "이거 금요일까지 될까요", me)).toBe(true);
    expect(addressedToUser(text, "이것도요", me)).toBe(true);
    expect(addressedToUser("최유나: @박지훈 이거 될까요?", "이거 될까요", me)).toBe(false);
    expect(addressedToUser("최유나: 청혁님 이거 될까요?", "이거 될까요", me)).toBe(false);
  });

  it("다른 이름의 앞부분 · 메일 주소는 언급이 아니고, 님 · 씨는 붙어도 된다", () => {
    expect(addressedToUser("최유나: @청혁이형 이거 될까요?", "이거 될까요", me)).toBe(false);
    expect(addressedToUser("최유나: help@daniel.kr 로 보내 주세요", "보내 주세요", me)).toBe(false);
    expect(addressedToUser("최유나: @청혁님 이거 될까요?", "이거 될까요", me)).toBe(true);
    expect(addressedToUser("Alex: @Daniel, can you?", "can you", me)).toBe(true);
  });

  it("여러 줄 메시지면 첫 줄의 언급도 본다", () => {
    const multi = ["최유나: @송청혁", "이거 금요일까지 될까요?", "박지훈: 저도 궁금해요"].join("\n");
    expect(addressedToUser(multi, "이거 금요일까지 될까요", me)).toBe(true);
    expect(addressedToUser(multi, "저도 궁금해요", me)).toBe(false);
  });
});

describe("speakerRole", () => {
  it("사용자(이름 · 별칭 · 성을 뺀 이름)면 me", () => {
    expect(speakerRole("송청혁", "박지훈", me)).toBe("me");
    expect(speakerRole("Daniel", null, me)).toBe("me");
    expect(speakerRole("청혁", "박지훈", me)).toBe("me");
  });

  it("요청한 사람이면 counterpart (호칭 · 전체 이름 뒤 직함은 같은 사람)", () => {
    expect(speakerRole("박지훈", "박지훈", me)).toBe("counterpart");
    expect(speakerRole("김대표", "김대표님", me)).toBe("counterpart");
    expect(speakerRole("김민수", "김민수 대표", me)).toBe("counterpart");
  });

  it("둘 다 전체 이름이고 다르면 third_party", () => {
    expect(speakerRole("박지은", "최민수", me)).toBe("third_party");
  });

  it("비교할 수 없는 모양이면 정하지 않는다 (직함 · 이름만 · 다른 글자 · 요청자 모름)", () => {
    expect(speakerRole("김민수", "김대표", me)).toBeNull();
    expect(speakerRole("김민수", "민수", me)).toBeNull();
    expect(speakerRole("김민수", "Minsu Kim", me)).toBeNull();
    expect(speakerRole("Daniel Park", "Daniel", me)).toBeNull();
    expect(speakerRole("개발팀장", "개발팀", me)).toBeNull();
    expect(speakerRole("박지은", null, me)).toBeNull();
  });
});
