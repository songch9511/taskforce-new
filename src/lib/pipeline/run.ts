import { EXTRACT_PROMPT_VERSION } from "@/lib/ai/prompts/extract";
import { JUDGE_PROMPT_VERSION } from "@/lib/ai/prompts/judge";

import { extractCandidates, type CompleteJson, type ExtractInput } from "./extract";
import { judgeCandidate, type Decide, type JudgeResult } from "./judge";
import { verifyCandidates, type VerifiedCandidate } from "./verify";

// 원문 하나를 파이프라인 끝까지 돌린다: ① 추출 → ② 기계적 검증 → ③ Jev 판정.
// DB와 분리된 함수라 API · eval · 테스트에서 같은 코드를 쓴다. (④ 매칭 · ⑤ 진실 판정은 Phase 2)

export type PipelineDeps = { complete: CompleteJson; decide: Decide };

export type JudgedCandidate = { candidate: VerifiedCandidate; judge: JudgeResult };

export type PipelineResult = {
  judged: JudgedCandidate[];
  /** 원문에 없는 인용이라 버린 후보 수 */
  droppedCount: number;
  summary: {
    extracted: number;
    dropped: number;
    auto: number;
    confirm: number;
    reject: number;
    dueCorrected: number;
    models: { extract: string; judge: string | null };
    promptVersions: { extract: string; judge: string };
    cost: number;
  };
};

export async function runPipeline(input: ExtractInput, deps: PipelineDeps): Promise<PipelineResult> {
  const extracted = await extractCandidates(input, deps.complete);
  const verified = verifyCandidates(extracted.candidates, { text: input.text, occurredAt: input.occurredAt });

  const source = { text: input.text, kind: input.kind, occurredAt: input.occurredAt, participants: input.participants };
  const judged = await Promise.all(
    verified.kept.map(async (candidate) => ({
      candidate,
      judge: await judgeCandidate(candidate, source, input.identity, deps.decide),
    })),
  );

  const count = (decision: JudgeResult["decision"]) => judged.filter((j) => j.judge.decision === decision).length;
  const cost = (extracted.usage?.cost ?? 0) + judged.reduce((sum, j) => sum + (j.judge.cost ?? 0), 0);

  return {
    judged,
    droppedCount: verified.dropped.length,
    summary: {
      extracted: extracted.candidates.length,
      dropped: verified.dropped.length,
      auto: count("auto"),
      confirm: count("confirm"),
      reject: count("reject"),
      dueCorrected: verified.kept.filter((c) => c.due_check === "corrected").length,
      models: { extract: extracted.model, judge: judged[0]?.judge.model ?? null },
      promptVersions: { extract: EXTRACT_PROMPT_VERSION, judge: JUDGE_PROMPT_VERSION },
      cost,
    },
  };
}
