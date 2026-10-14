import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { AnswerInputError } from "./answers";
import { answerAgentApproval } from "./approvals";

const USER = "11111111-1111-4111-8111-111111111111";
const TASK = "22222222-2222-4222-8222-222222222222";
const STEP = "33333333-3333-4333-8333-333333333333";
const question = { kind: "approval", questions: [{ id: "approval", secret: false }] };
const input = { userId: USER, agentTaskId: TASK, providerRequestId: "request-1", answers: { approval: "allow" }, question };
function client(outcome: unknown = { status: "answered", step_id: STEP }) {
  const run = vi.fn(async () => ({ data: outcome }));
  const rpc = vi.fn(() => ({ throwOnError: run }));
  return { admin: { rpc } as unknown as SupabaseClient, rpc, run };
}
describe("answerAgentApproval", () => {
  it.each(["allow", "deny"])("answers %s via the single transactional approval RPC", async (decision) => {
    const { admin, rpc } = client();
    expect(await answerAgentApproval(admin, { ...input, answers: { approval: decision } })).toEqual({ status: "answered", step_id: STEP });
    expect(rpc).toHaveBeenCalledExactlyOnceWith("answer_agent_approval", {
      p_user_id: USER, p_task_id: TASK, p_provider_request_id: "request-1", p_answers: { approval: decision },
    });
  });
  it.each([
    { answers: { approval: "Allow" } }, { answers: { approval: ["allow"] } }, { answers: { approval: "allow", extra: "deny" } },
    { answers: {} }, { question: { ...question, questions: [question.questions[0], question.questions[0]] } },
    { question: { ...question, kind: "input" } }, { question: { ...question, questions: [{ id: "approval", secret: true }] } },
    { userId: "other" }, { providerRequestId: "" },
  ])("rejects invalid approval input before RPC %#", async (override) => {
    const { admin, rpc } = client();
    await expect(answerAgentApproval(admin, { ...input, ...override })).rejects.toBeInstanceOf(AnswerInputError);
    expect(rpc).not.toHaveBeenCalled();
  });
  it.each(["duplicate", "question_stale", "invalid_answer", "not_found"])("preserves SQL %s", async (status) => {
    const result = status === "duplicate" ? { status, step_id: STEP } : { status };
    const { admin } = client(result);
    expect(await answerAgentApproval(admin, input)).toEqual(result);
  });
  it("retries rolled-back lock contention, but does not misclassify database errors", async () => {
    const { admin, rpc, run } = client();
    run.mockRejectedValueOnce({ code: "55P03" });
    await answerAgentApproval(admin, input);
    expect(rpc).toHaveBeenCalledTimes(2);
    run.mockRejectedValueOnce({ code: "XX000", message: "private" });
    await expect(answerAgentApproval(admin, input)).rejects.toMatchObject({ code: "XX000" });
    expect(rpc).toHaveBeenCalledTimes(3);
  });
  it("rejects malformed SQL results as a server failure", async () => {
    const { admin } = client({ status: "allow" });
    await expect(answerAgentApproval(admin, input)).rejects.not.toBeInstanceOf(AnswerInputError);
  });
});
