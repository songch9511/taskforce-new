import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { answerAgentQuestion, agentAnswersSchema } from "./questions";

const id = "10000000-0000-4000-8000-000000000001";
const question = { provider_request_id: "request", kind: "input" as const, structured: true, questions: [
  { id: "choice", header: "Pick", text: "Choose", options: [{ label: "A", description: "" }, { label: "B", description: "" }], multi_select: false, allow_other: false, secret: false },
] };
const input = { userId: id, agentTaskId: id, providerRequestId: "request", answers: { choice: "A" }, question };
function db(response: unknown = { status: "answered", step_id: id }) {
  const rpc = vi.fn().mockReturnValue({ throwOnError: vi.fn().mockResolvedValue({ data: response }) });
  return { rpc, admin: { rpc } as unknown as SupabaseClient };
}
describe("answerAgentQuestion", () => {
  it("sends a validated answer once and preserves the question key", async () => {
    const d = db();
    expect(await answerAgentQuestion(d.admin, input)).toEqual({ status: "answered", step_id: id });
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("answer_agent_question", { p_user_id: id, p_agent_task_id: id, p_provider_request_id: "request", p_answers: { choice: "A" }, p_answered_locally: false });
  });
  it.each(["duplicate", "question_stale", "invalid_answer", "secret_requires_local", "not_found"])("preserves SQL %s", async (status) => {
    const result = status === "duplicate" ? { status, step_id: id } : { status };
    expect(await answerAgentQuestion(db(result).admin, input)).toEqual(result);
  });
  it.each([
    { choice: "unknown" }, { choice: ["A"] }, {}, { choice: "A", extra: "A" },
  ])("rejects mismatched single answers before RPC", async (answers) => {
    const d = db();
    await expect(answerAgentQuestion(d.admin, { ...input, answers })).rejects.toThrow();
    expect(d.rpc).not.toHaveBeenCalled();
  });
  it("validates multi-select, Other, all questions, and approval", async () => {
    const base = question.questions[0];
    for (const [shape, answers] of [
      [{ ...question, questions: [{ ...base, multi_select: true }] }, { choice: ["A", "B"] }],
      [{ ...question, questions: [{ ...base, allow_other: true }] }, { choice: "Something else" }],
      [{ ...question, questions: [base, { ...base, id: "second" }] }, { choice: "A", second: "B" }],
      [{ ...question, kind: "approval" }, { choice: "allow" }],
      [{ ...question, kind: "approval" }, { choice: "deny" }],
    ] as const) {
      expect(await answerAgentQuestion(db().admin, { ...input, question: shape, answers })).toEqual({ status: "answered", step_id: id });
    }
  });
  it.each([
    [{ ...question, questions: [{ ...question.questions[0], multi_select: true }] }, { choice: [] }],
    [{ ...question, questions: [{ ...question.questions[0], allow_other: true }] }, { choice: " \t\n" }],
    [{ ...question, questions: [{ ...question.questions[0], multi_select: true }] }, { choice: ["unknown"] }],
    [{ ...question, questions: [{ ...question.questions[0], multi_select: true }] }, { choice: ["A", "A"] }],
    [{ ...question, questions: [{ ...question.questions[0], allow_other: true }] }, { choice: "x".repeat(2001) }],
    [{ ...question, kind: "approval" }, { choice: "A" }],
    [{ ...question, questions: [{ ...question.questions[0], allow_other: true }] }, { choice: "" }],
  ])("rejects invalid choice forms", async (shape, answers) => {
    const d = db();
    await expect(answerAgentQuestion(d.admin, { ...input, question: shape, answers })).rejects.toThrow();
    expect(d.rpc).not.toHaveBeenCalled();
  });
  it("accepts only a trusted local marker for secrets, never a value", async () => {
    const secret = { ...question, questions: [{ ...question.questions[0], secret: true }] };
    const remote = db();
    await expect(answerAgentQuestion(remote.admin, { ...input, question: secret })).rejects.toThrow();
    expect(remote.rpc).not.toHaveBeenCalled();
    const d = db();
    await answerAgentQuestion(d.admin, { ...input, question: secret, answers: null, answeredLocally: true });
    expect(d.rpc).toHaveBeenCalledWith("answer_agent_question", expect.objectContaining({ p_answers: null, p_answered_locally: true }));
    for (const answers of [null, {}, { choice: "secret" }]) {
      const bad = db();
      await expect(answerAgentQuestion(bad.admin, { ...input, question: secret, answers, answeredLocally: answers !== null && Object.keys(answers).length > 0 })).rejects.toThrow();
      expect(bad.rpc).not.toHaveBeenCalled();
    }
    await expect(answerAgentQuestion(db().admin, { ...input, answeredLocally: true })).rejects.toThrow();
  });
  it.each([
    { answers: { choice: "secret-value" } },
    { answers: {}, answeredLocally: true },
    { answers: null, answeredLocally: true },
  ])("rejects answers without a question snapshot before RPC", async (patch) => {
    const d = db();
    await expect(answerAgentQuestion(d.admin, { ...input, question: undefined, ...patch })).rejects.toThrow();
    expect(d.rpc).not.toHaveBeenCalled();
  });
  it("validates keys and local markers with a supplied question snapshot", async () => {
    for (const patch of [{ agentTaskId: "bad" }, { providerRequestId: "" }, { providerRequestId: "x".repeat(201) }, { answers: null }, { answers: { choice: "value" }, answeredLocally: true }]) {
      const invalid = db();
      await expect(answerAgentQuestion(invalid.admin, { ...input, ...patch })).rejects.toThrow();
      expect(invalid.rpc).not.toHaveBeenCalled();
    }
  });
  it("bounds answers in UTF-8 bytes and text in Unicode characters", () => {
    expect(agentAnswersSchema.safeParse({ a: "😀".repeat(1100) }).success).toBe(false);
    expect(agentAnswersSchema.safeParse({ a: "x".repeat(2001) }).success).toBe(false);
    expect(agentAnswersSchema.safeParse({ a: "😀".repeat(500) }).success).toBe(true);
  });
  it.each([{ status: "answered" }, { status: "duplicate" }, { status: "unknown" }, { status: "question_stale", value: "leak" }])("rejects malformed response", async (response) => {
    await expect(answerAgentQuestion(db(response).admin, input)).rejects.toThrow();
  });
  it("propagates DB errors", async () => {
    const d = db();
    d.rpc.mockReturnValue({ throwOnError: vi.fn().mockRejectedValue(new Error("db")) });
    await expect(answerAgentQuestion(d.admin, input)).rejects.toThrow("db");
  });
});
