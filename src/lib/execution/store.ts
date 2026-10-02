import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { CreditsResponse, RunSummary } from "@/lib/api/contract";
import { hasConsentFor } from "@/lib/consent/store";
import { loadIdentity } from "@/lib/connectors/store";

import type { ExecutionContextInput } from "./context";
import { withDeadlockRetry } from "./deadlock";
import { materialFromRows, type ActionRow, type ConnectionRow, type EvidenceRow, type SourceRow } from "./material";
import { supabaseReceiptStore } from "./receipt-store";
import { OPEN_RUN_STATES, RunActionNotFoundError, type ExecutionStore, type StepRow } from "./types";

// 실행기의 DB 쪽 (service role). 판단(스위치 · 허용 목록 · 크레딧 · CAS)은 SQL 함수에만 있고(20261021000000 · 20261022000000), 여기는 RPC와 읽기뿐이다.
// 모든 RPC는 교착(40P01)이면 다시 부른다(deadlock.ts): stop · begin_call · complete_internal_step · 예약 해제가 같은 run · 계정을 잠근다.
// 읽기는 user_id · run_id로 좁힌다. 사용자 글(요청 · 원문 · 초안)은 로그에 남기지 않는다.

/** 근거가 많은 Action도 읽는 양이 커지지 않게 최근 근거만 (context.ts가 원문 6개 · 발췌 길이로 다시 줄인다) */
const EVIDENCE_LIMIT = 40;

const RUN_SUMMARY_COLUMNS = "id, action_id, goal, state, hold_reason, outcome, budget_credits, created_at";

