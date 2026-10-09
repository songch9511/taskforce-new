import { describe, expect, it, vi } from "vitest";

import type { ReportPreferences, ReportPreferencesRequest } from "@/lib/api/contract";

import { DEFAULT_REPORT_PREFERENCES, handleGetReportPreferences, handlePutReportPreferences, type ReportPreferencesDeps } from "./preferences";

// GET · PUT /api/v2/reports/preferences 처리. 저장소 · 인증은 가짜로 (route 연결은 src/app/api/v2/reports/preferences/route.test.ts).

type User = { id: string };

const VALID: ReportPreferencesRequest = {
  mode: "both",
  daily_time: "08:30",
  quiet_start: "22:00",
  quiet_end: "08:00",
  respect_focus: true,
  time_zone: "Asia/Seoul",
};

function deps(options: { enabled?: boolean; user?: User | null; stored?: ReportPreferences | null; saveError?: Error } = {}) {
  const saved: ReportPreferencesRequest[] = [];
  const authenticate = vi.fn(async () => (options.user === undefined ? { id: "u1" } : options.user));
  const d: ReportPreferencesDeps<User> = {
    enabled: () => options.enabled ?? true,
    authenticate,
    load: async () => options.stored ?? null,
    save: async (_user, prefs) => {
      if (options.saveError) throw options.saveError;
      saved.push(prefs);
      return { ...prefs, saved: true };
    },
  };
  return { d, saved, authenticate };
}

const get = () => new Request("http://localhost/api/v2/reports/preferences");
const put = (body: unknown) => new Request("http://localhost/api/v2/reports/preferences", { method: "PUT", body: JSON.stringify(body) });

describe("보고 설정 API", () => {
  it("REPORTS_V2_ENABLED가 꺼져 있으면 GET · PUT 모두 404이고 인증 · 저장을 하지 않는다", async () => {
    const { d, saved, authenticate } = deps({ enabled: false });
    for (const response of [await handleGetReportPreferences(get(), d), await handlePutReportPreferences(put(VALID), d)]) {
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({ error: { code: "not_found", message: "없는 경로입니다." } });
    }
    expect(authenticate).not.toHaveBeenCalled();
    expect(saved).toEqual([]);
  });

  it("로그인하지 않았으면 401", async () => {
    const { d } = deps({ user: null });
    expect((await handleGetReportPreferences(get(), d)).status).toBe(401);
    expect((await handlePutReportPreferences(put(VALID), d)).status).toBe(401);
  });

  it("저장한 적이 없으면 D06 기본값과 time_zone null (서버는 시간대를 추측하지 않는다)", async () => {
    const response = await handleGetReportPreferences(get(), deps().d);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      mode: "both",
      daily_time: "08:30",
      quiet_start: "22:00",
      quiet_end: "08:00",
      respect_focus: true,
      time_zone: null,
      saved: false,
    });
    expect(DEFAULT_REPORT_PREFERENCES.saved).toBe(false);
  });

  it("저장한 설정을 그대로 돌려준다", async () => {
    const stored: ReportPreferences = { ...VALID, mode: "daily", quiet_start: null, quiet_end: null, time_zone: "Europe/London", saved: true };
    expect(await (await handleGetReportPreferences(get(), deps({ stored }).d)).json()).toEqual(stored);
  });

  it("PUT: 검증한 값만 저장하고 저장된 설정을 돌려준다. 조용한 시간 끄기는 둘 다 null", async () => {
    const { d, saved } = deps();
    const response = await handlePutReportPreferences(put(VALID), d);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ...VALID, saved: true });

    const off = { ...VALID, mode: "meaningful", quiet_start: null, quiet_end: null, respect_focus: false, time_zone: "America/New_York" };
    expect((await handlePutReportPreferences(put(off), d)).status).toBe(200);
    expect(saved).toEqual([VALID, off]);
  });

  it.each<[string, Record<string, unknown>]>([
    ["시간대가 없다", { time_zone: undefined }],
    ["시간대 null", { time_zone: null }],
    ["고정 오프셋은 IANA 이름이 아니다", { time_zone: "+09:00" }],
    ["없는 시간대", { time_zone: "Mars/Base" }],
    ["철자가 틀린 시간대", { time_zone: "Asia/Seol" }],
    ["시각 모양 8:30", { daily_time: "8:30" }],
    ["24:00은 없는 시각", { daily_time: "24:00" }],
    ["초 단위", { daily_time: "08:30:00" }],
    ["조용한 시간 한쪽만 null", { quiet_end: null }],
    ["조용한 시간 시작 == 끝", { quiet_start: "03:00", quiet_end: "03:00" }],
    ["모르는 모드", { mode: "weekly" }],
    ["respect_focus가 불리언이 아니다", { respect_focus: "yes" }],
    ["모르는 필드 (부분 수정 · 서버 전용 열을 받지 않는다)", { schedule_changed_at: "2026-10-10T00:00:00Z" }],
  ])("잘못된 본문은 400이고 저장하지 않는다: %s", async (_name, patch) => {
    const { d, saved } = deps();
    const response = await handlePutReportPreferences(put({ ...VALID, ...patch }), d);
    expect(response.status).toBe(400);
    expect((await response.json()).error.code).toBe("invalid_request");
    expect(saved).toEqual([]);
  });

  it("저장이 실패하면 500 (요청 값을 오류 메시지에 담지 않는다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await handlePutReportPreferences(put(VALID), deps({ saveError: new Error("db down") }).d);
    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: { code: "internal_error", message: "보고 설정을 저장하지 못했습니다." } });
  });
});
