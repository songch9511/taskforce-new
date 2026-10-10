import type { ReportMode } from "@/lib/api/contract";
import { sendPush, type ApnsConfig, type ApnsDevice, type PushResult, type Transport } from "@/lib/notify/apns";

import { DAILY_REPORT_COLLAPSE_ID, dailyReportPayload, isEmptyReport, type ReportStatusCounts } from "./payload";
import { isSupportedTimeZone, localWall, nextQuietStart, planDailyReport, quietNow, type ReportSchedulePrefs } from "./schedule";

// 일일 보고 job (cron/reports, REPORTS_V2_ENABLED 뒤). 저장소(store)와 APNs 전송(transport) · 시계(clock)를 주입받는다 — 테스트는 가짜로, 운영은 store.ts.
//
// 한 번 돌 때:
// 1. 더 보낼 수 없는 대기 행을 닫는다 (늦음 · 시도를 다 씀, DB 함수 finish_stale_report_deliveries. 일일 보고를 끈 사용자 것은 skipped mode_changed).
// 2. 다시 보낼 차례인 대기 행: 일일 보고를 끈(meaningful) 사용자면 닫고(결과를 아는 실패는 skipped mode_changed, 결과를 모르면
//    failed mode_changed_unknown), 지금 조용한 시간이면 두고(창이 닫히면 1이 닫는다), 아니면 다시 잡아(claim_report_retry) 보낸다.
//    다시 잡기는 이번 실행이 읽은 설정 version을 넘긴다: 그 사이 설정이 바뀌었으면 DB 함수가 아무것도 하지 않는다(낡은 조용한 시간 ·
//    시간대 · Respect Focus로 보내지 않는다). 실패 뒤 일정을 바꿨으면(schedule_version이 다름) DB 함수가 다시 보내지 않고 닫는다:
//    결과를 아는 실패는 skipped schedule_changed(그날 새 일정의 보고가 갈 수 있다), 결과를 모르면 failed schedule_changed_unknown(그날은 보낸 날).
// 3. 일일 보고가 켜진 사용자마다 planDailyReport로 지금 보낼 날짜를 정하고, 잡히면(claim_report_delivery) 보낸다.
//    잡기는 DB 함수가 사용자 잠금 안에서 원장과 설정 version을 다시 확인하므로 cron이 겹쳐 돌아도 하루 한 번이고,
//    cron이 설정을 읽은 뒤 PUT이 설정을 바꿨으면 잡지 않는다(다음 실행이 새 설정으로 계산한다).
// 결과를 모름(UNKNOWN_OUTCOME_CODES): 연결 오류 · 응답 시간 초과 · 상태 없는 응답, 또는 잡힌 뒤 결과를 남기지 못하고 멈춤(last_error 없음).
//    APNs가 이미 받았을 수 있어 그날은 보낸 날로 센다. 기기 여럿 중 하나라도 결과를 모르면 그 코드를 남긴다(분명한 거절보다 앞선다).
// 경계: 설정 변경이 잡기 · 다시 잡기의 설정 행 잠금보다 먼저 커밋되면 지켜진다. 이미 잡혀 보내는 중(임대 중, APNs 요청 중)이던 보고와
//    결과를 모르는 보고는 그 뒤 일정을 바꿔도 갔을 수 있고, 그 현지 날은 보낸 날이다(두 번째 보고 없음).
// 4. 보내기: 숫자 상태(report_status_counts)가 모두 0이면 보내지 않고(skipped empty), 기기가 없으면 skipped no_devices.
//    기기 하나라도 받으면 sent. 등록이 끊긴 토큰(410 · BadDeviceToken)은 기존 알림처럼 기기 행을 지운다.
//    APNs 만료(apns-expiration)는 창 끝과 다음 조용한 시간 시작 중 이른 쪽: 기기가 꺼져 있어도 그 뒤로는 APNs가 버린다(그 전까지는 늦게 갈 수 있다).
//    일시 오류(5xx · 429 · 연결 오류)는 REPORT_RETRY_DELAYS_MS 뒤 다시(최대 REPORT_MAX_ATTEMPTS번, 창 안에서만), 그 밖의 거절은 failed.
//    결과는 잡을 때의 attempts를 펜스로 남긴다: 그 사이 다른 실행이 다시 잡았거나 닫혔으면 0행이라 세지 않는다(fence_missed, id만 로그).
// 사용자 하나의 실패(DB · 전송 오류)는 errors로 세고 다음 사용자로 넘어간다. 시각은 잡기 · 보내기마다 시계를 다시 읽는다.
// 보내고 기록하기 전에 실행이 죽으면 임대(REPORT_LEASE_SECONDS) 뒤 시도 상한 안에서 다시 보낼 수 있다:
// 같은 collapse id라 알림 센터의 항목은 바뀌지만, 기기가 다시 울릴 수는 있다.
// 로그 · 원장에는 숫자와 코드 · id만 남긴다 (사용자 글 없음).

