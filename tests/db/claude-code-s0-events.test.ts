import { readFileSync } from "node:fs";
import path from "node:path";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agentQuestionsStopFixtures } from "./agent-questions-stop.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// OA D3a 4.5 (Q18): Claude Code adapter가 S0 stream-json에서 만든 사건(Kit 골든 `claude-code-events.json`)을 기존 사건 적용 경로
// (`apply_agent_event`)로 넣어 task 상태가 계약대로 움직이는지 본다. 서버 코드는 바꾸지 않는다.
// 접수 → 질문(input · approval, structured) → 답 → running → idle, 로그인 없음 → 접수 전 failed(sign_in_needed), 중단 → cancelled
type Golden = { session_id: string; task_id: string; sequences: Record<string, Record<string, unknown>[]> };
const golden = JSON.parse(readFileSync(path.resolve(import.meta.dirname, "../../apple/Packages/TaskforceKit/Tests/TaskforceKitTests/Fixtures/bridge-v1/claude-code-events.json"), "utf8")) as Golden;
const BAD = ["late", "conflict", "invalid_state", "not_found", "question_conflict", "step_not_calling", "duplicate"];

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

describe("Claude Code S0 events through apply_agent_event (PGlite)", () => {
  const conn: () => ConversationAgentDb = () => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) });
  const f = agentQuestionsStopFixtures(conn);

  async function world() {
    const base = await f.turnWorld();
    await f.updateRow("agent_connections", base.connection, { adapter: "agent:claude-code" });
    const r = await f.start(base.user, base.message, [], [], "write");
    expect(r.status).toBe("started");
    const session = String((await f.one(`select agent_session_id from public.agent_tasks where id=$1`, [r.agent_task_id])).agent_session_id);
    await f.updateRow("execution_steps", r.step_id!, { state: "calling", lease_owner: "claude-code-s0" });
    return { ...base, session, task: r.agent_task_id!, run: r.run_id!, step: r.step_id!, turn: r.turn_seq! };
  }

  /** 골든의 자리 id를 이 세계의 id로 바꿔 차례로 적용한다. 결과 상태를 모은다 */
  async function play(w: { user: string; session: string; task: string; turn: number }, name: string) {
    const statuses: string[] = [];
    const states: string[] = [];
    for (const event of golden.sequences[name]) {
      const text = JSON.stringify(event).replaceAll(golden.session_id, w.session).replaceAll(golden.task_id, w.task);
      const live = { ...JSON.parse(text), turn_seq: w.turn };
      const result = await f.apply(w.user, live);
      statuses.push(result.status);
      states.push(String((await f.state(w)).state));
    }
    expect(statuses.filter(status => BAD.includes(status)), `${name}: ${statuses.join(",")}`).toEqual([]);
    return states;
  }

  it("a trivial turn binds the session, is accepted, replies and ends idle", async () => {
    const w = await world();
    expect(await play(w, "trivial_turn")).toEqual(["dispatched", "accepted", "accepted", "idle"]);
    expect(await f.one(`select external_session_id from public.agent_sessions where id=$1`, [w.session])).toEqual({ external_session_id: "2c4bde0f-3c30-4976-80df-ce1603668f72" });
    const replies = await f.q(`select text from public.conversation_messages where conversation_id=$1 and role='assistant'`, [w.conversation]);
    expect(replies).toEqual([{ text: "OK" }]);
  });

  it("an ask_user defer becomes a structured input question; the answer resumes to running and the turn ends idle", async () => {
    const w = await world();
    expect(await play(w, "ask_turn")).toEqual(["dispatched", "accepted", "running", "awaiting_answer"]);
    const pending = (await f.state(w)).pending_question as { kind: string; structured: boolean; provider_request_id: string; questions: { id: string; options: { label: string }[] }[] };
    expect(pending).toMatchObject({ kind: "input", structured: true, provider_request_id: "toolu_01BHLsvBzENgVdhX2qSAFRSm" });
    expect(pending.questions.map(question => question.id)).toEqual(["color"]);
    expect(pending.questions[0].options.map(option => option.label)).toEqual(["red", "blue"]);
    const answered = await f.answer(w.user, w.task, "toolu_01BHLsvBzENgVdhX2qSAFRSm", { color: "blue" });
    expect(answered.status).toBe("answered");
    expect((await f.state(w)).state).toBe("running");
    // bridge가 답 명령을 lease해 전달했다 (D2a ack 경로는 이 시험 밖)
    await f.updateRow("execution_steps", answered.step_id!, { state: "called", lease_owner: null });
    expect((await play(w, "answer_resume")).at(-1)).toBe("idle");
  });

  it("a deferred write becomes a structured approval question", async () => {
    const w = await world();
    expect(await play(w, "approval_turn")).toEqual(["accepted", "running", "awaiting_answer"]);
    const pending = (await f.state(w)).pending_question as { kind: string; structured: boolean; questions: { id: string; text: string; options: { label: string }[] }[] };
    expect(pending).toMatchObject({ kind: "approval", structured: true });
    expect(pending.questions).toEqual([expect.objectContaining({ id: "approval", text: "Write b.txt", options: [{ label: "Allow", description: "" }, { label: "Deny", description: "" }] })]);
  });

  it("a synthetic not-logged-in turn fails before acceptance with sign_in_needed", async () => {
    const w = await world();
    expect(await play(w, "sign_in_needed")).toEqual(["failed"]);
    expect(await f.one(`select delivery_state, delivery_reason from public.conversation_messages where id=$1`, [w.message])).toEqual({ delivery_state: "not_sent", delivery_reason: "sign_in_needed" });
  });

  it("an interrupted turn ends cancelled", async () => {
    const w = await world();
    expect(await play(w, "cancelled")).toEqual(["accepted", "running", "cancelled"]);
  });
});
