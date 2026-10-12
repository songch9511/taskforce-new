import { describe, expect, it } from "vitest";

import type { UserIdentity } from "@/lib/pipeline/identity";

import { normalizeAccountRef, observationsFromParticipants, slackObservation } from "./people";

// 상대 계정 뽑기 (아키텍처 5.5): 1차 키는 계정, 2차 키는 이메일, 이름만으로는 사람을 만들거나 합치지 않는다.

const me: UserIdentity = { name: "김도윤", aliases: ["Daniel"], emails: ["me@example.com"] };

describe("observationsFromParticipants", () => {
  it("주소가 있는 관련자만 계정으로(주소 = 계정, 소문자), 사용자 자신 · 이름만 있는 사람 · 같은 주소는 빼거나 한 번", () => {
    const observations = observationsFromParticipants(
      "gmail",
      {
        from: { name: "김지훈", email: "Jihoon@Example.com" },
        to: [{ name: "김도윤", email: "me@example.com" }, { name: "이름만" }],
        cc: [{ name: "김지훈 (회사)", email: "jihoon@example.com" }, { email: "ops@example.com" }, { name: "주소 아님", email: "not-an-address" }],
      },
      me,
    );
    expect(observations).toEqual([
      { provider: "gmail", accountRef: "jihoon@example.com", displayName: "김지훈", email: "jihoon@example.com" },
      { provider: "gmail", accountRef: "ops@example.com", displayName: null, email: "ops@example.com" },
    ]);
  });

  it("이름이 같아도 주소가 다르면 다른 계정이다 (합치지 않는다)", () => {
    const observations = observationsFromParticipants(
      "google",
      { attendees: [{ name: "김민수", email: "minsu@a.dev" }, { name: "김민수", email: "minsu@b.dev" }] },
      me,
    );
    expect(observations.map((o) => o.accountRef)).toEqual(["minsu@a.dev", "minsu@b.dev"]);
    expect(observationsFromParticipants("gmail", null, me)).toEqual([]);
  });
});

describe("계정 id", () => {
  it("메일 서비스는 주소를 소문자로, 그 밖은 앞뒤 공백만", () => {
    expect(normalizeAccountRef("gmail", " A@B.dev ")).toBe("a@b.dev");
    expect(normalizeAccountRef("slack", " T1:U2 ")).toBe("T1:U2");
  });

  it("Slack 계정은 워크스페이스까지 붙인다: 다른 워크스페이스의 같은 사용자 id는 다른 계정", () => {
    expect(slackObservation("T1", "U2", " 지훈 ", "Jihoon@Example.com")).toEqual({ provider: "slack", accountRef: "T1:U2", displayName: "지훈", email: "jihoon@example.com" });
    expect(slackObservation("T9", "U2", null).accountRef).toBe("T9:U2");
    expect(slackObservation("T1", "U2", "", "nope").email).toBeNull();
  });
});
