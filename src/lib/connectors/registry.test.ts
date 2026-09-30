import { afterEach, describe, expect, it, vi } from "vitest";

import { connectorFor, syncConnections, tokenRevokerFor, webConnector } from "./registry";

vi.mock("server-only", () => ({}));

// Slack 연결을 앱에 열기 전(SLACK_CONNECT_ENABLED): 앱 · 동기화에는 닫혀 있고, 웹(/lab)은 운영자(ADMIN_EMAILS)만 운영에서 시험한다.
describe("Slack 연결 열기", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("닫혀 있으면 앱에는 null, 웹은 운영자에게만 연다. 토큰 폐기는 늘 된다", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "");
    vi.stubEnv("ADMIN_EMAILS", "ops@example.com");
    expect(connectorFor("slack")).toBeNull();
    expect(webConnector("slack", "ops@example.com")?.provider).toBe("slack");
    expect(webConnector("slack", "tester@example.com")).toBeNull();
    expect(webConnector("slack", null)).toBeNull();
    expect(tokenRevokerFor("slack")).toBeTypeOf("function");
  });

  it("열면 누구나", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "true");
    vi.stubEnv("ADMIN_EMAILS", "");
    expect(connectorFor("slack")?.provider).toBe("slack");
    expect(webConnector("slack", "tester@example.com")?.provider).toBe("slack");
  });

  it("닫혀 있어도 이미 있는 Slack 연결(운영자 시험)은 동기화한다", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "");
    const providers: unknown[] = [];
    const admin = {
      rpc: (_name: string, args: { p_providers: unknown[] }) => {
        providers.push(...args.p_providers);
        return { throwOnError: async () => ({ data: [] }) };
      },
    };
    await syncConnections(admin as never);
    expect(providers).toContain("slack");
  });
});

// Gmail 연결을 앱에 열기 전(GMAIL_CONNECT_ENABLED): Slack과 같은 모양. 앱 · 새 연결은 닫고, 웹(/lab)은 운영자만, 이미 있는 연결은 동기화한다.
describe("Gmail 연결 열기", () => {
  afterEach(() => vi.unstubAllEnvs());

  /** 동기화 대상 서비스 (syncable_connections에 넘기는 p_providers) */
  async function syncedProviders() {
    const providers: unknown[] = [];
    const admin = {
      rpc: (_name: string, args: { p_providers: unknown[] }) => {
        providers.push(...args.p_providers);
        return { throwOnError: async () => ({ data: [] }) };
      },
    };
    await syncConnections(admin as never);
    return providers;
  }

  it("닫혀 있으면 앱에는 null, 웹은 운영자에게만 연다. 토큰 폐기는 늘 된다", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "");
    vi.stubEnv("ADMIN_EMAILS", "ops@example.com");
    expect(connectorFor("gmail")).toBeNull();
    expect(webConnector("gmail", "ops@example.com")?.provider).toBe("gmail");
    expect(webConnector("gmail", "OPS@example.com")?.provider).toBe("gmail");
    expect(webConnector("gmail", "tester@example.com")).toBeNull();
    expect(webConnector("gmail", null)).toBeNull();
    expect(tokenRevokerFor("gmail")).toBeTypeOf("function");
  });

  it("열면 누구나", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "true");
    vi.stubEnv("ADMIN_EMAILS", "");
    expect(connectorFor("gmail")?.provider).toBe("gmail");
    expect(webConnector("gmail", "tester@example.com")?.provider).toBe("gmail");
  });

  it("Gmail 플래그는 Slack 플래그와 따로 논다", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "true");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "");
    expect(connectorFor("slack")?.provider).toBe("slack");
    expect(connectorFor("gmail")).toBeNull();
  });

  it("닫혀 있어도 이미 있는 Gmail 연결(운영자 시험)은 동기화한다", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "");
    expect(await syncedProviders()).toContain("gmail");
  });

  it("개발 서버에서는 플래그가 비어 있어도 연다", () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "");
    expect(connectorFor("gmail")?.provider).toBe("gmail");
  });

});

// google(Calendar · Meet) 연결을 앱에 열기 전(GOOGLE_CONNECT_ENABLED): Gmail과 같은 모양. 앱 · 새 연결은 닫고, 웹(/lab)은 운영자만, 이미 있는 연결은 동기화한다.
describe("Google 연결 열기", () => {
  afterEach(() => vi.unstubAllEnvs());

  it("운영에서는 기본으로 닫혀 있다: 앱에는 null, 웹은 운영자에게만 연다. 토큰 폐기는 늘 된다", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("GOOGLE_CONNECT_ENABLED", "");
    vi.stubEnv("ADMIN_EMAILS", "ops@example.com");
    expect(connectorFor("google")).toBeNull();
    expect(webConnector("google", "ops@example.com")?.provider).toBe("google");
    expect(webConnector("google", "tester@example.com")).toBeNull();
    expect(webConnector("google", null)).toBeNull();
    expect(tokenRevokerFor("google")).toBeTypeOf("function");
  });

  it("열면 누구나", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("GOOGLE_CONNECT_ENABLED", "true");
    vi.stubEnv("ADMIN_EMAILS", "");
    expect(connectorFor("google")?.provider).toBe("google");
    expect(webConnector("google", "tester@example.com")?.provider).toBe("google");
  });

  it("Google 플래그는 Gmail · Slack 플래그와 따로 논다", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("SLACK_CONNECT_ENABLED", "true");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "true");
    vi.stubEnv("GOOGLE_CONNECT_ENABLED", "");
    expect(connectorFor("slack")?.provider).toBe("slack");
    expect(connectorFor("gmail")?.provider).toBe("gmail");
    expect(connectorFor("google")).toBeNull();
    vi.stubEnv("GOOGLE_CONNECT_ENABLED", "true");
    vi.stubEnv("GMAIL_CONNECT_ENABLED", "");
    expect(connectorFor("google")?.provider).toBe("google");
    expect(connectorFor("gmail")).toBeNull();
  });

  it("닫혀 있어도 이미 있는 google 연결(운영자 시험)은 동기화한다", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("GOOGLE_CONNECT_ENABLED", "");
    const providers: unknown[] = [];
    const admin = {
      rpc: (_name: string, args: { p_providers: unknown[] }) => {
        providers.push(...args.p_providers);
        return { throwOnError: async () => ({ data: [] }) };
      },
    };
    await syncConnections(admin as never);
    expect(providers).toContain("google");
  });

  it("개발 서버에서는 플래그가 비어 있어도 연다", () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("GOOGLE_CONNECT_ENABLED", "");
    expect(connectorFor("google")?.provider).toBe("google");
  });
});
