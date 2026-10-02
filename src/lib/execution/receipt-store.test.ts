import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { supabaseReceiptStore } from "./receipt-store";

vi.mock("server-only", () => ({}));

// 운영 store가 부르는 표 · RPC 이름과 인자. SQL 자체(write_execution_receipt · missing_execution_receipts)는 tests/db/execution-receipts.test.ts

type Row = Record<string, unknown>;

/** 표마다 한 행을 돌려주는 가짜 service role 클라이언트. 걸러 쓴 조건(eq)과 RPC 호출을 기록한다 */
function fakeAdmin(tables: Record<string, Row | null>, rpcData: Record<string, unknown> = {}) {
  const filters: [string, string, unknown][] = [];
  const rpc = vi.fn((name: string) => ({ throwOnError: async () => ({ data: rpcData[name] ?? null }) }));
  const admin = {
    from: (table: string) => {
      const q = {
        select: () => q,
        eq: (column: string, value: unknown) => {
          filters.push([table, column, value]);
          return q;
        },
        maybeSingle: () => q,
        returns: () => q,
        throwOnError: async () => ({ data: table === "claims" ? [] : (tables[table] ?? null) }),
      };
      return q;
    },
    rpc,
  } as unknown as SupabaseClient;
  return { admin, filters, rpc };
}

const STEP = { run_id: "run-1", user_id: "user-1", kind: "draft", state: "called" };
const ARTIFACT = { id: "artifact-1", title: "제안서 초안", created_at: "2026-10-02T05:00:00.123456+00:00" };

describe("supabaseReceiptStore", () => {
  it("receiptTarget: 끝낸 초안 단계와 그 run의 Action · 산출물 (같은 사용자로 좁혀 읽는다)", async () => {
    const { admin, filters } = fakeAdmin({ execution_steps: STEP, execution_runs: { action_id: "action-1" }, execution_artifacts: ARTIFACT });
    expect(await supabaseReceiptStore(admin).receiptTarget("step-1")).toEqual({
      stepId: "step-1",
      runId: "run-1",
      userId: "user-1",
      actionId: "action-1",
      artifact: { id: "artifact-1", title: "제안서 초안", createdAt: new Date(ARTIFACT.created_at) },
    });
    expect(filters).toEqual(
      expect.arrayContaining([
        ["execution_steps", "id", "step-1"],
        ["execution_runs", "user_id", "user-1"],
        ["execution_artifacts", "step_id", "step-1"],
        ["execution_artifacts", "user_id", "user-1"],
      ]),
    );
  });

  it.each([
    ["없는 단계", { execution_steps: null }],
    ["계획 단계", { execution_steps: { ...STEP, kind: "plan" } }],
    ["끝내지 않은 초안 단계", { execution_steps: { ...STEP, state: "calling" } }],
    ["산출물 없음", { execution_steps: STEP, execution_runs: { action_id: "action-1" }, execution_artifacts: null }],
  ])("receiptTarget: %s면 null", async (_name, tables) => {
    expect(await supabaseReceiptStore(fakeAdmin(tables).admin).receiptTarget("step-1")).toBeNull();
  });

  it("loadAction: 행의 버전 · 제목 · 확인 이유와 Claim", async () => {
    const { admin } = fakeAdmin({ actions: { title: "제안서 보내기", confirm_reasons: ["담당 확인"], needs_confirmation: true, version: 4, status: "open", started_at: null } });
    expect(await supabaseReceiptStore(admin).loadAction("user-1", "action-1")).toEqual({ version: 4, title: "제안서 보내기", confirmReasons: ["담당 확인"], claims: [] });
    expect(await supabaseReceiptStore(fakeAdmin({ actions: null }).admin).loadAction("user-1", "action-1")).toBeNull();
  });

  it("writeReceipt · missingReceipts: DB 함수 하나씩 (인자 그대로)", async () => {
    const { admin, rpc } = fakeAdmin({}, { write_execution_receipt: "exists", missing_execution_receipts: [{ step_id: "a" }, { step_id: "b" }] });
    const store = supabaseReceiptStore(admin);
    const receipt = {
      source: { title: "제안서 초안", raw_text: "초안 저장: 제안서 초안", external_url: "taskforce://artifacts/artifact-1" },
      claim: { id: "claim-1", quote: "초안 저장: 제안서 초안", speaker_role: "me" as const, certainty: "firm" as const, directness: "first_hand" as const, audience: "private" as const },
    };
    expect(await store.writeReceipt("step-1", 4, receipt)).toBe("exists");
    expect(rpc).toHaveBeenCalledWith("write_execution_receipt", { p_step: "step-1", p_expected_version: 4, p_receipt: receipt });
    expect(await store.missingReceipts(20)).toEqual(["a", "b"]);
    expect(rpc).toHaveBeenCalledWith("missing_execution_receipts", { p_limit: 20 });
  });
});
