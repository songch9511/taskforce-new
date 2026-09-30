import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { retryStalledSources } from "@/lib/sources/retry";

import { GET } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({})) }));
vi.mock("@/lib/sources/retry", () => ({
  retryDeps: vi.fn(() => ({})),
  retryStalledSources: vi.fn(async () => ({ due: 0, retried: 0, failed: 0, gaveUp: 0, expired: 0, skippedForTime: 0 })),
}));

const cron = (authorization = "Bearer s3cret") => GET(new Request("https://api.example.dev/api/cron/retry-sources", { headers: { authorization } }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("CRON_SECRET", "s3cret");
});

afterEach(() => vi.unstubAllEnvs());

describe("GET /api/cron/retry-sources", () => {
  it("CRON_SECRET이 맞지 않으면 401", async () => {
    expect((await cron("Bearer wrong!")).status).toBe(401);
    expect(retryStalledSources).not.toHaveBeenCalled();
  });

  it("결과(due, retried, failed, gaveUp, expired, skippedForTime)를 그대로 JSON으로 돌려준다", async () => {
    const result = { due: 2, retried: 1, failed: 1, gaveUp: 3, expired: 7, skippedForTime: 0 };
    vi.mocked(retryStalledSources).mockResolvedValueOnce(result);
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(result);
  });

  it("실행 한도(300초) 안에서 응답할 시간을 남기고, 한 건은 최악 200초로 잡는다", async () => {
    const before = Date.now();
    const response = await cron();
    const after = Date.now();
    expect(response.status).toBe(200);
    const [, options] = vi.mocked(retryStalledSources).mock.calls[0];
    expect(options.itemBudgetMs).toBe(200_000);
    // 시작 시각 + 280초 (300초 한도에서 응답할 20초를 뺀다)
    expect(options.deadline).toBeGreaterThanOrEqual(before + 280_000);
    expect(options.deadline).toBeLessThanOrEqual(after + 280_000);
  });
});
