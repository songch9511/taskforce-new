import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { SupabaseActionStore, SupabaseTaskLinks } from "@/lib/actions/db-store";
import { SUMMARY_COLUMNS } from "@/lib/actions/service";
import { DeadlineExceededError } from "@/lib/ai/deadline";
import { embed, embedConfigFromEnv, EmbedError } from "@/lib/ai/embed";
import { decide, jevConfigFromEnv, JevError } from "@/lib/ai/jev";
import { completeJson, llmConfigFromEnv, LlmError } from "@/lib/ai/llm";
import type { ActionSummary, MissingReportResponse, SourceFailureCode } from "@/lib/api/contract";
import { MISSING_REPORT_LIMIT, RateLimitedError } from "@/lib/api/rate-limit";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { assertConsent, CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError, withConsentGate } from "@/lib/consent/gate";
import { consentCheck } from "@/lib/consent/store";
import { backfillEmbeddings } from "@/lib/pipeline/backfill-embeddings";
import type { ExtractInput } from "@/lib/pipeline/extract";
import type { UserIdentity } from "@/lib/pipeline/identity";
import type { JudgeResult } from "@/lib/pipeline/judge";
import { mergeJudged, type MergeDeps } from "@/lib/pipeline/merge";
import { mergeTask, type TaskInput } from "@/lib/pipeline/merge-task";
import {
  classifyMiss,
  extractMissing,
  QUOTED_HISTORY_DROP,
  responseMissStage,
  reportMatchDecide,
  reportStore,
  trackedByEvidence,
  unappliedCandidates,
  type MissingInput,
  type MissLog,
  type SourceEvidence,
} from "@/lib/pipeline/missing";
import { runPipeline, type PipelineDeps } from "@/lib/pipeline/run";
import { notifyConfirmations } from "@/lib/notify/service";

// 저장된 원문 하나를 끝까지 처리한다 (POST /api/v1/sources · 연동 동기화 · 재처리 cron이 부른다):
// 추출 → 검증 → Jev 판정(judge_logs) → 기존 Action과 매칭 · 병합(actions · claims · evidence · action_events).
// Action 쓰기는 서버만 할 수 있으므로 service role 클라이언트로 부르고, 모든 쓰기에 user_id를 넣는다.
// 빠진 할 일 신고(reportMissing, POST /api/v1/sources/:id/missing)도 같은 병합 · 사용자 잠금을 쓴다. 사용자가 기다리므로 마감 안에서만 한다.
// 세 함수 모두 모델 호출(LLM · Jev · 임베딩) 직전마다 외부 AI 처리 동의를 다시 확인한다 (withConsentGate).
// 원문 처리의 매칭 전에는 임베딩이 없는 열린 Action(직접 추가할 때 못 만든 것)을 몇 개씩 채운다 (backfillEmbeddings, 실패해도 처리는 계속).
// 사용자가 기다리는 빠진 할 일 신고는 채우지 않는다 (시간이 빠듯하고, 배경 처리가 채운다).
// 도중에 철회하면 ConsentRequiredError를 던진다: 원문은 failed로 남기고, 부르는 쪽(동기화 · 스크립트 · 재처리 cron)은 남은 항목을 멈춘다.

export type ProcessDeps = PipelineDeps & Pick<MergeDeps, "embed">;

/**
 * 사용자가 기다리는 처리(빠진 할 일 신고)에서 추출(LLM) 뒤 판정 · 병합에 남기는 시간: Jev 2번(판정 · 매칭) · 후보 임베딩 · DB 읽기 · 쓰기 · 잠금 대기.
 * 보통 합쳐 몇 초다. 그 호출들은 마감(deadline)까지 쓸 수 있어, 멈춰도 실행 한도 안에 오류로 끝난다.
 */
export const AFTER_EXTRACT_MS = 15_000;

/** 빠진 할 일 신고가 사용자 잠금을 얻은 뒤 병합(후보 임베딩 · Jev 매칭 · 쓰기)에 필요한 최소 시간. 마감까지 이만큼 남지 않으면 병합을 시작하지 않는다 */
export const MERGE_MIN_MS = 5_000;

