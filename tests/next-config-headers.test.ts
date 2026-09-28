import { unstable_getResponseFromNextConfig } from "next/experimental/testing/server";
import { afterEach, describe, expect, it, vi } from "vitest";

import nextConfig from "../next.config";

async function headersFor(path: string) {
  const response = await unstable_getResponseFromNextConfig({ url: `https://taskforce.test${path}`, nextConfig });
  return response.headers;
}

const API_PATHS = ["/api/v1/actions", "/api/v1/actions/abc/confirm", "/api/connectors/notion/callback", "/api/cron/sync"];
const PAGE_PATHS = ["/", "/lab", "/admin/metrics", "/login", "/auth/confirm"];

describe("보안 헤더 (next.config.ts)", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it.each([...API_PATHS, ...PAGE_PATHS])("%s에 공통 헤더가 붙는다", async (path) => {
    const headers = await headersFor(path);
    expect(headers.get("strict-transport-security")).toMatch(/^max-age=(\d+); includeSubDomains$/);
    expect(Number(/max-age=(\d+)/.exec(headers.get("strict-transport-security") ?? "")?.[1])).toBeGreaterThanOrEqual(31536000);
    expect(headers.get("x-content-type-options")).toBe("nosniff");
    expect(headers.get("referrer-policy")).toBe("strict-origin-when-cross-origin");
    expect(headers.get("x-frame-options")).toBe("DENY");
    expect(headers.get("permissions-policy")).toContain("camera=()");
    expect(headers.get("permissions-policy")).toContain("microphone=()");
    expect(headers.get("permissions-policy")).toContain("geolocation=()");
    expect(headers.get("cross-origin-opener-policy")).toBe("same-origin");
    expect(headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
  });

  it.each(API_PATHS)("%s는 아무것도 불러오지 않는 API용 CSP를 받는다", async (path) => {
    expect((await headersFor(path)).get("content-security-policy")).toBe("default-src 'none'; frame-ancestors 'none'");
  });

  it.each(PAGE_PATHS)("%s는 자기 출처만 허용하는 화면용 CSP를 받는다", async (path) => {
    const csp = (await headersFor(path)).get("content-security-policy") ?? "";
    expect(csp).toContain("default-src 'self'");
    expect(csp).toContain("object-src 'none'");
    expect(csp).toContain("base-uri 'self'");
    expect(csp).toContain("form-action 'self'");
    expect(csp).not.toContain("'unsafe-eval'");
  });

  it("Supabase 주소가 있으면 화면 CSP의 connect-src에 https · wss로 들어간다", async () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://abcd.supabase.co");
    const csp = (await headersFor("/lab")).get("content-security-policy") ?? "";
    expect(csp).toContain("connect-src 'self' https://abcd.supabase.co wss://abcd.supabase.co");
  });

  it("개발 모드에서만 'unsafe-eval'을 더한다", async () => {
    vi.stubEnv("NODE_ENV", "development");
    expect((await headersFor("/lab")).get("content-security-policy")).toContain("'unsafe-eval'");
  });

  it("X-Powered-By를 내보내지 않는다", () => {
    expect(nextConfig.poweredByHeader).toBe(false);
  });
});
