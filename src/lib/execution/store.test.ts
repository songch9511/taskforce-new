import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/connectors/store", () => ({ loadIdentity: vi.fn(async () => ({ name: "김도윤", aliases: [], emails: [] })) }));

import { buildExecutionContext } from "./context";
import { createRun, loadCredits, stopRun, supabaseExecutionStore } from "./store";
import { RunActionNotFoundError } from "./types";

// 운영 store(supabase-js)의 읽기 · RPC. PostgREST 대신 표 데이터를 거르는 작은 가짜 클라이언트로 본다 (eq · in · not · gt · lt · gte · maybeSingle).
// 실제 SQL 함수는 tests/db/execution-executor.test.ts가 PGlite에서 본다.

type Row = Record<string, unknown>;
type Op = [string, unknown[]];

function matches(row: Row, [op, args]: Op): boolean {
  const [column, a, b] = args as [string, unknown, unknown];
  switch (op) {
    case "eq":
      return row[column] === a;
    case "in":
      return (a as unknown[]).includes(row[column]);
    case "gt":
      return (row[column] as number) > (a as number);
    case "lt":
      return (row[column] as number) < (a as number);
    case "gte":
      return String(row[column]) >= String(a);
    case "not":
      if (a === "is") return row[column] !== null && row[column] !== undefined;
      if (a === "in") return !String(b).slice(1, -1).split(",").includes(String(row[column]));
      throw new Error(`not ${String(a)}`);
    default:
      return true; // select · order · limit
  }
}

function fakeAdmin(tables: Record<string, Row[]>, rpc: (fn: string, args: Row) => Promise<unknown> = async () => null) {
  const queries: { table: string; ops: Op[] }[] = [];
  const from = (table: string) => {
    const ops: Op[] = [];
    queries.push({ table, ops });
    let single = false;
    const result = () => {
      const rows = (tables[table] ?? []).filter((row) => ops.every((op) => matches(row, op)));
      return single ? { data: rows[0] ?? null, error: null } : { data: rows, count: rows.length, error: null };
    };
    const builder: Record<string, unknown> = {
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) => Promise.resolve(result()).then(resolve, reject),
      maybeSingle: () => ((single = true), builder),
      throwOnError: () => builder,
    };
    for (const op of ["select", "eq", "in", "not", "gt", "lt", "gte", "order", "limit"]) {
      builder[op] = (...args: unknown[]) => (ops.push([op, args]), builder);
    }
    return builder;
  };
  const rpcFn = vi.fn((fn: string, args: Row) => ({
    throwOnError: async () => ({ data: await rpc(fn, args) }),
  }));
  return { client: { from, rpc: rpcFn } as unknown as SupabaseClient, queries, rpc: rpcFn };
}

const USER = "u1";

describe("supabaseExecutionStore.loadMaterial", () => {
  it("원문의 서비스는 connections 행에서 읽는다: Slack 연결의 원문(링크 없음)은 자료에서 빠진다", async () => {
    const { client, queries } = fakeAdmin({
      actions: [{ id: "a1", user_id: USER, title: "견적 회신", status: "open", owner: "me", due_date: null, counterpart: "박서준" }],
      evidence: [
        { action_id: "a1", user_id: USER, source_id: "s-slack", quote: "slack-secret-7731" },
        { action_id: "a1", user_id: USER, source_id: "s-mail", quote: "견적서 금요일까지" },
      ],
      sources: [
        {
          id: "s-slack",
          user_id: USER,
          kind: "message",
          title: null,
          raw_text: "slack-secret-7731 내부 채널",
          raw_text_purged_at: null,
          raw_text_purge_reason: null,
          occurred_at: "2026-10-01T01:00:00+00:00",
          participants: null,
          external_url: null,
          external_id: "C1:1727740800.000100",
          connection_id: "c-slack",
        },
        {
          id: "s-mail",
          user_id: USER,
          kind: "email",
          title: "Re: 견적",
          raw_text: "박서준: 견적서 금요일까지 회신 부탁드려요.",
          raw_text_purged_at: null,
          raw_text_purge_reason: null,
          occurred_at: "2026-10-01T02:00:00+00:00",
          participants: null,
          external_url: null,
          external_id: "m1",
          connection_id: "c-mail",
        },
      ],
      connections: [
        { id: "c-slack", user_id: USER, provider: "slack" },
        { id: "c-mail", user_id: USER, provider: "gmail" },
        // 다른 사용자의 같은 id 연결은 보지 않는다 (user_id로 좁힌다)
        { id: "c-mail", user_id: "u2", provider: "slack" },
      ],
    });
    const input = await supabaseExecutionStore(client).loadMaterial(USER, "a1");
    expect(input?.sources.map((s) => [s.id, s.provider])).toEqual([
      ["s-slack", "slack"],
      ["s-mail", "gmail"],
    ]);
    const material = JSON.stringify(buildExecutionContext(input!).material);
    expect(material).not.toContain("slack-secret-7731");
    expect(material).toContain("견적서 금요일까지");
    // 모든 읽기를 사용자로 좁혔다
    for (const q of queries) expect(q.ops).toContainEqual(["eq", ["user_id", USER]]);
    expect(queries.find((q) => q.table === "connections")?.ops).toContainEqual(["in", ["id", ["c-slack", "c-mail"]]]);
  });

  it("Action이 없거나 남의 것이면 null (근거를 읽지 않는다)", async () => {
    const { client, queries } = fakeAdmin({ actions: [{ id: "a1", user_id: "u2", title: "x", status: "open", owner: "me", due_date: null, counterpart: null }] });
    expect(await supabaseExecutionStore(client).loadMaterial(USER, "a1")).toBeNull();
    expect(queries.map((q) => q.table)).toEqual(["actions"]);
  });
});

