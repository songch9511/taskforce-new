import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";
import { loadIdentity } from "@/lib/connectors/store";
import type { ExtractInput } from "@/lib/pipeline/extract";
import type { UserIdentity } from "@/lib/pipeline/identity";

import { failureSummary, processSource, PROCESSING_FAILED_MESSAGE, RETRY_MAX_ATTEMPTS } from "./process";

// 추출이 실패했거나(모델 시간 초과 · 출력 한도 등) 처리 도중 함수가 끊겨 "처리 중"에 멈춘 글 원문을 다시 처리한다
// (/api/cron/retry-sources). 그대로 두면 그 원문의 약속이 조용히 빠진다: 다른 곳에서 다시 처리하지 않고, Slack은 대기 메시지 본문도 비운다.
// 할 일 DB 항목(kind task)은 task_source_states가 멈춘 처리를 따로 다시 한다.
// 앞선 시도가 이미 반영한 후보는 processSource가 빼고 병합한다 (근거가 두 번 붙지 않게).

/** 처리 중 · 대기에 이만큼 멈춰 있으면 함수가 끊긴 것으로 본다 (원문을 처리하는 함수의 실행 한도 300초보다 넉넉히) */
export const STALE_PROCESSING_MS = 15 * 60_000;
/**
 * 들어온 지 이만큼 안의 원문만 다시 처리한다. 오래된 원문을 뒤늦게 반영하면 이미 지난 약속이 새 할 일로 뜨고,
 * 그 사이 처리된 뒷 원문(완료 · 취소)과 순서가 뒤집힌다. 이 기능 전에 실패한 오래된 원문은 scripts/reprocess-sources.ts로 따로 본다.
 */
export const RETRY_WINDOW_MS = 24 * 3_600_000;
/** 실패한 뒤 다음 시도까지 기다리는 시간 (첫 실패 뒤 · 두 번째 실패 뒤): 공급자 장애가 잠깐 이어질 때 시도를 한꺼번에 다 쓰지 않게 */
export const RETRY_DELAYS_MS = [30 * 60_000, 3 * 3_600_000];

export type RetryCandidate = {
  id: string;
  user_id: string;
  kind: ExtractInput["kind"];
  raw_text: string;
  occurred_at: string;
  participants: ExtractInput["participants"] | null;
  written_by_me: boolean | null;
  processing_status: "pending" | "processing" | "done" | "failed";
  processing_summary: Record<string, unknown> | null;
  processing_error: string | null;
  created_at: string;
};

/** retry: 이번 시도 번호로 다시 처리한다. give_up: 멈춘 채 시도를 다 써서 실패로 닫는다 */
export type RetryPlan = { kind: "retry"; attempt: number } | { kind: "give_up"; attempt: number };

const numberOr = (value: unknown, fallback: number) => (typeof value === "number" && Number.isFinite(value) ? value : fallback);

/** 이 원문을 지금 어떻게 할지 (아직 기다리거나 대상이 아니면 null) */
export function retryPlan(row: RetryCandidate, now: Date): RetryPlan | null {
  const summary = row.processing_summary ?? {};
  const attempt = numberOr(summary.attempt, row.processing_status === "pending" ? 0 : 1);
  // 기록된 시각이 없으면 들어온 시각으로 본다
  const elapsed = (at: unknown) => now.getTime() - new Date(typeof at === "string" ? at : row.created_at).getTime();
  if (row.processing_status === "failed") {
    // 시도 기록이 생기기 전에 실패한 원문은 오류 문구로 가른다 (동의 철회는 다시 하지 않는다)
    const retryable = typeof summary.retryable === "boolean" ? summary.retryable : row.processing_error !== CONSENT_WITHDRAWN_MESSAGE;
    if (!retryable || attempt >= RETRY_MAX_ATTEMPTS) return null;
    const delay = RETRY_DELAYS_MS[Math.min(attempt, RETRY_DELAYS_MS.length) - 1];
    return elapsed(summary.failed_at) >= delay ? { kind: "retry", attempt: attempt + 1 } : null;
  }
  if (row.processing_status === "processing" || row.processing_status === "pending") {
    if (elapsed(summary.started_at) < STALE_PROCESSING_MS) return null;
    return attempt >= RETRY_MAX_ATTEMPTS ? { kind: "give_up", attempt } : { kind: "retry", attempt: attempt + 1 };
  }
  return null;
}