/**
 * deadline(epoch ms, lib/ai/deadline.ts interactiveDeadline)을 주면 사용자가 기다리는 처리(빠진 할 일 신고)다: 모델 호출을 모두 그 시각 안에 끝내고,
 * 추출(LLM)은 첫 호출부터 추론량을 제한하며 뒤의 판정 · 병합에 AFTER_EXTRACT_MS를 남긴다.
 * 없으면 배경 처리(원문 처리 · 동기화 · 재처리 cron): 호출마다 제 시간 한도(LLM 90초 · Jev · 임베딩 30초)만 쓴다.
 */
export function processDepsFromEnv(deadline?: number): ProcessDeps {
  const llm = llmConfigFromEnv();
  const jev = jevConfigFromEnv();
  const embedding = embedConfigFromEnv();
  if (deadline !== undefined) {
    llm.deadline = deadline - AFTER_EXTRACT_MS;
    jev.deadline = deadline;
    embedding.deadline = deadline;
  }
  return {
    complete: (request) => completeJson(llm, request),
    decide: (request) => decide(jev, request),
    embed: async (texts) => (await embed(embedding, texts)).vectors,
  };
}

// 같은 사용자의 병합은 한 번에 하나씩: 동시에 비슷한 후보 둘이 모두 "새 Action"이 되는 중복을 막는다.
// (한 서버 인스턴스 안에서만 보장된다. 인스턴스 사이의 드문 경합은 write_action의 버전 확인이 값 손실을 막는다.)
const mergeQueues = new Map<string, Promise<unknown>>();

export const USER_LOCK_TIMEOUT_MESSAGE = "병합 대기 시간 초과 (같은 사용자의 다른 처리가 끝나지 않음)";
/** 기다리지 않았는데(앞선 병합 없음) 마감까지 MERGE_MIN_MS가 남지 않았을 때: 앞 단계(추출 · 판정)가 시간을 다 썼다 */
export const MERGE_NO_TIME_MESSAGE = "병합할 시간 없음 (앞 단계가 마감 전 시간을 다 씀)";

/**
 * deadline(epoch ms)을 주면(사용자가 기다리는 누락 신고) 앞선 병합을 마감 전 MERGE_MIN_MS까지만 기다린다.
 * 넘기면 task를 부르지 않고 DeadlineExceededError를 낸다: 차례가 나중에 와도 병합하지 않는다. 대기열 순서는 그대로다.
 * 차례가 와도 마감까지 MERGE_MIN_MS가 남지 않았으면 병합을 시작하지 않는다. 시작한 병합은 끊지 않는다 (그 안의 모델 호출이 마감을 넘지 않는다).
 * 오류 단계(deadline_exceeded 기록)는 앞선 병합을 기다렸으면 lock, 기다리지 않았으면 merge다 (앞 단계가 느렸다).
 */
export function withUserLock<T>(userId: string, task: () => Promise<T>, deadline?: number): Promise<T> {
  const contended = mergeQueues.has(userId);
  const previous = mergeQueues.get(userId) ?? Promise.resolve();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let expired = false;
  const run = previous
    .catch(() => undefined)
    .then(() => {
      clearTimeout(timer);
      if (expired) throw new DeadlineExceededError("lock", USER_LOCK_TIMEOUT_MESSAGE);
      if (deadline !== undefined && deadline - Date.now() < MERGE_MIN_MS) {
        throw contended ? new DeadlineExceededError("lock", USER_LOCK_TIMEOUT_MESSAGE) : new DeadlineExceededError("merge", MERGE_NO_TIME_MESSAGE);
      }
      return task();
    });
  mergeQueues.set(userId, run);
  // 실패해도 대기열을 비운다. finally가 아니라 then(성공, 실패)이어야 거절이 처리되지 않은 채 남지 않는다.
  const release = () => {
    if (mergeQueues.get(userId) === run) mergeQueues.delete(userId);
  };
  run.then(release, release);
  if (deadline === undefined) return run;
  // 차례가 오면(task를 시작하면) 타이머를 지우므로, 이 약속은 기다리는 동안 마감 전 MERGE_MIN_MS를 넘겼을 때만 끝난다.
  const waited = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => {
        expired = true;
        reject(new DeadlineExceededError("lock", USER_LOCK_TIMEOUT_MESSAGE));
      },
      Math.max(0, deadline - MERGE_MIN_MS - Date.now()),
    );
  });
  return Promise.race([run, waited]);
}