export function supabaseExecutionStore(admin: SupabaseClient): ExecutionStore {
  const rpc = <T>(fn: string, args: Record<string, unknown>) =>
    withDeadlockRetry(async () => (await admin.rpc(fn, args).throwOnError()).data as T);

  return {
    // receipt 쓰기 (receipt-store.ts): 끝낸 초안 단계 · 산출물 읽기와 write_execution_receipt · missing_execution_receipts
    ...supabaseReceiptStore(admin),

    async loadRun(runId) {
      const { data } = await admin.from("execution_runs").select("id, user_id, action_id, state, request").eq("id", runId).maybeSingle().throwOnError();
      return data;
    },

    async nextOpenStep(runId) {
      const { data } = await admin
        .from("execution_steps")
        .select("id, run_id, seq, kind, state, version")
        .eq("run_id", runId)
        .not("state", "in", "(called,skipped)")
        .order("seq")
        .limit(1)
        .maybeSingle()
        .throwOnError();
      return data as StepRow | null;
    },

    async hasStepAfter(runId, seq) {
      const { count } = await admin.from("execution_steps").select("id", { count: "exact", head: true }).eq("run_id", runId).gt("seq", seq).throwOnError();
      return (count ?? 0) > 0;
    },

    async draftHistory(runId, beforeSeq) {
      const { data: steps } = await admin
        .from("execution_steps")
        .select("id, state, args")
        .eq("run_id", runId)
        .eq("kind", "draft")
        .in("state", ["called", "failed"])
        .lt("seq", beforeSeq)
        .order("seq")
        .throwOnError();
      const rows = (steps ?? []) as { id: string; state: "called" | "failed"; args: Record<string, unknown> | null }[];
      if (rows.length === 0) return [];
      const { data: artifacts } = await admin
        .from("execution_artifacts")
        .select("step_id, title")
        .in("step_id", rows.map((s) => s.id))
        .throwOnError();
      const titles = new Map(((artifacts ?? []) as { step_id: string; title: string }[]).map((a) => [a.step_id, a.title]));
      return rows.map((s) => ({ state: s.state, brief: typeof s.args?.brief === "string" ? s.args.brief : null, title: titles.get(s.id) ?? null }));
    },

    async loadMaterial(userId, actionId): Promise<ExecutionContextInput | null> {
      const { data: action } = await admin
        .from("actions")
        .select("title, status, owner, due_date, counterpart")
        .eq("id", actionId)
        .eq("user_id", userId)
        .maybeSingle()
        .throwOnError();
      if (!action) return null;
      // 실행 receipt(role executed)는 원문 근거가 아니라 읽지 않는다: 초안마다 늘어 최근 40개 자리를 원문 근거에서 빼앗지 않게 (context.ts도 다시 뺀다)
      const { data: evidence } = await admin
        .from("evidence")
        .select("source_id, quote")
        .eq("action_id", actionId)
        .eq("user_id", userId)
        .neq("role", "executed")
        .order("created_at", { ascending: false })
        .limit(EVIDENCE_LIMIT)
        .throwOnError();
      const evidenceRows = (evidence ?? []) as EvidenceRow[];
      const sourceIds = [...new Set(evidenceRows.map((e) => e.source_id))];
      const { data: sources } = sourceIds.length
        ? await admin
            .from("sources")
            .select("id, kind, title, raw_text, raw_text_purged_at, raw_text_purge_reason, occurred_at, participants, external_url, external_id, connection_id")
            .in("id", sourceIds)
            .eq("user_id", userId)
            .throwOnError()
        : { data: [] };
      const sourceRows = (sources ?? []) as SourceRow[];
      // 원문의 서비스는 연결 행에서 읽는다 (sources에는 provider가 없다). 찾지 못한 연결의 원문은 material.ts가 뺀다
      const connectionIds = [...new Set(sourceRows.map((s) => s.connection_id).filter((id): id is string => Boolean(id)))];
      const { data: connections } = connectionIds.length
        ? await admin.from("connections").select("id, provider").in("id", connectionIds).eq("user_id", userId).throwOnError()
        : { data: [] };
      return materialFromRows({
        action: action as ActionRow,
        evidence: evidenceRows,
        sources: sourceRows,
        connections: (connections ?? []) as ConnectionRow[],
      });
    },

    async holdsLease(stepId, owner) {
      const { data } = await admin.from("execution_steps").select("state, lease_owner").eq("id", stepId).maybeSingle().throwOnError();
      const row = data as { state: string; lease_owner: string | null } | null;
      return row?.state === "calling" && row.lease_owner === owner;
    },

    hasConsent: (userId) => hasConsentFor(admin, userId),
    userName: async (userId) => (await loadIdentity(admin, userId)).name,

    prepareStep: (stepId, version) => rpc<boolean>("prepare_step", { p_step: stepId, p_version: version }),
    beginCall: (stepId, owner, version) => rpc("begin_call", { p_step: stepId, p_owner: owner, p_version: version }),
    appendStep: (runId, seq, step) => rpc<string | null>("append_step", { p_run_id: runId, p_seq: seq, p_step: step }),
    completeInternalStep: (stepId, owner, receipt, attempts, artifact, outcome) =>
      rpc<boolean>("complete_internal_step", {
        p_step: stepId,
        p_owner: owner,
        p_receipt: receipt,
        p_attempts: attempts,
        p_artifact: artifact,
        p_outcome: outcome,
      }),
    recordUsage: (stepId, attempts) => rpc<number>("record_usage", { p_step: stepId, p_attempts: attempts }),
    settleFailed: (stepId, owner, receipt) => rpc<boolean>("settle_step", { p_step: stepId, p_owner: owner, p_state: "failed", p_receipt: receipt }),
    markUnknown: (stepId, owner) => rpc<boolean>("mark_unknown", { p_step: stepId, p_owner: owner }),
    finishRun: (runId) => rpc<boolean>("finish_run", { p_run_id: runId }),

    globallyBlocked: () => executionGloballyBlocked(admin),
    sweepExpire: () => rpc<number>("sweep_expire", {}),

    async unconfirmedUsage(limit, since) {
      const { data } = await admin
        .from("execution_usage")
        .select("id, generation_id")
        .eq("cost_status", "unconfirmed")
        .not("generation_id", "is", null)
        .gte("created_at", since.toISOString())
        // 청구 대상(초안) 먼저: 확정돼야 정산 · 해제되는 행이 플랫폼 원가 행 뒤에 밀리지 않게
        .order("billable", { ascending: false })
        .order("created_at")
        .limit(limit)
        .throwOnError();
      return (data ?? []) as { id: number; generation_id: string }[];
    },

    reconcileUsage: (usageId, costUsd) => rpc<boolean>("reconcile_usage", { p_usage_id: usageId, p_cost_usd: costUsd }),

    async openEndedCreditRuns(limit) {
      const rows = await rpc<{ run_id: string }[] | null>("credit_open_ended_runs", { p_limit: limit });
      return (rows ?? []).map((r) => r.run_id);
    },

    releaseRunCredits: (runId) => rpc<number>("release_run_credits", { p_run_id: runId }),

    async wakeableRuns(limit) {
      // 막히지 않은 run 먼저(오래된 순), 막힌 run(hold_reason)은 뒤에 새것부터: 운영자만 풀 수 있는 오래된 hold(actor · blocked)가 쌓여도
      // 지급으로 풀린 새 run(credit)이 그 뒤에 굶지 않게
      const open = () => admin.from("execution_runs").select("id, hold_reason").in("state", [...OPEN_RUN_STATES]);
      const [{ data: free }, { data: held }] = await Promise.all([
        open().is("hold_reason", null).order("created_at").limit(limit * 2).throwOnError(),
        open().not("hold_reason", "is", null).order("created_at", { ascending: false }).limit(limit * 2).throwOnError(),
      ]);
      const rows = [...(free ?? []), ...(held ?? [])] as { id: string; hold_reason: string | null }[];
      if (rows.length === 0) return [];
      // lease를 가진 함수가 부르는 중인 run은 깨우지 않는다 (깨워도 아무것도 하지 않는다)
      const { data: calling } = await admin
        .from("execution_steps")
        .select("run_id")
        .eq("state", "calling")
        .in("run_id", rows.map((r) => r.id))
        .throwOnError();
      const busy = new Set(((calling ?? []) as { run_id: string }[]).map((s) => s.run_id));
      return rows
        .filter((r) => !busy.has(r.id))
        .slice(0, limit)
        .map((r) => ({ id: r.id, held: r.hold_reason !== null }));
    },
  };
}

