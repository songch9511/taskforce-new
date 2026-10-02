import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { SourceFailureCode } from "@/lib/api/contract";
import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";
import { connectedAt, loadIdentity } from "@/lib/connectors/store";
import type { ExtractInput } from "@/lib/pipeline/extract";
import type { UserIdentity } from "@/lib/pipeline/identity";

import { failureSummary, processSource, PROCESSING_FAILED_MESSAGE, recordSourceFailed, RETRY_MAX_ATTEMPTS } from "./process";
import { RETRY_WINDOW_MS } from "./retry-window";

// 추출이 실패했거나(모델 시간 초과 · 출력 한도 등) 처리 도중 함수가 끊겨 "처리 중"에 멈춘 글 원문을 다시 처리한다
// (/api/cron/retry-sources). 그대로 두면 그 원문의 약속이 조용히 빠진다: 다른 곳에서 다시 처리하지 않고, Slack은 대기 메시지 본문도 비운다.
// 할 일 DB 항목(kind task)은 task_source_states가 멈춘 처리를 따로 다시 한다.
// 앞선 시도가 이미 반영한 후보는 processSource가 빼고 병합한다 (근거가 두 번 붙지 않게).
// 들어온 지 RETRY_WINDOW_MS가 지난 뒤에도 처리 중 · 대기에 멈춘 원문(동의하지 않은 사용자의 것, 후보 밖이었던 것, 창이 닫히기 전 마지막
// 시도에서 함수가 끊긴 것)은 다시 처리하지 않고 실패로 닫는다: 그대로 두면 영영 "처리 중"이다 (한 번에 EXPIRE_BATCH건까지).
// 다시 해 볼 만한 실패로 남았는데 다음 시도 전에 창이 지난 원문도 더 다시 하지 않는 실패로 닫는다 (까닭 코드 · 문구는 그대로).

/** 처리 중 · 대기에 이만큼 멈춰 있으면 함수가 끊긴 것으로 본다 (원문을 처리하는 함수의 실행 한도 300초보다 넉넉히) */
export const STALE_PROCESSING_MS = 15 * 60_000;
/** 들어온 지 이만큼 안의 원문만 다시 처리한다 (retry-window.ts) */
export { RETRY_WINDOW_MS };
/** 창을 지난 원문을 한 번의 cron 실행에서 닫는 최대 건수, 목록(멈춘 원문 · 다시 해 볼 실패 · 기록 전 실패)마다 (오래된 것부터, 남은 것은 다음 cron이 이어서 한다) */
export const EXPIRE_BATCH = 100;
/** 닫기에 쓰는 시간 한도: DB가 느려도 닫기가 창 안 원문의 다시 처리 시간을 먹지 않게 (닫기는 다음 cron이 이어서 해도 된다) */
export const EXPIRE_TIME_BUDGET_MS = 20_000;
/** 실패한 뒤 다음 시도까지 기다리는 시간 (첫 실패 뒤 · 두 번째 실패 뒤): 공급자 장애가 잠깐 이어질 때 시도를 한꺼번에 다 쓰지 않게 */
export const RETRY_DELAYS_MS = [30 * 60_000, 3 * 3_600_000];

