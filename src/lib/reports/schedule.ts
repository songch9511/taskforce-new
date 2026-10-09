// 일일 보고 시각 계산 (0.2.0 H1). 순수 함수: 시각(now) · 설정 · 원장의 마지막 예정 시각만 받는다 — DB · 네트워크 · 시계 읽기 없음.
// 시간대 계산은 런타임 Intl(IANA tz 데이터)로 한다. 규칙 요약은 docs/FEATURE_MAP.md 3-8 "일일 보고 시각 규칙".
//
// 규칙
// 1. 예정 시각: 현지 날짜 D의 daily_time. daily_time이 조용한 시간 안이면 그 날의 quiet_end로 미룬다 (시각만 옮긴다, 날짜는 D 그대로).
// 2. DST: 없는 현지 시각(봄 앞당김)은 그 뒤 첫 실제 시각(시계가 건너뛴 직후)에 보낸다. 두 번 오는 현지 시각(가을 되돌림)은 처음 것.
//    어느 쪽이든 그 날 보고는 한 번이다 (아래 4).
// 3. 늦은 보고: 예정 시각에서 REPORT_STALE_MS(2시간)가 지나면 그 날은 보내지 않는다. 지난 날짜를 몰아서 보내지 않는다 —
//    후보는 어제 · 오늘 · 다음 이틀뿐이고(어제는 자정 직전 예정이 자정 뒤 실행에 걸릴 때만), 한 번에 하나만 고른다.
//    조용한 시간에는 보내지 않는다: 늦어서 조용한 시간에 걸리면 끝날 때까지 기다리고, 그 사이 창이 닫히면 그 날은 건너뛴다.
// 4. 하루에 하나: 원장에 지금 시간대의 현지 날짜 D가 시작한 뒤(또는 더 뒤)로 예정된 보고가 있으면 D는 보내지 않는다.
//    날짜는 "그 보고의 예정 시각이 지금 시간대로 어느 날인가"로 센다. 그래서 시간대를 바꿔도 같은 현지 날에 두 번 오지 않고,
//    서쪽으로 옮겨 날짜가 되돌아가도 하루를 잃지 않는다. 원장 확인은 DB 함수 claim_report_delivery가 사용자 잠금 안에서 다시 한다.
// 5. 설정 · 시간대를 바꾸면 남은 일정만 새로 계산한다. 이미 보낸 날은 다시 보내지 않는다(4).
//    오늘 보고가 아직 안 갔는데 바뀐 예정 시각이 이미 지났으면, 바꾼 시각부터 REPORT_STALE_MS 안에 보낸다 (바꿔서 오늘을 잃지 않는다).
//    처음 만든 설정은 예외다: 설정이 생기기 전 예정 시각의 보고는 보내지 않는다 (켜자마자 "오늘 보고"가 오지 않는다).
// 6. 모드 meaningful은 일일 보고가 없다. 시간대를 런타임이 모르면(Intl 오류) 아무 일정도 만들지 않는다.

import type { ReportMode } from "@/lib/api/contract";

export type ReportSchedulePrefs = {
  mode: ReportMode;
  /** "HH:MM" 현지 벽시계 */
  dailyTime: string;
  /** 조용한 시간 [start, end). 둘 다 null이면 끔. start > end면 자정을 넘는다. 같으면 빈 창(끔과 같다, API는 받지 않는다) */
  quietStart: string | null;
  quietEnd: string | null;
  /** IANA 시간대 (Mac이 보낸 이름) */
  timeZone: string;
  createdAt: Date;
  scheduleChangedAt: Date;
};

/** 예정 시각에서 이만큼 지나면 그 날 보고는 보내지 않는다 (밀린 보고를 몰아 보내지 않는다) */
export const REPORT_STALE_MS = 2 * 60 * 60_000;

const MINUTE_MS = 60_000;
const DAY_MS = 24 * 60 * MINUTE_MS;

// ─── 시간대 ─────────────────────────────────────────────

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(timeZone, f);
  }
  return f;
}

/** 런타임(Intl)이 아는 시간대인가 */
export function isSupportedTimeZone(timeZone: string): boolean {
  try {
    formatter(timeZone);
    return true;
  } catch {
    return false;
  }
}

type Parts = { year: number; month: number; day: number; hour: number; minute: number; second: number };

