import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { SupabaseActionStore } from "@/lib/actions/db-store";
import { embed, embedConfigFromEnv, EmbedError } from "@/lib/ai/embed";
import { decide, jevConfigFromEnv, JevError } from "@/lib/ai/jev";
import { completeJson, llmConfigFromEnv, LlmError } from "@/lib/ai/llm";
import type { ExtractInput } from "@/lib/pipeline/extract";
import { mergeJudged, type MergeDeps } from "@/lib/pipeline/merge";
import { runPipeline, type PipelineDeps } from "@/lib/pipeline/run";
import { notifyConfirmations } from "@/lib/notify/service";

// 저장된 원문 하나를 끝까지 처리한다 (POST /api/v1/sources · 연동 동기화가 부른다):
// 추출 → 검증 → Jev 판정(judge_logs) → 기존 Action과 매칭 · 병합(actions · claims · evidence · action_events).
// Action 쓰기는 서버만 할 수 있으므로 service role 클라이언트로 부르고, 모든 쓰기에 user_id를 넣는다.

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
  await scoped(admin.from("sources").update({ processing_status: "processing" })).throwOnError();

  try {
    const result = await runPipeline(input, deps);

    if (result.judged.length > 0) {
      await admin
        .from("judge_logs")
        .insert(
          result.judged.map(({ candidate, judge }) => ({
            user_id: source.userId,
            source_id: sourceId,
            candidate,
            jev_answers: { signals: judge.signals, reasons: judge.reasons },
            decision: judge.decision,
            model_version: `${judge.model}@${judge.promptVersion}`,
          })),
        )
        .throwOnError();
    }

    // 기존 Action과 맞춰 보고 반영한다.
    const store = new SupabaseActionStore(admin, source.userId);
    const outcomes = await withUserLock(source.userId, () =>
      mergeJudged(
        store,
        result.judged,
        { id: sourceId, text: input.text, kind: input.kind, occurredAt: input.occurredAt },
        input.identity,
        { embed: deps.embed, decide: deps.decide, newId: () => crypto.randomUUID() },
      ),
    );
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
    return { needsConfirmation: [] };
  }
}
