import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { SupabaseActionStore, SupabaseTaskLinks } from "@/lib/actions/db-store";
import { SUMMARY_COLUMNS } from "@/lib/actions/service";
import { embed, embedConfigFromEnv, EmbedError } from "@/lib/ai/embed";
import { decide, jevConfigFromEnv, JevError } from "@/lib/ai/jev";
import { completeJson, llmConfigFromEnv, LlmError } from "@/lib/ai/llm";
import type { ActionSummary, MissingReportResponse } from "@/lib/api/contract";
import { MISSING_REPORT_LIMIT, RateLimitedError } from "@/lib/api/rate-limit";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { assertConsent, CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError, withConsentGate } from "@/lib/consent/gate";
import { consentCheck } from "@/lib/consent/store";
import { backfillEmbeddings } from "@/lib/pipeline/backfill-embeddings";
import type { ExtractInput } from "@/lib/pipeline/extract";
import type { UserIdentity } from "@/lib/pipeline/identity";
import { mergeJudged, type MergeDeps } from "@/lib/pipeline/merge";
import { mergeTask, type TaskInput } from "@/lib/pipeline/merge-task";
import {
  classifyMiss,
  extractMissing,
  reportMatchDecide,
  reportStore,
  trackedByEvidence,
  type MissingInput,
  type MissLog,
  type SourceEvidence,
} from "@/lib/pipeline/missing";
import { runPipeline, type PipelineDeps } from "@/lib/pipeline/run";
import { notifyConfirmations } from "@/lib/notify/service";

// 저장된 원문 하나를 끝까지 처리한다 (POST /api/v1/sources · 연동 동기화가 부른다):
// 추출 → 검증 → Jev 판정(judge_logs) → 기존 Action과 매칭 · 병합(actions · claims · evidence · action_events).
// Action 쓰기는 서버만 할 수 있으므로 service role 클라이언트로 부르고, 모든 쓰기에 user_id를 넣는다.
// 빠진 할 일 신고(reportMissing, POST /api/v1/sources/:id/missing)도 같은 병합 · 사용자 잠금을 쓴다.
// 세 함수 모두 모델 호출(LLM · Jev · 임베딩) 직전마다 외부 AI 처리 동의를 다시 확인한다 (withConsentGate).
// 매칭 전에는 임베딩이 없는 열린 Action(직접 추가할 때 못 만든 것)을 몇 개씩 채운다 (backfillEmbeddings, 실패해도 처리는 계속).
// 도중에 철회하면 ConsentRequiredError를 던진다: 원문은 failed로 남기고, 부르는 쪽(동기화 · 스크립트)은 남은 항목을 멈춘다.

export type ProcessDeps = PipelineDeps & Pick<MergeDeps, "embed">;

export function processDepsFromEnv(): ProcessDeps {
  const llm = llmConfigFromEnv();
  const jev = jevConfigFromEnv();
  const embedding = embedConfigFromEnv();
  return {
    complete: (request) => completeJson(llm, request),
    decide: (request) => decide(jev, request),
    embed: async (texts) => (await embed(embedding, texts)).vectors,
  };
}

// 같은 사용자의 병합은 한 번에 하나씩: 동시에 비슷한 후보 둘이 모두 "새 Action"이 되는 중복을 막는다.
// (한 서버 인스턴스 안에서만 보장된다. 인스턴스 사이의 드문 경합은 write_action의 버전 확인이 값 손실을 막는다.)
const mergeQueues = new Map<string, Promise<unknown>>();
function withUserLock<T>(userId: string, task: () => Promise<T>): Promise<T> {
  const previous = mergeQueues.get(userId) ?? Promise.resolve();
  const run = previous.catch(() => undefined).then(task);
  mergeQueues.set(userId, run);
  // 실패해도 대기열을 비운다. finally가 아니라 then(성공, 실패)이어야 거절이 처리되지 않은 채 남지 않는다.
  const release = () => {
    if (mergeQueues.get(userId) === run) mergeQueues.delete(userId);
  };
  run.then(release, release);
  return run;
}

/** 사용자에게 보여도 되는 오류만 그대로 두고, DB 오류 등은 일반 문구로 바꾼다 (자세한 내용은 서버 로그). */
function userFacingError(error: unknown): string {
  if (error instanceof ConsentRequiredError) return CONSENT_WITHDRAWN_MESSAGE;
  if (error instanceof LlmError || error instanceof JevError || error instanceof EmbedError) return error.message.slice(0, 300);
  return "처리 중 오류가 발생했습니다.";
}

export type ProcessResult = {
  /** 이번 처리로 확인 요청이 새로 생긴 Action (알림용) */
  needsConfirmation: string[];
};

