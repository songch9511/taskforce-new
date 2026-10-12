import { describe, expect, it } from "vitest";

import { localDay, validTimeZone } from "./day";

// 비긴급 제안의 "하루"는 사용자 현지 달력 날짜다 (A09: timezone 경계). 시계는 고정한다. 실제 시스템 시계 · 시간대는 쓰지 않는다.

describe("localDay: 같은 순간이 시간대마다 다른 하루", () => {
  const instant = new Date("2026-10-12T16:30:00Z");
  it.each([
    ["UTC", "2026-10-12"],
    ["Asia/Seoul", "2026-10-13"], // +09:00 → 다음 날 01:30
    ["America/Los_Angeles", "2026-10-12"], // -07:00 → 09:30
    ["Pacific/Kiritimati", "2026-10-13"], // +14:00
    ["Pacific/Pago_Pago", "2026-10-12"], // -11:00
  ])("%s → %s", (zone, day) => {
    expect(localDay(instant, zone)).toBe(day);
  });

  it("자정 경계: 현지 23:59:59.999와 00:00:00.000은 서로 다른 하루다", () => {
    expect(localDay(new Date("2026-10-12T14:59:59.999Z"), "Asia/Seoul")).toBe("2026-10-12");
    expect(localDay(new Date("2026-10-12T15:00:00.000Z"), "Asia/Seoul")).toBe("2026-10-13");
  });

  it("DST 시작일(23시간짜리 하루)에도 현지 날짜는 하나다: 뉴욕 2026-03-08", () => {
    // 02:00 EST → 03:00 EDT. 하루는 23시간이지만 달력 날짜는 03-08 하나, 다음 날 00:00부터 03-09
    expect(localDay(new Date("2026-03-08T05:00:00Z"), "America/New_York")).toBe("2026-03-08"); // 00:00 EST
    expect(localDay(new Date("2026-03-08T06:59:59Z"), "America/New_York")).toBe("2026-03-08"); // 01:59:59 EST
    expect(localDay(new Date("2026-03-08T07:00:00Z"), "America/New_York")).toBe("2026-03-08"); // 03:00 EDT (02시는 없다)
    expect(localDay(new Date("2026-03-09T03:59:59Z"), "America/New_York")).toBe("2026-03-08"); // 23:59:59 EDT
    expect(localDay(new Date("2026-03-09T04:00:00Z"), "America/New_York")).toBe("2026-03-09");
  });

  it("DST 끝일(25시간짜리 하루): 같은 01시가 두 번 있어도 날짜는 하나이고, 24시간 뒤라고 다음 날이 아니다: 뉴욕 2026-11-01", () => {
    expect(localDay(new Date("2026-11-01T04:00:00Z"), "America/New_York")).toBe("2026-11-01"); // 00:00 EDT
    expect(localDay(new Date("2026-11-01T05:30:00Z"), "America/New_York")).toBe("2026-11-01"); // 01:30 EDT
    expect(localDay(new Date("2026-11-01T06:30:00Z"), "America/New_York")).toBe("2026-11-01"); // 01:30 EST (두 번째 01:30)
    // 첫 순간에서 24시간 뒤(2026-11-02T04:00Z)는 아직 11-01 23:00 EST다 — 하루는 25시간이다
    expect(localDay(new Date("2026-11-02T04:00:00Z"), "America/New_York")).toBe("2026-11-01");
    expect(localDay(new Date("2026-11-02T05:00:00Z"), "America/New_York")).toBe("2026-11-02");
  });

  it("반 시간 오프셋 DST(Lord Howe 30분 이동)와 UTC+5:45(카트만두)도 현지 날짜대로", () => {
    // 2026-10-04 02:00 LHST(+10:30) → 02:30 LHDT(+11:00): 하루는 23.5시간
    expect(localDay(new Date("2026-10-03T13:29:59Z"), "Australia/Lord_Howe")).toBe("2026-10-03"); // 23:59:59 LHST (전날)
    expect(localDay(new Date("2026-10-03T13:30:00Z"), "Australia/Lord_Howe")).toBe("2026-10-04"); // 00:00 LHST
    expect(localDay(new Date("2026-10-03T15:29:59Z"), "Australia/Lord_Howe")).toBe("2026-10-04"); // 01:59:59 LHST
    expect(localDay(new Date("2026-10-03T15:30:00Z"), "Australia/Lord_Howe")).toBe("2026-10-04"); // 02:30 LHDT (02:00–02:30은 없다)
    expect(localDay(new Date("2026-10-04T12:59:59Z"), "Australia/Lord_Howe")).toBe("2026-10-04"); // 23:59:59 LHDT (+11:00)
    expect(localDay(new Date("2026-10-04T13:00:00Z"), "Australia/Lord_Howe")).toBe("2026-10-05"); // 00:00 LHDT
    expect(localDay(new Date("2026-10-12T18:14:59Z"), "Asia/Kathmandu")).toBe("2026-10-12"); // 23:59:59 +05:45
    expect(localDay(new Date("2026-10-12T18:15:00Z"), "Asia/Kathmandu")).toBe("2026-10-13");
  });

  it("연말 · 윤일 경계", () => {
    expect(localDay(new Date("2026-12-31T14:59:59Z"), "Asia/Seoul")).toBe("2026-12-31");
    expect(localDay(new Date("2026-12-31T15:00:00Z"), "Asia/Seoul")).toBe("2027-01-01");
    expect(localDay(new Date("2028-02-28T15:00:00Z"), "Asia/Seoul")).toBe("2028-02-29");
  });

  it("모르는 · 잘못된 시간대는 null이다 (추측하지 않는다). 잘못된 시각도", () => {
    for (const zone of ["", "Mars/Olympus", "Not A Zone", "KST", "+09:00", "a".repeat(80)]) {
      expect(localDay(instant, zone), zone).toBeNull();
      expect(validTimeZone(zone), zone).toBe(false);
    }
    expect(localDay(new Date("nope"), "UTC")).toBeNull();
    expect(validTimeZone("Asia/Seoul")).toBe(true);
  });

  it("시스템 시간대 · 시계와 무관하다: 같은 입력은 언제나 같은 날짜", () => {
    const before = process.env.TZ;
    try {
      for (const tz of ["UTC", "Asia/Tokyo", "America/Los_Angeles"]) {
        process.env.TZ = tz;
        expect(localDay(instant, "Asia/Seoul")).toBe("2026-10-13");
      }
    } finally {
      if (before === undefined) delete process.env.TZ;
      else process.env.TZ = before;
    }
  });
});
