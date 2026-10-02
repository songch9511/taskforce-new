import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { loadClaims, loadStoredRow } from "@/lib/actions/db-store";

import type { ReceiptStore, ReceiptWriteResult } from "./receipt";

// receipt 쓰기(receipt.ts)의 운영 DB 연산: service role로 읽고 user_id로 좁힌다. 쓰기는 DB 함수 write_execution_receipt 하나다.

type StepRow = { run_id: string; user_id: string; kind: string; state: string };

export function supabaseReceiptStore(admin: SupabaseClient): ReceiptStore {
  return {
    async receiptTarget(stepId) {
      const { data: step } = await admin.from("execution_steps").select("run_id, user_id, kind, state").eq("id", stepId).maybeSingle<StepRow>().throwOnError();
      if (!step || step.kind !== "draft" || step.state !== "called") return null;
      const [{ data: run }, { data: artifact }] = await Promise.all([
        admin.from("execution_runs").select("action_id").eq("id", step.run_id).eq("user_id", step.user_id).maybeSingle<{ action_id: string }>().throwOnError(),
        admin
          .from("execution_artifacts")
          .select("id, title, created_at")
          .eq("step_id", stepId)
          .eq("user_id", step.user_id)
          .maybeSingle<{ id: string; title: string; created_at: string }>()
          .throwOnError(),
      ]);
      if (!run || !artifact) return null;
      return {
        stepId,
        runId: step.run_id,
        userId: step.user_id,
        actionId: run.action_id,
        artifact: { id: artifact.id, title: artifact.title, createdAt: new Date(artifact.created_at) },
      };
    },
    async loadAction(userId, actionId) {
      // 버전은 행에서 읽고 쓰기는 그 버전으로 CAS하므로, Claim을 함께 읽어도 그 사이 바뀐 것은 conflict로 다시 읽는다
      const [row, claims] = await Promise.all([loadStoredRow(admin, userId, actionId), loadClaims(admin, userId, actionId)]);
      if (!row) return null;
      return { version: row.version, title: row.title, confirmReasons: row.confirm_reasons, claims };
    },
    async writeReceipt(stepId, expectedVersion, receipt) {
      const { data } = await admin.rpc("write_execution_receipt", { p_step: stepId, p_expected_version: expectedVersion, p_receipt: receipt }).throwOnError();
      return data as ReceiptWriteResult;
    },
    async missingReceipts(limit) {
      const { data } = await admin.rpc("missing_execution_receipts", { p_limit: limit }).throwOnError();
      return ((data ?? []) as { step_id: string }[]).map((row) => row.step_id);
    },
  };
}