export type RetryDeps = {
  /** since 뒤에 들어온, 끝나지 않은 글 원문 (들어온 순서로) */
  candidates: (since: Date) => Promise<RetryCandidate[]>;
  /** 이 중 외부 AI 처리에 동의한 사용자 */
  consentedUsers: (userIds: string[]) => Promise<Set<string>>;
  identity: (userId: string) => Promise<UserIdentity>;
  /** 읽은 뒤 다른 실행이 바꾸지 않았을 때만 이번 시도로 가져간다 (두 실행이 같은 원문을 함께 처리하지 않게). 가져갔으면 true */
  claim: (row: RetryCandidate, attempt: number) => Promise<boolean>;
  /** 끝까지 처리했으면 true. 동의를 철회했으면 ConsentRequiredError를 던진다 (원문은 failed로 남는다) */
  process: (row: RetryCandidate, identity: UserIdentity, attempt: number) => Promise<boolean>;
  /** 멈춘 채 시도를 다 쓴 원문을 실패로 닫는다 (읽은 뒤 바뀌지 않았을 때만). 닫았으면 true */
  giveUp: (row: RetryCandidate, attempt: number) => Promise<boolean>;
  /** 처리 도중 Slack 연결을 끊었으면 이번 처리가 쓴 글자도 지운다 (D3) */
  repurge: (row: RetryCandidate) => Promise<void>;
  clock?: () => number;
};

export type RetryResult = { due: number; retried: number; failed: number; gaveUp: number; skippedForTime: number };

/**
 * 다시 처리할 원문을 오래된 순서로 하나씩 처리한다. 한 건의 처리 시간 예산(itemBudgetMs)이 한도(deadline) 안에 들 때만 새로 시작하고,
 * 남은 것은 다음 cron이 이어서 한다. 한 건이 실패해도 다음 원문을 처리한다. 도중에 동의를 철회한 사용자의 남은 원문은 멈춘다.
 */
export async function retryStalledSources(deps: RetryDeps, options: { now: Date; deadline: number; itemBudgetMs: number }): Promise<RetryResult> {
  const clock = deps.clock ?? Date.now;
  const plans = (await deps.candidates(new Date(options.now.getTime() - RETRY_WINDOW_MS))).flatMap((row) => {
    const plan = retryPlan(row, options.now);
    return plan ? [{ row, plan }] : [];
  });
  const result: RetryResult = { due: 0, retried: 0, failed: 0, gaveUp: 0, skippedForTime: 0 };

  for (const { row, plan } of plans) {
    if (plan.kind !== "give_up") continue;
    await deps.giveUp(row, plan.attempt).then(
      (closed) => closed && result.gaveUp++,
      (error) => console.error(`멈춘 원문 닫기 실패 (${row.id}):`, error instanceof Error ? error.message : error),
    );
  }

  const due = plans.flatMap(({ row, plan }) => (plan.kind === "retry" ? [{ row, attempt: plan.attempt }] : []));
  const consented = await deps.consentedUsers([...new Set(due.map(({ row }) => row.user_id))]);
  const targets = due.filter(({ row }) => consented.has(row.user_id));
  result.due = targets.length;
  const identities = new Map<string, UserIdentity>();
  const withdrawn = new Set<string>();

  for (const [index, { row, attempt }] of targets.entries()) {
    if (withdrawn.has(row.user_id)) continue;
    if (clock() + options.itemBudgetMs > options.deadline) {
      result.skippedForTime = targets.slice(index).filter((t) => !withdrawn.has(t.row.user_id)).length;
      break;
    }
    let identity: UserIdentity;
    try {
      // 가져가기 전에 준비한다: 모델을 부르기도 전에 실패해 시도 하나를 쓰지 않게
      identity = identities.get(row.user_id) ?? (await deps.identity(row.user_id));
      identities.set(row.user_id, identity);
      if (!(await deps.claim(row, attempt))) continue;
    } catch (error) {
      result.failed++;
      console.error(`원문 다시 처리 준비 실패 (${row.id}):`, error instanceof Error ? error.message : error);
      continue;
    }
    result.retried++;
    try {
      if (!(await deps.process(row, identity, attempt))) result.failed++;
    } catch (error) {
      result.failed++;
      if (error instanceof ConsentRequiredError) withdrawn.add(row.user_id);
      console.error(`원문 다시 처리 실패 (${row.id}):`, error instanceof Error ? error.message : error);
    } finally {
      await deps.repurge(row).catch((error) => console.error(`Slack 글자 다시 지우기 실패 (${row.id}):`, error instanceof Error ? error.message : error));
    }
  }
  return result;
}

