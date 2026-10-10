import { describe, expect, it } from "vitest";

import {
  firstSendableInstant,
  inQuietHours,
  isSupportedTimeZone,
  localInstants,
  localWall,
  nextQuietStart,
  planDailyReport,
  quietNow,
  REPORT_STALE_MS,
  resolveLocalTime,
  type ReportSchedulePrefs,
} from "./schedule";

// 일일 보고 시각 규칙 (schedule.ts 머리 주석 1–6). 기대값은 손으로 계산한 UTC 순간이다:
// 서울 UTC+9 (DST 없음) · 런던 2026-03-29 01:00Z BST 시작, 2026-10-25 01:00Z GMT 복귀 · 뉴욕 2026-03-08 07:00Z EDT 시작, 2026-11-01 06:00Z EST 복귀 ·
// 로스앤젤레스 2026-10 UTC-7.

const LONG_AGO = new Date("2026-01-01T00:00:00Z");

function prefs(overrides: Partial<ReportSchedulePrefs> = {}): ReportSchedulePrefs {
  return {
    mode: "both",
    dailyTime: "08:30",
    quietStart: "22:00",
    quietEnd: "08:00",
    timeZone: "Asia/Seoul",
    createdAt: LONG_AGO,
    scheduleChangedAt: LONG_AGO,
    ...overrides,
  };
}

const at = (iso: string) => new Date(iso);
const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());

/**
 * cron을 stepMinutes마다 돌리는 것처럼 from부터 to까지 계획을 묻고, 보낼 차례면 보낸 것으로 친다 (원장의 마지막 예정 시각을 갱신).
 * prefsAt으로 도중에 설정을 바꿀 수 있고, up이 false인 시각은 job이 멈춘 것이다.
 */
function simulate(options: {
  prefsAt: (now: Date) => ReportSchedulePrefs;
  from: string;
  to: string;
  stepMinutes?: number;
  up?: (now: Date) => boolean;
  last?: Date | null;
}) {
  const sends: { at: string; date: string }[] = [];
  let last = options.last ?? null;
  const step = (options.stepMinutes ?? 5) * 60_000;
  for (let t = Date.parse(options.from); t <= Date.parse(options.to); t += step) {
    const now = new Date(t);
    if (options.up && !options.up(now)) continue;
    const plan = planDailyReport(now, options.prefsAt(now), last);
    if (plan.due) {
      sends.push({ at: now.toISOString(), date: plan.due.reportDate });
      last = plan.due.scheduledAt;
    }
  }
  return sends;
}

describe("시간대 계산", () => {
  it("서울(DST 없음) 08:30은 전날 23:30Z", () => {
    expect(iso(resolveLocalTime("2026-10-10", 8 * 60 + 30, "Asia/Seoul"))).toBe("2026-10-09T23:30:00.000Z");
    expect(localWall(at("2026-10-09T23:30:00Z"), "Asia/Seoul")).toEqual({ date: "2026-10-10", minutes: 510 });
  });

  it("런던은 BST(UTC+1)와 GMT(UTC+0)에서 같은 08:30이 다른 UTC다", () => {
    expect(iso(resolveLocalTime("2026-10-24", 510, "Europe/London"))).toBe("2026-10-24T07:30:00.000Z");
    expect(iso(resolveLocalTime("2026-10-26", 510, "Europe/London"))).toBe("2026-10-26T08:30:00.000Z");
  });

  it("봄 앞당김으로 없는 현지 시각은 시계가 건너뛴 직후(전환 순간) 하나다: 뉴욕 2026-03-08 02:30 → 03:00 EDT, 런던 2026-03-29 01:30 → 02:00 BST", () => {
    expect(localInstants("2026-03-08", 150, "America/New_York").map(iso)).toEqual(["2026-03-08T07:00:00.000Z"]);
    expect(localWall(at("2026-03-08T07:00:00Z"), "America/New_York")).toEqual({ date: "2026-03-08", minutes: 180 });
    expect(localInstants("2026-03-29", 90, "Europe/London").map(iso)).toEqual(["2026-03-29T01:00:00.000Z"]);
  });

  it("가을 되돌림으로 두 번 오는 현지 시각은 둘 다 찾고, 정할 때는 처음 것: 뉴욕 2026-11-01 01:30 EDT · EST", () => {
    expect(localInstants("2026-11-01", 90, "America/New_York").map(iso)).toEqual(["2026-11-01T05:30:00.000Z", "2026-11-01T06:30:00.000Z"]);
    expect(iso(resolveLocalTime("2026-11-01", 90, "America/New_York"))).toBe("2026-11-01T05:30:00.000Z");
  });

  it("자정이 없는 날(산티아고 2026-09-06 00:00 → 01:00)의 하루 시작은 01:00", () => {
    expect(iso(resolveLocalTime("2026-09-06", 0, "America/Santiago"))).toBe("2026-09-06T04:00:00.000Z");
  });

  it("런타임이 아는 IANA 시간대만 쓴다", () => {
    for (const tz of ["Asia/Seoul", "Europe/London", "America/New_York", "America/Argentina/Buenos_Aires", "UTC", "Etc/GMT+9"]) expect(isSupportedTimeZone(tz), tz).toBe(true);
    for (const tz of ["Mars/Base", "Asia/Seol", "", "Not a zone"]) expect(isSupportedTimeZone(tz), tz).toBe(false);
  });
});

