import type { SupabaseClient } from "@supabase/supabase-js";

import { answerAgentQuestion, type AnswerAgentQuestionResult } from "./questions";

// 질문 답 route의 보조 (Assistant 계약 v3 3.6, OA D1d-s). answerAgentQuestion(questions.ts)은 그대로 쓴다.

/** 답이 질문과 맞지 않는다 (RPC 앞의 입력 검증 실패 → route는 400). DB 오류와 구별한다 */
export class AnswerInputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AnswerInputError";
  }
}

/**
 * answerAgentQuestion을 부르되 RPC에 닿기 전의 실패(모양 · 질문과의 불일치 · 비밀값 로컬 처리)만 AnswerInputError로 바꾼다.
 * questions.ts의 모든 입력 검증은 admin.rpc 앞에서 끝나므로, rpc가 불린 뒤의 오류(DB 오류 · 예상 밖 출력)는 입력 오류로 둔갑하지 않는다
 */
export async function answerFromRoute(
  admin: SupabaseClient,
  input: { userId: string; agentTaskId: string; providerRequestId: string; answers: unknown; question: unknown },
): Promise<AnswerAgentQuestionResult> {
  let reachedDatabase = false;
  const probe = {
    rpc: (...args: Parameters<SupabaseClient["rpc"]>) => {
      reachedDatabase = true;
      return admin.rpc(...args);
    },
  } as unknown as SupabaseClient;
  try {
    return await answerAgentQuestion(probe, { ...input, answeredLocally: false });
  } catch (error) {
    if (!reachedDatabase) throw new AnswerInputError(error instanceof Error ? error.message : "invalid answer");
    throw error;
  }
}

export type AnswerTask = { id: string; sessionId: string; pendingQuestion: unknown; answeredQuestion: unknown };

/** 내 작업의 세션 · 열린 질문 · 이미 답이 간 질문 (같은 답을 다시 보내면 duplicate로 수렴하려고 answered_question도 읽는다) */
export async function loadAnswerTask(admin: SupabaseClient, userId: string, taskId: string): Promise<AnswerTask | null> {
  const { data } = await admin.from("agent_tasks").select("id, agent_session_id, pending_question, answered_question").eq("user_id", userId).eq("id", taskId).maybeSingle().throwOnError();
  if (!data) return null;
  const row = data as { id: string; agent_session_id: string; pending_question: unknown; answered_question: unknown };
  return { id: row.id, sessionId: row.agent_session_id, pendingQuestion: row.pending_question ?? null, answeredQuestion: row.answered_question ?? null };
}

/** question_answered (OD-16): 질문 종류와 adapter만. 답 값 · 글은 담지 않는다 */
export async function recordQuestionAnswered(admin: SupabaseClient, userId: string, info: { kind: string; adapter: string }): Promise<void> {
  await admin.from("metric_events").insert({ user_id: userId, type: "question_answered", props: { kind: info.kind, adapter: info.adapter } }).throwOnError();
}