/** 읽은 뒤 상태와 처리 기록이 그대로일 때만 고친다 (시도마다 시작 · 실패 시각이 새로 찍혀 기록이 바뀐다). 고쳤으면 true */
async function updateIfUnchanged(admin: SupabaseClient, row: RetryCandidate, values: Record<string, unknown>): Promise<boolean> {
  const query = admin
    .from("sources")
    .update(values)
    .eq("id", row.id)
    .eq("user_id", row.user_id)
    .eq("processing_status", row.processing_status);
  const { data } = await (row.processing_summary === null ? query.is("processing_summary", null) : query.contains("processing_summary", row.processing_summary))
    .select("id")
    .throwOnError();
  return (data ?? []).length > 0;
}

/** service role로 읽고 처리한다. 후보는 RETRY_WINDOW_MS 안에 들어온 것을 오래된 순서로 limit건 (나중 원문이 앞 원문의 약속을 바꾼다) */
export function retryDeps(admin: SupabaseClient, limit = 50): RetryDeps {
  return {
    candidates: async (since) => {
      const { data } = await admin
        .from("sources")
        .select(
          "id, user_id, kind, raw_text, occurred_at, participants, written_by_me, processing_status, processing_summary, processing_error, created_at",
        )
        .in("processing_status", ["pending", "processing", "failed"])
        .neq("kind", "task")
        .is("raw_text_purged_at", null)
        .gte("created_at", since.toISOString())
        // 더 다시 하지 않기로 한 실패(동의 철회 · 마지막 시도)는 뺀다: 후보 자리를 차지하지 않게
        .or("processing_summary->>retryable.is.null,processing_summary->>retryable.eq.true")
        .order("created_at", { ascending: true })
        .limit(limit)
        .throwOnError();
      return (data ?? []) as RetryCandidate[];
    },
    consentedUsers: async (userIds) => {
      if (userIds.length === 0) return new Set();
      const { data } = await admin.from("profiles").select("user_id").in("user_id", userIds).not("ai_consent_at", "is", null).throwOnError();
      return new Set(((data ?? []) as { user_id: string }[]).map((row) => row.user_id));
    },
    identity: (userId) => loadIdentity(admin, userId),
    claim: (row, attempt) =>
      updateIfUnchanged(admin, row, { processing_status: "processing", processing_summary: { attempt, started_at: new Date().toISOString() } }),
    // 동의를 철회하면 원문은 failed로 남긴다. 동기화와 달리 지우지 않는다: 이때쯤이면 Slack 대기 메시지 본문은 비었고
    // Notion은 그 뒤에 고친 페이지만 다시 가져오므로, 지우면 원문을 다시 얻을 수 없다
    process: async (row, identity, attempt) => {
      const { ok } = await processSource(admin, { id: row.id, userId: row.user_id, attempt, retry: true }, {
        text: row.raw_text,
        kind: row.kind,
        occurredAt: new Date(row.occurred_at),
        identity,
        participants: row.participants ?? undefined,
        writtenByMe: row.written_by_me,
      });
      return ok;
    },
    giveUp: (row, attempt) =>
      updateIfUnchanged(admin, row, {
        processing_status: "failed",
        processed_at: new Date().toISOString(),
        processing_error: PROCESSING_FAILED_MESSAGE,
        processing_summary: { ...failureSummary(null, attempt), retryable: false },
      }),
    repurge: async (row) => {
      await admin.rpc("slack_repurge_if_disconnected", { p_user_id: row.user_id, p_source_id: row.id }).throwOnError();
    },
  };
}
