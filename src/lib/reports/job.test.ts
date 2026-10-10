import { generateKeyPairSync } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ApnsConfig, Transport } from "@/lib/notify/apns";

import {
  pushErrorCode,
  REPORT_LEASE_SECONDS,
  REPORT_MAX_ATTEMPTS,
  runDailyReports,
  type ClaimInput,
  type DeliveryOutcome,
  type ReportDeliveryRow,
  type ReportDevice,
  type ReportPreferenceRow,
  type ReportStore,
} from "./job";
import type { ReportStatusCounts } from "./payload";

// 일일 보고 job: 가짜 저장소(원장 규칙은 DB 함수와 같게 흉내)와 가짜 APNs 전송으로. 실제 DB 함수의 잠금 · 경합은
// tests/db/report-preferences.test.ts(PGlite)와 tests/pg/report-deliveries.test.ts(실제 Postgres)가 본다.

const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const config: ApnsConfig = { keyId: "ABC123DEFG", teamId: "U9DWQKQFMW", key: privateKey, bundleId: "dev.taskforcelabs.taskforce" };

const ALICE = "00000000-0000-4000-8000-00000000000a";
const BOB = "00000000-0000-4000-8000-00000000000b";

/** 서울 10-10 08:30 KST */
const SEOUL_0830 = new Date("2026-10-09T23:30:00Z");
const minutes = (n: number) => n * 60_000;
const after = (base: Date, ms: number) => new Date(base.getTime() + ms);

function pref(userId: string, overrides: Partial<ReportPreferenceRow> = {}): ReportPreferenceRow {
  return {
    user_id: userId,
    mode: "both",
    daily_time: "08:30",
    quiet_start: "22:00",
    quiet_end: "08:00",
    respect_focus: true,
    time_zone: "Asia/Seoul",
    created_at: "2026-01-01T00:00:00Z",
    schedule_changed_at: "2026-01-01T00:00:00Z",
    schedule_version: 1,
    version: 1,
    ...overrides,
  };
}

/** 원장 행 + 가짜가 따로 들고 있는 DB 열 (job은 읽지 않는다) */
type FakeRow = ReportDeliveryRow & { schedule_version: number };
const unknownOutcome = (d: FakeRow) => d.last_error === null || d.last_error === "network" || d.last_error === "apns_0";
const SCHEDULE_FIELDS = ["mode", "daily_time", "quiet_start", "quiet_end", "time_zone"] as const;
/** report_deliveries 행이 그날을 막는가 (claim_report_delivery · isBlockingDelivery와 같다) */
const blocking = (d: FakeRow) => !(d.status === "skipped" && (d.last_error === "schedule_changed" || d.last_error === "mode_changed"));

const device = (userId: string, id: string, token: string): ReportDevice => ({ id, user_id: userId, token, environment: "sandbox" });

/** 사용자의 열린 할 일 (가짜 report_status_counts가 센다). 제목 · 상대 · 메모는 알림에 실리면 안 되는 글이다 */
type FakeAction = { title: string; counterpart: string; notes: string; needs_confirmation: boolean; due_date: string | null };