/** 사용자에게 보여도 되는 오류만 그대로 두고, DB 오류 등은 일반 문구로 바꾼다 (자세한 내용은 서버 로그). */
function userFacingError(error: unknown): string {
  if (error instanceof ConsentRequiredError) return CONSENT_WITHDRAWN_MESSAGE;
  if (error instanceof LlmError || error instanceof JevError || error instanceof EmbedError) return error.message.slice(0, 300);
  return PROCESSING_FAILED_MESSAGE;
}

/** 원인을 사용자에게 보일 수 없는 처리 실패 문구 (처리 중에 멈춘 채 다시 처리할 횟수를 다 쓴 원문에도 쓴다, retry.ts) */
export const PROCESSING_FAILED_MESSAGE = "처리 중 오류가 발생했습니다.";

/** AI 공급자(OpenRouter)가 한도 · 잔액으로 거절한 응답 코드. 402 잔액 부족, 403 키 사용 한도 (2026-09-30 한도 도달 때 모든 호출이 403, 런북 I9) */
const AI_QUOTA_STATUSES = new Set([402, 403]);

/** AI 설정 오류(키 · 모델 환경변수가 없음, LLM_OVERRUN_REASONING_EFFORT 값이 틀림)의 문구에는 환경변수 이름이 들어 있다 */
const AI_CONFIG_ERROR = /[A-Z0-9]+_[A-Z0-9_]+/;

/**
 * 처리 실패의 까닭 코드 (sources.processing_error_code, 앱 · 지표가 본다). AI 호출 오류는 응답 코드 · 시간 초과 · 응답 형식으로 가른다.
 * 오류 문구는 lib/ai의 llm.ts · jev.ts · embed.ts가 만든 것이다: "… 요청 실패 (상태 코드)" · "… 시간 초과 …" (process.test.ts가 실제 함수의 오류로 고정한다).
 */
export function sourceFailureCode(error: unknown): SourceFailureCode {
  if (error instanceof ConsentRequiredError) return "consent";
  if (error instanceof DeadlineExceededError) return error.stage === "lock" || error.stage === "merge" ? "internal" : "ai_timeout";
  // 배경 처리의 임베딩은 시간 초과를 그대로 던진다 (embed.ts)
  if (error instanceof DOMException && error.name === "TimeoutError") return "ai_timeout";
  if (!(error instanceof LlmError || error instanceof JevError || error instanceof EmbedError)) return "internal";
  // 운영 설정 문제지 AI 응답 문제가 아니다
  if (AI_CONFIG_ERROR.test(error.message)) return "internal";
  const status = /요청 실패 \((\d{3})\)/.exec(error.message)?.[1];
  if (status) return AI_QUOTA_STATUSES.has(Number(status)) ? "ai_quota" : "internal";
  if ((error instanceof LlmError && error.kind === "timeout") || /시간 초과/.test(error.message)) return "ai_timeout";
  return "ai_output";
}

/**
 * 원문을 더 다시 처리하지 않기로 실패로 닫았을 때(시도를 다 씀 · 창이 지남 · 동의 철회) 지표 이벤트 source_failed를 한 줄 남긴다.
 * provider는 그 원문을 가져온 연결의 서비스 (직접 넣은 원문 · 연결을 끊은 원문은 null). 원문 · 까닭 글은 남기지 않는다.
 * 기록이 실패해도 처리 결과에는 영향이 없다 (로그에는 원문 id와 오류만).
 */