describe("조용한 시간", () => {
  it("자정을 넘는 22:00–08:00: 시작은 포함, 끝은 제외", () => {
    expect(inQuietHours(22 * 60, "22:00", "08:00")).toBe(true);
    expect(inQuietHours(23 * 60 + 59, "22:00", "08:00")).toBe(true);
    expect(inQuietHours(0, "22:00", "08:00")).toBe(true);
    expect(inQuietHours(7 * 60 + 59, "22:00", "08:00")).toBe(true);
    expect(inQuietHours(8 * 60, "22:00", "08:00")).toBe(false);
    expect(inQuietHours(21 * 60 + 59, "22:00", "08:00")).toBe(false);
  });

  it("같은 날 안의 창 12:00–14:00", () => {
    expect(inQuietHours(13 * 60, "12:00", "14:00")).toBe(true);
    expect(inQuietHours(14 * 60, "12:00", "14:00")).toBe(false);
    expect(inQuietHours(11 * 60 + 59, "12:00", "14:00")).toBe(false);
  });

  it("끔(null)과 시작 == 끝(빈 창)은 언제나 조용한 시간이 아니다", () => {
    for (let m = 0; m < 24 * 60; m += 15) {
      expect(inQuietHours(m, null, null)).toBe(false);
      expect(inQuietHours(m, "03:00", "03:00")).toBe(false);
    }
  });

  it("조용한 시간 안의 순간은 그 뒤 처음 끝나는 quiet_end로 미룬다 — 앞당기지 않는다 (서울 10-10, 시작 경계 포함 · 끝 경계 제외)", () => {
    const send = (kst: string, q: Partial<ReportSchedulePrefs> = {}) => iso(firstSendableInstant(Date.parse(`${kst}+09:00`), prefs(q)));
    expect(send("2026-10-10T23:00:00")).toBe("2026-10-10T23:00:00.000Z"); // 23:00 → 다음 날 08:00 KST
    expect(send("2026-10-10T22:00:00")).toBe("2026-10-10T23:00:00.000Z"); // 22:00(시작) → 다음 날 08:00 KST
    expect(send("2026-10-10T06:00:00")).toBe("2026-10-09T23:00:00.000Z"); // 06:00 → 같은 날 08:00 KST
    expect(send("2026-10-10T08:00:00")).toBe("2026-10-09T23:00:00.000Z"); // 08:00(끝) → 그대로
    expect(send("2026-10-10T21:59:00")).toBe("2026-10-10T12:59:00.000Z"); // 21:59 → 그대로
    expect(send("2026-10-10T03:00:00", { quietStart: "03:00", quietEnd: "03:00" })).toBe("2026-10-09T18:00:00.000Z");
    expect(send("2026-10-10T03:00:00", { quietStart: null, quietEnd: null })).toBe("2026-10-09T18:00:00.000Z");
  });

  it("nextQuietStart: 다음 조용한 시간 시작 순간 (APNs 만료의 상한). 끔 · 빈 창 · 모르는 시간대는 null", () => {
    expect(iso(nextQuietStart(Date.parse("2026-10-10T01:00:00Z"), prefs()))).toBe("2026-10-10T13:00:00.000Z"); // 10:00 KST → 22:00 KST
    expect(iso(nextQuietStart(Date.parse("2026-10-10T13:30:00Z"), prefs()))).toBe("2026-10-11T13:00:00.000Z"); // 22:30 KST → 다음 날 22:00
    expect(iso(nextQuietStart(Date.parse("2026-10-10T13:00:00Z"), prefs()))).toBe("2026-10-11T13:00:00.000Z"); // 시작 순간 자체는 지난 것으로
    expect(nextQuietStart(Date.parse("2026-10-10T01:00:00Z"), prefs({ quietStart: null, quietEnd: null }))).toBeNull();
    expect(nextQuietStart(Date.parse("2026-10-10T01:00:00Z"), prefs({ quietStart: "03:00", quietEnd: "03:00" }))).toBeNull();
    expect(nextQuietStart(Date.parse("2026-10-10T01:00:00Z"), prefs({ timeZone: "Mars/Base" }))).toBeNull();
    // 런던 GMT 복귀 날(10-25)에도 현지 22:00 = 22:00Z
    expect(iso(nextQuietStart(Date.parse("2026-10-25T12:00:00Z"), prefs({ timeZone: "Europe/London" })))).toBe("2026-10-25T22:00:00.000Z");
    // 뉴욕 되돌림 날 두 번 오는 01:30: 첫 번째가 지났으면 두 번째
    expect(iso(nextQuietStart(Date.parse("2026-11-01T05:35:00Z"), prefs({ timeZone: "America/New_York", quietStart: "01:30", quietEnd: "06:00" })))).toBe("2026-11-01T06:30:00.000Z");
  });

  it("quietNow는 사용자 시간대의 지금 시각으로 본다. 모르는 시간대면 보내지 않도록 조용한 시간으로 친다", () => {
    expect(quietNow(at("2026-10-10T13:30:00Z"), prefs())).toBe(true); // 서울 22:30
    expect(quietNow(at("2026-10-10T13:30:00Z"), prefs({ timeZone: "Europe/London" }))).toBe(false); // 런던 14:30
    expect(quietNow(at("2026-10-10T13:30:00Z"), prefs({ timeZone: "Mars/Base" }))).toBe(true);
  });
});

