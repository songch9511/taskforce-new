import { describe, expect, it } from "vitest";

import { gmailConnectEnabled, googleConnectEnabled, oauthStateSecret, parsePublicEnv, slackAppToken, slackConnectEnabled, slackSigningSecret } from "./env";

describe("parsePublicEnv", () => {
  it("올바른 값이면 그대로 돌려준다", () => {
    const env = parsePublicEnv({
      NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_x",
    });
    expect(env.NEXT_PUBLIC_SUPABASE_URL).toBe("https://abc.supabase.co");
  });

  it("값이 없으면 어떤 변수가 빠졌는지 알려준다", () => {
    expect(() => parsePublicEnv({ NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co" })).toThrow(
      /NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY/,
    );
  });

  it("URL 형식이 아니면 거부한다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "abc",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).toThrow(/NEXT_PUBLIC_SUPABASE_URL/);
  });

  it("대시보드 주소를 넣으면 API 주소를 쓰라고 알려준다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://supabase.com/dashboard/project/abc",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).toThrow(/경로 없이/);
  });

  it("/rest/v1/ 같은 경로가 붙으면 거부한다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co/rest/v1/",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).toThrow(/경로 없이/);
  });

  it("끝에 슬래시만 있는 주소는 허용한다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co/",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).not.toThrow();
  });
});

describe("oauthStateSecret", () => {
  it("32자 이상이면 앞뒤 공백을 빼고 돌려준다", () => {
    expect(oauthStateSecret({ OAUTH_STATE_SECRET: ` ${"a".repeat(64)} ` })).toBe("a".repeat(64));
  });

  it.each([[undefined], [""], ["short-secret"]])("없거나 짧으면 던진다 (%s)", (value) => {
    expect(() => oauthStateSecret({ OAUTH_STATE_SECRET: value })).toThrow(/OAUTH_STATE_SECRET/);
  });
});

describe("Slack 비밀값", () => {
  it("서명 키가 없으면 던진다 (서명 없이 받으면 가짜 메시지가 들어온다)", () => {
    expect(slackSigningSecret({ SLACK_SIGNING_SECRET: " abc " })).toBe("abc");
    expect(() => slackSigningSecret({})).toThrow(/SLACK_SIGNING_SECRET/);
  });

  it("앱 수준 토큰은 xapp-로 시작할 때만 쓴다", () => {
    expect(slackAppToken({ SLACK_APP_TOKEN: "xapp-1-A-1-x" })).toBe("xapp-1-A-1-x");
    expect(slackAppToken({ SLACK_APP_TOKEN: "xoxp-1" })).toBeNull();
    expect(slackAppToken({})).toBeNull();
  });
});

describe("slackConnectEnabled", () => {
  it("설정하면 그 값대로, 설정하지 않았으면 개발 서버에서만 연다", () => {
    expect(slackConnectEnabled({ SLACK_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(true);
    expect(slackConnectEnabled({ SLACK_CONNECT_ENABLED: "false", NODE_ENV: "development" })).toBe(false);
    expect(slackConnectEnabled({ NODE_ENV: "production" })).toBe(false);
    expect(slackConnectEnabled({ NODE_ENV: "development" })).toBe(true);
  });
});

describe("gmailConnectEnabled", () => {
  it("설정하면 그 값대로, 설정하지 않았으면 개발 서버에서만 연다", () => {
    expect(gmailConnectEnabled({ GMAIL_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(true);
    expect(gmailConnectEnabled({ GMAIL_CONNECT_ENABLED: " true ", NODE_ENV: "production" })).toBe(true);
    expect(gmailConnectEnabled({ GMAIL_CONNECT_ENABLED: "false", NODE_ENV: "development" })).toBe(false);
    expect(gmailConnectEnabled({ GMAIL_CONNECT_ENABLED: "", NODE_ENV: "production" })).toBe(false);
    expect(gmailConnectEnabled({ NODE_ENV: "production" })).toBe(false);
    expect(gmailConnectEnabled({ NODE_ENV: "development" })).toBe(true);
  });

  it("Slack 플래그를 보지 않는다", () => {
    expect(gmailConnectEnabled({ SLACK_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(false);
    expect(slackConnectEnabled({ GMAIL_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(false);
  });
});

describe("googleConnectEnabled", () => {
  it("설정하면 그 값대로, 설정하지 않았으면 개발 서버에서만 연다", () => {
    expect(googleConnectEnabled({ GOOGLE_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(true);
    expect(googleConnectEnabled({ GOOGLE_CONNECT_ENABLED: " true ", NODE_ENV: "production" })).toBe(true);
    expect(googleConnectEnabled({ GOOGLE_CONNECT_ENABLED: "false", NODE_ENV: "development" })).toBe(false);
    expect(googleConnectEnabled({ GOOGLE_CONNECT_ENABLED: "", NODE_ENV: "production" })).toBe(false);
    expect(googleConnectEnabled({ NODE_ENV: "production" })).toBe(false);
    expect(googleConnectEnabled({ NODE_ENV: "development" })).toBe(true);
  });

  it("Gmail · Slack 플래그를 보지 않는다", () => {
    expect(googleConnectEnabled({ GMAIL_CONNECT_ENABLED: "true", SLACK_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(false);
    expect(gmailConnectEnabled({ GOOGLE_CONNECT_ENABLED: "true", NODE_ENV: "production" })).toBe(false);
  });
});