export async function recordSourceFailed(admin: SupabaseClient, source: { id: string; userId: string }): Promise<void> {
  try {
    const { data: row } = await admin.from("sources").select("connection_id").eq("id", source.id).eq("user_id", source.userId).maybeSingle().throwOnError();
    const connectionId = (row as { connection_id?: string | null } | null)?.connection_id ?? null;
    let provider: string | null = null;
    if (connectionId) {
      const { data: connection } = await admin
        .from("connections")
        .select("provider")
        .eq("id", connectionId)
        .eq("user_id", source.userId)
        .maybeSingle()
        .throwOnError();
      provider = (connection as { provider?: string } | null)?.provider ?? null;
    }
    await admin.from("metric_events").insert({ user_id: source.userId, type: "source_failed", provider }).throwOnError();
  } catch (error) {
    console.error(`원문 실패 지표 기록 실패 (${source.id}):`, error instanceof Error ? error.message : error);
  }
}

/** 한 원문을 처리해 보는 최대 횟수 (첫 처리 포함). 넘으면 cron이 더 다시 처리하지 않는다 (retry.ts) */
export const RETRY_MAX_ATTEMPTS = 3;

/** 실패 기록 (processing_summary): 몇 번째 시도였고 다시 해 볼 만한지. 동의 철회 · 마지막 시도는 다시 하지 않는다 */
export function failureSummary(error: unknown, attempt: number, now = new Date()): { attempt: number; retryable: boolean; failed_at: string } {
  return { attempt, retryable: !(error instanceof ConsentRequiredError) && attempt < RETRY_MAX_ATTEMPTS, failed_at: now.toISOString() };
}

export type ProcessResult = {
  /** 끝까지 처리했는가 (아니면 원문은 failed로 남는다) */
  ok: boolean;
  /** 이번 처리로 확인 요청이 새로 생긴 Action (알림용) */
  needsConfirmation: string[];
};

/** judge_logs 한 행 (후보 하나의 판정) */
export type JudgeLogRow = {
  user_id: string;
  source_id: string;
  candidate: unknown;
  jev_answers: Record<string, unknown>;
  decision: JudgeResult["decision"];
  model_version: string;
};

/**
 * 이 원문의 판정 기록을 이번 처리 결과로 바꾼다. 다시 처리해도(scripts/reprocess-sources.ts) 쌓이지 않아,
 * 누락 신고의 놓친 단계 분류(classifyMiss)와 /lab이 마지막 처리만 본다.
 */
export async function replaceJudgeLogs(admin: SupabaseClient, source: { id: string; userId: string }, rows: JudgeLogRow[]): Promise<void> {
  await admin.from("judge_logs").delete().eq("user_id", source.userId).eq("source_id", source.id).throwOnError();
  if (rows.length > 0) await admin.from("judge_logs").insert(rows).throwOnError();
}

/**
 * 원문 하나를 처리한다. source.notify가 false면 확인 요청 알림을 보내지 않는다 (확인 요청 자체는 만든다):
 * 연결 전 시각의 원문을 한꺼번에 가져올 때(Gmail 첫 14일 · 다시 연결 뒤 이어 가져오기) 원문마다 알림이 가지 않게 (원칙 3).
 */