/** DB 함수 claim_report_delivery · claim_report_retry · finish_stale_report_deliveries의 규칙을 흉내 내는 메모리 저장소 */
function fakeStore(init: { prefs: ReportPreferenceRow[]; devices?: ReportDevice[]; actions?: Record<string, FakeAction[]>; deliveries?: ReportDeliveryRow[] }) {
  const state = {
    prefs: init.prefs,
    devices: [...(init.devices ?? [])],
    deliveries: (init.deliveries ?? []).map((d): FakeRow => ({ schedule_version: 1, ...d })),
    records: [] as { id: string; outcome: DeliveryOutcome }[],
    recordTimes: [] as Date[],
    claims: [] as ClaimInput[],
    removed: [] as string[],
    failRecordFor: new Set<string>(),
    failCountsFor: new Set<string>(),
    failClaimFor: new Set<string>(),
    /** 이 사용자의 행은 기록 직전에 다른 실행이 다시 잡은 것처럼 attempts를 올린다 (펜스 불일치) */
    reclaimBeforeRecord: new Set<string>(),
    failFinish: false,
    /** statusCounts가 받은 현지 날짜 */
    countDays: [] as string[],
  };
  let seq = 0;
  const prefOf = (userId: string) => state.prefs.find((p) => p.user_id === userId);
  /** PUT 흉내 (트리거처럼): version은 언제나 +1, 일정에 닿는 값이 바뀌면 schedule_version +1 · schedule_changed_at */
  const put = (userId: string, patch: Partial<ReportPreferenceRow>, at: Date) => {
    const i = state.prefs.findIndex((p) => p.user_id === userId);
    const old = state.prefs[i];
    const next = { ...old, ...patch, version: old.version + 1 };
    const changed = SCHEDULE_FIELDS.some((f) => next[f] !== old[f]);
    state.prefs[i] = changed ? { ...next, schedule_version: old.schedule_version + 1, schedule_changed_at: at.toISOString() } : next;
  };
  /** 일정 · 모드 변경으로 닫기: 결과를 아는 실패는 skipped(그날을 막지 않음), 결과를 모르면 failed *_unknown (DB 함수와 같다) */
  const closeChanged = (d: FakeRow, reason: "schedule_changed" | "mode_changed") =>
    Object.assign(d, unknownOutcome(d) ? { status: "failed", last_error: `${reason}_unknown` } : { status: "skipped", last_error: reason }, { next_attempt_at: null });
  const store: ReportStore = {
    async finishStale(now, max) {
      if (state.failFinish) throw new Error("statement timeout");
      let n = 0;
      for (const d of state.deliveries) {
        if (d.status === "pending" && Date.parse(d.next_attempt_at!) <= now.getTime() && (now.getTime() > Date.parse(d.expires_at) || d.attempts >= max)) {
          const p = prefOf(d.user_id)!;
          if (p.mode === "meaningful") closeChanged(d, "mode_changed");
          else if (d.schedule_version !== p.schedule_version) closeChanged(d, "schedule_changed");
          else Object.assign(d, { status: "failed", last_error: d.last_error ?? "stale", next_attempt_at: null });
          n++;
        }
      }
      return n;
    },
    dailyPreferences: async () => state.prefs.filter((p) => p.mode !== "meaningful"),
    async lastScheduled(since) {
      const last = new Map<string, Date>();
      for (const d of state.deliveries.filter(blocking)) {
        const at = new Date(d.scheduled_at);
        if (at >= since && (!last.get(d.user_id) || at > last.get(d.user_id)!)) last.set(d.user_id, at);
      }
      return last;
    },
    retryable: async (now, max) =>
      state.deliveries.filter(
        (d) => d.status === "pending" && Date.parse(d.next_attempt_at!) <= now.getTime() && now.getTime() <= Date.parse(d.expires_at) && d.attempts < max,
      ),
    async claim(input) {
      if (state.failClaimFor.has(input.userId)) throw new Error("connection reset");
      state.claims.push(input);
      // 잠근 뒤 설정 version이 계획과 다르면 잡지 않는다
      const current = prefOf(input.userId);
      if (!current || current.version !== input.preferencesVersion) return null;
      if (state.deliveries.some((d) => d.user_id === input.userId && blocking(d) && Date.parse(d.scheduled_at) >= input.dayStart.getTime())) return null;
      const row: FakeRow = {
        id: `delivery-${++seq}`,
        user_id: input.userId,
        kind: "daily",
        time_zone: input.timeZone,
        report_date: input.reportDate,
        scheduled_at: input.scheduledAt.toISOString(),
        expires_at: input.expiresAt.toISOString(),
        status: "pending",
        attempts: 1,
        next_attempt_at: new Date(input.now.getTime() + input.leaseSeconds * 1000).toISOString(),
        schedule_version: current.schedule_version,
        last_error: null,
      };
      state.deliveries.push(row);
      return { ...row };
    },
    async claimRetry(id, now, leaseSeconds, max, preferencesVersion) {
      const d = state.deliveries.find((x) => x.id === id);
      if (!d) return null;
      const current = prefOf(d.user_id)!;
      // 이번 실행이 읽은 설정이 낡았으면 아무것도 하지 않는다 (claim_report_retry와 같다)
      if (current.version !== preferencesVersion) return null;
      // 실패 뒤 일정을 바꿨으면 다시 보내지 않고 닫는다
      if (d.status === "pending" && Date.parse(d.next_attempt_at!) <= now.getTime() && d.schedule_version !== current.schedule_version) {
        closeChanged(d, "schedule_changed");
        return null;
      }
      if (d.status !== "pending" || Date.parse(d.next_attempt_at!) > now.getTime() || d.attempts >= max || now.getTime() > Date.parse(d.expires_at)) return null;
      // 더 늦게 예정된 보고가 있으면 앞 날짜를 다시 잡지 않는다 (claim_report_retry와 같다)
      if (state.deliveries.some((o) => o.user_id === d.user_id && o.id !== d.id && blocking(o) && Date.parse(o.scheduled_at) > Date.parse(d.scheduled_at))) return null;
      d.attempts++;
      d.next_attempt_at = new Date(now.getTime() + leaseSeconds * 1000).toISOString();
      d.last_error = null;
      return { ...d };
    },
    async statusCounts(userId, today): Promise<ReportStatusCounts> {
      if (state.failCountsFor.has(userId)) throw new Error("connection reset");
      state.countDays.push(today);
      const open = init.actions?.[userId] ?? [{ title: "기본 할 일", counterpart: "", notes: "", needs_confirmation: true, due_date: null }];
      return {
        review: open.filter((a) => a.needs_confirmation).length,
        overdue: open.filter((a) => !a.needs_confirmation && a.due_date !== null && a.due_date < today).length,
        due_today: open.filter((a) => !a.needs_confirmation && a.due_date === today).length,
        in_progress: 0,
      };
    },
    devices: async (userId) => state.devices.filter((d) => d.user_id === userId),
    async removeDevice(d) {
      state.removed.push(d.id);
      state.devices = state.devices.filter((x) => x.id !== d.id);
    },
    async record(delivery, outcome, now) {
      if (state.failRecordFor.has(delivery.user_id)) throw new Error("timeout");
      if (state.reclaimBeforeRecord.has(delivery.user_id)) state.deliveries.find((x) => x.id === delivery.id)!.attempts++;
      state.recordTimes.push(now);
      const d = state.deliveries.find((x) => x.id === delivery.id && x.attempts === delivery.attempts && x.status === "pending");
      if (!d) return 0;
      state.records.push({ id: delivery.id, outcome });
      d.status = outcome.status;
      d.next_attempt_at = outcome.status === "pending" ? outcome.nextAttemptAt.toISOString() : null;
      d.last_error = outcome.status === "sent" ? null : outcome.lastError;
      return 1;
    },
  };
  return { store, state, put };
}

