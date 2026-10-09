import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  authenticateRequest: vi.fn(),
  loadReportPreferences: vi.fn(),
  saveReportPreferences: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.authenticateRequest }));
vi.mock("@/lib/reports/store", () => ({ loadReportPreferences: mocks.loadReportPreferences, saveReportPreferences: mocks.saveReportPreferences }));

import { GET, PUT } from "./route";

// route 연결: gate는 REPORTS_V2_ENABLED, 인증은 authenticateRequest(Bearer · 쿠키 + CSRF), 저장소는 store.ts.

const ENDPOINT = "https://app.example.test/api/v2/reports/preferences";
const BODY = { mode: "daily", daily_time: "07:00", quiet_start: null, quiet_end: null, respect_focus: true, time_zone: "Europe/London" };

beforeEach(() => {
  vi.clearAllMocks();
  mocks.authenticateRequest.mockResolvedValue({ user: { id: "u1" } });
  mocks.loadReportPreferences.mockResolvedValue(null);
  mocks.saveReportPreferences.mockImplementation(async (_context, prefs) => ({ ...prefs, saved: true }));
});

afterEach(() => vi.unstubAllEnvs());

describe("/api/v2/reports/preferences", () => {
  it("REPORTS_V2_ENABLED가 꺼져 있으면(기본) 404, 인증도 하지 않는다", async () => {
    expect((await GET(new Request(ENDPOINT))).status).toBe(404);
    expect((await PUT(new Request(ENDPOINT, { method: "PUT", body: JSON.stringify(BODY) }))).status).toBe(404);
    expect(mocks.authenticateRequest).not.toHaveBeenCalled();
    expect(mocks.saveReportPreferences).not.toHaveBeenCalled();
  });

  it("켜져 있으면 GET은 기본값, PUT은 인증한 사용자로 저장", async () => {
    vi.stubEnv("REPORTS_V2_ENABLED", "true");
    expect(await (await GET(new Request(ENDPOINT))).json()).toMatchObject({ mode: "both", time_zone: null, saved: false });

    const response = await PUT(new Request(ENDPOINT, { method: "PUT", body: JSON.stringify(BODY) }));
    expect(response.status).toBe(200);
    expect(mocks.saveReportPreferences).toHaveBeenCalledWith({ user: { id: "u1" } }, BODY);
  });

  it("인증이 실패하면(쿠키 쓰기의 다른 출처 포함, authenticateRequest가 null) 401", async () => {
    vi.stubEnv("REPORTS_V2_ENABLED", "true");
    mocks.authenticateRequest.mockResolvedValue(null);
    expect((await PUT(new Request(ENDPOINT, { method: "PUT", body: JSON.stringify(BODY) }))).status).toBe(401);
    expect(mocks.saveReportPreferences).not.toHaveBeenCalled();
  });
});
