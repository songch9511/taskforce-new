import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createAdminClient: vi.fn(() => ({ admin: true })),
  apnsConfigFromEnv: vi.fn(),
  runDailyReports: vi.fn(),
  supabaseReportStore: vi.fn(() => ({ store: true })),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.createAdminClient }));
vi.mock("@/lib/notify/apns", () => ({ apnsConfigFromEnv: mocks.apnsConfigFromEnv }));
vi.mock("@/lib/reports/job", () => ({ runDailyReports: mocks.runDailyReports }));
vi.mock("@/lib/reports/store", () => ({ supabaseReportStore: mocks.supabaseReportStore }));

import { GET } from "./route";

// 일일 보고 cron (0.2.0 H1): gate가 꺼져 있으면 아무것도 읽거나 보내지 않는다.

const RESULT = {
  preferences: 3,
  due: 1,
  claimed: 1,
  retried: 0,
  held: 0,
  sent: 1,
  retrying: 0,
  failed: 0,
  skipped: 0,
  expired: 0,
  invalid_time_zone: 0,
  deferred_for_time: 0,
  fence_missed: 0,
  errors: 0,
};
const CONFIG = { keyId: "k" };
const cron = (authorization = "Bearer s3cret") => GET(new Request("https://api.example.test/api/cron/reports", { headers: { authorization } }));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.stubEnv("REPORTS_V2_ENABLED", "true");
  mocks.apnsConfigFromEnv.mockReturnValue(CONFIG);
  mocks.runDailyReports.mockResolvedValue(RESULT);
  vi.spyOn(console, "info").mockImplementation(() => {});
  vi.spyOn(console, "error").mockImplementation(() => {});
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("GET /api/cron/reports", () => {
  it("CRON_SECRET이 맞지 않으면 401", async () => {
    expect((await cron("Bearer wrong!")).status).toBe(401);
    expect(mocks.runDailyReports).not.toHaveBeenCalled();
  });

  it.each(["", "false", "1", "TRUE"])("REPORTS_V2_ENABLED=%j이면 { enabled: false }만 돌려주고 DB · APNs에 닿지 않는다", async (value) => {
    vi.stubEnv("REPORTS_V2_ENABLED", value);
    const response = await cron();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ enabled: false });
    expect(mocks.createAdminClient).not.toHaveBeenCalled();
    expect(mocks.apnsConfigFromEnv).not.toHaveBeenCalled();
    expect(mocks.runDailyReports).not.toHaveBeenCalled();
  });

  it("APNs 키가 없으면 원장도 만들지 않는다", async () => {
    mocks.apnsConfigFromEnv.mockReturnValue(null);
    expect(await (await cron()).json()).toEqual({ enabled: true, configured: false });
    expect(mocks.createAdminClient).not.toHaveBeenCalled();
    expect(mocks.runDailyReports).not.toHaveBeenCalled();
  });

  it("켜져 있으면 service role 저장소 · APNs 설정으로 돌리고 숫자만 돌려준다. 응답할 15초를 남긴다", async () => {
    const before = Date.now();
    const response = await cron();
    const after = Date.now();
    expect(await response.json()).toEqual({ enabled: true, configured: true, ...RESULT });
    expect(mocks.supabaseReportStore).toHaveBeenCalledWith({ admin: true });
    const [store, push, options] = mocks.runDailyReports.mock.calls[0] as unknown as [unknown, unknown, { deadline: number; clock?: unknown }];
    expect(store).toEqual({ store: true });
    expect(push).toEqual({ config: CONFIG });
    // 고정 시각을 넘기지 않는다: job이 잡기 · 보내기마다 시계를 읽는다
    expect(Object.keys(options)).toEqual(["deadline"]);
    expect(options.deadline).toBeGreaterThanOrEqual(before + 45_000);
    expect(options.deadline).toBeLessThanOrEqual(after + 45_000);
    expect(console.info).toHaveBeenCalledWith(JSON.stringify({ event: "daily_reports", ...RESULT }));
  });

  it.each([{ failed: 2 }, { errors: 1 }, { fence_missed: 1 }])("실패 · 오류 · 펜스 불일치(%o)가 있으면 오류 로그로 남긴다 (응답은 200, 다음 실행이 다시 돈다)", async (extra) => {
    mocks.runDailyReports.mockResolvedValueOnce({ ...RESULT, ...extra });
    expect((await cron()).status).toBe(200);
    expect(console.error).toHaveBeenCalledWith(JSON.stringify({ event: "daily_reports", ...RESULT, ...extra }));
  });
});
