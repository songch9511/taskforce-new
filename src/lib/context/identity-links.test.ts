import { describe, expect, it } from "vitest";

import { countsAsMe, identityEmails, oauthIdentityFromConnection, type IdentityLinkRow } from "./identity-links";

// 서비스별 "나" (아키텍처 5.5): oauth · profile · user_confirmed이고 공용이 아닌 링크만 "나". 추정 · 공용은 올리지 않는다.

const link = (overrides: Partial<IdentityLinkRow>): IdentityLinkRow => ({
  provider: "gmail",
  account_ref: "sub-1",
  email: null,
  verified_via: "oauth",
  shared_account: false,
  ...overrides,
});

describe("countsAsMe", () => {
  it.each([
    ["oauth", false, true],
    ["profile", false, true],
    ["user_confirmed", false, true],
    ["inferred", false, false],
    ["oauth", true, false],
    ["user_confirmed", true, false],
  ] as const)("%s (공용 %s) → %s", (via, shared, expected) => {
    expect(countsAsMe({ verified_via: via, shared_account: shared })).toBe(expected);
  });
});

describe("identityEmails", () => {
  it("링크가 없으면 지금과 같다 (프로필 · 로그인 + 연결 설정 주소)", () => {
    expect(identityEmails(["login@example.com"], ["me@company.dev"], [])).toEqual(["login@example.com", "me@company.dev"]);
  });

  it("한 서비스에 계정 여럿: 나로 치는 링크의 주소를 모두 더하고, 추정 · 공용 링크는 더하지 않는다", () => {
    const emails = identityEmails(
      ["login@example.com"],
      [],
      [
        link({ account_ref: "sub-1", email: "Me@Work.dev" }),
        link({ account_ref: "sub-2", email: "me@home.dev" }),
        link({ verified_via: "profile", account_ref: "alias", email: "alias@work.dev" }),
        link({ verified_via: "inferred", account_ref: "maybe", email: "maybe-me@work.dev" }),
        link({ verified_via: "user_confirmed", account_ref: "team", email: "team@work.dev", shared_account: true }),
      ],
    );
    expect(emails).toEqual(["login@example.com", "me@work.dev", "me@home.dev", "alias@work.dev"]);
  });

  it("공용으로 표시한 주소는 연결 설정 주소에서도 빼지만, 사용자가 정한 프로필 · 로그인 주소는 빼지 않는다", () => {
    const shared = [link({ verified_via: "user_confirmed", account_ref: "team", email: "TEAM@work.dev", shared_account: true })];
    expect(identityEmails(["login@example.com"], ["team@work.dev", "me@work.dev"], shared)).toEqual(["login@example.com", "me@work.dev"]);
    expect(identityEmails(["team@work.dev"], [], shared)).toEqual(["team@work.dev"]);
    // 추정 링크의 공용 표시는 보지 않는다 (확인 전): 연결 주소가 그대로 "나"
    expect(identityEmails([], ["me@work.dev"], [link({ verified_via: "inferred", account_ref: "x", email: "me@work.dev", shared_account: true })])).toEqual(["me@work.dev"]);
  });
});

describe("oauthIdentityFromConnection", () => {
  it("Slack은 팀:사용자, Google · Gmail은 계정 sub + 주소. Notion 연결 id는 워크스페이스라 링크가 없다", () => {
    expect(oauthIdentityFromConnection({ provider: "slack", externalAccountId: "T1:U1", displayName: "Acme" })).toEqual({ provider: "slack", accountRef: "T1:U1", email: null });
    expect(oauthIdentityFromConnection({ provider: "gmail", externalAccountId: "1234", displayName: " Me@Gmail.com " })).toEqual({
      provider: "gmail",
      accountRef: "1234",
      email: "me@gmail.com",
    });
    expect(oauthIdentityFromConnection({ provider: "google", externalAccountId: "1234", displayName: null })).toEqual({ provider: "google", accountRef: "1234", email: null });
    expect(oauthIdentityFromConnection({ provider: "notion", externalAccountId: "workspace-1", displayName: "Acme" })).toBeNull();
  });
});
