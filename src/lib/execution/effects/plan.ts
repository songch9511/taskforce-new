import { PLAN_PROMPT_VERSION } from "@/lib/ai/prompts/plan";

import { DRAFT_ESTIMATE_CREDITS } from "../limits";
import { loadExecutionContext } from "../material";
import { planNextStep } from "../plan";
import type { EffectInput, EffectResult, RunOutcome } from "../types";

// 계획 단계 (내부 효과, 플랫폼 원가라 청구하지 않는다): planner(plan.ts)가 고른 다음 단계 하나를 run에 반영한다.
//   draft → 초안 단계를 붙인다 (예약 추정치 DRAFT_ESTIMATE_CREDITS). 계획 단계는 초안을 붙일 자리가 있을 때만 생기므로(seq 1, 그리고
//           effects/draft.ts가 MAX_STEPS 안에서 붙인 것) 여기서 단계 상한을 다시 보지 않는다
//   needs_connection → run을 끝낸다, 결과 needs_connection (A39: 초안 단계 0 · 청구 0, 앞서 만든 초안은 그대로)
//   ask_user → run을 끝낸다, 결과 needs_input (질문은 receipt.question)
//   done → run을 끝낸다, 앞선 초안이 있으면 결과 draft_ready
// 같은 계획 단계를 다시 부르면(lease 만료 뒤 다시 준비) 앞 시도가 이미 붙인 단계가 있을 수 있다: 모델을 다시 부르지 않고 그대로 끝내고 깨운다.

export async function planEffect({ store, complete, run, step, now }: EffectInput): Promise<EffectResult> {
  if (await store.hasStepAfter(run.id, step.seq)) {
    return {
      receipt: { decision: "draft", prompt_version: PLAN_PROMPT_VERSION },
      attempts: [],
      artifact: null,
      append: null,
      outcome: null,
      finish: false,
      stepAfterExists: true,
    };
  }

  const [{ context, name }, history] = await Promise.all([loadExecutionContext(store, run), store.draftHistory(run.id, step.seq)]);
  const result = await planNextStep(
    {
      request: run.request,
      now,
      user: { name },
      context,
      history: history.map((h) => ({ kind: "draft", status: h.state, brief: h.brief ?? "", title: h.title })),
    },
    complete,
  );
  const drafted = history.some((h) => h.state === "called");
  const base = { attempts: result.attempts, artifact: null };
  const receipt = (extra: Record<string, unknown>) => ({ ...extra, model: result.model, prompt_version: result.promptVersion });
  const end = (outcome: RunOutcome | null, extra: Record<string, unknown>): EffectResult => ({
    ...base,
    receipt: receipt(extra),
    append: null,
    outcome,
    finish: outcome === null,
  });

  const next = result.step;
  switch (next.kind) {
    case "draft":
      return {
        ...base,
        receipt: receipt({ decision: "draft" }),
        append: { kind: "draft", provider: "taskforce", tool: "draft", purpose: "draft", args: { brief: next.brief }, estimate_credits: DRAFT_ESTIMATE_CREDITS },
        outcome: null,
        finish: false,
      };
    case "needs_connection":
      return end("needs_connection", { decision: "needs_connection", capability: next.capability });
    case "ask_user":
      return end("needs_input", { decision: "ask_user", question: next.question });
    case "done":
      return end(drafted ? "draft_ready" : null, { decision: "done" });
  }
}
