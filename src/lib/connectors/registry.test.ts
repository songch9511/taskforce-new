import { afterEach, describe, expect, it, vi } from "vitest";

import { connectorFor, slackWebConnector, tokenRevokerFor } from "./registry";

vi.mock("server-only", () => ({}));

// Slack 연결을 앱에 열기 전(SLACK_CONNECT_ENABLED): 앱 · 동기화에는 닫혀 있고, 웹(/lab)은 운영자(ADMIN_EMAILS)만 운영에서 시험한다.
describe("Slack 연결 열기", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("닫혀 있으면 앱에는 null, 웹은 운영자에게만 연다. 토큰 폐기는 늘 된다", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "");
    vi.stubEnv("ADMIN_EMAILS", "ops@example.com");
    expect(connectorFor("slack")).toBeNull();
    expect(slackWebConnector("ops@example.com")?.provider).toBe("slack");
    expect(slackWebConnector("tester@example.com")).toBeNull();
    expect(slackWebConnector(null)).toBeNull();
    expect(tokenRevokerFor("slack")).toBeTypeOf("function");
  });

  it("열면 누구나", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "true");
    vi.stubEnv("ADMIN_EMAILS", "");
    expect(connectorFor("slack")?.provider).toBe("slack");
    expect(slackWebConnector("tester@example.com")?.provider).toBe("slack");
  });
});
