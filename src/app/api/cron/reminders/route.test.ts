import { readFileSync } from "node:fs";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ notifyDueSoon: vi.fn(), createAdminClient: vi.fn(() => ({ admin: true })) }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.createAdminClient }));
vi.mock("@/lib/notify/service", () => ({ notifyDueSoon: mocks.notifyDueSoon }));

import { GET } from "./route";

// 기존 아침 기한 알림은 0.2.0 보고(REPORTS_V2_ENABLED · cron/reports)와 상관없이 그대로 돈다 (H1 회귀).

const cron = (authorization = "Bearer s3cret") => GET(new Request("https://api.example.test/api/cron/reminders", { headers: { authorization } }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("CRON_SECRET", "s3cret");
  mocks.notifyDueSoon.mockResolvedValue({ users: 2, sent: 3 });
});

afterEach(() => vi.unstubAllEnvs());

describe("GET /api/cron/reminders", () => {
  it("CRON_SECRET이 맞지 않으면 401", async () => {
    expect((await cron("Bearer wrong!")).status).toBe(401);
    expect(mocks.notifyDueSoon).not.toHaveBeenCalled();
  });

  it.each([undefined, "true", "false"])("REPORTS_V2_ENABLED=%s여도 기한 알림을 한 번 보내고 결과를 그대로 돌려준다", async (value) => {
    if (value !== undefined) vi.stubEnv("REPORTS_V2_ENABLED", value);
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ users: 2, sent: 3 });
    expect(mocks.notifyDueSoon).toHaveBeenCalledTimes(1);
    expect(mocks.notifyDueSoon).toHaveBeenCalledWith({ admin: true });
  });

  it("vercel.json의 스케줄은 그대로 매일 00:00 UTC (09:00 KST)", () => {
    const vercel = JSON.parse(readFileSync(path.resolve(__dirname, "../../../../../vercel.json"), "utf8")) as { crons: { path: string; schedule: string }[] };
    expect(vercel.crons).toContainEqual({ path: "/api/cron/reminders", schedule: "0 0 * * *" });
  });
});
