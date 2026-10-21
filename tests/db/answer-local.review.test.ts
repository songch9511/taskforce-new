import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { answerFromRoute, loadAnswerTask } from "@/lib/agents/answers";
import { answerAgentApproval } from "@/lib/agents/approvals";
import { loadSessionAdapter } from "@/lib/agents/sessions";
import { handleAnswerQuestion } from "@/lib/api/agent-conversations";
import { loadReturnSummary } from "@/lib/review/return-summary";
import { loadReview } from "@/lib/review/review";

import { adminOf, createCoordinatorDb } from "../coordinator/support";
import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { sha256, REQUEST } from "./answer-local.scenarios";
import { asUser } from "./local-supabase";
import { BOTH, reviewAgentInputsFixtures } from "./review-agent-inputs.scenarios";

// OA F2 T9: 표시의 효과. 질문이 비면 Review 항목이 모든 읽기에서 사라지고, 복귀 요약 줄의 needs_answer가 D4b-s 규칙대로 다시 정해진다. 서버 답 route(D1d)는 표시 전후 모두 409 secret_requires_local.
let db: PGlite;
let admin: SupabaseClient;
let f: ReturnType<typeof reviewAgentInputsFixtures>;
beforeAll(async () => {
  db = await createCoordinatorDb();
  await db.query("select set_config('app.now', '', false)");
  admin = adminOf(db);
  f = reviewAgentInputsFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
}, 120_000);
afterAll(() => db.close());
afterEach(() => vi.unstubAllEnvs());

const NOW = new Date();
const HORIZON = NOW.toISOString().replace("Z", "000Z");
function enrollFixture(user: string): void {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", user);
}
const review = (user: string) => { enrollFixture(user); return loadReview(admin, user, NOW, { coordinatorEnabled: false, timeZone: async () => "Asia/Seoul", agentAdapters: BOTH }); };
const summary = (user: string) => loadReturnSummary(admin, user, NOW, { agentAdapters: BOTH, horizon: HORIZON });
const itemsOf = (response: Awaited<ReturnType<typeof review>>) => (response.decisions ?? []).flatMap((group) => group.items);
const env = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" };
/** D1d의 실제 답 handler를 PGlite admin 위에서 그대로 돌린다 */
const answerWith = (user: string) => async (task: string, body: unknown) => {
  enrollFixture(user);
  const response = await handleAnswerQuestion(new Request(`https://api.example.dev/api/v2/agent-tasks/${task}/answer`, { method: "POST", body: JSON.stringify(body) }), task, {
    enabled: () => true,
    authenticate: async () => ({ user: { id: user } }),
    sessionAdapter: (_u, sessionId) => loadSessionAdapter(admin, user, sessionId, { ...env, AGENT_BETA_USER_IDS: user }),
    loadTask: (_u, taskId) => loadAnswerTask(admin, user, taskId),
    answerApproval: (_u, input) => answerAgentApproval(admin, { userId: user, agentTaskId: input.taskId, providerRequestId: input.providerRequestId, answers: input.answers, question: input.question }),
    answer: (_u, input) => answerFromRoute(admin, { userId: user, agentTaskId: input.taskId, providerRequestId: input.providerRequestId, answers: input.answers, question: input.question }),
  });
  return { status: response.status, body: (await response.json()) as Record<string, unknown> };
};
const local = async (w: { user: string; bridge: string; task: string }) =>
  (await f.one("select public.answer_agent_question_locally($1,$2,$3,$4,$5::text[]) as result", [w.user, w.bridge, w.task, sha256(REQUEST), BOTH])).result as { status: string };

describe("T9 Review · 복귀 요약 · 서버 답 route", () => {
  it("표시 전에는 Review에 agent_secret_question이 있고 복귀 요약 줄이 답할 것으로 나온다. 표시 뒤에는 둘 다 그 결정이 없다", async () => {
    const w = await f.questionWorld(answerQuestionFixture({ secret: true }), "agent:codex");
    expect(await f.inputs(w.user)).toMatchObject([{ kind: "agent_secret_question", item_ref: w.task }]);
    expect(itemsOf(await review(w.user)).map((item) => item.kind)).toEqual(["agent_secret_question"]);
    const line = (await summary(w.user)).items.find((item) => item.action_id === w.action);
    expect(line).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["agent_secret_question"] } });

    expect((await local(w)).status).toBe("answered");

    expect(await f.inputs(w.user)).toEqual([]);
    expect(itemsOf(await review(w.user))).toEqual([]);
    const after = (await summary(w.user)).items.find((item) => item.action_id === w.action);
    expect(after?.decisions ?? []).toEqual([]);
    expect(after?.needs_answer ?? false).toBe(false);
  });

  it("다른 이슈의 비밀값 질문은 영향이 없다 (그 작업의 표시만 그 작업의 항목을 지운다)", async () => {
    const a = await f.questionWorld(answerQuestionFixture({ secret: true }), "agent:codex");
    const other = await f.otherRun(a);
    const task = await f.asking(a.user, other, { secrets: [true] });
    expect((await f.inputs(a.user)).map((row) => row.item_ref).sort()).toEqual([a.task, task].sort());
    await local(a);
    expect((await f.inputs(a.user)).map((row) => row.item_ref)).toEqual([task]);
  });

  it("D1d 답 route는 표시 전후 모두 409 secret_requires_local이고 답 단계를 만들지 않는다", async () => {
    const w = await f.questionWorld(answerQuestionFixture({ secret: true }), "agent:codex");
    const body = { provider_request_id: REQUEST, answers: { choice: "A" } };
    expect(await answerWith(w.user)(w.task, body)).toMatchObject({ status: 409, body: { error: { code: "secret_requires_local" } } });
    expect(await f.answerSteps(w.task)).toEqual([]);
    expect((await local(w)).status).toBe("answered");
    const steps = await f.answerSteps(w.task);
    expect(steps).toHaveLength(1);
    expect(await answerWith(w.user)(w.task, body)).toMatchObject({ status: 409, body: { error: { code: "secret_requires_local" } } });
    expect(await f.answerSteps(w.task)).toHaveLength(1);
  });
});
