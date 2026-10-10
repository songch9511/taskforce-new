import { describe, expect, it, vi } from "vitest";

import type { ReportPreferences, ReportPreferencesRequest } from "@/lib/api/contract";

import { DEFAULT_REPORT_PREFERENCES, handleGetReportPreferences, handlePutReportPreferences, type ReportPreferencesDeps } from "./preferences";

// GET · PUT /api/v2/reports/preferences 처리. 저장소 · 인증은 가짜로 (route 연결은 src/app/api/v2/reports/preferences/route.test.ts,
// 실제 비교 후 쓰기 쿼리는 store.test.ts, version 트리거는 tests/db/report-preferences.test.ts).

type User = { id: string };

const VALID: ReportPreferencesRequest = {
  mode: "both",
  daily_time: "08:30",
  quiet_start: "22:00",
  quiet_end: "08:00",
  respect_focus: true,
  time_zone: "Asia/Seoul",
  expected_version: null,
};

/** DB의 비교 후 쓰기를 흉내 낸다: expected_version null = 처음 만들기(있으면 충돌), 숫자 = 그 version일 때만 */
function deps(options: { enabled?: boolean; user?: User | null; stored?: ReportPreferences | null; saveError?: Error } = {}) {
  let row: ReportPreferences | null = options.stored ?? null;
  const saved: ReportPreferencesRequest[] = [];
  const authenticate = vi.fn(async () => (options.user === undefined ? { id: "u1" } : options.user));
  const d: ReportPreferencesDeps<User> = {
    enabled: () => options.enabled ?? true,
    authenticate,
    load: async () => row,
    save: async (_user, prefs) => {
      if (options.saveError) throw options.saveError;
      const { expected_version: expected, ...fields } = prefs;
      if (expected === null ? row !== null : row === null || row.version !== expected) return null;
      saved.push(prefs);
      row = { ...fields, saved: true, version: (row?.version ?? 0) + 1 };
      return row;
    },
  };
  return { d, saved, authenticate };
}

const get = () => new Request("http://localhost/api/v2/reports/preferences");
const put = (body: unknown) => new Request("http://localhost/api/v2/reports/preferences", { method: "PUT", body: JSON.stringify(body) });

const STORED: ReportPreferences = {
  mode: "both",
  daily_time: "08:30",
  quiet_start: "22:00",
  quiet_end: "08:00",
  respect_focus: true,
  time_zone: "Asia/Seoul",
  saved: true,
  version: 3,
};

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

  it("저장한 적이 없으면 D06 기본값 · time_zone null · version null · saved false (서버는 시간대를 추측하지 않는다)", async () => {
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
      version: null,
    });
    expect(DEFAULT_REPORT_PREFERENCES.saved).toBe(false);
  });

  it("저장한 설정을 version과 함께 그대로 돌려준다", async () => {
    const stored: ReportPreferences = { ...STORED, mode: "daily", quiet_start: null, quiet_end: null, time_zone: "Europe/London", version: 4 };
    expect(await (await handleGetReportPreferences(get(), deps({ stored }).d)).json()).toEqual(stored);
  });

  it("처음 만들기(expected_version null)는 행이 없을 때만, 다음 PUT은 받은 version으로. 조용한 시간 끄기는 둘 다 null", async () => {
    const { d, saved } = deps();
    const created = await handlePutReportPreferences(put(VALID), d);
    expect(created.status).toBe(200);
    const first = await created.json();
    expect(first).toMatchObject({ mode: "both", time_zone: "Asia/Seoul", saved: true, version: 1 });
    expect(first).not.toHaveProperty("expected_version");

    const off = { ...VALID, mode: "meaningful", quiet_start: null, quiet_end: null, respect_focus: false, time_zone: "America/New_York", expected_version: first.version };
    const updated = await handlePutReportPreferences(put(off), d);
    expect(updated.status).toBe(200);
    expect((await updated.json()).version).toBe(2);
    expect(saved).toEqual([VALID, off]);
  });

  it.each([null, 2, 4])("이미 있는데 처음 만들기를 보내거나(다른 Mac이 먼저 만듦) 읽은 version이 맞지 않으면 409이고 덮어쓰지 않는다 (expected_version %s)", async (expected) => {
    const { d, saved } = deps({ stored: STORED });
    const response = await handlePutReportPreferences(put({ ...VALID, time_zone: "Europe/London", expected_version: expected }), d);
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: { code: "conflict", message: "다른 기기에서 먼저 바꿨습니다. 다시 불러와 주세요." } });
    expect(saved).toEqual([]);
    expect((await (await handleGetReportPreferences(get(), d)).json()).time_zone).toBe("Asia/Seoul");
    // 다시 읽은 version으로는 바뀐다
    expect((await handlePutReportPreferences(put({ ...VALID, time_zone: "Europe/London", expected_version: 3 }), d)).status).toBe(200);
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
    ["expected_version이 없다", { expected_version: undefined }],
    ["expected_version 0", { expected_version: 0 }],
    ["모르는 필드 (부분 수정 · 서버 전용 열을 받지 않는다)", { schedule_changed_at: "2026-10-10T00:00:00Z" }],
    ["version을 직접 보낸다", { version: 9 }],
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
