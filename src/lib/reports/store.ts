import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { ApiContext } from "@/lib/api/auth";
import { reportPreferencesSchema, type ReportPreferences, type ReportPreferencesRequest } from "@/lib/api/contract";
import { readAll } from "@/lib/read-all";
import { createAdminClient } from "@/lib/supabase/admin";

import type { ReportDeliveryRow, ReportDevice, ReportPreferenceRow, ReportStore } from "./job";
import type { ReportStatusCounts } from "./payload";
import { isBlockingDelivery } from "./schedule";

// 보고 표 읽기 · 쓰기 (20261105000000_report_preferences). 설정 읽기는 사용자 권한(RLS), 쓰기와 job은 service role.

const PREFERENCE_API_COLUMNS = "mode, daily_time, quiet_start, quiet_end, respect_focus, time_zone, version";
const PREFERENCE_JOB_COLUMNS =
  "user_id, mode, daily_time, quiet_start, quiet_end, respect_focus, time_zone, created_at, schedule_changed_at, schedule_version, version";
const DELIVERY_COLUMNS = "id, user_id, kind, time_zone, report_date, scheduled_at, expires_at, status, attempts, next_attempt_at, last_error";

/** GET /api/v2/reports/preferences: 자기 설정 행 (RLS). 없으면 null */
export async function loadReportPreferences({ supabase }: ApiContext): Promise<ReportPreferences | null> {
  const { data } = await supabase.from("report_preferences").select(PREFERENCE_API_COLUMNS).maybeSingle().throwOnError();
  return data ? reportPreferencesSchema.parse({ ...data, saved: true }) : null;
}

/**
 * PUT: 앱은 쓰기 권한이 없다 — 서버가 사용자 id로 쓴다. 비교 후 쓰기(compare-and-set):
 * expected_version null = 처음 만들기(insert, 이미 있으면 유일 키 위반 → null), 숫자 = 그 version일 때만 고치기(0행 → null).
 * version · schedule_changed_at은 DB 트리거가 정한다. null이면 route가 409
 */
export async function saveReportPreferences({ user }: ApiContext, prefs: ReportPreferencesRequest): Promise<ReportPreferences | null> {
  return writeReportPreferences(createAdminClient(), user.id, prefs);
}

export async function writeReportPreferences(admin: SupabaseClient, userId: string, prefs: ReportPreferencesRequest): Promise<ReportPreferences | null> {
  const { expected_version: expected, ...fields } = prefs;
  if (expected === null) {
    const { data, error } = await admin.from("report_preferences").insert({ user_id: userId, ...fields }).select(PREFERENCE_API_COLUMNS).maybeSingle();
    if (error?.code === "23505") return null;
    if (error) throw new Error(`보고 설정 만들기 실패 (${error.code})`);
    return data ? reportPreferencesSchema.parse({ ...data, saved: true }) : null;
  }
  const { data } = await admin
    .from("report_preferences")
    .update(fields)
    .eq("user_id", userId)
    .eq("version", expected)
    .select(PREFERENCE_API_COLUMNS)
    .throwOnError();
  const row = ((data ?? []) as Record<string, unknown>[])[0];
  return row ? reportPreferencesSchema.parse({ ...row, saved: true }) : null;
}