describe("planDailyReport: 기본 (서울, D06 기본값)", () => {
  it("예정 전에는 다음 시각만, 예정 시각부터 2시간까지 보낼 차례 (경계 포함)", () => {
    const before = planDailyReport(at("2026-10-09T23:29:00Z"), prefs(), null);
    expect(before.due).toBeNull();
    expect(before.next).toEqual({ reportDate: "2026-10-10", at: at("2026-10-09T23:30:00Z") });

    const due = planDailyReport(at("2026-10-09T23:30:00Z"), prefs(), null);
    expect(due.due).toEqual({
      reportDate: "2026-10-10",
      dayStart: at("2026-10-09T15:00:00Z"),
      scheduledAt: at("2026-10-09T23:30:00Z"),
      sendAt: at("2026-10-09T23:30:00Z"),
      expiresAt: at("2026-10-10T01:30:00Z"),
    });
    expect(due.next).toEqual({ reportDate: "2026-10-10", at: at("2026-10-09T23:30:00Z") });
    expect(planDailyReport(at("2026-10-10T01:30:00Z"), prefs(), null).due?.reportDate).toBe("2026-10-10");
    expect(REPORT_STALE_MS).toBe(2 * 60 * 60_000);
  });

  it("2시간이 지나면 그 날은 보내지 않고 다음 날을 기다린다", () => {
    const late = planDailyReport(at("2026-10-10T01:31:00Z"), prefs(), null);
    expect(late.due).toBeNull();
    expect(late.next).toEqual({ reportDate: "2026-10-11", at: at("2026-10-10T23:30:00Z") });
  });

  it("하루에 하나: 원장에 오늘 예정된 보고가 있으면 오늘은 보내지 않는다", () => {
    const plan = planDailyReport(at("2026-10-09T23:35:00Z"), prefs(), at("2026-10-09T23:30:00Z"));
    expect(plan.due).toBeNull();
    expect(plan.next?.reportDate).toBe("2026-10-11");
  });

  it("모드 daily는 both와 같은 일정, meaningful은 일일 보고가 없다", () => {
    expect(planDailyReport(at("2026-10-09T23:30:00Z"), prefs({ mode: "daily" }), null).due?.reportDate).toBe("2026-10-10");
    expect(planDailyReport(at("2026-10-09T23:30:00Z"), prefs({ mode: "meaningful" }), null)).toEqual({ due: null, next: null });
  });

  it("런타임이 모르는 시간대면 일정을 만들지 않는다 (추측하지 않는다)", () => {
    expect(planDailyReport(at("2026-10-09T23:30:00Z"), prefs({ timeZone: "Mars/Base" }), null)).toEqual({ due: null, next: null });
  });

  it("서울 일주일: 매일 08:30 KST(23:30Z)에 한 번씩", () => {
    const sends = simulate({ prefsAt: () => prefs(), from: "2026-10-09T15:00:00Z", to: "2026-10-16T14:55:00Z" });
    expect(sends).toEqual(
      ["10", "11", "12", "13", "14", "15", "16"].map((day) => ({
        date: `2026-10-${day}`,
        at: new Date(Date.parse(`2026-10-${day}T08:30:00+09:00`)).toISOString(),
      })),
    );
  });

  it("런던: BST에서 GMT로 바뀌는 주에도 현지 08:30에 하루 한 번 (07:30Z → 08:30Z)", () => {
    const sends = simulate({ prefsAt: () => prefs({ timeZone: "Europe/London" }), from: "2026-10-23T23:00:00Z", to: "2026-10-26T22:55:00Z" });
    expect(sends).toEqual([
      { date: "2026-10-24", at: "2026-10-24T07:30:00.000Z" },
      { date: "2026-10-25", at: "2026-10-25T08:30:00.000Z" },
      { date: "2026-10-26", at: "2026-10-26T08:30:00.000Z" },
    ]);
  });
});