export async function processSource(
  admin: SupabaseClient,
  source: { id: string; userId: string },
  input: ExtractInput,
  deps: ProcessDeps = processDepsFromEnv(),
): Promise<ProcessResult> {
  const sourceId = source.id;
  const scoped = <T extends { eq: (column: string, value: string) => T }>(query: T) => query.eq("id", sourceId).eq("user_id", source.userId);
  const check = consentCheck(admin, source.userId);
  const ai = withConsentGate(deps, check);
  await scoped(admin.from("sources").update({ processing_status: "processing" })).throwOnError();

  try {
    await assertConsent(check);
    const result = await runPipeline(input, ai);

    if (result.judged.length > 0) {
      await admin
        .from("judge_logs")
        .insert(
          result.judged.map(({ candidate, judge }) => ({
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
          })),
        )
        .throwOnError();
    }

    // 기존 Action과 맞춰 보고 반영한다.
    const store = new SupabaseActionStore(admin, source.userId);
    const outcomes = await withUserLock(source.userId, async () => {
      await backfillEmbeddings(store, ai.embed);
      return mergeJudged(
        store,
        result.judged,
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
        processing_summary: {
          ...result.summary,
          merge: { new: count("new"), updated: count("update"), duplicate: count("duplicate"), completed: count("complete"), cancelled: count("cancel") },
        },
      }),
    ).throwOnError();
    const needsConfirmation = [...store.needsConfirmation];
    // 알림 실패는 처리 결과에 영향을 주지 않는다.
    await notifyConfirmations(admin, source.userId, needsConfirmation).catch((error) =>
      console.error("확인 요청 알림 실패:", error instanceof Error ? error.message : error),
    );
    return { needsConfirmation };
  } catch (error) {
    // 서버 로그에는 원인을, 사용자에게는 원문 · 내부 정보가 없는 문구만 남긴다.
    console.error(`원문 처리 실패 (${sourceId}):`, error instanceof Error ? error.message : error);
    await scoped(
      admin.from("sources").update({ processing_status: "failed", processed_at: new Date().toISOString(), processing_error: userFacingError(error) }),
    );
    if (error instanceof ConsentRequiredError) throw error;
    return { needsConfirmation: [] };
  }
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
    return { needsConfirmation };
  } catch (error) {
    console.error(`할 일 처리 실패 (${source.id}):`, error instanceof Error ? error.message : error);
    await scoped(
      admin.from("sources").update({ processing_status: "failed", processed_at: new Date().toISOString(), processing_error: userFacingError(error) }),
    );
    // 처리를 마치지 못한 할 일은 동의한 뒤 동기화가 다시 처리한다 (pendingTasks).
    if (error instanceof ConsentRequiredError) throw error;
    return { needsConfirmation: [] };
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
 * 4. 새 Action이면 created와 같은 트랜잭션에 user_reported_missing(actor user, after { stage, source_id })을 남긴다.
 *    이미 있는 Action(확실한 반복 · 변경)이면 근거만 더하고 already_tracked — 신고로 세지 않는다.
 * 병합이 기존 Action의 완료 · 취소로 보는 경우는 reportMatchDecide가 같은 일의 반복으로 바꾼다 (신고로 할 일을 끝내지 않는다).
 * commitment 후보는 unmatched가 되지 않으므로, Action을 못 얻으면 오류로 본다.
 */
export async function reportMissing(
  admin: SupabaseClient,
  source: { id: string; userId: string; processingStatus: string },
  input: MissingInput,
  deps: ProcessDeps = processDepsFromEnv(),
): Promise<MissingReportResponse> {
  const tracked = await trackedActionSummary(admin, source, input.quote);
  if (tracked) return { status: "already_tracked", action: tracked, stage: null };

  const retryAt = await takeRateLimit(admin, source.userId, "missing_report", MISSING_REPORT_LIMIT);
  if (retryAt) throw new RateLimitedError(retryAt);
  const ai = withConsentGate(deps, consentCheck(admin, source.userId));

  const { data: logs } = await admin
    .from("judge_logs")
    .select("candidate, decision")
    .eq("user_id", source.userId)
    .eq("source_id", source.id)
    .throwOnError();
  const stage = classifyMiss({
    processingStatus: source.processingStatus,
    logs: ((logs ?? []) as { candidate: { quote?: unknown } | null; decision: MissLog["decision"] }[]).map((log) => ({
      quote: typeof log.candidate?.quote === "string" ? log.candidate.quote : "",
      decision: log.decision,
    })),
    quote: input.quote,
  });

  const { judged } = await extractMissing(input, ai);
  const store = new SupabaseActionStore(admin, source.userId, {
    createEvents: [{ type: "user_reported_missing", before: null, after: { stage, source_id: source.id }, rule: null, actor: "user" }],
  });
  const [outcome] = await withUserLock(source.userId, async () => {
    await backfillEmbeddings(store, ai.embed);
    return mergeJudged(reportStore(store), [judged], { id: source.id, text: input.text, kind: input.kind, occurredAt: input.occurredAt }, input.identity, {
      embed: ai.embed,
      decide: reportMatchDecide(ai.decide),
      newId: () => crypto.randomUUID(),
    });
  });
  if (!outcome?.actionId) throw new Error(`누락 신고를 반영하지 못했습니다 (${outcome?.relation ?? "결과 없음"})`);

  const action = await actionSummary(admin, source.userId, outcome.actionId);
  return outcome.relation === "new" ? { status: "created", action, stage } : { status: "already_tracked", action, stage: null };
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