/** cron/reports의 저장소 (service role). DB 함수는 service_role만 실행할 수 있다 */
export function supabaseReportStore(admin: SupabaseClient): ReportStore {
  const first = (data: unknown) => (((data ?? []) as ReportDeliveryRow[])[0] ?? null);
  return {
    async finishStale(now, maxAttempts) {
      const { data } = await admin.rpc("finish_stale_report_deliveries", { p_now: now.toISOString(), p_max_attempts: maxAttempts }).throwOnError();
      return Number(data ?? 0);
    },
    dailyPreferences: () =>
      readAll<ReportPreferenceRow>((from, to) =>
        admin.from("report_preferences").select(PREFERENCE_JOB_COLUMNS).in("mode", ["both", "daily"]).order("user_id").range(from, to),
      ),
    async lastScheduled(since) {
      const rows = await readAll<{ user_id: string; scheduled_at: string; status: string; last_error: string | null }>((from, to) =>
        admin
          .from("report_deliveries")
          .select("user_id, scheduled_at, status, last_error")
          .eq("kind", "daily")
          .gte("scheduled_at", since.toISOString())
          .order("id")
          .range(from, to),
      );
      const last = new Map<string, Date>();
      // 보내지 않고 닫힌 일정 변경 · 모드 변경 행은 그날을 막지 않는다 (claim_report_delivery와 같은 규칙)
      for (const row of rows.filter(isBlockingDelivery)) {
        const at = new Date(row.scheduled_at);
        const seen = last.get(row.user_id);
        if (!seen || at > seen) last.set(row.user_id, at);
      }
      return last;
    },
    retryable: (now, maxAttempts) =>
      readAll<ReportDeliveryRow>((from, to) =>
        admin
          .from("report_deliveries")
          .select(DELIVERY_COLUMNS)
          .eq("status", "pending")
          .lte("next_attempt_at", now.toISOString())
          .gte("expires_at", now.toISOString())
          .lt("attempts", maxAttempts)
          .order("next_attempt_at")
          .order("id")
          .range(from, to),
      ),
    async claim(input) {
      const { data } = await admin
        .rpc("claim_report_delivery", {
          p_user_id: input.userId,
          p_kind: "daily",
          p_time_zone: input.timeZone,
          p_report_date: input.reportDate,
          p_day_start: input.dayStart.toISOString(),
          p_scheduled_at: input.scheduledAt.toISOString(),
          p_expires_at: input.expiresAt.toISOString(),
          p_now: input.now.toISOString(),
          p_lease_seconds: input.leaseSeconds,
          p_preferences_version: input.preferencesVersion,
        })
        .throwOnError();
      return first(data);
    },
    async claimRetry(id, now, leaseSeconds, maxAttempts, preferencesVersion) {
      const { data } = await admin
        .rpc("claim_report_retry", {
          p_id: id,
          p_now: now.toISOString(),
          p_lease_seconds: leaseSeconds,
          p_max_attempts: maxAttempts,
          p_preferences_version: preferencesVersion,
        })
        .throwOnError();
      return first(data);
    },
    async statusCounts(userId, today) {
      const { data } = await admin.rpc("report_status_counts", { p_user_id: userId, p_today: today }).throwOnError();
      const row = ((data ?? []) as ReportStatusCounts[])[0];
      return row ?? { review: 0, overdue: 0, due_today: 0, in_progress: 0 };
    },
    async devices(userId) {
      const { data } = await admin.from("devices").select("id, user_id, token, environment").eq("user_id", userId).throwOnError();
      return (data ?? []) as ReportDevice[];
    },
    async removeDevice(device) {
      await admin.from("devices").delete().eq("id", device.id).eq("user_id", device.user_id).throwOnError();
    },
    async record(delivery, outcome, now) {
      const fields =
        outcome.status === "sent"
          ? { status: "sent", sent_at: now.toISOString(), next_attempt_at: null, last_error: null }
          : outcome.status === "pending"
            ? { status: "pending", next_attempt_at: outcome.nextAttemptAt.toISOString(), last_error: outcome.lastError }
            : { status: outcome.status, next_attempt_at: null, last_error: outcome.lastError };
      // 잡을 때의 attempts가 펜스다: 그 사이 다른 실행이 다시 잡았거나 닫혔으면 0행 (덮지 않는다). 바뀐 행 수를 돌려준다
      const { data } = await admin
        .from("report_deliveries")
        .update(fields)
        .eq("id", delivery.id)
        .eq("attempts", delivery.attempts)
        .eq("status", "pending")
        .select("id")
        .throwOnError();
      return (data ?? []).length;
    },
  };
}