export const REPORT_MAX_ATTEMPTS = 3;
export const REPORT_LEASE_SECONDS = 300;
/** n번째 시도가 일시 오류로 실패한 뒤 기다리는 시간 (n = 1, 2) */
export const REPORT_RETRY_DELAYS_MS = [5 * 60_000, 15 * 60_000] as const;
/** APNs가 받았는지 모르는 실패 코드: 연결 오류 · 응답 시간 초과(network), 상태 없는 응답(apns_0). 원장 last_error null(잡힌 뒤 결과 없음)도 같다 */
export const UNKNOWN_OUTCOME_CODES = ["network", "apns_0"] as const;
export const isUnknownOutcome = (lastError: string | null) => lastError === null || (UNKNOWN_OUTCOME_CODES as readonly string[]).includes(lastError);
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
  /** 일정 세대 (일정에 닿는 값이 바뀔 때만 오른다) */
  schedule_version: number;
  /** 설정 version (고칠 때마다 오른다). 잡기 · 다시 잡기에 넘겨 이번 실행이 읽은 설정이 아직 최신인지 DB 함수가 본다 */
  version: number;
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
  /** 지난 시도의 실패 코드. 대기 행에서 null이면 잡힌 뒤 결과를 남기지 못한 것(결과를 모름) */
  last_error: string | null;
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
  /** 계획에 쓴 설정의 version: 잡는 순간 설정과 다르면 DB 함수가 잡지 않는다 */
  preferencesVersion: number;
};

