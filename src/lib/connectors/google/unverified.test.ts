import { describe, expect, it } from "vitest";

import { CALENDAR_EVENTS_SCOPE, isConnectedAccount, LIST_ATTENDED_MEETINGS, MEET_READONLY_SCOPE, sameMeetingCode } from "./unverified";

// dev 회의로 확인할 가정들 (google-integration.md 9장 "PR 3 dev에서 확인할 것"). 확인 결과가 다르면 이 파일의 한 줄만 바꾼다.

describe("dev에서 확인할 가정의 지금 값", () => {
  it("범위는 google-verification.md 1장 그대로다 (Calendar는 초대가 보이는지 dev 확인 전)", () => {
    expect(CALENDAR_EVENTS_SCOPE).toBe("https://www.googleapis.com/auth/calendar.events.owned.readonly");
    expect(MEET_READONLY_SCOPE).toBe("https://www.googleapis.com/auth/meetings.space.readonly");
  });

  it("참석한 회의도 찾는다 (G2 ②, 두 길을 모두 만든다)", () => {
    expect(LIST_ATTENDED_MEETINGS).toBe(true);
  });
});

describe("isConnectedAccount (G5)", () => {
  it("Meet 참가자의 users/{id}가 연결한 계정의 sub와 같을 때만 사용자다", () => {
    expect(isConnectedAccount("users/1234567890", "1234567890")).toBe(true);
    expect(isConnectedAccount("users/1234567890", "999")).toBe(false);
    expect(isConnectedAccount("1234567890", "1234567890")).toBe(false);
    expect(isConnectedAccount(undefined, "1234567890")).toBe(false);
    expect(isConnectedAccount("users/1234567890", null)).toBe(false);
    expect(isConnectedAccount("users/", "")).toBe(false);
  });
});

describe("sameMeetingCode", () => {
  it("대소문자 · 하이픈을 무시하고 비교한다", () => {
    expect(sameMeetingCode("abc-defg-hij", "abc-defg-hij")).toBe(true);
    expect(sameMeetingCode("ABC-defg-hij", "abcdefghij")).toBe(true);
    expect(sameMeetingCode("abc-defg-hij", "abc-defg-xyz")).toBe(false);
  });

  it("빈 코드는 같은 코드가 아니다", () => {
    expect(sameMeetingCode(undefined, undefined)).toBe(false);
    expect(sameMeetingCode("", "")).toBe(false);
    expect(sameMeetingCode("abc-defg-hij", undefined)).toBe(false);
  });
});