export async function processSource(
  admin: SupabaseClient,
  /**
   * attempt: 몇 번째 처리인가 (처음 1, cron이 다시 처리하면 2 · 3).
   * retry: 재처리 cron이 다시 처리한다 (대기에 멈춘 원문은 attempt 1이어도 다시 처리다, lib/sources/retry.ts)
   */
  source: { id: string; userId: string; attempt?: number; retry?: boolean; notify?: boolean },
  input: ExtractInput,
  deps: ProcessDeps = processDepsFromEnv(),
): Promise<ProcessResult> {
  const sourceId = source.id;
  const scoped = <T extends { eq: (column: string, value: string) => T }>(query: T) => query.eq("id", sourceId).eq("user_id", source.userId);
  const check = consentCheck(admin, source.userId);
  const ai = withConsentGate(deps, check);
  const attempt = source.attempt ?? 1;
  // 시작 시각을 남겨, 처리 도중 함수가 끊겨 멈춘 원문을 cron이 알아보고 다시 처리한다 (retry.ts)
  await scoped(
    admin.from("sources").update({ processing_status: "processing", processing_summary: { attempt, started_at: new Date().toISOString() } }),
  ).throwOnError();

  try {
    await assertConsent(check);
    const result = await runPipeline(input, ai);

    const judgedRows: JudgeLogRow[] = result.judged.map(({ candidate, judge }) => ({
      user_id: source.userId,
      source_id: sourceId,
      candidate,
      jev_answers: {
        signals: judge.signals,
        reasons: judge.reasons,
        ...(judge.rule ? { rule: judge.rule } : {}),
        ...(judge.speaker ? { quote_speaker: judge.speaker } : {}),
      },
      decision: judge.decision,
      model_version: `${judge.model}@${judge.promptVersion}`,
    }));
    // 연결 메일의 인용된 옛 메일에만 있어 기계 검증이 버린 후보: 판정 전에 버렸으니 답 대신 이유만 남긴다 (누락 신고가 이 단계를 알아본다, classifyMiss)
    const droppedRows: JudgeLogRow[] = result.droppedQuotedHistory.map((candidate) => ({
      user_id: source.userId,
      source_id: sourceId,
      candidate,
      jev_answers: { dropped: QUOTED_HISTORY_DROP },
      decision: "reject",
      model_version: `verify@${result.summary.promptVersions.extract}`,
    }));
    await replaceJudgeLogs(admin, source, [...judgedRows, ...droppedRows]);
    if (result.droppedQuotedHistory.length > 0) console.log(`인용된 옛 메일 속 후보 ${result.droppedQuotedHistory.length}건 버림 (${sourceId})`);

    // 기존 Action과 맞춰 보고 반영한다.
    const store = new SupabaseActionStore(admin, source.userId);
    let alreadyApplied = 0;
    const outcomes = await withUserLock(source.userId, async () => {
      await backfillEmbeddings(store, ai.embed);
      // 다시 처리할 때는 이 원문에서 이미 근거로 쓰인 구절과 겹치는 후보를 빼고 병합한다: 앞선 시도가 병합 도중에 실패 · 중단됐거나
      // 그 사이 누락 신고 · 직접 추가로 붙은 구절에 근거 · Claim이 두 번 붙지 않게.
      const judged = source.retry ? unappliedCandidates(result.judged, await sourceEvidenceQuotes(admin, source)) : result.judged;
      alreadyApplied = result.judged.length - judged.length;
      return mergeJudged(
        store,
        judged,
        { id: sourceId, text: input.text, kind: input.kind, occurredAt: input.occurredAt },
        input.identity,
        { embed: ai.embed, decide: ai.decide, newId: () => crypto.randomUUID() },
      );
    });
    const count = (relation: string) => outcomes.filter((o) => o.relation === relation).length;

    await scoped(
      admin.from("sources").update({
        processing_status: "done",
        processed_at: new Date().toISOString(),
        processing_error: null,
        processing_error_code: null,
        processing_summary: {
          ...result.summary,
          attempt,
          merge: {
            new: count("new"),
            updated: count("update"),
            duplicate: count("duplicate"),
            completed: count("complete"),
            cancelled: count("cancel"),
            // 다시 처리할 때 이미 반영된 것으로 보고 병합 전에 뺀 후보
            ...(source.retry ? { already_applied: alreadyApplied } : {}),
          },
        },
      }),
    ).throwOnError();
    const needsConfirmation = [...store.needsConfirmation];
    // 알림 실패는 처리 결과에 영향을 주지 않는다.
    if (source.notify !== false) {
      await notifyConfirmations(admin, source.userId, needsConfirmation).catch((error) =>
        console.error("확인 요청 알림 실패:", error instanceof Error ? error.message : error),
      );
    }
    return { ok: true, needsConfirmation };
  } catch (error) {
    // 서버 로그에는 원인을, 사용자에게는 원문 · 내부 정보가 없는 문구만 남긴다.
    console.error(`원문 처리 실패 (${sourceId}):`, error instanceof Error ? error.message : error);
    const summary = failureSummary(error, attempt);
    const { error: recordError } = await scoped(
      admin.from("sources").update({
        processing_status: "failed",
        processed_at: new Date().toISOString(),
        processing_error: userFacingError(error),
        processing_error_code: sourceFailureCode(error),
        processing_summary: summary,
      }),
    );
    if (recordError) console.error(`원문 실패 기록 실패 (${sourceId}):`, recordError.message);
    // 더 다시 하지 않는 실패(동의 철회 · 마지막 시도)는 닫힌 실패로 센다. 실패로 기록하지 못했으면 닫히지 않은 것이라 세지 않는다
    else if (!summary.retryable) await recordSourceFailed(admin, source);
    if (error instanceof ConsentRequiredError) throw error;
    return { ok: false, needsConfirmation: [] };
  }
}

