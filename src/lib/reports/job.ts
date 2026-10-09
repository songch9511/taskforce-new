import type { ReportMode } from "@/lib/api/contract";
import { sendPush, type ApnsConfig, type ApnsDevice, type PushResult, type Transport } from "@/lib/notify/apns";

import { DAILY_REPORT_COLLAPSE_ID, dailyReportPayload, isEmptyReport, type ReportStatusCounts } from "./payload";
import { isSupportedTimeZone, planDailyReport, quietNow, type ReportSchedulePrefs } from "./schedule";

// 일일 보고 job (cron/reports, REPORTS_V2_ENABLED 뒤). 저장소(store)와 APNs 전송(transport)을 주입받는다 — 테스트는 가짜로, 운영은 store.ts.
//
// 한 번 돌 때:
// 1. 더 보낼 수 없는 대기 행을 닫는다 (늦음 · 시도를 다 씀, DB 함수 finish_stale_report_deliveries).
// 2. 다시 보낼 차례인 대기 행: 지금 조용한 시간이거나 일일 보고를 끈 사용자면 두고(창이 닫히면 1이 닫는다), 아니면 다시 잡아(claim_report_retry) 보낸다.
// 3. 일일 보고가 켜진 사용자마다 planDailyReport로 지금 보낼 날짜를 정하고, 잡히면(claim_report_delivery) 보낸다.
//    잡기는 DB 함수가 사용자 잠금 안에서 원장을 다시 확인하므로 cron이 겹쳐 돌아도 하루 한 번이다.
// 4. 보내기: 숫자 상태(report_status_counts)가 모두 0이면 보내지 않고(skipped empty), 기기가 없으면 skipped no_devices.
//    기기 하나라도 받으면 sent. 등록이 끊긴 토큰(410 · BadDeviceToken)은 기존 알림처럼 기기 행을 지운다.
//    일시 오류(5xx · 429 · 연결 오류)는 REPORT_RETRY_DELAYS_MS 뒤 다시(최대 REPORT_MAX_ATTEMPTS번, 창 안에서만), 그 밖의 거절은 failed.
//    결과는 잡을 때의 attempts를 펜스로 남긴다 (임대가 끝나 다른 실행이 다시 잡았으면 덮지 않는다).
// 보내고 기록하기 전에 실행이 죽으면 임대(REPORT_LEASE_SECONDS) 뒤 시도 상한 안에서 다시 보낼 수 있다: 같은 collapse id라 기기에는 하나로 보인다.
// 로그 · 원장에는 숫자와 코드만 남긴다 (사용자 글 없음).

export const REPORT_MAX_ATTEMPTS = 3;
export const REPORT_LEASE_SECONDS = 300;
/** n번째 시도가 일시 오류로 실패한 뒤 기다리는 시간 (n = 1, 2) */
export const REPORT_RETRY_DELAYS_MS = [5 * 60_000, 15 * 60_000] as const;
/** 원장에서 마지막 예정 시각을 찾는 범위: 후보 날짜(어제 ~ 모레)보다 넉넉히 */
const LEDGER_LOOKBACK_MS = 3 * 24 * 60 * 60_000;

export type ReportPreferenceRow = {
  user_id: string;
  mode: ReportMode;
  daily_time: string;
  quiet_start: string | null;
  quiet_end: string | null;
  respect_focus: boolean;
  time_zone: string;
  created_at: string;
  schedule_changed_at: string;
};

export type ReportDeliveryStatus = "pending" | "sent" | "failed" | "skipped";

export type ReportDeliveryRow = {
  id: string;
  user_id: string;
  kind: "daily";
  time_zone: string;
  report_date: string;
  scheduled_at: string;
  expires_at: string;
  status: ReportDeliveryStatus;
  attempts: number;
  next_attempt_at: string | null;
};

export type ReportDevice = ApnsDevice & { id: string; user_id: string };

export type DeliveryOutcome =
  | { status: "sent" }
  | { status: "pending"; lastError: string; nextAttemptAt: Date }
  | { status: "failed" | "skipped"; lastError: string };

export type ClaimInput = {
  userId: string;
  timeZone: string;
  reportDate: string;
  dayStart: Date;
  scheduledAt: Date;
  expiresAt: Date;
  now: Date;
  leaseSeconds: number;
};