describe("supabaseExecutionStore 읽기", () => {
  it("wakeableRuns: 끝나지 않은 run 중 부르는 중인 단계가 없는 것만, 상한까지", async () => {
    const { client } = fakeAdmin({
      execution_runs: [
        { id: "r1", state: "running", hold_reason: null },
        { id: "r2", state: "queued", hold_reason: null },
        { id: "r3", state: "waiting_approval", hold_reason: "credit" },
        { id: "r4", state: "done", hold_reason: null },
      ],
      execution_steps: [{ run_id: "r2", state: "calling" }],
    });
    const store = supabaseExecutionStore(client);
    expect(await store.wakeableRuns(10)).toEqual([
      { id: "r1", held: false },
      { id: "r3", held: true },
    ]);
    expect(await store.wakeableRuns(1)).toEqual([{ id: "r1", held: false }]);
  });

  it("draftHistory: 끝낸 · 실패한 초안 단계의 지시와 산출물 제목", async () => {
    const { client } = fakeAdmin({
      execution_steps: [
        { id: "d1", run_id: "r1", kind: "draft", state: "called", seq: 2, args: { brief: "회신" } },
        { id: "d2", run_id: "r1", kind: "draft", state: "failed", seq: 4, args: {} },
        { id: "d3", run_id: "r1", kind: "draft", state: "called", seq: 6, args: { brief: "나중" } },
      ],
      execution_artifacts: [{ step_id: "d1", title: "Re: 견적" }],
    });
    expect(await supabaseExecutionStore(client).draftHistory("r1", 5)).toEqual([
      { state: "called", brief: "회신", title: "Re: 견적" },
      { state: "failed", brief: null, title: null },
    ]);
  });

  it("loadCredits: 계정 행의 합계, 지급 기록이 없으면 0", async () => {
    const rates = [{ version: "c3-v1", active: true }];
    expect(await loadCredits(fakeAdmin({ credit_accounts: [{ user_id: USER, granted: 100, reserved: 20, settled: 3 }], credit_rates: rates }).client, USER)).toEqual({
      available: 77,
      reserved: 20,
      rate_version: "c3-v1",
    });
    expect(await loadCredits(fakeAdmin({ credit_rates: rates }).client, USER)).toEqual({ available: 0, reserved: 0, rate_version: "c3-v1" });
  });
});

describe("RPC", () => {
  it("교착(40P01)이면 다시 부른다: stop_run", async () => {
    let calls = 0;
    const { client } = fakeAdmin({}, async () => {
      calls++;
      if (calls === 1) throw Object.assign(new Error("deadlock detected"), { code: "40P01" });
      return "stopped";
    });
    expect(await stopRun(client, USER, "r1")).toBe("stopped");
    expect(calls).toBe(2);
  });

  it("교착이면 다시 부른다: begin_call · complete_internal_step (실행기의 모든 RPC)", async () => {
    const seen: string[] = [];
    const { client } = fakeAdmin({}, async (fn) => {
      seen.push(fn);
      if (seen.filter((f) => f === fn).length === 1) throw Object.assign(new Error("deadlock detected"), { code: "40P01" });
      return fn === "begin_call" ? { gate: "ok" } : true;
    });
    const store = supabaseExecutionStore(client);
    expect(await store.beginCall("s1", "fn-1", 2)).toEqual({ gate: "ok" });
    expect(await store.completeInternalStep("s1", "fn-1", {}, [], null, null)).toBe(true);
    expect(seen).toEqual(["begin_call", "begin_call", "complete_internal_step", "complete_internal_step"]);
  });

  it("create_run이 열린 Action을 찾지 못하면(P0002) RunActionNotFoundError", async () => {
    const { client } = fakeAdmin({}, async () => {
      throw Object.assign(new Error("open action not found"), { code: "P0002" });
    });
    await expect(createRun(client, USER, { actionId: "a1", goal: "draft", request: "초안", budgetCredits: null })).rejects.toBeInstanceOf(RunActionNotFoundError);
  });

  it("complete_internal_step에 시도 기록 · 산출물 · 결과를 그대로 넘긴다", async () => {
    const { client, rpc } = fakeAdmin({}, async () => true);
    const attempts = [{ generationId: "gen-1", model: "m", usage: { prompt_tokens: 1, completion_tokens: 2, cost: 0.001 } }];
    const artifact = { title: "t", body: "b", model: "m", prompt_version: "draft-v1" };
    await supabaseExecutionStore(client).completeInternalStep("s1", "fn-1", { to: [] }, attempts, artifact, "draft_ready");
    expect(rpc).toHaveBeenCalledWith("complete_internal_step", {
      p_step: "s1",
      p_owner: "fn-1",
      p_receipt: { to: [] },
      p_attempts: attempts,
      p_artifact: artifact,
      p_outcome: "draft_ready",
    });
  });
});