export type RetryCandidate = {
  id: string;
  user_id: string;
  connection_id: string | null;
  /** 연결로 가져온 원문이면 서비스의 id (직접 넣은 원문은 null. 연결을 끊어 connection_id가 비어도 남는다) */
  external_id: string | null;
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

/**
 * 창을 지나 멈춘 원문 · 창을 지난 다시 해 볼 만한 실패를 닫는 데 필요한 것만 (글은 읽지 않는다). kind는 글 종류가 아니어도 받아 task를 다시 걸러낸다.
 * processing_error는 시도 기록이 생기기 전의 실패가 동의 철회인지 가르는 데만, processed_at은 닫는 실패가 아직 보이던 것인지 가르는 데만 쓴다.
 */
export type ExpiredCandidate = Pick<RetryCandidate, "id" | "user_id" | "processing_status" | "processing_summary" | "processing_error" | "created_at"> & {
  kind: string;
  processed_at: string | null;
};

/** retry: 이번 시도 번호로 다시 처리한다. give_up: 멈춘 채 시도를 다 써서 실패로 닫는다 */
export type RetryPlan = { kind: "retry"; attempt: number } | { kind: "give_up"; attempt: number };

const numberOr = (value: unknown, fallback: number) => (typeof value === "number" && Number.isFinite(value) ? value : fallback);

/** 지금까지 시도한 횟수 (기록이 없으면 대기는 0, 처리 중은 1) */
const attemptOf = (row: Pick<RetryCandidate, "processing_status" | "processing_summary">) =>
  numberOr(row.processing_summary?.attempt, row.processing_status === "pending" ? 0 : 1);

/** 실패한 원문을 다시 해 볼 만한가. 시도 기록이 생기기 전에 실패한 원문은 오류 문구로 가른다 (동의 철회는 다시 하지 않는다) */
const failureRetryable = (row: Pick<RetryCandidate, "processing_summary" | "processing_error">) =>
  typeof row.processing_summary?.retryable === "boolean" ? row.processing_summary.retryable : row.processing_error !== CONSENT_WITHDRAWN_MESSAGE;

/** 이 원문을 지금 어떻게 할지 (아직 기다리거나 대상이 아니면 null) */
export function retryPlan(row: RetryCandidate, now: Date): RetryPlan | null {
  const summary = row.processing_summary ?? {};
  const attempt = attemptOf(row);
  // 기록된 시각이 없으면 들어온 시각으로 본다
  const elapsed = (at: unknown) => now.getTime() - new Date(typeof at === "string" ? at : row.created_at).getTime();
  if (row.processing_status === "failed") {
    if (!failureRetryable(row) || attempt >= RETRY_MAX_ATTEMPTS) return null;
    const delay = RETRY_DELAYS_MS[Math.min(attempt, RETRY_DELAYS_MS.length) - 1];
    return elapsed(summary.failed_at) >= delay ? { kind: "retry", attempt: attempt + 1 } : null;
  }
  if (row.processing_status === "processing" || row.processing_status === "pending") {
    if (elapsed(summary.started_at) < STALE_PROCESSING_MS) return null;
    return attempt >= RETRY_MAX_ATTEMPTS ? { kind: "give_up", attempt } : { kind: "retry", attempt: attempt + 1 };
  }
  return null;
}

/**
 * 다시 처리하지 않고 실패로 닫을 원문인가: 들어온 지 RETRY_WINDOW_MS가 지났고 처리 중 · 대기에 STALE_PROCESSING_MS 넘게 멈춘 글 원문,
 * 또는 들어온 지 RETRY_WINDOW_MS가 지난 다시 해 볼 만한 실패(다음 시도 전에 창이 지남).
 * 닫을 때 기록할 시도 번호를 돌려준다 (아니면 null). 처리 창 안의 원문 · 아직 돌고 있을 수 있는 원문 · 할 일 DB 항목 · 이미 닫힌 실패는 건드리지 않는다.
 */
export function expiredAttempt(row: ExpiredCandidate, now: Date): number | null {
  if (row.kind === "task") return null;
  const age = (at: string) => now.getTime() - new Date(at).getTime();
  // 창 안(candidates의 created_at >= 창 시작)이면 다시 처리 대상이다
  if (age(row.created_at) <= RETRY_WINDOW_MS) return null;
  if (row.processing_status === "failed") return failureRetryable(row) ? attemptOf(row) : null;
  if (row.processing_status !== "processing" && row.processing_status !== "pending") return null;
  // 기록된 시각이 없으면 들어온 시각으로 본다 (retryPlan과 같다)
  const startedAt = row.processing_summary?.started_at;
  if (age(typeof startedAt === "string" ? startedAt : row.created_at) < STALE_PROCESSING_MS) return null;
  return attemptOf(row);
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
  /**
   * createdBefore 전에 들어와 startedBefore 전부터 처리 중 · 대기에 멈춘 글 원문, 그 뒤에 createdBefore 전에 들어온 다시 해 볼 만한 실패.
   * 목록마다 들어온 순서로 limit건까지 (실패가 많아도 멈춘 원문 닫기가 밀리지 않게 멈춘 원문을 앞에 둔다)
   */
  expired: (range: { createdBefore: Date; startedBefore: Date; limit: number }) => Promise<ExpiredCandidate[]>;
  /** 창을 지나 멈춘 원문 · 창을 지난 다시 해 볼 만한 실패를 더 다시 하지 않는 실패로 닫는다 (읽은 뒤 바뀌지 않았을 때만). 닫았으면 true */
  expire: (row: ExpiredCandidate, attempt: number) => Promise<boolean>;
  /** 처리 도중 Slack 연결을 끊었으면 이번 처리가 쓴 글자도 지운다 (D3) */
  repurge: (row: RetryCandidate) => Promise<void>;
  clock?: () => number;
};

export type RetryResult = { due: number; retried: number; failed: number; gaveUp: number; expired: number; skippedForTime: number };

/**
 * 다시 처리할 원문을 오래된 순서로 하나씩 처리한다. 한 건의 처리 시간 예산(itemBudgetMs)이 한도(deadline) 안에 들 때만 새로 시작하고,
 * 남은 것은 다음 cron이 이어서 한다. 한 건이 실패해도 다음 원문을 처리한다. 도중에 동의를 철회한 사용자의 남은 원문은 멈춘다.
 * 그 전에 창(RETRY_WINDOW_MS)을 지나서도 처리 중 · 대기에 멈춘 원문을 오래된 것부터 EXPIRE_BATCH건까지 실패로 닫는다 (동의와 상관없이).
 * 다시 해 볼 실패로 남은 채 창이 지난 원문도 그 뒤에 목록마다 EXPIRE_BATCH건까지 닫는다.
 */
export async function retryStalledSources(deps: RetryDeps, options: { now: Date; deadline: number; itemBudgetMs: number }): Promise<RetryResult> {
  const clock = deps.clock ?? Date.now;
  const windowStart = new Date(options.now.getTime() - RETRY_WINDOW_MS);
  const plans = (await deps.candidates(windowStart)).flatMap((row) => {
    const plan = retryPlan(row, options.now);
    return plan ? [{ row, plan }] : [];
  });
  const result: RetryResult = { due: 0, retried: 0, failed: 0, gaveUp: 0, expired: 0, skippedForTime: 0 };

  for (const { row, plan } of plans) {
    if (plan.kind !== "give_up") continue;
    await deps.giveUp(row, plan.attempt).then(
      (closed) => closed && result.gaveUp++,
      (error) => console.error(`멈춘 원문 닫기 실패 (${row.id}):`, error instanceof Error ? error.message : error),
    );
  }

  // 닫기는 살리는 일이 아니라 정리라서, 찾기가 실패해도 다시 처리는 막지 않는다
  try {
    const expired = await deps.expired({
      createdBefore: windowStart,
      startedBefore: new Date(options.now.getTime() - STALE_PROCESSING_MS),
      limit: EXPIRE_BATCH,
    });
    const expireUntil = clock() + EXPIRE_TIME_BUDGET_MS;
    for (const row of expired) {
      if (clock() > expireUntil) break;
      const attempt = expiredAttempt(row, options.now);
      if (attempt === null) continue;
      await deps.expire(row, attempt).then(
        (closed) => closed && result.expired++,
        (error) => console.error(`창을 지난 원문 닫기 실패 (${row.id}):`, error instanceof Error ? error.message : error),
      );
    }
  } catch (error) {
    console.error("창을 지난 원문 찾기 실패:", error instanceof Error ? error.message : error);
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
async function updateIfUnchanged(
  admin: SupabaseClient,
  row: Pick<RetryCandidate, "id" | "user_id" | "processing_status" | "processing_summary">,
  values: Record<string, unknown>,
  options: { stillRetryable?: boolean } = {},
): Promise<boolean> {
  let query = admin
    .from("sources")
    .update(values)
    .eq("id", row.id)
    .eq("user_id", row.user_id)
    .eq("processing_status", row.processing_status);
  // 기록에 retryable이 없던 실패는 retryable · closed를 더한 뒤에도 포함 검사(@>)가 맞는다: 아직 다시 해 볼 실패일 때만 바꿔
  // 겹친 두 실행이 둘 다 닫았다고 보지 않게 한다
  if (options.stillRetryable) query = query.or("processing_summary->>retryable.is.null,processing_summary->>retryable.eq.true");
  const { data } = await (row.processing_summary === null ? query.is("processing_summary", null) : query.contains("processing_summary", row.processing_summary))
    .select("id")
    .throwOnError();
  return (data ?? []).length > 0;
}

/**
 * 실패로 닫고 다시 하지 않는다. code는 까닭 코드: 마지막 시도에서 멈춘 원문(함수가 끊긴 까닭을 모른다)은 internal, 창을 지난 원문은 expired.
 * extra는 처리 기록에 남기는 닫은 까닭. 닫았으면 지표 이벤트 source_failed를 남긴다 (다른 실행이 먼저 바꿨으면 남기지 않는다).
 */
async function closeFailed(
  admin: SupabaseClient,
  row: Pick<RetryCandidate, "id" | "user_id" | "processing_status" | "processing_summary">,
  attempt: number,
  code: SourceFailureCode,
  extra: Record<string, unknown> = {},
) {
  const closed = await updateIfUnchanged(admin, row, {
    processing_status: "failed",
    processed_at: new Date().toISOString(),
    processing_error: PROCESSING_FAILED_MESSAGE,
    processing_error_code: code,
    processing_summary: { ...failureSummary(null, attempt), retryable: false, ...extra },
  });
  if (closed) await recordSourceFailed(admin, { id: row.id, userId: row.user_id });
  return closed;
}

/**
 * 다음 시도 전에 창이 지난 다시 해 볼 만한 실패를 더 다시 하지 않는 실패로 닫는다. 실패 시각 · 문구 · 까닭 코드는 그대로 두고
 * 처리 기록에 retryable false와 닫은 까닭만 더한다 (실패 시각이 그대로라 GET /api/v1/now에서는 그 시각부터 하루 뒤 빠진다).
 * 닫았으면 source_failed를 남긴다. 다른 실행이 먼저 바꿨거나, 실패한 지 RETRY_WINDOW_MS가 지난 실패(이미 /now에 보이지 않던 것,
 * 이 기능 전의 옛 실패 포함)면 남기지 않는다: 배포 뒤 첫 실행이 옛 실패를 한꺼번에 닫아도 지표가 튀지 않게.
 */
async function closeAgedOutFailure(admin: SupabaseClient, row: ExpiredCandidate) {
  const closed = await updateIfUnchanged(
    admin,
    row,
    { processing_summary: { ...row.processing_summary, retryable: false, closed: "expired" } },
    { stillRetryable: true },
  );
  const visible = row.processed_at !== null && Date.now() - Date.parse(row.processed_at) <= RETRY_WINDOW_MS;
  if (closed && visible) await recordSourceFailed(admin, { id: row.id, userId: row.user_id });
  return closed;
}

/** service role로 읽고 처리한다. 후보는 RETRY_WINDOW_MS 안에 들어온 것을 오래된 순서로 limit건 (나중 원문이 앞 원문의 약속을 바꾼다) */
export function retryDeps(admin: SupabaseClient, limit = 50): RetryDeps {
  const connectedAts = new Map<string, Promise<Date | null>>();
  // 연결(다시 연결) 전 시각의 원문은 확인 요청 알림을 보내지 않는다: 동기화가 한꺼번에 가져온 옛 원문이
  // 다시 처리되며 알림을 몰아 보내지 않게 (Gmail 동기화와 같은 기준, lib/connectors/gmail/run.ts)
  const notifies = async (row: RetryCandidate) => {
    if (!row.connection_id) return true;
    const key = row.connection_id;
    if (!connectedAts.has(key)) connectedAts.set(key, connectedAt(admin, { id: key, userId: row.user_id }));
    const since = await connectedAts.get(key);
    return !since || new Date(row.occurred_at) >= since;
  };
  return {
    candidates: async (since) => {
      const { data } = await admin
        .from("sources")
        .select(
          "id, user_id, connection_id, external_id, kind, raw_text, occurred_at, participants, written_by_me, processing_status, processing_summary, processing_error, created_at",
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
      const notify = await notifies(row);
      const { ok } = await processSource(admin, { id: row.id, userId: row.user_id, attempt, retry: true, notify }, {
        text: row.raw_text,
        kind: row.kind,
        occurredAt: new Date(row.occurred_at),
        identity,
        participants: row.participants ?? undefined,
        writtenByMe: row.written_by_me,
        fromConnector: row.external_id !== null,
      });
      return ok;
    },
    giveUp: (row, attempt) => closeFailed(admin, row, attempt, "internal"),
    // 글은 읽지 않는다 (닫는 데 필요 없다). 글이 지워진 원문도 닫는다: 그대로 두면 처리 중 · 다시 해 볼 실패로 남는다
    expired: async ({ createdBefore, startedBefore, limit }) => {
      const columns = "id, user_id, kind, processing_status, processing_summary, processing_error, processed_at, created_at";
      const { data: stalled } = await admin
        .from("sources")
        .select(columns)
        .in("processing_status", ["pending", "processing"])
        .neq("kind", "task")
        .lt("created_at", createdBefore.toISOString())
        .or(`processing_summary->>started_at.is.null,processing_summary->>started_at.lt.${startedBefore.toISOString()}`)
        .order("created_at", { ascending: true })
        .limit(limit)
        .throwOnError();
      // 다시 해 볼 만한 실패로 남았는데 창이 지난 것: retryable true
      const { data: retryable } = await admin
        .from("sources")
        .select(columns)
        .eq("processing_status", "failed")
        .neq("kind", "task")
        .lt("created_at", createdBefore.toISOString())
        .eq("processing_summary->>retryable", "true")
        .order("created_at", { ascending: true })
        .limit(limit)
        .throwOnError();
      // 시도 기록이 생기기 전의 실패 중 동의 철회가 아닌 것 (retryPlan과 같은 기준). 동의 철회는 조회에서 빼서 자리를 차지하지 않게 한다
      const { data: legacy } = await admin
        .from("sources")
        .select(columns)
        .eq("processing_status", "failed")
        .neq("kind", "task")
        .lt("created_at", createdBefore.toISOString())
        .is("processing_summary->>retryable", null)
        .neq("processing_error", CONSENT_WITHDRAWN_MESSAGE)
        .order("created_at", { ascending: true })
        .limit(limit)
        .throwOnError();
      return [...(stalled ?? []), ...(retryable ?? []), ...(legacy ?? [])] as ExpiredCandidate[];
    },
    expire: (row, attempt) =>
      row.processing_status === "failed" ? closeAgedOutFailure(admin, row) : closeFailed(admin, row, attempt, "expired", { closed: "expired" }),
    repurge: async (row) => {
      await admin.rpc("slack_repurge_if_disconnected", { p_user_id: row.user_id, p_source_id: row.id }).throwOnError();
    },
  };
}