export type ReportStore = {
  finishStale(now: Date, maxAttempts: number): Promise<number>;
  /** 일일 보고가 켜진(mode both · daily) 설정 행 전부 */
  dailyPreferences(): Promise<ReportPreferenceRow[]>;
  /** since 뒤로 예정된 일일 보고 원장의 사용자별 가장 늦은 예정 시각 (상태와 상관없이) */
  lastScheduled(since: Date): Promise<Map<string, Date>>;
  /** 다시 보낼 차례인 대기 행 (next_attempt_at ≤ now ≤ expires_at, 시도가 남음) */
  retryable(now: Date, maxAttempts: number): Promise<ReportDeliveryRow[]>;
  claim(input: ClaimInput): Promise<ReportDeliveryRow | null>;
  claimRetry(id: string, now: Date, leaseSeconds: number, maxAttempts: number): Promise<ReportDeliveryRow | null>;
  statusCounts(userId: string, today: string): Promise<ReportStatusCounts>;
  devices(userId: string): Promise<ReportDevice[]>;
  removeDevice(device: ReportDevice): Promise<void>;
  record(delivery: ReportDeliveryRow, outcome: DeliveryOutcome, now: Date): Promise<void>;
};

export type ReportPush = { config: ApnsConfig; transport?: Transport };

export type DailyReportResult = {
  /** 일일 보고가 켜진 설정 수 */
  preferences: number;
  /** 지금 보낼 차례로 계산된 사용자 수 */
  due: number;
  /** 새로 잡은 보고 (겹친 실행이 먼저 잡았거나 이미 있으면 세지 않는다) */
  claimed: number;
  /** 다시 잡은 보고 */
  retried: number;
  /** 다시 보낼 차례지만 조용한 시간 · 일일 보고 끔이라 둔 것 */
  held: number;
  sent: number;
  /** 일시 오류로 다음 시도를 기다리는 것 */
  retrying: number;
  failed: number;
  skipped: number;
  /** 1단계에서 닫은 대기 행 */
  expired: number;
  /** 런타임이 모르는 시간대라 계산하지 못한 설정 */
  invalid_time_zone: number;
  /** 실행 시간이 모자라 이번에 잡지 않은 것 (다음 실행이 창 안에서 잡는다) */
  deferred_for_time: number;
};

export function schedulePrefs(row: ReportPreferenceRow): ReportSchedulePrefs {
  return {
    mode: row.mode,
    dailyTime: row.daily_time,
    quietStart: row.quiet_start,
    quietEnd: row.quiet_end,
    timeZone: row.time_zone,
    createdAt: new Date(row.created_at),
    scheduleChangedAt: new Date(row.schedule_changed_at),
  };
}

/** APNs 거절 → 원장 코드 (소문자 · 숫자 · _만, DB check와 같다). 5xx · 429는 일시 오류 */
export function pushErrorCode(result: Exclude<PushResult, { ok: true }>): { transient: boolean; code: string } {
  const transient = result.status >= 500 || result.status === 429;
  const reason = result.reason && /^[A-Za-z]{1,40}$/.test(result.reason) ? `_${result.reason.toLowerCase()}` : "";
  return { transient, code: `apns_${result.status}${reason}`.slice(0, 64) };
}

function retryOrFail(delivery: ReportDeliveryRow, code: string, now: Date): DeliveryOutcome {
  if (delivery.attempts >= REPORT_MAX_ATTEMPTS) return { status: "failed", lastError: code };
  const delay = REPORT_RETRY_DELAYS_MS[Math.min(delivery.attempts, REPORT_RETRY_DELAYS_MS.length) - 1];
  const nextAttemptAt = new Date(now.getTime() + delay);
  // 창이 닫힌 뒤의 다시 보내기는 없다: 그때는 기다리지 않고 끝낸다
  if (nextAttemptAt.getTime() > Date.parse(delivery.expires_at)) return { status: "failed", lastError: code };
  return { status: "pending", lastError: code, nextAttemptAt };
}