describe("planDailyReport: DST", () => {
  const ny = (overrides: Partial<ReportSchedulePrefs> = {}) => prefs({ timeZone: "America/New_York", quietStart: null, quietEnd: null, ...overrides });

  it("봄 앞당김(뉴욕 2026-03-08): 없는 02:30 보고는 그 뒤 첫 실제 시각 03:00 EDT(07:00Z)에 한 번", () => {
    const plan = planDailyReport(at("2026-03-08T07:00:00Z"), ny({ dailyTime: "02:30" }), at("2026-03-07T07:30:00Z"));
    expect(plan.due).toMatchObject({ reportDate: "2026-03-08", scheduledAt: at("2026-03-08T07:00:00Z") });
    expect(planDailyReport(at("2026-03-08T06:59:00Z"), ny({ dailyTime: "02:30" }), at("2026-03-07T07:30:00Z")).due).toBeNull();

    const sends = simulate({ prefsAt: () => ny({ dailyTime: "02:30" }), from: "2026-03-07T05:00:00Z", to: "2026-03-10T04:55:00Z" });
    expect(sends).toEqual([
      { date: "2026-03-07", at: "2026-03-07T07:30:00.000Z" },
      { date: "2026-03-08", at: "2026-03-08T07:00:00.000Z" },
      { date: "2026-03-09", at: "2026-03-09T06:30:00.000Z" },
    ]);
  });

  it("가을 되돌림(뉴욕 2026-11-01): 두 번 오는 01:30 중 처음(EDT 05:30Z)에만, 두 번째 01:30(EST 06:30Z)에는 보내지 않는다", () => {
    const daily = ny({ dailyTime: "01:30" });
    const second = planDailyReport(at("2026-11-01T06:30:00Z"), daily, at("2026-11-01T05:30:00Z"));
    expect(second.due).toBeNull();
    expect(second.next).toEqual({ reportDate: "2026-11-02", at: at("2026-11-02T06:30:00Z") });

    const sends = simulate({ prefsAt: () => daily, from: "2026-10-31T04:00:00Z", to: "2026-11-02T04:55:00Z" });
    expect(sends).toEqual([
      { date: "2026-10-31", at: "2026-10-31T05:30:00.000Z" },
      { date: "2026-11-01", at: "2026-11-01T05:30:00.000Z" },
    ]);
  });

  it("조용한 시간으로 미룬 보고의 quiet_end가 봄 앞당김으로 없는 시각(뉴욕 22:00–02:30, 2026-03-08)이면 시계가 건너뛴 직후 03:00 EDT에 한 번", () => {
    const p = ny({ dailyTime: "23:00", quietStart: "22:00", quietEnd: "02:30" });
    const sends = simulate({ prefsAt: () => p, from: "2026-03-07T05:00:00Z", to: "2026-03-09T04:55:00Z", last: at("2026-03-07T04:00:00Z") });
    expect(sends).toEqual([
      { date: "2026-03-07", at: "2026-03-08T07:00:00.000Z" }, // 명목 03-07 23:00 EST(04:00Z) → 03-08 03:00 EDT
    ]);
    expect(planDailyReport(at("2026-03-08T07:00:00Z"), p, at("2026-03-07T04:00:00Z")).due).toMatchObject({
      reportDate: "2026-03-07",
      scheduledAt: at("2026-03-08T04:00:00Z"),
      sendAt: at("2026-03-08T07:00:00Z"),
    });
  });

  it("조용한 시간으로 미룬 보고의 quiet_end가 가을 되돌림으로 두 번 오는 시각(뉴욕 22:00–01:30, 2026-11-01)이면 처음 01:30 EDT에 한 번", () => {
    const p = ny({ dailyTime: "23:00", quietStart: "22:00", quietEnd: "01:30" });
    const sends = simulate({ prefsAt: () => p, from: "2026-10-31T04:00:00Z", to: "2026-11-02T08:55:00Z", last: at("2026-10-31T03:00:00Z") });
    expect(sends).toEqual([
      { date: "2026-10-31", at: "2026-11-01T05:30:00.000Z" }, // 명목 10-31 23:00 EDT(03:00Z) → 11-01 01:30 EDT
      { date: "2026-11-01", at: "2026-11-02T06:30:00.000Z" }, // 명목 11-01 23:00 EST(04:00Z) → 11-02 01:30 EST
    ]);
  });

  it("되돌림 날 job이 처음 01:30을 놓치면 두 번째 01:30(1시간 늦음, 창 안)에 한 번 보낸다", () => {
    const sends = simulate({
      prefsAt: () => ny({ dailyTime: "01:30" }),
      from: "2026-11-01T04:00:00Z",
      to: "2026-11-01T23:55:00Z",
      up: (now) => now >= at("2026-11-01T06:30:00Z"),
    });
    expect(sends).toEqual([{ date: "2026-11-01", at: "2026-11-01T06:30:00.000Z" }]);
  });
});