/** 이 원문에서 Action의 근거로 쓰인 구절 전부 (담당 · 상태와 상관없이) */
async function sourceEvidenceQuotes(admin: SupabaseClient, source: { id: string; userId: string }): Promise<string[]> {
  const { data } = await admin.from("evidence").select("quote").eq("user_id", source.userId).eq("source_id", source.id).throwOnError();
  return ((data ?? []) as { quote: string | null }[]).flatMap((e) => (e.quote ? [e.quote] : []));
}

/**
 * 구조화된 할 일(Notion 할 일 DB 등) 원문 하나를 처리한다. LLM 추출 · Jev 판정 없이 속성 스냅샷을 Claim으로 옮긴다.
 * 처음 보는 할 일만 기존 Action과 매칭(임베딩 + Jev)하고, 이후 버전은 action_links로 바로 붙인다.
 */
export async function processTaskSource(
  admin: SupabaseClient,
  source: { id: string; userId: string; connectionId: string },
  task: TaskInput & { identity: UserIdentity },
  deps: Pick<ProcessDeps, "embed" | "decide"> = processDepsFromEnv(),
): Promise<ProcessResult> {
  const scoped = <T extends { eq: (column: string, value: string) => T }>(query: T) => query.eq("id", source.id).eq("user_id", source.userId);
  const check = consentCheck(admin, source.userId);
  const ai = withConsentGate(deps, check);
  // 시작 시각을 남긴다: 중간에 멈춘 처리를 가려 다시 처리한다 (connectors/tasks-ingest.ts).
  await scoped(
    admin.from("sources").update({ processing_status: "processing", processing_summary: { started_at: new Date().toISOString() } }),
  ).throwOnError();

  try {
    await assertConsent(check);
    const store = new SupabaseActionStore(admin, source.userId);
    const links = new SupabaseTaskLinks(admin, source.userId, source.connectionId);
    const outcome = await withUserLock(source.userId, async () => {
      await backfillEmbeddings(store, ai.embed);
      return mergeTask(store, links, task, { id: source.id, occurredAt: task.edit.occurredAt }, task.identity, {
        embed: ai.embed,
        decide: ai.decide,
        newId: () => crypto.randomUUID(),
      });
    });

    await scoped(
      admin.from("sources").update({
        processing_status: "done",
        processed_at: new Date().toISOString(),
        processing_error: null,
        processing_error_code: null,
        processing_summary: {
          structured: true,
          relation: outcome.relation,
          changes: outcome.changes,
          edited_by_user: task.edit.editedByUser,
        },
      }),
    ).throwOnError();
    const needsConfirmation = [...store.needsConfirmation];
    await notifyConfirmations(admin, source.userId, needsConfirmation).catch((error) =>
      console.error("확인 요청 알림 실패:", error instanceof Error ? error.message : error),
    );
    return { ok: true, needsConfirmation };
  } catch (error) {
    console.error(`할 일 처리 실패 (${source.id}):`, error instanceof Error ? error.message : error);
    await scoped(
      admin.from("sources").update({
        processing_status: "failed",
        processed_at: new Date().toISOString(),
        processing_error: userFacingError(error),
        processing_error_code: sourceFailureCode(error),
      }),
    );
    // 처리를 마치지 못한 할 일은 동의한 뒤 동기화가 다시 처리한다 (pendingTasks). 닫힌 실패가 아니라 source_failed는 남기지 않는다.
    if (error instanceof ConsentRequiredError) throw error;
    return { ok: false, needsConfirmation: [] };
  }
}

