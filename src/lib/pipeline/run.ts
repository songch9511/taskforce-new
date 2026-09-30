import { EXTRACT_PROMPT_VERSION } from "@/lib/ai/prompts/extract";
import { JUDGE_PROMPT_VERSION } from "@/lib/ai/prompts/judge";

import { extractCandidates, type ActionCandidate, type CompleteJson, type ExtractInput } from "./extract";
import { judgeCandidate, type Decide, type JudgeResult } from "./judge";
import { verifyCandidates, type VerifiedCandidate } from "./verify";

// 원문 하나를 파이프라인 끝까지 돌린다: ① 추출 → ② 기계적 검증 → ③ Jev 판정.
// DB와 분리된 함수라 API · eval · 테스트에서 같은 코드를 쓴다. 매칭 · 진실 판정은 그 뒤 merge.ts mergeJudged가 한다.

export type PipelineDeps = { complete: CompleteJson; decide: Decide };

export type JudgedCandidate = { candidate: VerifiedCandidate; judge: JudgeResult };

export type PipelineResult = {
  judged: JudgedCandidate[];
  /** 인용이 원문에 없거나 연결로 가져온 메일의 인용된 옛 메일에만 있어 버린 후보 수 */
  droppedCount: number;
  /**
   * 연결로 가져온 메일의 인용된 옛 메일에만 있어 기계 검증이 버린 후보. 처리 기록(judge_logs)에 남겨, 사용자가 신고한 누락이
   * 이 규칙 때문인지 가른다 (missing.ts classifyMiss의 quoted_history). 인용이 원문에 없는 후보(환각)는 남기지 않는다
   */
  droppedQuotedHistory: ActionCandidate[];
  summary: {
    extracted: number;
    dropped: number;
    /** 버린 후보를 이유별로: 인용이 원문에 없음(환각) / 연결 메일의 인용된 옛 메일에만 있음 */
    droppedByReason: { quoteNotFound: number; quotedHistory: number };
    auto: number;
    confirm: number;
    reject: number;
    dueCorrected: number;
    models: { extract: string; judge: string | null };
    promptVersions: { extract: string; judge: string };
    cost: number;
    reasoningLimited: boolean;
  };
};

export async function runPipeline(input: ExtractInput, deps: PipelineDeps): Promise<PipelineResult> {
  const extracted = await extractCandidates(input, deps.complete);
  const verified = verifyCandidates(extracted.candidates, { text: input.text, occurredAt: input.occurredAt, kind: input.kind, fromConnector: input.fromConnector });

  const source = { text: input.text, kind: input.kind, occurredAt: input.occurredAt, participants: input.participants, writtenByMe: input.writtenByMe };
  const judged = await Promise.all(
    verified.kept.map(async (candidate) => ({
      candidate,
      judge: await judgeCandidate(candidate, source, input.identity, deps.decide),
    })),
  );

  const quotedHistory = verified.dropped.filter((d) => d.reason === "QUOTED_HISTORY");
  const count = (decision: JudgeResult["decision"]) => judged.filter((j) => j.judge.decision === decision).length;
  const cost = (extracted.usage?.cost ?? 0) + judged.reduce((sum, j) => sum + (j.judge.cost ?? 0), 0);

  return {
    judged,
    droppedCount: verified.dropped.length,
    droppedQuotedHistory: quotedHistory.map((d) => d.candidate),
    summary: {
      extracted: extracted.candidates.length,
      dropped: verified.dropped.length,
      droppedByReason: { quoteNotFound: verified.dropped.length - quotedHistory.length, quotedHistory: quotedHistory.length },
      auto: count("auto"),
      confirm: count("confirm"),
      reject: count("reject"),
      dueCorrected: verified.kept.filter((c) => c.due_check === "corrected").length,
      models: { extract: extracted.model, judge: judged[0]?.judge.model ?? null },
      promptVersions: { extract: EXTRACT_PROMPT_VERSION, judge: JUDGE_PROMPT_VERSION },
      cost,
      // 추출이 한도를 넘겨 추론량을 제한해 다시 물은 답이면 true (품질이 조금 낮을 수 있다, 제품 원칙 6)
      reasoningLimited: extracted.reasoningLimited,
    },
  };
}