describe("planDailyReport: 조용한 시간", () => {
  it("보고 시각이 자정을 넘는 조용한 시간 안(23:00, 22:00–08:00)이면 D 보고는 D+1 08:00에, 날짜마다 한 번, 명목 시각보다 앞당기지 않는다", () => {
    const p = prefs({ dailyTime: "23:00" });
    const sends = simulate({ prefsAt: () => p, from: "2026-10-09T15:00:00Z", to: "2026-10-12T14:55:00Z" });
    expect(sends.map((s) => [s.date, localWall(at(s.at), "Asia/Seoul").date, localWall(at(s.at), "Asia/Seoul").minutes])).toEqual([
      ["2026-10-09", "2026-10-10", 480],
      ["2026-10-10", "2026-10-11", 480],
      ["2026-10-11", "2026-10-12", 480],
    ]);
    for (const send of sends) expect(Date.parse(send.at), send.date).toBeGreaterThan(Date.parse(`${send.date}T23:00:00+09:00`));
  });

  it("재현(리뷰): 10-10 07:00 KST에 만든 daily 23:00 설정은 10-10 08:00에 보내지 않고, 10-10 보고는 10-11 08:00 KST에", () => {
    const created = at("2026-10-09T22:00:00Z");
    const p = prefs({ mode: "daily", dailyTime: "23:00", createdAt: created, scheduleChangedAt: created });
    const plan = planDailyReport(at("2026-10-09T23:00:00Z"), p, null);
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-10", at: at("2026-10-10T23:00:00Z") });
    expect(planDailyReport(at("2026-10-10T23:00:00Z"), p, null).due).toEqual({
      reportDate: "2026-10-10",
      dayStart: at("2026-10-09T15:00:00Z"),
      scheduledAt: at("2026-10-10T14:00:00Z"), // 명목 10-10 23:00 KST
      sendAt: at("2026-10-10T23:00:00Z"), // 10-11 08:00 KST
      expiresAt: at("2026-10-11T01:00:00Z"),
    });
  });

  it("보고 시각이 조용한 시간 시작(22:00)과 같으면 D+1 08:00으로, 끝(08:00)과 같으면 그날 08:00 그대로", () => {
    // 22:00: 10-10 08:00 KST 실행에서 보낼 것은 10-09 보고(명목 10-09 22:00)
    expect(planDailyReport(at("2026-10-09T23:00:00Z"), prefs({ dailyTime: "22:00" }), null).due).toMatchObject({
      reportDate: "2026-10-09",
      scheduledAt: at("2026-10-09T13:00:00Z"),
      sendAt: at("2026-10-09T23:00:00Z"),
    });
    // 10-10 보고는 10-10 22:00 KST가 아니라 10-11 08:00 KST
    expect(planDailyReport(at("2026-10-10T13:00:00Z"), prefs({ dailyTime: "22:00" }), at("2026-10-09T13:00:00Z")).next).toEqual({
      reportDate: "2026-10-10",
      at: at("2026-10-10T23:00:00Z"),
    });
    expect(planDailyReport(at("2026-10-09T23:00:00Z"), prefs({ dailyTime: "08:00" }), null).due).toMatchObject({
      reportDate: "2026-10-10",
      scheduledAt: at("2026-10-09T23:00:00Z"),
      sendAt: at("2026-10-09T23:00:00Z"),
    });
  });

  it("새 설정의 07:00(조용한 시간 안): 07:00 전에 만들면 그날 08:00에, 07:00 뒤에 만들면 명목 시각이 저장 전이라 다음 날 08:00", () => {
    const before = at("2026-10-09T21:30:00Z"); // 06:30 KST
    const p1 = prefs({ dailyTime: "07:00", createdAt: before, scheduleChangedAt: before });
    expect(planDailyReport(at("2026-10-09T23:00:00Z"), p1, null).due).toMatchObject({ reportDate: "2026-10-10", sendAt: at("2026-10-09T23:00:00Z") });
    const after = at("2026-10-09T22:30:00Z"); // 07:30 KST
    const p2 = prefs({ dailyTime: "07:00", createdAt: after, scheduleChangedAt: after });
    const plan = planDailyReport(at("2026-10-09T23:00:00Z"), p2, null);
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-11", at: at("2026-10-10T23:00:00Z") });
  });

  it("미룬 보고 다음 날의 정시 보고: 23:00 → 21:00으로 바꾸면 D 보고(D+1 08:00)와 D+1 보고(21:00)가 하나씩 (잃지도 겹치지도 않는다)", () => {
    const late = prefs({ dailyTime: "23:00" });
    const early = prefs({ dailyTime: "21:00", scheduleChangedAt: at("2026-10-11T00:00:00Z") }); // 10-11 09:00 KST에 바꿈
    const sends = simulate({
      prefsAt: (now) => (now < at("2026-10-11T00:00:00Z") ? late : early),
      from: "2026-10-10T15:00:00Z",
      to: "2026-10-12T14:55:00Z",
      last: at("2026-10-09T14:00:00Z"),
    });
    expect(sends.map((s) => [s.date, s.at])).toEqual([
      ["2026-10-10", "2026-10-10T23:00:00.000Z"], // 10-10 보고: 10-11 08:00 KST
      ["2026-10-11", "2026-10-11T12:00:00.000Z"], // 10-11 보고: 10-11 21:00 KST
      ["2026-10-12", "2026-10-12T12:00:00.000Z"],
    ]);
  });

  it("같은 날 안의 창(12:00–14:00)에 든 13:00은 14:00에", () => {
    const plan = planDailyReport(at("2026-10-10T04:00:00Z"), prefs({ dailyTime: "13:00", quietStart: "12:00", quietEnd: "14:00" }), null);
    expect(plan.next).toEqual({ reportDate: "2026-10-10", at: at("2026-10-10T05:00:00Z") });
  });

  it("시작 == 끝(03:00–03:00)은 조용한 시간이 없는 것과 같다: 03:00 보고가 03:00에", () => {
    const plan = planDailyReport(at("2026-10-09T18:00:00Z"), prefs({ dailyTime: "03:00", quietStart: "03:00", quietEnd: "03:00" }), null);
    expect(plan.due?.scheduledAt).toEqual(at("2026-10-09T18:00:00Z"));
  });

  it("조용한 시간을 끄면(null) 23:30 보고가 23:30에", () => {
    const plan = planDailyReport(at("2026-10-10T14:30:00Z"), prefs({ dailyTime: "23:30", quietStart: null, quietEnd: null }), null);
    expect(plan.due).toMatchObject({ reportDate: "2026-10-10", scheduledAt: at("2026-10-10T14:30:00Z") });
  });

  it("늦은 보고도 조용한 시간에는 보내지 않고, 끝났을 때 창이 닫혀 있으면 그 날은 건너뛴다 (21:30 보고, job 21:25–22:30 멈춤)", () => {
    const p = prefs({ dailyTime: "21:30" });
    const down = (now: Date) => !(now >= at("2026-10-10T12:25:00Z") && now < at("2026-10-10T13:30:00Z"));
    expect(planDailyReport(at("2026-10-10T13:30:00Z"), p, at("2026-10-09T12:30:00Z")).due).toBeNull(); // 22:30 KST: 조용한 시간
    const sends = simulate({ prefsAt: () => p, from: "2026-10-08T15:00:00Z", to: "2026-10-11T14:55:00Z", up: down });
    expect(sends).toEqual([
      { date: "2026-10-09", at: "2026-10-09T12:30:00.000Z" },
      { date: "2026-10-11", at: "2026-10-11T12:30:00.000Z" },
    ]);
  });
});