/**
 * 빠진 할 일 신고 (POST /api/v1/sources/:id/missing). 원문이 사용자의 것인지 · 구절이 원문에 있는지는 부르는 쪽이
 * 사용자 권한(RLS)으로 먼저 확인한다. 여기서는 service role로 쓰고 모든 쿼리를 user_id로 좁힌다.
 * 0. 이 원문에서 이미 Action의 근거로 쓰인 구절과 겹치면 그 Action(끝냈거나 지운 것도)을 already_tracked로 돌려준다.
 *    모델을 부르지 않고 신고로 세지 않는다 (trackedByEvidence)
 * 1. 사용자별 시도 횟수를 넘었으면 RateLimitedError (모델을 부르기 전에 시도를 남긴다. 세기와 남기기는 한 트랜잭션: take_rate_limit)
 * 2. 원래 처리의 판정 기록(judge_logs)으로 어느 단계가 놓쳤는지 가른다 (classifyMiss)
 * 3. 구절 하나를 후보로 만들고(extractMissing) 보통 원문과 같은 병합(mergeJudged)으로 반영한다.
 *    다른 사람 담당 Action과는 합치지 않고(reportStore), 확신이 낮은 병합은 새 일로 본다(reportMatchDecide)
 * 4. 새 Action이면 created와 같은 트랜잭션에 user_reported_missing(actor user, after { stage, source_id, reasoning_limited })을 남긴다.
 *    이미 있는 Action(확실한 반복 · 변경)이면 근거만 더하고 already_tracked — 신고로 세지 않는다.
 * 병합이 기존 Action의 완료 · 취소로 보는 경우는 reportMatchDecide가 같은 일의 반복으로 바꾼다 (신고로 할 일을 끝내지 않는다).
 * commitment 후보는 unmatched가 되지 않으므로, Action을 못 얻으면 오류로 본다.
 * 사용자가 기다리므로 마감을 반드시 받는다: deadline(epoch ms, lib/ai/deadline.ts interactiveDeadline)과 그 마감으로 만든
 * deps(processDepsFromEnv(deadline)). 모델 호출과 같은 사용자의 다른 병합 기다리기(withUserLock)가 마감을 넘지 않고,
 * 임베딩 채우기(backfillEmbeddings)는 하지 않는다 (그만큼 신고에 필요한 임베딩 · 매칭 시간을 쓰지 않게. 배경 처리가 채운다).
 * 시간이 모자라면 DeadlineExceededError.
 */