function partsAt(ms: number, timeZone: string): Parts {
  const parts: Record<string, number> = {};
  for (const part of formatter(timeZone).formatToParts(new Date(ms))) {
    if (part.type !== "literal") parts[part.type] = Number(part.value);
  }
  return parts as Parts;
}

/** 현지 벽시계: 날짜 "YYYY-MM-DD"와 자정부터의 분 */
export type LocalWall = { date: string; minutes: number };

const pad = (n: number, width = 2) => String(n).padStart(width, "0");

export function localWall(at: Date | number, timeZone: string): LocalWall {
  const p = partsAt(typeof at === "number" ? at : at.getTime(), timeZone);
  return { date: `${pad(p.year, 4)}-${pad(p.month)}-${pad(p.day)}`, minutes: p.hour * 60 + p.minute };
}

/** 이 순간의 UTC 차이 (현지 - UTC, ms) */
function offsetAt(ms: number, timeZone: string): number {
  const p = partsAt(ms, timeZone);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - Math.floor(ms / 1000) * 1000;
}

export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

const compareWall = (a: LocalWall, b: LocalWall) => (a.date === b.date ? a.minutes - b.minutes : a.date < b.date ? -1 : 1);

/**
 * 현지 날짜 date의 minutes 시각이 되는 순간들 (오름차순, 분 단위 정렬).
 * 보통 하나, 가을 되돌림의 겹친 시각은 둘. 봄 앞당김으로 없는 시각이면 시계가 그 시각을 건너뛴 순간(전환 순간) 하나.
 * 그 순간이 다른 날짜면(자정을 건너뛰는 전환) 빈 배열.
 */
export function localInstants(date: string, minutes: number, timeZone: string): number[] {
  const [y, m, d] = date.split("-").map(Number);
  const naive = Date.UTC(y, m - 1, d, Math.floor(minutes / 60), minutes % 60);
  const offsets = [...new Set([offsetAt(naive - DAY_MS, timeZone), offsetAt(naive, timeZone), offsetAt(naive + DAY_MS, timeZone)])].sort((a, b) => a - b);
  const target = { date, minutes };
  const matches = offsets
    .map((offset) => naive - offset)
    .filter((t) => compareWall(localWall(t, timeZone), target) === 0)
    .sort((a, b) => a - b);
  if (matches.length > 0) return [...new Set(matches)];

  // 없는 시각: 큰 차이로 본 순간(lo)은 목표 전, 작은 차이로 본 순간(hi)은 목표 뒤다. 그 사이에서 시계가 목표를 처음 넘는 분을 찾는다
  let lo = naive - offsets[offsets.length - 1];
  let hi = naive - offsets[0];
  if (!(compareWall(localWall(lo, timeZone), target) < 0 && compareWall(localWall(hi, timeZone), target) > 0)) return [];
  while (hi - lo > MINUTE_MS) {
    const mid = lo + Math.floor((hi - lo) / (2 * MINUTE_MS)) * MINUTE_MS;
    if (compareWall(localWall(mid, timeZone), target) >= 0) hi = mid;
    else lo = mid;
  }
  return localWall(hi, timeZone).date === date ? [hi] : [];
}

/** 현지 날짜 date의 minutes 시각이 처음 오는 순간 (규칙 2). 없으면 null */
export function resolveLocalTime(date: string, minutes: number, timeZone: string): number | null {
  return localInstants(date, minutes, timeZone)[0] ?? null;
}

// ─── 조용한 시간 ────────────────────────────────────────

export function clockMinutes(clock: string): number {
  const [h, m] = clock.split(":").map(Number);
  return h * 60 + m;
}

/** 현지 시각(분)이 조용한 시간 [start, end) 안인가. 끔(null) · 빈 창(start == end)은 언제나 아니다 */
export function inQuietHours(minutes: number, quietStart: string | null, quietEnd: string | null): boolean {
  if (quietStart === null || quietEnd === null) return false;
  const start = clockMinutes(quietStart);
  const end = clockMinutes(quietEnd);
  if (start === end) return false;
  return start < end ? minutes >= start && minutes < end : minutes >= start || minutes < end;
}

/** 일일 보고를 보낼 현지 시각(분): daily_time, 조용한 시간 안이면 quiet_end (규칙 1) */
export function effectiveDailyMinutes(prefs: Pick<ReportSchedulePrefs, "dailyTime" | "quietStart" | "quietEnd">): number {
  const daily = clockMinutes(prefs.dailyTime);
  return inQuietHours(daily, prefs.quietStart, prefs.quietEnd) ? clockMinutes(prefs.quietEnd!) : daily;
}