describe("planDailyReport: 밀린 보고를 몰아 보내지 않는다", () => {
  it("job이 사흘 멈췄다 09:10 KST에 돌아오면 그 날 보고 하나만 (지난 날짜 0)", () => {
    const sends = simulate({
      prefsAt: () => prefs(),
      from: "2026-10-09T15:00:00Z",
      to: "2026-10-13T14:55:00Z",
      up: (now) => now >= at("2026-10-13T00:10:00Z"),
      last: at("2026-10-08T23:30:00Z"),
    });
    expect(sends).toEqual([{ date: "2026-10-13", at: "2026-10-13T00:10:00.000Z" }]);
  });

  it("15:00 KST에 돌아오면 오늘 보고는 늦어서 보내지 않고 내일 08:30을 기다린다", () => {
    const plan = planDailyReport(at("2026-10-13T06:00:00Z"), prefs(), at("2026-10-08T23:30:00Z"));
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-14", at: at("2026-10-13T23:30:00Z") });
  });

  it("자정 직전 보고(23:50, 조용한 시간 끔)를 자정 뒤 실행이 잡아도 날짜마다 정확히 한 번 (어제 후보), 하루도 빠지지 않는다", () => {
    const sends = simulate({
      prefsAt: () => prefs({ dailyTime: "23:50", quietStart: null, quietEnd: null }),
      from: "2026-10-09T15:00:00Z",
      to: "2026-10-14T15:00:00Z",
      stepMinutes: 15,
      last: at("2026-10-09T14:50:00Z"),
    });
    expect(sends.map((s) => s.date)).toEqual(["2026-10-10", "2026-10-11", "2026-10-12", "2026-10-13", "2026-10-14"]);
    // 23:50 다음 실행은 다음 날 00:00 KST(15:00Z)
    expect(sends[0].at).toBe("2026-10-10T15:00:00.000Z");
  });
});

