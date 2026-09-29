import { afterEach, describe, expect, it, vi } from "vitest";

import { cronAuthorized, cronUnauthorized } from "./cron";

const request = (authorization?: string) => new Request("https://api.example.dev/api/cron/sync", { headers: authorization ? { authorization } : {} });

afterEach(() => vi.unstubAllEnvs());

describe("cronAuthorized", () => {
  it("Bearer $CRON_SECRET만 받는다", () => {
    vi.stubEnv("CRON_SECRET", "s3cret");
    expect(cronAuthorized(request("Bearer s3cret"))).toBe(true);
    expect(cronAuthorized(request("bearer s3cret"))).toBe(true);
    expect(cronAuthorized(request("Bearer wrong!"))).toBe(false);
    expect(cronAuthorized(request("Bearer s3cret-longer"))).toBe(false);
    expect(cronAuthorized(request())).toBe(false);
  });

  it("CRON_SECRET이 비어 있으면 모두 거절한다", () => {
    vi.stubEnv("CRON_SECRET", "");
    expect(cronAuthorized(request("Bearer "))).toBe(false);
    expect(cronAuthorized(request())).toBe(false);
  });

  it("거절 응답은 401 unauthorized", async () => {
    const response = cronUnauthorized();
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: { code: "unauthorized", message: "cron 인증 실패" } });
  });
});
