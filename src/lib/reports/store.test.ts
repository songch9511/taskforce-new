import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import type { ReportPreferencesRequest } from "@/lib/api/contract";

import type { ReportDeliveryRow } from "./job";
import { supabaseReportStore, writeReportPreferences } from "./store";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));

// store.ts가 DB 함수 · 표에 보내는 것 (함수 이름 · 인자 이름 · 필터 · 펜스 · 행 수). 함수 자체의 동작은 tests/db · tests/pg가 본다.

type Call = { table?: string; rpc?: string; args?: unknown; ops: unknown[][] };
type Reply = { data?: unknown; error?: { code: string; message: string } | null };

/** 호출을 적어 두는 가짜 supabase-js: 어떤 메서드든 이어 부를 수 있고, await하면 reply(call)을 돌려준다 (throwOnError면 오류를 던진다) */
function fakeAdmin(reply: (call: Call) => Reply = () => ({ data: [] })) {
  const calls: Call[] = [];
  const builder = (call: Call): unknown =>
    new Proxy(
      {},
      {
        get(_target, prop) {
          if (prop === "then") {
            const { data = null, error = null } = reply(call);
            const throws = call.ops.some(([op]) => op === "throwOnError");
            const settled = error && throws ? Promise.reject(error) : Promise.resolve({ data, error });
            return settled.then.bind(settled);
          }
          return (...args: unknown[]) => {
            call.ops.push([String(prop), ...args]);
            return builder(call);
          };
        },
      },
    );
  const admin = {
    from: (table: string) => {
      const call: Call = { table, ops: [] };
      calls.push(call);
      return builder(call);
    },
    rpc: (rpc: string, args: unknown) => {
      const call: Call = { rpc, args, ops: [] };
      calls.push(call);
      return builder(call);
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

const DELIVERY: ReportDeliveryRow = {
  id: "d-1",
  user_id: "u-1",
  kind: "daily",
  time_zone: "Asia/Seoul",
  report_date: "2026-10-10",
  scheduled_at: "2026-10-09T23:30:00Z",
  expires_at: "2026-10-10T01:30:00Z",
  status: "pending",
  attempts: 2,
  next_attempt_at: "2026-10-09T23:35:00Z",
  last_error: null,
};

const NOW = new Date("2026-10-09T23:30:00Z");

describe("supabaseReportStore: DB 함수 호출", () => {
  it("claim은 claim_report_delivery에 p_ 인자로 시각을 ISO로 보내고, 잡힌 첫 행(없으면 null)을 돌려준다", async () => {
    const { admin, calls } = fakeAdmin((call) => ({ data: call.rpc ? [DELIVERY] : [] }));
    const store = supabaseReportStore(admin);
    const input = {
      userId: "u-1",
      timeZone: "Asia/Seoul",
      reportDate: "2026-10-10",
      dayStart: new Date("2026-10-09T15:00:00Z"),
      scheduledAt: new Date("2026-10-09T23:30:00Z"),
      expiresAt: new Date("2026-10-10T01:30:00Z"),
      now: NOW,
      leaseSeconds: 300,
      preferencesVersion: 4,
    };
    expect(await store.claim(input)).toEqual(DELIVERY);
    expect(calls[0]).toMatchObject({
      rpc: "claim_report_delivery",
      args: {
        p_user_id: "u-1",
        p_kind: "daily",
        p_time_zone: "Asia/Seoul",
        p_report_date: "2026-10-10",
        p_day_start: "2026-10-09T15:00:00.000Z",
        p_scheduled_at: "2026-10-09T23:30:00.000Z",
        p_expires_at: "2026-10-10T01:30:00.000Z",
        p_now: "2026-10-09T23:30:00.000Z",
        p_lease_seconds: 300,
        p_preferences_version: 4,
      },
    });
    expect(calls[0].ops).toContainEqual(["throwOnError"]);
    expect(await supabaseReportStore(fakeAdmin(() => ({ data: [] })).admin).claim(input)).toBeNull();
  });

  it("claimRetry · finishStale · statusCounts의 함수 이름과 인자", async () => {
    const { admin, calls } = fakeAdmin((call) => {
      if (call.rpc === "finish_stale_report_deliveries") return { data: 3 };
      if (call.rpc === "report_status_counts") return { data: [{ review: 1, overdue: 0, due_today: 2, in_progress: 0 }] };
      return { data: [] };
    });
    const store = supabaseReportStore(admin);
    expect(await store.claimRetry("d-1", NOW, 300, 3, 7)).toBeNull();
    expect(await store.finishStale(NOW, 3)).toBe(3);
    expect(await store.statusCounts("u-1", "2026-10-10")).toEqual({ review: 1, overdue: 0, due_today: 2, in_progress: 0 });
    expect(calls.map((c) => [c.rpc, c.args])).toEqual([
      ["claim_report_retry", { p_id: "d-1", p_now: "2026-10-09T23:30:00.000Z", p_lease_seconds: 300, p_max_attempts: 3, p_preferences_version: 7 }],
      ["finish_stale_report_deliveries", { p_now: "2026-10-09T23:30:00.000Z", p_max_attempts: 3 }],
      ["report_status_counts", { p_user_id: "u-1", p_today: "2026-10-10" }],
    ]);
    expect(await supabaseReportStore(fakeAdmin(() => ({ data: [] })).admin).statusCounts("u-1", "2026-10-10")).toEqual({ review: 0, overdue: 0, due_today: 0, in_progress: 0 });
  });

  it("DB 함수 오류는 던진다 (job이 사용자별로 errors로 센다)", async () => {
    const { admin } = fakeAdmin(() => ({ error: { code: "42501", message: "permission denied" } }));
    await expect(supabaseReportStore(admin).claimRetry("d-1", NOW, 300, 3, 1)).rejects.toMatchObject({ code: "42501" });
  });
});

describe("supabaseReportStore: 원장 · 설정 읽기", () => {
  it("dailyPreferences는 일일 보고가 켜진 모드만 (일정 세대 포함), lastScheduled는 그날을 막는 행 중 사용자별 가장 늦은 명목 시각", async () => {
    const { admin, calls } = fakeAdmin((call) =>
      call.table === "report_deliveries"
        ? {
            data: [
              { user_id: "a", scheduled_at: "2026-10-08T23:30:00Z", status: "sent", last_error: null },
              { user_id: "a", scheduled_at: "2026-10-09T23:30:00Z", status: "skipped", last_error: "empty" },
              // 보내지 않고 닫힌 일정 변경 · 모드 변경 행은 그날을 막지 않는다
              { user_id: "a", scheduled_at: "2026-10-10T23:30:00Z", status: "skipped", last_error: "schedule_changed" },
              { user_id: "b", scheduled_at: "2026-10-09T07:30:00Z", status: "pending", last_error: null },
              { user_id: "b", scheduled_at: "2026-10-10T07:30:00Z", status: "skipped", last_error: "mode_changed" },
              { user_id: "c", scheduled_at: "2026-10-10T07:30:00Z", status: "skipped", last_error: "schedule_changed" },
            ],
          }
        : { data: [] },
    );
    const store = supabaseReportStore(admin);
    await store.dailyPreferences();
    expect(calls[0].table).toBe("report_preferences");
    expect(calls[0].ops).toContainEqual(["in", "mode", ["both", "daily"]]);
    expect(String(calls[0].ops.find(([op]) => op === "select")?.[1])).toMatch(/schedule_version, version$/);
    const last = await store.lastScheduled(new Date("2026-10-07T00:00:00Z"));
    expect(calls[1].ops).toEqual(expect.arrayContaining([["eq", "kind", "daily"], ["gte", "scheduled_at", "2026-10-07T00:00:00.000Z"]]));
    expect([...last.entries()]).toEqual([
      ["a", new Date("2026-10-09T23:30:00Z")],
      ["b", new Date("2026-10-09T07:30:00Z")],
    ]);
  });
});

describe("supabaseReportStore.retryable", () => {
  it("다시 보낼 차례인 대기 행을 last_error와 함께 읽는다 (결과를 모르는 행을 job이 가린다)", async () => {
    const { admin, calls } = fakeAdmin(() => ({ data: [DELIVERY] }));
    expect(await supabaseReportStore(admin).retryable(NOW, 3)).toEqual([DELIVERY]);
    expect(String(calls[0].ops.find(([op]) => op === "select")?.[1])).toMatch(/last_error$/);
    expect(calls[0].ops).toEqual(
      expect.arrayContaining([
        ["eq", "status", "pending"],
        ["lte", "next_attempt_at", NOW.toISOString()],
        ["gte", "expires_at", NOW.toISOString()],
        ["lt", "attempts", 3],
      ]),
    );
  });
});

describe("supabaseReportStore.record: 펜스와 바뀐 행 수", () => {
  it.each<[string, Parameters<ReturnType<typeof supabaseReportStore>["record"]>[1], Record<string, unknown>]>([
    ["sent", { status: "sent" }, { status: "sent", sent_at: NOW.toISOString(), next_attempt_at: null, last_error: null }],
    [
      "pending",
      { status: "pending", lastError: "apns_503", nextAttemptAt: new Date("2026-10-09T23:35:00Z") },
      { status: "pending", next_attempt_at: "2026-10-09T23:35:00.000Z", last_error: "apns_503" },
    ],
    ["skipped", { status: "skipped", lastError: "mode_changed" }, { status: "skipped", next_attempt_at: null, last_error: "mode_changed" }],
  ])("%s: 잡을 때의 attempts · pending일 때만 고치고, 바뀐 행 수를 돌려준다", async (_name, outcome, fields) => {
    const { admin, calls } = fakeAdmin(() => ({ data: [{ id: "d-1" }] }));
    expect(await supabaseReportStore(admin).record(DELIVERY, outcome, NOW)).toBe(1);
    expect(calls[0].table).toBe("report_deliveries");
    expect(calls[0].ops).toEqual([
      ["update", fields],
      ["eq", "id", "d-1"],
      ["eq", "attempts", 2],
      ["eq", "status", "pending"],
      ["select", "id"],
      ["throwOnError"],
    ]);
  });

  it("펜스가 맞지 않으면 0 (job이 sent로 세지 않는다)", async () => {
    const { admin } = fakeAdmin(() => ({ data: [] }));
    expect(await supabaseReportStore(admin).record(DELIVERY, { status: "sent" }, NOW)).toBe(0);
  });
});

describe("writeReportPreferences: 비교 후 쓰기", () => {
  const REQUEST: ReportPreferencesRequest = {
    mode: "both",
    daily_time: "08:30",
    quiet_start: "22:00",
    quiet_end: "08:00",
    respect_focus: true,
    time_zone: "Asia/Seoul",
    expected_version: null,
  };
  const ROW = { mode: "both", daily_time: "08:30", quiet_start: "22:00", quiet_end: "08:00", respect_focus: true, time_zone: "Asia/Seoul", version: 1 };

  it("expected_version null이면 insert (expected_version은 쓰지 않는다)하고 저장된 행을 돌려준다", async () => {
    const { admin, calls } = fakeAdmin(() => ({ data: ROW }));
    expect(await writeReportPreferences(admin, "u-1", REQUEST)).toEqual({ ...ROW, saved: true });
    const { expected_version: _omitted, ...fields } = REQUEST;
    void _omitted;
    expect(calls[0].ops[0]).toEqual(["insert", { user_id: "u-1", ...fields }]);
  });

  it("이미 행이 있으면(유일 키 23505) null → 409. 다른 오류는 코드만 담아 던진다", async () => {
    expect(await writeReportPreferences(fakeAdmin(() => ({ error: { code: "23505", message: "duplicate key" } })).admin, "u-1", REQUEST)).toBeNull();
    await expect(writeReportPreferences(fakeAdmin(() => ({ error: { code: "23514", message: "check" } })).admin, "u-1", REQUEST)).rejects.toThrow("보고 설정 만들기 실패 (23514)");
  });

  it("expected_version이 있으면 user_id · version이 맞을 때만 update, 0행이면 null → 409", async () => {
    const { admin, calls } = fakeAdmin(() => ({ data: [{ ...ROW, version: 4 }] }));
    expect(await writeReportPreferences(admin, "u-1", { ...REQUEST, expected_version: 3 })).toEqual({ ...ROW, version: 4, saved: true });
    const { expected_version: _omitted, ...fields } = REQUEST;
    void _omitted;
    expect(calls[0].ops.slice(0, 3)).toEqual([
      ["update", fields],
      ["eq", "user_id", "u-1"],
      ["eq", "version", 3],
    ]);
    expect(await writeReportPreferences(fakeAdmin(() => ({ data: [] })).admin, "u-1", { ...REQUEST, expected_version: 3 })).toBeNull();
  });
});
