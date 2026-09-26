import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { decide, jevConfigFromEnv } from "@/lib/ai/jev";
import { completeJson, llmConfigFromEnv } from "@/lib/ai/llm";
import type { ExtractInput } from "@/lib/pipeline/extract";
import { runPipeline, type PipelineDeps } from "@/lib/pipeline/run";

// 저장된 원문 하나를 파이프라인에 돌리고 결과를 DB에 남긴다. POST /api/v1/sources가 202를 돌려준 뒤 실행한다.
// Phase 1은 판정 결과를 judge_logs에만 남긴다. Action 반영은 Phase 3(apply.ts)에서 한다.

export function pipelineDepsFromEnv(): PipelineDeps {
  const llm = llmConfigFromEnv();
  const jev = jevConfigFromEnv();
  return { complete: (request) => completeJson(llm, request), decide: (request) => decide(jev, request) };
}

/**
 * `supabase`는 사용자 권한 클라이언트(API)나 service role 클라이언트(연동 동기화) 모두 된다.
 * service role은 auth.uid()가 없으므로 user_id를 직접 넣는다.
 */
export async function processSource(
  supabase: SupabaseClient,
  source: { id: string; userId: string },
  input: ExtractInput,
  deps: PipelineDeps = pipelineDepsFromEnv(),
): Promise<void> {
  const sourceId = source.id;
  await supabase.from("sources").update({ processing_status: "processing" }).eq("id", sourceId).eq("user_id", source.userId).throwOnError();

  try {
    const result = await runPipeline(input, deps);

    if (result.judged.length > 0) {
      await supabase
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

    await supabase
      .from("sources")
      .update({ processing_status: "done", processed_at: new Date().toISOString(), processing_summary: result.summary, processing_error: null })
      .eq("id", sourceId).eq("user_id", source.userId)
      .throwOnError();
  } catch (error) {
    // 오류 메시지에는 원문이 들어가지 않는다 (LLM · Jev 오류는 상태 코드와 형식 문제만 담는다).
    const message = error instanceof Error ? error.message : "알 수 없는 오류";
    console.error(`원문 처리 실패 (${sourceId}):`, message);
    await supabase
      .from("sources")
      .update({ processing_status: "failed", processed_at: new Date().toISOString(), processing_error: message.slice(0, 300) })
      .eq("id", sourceId).eq("user_id", source.userId);
  }
}
