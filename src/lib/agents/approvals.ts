import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AnswerInputError } from "./answers";
import { answerAgentQuestionResultSchema, type AnswerAgentQuestionResult } from "./questions";
import { retryOnConflict } from "./retry";

const approvalInputSchema = z.object({
  userId: z.guid(), agentTaskId: z.guid(),
  providerRequestId: z.string().min(1).refine((value) => Array.from(value).length <= 200),
  answers: z.strictObject({ approval: z.enum(["allow", "deny"]) }),
  question: z.object({ kind: z.literal("approval"), questions: z.array(z.object({ id: z.literal("approval"), secret: z.literal(false) })).length(1) }),
});

/** Approval, its reserved leases and its metric commit together; input questions keep their existing RPC. */
export async function answerAgentApproval(admin: SupabaseClient, input: {
  userId: string; agentTaskId: string; providerRequestId: string; answers: unknown; question: unknown;
}): Promise<AnswerAgentQuestionResult> {
  const parsed = approvalInputSchema.safeParse(input);
  if (!parsed.success) throw new AnswerInputError("Invalid approval answer");
  const { userId, agentTaskId, providerRequestId, answers } = parsed.data;
  const { data } = await retryOnConflict(async () => await admin.rpc("answer_agent_approval", {
    p_user_id: userId, p_task_id: agentTaskId, p_provider_request_id: providerRequestId, p_answers: answers,
  }).throwOnError());
  return answerAgentQuestionResultSchema.parse(data);
}
