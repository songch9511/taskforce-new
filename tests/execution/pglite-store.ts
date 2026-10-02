import type { PGlite } from "@electric-sql/pglite";

import { materialFromRows, type ActionRow, type ConnectionRow, type EvidenceRow, type SourceRow } from "@/lib/execution/material";
import type { BeginCallResult, DraftHistoryRow, ExecutionStore, RunRow, StepRow } from "@/lib/execution/types";

// 실행기(src/lib/execution/executor.ts)를 PGlite에서 돌리는 store. 운영 store(store.ts, supabase-js)와 같은 SQL 함수를 부르고,
// 읽기만 같은 뜻의 SQL로 옮겼다. 자료는 운영과 같은 materialFromRows로 만든다 (DB 모양 그대로).

const OPEN_RUN_STATES = "('queued', 'running', 'waiting_approval')";

export function pgliteExecutionStore(db: PGlite, options: { userName?: string } = {}): ExecutionStore {
  const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
  const r = async <T>(sql: string, params: unknown[] = []) => (await one<{ r: T }>(sql, params)).r;
  const json = (value: unknown) => (value === null ? null : JSON.stringify(value));

  return {
    loadRun: async (runId) => (await one<RunRow>("select id, user_id, action_id, state, request from public.execution_runs where id = $1", [runId])) ?? null,
    nextOpenStep: async (runId) =>
      (await one<StepRow>(
        "select id, run_id, seq, kind, state, version from public.execution_steps where run_id = $1 and state not in ('called', 'skipped') order by seq limit 1",
        [runId],
      )) ?? null,
    hasStepAfter: (runId, seq) => r<boolean>("select exists (select 1 from public.execution_steps where run_id = $1 and seq > $2) as r", [runId, seq]),
    draftHistory: async (runId, beforeSeq) =>
      (
        await db.query<DraftHistoryRow>(
          `select s.state, s.args->>'brief' as brief, a.title from public.execution_steps s
           left join public.execution_artifacts a on a.step_id = s.id
           where s.run_id = $1 and s.kind = 'draft' and s.state in ('called', 'failed') and s.seq < $2 order by s.seq`,
          [runId, beforeSeq],
        )
      ).rows,
    async loadMaterial(userId, actionId) {
      const action = await one<ActionRow>("select title, status, owner, due_date::text, counterpart from public.actions where id = $1 and user_id = $2", [actionId, userId]);
      if (!action) return null;
      const evidence = (
        await db.query<EvidenceRow>("select source_id, quote from public.evidence where action_id = $1 and user_id = $2 order by created_at desc limit 40", [actionId, userId])
      ).rows;
      const sources = (
        await db.query<SourceRow>(
          `select id, kind, title, raw_text, raw_text_purged_at::text, raw_text_purge_reason, occurred_at::text, participants, external_url, external_id, connection_id
           from public.sources where id = any($1::uuid[]) and user_id = $2`,
          [[...new Set(evidence.map((e) => e.source_id))], userId],
        )
      ).rows;
      const connections = (
        await db.query<ConnectionRow>("select id, provider from public.connections where id = any($1::uuid[]) and user_id = $2", [
          sources.map((s) => s.connection_id).filter(Boolean),
          userId,
        ])
      ).rows;
      return materialFromRows({ action, evidence, sources, connections });
    },
    hasConsent: (userId) => r<boolean>("select exists (select 1 from public.profiles where user_id = $1 and ai_consent_at is not null) as r", [userId]),
    userName: async () => options.userName ?? "김도윤",

    prepareStep: (stepId, version) => r<boolean>("select public.prepare_step($1, $2) as r", [stepId, version]),
    beginCall: (stepId, owner, version) => r<BeginCallResult>("select public.begin_call($1, $2, $3) as r", [stepId, owner, version]),
    appendStep: (runId, seq, step) => r<string | null>("select public.append_step($1, $2, $3::jsonb) as r", [runId, seq, json(step)]),
    completeInternalStep: (stepId, owner, receipt, attempts, artifact, outcome) =>
      r<boolean>("select public.complete_internal_step($1, $2, $3::jsonb, $4::jsonb, $5::jsonb, $6) as r", [stepId, owner, json(receipt), json(attempts), json(artifact), outcome]),
    recordUsage: (stepId, attempts) => r<number>("select public.record_usage($1, $2::jsonb) as r", [stepId, json(attempts)]),
    settleFailed: (stepId, owner, receipt) => r<boolean>("select public.settle_step($1, $2, 'failed', $3::jsonb) as r", [stepId, owner, json(receipt)]),
    markUnknown: (stepId, owner) => r<boolean>("select public.mark_unknown($1, $2) as r", [stepId, owner]),
    finishRun: (runId) => r<boolean>("select public.finish_run($1) as r", [runId]),

    sweepExpire: () => r<number>("select public.sweep_expire() as r"),
    unconfirmedUsage: async (limit, since) =>
      (
        await db.query<{ id: number; generation_id: string }>(
          `select id::int, generation_id from public.execution_usage
           where cost_status = 'unconfirmed' and generation_id is not null and created_at >= $2 order by created_at limit $1`,
          [limit, since.toISOString()],
        )
      ).rows,
    reconcileUsage: (usageId, costUsd) => r<boolean>("select public.reconcile_usage($1, $2::numeric) as r", [usageId, costUsd]),
    openEndedCreditRuns: async (limit) => (await db.query<{ run_id: string }>("select run_id from public.credit_open_ended_runs($1)", [limit])).rows.map((x) => x.run_id),
    releaseRunCredits: (runId) => r<number>("select public.release_run_credits($1) as r", [runId]),
    wakeableRuns: async (limit) =>
      (
        await db.query<{ id: string }>(
          `select r.id from public.execution_runs r where r.state in ${OPEN_RUN_STATES}
             and not exists (select 1 from public.execution_steps s where s.run_id = r.id and s.state = 'calling')
           order by r.hold_reason nulls first, r.created_at limit $1`,
          [limit],
        )
      ).rows.map((x) => x.id),
  };
}
