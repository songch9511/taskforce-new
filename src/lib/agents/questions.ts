import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

const answerText = z.string().refine((value) => Array.from(value).length <= 2000);
export const agentAnswersSchema = z.record(z.string(), z.union([answerText, z.array(answerText).max(10)]))
  .refine((answers) => {
    // JSONB includes spaces between keys and values and between array entries.
    const serialized = "{" + Object.entries(answers).map(([key, value]) => `${JSON.stringify(key)}: ${Array.isArray(value)
      ? "[" + value.map((item) => JSON.stringify(item)).join(", ") + "]" : JSON.stringify(value)}`).join(", ") + "}";
    return Buffer.byteLength(serialized, "utf8") <= 4096;
  }, "Answers exceed 4096 UTF-8 bytes");
const questionShape = z.object({
  kind: z.enum(["input", "approval"]),
  questions: z.array(z.object({
    id: z.string(), options: z.array(z.object({ label: z.string() })),
    multi_select: z.boolean(), allow_other: z.boolean(), secret: z.boolean(),
  })).min(1).max(4),
});
export const answerAgentQuestionResultSchema = z.discriminatedUnion("status", [
  z.strictObject({ status: z.enum(["answered", "duplicate"]), step_id: z.guid() }),
  z.strictObject({ status: z.enum(["question_stale", "invalid_answer", "secret_requires_local", "not_found"]) }),
]);
export type AnswerAgentQuestionResult = z.infer<typeof answerAgentQuestionResultSchema>;

/** answeredLocally requires server proof of the session-owning Mac; never copy it from a request body. */
export async function answerAgentQuestion(admin: SupabaseClient, input: {
  userId: string; agentTaskId: string; providerRequestId: string;
  answers: unknown; answeredLocally?: boolean; question: unknown;
}): Promise<AnswerAgentQuestionResult> {
  const userId = z.guid().parse(input.userId);
  const taskId = z.guid().parse(input.agentTaskId);
  const requestId = z.string().min(1).refine((value) => Array.from(value).length <= 200).parse(input.providerRequestId);
  const local = z.boolean().parse(input.answeredLocally ?? false);
  const answers = input.answers === null ? null : agentAnswersSchema.parse(input.answers);
  const question = questionShape.parse(input.question);
  const secret = question.questions.some((item) => item.secret);
  if (local) {
    if ((answers !== null && Object.keys(answers).length !== 0) || !secret) throw new Error("Local answers must contain only a secret-answer marker");
  } else {
    if (secret || answers === null) throw new Error("Secret answers require the session-owning Mac");
    if (Object.keys(answers).length !== question.questions.length) throw new Error("Answer every question exactly once");
    for (const item of question.questions) {
      const value = Object.hasOwn(answers, item.id) ? answers[item.id] : undefined;
      const labels = item.options.map((option) => option.label);
      const valid = question.kind === "approval" ? value === "allow" || value === "deny"
        : item.multi_select ? Array.isArray(value) && value.length > 0 && new Set(value).size === value.length && value.every((label) => labels.includes(label))
        : typeof value === "string" && (labels.includes(value) || (item.allow_other && value.trim().length > 0));
      if (!valid) throw new Error("Answer does not match the question");
    }
  }
  const { data } = await admin.rpc("answer_agent_question", {
    p_user_id: userId, p_agent_task_id: taskId, p_provider_request_id: requestId,
    p_answers: answers, p_answered_locally: local,
  }).throwOnError();
  return answerAgentQuestionResultSchema.parse(data);
}