export type ReportStore = {
  finishStale(now: Date, maxAttempts: number): Promise<number>;
  /** 일일 보고가 켜진(mode both · daily) 설정 행 전부 */
  dailyPreferences(): Promise<ReportPreferenceRow[]>;
  /** since 뒤로 명목 시각이 있는 일일 보고 원장의 사용자별 가장 늦은 명목 시각 (그날을 막는 행만, isBlockingDelivery) */
  lastScheduled(since: Date): Promise<Map<string, Date>>;
  /** 다시 보낼 차례인 대기 행 (next_attempt_at ≤ now ≤ expires_at, 시도가 남음) */
  retryable(now: Date, maxAttempts: number): Promise<ReportDeliveryRow[]>;
  claim(input: ClaimInput): Promise<ReportDeliveryRow | null>;
  /** preferencesVersion = 이번 실행이 읽은 설정 version. 다르면 DB 함수가 아무것도 하지 않는다 */
  claimRetry(id: string, now: Date, leaseSeconds: number, maxAttempts: number, preferencesVersion: number): Promise<ReportDeliveryRow | null>;
  statusCounts(userId: string, today: string): Promise<ReportStatusCounts>;
  devices(userId: string): Promise<ReportDevice[]>;
  removeDevice(device: ReportDevice): Promise<void>;
  /** 펜스(잡을 때의 attempts · pending)가 맞을 때만 쓴다. 바뀐 행 수 (0 = 펜스 불일치) */
  record(delivery: ReportDeliveryRow, outcome: DeliveryOutcome, now: Date): Promise<number>;
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
  /** 다시 보낼 차례지만 지금 조용한 시간이라 둔 것 */
  held: number;
  sent: number;
  /** 일시 오류로 다음 시도를 기다리는 것 */
  retrying: number;
  failed: number;
  /** 보낼 것 없음(empty) · 기기 없음(no_devices) · 일일 보고를 끔(mode_changed) */
  skipped: number;
  /** 1단계에서 닫은 대기 행 */
  expired: number;
  /** 런타임이 모르는 시간대라 계산하지 못한 설정 */
  invalid_time_zone: number;
  /** 실행 시간이 모자라 이번에 잡지 않은 것 (다음 실행이 창 안에서 잡는다) */
  deferred_for_time: number;
  /** 기록할 때 펜스가 맞지 않아 0행 (그 사이 다른 실행이 다시 잡았거나 닫힘). 결과 숫자에 넣지 않는다 */
  fence_missed: number;
  /** 사용자 하나 · 단계 하나의 실패 (DB · 예상 못 한 오류). 다음 사용자는 계속한다 */
  errors: number;
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

/** APNs 거절 → 원장 코드 (소문자 · 숫자 · _만, DB check와 같다). 5xx · 429 · 상태 없는 응답(apns_0)은 일시 오류 */
export function pushErrorCode(result: Exclude<PushResult, { ok: true }>): { transient: boolean; code: string } {
  const status = Number.isInteger(result.status) && result.status > 0 ? result.status : 0;
  const transient = status === 0 || status >= 500 || status === 429;
  const reason = result.reason && /^[A-Za-z]{1,40}$/.test(result.reason) ? `_${result.reason.toLowerCase()}` : "";
  return { transient, code: `apns_${status}${reason}`.slice(0, 64) };
}

/**
 * APNs 만료(UNIX 초): 창 끝(expires_at)과 보내는 순간 뒤 첫 조용한 시간 시작 중 이른 쪽.
 * 이미 지났으면 0 (보관하지 않고 한 번만 시도)
 */
export function reportExpiration(delivery: Pick<ReportDeliveryRow, "expires_at">, pref: ReportPreferenceRow, sendAt: number): number {
  const until = Math.min(Date.parse(delivery.expires_at), nextQuietStart(sendAt, schedulePrefs(pref)) ?? Number.POSITIVE_INFINITY);
  const seconds = Math.floor(until / 1000);
  return seconds > Math.floor(sendAt / 1000) ? seconds : 0;
}

function retryOrFail(delivery: ReportDeliveryRow, code: string, now: Date): DeliveryOutcome {
  if (delivery.attempts >= REPORT_MAX_ATTEMPTS) return { status: "failed", lastError: code };
  const delay = REPORT_RETRY_DELAYS_MS[Math.min(delivery.attempts, REPORT_RETRY_DELAYS_MS.length) - 1];
  const nextAttemptAt = new Date(now.getTime() + delay);
  // 창이 닫힌 뒤의 다시 보내기는 없다: 그때는 기다리지 않고 끝낸다
  if (nextAttemptAt.getTime() > Date.parse(delivery.expires_at)) return { status: "failed", lastError: code };
  return { status: "pending", lastError: code, nextAttemptAt };
}

async function deliver(
  store: ReportStore,
  push: ReportPush,
  delivery: ReportDeliveryRow,
  pref: ReportPreferenceRow,
  clock: () => number,
): Promise<DeliveryOutcome> {
  let counts: ReportStatusCounts;
  let devices: ReportDevice[];
  try {
    // 숫자는 보내는 순간의 현지 날짜로 센다 (자정을 넘겨 보내는 어제 보고도 "오늘 마감"이 지금의 오늘이다). 원장 날짜는 report_date 그대로
    counts = await store.statusCounts(delivery.user_id, localWall(clock(), pref.time_zone).date);
    if (isEmptyReport(counts)) return { status: "skipped", lastError: "empty" };
    devices = await store.devices(delivery.user_id);
  } catch {
    return retryOrFail(delivery, "internal", new Date(clock()));
  }
  if (devices.length === 0) return { status: "skipped", lastError: "no_devices" };

  const payload = dailyReportPayload(counts, { respectFocus: pref.respect_focus });
  let delivered = 0;
  let transient: string | null = null;
  let unknown: string | null = null;
  let rejected: string | null = null;
  for (const device of devices) {
    let result: PushResult;
    try {
      const options = { collapseId: DAILY_REPORT_COLLAPSE_ID, expiration: reportExpiration(delivery, pref, clock()) };
      result = await sendPush(push.config, device, payload, push.transport, options);
    } catch {
      // 요청이 나간 뒤의 응답 시간 초과일 수 있다: 갔는지 모른다
      unknown ??= "network";
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
      if (isUnknownOutcome(code)) unknown ??= code;
      else if (retry) transient ??= code;
      else rejected ??= code;
    }
  }
  if (delivered > 0) return { status: "sent" };
  // 결과를 모르는 기기가 있으면 그 코드가 앞선다 (일정이 바뀌어도 그날을 보낸 날로 센다)
  if (unknown ?? transient) return retryOrFail(delivery, (unknown ?? transient)!, new Date(clock()));
  return { status: "failed", lastError: rejected ?? "rejected" };
}

export async function runDailyReports(store: ReportStore, push: ReportPush, options: { deadline: number; clock?: () => number }): Promise<DailyReportResult> {
  const { deadline } = options;
  const clock = options.clock ?? Date.now;
  const now = () => new Date(clock());
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
    fence_missed: 0,
    errors: 0,
  };

  const failedStep = (step: string, id: string, error: unknown) => {
    result.errors++;
    console.error(`일일 보고 ${step} 실패 (${id}):`, error instanceof Error ? error.message : error);
  };

  /** 결과를 펜스로 기록하고, 실제로 바뀐 경우에만 센다 */
  const record = async (delivery: ReportDeliveryRow, outcome: DeliveryOutcome) => {
    const changed = await store.record(delivery, outcome, now());
    if (changed === 0) {
      result.fence_missed++;
      console.error(`일일 보고 기록 펜스 불일치 (${delivery.id}, attempts ${delivery.attempts})`);
      return;
    }
    if (outcome.status === "sent") result.sent++;
    else if (outcome.status === "pending") result.retrying++;
    else if (outcome.status === "failed") result.failed++;
    else result.skipped++;
  };

  try {
    result.expired = await store.finishStale(now(), REPORT_MAX_ATTEMPTS);
  } catch (error) {
    failedStep("대기 행 닫기", "all", error);
  }
  const prefs = await store.dailyPreferences();
  result.preferences = prefs.length;
  const byUser = new Map(prefs.map((p) => [p.user_id, p]));

  let retryRows: ReportDeliveryRow[] = [];
  try {
    retryRows = await store.retryable(now(), REPORT_MAX_ATTEMPTS);
  } catch (error) {
    failedStep("다시 보낼 행 읽기", "all", error);
  }
  for (const row of retryRows) {
    try {
      const pref = byUser.get(row.user_id);
      if (!pref) {
        // 일일 보고를 껐다 (dailyPreferences는 both · daily만): 다시 보내지 않고 닫는다. 갔는지 모르면 그날은 보낸 날로 (failed)
        await record(row, isUnknownOutcome(row.last_error) ? { status: "failed", lastError: "mode_changed_unknown" } : { status: "skipped", lastError: "mode_changed" });
        continue;
      }
      if (quietNow(now(), schedulePrefs(pref))) {
        result.held++;
        continue;
      }
      if (clock() > deadline) {
        result.deferred_for_time++;
        continue;
      }
      const claimed = await store.claimRetry(row.id, now(), REPORT_LEASE_SECONDS, REPORT_MAX_ATTEMPTS, pref.version);
      if (!claimed) continue;
      result.retried++;
      await record(claimed, await deliver(store, push, claimed, pref, clock));
    } catch (error) {
      failedStep("다시 보내기", row.id, error);
    }
  }

  const last = await store.lastScheduled(new Date(clock() - LEDGER_LOOKBACK_MS));
  for (const pref of prefs) {
    try {
      if (!isSupportedTimeZone(pref.time_zone)) {
        result.invalid_time_zone++;
        continue;
      }
      const plan = planDailyReport(now(), schedulePrefs(pref), last.get(pref.user_id) ?? null);
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
        now: now(),
        leaseSeconds: REPORT_LEASE_SECONDS,
        preferencesVersion: pref.version,
      });
      if (!claimed) continue;
      result.claimed++;
      await record(claimed, await deliver(store, push, claimed, pref, clock));
    } catch (error) {
      failedStep("보내기", pref.user_id, error);
    }
  }
  return result;
}