/** 토큰마다 정한 응답을 돌려주는 가짜 APNs. 기본은 200 */
function fakeApns(responses: Record<string, (() => { status: number; body: string }) | undefined> = {}) {
  const sent: Parameters<Transport>[0][] = [];
  const transport: Transport = async (request) => {
    sent.push(request);
    const token = request.path.split("/").pop()!;
    const respond = responses[token];
    return respond ? respond() : { status: 200, body: "" };
  };
  return { transport, sent };
}

/** now가 Date면 멈춘 시계, 함수면 그 시계 */
const run = (store: ReportStore, transport: Transport, now: Date | (() => number), deadline = Number.POSITIVE_INFINITY) =>
  runDailyReports(store, { config, transport }, { deadline, clock: typeof now === "function" ? now : () => now.getTime() });

beforeEach(() => {
  vi.restoreAllMocks();
  vi.spyOn(console, "error").mockImplementation(() => {});
});

describe("runDailyReports", () => {
  it("보낼 차례인 사용자에게 기기마다 한 번 보내고 sent로 남긴다 (collapse id · 짧은 상태 · deep link)", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64)), device(ALICE, "d2", "b".repeat(64))] });
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830);

    expect(result).toMatchObject({ preferences: 1, due: 1, claimed: 1, sent: 1, failed: 0, skipped: 0, retrying: 0 });
    expect(apns.sent).toHaveLength(2);
    expect(apns.sent[0].headers["apns-collapse-id"]).toBe("daily-report");
    expect(JSON.parse(apns.sent[0].body)).toEqual({
      aps: { alert: { title: "Daily report", body: "1 to review" }, sound: "default", "thread-id": "reports", "interruption-level": "active" },
      kind: "daily_report",
      url: "taskforce://work",
    });
    expect(state.claims[0]).toMatchObject({
      userId: ALICE,
      timeZone: "Asia/Seoul",
      reportDate: "2026-10-10",
      dayStart: new Date("2026-10-09T15:00:00Z"),
      scheduledAt: SEOUL_0830,
      expiresAt: new Date("2026-10-10T01:30:00Z"),
      leaseSeconds: REPORT_LEASE_SECONDS,
    });
    expect(state.records).toEqual([{ id: "delivery-1", outcome: { status: "sent" } }]);
  });

  it("같은 날 다시 돌려도(겹치거나 5분 뒤 cron) 한 번만 보낸다", async () => {
    const { store } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    await run(store, apns.transport, SEOUL_0830);
    const again = await run(store, apns.transport, SEOUL_0830);
    const later = await run(store, apns.transport, after(SEOUL_0830, minutes(5)));
    expect(apns.sent).toHaveLength(1);
    expect(again).toMatchObject({ due: 0, claimed: 0, sent: 0 });
    expect(later).toMatchObject({ due: 0, claimed: 0, sent: 0 });
  });

  it("알림 요청(헤더 · 본문)에 사용자 글(할 일 제목 · 상대 이름 · 이메일 · 메모)이 없다", async () => {
    const secret = { title: "ZEBRA-TITLE 계약서 서명", counterpart: "QUOKKA-NAME 김지훈 jihoon@quokka.example", notes: "AXOLOTL-NOTE 비밀 메모" };
    const { store } = fakeStore({
      prefs: [pref(ALICE)],
      devices: [device(ALICE, "d1", "a".repeat(64))],
      actions: {
        [ALICE]: [
          { ...secret, needs_confirmation: true, due_date: null },
          { ...secret, needs_confirmation: false, due_date: "2026-10-10" },
          { ...secret, needs_confirmation: false, due_date: "2026-10-01" },
        ],
      },
    });
    const apns = fakeApns();
    await run(store, apns.transport, SEOUL_0830);
    expect(apns.sent).toHaveLength(1);
    const wire = JSON.stringify(apns.sent[0]);
    for (const text of ["ZEBRA", "QUOKKA", "AXOLOTL", "김지훈", "jihoon", "계약서", "비밀"]) expect(wire, text).not.toContain(text);
    expect(JSON.parse(apns.sent[0].body).aps.alert.body).toBe("1 to review · 1 overdue · 1 due today");
  });

  it("Respect Focus를 끈 사용자는 time-sensitive를 요청한다", async () => {
    const { store } = fakeStore({ prefs: [pref(ALICE, { respect_focus: false })], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    await run(store, apns.transport, SEOUL_0830);
    expect(JSON.parse(apns.sent[0].body).aps["interruption-level"]).toBe("time-sensitive");
  });

  it("숫자가 모두 0이면 보내지 않고 skipped empty, 기기가 없으면 skipped no_devices", async () => {
    const { store, state } = fakeStore({
      prefs: [pref(ALICE), pref(BOB)],
      devices: [device(ALICE, "d1", "a".repeat(64))],
      actions: { [ALICE]: [] },
    });
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(apns.sent).toHaveLength(0);
    expect(result).toMatchObject({ claimed: 2, skipped: 2, sent: 0 });
    expect(state.records.map((r) => r.outcome)).toEqual([
      { status: "skipped", lastError: "empty" },
      { status: "skipped", lastError: "no_devices" },
    ]);
  });

  it("등록이 끊긴 기기(410)는 지우고, 다른 기기가 받았으면 sent", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64)), device(ALICE, "d2", "b".repeat(64))] });
    const apns = fakeApns({ ["a".repeat(64)]: () => ({ status: 410, body: JSON.stringify({ reason: "Unregistered" }) }) });
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(state.removed).toEqual(["d1"]);
    expect(result.sent).toBe(1);
  });

  it("기기 하나라도 결과를 모르면(연결 오류 · 응답 시간 초과) 다른 기기의 분명한 거절보다 앞서 network로 남긴다 (갔을 수 있다)", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64)), device(ALICE, "d2", "b".repeat(64))] });
    const apns = fakeApns({
      ["a".repeat(64)]: () => ({ status: 503, body: JSON.stringify({ reason: "ServiceUnavailable" }) }),
      ["b".repeat(64)]: () => {
        throw new Error("APNs 응답 시간 초과");
      },
    });
    await run(store, apns.transport, SEOUL_0830);
    expect(state.records[0].outcome).toEqual({ status: "pending", lastError: "network", nextAttemptAt: after(SEOUL_0830, minutes(5)) });
  });

  it("모든 기기가 끊겼거나 영구 거절이면 failed (코드만 남긴다)", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns({ ["a".repeat(64)]: () => ({ status: 403, body: JSON.stringify({ reason: "InvalidProviderToken" }) }) });
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(result.failed).toBe(1);
    expect(state.records[0].outcome).toEqual({ status: "failed", lastError: "apns_403_invalidprovidertoken" });
  });

  it("일시 오류(5xx · 연결 오류)는 5분 · 15분 뒤 다시 잡아 보내고, 세 번째도 실패하면 failed", async () => {
    let calls = 0;
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns({
      ["a".repeat(64)]: () => {
        calls++;
        if (calls === 2) throw new Error("socket hang up");
        return { status: 503, body: JSON.stringify({ reason: "ServiceUnavailable" }) };
      },
    });

    const first = await run(store, apns.transport, SEOUL_0830);
    expect(first).toMatchObject({ claimed: 1, retrying: 1 });
    expect(state.records[0].outcome).toEqual({ status: "pending", lastError: "apns_503_serviceunavailable", nextAttemptAt: after(SEOUL_0830, minutes(5)) });

    // 4분 뒤: 아직 차례가 아니다 (새로 잡지도 않는다)
    expect(await run(store, apns.transport, after(SEOUL_0830, minutes(4)))).toMatchObject({ retried: 0, claimed: 0 });

    const second = await run(store, apns.transport, after(SEOUL_0830, minutes(5)));
    expect(second).toMatchObject({ retried: 1, retrying: 1, claimed: 0 });
    expect(state.records[1].outcome).toEqual({ status: "pending", lastError: "network", nextAttemptAt: after(SEOUL_0830, minutes(20)) });

    const third = await run(store, apns.transport, after(SEOUL_0830, minutes(20)));
    expect(third).toMatchObject({ retried: 1, failed: 1 });
    expect(state.records[2].outcome).toEqual({ status: "failed", lastError: "apns_503_serviceunavailable" });
    expect(state.deliveries[0]).toMatchObject({ status: "failed", attempts: REPORT_MAX_ATTEMPTS });
    expect(apns.sent).toHaveLength(3);

    expect(await run(store, apns.transport, after(SEOUL_0830, minutes(60)))).toMatchObject({ retried: 0, claimed: 0 });
    expect(apns.sent).toHaveLength(3);
  });

  it("다음 시도가 창(예정 + 2시간) 뒤라면 기다리지 않고 failed", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns({ ["a".repeat(64)]: () => ({ status: 500, body: "" }) });
    // 예정 1시간 57분 뒤 첫 시도 → 5분 뒤는 창 밖
    await run(store, apns.transport, after(SEOUL_0830, minutes(117)));
    expect(state.records[0].outcome).toEqual({ status: "failed", lastError: "apns_500" });
  });

  it("다시 보낼 차례여도 지금 조용한 시간이면 두고(held), 일일 보고를 끈(meaningful) 사용자 것은 skipped · mode_changed로 닫는다. 보내지 않는다", async () => {
    const pending = (userId: string): ReportDeliveryRow => ({
      id: `pending-${userId}`,
      user_id: userId,
      kind: "daily",
      time_zone: "Asia/Seoul",
      report_date: "2026-10-10",
      scheduled_at: "2026-10-10T12:50:00Z", // 21:50 KST
      expires_at: "2026-10-10T14:50:00Z",
      status: "pending",
      attempts: 1,
      next_attempt_at: "2026-10-10T12:55:00Z",
      last_error: "apns_503",
    });
    const { store, state } = fakeStore({
      prefs: [pref(ALICE, { daily_time: "21:50" }), pref(BOB, { mode: "meaningful" })],
      devices: [device(ALICE, "d1", "a".repeat(64)), device(BOB, "d2", "b".repeat(64))],
      deliveries: [pending(ALICE), pending(BOB)],
    });
    const apns = fakeApns();
    // 22:05 KST: 조용한 시간
    const result = await run(store, apns.transport, new Date("2026-10-10T13:05:00Z"));
    expect(result).toMatchObject({ held: 1, skipped: 1, retried: 0, claimed: 0 });
    expect(apns.sent).toHaveLength(0);
    expect(state.records).toEqual([{ id: `pending-${BOB}`, outcome: { status: "skipped", lastError: "mode_changed" } }]);
    expect(state.deliveries.map((d) => [d.user_id, d.status])).toEqual([
      [ALICE, "pending"],
      [BOB, "skipped"],
    ]);
  });

  it("더 늦게 예정된 보고가 있으면 앞 날짜의 대기 행을 다시 잡지 않는다", async () => {
    const row = (id: string, date: string, scheduled: string): ReportDeliveryRow => ({
      id,
      user_id: ALICE,
      kind: "daily",
      time_zone: "Asia/Seoul",
      report_date: date,
      scheduled_at: scheduled,
      expires_at: new Date(Date.parse(scheduled) + minutes(120)).toISOString(),
      status: "pending",
      attempts: 1,
      next_attempt_at: scheduled,
      last_error: "apns_503",
    });
    const { store } = fakeStore({
      prefs: [pref(ALICE)],
      devices: [device(ALICE, "d1", "a".repeat(64))],
      deliveries: [row("older", "2026-10-10", "2026-10-09T23:30:00Z"), { ...row("newer", "2026-10-11", "2026-10-10T23:30:00Z"), status: "sent", next_attempt_at: null }],
    });
    const apns = fakeApns();
    expect(await run(store, apns.transport, after(SEOUL_0830, minutes(10)))).toMatchObject({ retried: 0, claimed: 0 });
    expect(apns.sent).toHaveLength(0);
  });

  it("실행 시간이 모자라면 새로 잡지 않는다 (deferred_for_time, 다음 실행이 창 안에서 잡는다)", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830, SEOUL_0830.getTime() - 1);
    expect(result).toMatchObject({ due: 1, claimed: 0, deferred_for_time: 1 });
    expect(state.claims).toHaveLength(0);
    expect(apns.sent).toHaveLength(0);
  });

  it("런타임이 모르는 시간대는 계산하지 않고 센다 (DB는 모양만 본다)", async () => {
    const { store } = fakeStore({ prefs: [pref(ALICE, { time_zone: "Mars/Base" })], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    expect(await run(store, apns.transport, SEOUL_0830)).toMatchObject({ invalid_time_zone: 1, due: 0 });
    expect(apns.sent).toHaveLength(0);
  });

  it("숫자를 읽지 못하면 internal로 다시 시도하고, 기록이 실패하면 보냈어도 세지 않고 errors로 (원장이 그대로라 임대 뒤 다시 잡힌다)", async () => {
    const { store, state } = fakeStore({
      prefs: [pref(ALICE), pref(BOB)],
      devices: [device(ALICE, "d1", "a".repeat(64)), device(BOB, "d2", "b".repeat(64))],
    });
    state.failCountsFor.add(ALICE);
    state.failRecordFor.add(BOB);
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(result).toMatchObject({ claimed: 2, retrying: 1, sent: 0, errors: 1 });
    expect(state.records).toEqual([{ id: "delivery-1", outcome: { status: "pending", lastError: "internal", nextAttemptAt: after(SEOUL_0830, minutes(5)) } }]);
    expect(apns.sent.map((r) => r.path)).toEqual([`/3/device/${"b".repeat(64)}`]);
    expect(console.error).toHaveBeenCalledWith(`일일 보고 보내기 실패 (${BOB}):`, "timeout");
  });

  it("예정 전 · meaningful 사용자는 잡지 않는다", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE), pref(BOB, { mode: "meaningful" })], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    expect(await run(store, apns.transport, after(SEOUL_0830, -minutes(1)))).toMatchObject({ preferences: 1, due: 0 });
    expect(state.claims).toHaveLength(0);
  });
  it("APNs 만료는 창 끝과 다음 조용한 시간 시작 중 이른 쪽 (늦게 켜진 기기에 조용한 시간 · 창 밖 보고가 가지 않게)", async () => {
    const expirationOf = async (overrides: Partial<ReportPreferenceRow>, now: Date) => {
      const { store } = fakeStore({ prefs: [pref(ALICE, overrides)], devices: [device(ALICE, "d1", "a".repeat(64))] });
      const apns = fakeApns();
      await run(store, apns.transport, now);
      expect(apns.sent, JSON.stringify(overrides)).toHaveLength(1);
      return apns.sent[0].headers["apns-expiration"];
    };
    const seconds = (iso: string) => String(Date.parse(iso) / 1000);
    // 08:30 KST 보고: 창 끝 10:30 KST가 22:00보다 이르다
    expect(await expirationOf({}, SEOUL_0830)).toBe(seconds("2026-10-10T01:30:00Z"));
    // 21:00 KST 보고: 창 끝 23:00 KST보다 조용한 시간 시작 22:00 KST가 이르다
    expect(await expirationOf({ daily_time: "21:00" }, new Date("2026-10-10T12:00:00Z"))).toBe(seconds("2026-10-10T13:00:00Z"));
    // 조용한 시간을 끄면 창 끝 (23:00 보고 → 다음 날 01:00 KST)
    expect(await expirationOf({ daily_time: "23:00", quiet_start: null, quiet_end: null }, new Date("2026-10-10T14:00:00Z"))).toBe(seconds("2026-10-10T16:00:00Z"));
  });

  it("사용자 하나의 실패(잡기 오류)는 errors로 세고 다음 사용자는 보낸다. 대기 행 닫기가 실패해도 계속한다", async () => {
    const { store, state } = fakeStore({
      prefs: [pref(ALICE), pref(BOB)],
      devices: [device(ALICE, "d1", "a".repeat(64)), device(BOB, "d2", "b".repeat(64))],
    });
    state.failClaimFor.add(ALICE);
    state.failFinish = true;
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(result).toMatchObject({ errors: 2, due: 2, claimed: 1, sent: 1 });
    expect(apns.sent.map((r) => r.path)).toEqual([`/3/device/${"b".repeat(64)}`]);
    expect(console.error).toHaveBeenCalledWith(`일일 보고 보내기 실패 (${ALICE}):`, "connection reset");
  });

  it("시각은 잡기 · 보내기 · 기록마다 시계를 다시 읽는다 (실행이 길어도 낡은 시각을 쓰지 않는다)", async () => {
    let t = SEOUL_0830.getTime();
    const clock = () => (t += 1_000);
    const { store, state } = fakeStore({
      prefs: [pref(ALICE), pref(BOB)],
      devices: [device(ALICE, "d1", "a".repeat(64)), device(BOB, "d2", "b".repeat(64))],
    });
    const apns = fakeApns({ ["b".repeat(64)]: () => ({ status: 503, body: "" }) });
    await run(store, apns.transport, clock);
    const [aliceClaim, bobClaim] = state.claims;
    expect(bobClaim.now.getTime()).toBeGreaterThan(aliceClaim.now.getTime());
    expect(state.recordTimes[0].getTime()).toBeGreaterThan(aliceClaim.now.getTime());
    expect(state.recordTimes[1].getTime()).toBeGreaterThan(bobClaim.now.getTime());
    // 다시 보낼 시각은 실패를 본 뒤의 시계로부터 5분
    const bobRetry = state.records[1].outcome as { nextAttemptAt: Date };
    expect(bobRetry.nextAttemptAt.getTime() - minutes(5)).toBeGreaterThan(bobClaim.now.getTime());
  });

  it("기록할 때 펜스가 맞지 않으면(그 사이 다른 실행이 다시 잡음) sent로 세지 않고 id만 로그로 남긴다", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    state.reclaimBeforeRecord.add(ALICE);
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(apns.sent).toHaveLength(1);
    expect(result).toMatchObject({ claimed: 1, sent: 0, fence_missed: 1 });
    expect(state.records).toEqual([]);
    expect(console.error).toHaveBeenCalledWith("일일 보고 기록 펜스 불일치 (delivery-1, attempts 1)");
  });
  it("숫자는 보내는 순간의 현지 날짜로 센다: 자정 직전(23:50) 보고를 00:00에 보내면 '오늘 마감'은 새 날짜 기준 (원장 날짜는 그대로)", async () => {
    const { store, state } = fakeStore({
      prefs: [pref(ALICE, { daily_time: "23:50", quiet_start: null, quiet_end: null })],
      devices: [device(ALICE, "d1", "a".repeat(64))],
    });
    const apns = fakeApns();
    // 10-10 23:50 KST 보고를 10-11 00:00 KST(10-10 15:00Z) 실행이 잡는다
    await run(store, apns.transport, new Date("2026-10-10T15:00:00Z"));
    expect(state.claims[0].reportDate).toBe("2026-10-10");
    expect(state.countDays).toEqual(["2026-10-11"]);
  });

  it("APNs 응답에 상태가 없으면(NaN) DB check에 맞는 apns_0으로, 일시 오류로 다룬다", () => {
    expect(pushErrorCode({ ok: false, status: Number.NaN, reason: null, unregistered: false })).toEqual({ transient: true, code: "apns_0" });
    expect(pushErrorCode({ ok: false, status: 429, reason: "TooManyRequests", unregistered: false })).toEqual({ transient: true, code: "apns_429_toomanyrequests" });
    expect(pushErrorCode({ ok: false, status: 400, reason: "Bad Topic!", unregistered: false })).toEqual({ transient: false, code: "apns_400" });
    for (const { code } of [pushErrorCode({ ok: false, status: Number.NaN, reason: "x".repeat(200), unregistered: false })]) expect(code).toMatch(/^[a-z0-9_]{1,64}$/);
  });

  describe("일정 변경과 보내기의 경합 (schedule_version)", () => {
    const TOKEN = "a".repeat(64);
    /** 처음 n번은 503, 그다음은 200. 보낸 시각을 남긴다 */
    function flaky(failFirst: number, clock: () => number) {
      const sentAt: string[] = [];
      const transport: Transport = async () => {
        sentAt.push(new Date(clock()).toISOString());
        return sentAt.length <= failFirst ? { status: 503, body: "" } : { status: 200, body: "" };
      };
      return { transport, sentAt };
    }

    it("08:30 실패 → 08:31 daily 18:00으로 바꿈 → 08:35 다시 보내기: 옛 08:30 보고는 가지 않고(skipped schedule_changed), 18:00 보고가 한 번", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      let t = SEOUL_0830.getTime();
      const apns = flaky(1, () => t);
      const tick = (iso: string) => ((t = Date.parse(iso)), run(store, apns.transport, () => t));
      await tick("2026-10-09T23:30:00Z"); // 08:30 KST: 503 → 대기
      put(ALICE, { daily_time: "18:00" }, new Date("2026-10-09T23:31:00Z"));
      for (let m = 35; m < 60; m += 5) await tick(`2026-10-09T23:${m}:00Z`);
      expect(apns.sentAt).toEqual(["2026-10-09T23:30:00.000Z"]);
      expect(state.deliveries[0]).toMatchObject({ status: "skipped", last_error: "schedule_changed" });
      for (let h = 0; h <= 10; h++) await tick(`2026-10-10T${String(h).padStart(2, "0")}:00:00Z`);
      for (let m = 5; m < 60; m += 5) await tick(`2026-10-10T09:${m}:00Z`);
      expect(apns.sentAt).toEqual(["2026-10-09T23:30:00.000Z", "2026-10-10T09:00:00.000Z"]); // 18:00 KST 한 번
      expect(state.deliveries.map((d) => [d.report_date, d.status])).toEqual([
        ["2026-10-10", "skipped"],
        ["2026-10-10", "sent"],
      ]);
    });

    it("08:30 실패 → 08:31 시간대를 런던으로 → 옛 서울 보고는 가지 않고, 런던 10-10 08:30 BST(07:30Z) 보고가 한 번", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      let t = SEOUL_0830.getTime();
      const apns = flaky(1, () => t);
      const tick = (ms: number) => ((t = ms), run(store, apns.transport, () => t));
      await tick(SEOUL_0830.getTime());
      put(ALICE, { time_zone: "Europe/London" }, new Date("2026-10-09T23:31:00Z"));
      for (let ms = Date.parse("2026-10-09T23:35:00Z"); ms <= Date.parse("2026-10-10T10:00:00Z"); ms += minutes(5)) await tick(ms);
      expect(apns.sentAt).toEqual(["2026-10-09T23:30:00.000Z", "2026-10-10T07:30:00.000Z"]);
      expect(state.deliveries.map((d) => [d.time_zone, d.report_date, d.status, d.last_error])).toEqual([
        ["Asia/Seoul", "2026-10-10", "skipped", "schedule_changed"],
        ["Europe/London", "2026-10-10", "sent", null],
      ]);
    });

    it("cron이 설정을 읽은 뒤 PUT이 일정을 바꾸면 옛 계획으로는 잡지 않고, 다음 실행이 새 일정으로 보낸다", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      const read = store.dailyPreferences;
      let putOnRead = true;
      store.dailyPreferences = async () => {
        const rows = structuredClone(await read());
        if (putOnRead) put(ALICE, { daily_time: "18:00" }, new Date("2026-10-09T23:30:00Z"));
        putOnRead = false;
        return rows;
      };
      const apns = fakeApns();
      expect(await run(store, apns.transport, SEOUL_0830)).toMatchObject({ due: 1, claimed: 0 });
      expect(state.claims[0].preferencesVersion).toBe(1);
      expect(state.deliveries).toEqual([]);
      expect(await run(store, apns.transport, new Date("2026-10-10T09:00:00Z"))).toMatchObject({ claimed: 1, sent: 1 });
      expect(state.claims[1].preferencesVersion).toBe(2);
      expect(apns.sent).toHaveLength(1);
    });

    it("이미 보낸 날은 일정을 바꿔도 다시 보내지 않는다 (08:30 보냄 → 09:00에 18:00으로 → 18:00에 없음)", async () => {
      const { store, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      const apns = fakeApns();
      await run(store, apns.transport, SEOUL_0830);
      put(ALICE, { daily_time: "18:00" }, new Date("2026-10-10T00:00:00Z"));
      expect(await run(store, apns.transport, new Date("2026-10-10T09:00:00Z"))).toMatchObject({ due: 0, claimed: 0 });
      expect(apns.sent).toHaveLength(1);
    });

    it("보내는 중(임대 중)에 일정을 바꾸면 그 보고는 한 번 가고, 그 현지 날은 보낸 날이다 (두 번째 없음)", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      const sent: string[] = [];
      const transport: Transport = async () => {
        put(ALICE, { daily_time: "18:00" }, new Date("2026-10-09T23:30:30Z")); // APNs 요청 중에 PUT이 커밋
        sent.push("x");
        return { status: 200, body: "" };
      };
      await run(store, transport, SEOUL_0830);
      expect(state.deliveries[0]).toMatchObject({ status: "sent", schedule_version: 1 });
      expect(state.prefs[0].schedule_version).toBe(2);
      expect(await run(store, transport, new Date("2026-10-10T09:00:00Z"))).toMatchObject({ due: 0, claimed: 0 });
      expect(sent).toHaveLength(1);
    });

    it("Respect Focus만 바꾸면 일정 세대가 그대로라 실패한 보고를 그대로 다시 보낸다", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      let t = SEOUL_0830.getTime();
      const apns = flaky(1, () => t);
      await run(store, apns.transport, () => t);
      put(ALICE, { respect_focus: false }, new Date("2026-10-09T23:31:00Z"));
      expect(state.prefs[0].schedule_version).toBe(1);
      t = Date.parse("2026-10-09T23:35:00Z");
      expect(await run(store, apns.transport, () => t)).toMatchObject({ retried: 1, sent: 1 });
      expect(apns.sentAt).toEqual(["2026-10-09T23:30:00.000Z", "2026-10-09T23:35:00.000Z"]);
    });
      it("08:30 보내기의 결과를 모름(응답 시간 초과) → 08:31 18:00으로 → 옛 행은 failed schedule_changed_unknown, 그날 18:00 보고는 없다 (갔을 수 있다)", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      let t = SEOUL_0830.getTime();
      let calls = 0;
      const transport: Transport = async () => {
        calls++;
        if (calls === 1) throw new Error("APNs 응답 시간 초과");
        return { status: 200, body: "" };
      };
      await run(store, transport, () => t);
      expect(state.deliveries[0]).toMatchObject({ status: "pending", last_error: "network" });
      put(ALICE, { daily_time: "18:00" }, new Date("2026-10-09T23:31:00Z"));
      for (let ms = Date.parse("2026-10-09T23:35:00Z"); ms <= Date.parse("2026-10-10T10:00:00Z"); ms += minutes(5)) {
        t = ms;
        await run(store, transport, () => t);
      }
      expect(calls).toBe(1);
      expect(state.deliveries).toHaveLength(1);
      expect(state.deliveries[0]).toMatchObject({ status: "failed", last_error: "schedule_changed_unknown" });
    });

    it("결과를 모르는 대기 행의 사용자가 일일 보고를 끄면 failed mode_changed_unknown (그날을 막는다), 분명한 실패면 skipped mode_changed", async () => {
      const row = (id: string, userId: string, lastError: string): ReportDeliveryRow => ({
        id,
        user_id: userId,
        kind: "daily",
        time_zone: "Asia/Seoul",
        report_date: "2026-10-10",
        scheduled_at: "2026-10-09T23:30:00Z",
        expires_at: "2026-10-10T01:30:00Z",
        status: "pending",
        attempts: 1,
        next_attempt_at: "2026-10-09T23:35:00Z",
        last_error: lastError,
      });
      const { store, state } = fakeStore({
        prefs: [pref(ALICE, { mode: "meaningful" }), pref(BOB, { mode: "meaningful" })],
        deliveries: [row("a", ALICE, "network"), row("b", BOB, "apns_503")],
      });
      await run(store, fakeApns().transport, after(SEOUL_0830, minutes(5)));
      expect(state.records).toEqual([
        { id: "a", outcome: { status: "failed", lastError: "mode_changed_unknown" } },
        { id: "b", outcome: { status: "skipped", lastError: "mode_changed" } },
      ]);
    });

    it("겹친 실행이 낡은 설정(Respect Focus 켬)을 읽은 뒤 PUT이 끄면, 그 실행의 다시 보내기는 아무것도 하지 않고(닫지도 잡지도 않음) 다음 실행이 새 설정으로 보낸다", async () => {
      const { store, state, put } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", TOKEN)] });
      let t = SEOUL_0830.getTime();
      const apns = flaky(1, () => t);
      await run(store, apns.transport, () => t);
      const read = store.dailyPreferences;
      let putOnRead = true;
      store.dailyPreferences = async () => {
        const rows = structuredClone(await read());
        if (putOnRead) put(ALICE, { respect_focus: false }, new Date("2026-10-09T23:35:00Z"));
        putOnRead = false;
        return rows;
      };
      t = Date.parse("2026-10-09T23:35:00Z");
      expect(await run(store, apns.transport, () => t)).toMatchObject({ retried: 0, sent: 0 });
      expect(state.deliveries[0]).toMatchObject({ status: "pending", attempts: 1 });
      t = Date.parse("2026-10-09T23:40:00Z");
      expect(await run(store, apns.transport, () => t)).toMatchObject({ retried: 1, sent: 1 });
      expect(apns.sentAt).toHaveLength(2);
    });
  });
});
