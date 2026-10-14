import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), loadAnswerTask: vi.fn(), loadSessionAdapter: vi.fn(), answerAgentQuestion: vi.fn(), answerAgentApproval: vi.fn(),
}));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/sessions", async (original) => ({ ...(await original<typeof import("@/lib/agents/sessions")>()), loadSessionAdapter: mocks.loadSessionAdapter }));
vi.mock("@/lib/agents/questions", async (original) => ({ ...(await original<typeof import("@/lib/agents/questions")>()), answerAgentQuestion: mocks.answerAgentQuestion }));
vi.mock("@/lib/agents/answers", async (original) => ({ ...(await original<typeof import("@/lib/agents/answers")>()), loadAnswerTask: mocks.loadAnswerTask }));

vi.mock("@/lib/agents/approvals", () => ({ answerAgentApproval: mocks.answerAgentApproval }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const TASK = "7a7a7a7a-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const STEP = "57575757-0000-4000-8000-000000000001";
const question = (extra: Record<string, unknown> = {}) => ({
  question_key: [TASK, "q-1"], provider_request_id: "q-1", kind: "input", structured: true, asked_at: "2026-10-14T01:00:00Z",
  questions: [{ id: "choice", header: "h", text: "t", options: [{ label: "Yes", description: "d" }], multi_select: false, allow_other: true, secret: false }],
  ...extra,
});
const call = (body: unknown = { provider_request_id: "q-1", answers: { choice: "Yes" } }) =>
  POST(new Request(`https://api.example.dev/api/v2/agent-tasks/${TASK}/answer`, { method: "POST", body: JSON.stringify(body) }), { params: Promise.resolve({ id: TASK }) });

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.loadSessionAdapter.mockResolvedValue({ adapter: "agent:codex", enabled: true });
  mocks.loadAnswerTask.mockResolvedValue({ id: TASK, sessionId: SESSION, pendingQuestion: question(), answeredQuestion: null });
  mocks.answerAgentApproval.mockResolvedValue({ status: "answered", step_id: STEP });
  mocks.answerAgentQuestion.mockResolvedValue({ status: "answered", step_id: STEP });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/agent-tasks/{id}/answer (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · RPC 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.answerAgentQuestion).not.toHaveBeenCalled();
  });

  it("켜져 있으면 열린 질문에 답을 넘기고(answered_locally는 늘 false) 지표는 SQL 래퍼가 같은 트랜잭션에서 쓴다 (recordMetric: true, 별도 insert 없음)", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "answered", step_id: STEP });
    expect(mocks.answerAgentQuestion).toHaveBeenCalledExactlyOnceWith(expect.anything(), { userId: USER, agentTaskId: TASK, providerRequestId: "q-1", answers: { choice: "Yes" }, question: question(), answeredLocally: false, recordMetric: true });
  });

  it("비밀값 · 옛 열쇠는 RPC 없이 409", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    const cases: [Record<string, unknown>, string][] = [
      [question({ questions: [{ id: "choice", header: "h", text: "t", options: [], multi_select: false, allow_other: true, secret: true }] }), "secret_requires_local"],
      [question({ question_key: [TASK, "q-2"] }), "question_stale"],
    ];
    for (const [pendingQuestion, code] of cases) {
      mocks.loadAnswerTask.mockResolvedValue({ id: TASK, sessionId: SESSION, pendingQuestion, answeredQuestion: null });
      const response = await call();
      expect(response.status).toBe(409);
      expect(await response.json()).toMatchObject({ error: { code } });
    }
    expect(mocks.answerAgentQuestion).not.toHaveBeenCalled();
  });
});

it.each(["allow", "deny"])("U4 wires approval %s through realAnswerDeps", async (decision) => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  const approval = question({ kind: "approval", questions: [{ ...question().questions[0], id: "approval" }] });
  mocks.loadAnswerTask.mockResolvedValue({ id: TASK, sessionId: SESSION, pendingQuestion: approval, answeredQuestion: null });
  const response = await call({ provider_request_id: "q-1", answers: { approval: decision } });
  expect(response.status).toBe(200);
  expect(mocks.answerAgentApproval).toHaveBeenCalledExactlyOnceWith(expect.anything(), {
    userId: USER, agentTaskId: TASK, providerRequestId: "q-1", answers: { approval: decision }, question: approval,
  });
  expect(mocks.answerAgentQuestion).not.toHaveBeenCalled();
});
