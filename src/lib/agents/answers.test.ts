import { describe, expect, it } from "vitest";

import { AnswerInputError, answerFromRoute, loadAnswerTask } from "./answers";
import { fakeAdmin } from "./fake-admin";

const USER = "10000000-0000-4000-8000-000000000001";
const OTHER = "20000000-0000-4000-8000-000000000002";
const TASK = "7a000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const STEP = "57000000-0000-4000-8000-000000000001";
const question = (secret = false) => ({
  kind: "input" as const,
  questions: [{ id: "choice", options: [{ label: "Yes" }, { label: "No" }], multi_select: false, allow_other: true, secret }],
});

describe("loadAnswerTask", () => {
  it("내 작업의 세션 · 열린 질문 · 이미 답이 간 질문을 읽는다 (남의 작업 · 없는 작업은 null)", async () => {
    const pending = { question_key: [TASK, "q"], kind: "input" };
    const fake = fakeAdmin({ tables: { agent_tasks: [{ id: TASK, user_id: USER, agent_session_id: SESSION, pending_question: pending, answered_question: null }] } });
    expect(await loadAnswerTask(fake.admin, USER, TASK)).toEqual({ id: TASK, sessionId: SESSION, pendingQuestion: pending, answeredQuestion: null });
    expect(await loadAnswerTask(fake.admin, OTHER, TASK)).toBeNull();
    expect(await loadAnswerTask(fake.admin, USER, STEP)).toBeNull();
  });
});

describe("answerFromRoute: 입력 검증 실패와 DB 오류를 구별한다", () => {
  const answered = { status: "answered", step_id: STEP };
  const input = (answers: unknown, q = question()) => ({ userId: USER, agentTaskId: TASK, providerRequestId: "q", answers, question: q });

  it("RPC 앞의 입력 검증 실패는 AnswerInputError (RPC 0)", async () => {
    const fake = fakeAdmin({ rpc: { answer_agent_question_recorded: () => answered } });
    for (const answers of [{ choice: "" }, { choice: "   " }, {}, { choice: "Yes", extra: "x" }, { choice: 5 }]) {
      await expect(answerFromRoute(fake.admin, input(answers))).rejects.toBeInstanceOf(AnswerInputError);
    }
    // 비밀값 질문의 값은 서버로 올 수 없다
    await expect(answerFromRoute(fake.admin, input({ choice: "pw" }, question(true)))).rejects.toBeInstanceOf(AnswerInputError);
    expect(fake.rpcCalls()).toEqual([]);
  });

  it("검증을 통과하면 지표까지 한 트랜잭션에서 남기는 SQL 래퍼 answer_agent_question_recorded를 부르고 결과를 돌려준다 (answered_locally는 늘 false, 별도 TS insert 없음)", async () => {
    const fake = fakeAdmin({ rpc: { answer_agent_question_recorded: () => answered } });
    expect(await answerFromRoute(fake.admin, input({ choice: "Yes" }))).toEqual(answered);
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["answer_agent_question_recorded"]);
    expect(fake.calls.filter((call) => call.kind === "insert")).toEqual([]);
    expect(fake.rpcCalls("answer_agent_question_recorded")[0].args).toMatchObject({ p_user_id: USER, p_agent_task_id: TASK, p_provider_request_id: "q", p_answers: { choice: "Yes" }, p_answered_locally: false });
  });

  it.each(["40001", "40P01", "55P03"])("검토 반영 9-2: %s로 두 번 롤백돼도 세 번째에 성공하면 그 결과를 돌려준다 (RPC 앞 검증은 한 번)", async (code) => {
    let calls = 0;
    const db = fakeAdmin({ rpc: { answer_agent_question_recorded: () => { if (++calls < 3) throw Object.assign(new Error("conflict"), { code }); return answered; } } });
    expect(await answerFromRoute(db.admin, input({ choice: "Yes" }))).toEqual(answered);
    expect(db.rpcCalls("answer_agent_question_recorded")).toHaveLength(3);
  });

  it("RPC 이후의 오류(DB 오류 · 예상 밖 출력)는 그대로 던진다 — 입력 오류로 둔갑하지 않는다", async () => {
    const db = fakeAdmin({ rpc: { answer_agent_question_recorded: () => { throw Object.assign(new Error("lock"), { code: "55P03" }); } } });
    const error = await answerFromRoute(db.admin, input({ choice: "Yes" })).catch((e: unknown) => e);
    expect(error).not.toBeInstanceOf(AnswerInputError);
    expect(error).toMatchObject({ code: "55P03" });
    expect(db.rpcCalls("answer_agent_question_recorded")).toHaveLength(3); // 검토 반영 9-2: 롤백된 경합은 두 번까지 다시 한 뒤에 던진다
    const odd = fakeAdmin({ rpc: { answer_agent_question_recorded: () => ({ status: "mystery" }) } });
    await expect(answerFromRoute(odd.admin, input({ choice: "Yes" }))).rejects.not.toBeInstanceOf(AnswerInputError);
  });
});