async function deliver(store: ReportStore, push: ReportPush, delivery: ReportDeliveryRow, pref: ReportPreferenceRow, now: Date): Promise<DeliveryOutcome> {
  let counts: ReportStatusCounts;
  let devices: ReportDevice[];
  try {
    counts = await store.statusCounts(delivery.user_id, delivery.report_date);
    if (isEmptyReport(counts)) return { status: "skipped", lastError: "empty" };
    devices = await store.devices(delivery.user_id);
  } catch {
    return retryOrFail(delivery, "internal", now);
  }
  if (devices.length === 0) return { status: "skipped", lastError: "no_devices" };

  const payload = dailyReportPayload(counts, { respectFocus: pref.respect_focus });
  let delivered = 0;
  let transient: string | null = null;
  let rejected: string | null = null;
  for (const device of devices) {
    let result: PushResult;
    try {
      result = await sendPush(push.config, device, payload, push.transport, { collapseId: DAILY_REPORT_COLLAPSE_ID });
    } catch {
      transient ??= "network";
      continue;
    }
    if (result.ok) {
      delivered++;
    } else if (result.unregistered) {
      rejected ??= "unregistered";
      try {
        await store.removeDevice(device);
      } catch (error) {
        console.error(`일일 보고: 등록이 끊긴 기기를 지우지 못함 (${device.id}):`, error instanceof Error ? error.message : error);
      }
    } else {
      const { transient: retry, code } = pushErrorCode(result);
      if (retry) transient ??= code;
      else rejected ??= code;
    }
  }
  if (delivered > 0) return { status: "sent" };
  if (transient) return retryOrFail(delivery, transient, now);
  return { status: "failed", lastError: rejected ?? "rejected" };
}

export async function runDailyReports(
  store: ReportStore,
  push: ReportPush,
  options: { now: Date; deadline: number; clock?: () => number },
): Promise<DailyReportResult> {
  const { now, deadline } = options;
  const clock = options.clock ?? Date.now;
  const result: DailyReportResult = {
    preferences: 0,
    due: 0,
    claimed: 0,
    retried: 0,
    held: 0,
    sent: 0,
    retrying: 0,
    failed: 0,
    skipped: 0,
    expired: 0,
    invalid_time_zone: 0,
    deferred_for_time: 0,
  };

  const finish = async (delivery: ReportDeliveryRow, pref: ReportPreferenceRow) => {
    const outcome = await deliver(store, push, delivery, pref, now);
    if (outcome.status === "sent") result.sent++;
    else if (outcome.status === "pending") result.retrying++;
    else if (outcome.status === "failed") result.failed++;
    else result.skipped++;
    try {
      await store.record(delivery, outcome, now);
    } catch (error) {
      // 기록하지 못하면 행은 임대가 끝난 뒤 다시 잡힐 수 있다 (같은 collapse id)
      console.error(`일일 보고 기록 실패 (${delivery.id}):`, error instanceof Error ? error.message : error);
    }
  };

  result.expired = await store.finishStale(now, REPORT_MAX_ATTEMPTS);
  const prefs = await store.dailyPreferences();
  result.preferences = prefs.length;
  const byUser = new Map(prefs.map((p) => [p.user_id, p]));

  for (const row of await store.retryable(now, REPORT_MAX_ATTEMPTS)) {
    const pref = byUser.get(row.user_id);
    if (!pref || quietNow(now, schedulePrefs(pref))) {
      result.held++;
      continue;
    }
    if (clock() > deadline) {
      result.deferred_for_time++;
      continue;
    }
    const claimed = await store.claimRetry(row.id, now, REPORT_LEASE_SECONDS, REPORT_MAX_ATTEMPTS);
    if (!claimed) continue;
    result.retried++;
    await finish(claimed, pref);
  }

  const last = await store.lastScheduled(new Date(now.getTime() - LEDGER_LOOKBACK_MS));
  for (const pref of prefs) {
    if (!isSupportedTimeZone(pref.time_zone)) {
      result.invalid_time_zone++;
      continue;
    }
    const plan = planDailyReport(now, schedulePrefs(pref), last.get(pref.user_id) ?? null);
    if (!plan.due) continue;
    result.due++;
    if (clock() > deadline) {
      result.deferred_for_time++;
      continue;
    }
    const claimed = await store.claim({
      userId: pref.user_id,
      timeZone: pref.time_zone,
      reportDate: plan.due.reportDate,
      dayStart: plan.due.dayStart,
      scheduledAt: plan.due.scheduledAt,
      expiresAt: plan.due.expiresAt,
      now,
      leaseSeconds: REPORT_LEASE_SECONDS,
    });
    if (!claimed) continue;
    result.claimed++;
    await finish(claimed, pref);
  }
  return result;
}