describe("planDailyReport: 설정 · 시간대를 바꿀 때 (두 번 보내지 않고, 하루를 잃지 않는다)", () => {
  it("오늘 이미 보냈으면 보고 시각을 바꿔도 오늘은 다시 보내지 않는다", () => {
    const changed = prefs({ dailyTime: "15:00", scheduleChangedAt: at("2026-10-10T01:00:00Z") });
    const plan = planDailyReport(at("2026-10-10T06:00:00Z"), changed, at("2026-10-09T23:30:00Z"));
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-11", at: at("2026-10-11T06:00:00Z") });
  });

  it("아직 안 보냈는데 바꾼 시각이 이미 지났으면 바꾼 뒤 2시간 안에 보낸다 (15:00 KST에 08:30으로)", () => {
    const changed = prefs({ dailyTime: "08:30", scheduleChangedAt: at("2026-10-10T06:00:00Z") });
    const plan = planDailyReport(at("2026-10-10T06:05:00Z"), changed, at("2026-10-08T23:30:00Z"));
    expect(plan.due).toEqual({
      reportDate: "2026-10-10",
      dayStart: at("2026-10-09T15:00:00Z"),
      scheduledAt: at("2026-10-09T23:30:00Z"),
      sendAt: at("2026-10-09T23:30:00Z"),
      expiresAt: at("2026-10-10T08:00:00Z"),
    });
    expect(planDailyReport(at("2026-10-10T08:01:00Z"), changed, at("2026-10-08T23:30:00Z")).due).toBeNull();
  });

  it("뒤로 미루면 새 시각에 한 번 (09:00 KST에 08:30 → 11:00)", () => {
    const changed = prefs({ dailyTime: "11:00", scheduleChangedAt: at("2026-10-10T00:00:00Z") });
    const sends = simulate({ prefsAt: () => changed, from: "2026-10-10T00:00:00Z", to: "2026-10-10T14:55:00Z", last: at("2026-10-08T23:30:00Z") });
    expect(sends).toEqual([{ date: "2026-10-10", at: "2026-10-10T02:00:00.000Z" }]);
  });

  it("모드를 meaningful에서 both로 바꾸면 오늘 보고(아직 없음)를 바로 보낸다", () => {
    const changed = prefs({ scheduleChangedAt: at("2026-10-10T06:00:00Z") });
    expect(planDailyReport(at("2026-10-10T06:00:00Z"), changed, at("2026-10-01T23:30:00Z")).due?.reportDate).toBe("2026-10-10");
  });

  it("처음 만든 설정은 이미 지난 오늘 시각의 보고를 보내지 않는다 (15:00 KST에 만듦 → 내일 08:30)", () => {
    const created = at("2026-10-10T06:00:00Z");
    const plan = planDailyReport(at("2026-10-10T06:00:00Z"), prefs({ createdAt: created, scheduleChangedAt: created }), null);
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-11", at: at("2026-10-10T23:30:00Z") });
    const early = at("2026-10-09T23:00:00Z");
    expect(planDailyReport(at("2026-10-09T23:30:00Z"), prefs({ createdAt: early, scheduleChangedAt: early }), null).due?.reportDate).toBe("2026-10-10");
  });

  it("처음 저장한 뒤 일정을 바꾸면 처음 저장 예외 대신 '오늘을 잃지 않는다'를 따른다 (08:00 저장 → 08:10에 07:55로 → 바로)", () => {
    const created = at("2026-10-09T23:00:00Z"); // 08:00 KST
    // 조용한 시간을 끈다 (켜져 있으면 07:55는 08:00으로 미뤄진다)
    const untouched = prefs({ dailyTime: "07:55", quietStart: null, quietEnd: null, createdAt: created, scheduleChangedAt: created });
    expect(planDailyReport(at("2026-10-09T23:10:00Z"), untouched, null).due).toBeNull(); // 바꾸지 않았으면 처음 저장 예외
    const changed = prefs({ dailyTime: "07:55", quietStart: null, quietEnd: null, createdAt: created, scheduleChangedAt: at("2026-10-09T23:10:00Z") });
    expect(planDailyReport(at("2026-10-09T23:10:00Z"), changed, null).due).toEqual({
      reportDate: "2026-10-10",
      dayStart: at("2026-10-09T15:00:00Z"),
      scheduledAt: at("2026-10-09T22:55:00Z"),
      sendAt: at("2026-10-09T22:55:00Z"),
      expiresAt: at("2026-10-10T01:10:00Z"),
    });
  });

  it("늦게 켜면 같은 달력 날에 두 번 받을 수 있다 (조용한 시간 끔, 23:30에 켬 → 00:10 그날 보고 · 08:30 다음 날 보고)", () => {
    // 10-10 23:30 KST(14:30Z)에 meaningful → both. 23:30 실행이 실패하고 다음 실행이 00:10 KST(15:10Z)
    const p = prefs({ quietStart: null, quietEnd: null, scheduleChangedAt: at("2026-10-10T14:30:00Z") });
    const sends = simulate({
      prefsAt: () => p,
      from: "2026-10-10T14:30:00Z",
      to: "2026-10-11T14:55:00Z",
      up: (now) => now >= at("2026-10-10T15:10:00Z"),
      last: at("2026-10-08T23:30:00Z"),
    });
    expect(sends).toEqual([
      { date: "2026-10-10", at: "2026-10-10T15:10:00.000Z" },
      { date: "2026-10-11", at: "2026-10-10T23:30:00.000Z" },
    ]);
  });

  it("한 달력 날에 보고가 없는 경우 A: D 07:00 KST에 08:30 → 23:00(조용한 시간 22–08)으로 바꾸면 D 보고는 D+1 08:00이라 달력 D에는 없다", () => {
    const p = prefs({ dailyTime: "23:00", scheduleChangedAt: at("2026-10-09T22:00:00Z") });
    const sends = simulate({ prefsAt: () => p, from: "2026-10-09T22:00:00Z", to: "2026-10-11T14:55:00Z", last: at("2026-10-08T23:30:00Z") });
    expect(sends).toEqual([{ date: "2026-10-10", at: "2026-10-10T23:00:00.000Z" }]); // 10-11 08:00 KST
    expect(sends.filter((s) => localWall(at(s.at), "Asia/Seoul").date === "2026-10-10")).toEqual([]);
  });

  it("한 달력 날에 보고가 없는 경우 B: D 08:30 보고를 보낸 뒤 23:00으로 바꾸면 D+1 보고는 D+2 08:00이라 달력 D+1에는 없다", () => {
    const p = prefs({ dailyTime: "23:00", scheduleChangedAt: at("2026-10-10T00:00:00Z") });
    const sends = simulate({ prefsAt: () => p, from: "2026-10-10T00:00:00Z", to: "2026-10-12T00:00:00Z", last: at("2026-10-09T23:30:00Z") });
    expect(sends).toEqual([{ date: "2026-10-11", at: "2026-10-11T23:00:00.000Z" }]); // 10-12 08:00 KST
    expect(sends.filter((s) => localWall(at(s.at), "Asia/Seoul").date === "2026-10-11")).toEqual([]);
  });

  it("한 달력 날에 보고가 없는 경우 C: daily 23:00 · 22–08로 D+1 08:00에 갈 D 보고가, D+1 02:00 KST에 조용한 시간을 끄면 사라진다", () => {
    const p = prefs({ dailyTime: "23:00", quietStart: null, quietEnd: null, scheduleChangedAt: at("2026-10-10T17:00:00Z") });
    const sends = simulate({ prefsAt: () => p, from: "2026-10-10T17:00:00Z", to: "2026-10-11T15:00:00Z", last: at("2026-10-09T14:00:00Z") });
    // 10-10 보고는 명목 23:00 KST(14:00Z)로 돌아가 이미 창이 닫혔고, 바꾼 때(10-11)는 그 sendAt(10-10)과 다른 날이라 다시 열리지 않는다
    expect(sends).toEqual([{ date: "2026-10-11", at: "2026-10-11T14:00:00.000Z" }]);
  });

  it("조용한 시간에 바꾸면 끝났을 때 창이 닫혀 그 날은 건너뛴다 (23:00 KST에 바꿈 → 다음 날 08:30)", () => {
    const changed = prefs({ dailyTime: "09:00", scheduleChangedAt: at("2026-10-10T14:00:00Z") });
    const plan = planDailyReport(at("2026-10-10T14:00:00Z"), changed, at("2026-10-08T23:30:00Z"));
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-11", at: at("2026-10-11T00:00:00Z") });
  });

  it("서울 보고 뒤 런던으로: 런던 같은 날에는 다시 오지 않고 런던 다음 날 08:30", () => {
    // 서울 10-10 08:30 = 10-09 23:30Z = 런던 10-10 00:30. 런던 10-10 01:00(00:00Z)에 시간대를 바꿈
    const london = prefs({ timeZone: "Europe/London", scheduleChangedAt: at("2026-10-10T00:00:00Z") });
    const sends = simulate({ prefsAt: () => london, from: "2026-10-10T00:00:00Z", to: "2026-10-11T22:55:00Z", last: at("2026-10-09T23:30:00Z") });
    expect(sends).toEqual([{ date: "2026-10-11", at: "2026-10-11T07:30:00.000Z" }]);
  });

  it("런던 보고 전에 서울로: 서울 오늘 보고가 아직 없으니 바꾼 뒤 바로 (하루를 잃지 않는다)", () => {
    // 런던 10-09 08:30(07:30Z) 보고 뒤, 런던 10-10 07:00(06:00Z) = 서울 15:00에 바꿈
    const seoul = prefs({ scheduleChangedAt: at("2026-10-10T06:00:00Z") });
    expect(planDailyReport(at("2026-10-10T06:05:00Z"), seoul, at("2026-10-09T07:30:00Z")).due?.reportDate).toBe("2026-10-10");
  });

  it("서쪽(서울 → 로스앤젤레스)으로 날짜가 되돌아가도 LA의 그 날은 이미 보낸 날로 치고, LA 다음 날은 잃지 않는다", () => {
    // 서울 10-11 08:30 = 10-10 23:30Z = LA 10-10 16:30. LA 10-10 17:00(10-11 00:00Z)에 바꿈
    const la = prefs({ timeZone: "America/Los_Angeles", scheduleChangedAt: at("2026-10-11T00:00:00Z") });
    const plan = planDailyReport(at("2026-10-11T00:05:00Z"), la, at("2026-10-10T23:30:00Z"));
    expect(plan.due).toBeNull();
    expect(plan.next).toEqual({ reportDate: "2026-10-11", at: at("2026-10-11T15:30:00Z") });
  });

  it("동쪽(로스앤젤레스 → 서울)으로: LA 보고가 이미 서울 그 날 00:30에 갔으면 서울 그 날은 다시 보내지 않는다", () => {
    // LA 10-10 08:30 = 10-10 15:30Z = 서울 10-11 00:30. 서울 10-11 01:00(10-10 16:00Z)에 바꿈
    const seoul = prefs({ scheduleChangedAt: at("2026-10-10T16:00:00Z") });
    const sends = simulate({ prefsAt: () => seoul, from: "2026-10-10T16:00:00Z", to: "2026-10-12T14:55:00Z", last: at("2026-10-10T15:30:00Z") });
    expect(sends).toEqual([{ date: "2026-10-12", at: "2026-10-11T23:30:00.000Z" }]);
  });
});