export async function reportMissing(
  admin: SupabaseClient,
  source: { id: string; userId: string; processingStatus: string },
  input: MissingInput,
  deadline: number,
  deps: ProcessDeps,
): Promise<MissingReportResponse> {
  const tracked = await trackedActionSummary(admin, source, input.quote);
  if (tracked) return { status: "already_tracked", action: tracked, stage: null };

  const retryAt = await takeRateLimit(admin, source.userId, "missing_report", MISSING_REPORT_LIMIT);
  if (retryAt) throw new RateLimitedError(retryAt);
  const ai = withConsentGate(deps, consentCheck(admin, source.userId));

  const { data: logs } = await admin
    .from("judge_logs")
    .select("candidate, decision, jev_answers")
    .eq("user_id", source.userId)
    .eq("source_id", source.id)
    .throwOnError();
  const stage = classifyMiss({
    processingStatus: source.processingStatus,
    logs: ((logs ?? []) as { candidate: { quote?: unknown } | null; decision: MissLog["decision"]; jev_answers: { dropped?: unknown } | null }[]).map((log) => ({
      quote: typeof log.candidate?.quote === "string" ? log.candidate.quote : "",
      decision: log.decision,
      ...(log.jev_answers?.dropped === QUOTED_HISTORY_DROP ? { dropped: QUOTED_HISTORY_DROP } : {}),
    })),
    quote: input.quote,
  });

  const { judged, summary } = await extractMissing(input, ai);
  const store = new SupabaseActionStore(admin, source.userId, {
    createEvents: [
      {
        type: "user_reported_missing",
        before: null,
        // reasoning_limited: 추론량을 제한해 뽑은 신고인가 (신고는 첫 호출부터 제한하므로 LLM_OVERRUN_REASONING_EFFORT=off가 아니면 true, 제품 원칙 6)
        after: { stage, source_id: source.id, reasoning_limited: summary.reasoningLimited },
        rule: null,
        actor: "user",
      },
    ],
  });
  const [outcome] = await withUserLock(
    source.userId,
    () =>
      mergeJudged(reportStore(store), [judged], { id: source.id, text: input.text, kind: input.kind, occurredAt: input.occurredAt }, input.identity, {
        embed: ai.embed,
        decide: reportMatchDecide(ai.decide),
        newId: () => crypto.randomUUID(),
      }),
    deadline,
  );
  if (!outcome?.actionId) throw new Error(`누락 신고를 반영하지 못했습니다 (${outcome?.relation ?? "결과 없음"})`);

  const action = await actionSummary(admin, source.userId, outcome.actionId);
  // 응답 계약에는 quoted_history가 없다(missStageSchema): 응답에서는 추출 안 됨으로 보이고, 이벤트(지표)에만 그대로 남는다
  return outcome.relation === "new" ? { status: "created", action, stage: responseMissStage(stage) } : { status: "already_tracked", action, stage: null };
}

async function actionSummary(admin: SupabaseClient, userId: string, actionId: string): Promise<ActionSummary> {
  const { data } = await admin.from("actions").select(SUMMARY_COLUMNS).eq("user_id", userId).eq("id", actionId).single().throwOnError();
  return data as ActionSummary;
}

/**
 * 이 원문에서 구절이 이미 근거인 Action의 요약 (없으면 null). 누락 신고와 직접 추가(POST /api/v1/actions)가 같이 쓴다.
 * 원문이 사용자의 것인지는 부르는 쪽이 사용자 권한(RLS)으로 먼저 확인한다. 모델을 부르지 않는다.
 */
export async function trackedActionSummary(admin: SupabaseClient, source: { id: string; userId: string }, quote: string): Promise<ActionSummary | null> {
  const tracked = await trackedAction(admin, source, quote);
  return tracked ? actionSummary(admin, source.userId, tracked) : null;
}

/** 이 원문의 근거 중 구절과 겹치는 것의 Action (상태와 상관없이, 다른 사람 담당은 빼고) */
async function trackedAction(admin: SupabaseClient, source: { id: string; userId: string }, quote: string): Promise<string | null> {
  const { data: evidence } = await admin
    .from("evidence")
    .select("action_id, quote")
    .eq("user_id", source.userId)
    .eq("source_id", source.id)
    .order("created_at")
    .throwOnError();
  const rows = (evidence ?? []) as { action_id: string; quote: string }[];
  if (rows.length === 0) return null;
  const ids = [...new Set(rows.map((e) => e.action_id))];

  const { data: actions } = await admin.from("actions").select("id, owner").eq("user_id", source.userId).in("id", ids).throwOnError();
  const owners = new Map(((actions ?? []) as { id: string; owner: SourceEvidence["owner"] }[]).map((a) => [a.id, a.owner]));
  return trackedByEvidence(
    rows.flatMap((e) => (owners.has(e.action_id) ? [{ actionId: e.action_id, quote: e.quote, owner: owners.get(e.action_id)! }] : [])),
    quote,
  );
}
