import { generateKeyPairSync } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ApnsConfig, Transport } from "@/lib/notify/apns";

import {
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
    ...overrides,
  };
}

const device = (userId: string, id: string, token: string): ReportDevice => ({ id, user_id: userId, token, environment: "sandbox" });

/** 사용자의 열린 할 일 (가짜 report_status_counts가 센다). 제목 · 상대 · 메모는 알림에 실리면 안 되는 글이다 */
type FakeAction = { title: string; counterpart: string; notes: string; needs_confirmation: boolean; due_date: string | null };

/** DB 함수 claim_report_delivery · claim_report_retry · finish_stale_report_deliveries의 규칙을 흉내 내는 메모리 저장소 */
function fakeStore(init: { prefs: ReportPreferenceRow[]; devices?: ReportDevice[]; actions?: Record<string, FakeAction[]>; deliveries?: ReportDeliveryRow[] }) {
  const state = {
    prefs: init.prefs,
    devices: [...(init.devices ?? [])],
    deliveries: [...(init.deliveries ?? [])],
    records: [] as { id: string; outcome: DeliveryOutcome }[],
    claims: [] as ClaimInput[],
    removed: [] as string[],
    failRecordFor: new Set<string>(),
    failCountsFor: new Set<string>(),
  };
  let seq = 0;
  const store: ReportStore = {
    async finishStale(now, max) {
      let n = 0;
      for (const d of state.deliveries) {
        if (d.status === "pending" && Date.parse(d.next_attempt_at!) <= now.getTime() && (now.getTime() > Date.parse(d.expires_at) || d.attempts >= max)) {
          d.status = "failed";
          d.next_attempt_at = null;
          n++;
        }
      }
      return n;
    },
    dailyPreferences: async () => state.prefs.filter((p) => p.mode !== "meaningful"),
    async lastScheduled(since) {
      const last = new Map<string, Date>();
      for (const d of state.deliveries) {
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
      state.claims.push(input);
      if (state.deliveries.some((d) => d.user_id === input.userId && Date.parse(d.scheduled_at) >= input.dayStart.getTime())) return null;
      const row: ReportDeliveryRow = {
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
      };
      state.deliveries.push(row);
      return { ...row };
    },
    async claimRetry(id, now, leaseSeconds, max) {
      const d = state.deliveries.find((x) => x.id === id);
      if (!d || d.status !== "pending" || Date.parse(d.next_attempt_at!) > now.getTime() || d.attempts >= max || now.getTime() > Date.parse(d.expires_at)) return null;
      d.attempts++;
      d.next_attempt_at = new Date(now.getTime() + leaseSeconds * 1000).toISOString();
      return { ...d };
    },
    async statusCounts(userId, today): Promise<ReportStatusCounts> {
      if (state.failCountsFor.has(userId)) throw new Error("connection reset");
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
    async record(delivery, outcome) {
      if (state.failRecordFor.has(delivery.user_id)) throw new Error("timeout");
      state.records.push({ id: delivery.id, outcome });
      const d = state.deliveries.find((x) => x.id === delivery.id && x.attempts === delivery.attempts && x.status === "pending");
      if (!d) return;
      d.status = outcome.status;
      d.next_attempt_at = outcome.status === "pending" ? outcome.nextAttemptAt.toISOString() : null;
    },
  };
  return { store, state };
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

const run = (store: ReportStore, transport: Transport, now: Date, deadline = Number.POSITIVE_INFINITY) =>
  runDailyReports(store, { config, transport }, { now, deadline });

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

  it("다시 보낼 차례여도 지금 조용한 시간이거나 일일 보고를 끈 사용자면 두고(held), 보내지 않는다", async () => {
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
    });
    const { store } = fakeStore({
      prefs: [pref(ALICE, { daily_time: "21:50" }), pref(BOB, { mode: "meaningful" })],
      devices: [device(ALICE, "d1", "a".repeat(64)), device(BOB, "d2", "b".repeat(64))],
      deliveries: [pending(ALICE), pending(BOB)],
    });
    const apns = fakeApns();
    // 22:05 KST: 조용한 시간
    const result = await run(store, apns.transport, new Date("2026-10-10T13:05:00Z"));
    expect(result).toMatchObject({ held: 2, retried: 0, claimed: 0 });
    expect(apns.sent).toHaveLength(0);
  });

  it("실행 시간이 모자라면 새로 잡지 않는다 (deferred_for_time, 다음 실행이 창 안에서 잡는다)", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE)], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830, Date.now() - 1);
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

  it("숫자를 읽지 못하면 internal로 다시 시도하고, 기록이 실패해도 다른 사용자는 계속 보낸다", async () => {
    const { store, state } = fakeStore({
      prefs: [pref(ALICE), pref(BOB)],
      devices: [device(ALICE, "d1", "a".repeat(64)), device(BOB, "d2", "b".repeat(64))],
    });
    state.failCountsFor.add(ALICE);
    state.failRecordFor.add(BOB);
    const apns = fakeApns();
    const result = await run(store, apns.transport, SEOUL_0830);
    expect(result).toMatchObject({ claimed: 2, retrying: 1, sent: 1 });
    expect(state.records).toEqual([{ id: "delivery-1", outcome: { status: "pending", lastError: "internal", nextAttemptAt: after(SEOUL_0830, minutes(5)) } }]);
    expect(apns.sent.map((r) => r.path)).toEqual([`/3/device/${"b".repeat(64)}`]);
    expect(console.error).toHaveBeenCalledWith("일일 보고 기록 실패 (delivery-2):", "timeout");
  });

  it("예정 전 · meaningful 사용자는 잡지 않는다", async () => {
    const { store, state } = fakeStore({ prefs: [pref(ALICE), pref(BOB, { mode: "meaningful" })], devices: [device(ALICE, "d1", "a".repeat(64))] });
    const apns = fakeApns();
    expect(await run(store, apns.transport, after(SEOUL_0830, -minutes(1)))).toMatchObject({ preferences: 1, due: 0 });
    expect(state.claims).toHaveLength(0);
  });
});