// ─── route (POST /runs · stop · GET /credits) ───

export async function isExecutionActor(admin: SupabaseClient, userId: string): Promise<boolean> {
  const { data } = await admin.from("execution_actors").select("user_id").eq("user_id", userId).maybeSingle().throwOnError();
  return Boolean(data);
}

/** 차단 스위치의 전체 행이 막혔거나 없다 (행이 없으면 막힌 것으로 본다, EXECUTION 6장). begin_call이 정하고, route는 새 run을 받지 않는 데만 쓴다 */
export async function executionGloballyBlocked(admin: SupabaseClient): Promise<boolean> {
  const { data } = await admin.from("execution_controls").select("blocked").eq("scope", "global").eq("key", "*").maybeSingle().throwOnError();
  return !data || (data as { blocked: boolean }).blocked;
}

/** 사용자 권한(RLS) 클라이언트로 읽는다: 남의 Action은 보이지 않는다. create_run이 같은 확인을 한 번 더 한다 */
export async function actionIsOpen(supabase: SupabaseClient, actionId: string): Promise<boolean> {
  const { data } = await supabase.from("actions").select("status").eq("id", actionId).maybeSingle().throwOnError();
  return (data as { status: string } | null)?.status === "open";
}

export async function createRun(
  admin: SupabaseClient,
  userId: string,
  run: { actionId: string; goal: "draft"; request: string; budgetCredits: number | null },
): Promise<string> {
  try {
    return await withDeadlockRetry(
      async () =>
        (
          await admin
            .rpc("create_run", { p_user_id: userId, p_action_id: run.actionId, p_goal: run.goal, p_request: run.request, p_budget_credits: run.budgetCredits })
            .throwOnError()
        ).data as string,
    );
  } catch (error) {
    if ((error as { code?: unknown }).code === "P0002") throw new RunActionNotFoundError();
    throw error;
  }
}

export async function loadRunSummary(admin: SupabaseClient, userId: string, runId: string): Promise<RunSummary | null> {
  const { data } = await admin.from("execution_runs").select(RUN_SUMMARY_COLUMNS).eq("id", runId).eq("user_id", userId).maybeSingle().throwOnError();
  return data as RunSummary | null;
}

/** 멈춘 뒤의 run 상태. 그 사용자의 run이 없으면 null (stop_run) */
export const stopRun = (admin: SupabaseClient, userId: string, runId: string) =>
  withDeadlockRetry(async () => (await admin.rpc("stop_run", { p_user_id: userId, p_run_id: runId }).throwOnError()).data as string | null);

/** 크레딧 합계: 계정 행(원장 합계를 든 잠금 행)과 지금 요율. 지급 기록이 없으면 0 */
export async function loadCredits(admin: SupabaseClient, userId: string): Promise<CreditsResponse> {
  const [{ data: account }, { data: rate }] = await Promise.all([
    admin.from("credit_accounts").select("granted, reserved, settled").eq("user_id", userId).maybeSingle().throwOnError(),
    admin.from("credit_rates").select("version").eq("active", true).maybeSingle().throwOnError(),
  ]);
  const a = (account ?? { granted: 0, reserved: 0, settled: 0 }) as { granted: number; reserved: number; settled: number };
  return {
    available: Math.max(0, a.granted - a.reserved - a.settled),
    reserved: a.reserved,
    rate_version: (rate as { version: string } | null)?.version ?? null,
  };
}
