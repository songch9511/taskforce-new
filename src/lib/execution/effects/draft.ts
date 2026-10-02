import { writeDraft } from "../draft";
import { MAX_STEPS } from "../limits";
import { loadExecutionContext } from "../material";
import type { EffectInput, EffectResult } from "../types";

// 초안 단계 (내부 효과, 청구 대상): 계획 단계가 고른 지시(brief, begin_call이 돌려준 인자)로 초안 하나를 써서 산출물로 남긴다. 보내지 않는다.
// 끝내기 전에 다음 계획 단계를 붙여 남은 조각(예: "써서 보내 줘"의 보내기 → needs_connection)을 다시 본다.
// 그 계획이 또 초안을 붙일 자리가 없으면(MAX_STEPS) 붙이지 않고 run을 draft_ready로 끝낸다.

export async function draftEffect({ store, complete, run, step, args, now }: EffectInput): Promise<EffectResult> {
  const { context, name } = await loadExecutionContext(store, run);
  const result = await writeDraft(
    { request: run.request, brief: typeof args.brief === "string" ? args.brief : null, now, user: { name }, context },
    complete,
  );
  const followUp = step.seq + 2 <= MAX_STEPS;
  return {
    // 받는 사람은 모델이 자료에서 고른 것이다 (보낼 때 쓰지 않는다, 사용자가 보고 고친다)
    receipt: { to: result.draft.to, model: result.model, prompt_version: result.promptVersion },
    attempts: result.attempts,
    artifact: { title: result.draft.title, body: result.draft.body, model: result.model, prompt_version: result.promptVersion },
    append: followUp ? { kind: "plan", provider: "taskforce", tool: "plan", purpose: "plan", estimate_credits: 0 } : null,
    outcome: followUp ? null : "draft_ready",
    finish: false,
  };
}