/** 이 순간 이후(포함) 조용한 시간이 아닌 첫 순간 */
export function firstSendableInstant(start: number, prefs: Pick<ReportSchedulePrefs, "quietStart" | "quietEnd" | "timeZone">): number | null {
  const wall = localWall(start, prefs.timeZone);
  if (!inQuietHours(wall.minutes, prefs.quietStart, prefs.quietEnd)) return start;
  const end = clockMinutes(prefs.quietEnd!);
  for (const date of [wall.date, addDays(wall.date, 1)]) {
    const next = localInstants(date, end, prefs.timeZone).find((t) => t > start);
    if (next !== undefined) return next;
  }
  return null;
}

// ─── 일일 보고 계획 ─────────────────────────────────────

export type DailyReportDue = {
  /** 지금 시간대의 현지 날짜 */
  reportDate: string;
  /** 그 날짜가 시작하는 순간 (원장 확인: 이 뒤로 예정된 보고가 있으면 잡지 않는다) */
  dayStart: Date;
  scheduledAt: Date;
  /** 이 뒤로는 보내지 않는다 (재시도 포함) */
  expiresAt: Date;
};

export type DailyReportPlan = {
  /** 지금 보낼 보고. 없으면 null */
  due: DailyReportDue | null;
  /** 다음에 보낼 순간 (지금 보낼 것이 있으면 지금). 일일 보고가 없는 모드 · 모르는 시간대면 null */
  next: { reportDate: string; at: Date } | null;
};

/**
 * 지금(now) 일일 보고를 보낼 차례인가, 어느 날짜의 보고인가, 다음은 언제인가.
 * lastScheduledAt = 이 사용자의 일일 보고 원장에서 가장 늦은 예정 시각 (상태와 상관없이, 없으면 null) — 규칙 4.
 */
export function planDailyReport(now: Date, prefs: ReportSchedulePrefs, lastScheduledAt: Date | null): DailyReportPlan {
  const none: DailyReportPlan = { due: null, next: null };
  if (prefs.mode === "meaningful" || !isSupportedTimeZone(prefs.timeZone)) return none;
  const t = now.getTime();
  const created = prefs.createdAt.getTime();
  const changed = prefs.scheduleChangedAt.getTime();
  const today = localWall(t, prefs.timeZone).date;
  const minutes = effectiveDailyMinutes(prefs);

  for (const offset of [-1, 0, 1, 2]) {
    const date = addDays(today, offset);
    const dayStart = resolveLocalTime(date, 0, prefs.timeZone);
    const scheduled = resolveLocalTime(date, minutes, prefs.timeZone);
    if (dayStart === null || scheduled === null) continue;
    // 규칙 4: 이 날(또는 더 뒤)의 보고가 이미 원장에 있다
    if (lastScheduledAt !== null && lastScheduledAt.getTime() >= dayStart) continue;
    // 규칙 5: 설정이 생기기 전의 예정 시각은 보내지 않는다
    if (scheduled < created) continue;
    let expires = scheduled + REPORT_STALE_MS;
    // 규칙 5: 그 날 일정을 바꿔 예정 시각이 이미 지났으면 바꾼 시각부터 다시 창을 연다 (처음 만든 설정은 아니다)
    if (changed > created && changed > scheduled && localWall(changed, prefs.timeZone).date === date) {
      expires = Math.max(expires, changed + REPORT_STALE_MS);
    }
    if (t > expires) continue;
    const at = firstSendableInstant(Math.max(scheduled, t), prefs);
    if (at === null || at > expires) continue;
    if (at <= t) {
      return {
        due: { reportDate: date, dayStart: new Date(dayStart), scheduledAt: new Date(scheduled), expiresAt: new Date(expires) },
        next: { reportDate: date, at: now },
      };
    }
    return { due: null, next: { reportDate: date, at: new Date(at) } };
  }
  return none;
}

/** 지금이 조용한 시간인가 (사용자 시간대). 모르는 시간대면 보내지 않도록 true */
export function quietNow(now: Date, prefs: Pick<ReportSchedulePrefs, "quietStart" | "quietEnd" | "timeZone">): boolean {
  if (!isSupportedTimeZone(prefs.timeZone)) return true;
  return inQuietHours(localWall(now, prefs.timeZone).minutes, prefs.quietStart, prefs.quietEnd);
}
