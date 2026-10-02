import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";

import { loadExecution } from "./load";

vi.mock("server-only", () => ({}));

// 실행 지표 읽기 (U2): 숫자 열만 읽고(요청 · 초안 · receipt 없음), 실행 표가 없으면(마이그레이션 적용 전) null로 두고 지표 화면은 그대로 뜬다.

const period = { from: new Date("2026-09-21T00:00:00Z"), to: new Date("2026-09-28T00:00:00Z") };

type Call = { table: string; method: string; args: unknown[] };

/** 표마다 정한 행을 돌려주는 가짜 service role 클라이언트. 부른 메서드를 남긴다. Error를 주면 그 표 읽기가 실패한다 */
function fakeAdmin(tables: Record<string, unknown[] | Error>) {
  const calls: Call[] = [];
  const admin = {
    from(table: string) {
      const result = tables[table] ?? [];
      let head = false;
      const builder: Record<string, unknown> = {};
      for (const method of ["gte", "eq", "or", "order"]) {
        builder[method] = (...args: unknown[]) => {
          calls.push({ table, method, args });
          return builder;
        };
      }
      builder.select = (columns: string, options?: { head?: boolean }) => {
        calls.push({ table, method: "select", args: [columns] });
        head = options?.head ?? false;
        return builder;
      };
      builder.range = async () => (result instanceof Error ? { data: null, error: result } : { data: result, error: null });
      builder.throwOnError = async () => {
        if (result instanceof Error) throw result;
        return head ? { data: null, count: result.length } : { data: result };
      };
      return builder;
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("loadExecution", () => {
  it("숫자 열만 읽어 실행 지표를 만든다: 정산 행만, 결과 불명 단계 수, 막힘 · 승인 대기 이벤트만", async () => {
    const { admin, calls } = fakeAdmin({
      execution_runs: [
        { state: "done", created_at: "2026-09-22T00:00:00Z" },
        { state: "running", created_at: "2026-09-23T00:00:00Z" },
      ],
      execution_events: [
        { type: "hold", to_state: "credit", at: "2026-09-22T00:00:00Z" },
        { type: "run", to_state: "waiting_approval", at: "2026-09-22T00:00:00Z" },
      ],
      execution_steps: [{}, {}, {}],
      // numeric 열은 문자열로 와도 숫자로 읽는다
      execution_usage: [
        { cost_usd: "0.004", cost_status: "confirmed", billable: true, created_at: "2026-09-22T00:00:00Z" },
        { cost_usd: 0.001, cost_status: "confirmed", billable: false, created_at: "2026-09-22T00:00:00Z" },
        { cost_usd: null, cost_status: "unconfirmed", billable: true, created_at: "2026-09-22T00:00:00Z" },
      ],
      credit_ledger: [{ credits: 4, rate_version: "c3-v1", created_at: "2026-09-22T00:00:01Z" }],
      credit_rates: [{ version: "c3-v1", usd_per_credit: "0.001" }],
    });

    const metric = await loadExecution(admin, period);

    expect(metric).toMatchObject({
      runs: 2,
      byState: { done: 1, running: 1 },
      unknownOutcome: 3,
      approvalRequests: 1,
      holds: { credit: 1 },
      cost: { unconfirmed: 1 },
      charged: { credits: 4 },
    });
    expect(metric!.cost.billableUsd).toBeCloseTo(0.004, 10);
    expect(metric!.cost.platformUsd).toBeCloseTo(0.001, 10);
    expect(metric!.charged.usd).toBeCloseTo(0.004, 10);

    const selected = Object.fromEntries(calls.filter((c) => c.method === "select").map((c) => [c.table, c.args[0]]));
    expect(selected).toEqual({
      execution_runs: "state, created_at",
      execution_events: "type, to_state, at",
      execution_steps: "id",
      execution_usage: "cost_usd, cost_status, billable, created_at",
      credit_ledger: "credits, rate_version, created_at",
      credit_rates: "version, usd_per_credit",
    });
    const filters = calls.filter((c) => ["eq", "or", "gte"].includes(c.method)).map((c) => [c.table, c.method, ...c.args]);
    const since = period.from.toISOString();
    expect(filters).toEqual([
      ["execution_runs", "gte", "created_at", since],
      ["execution_events", "or", "type.eq.hold,to_state.eq.waiting_approval"],
      ["execution_events", "gte", "at", since],
      // 결과 불명은 기간과 상관없이 지금 수
      ["execution_steps", "eq", "state", "unknown_outcome"],
      ["execution_usage", "gte", "created_at", since],
      ["credit_ledger", "eq", "kind", "settle"],
      ["credit_ledger", "gte", "created_at", since],
    ]);
  });

  it("실행 표를 읽지 못하면(마이그레이션 적용 전) null, 로그에는 오류 메시지만", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = fakeAdmin({ execution_runs: new Error('relation "public.execution_runs" does not exist') });

    expect(await loadExecution(admin, period)).toBeNull();
    expect(error).toHaveBeenCalledWith("실행 지표 읽기 실패:", 'relation "public.execution_runs" does not exist');
  });
});
