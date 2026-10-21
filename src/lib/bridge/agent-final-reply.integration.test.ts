import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
import { createLocalSupabase, asUser } from "../../../tests/db/local-supabase";
import { bridgeCommandFixtures } from "../../../tests/db/bridge-commands.scenarios";
import { answerQuestionFixture } from "../../../tests/db/agent-questions-stop.scenarios";

// Claude Code 첫 실사용(승인 세 번 뒤 마지막 답이 화면에 안 보였다): 서버가 그 흐름의 마지막 `message`를 대화에 쓰는가.
// Mac 쪽은 seq를 붙여 `accepted` → … → (질문 → 답 → 답 resume의 진행)×3 → `progress` → `message` → `turn_completed` 순으로 보낸다.
let db: PGlite;
const f = bridgeCommandFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

it("writes the final reply of a turn that needed three approvals, before the turn completes", async () => {
  const w = await f.world();
  await f.lease(w);
  let seq = 0;
  const send = (type: string, extra: Record<string, unknown> = {}) => f.bridgeEvent(w, f.event(w, type, { seq: ++seq, ...extra }));
  expect(await send("accepted")).toMatchObject({ status: "applied" });
  expect(await send("progress")).toMatchObject({ status: "applied" });
  for (const n of [1, 2, 3]) {
    const request = `approval-${n}`;
    expect(await send("question", { text: "Allow?", question: answerQuestionFixture({}, { kind: "approval", provider_request_id: request }) })).toMatchObject({ status: "applied", task_state: "awaiting_answer" });
    const answer = await f.answer(w.user, w.task, request, { choice: "allow" });
    expect(answer.status).toBe("answered");
    const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [answer.step_id])).id);
    expect(await f.lease({ ...w, command })).toMatchObject({ status: "leased", command: { kind: "answer", provider_request_id: request } });
    // 답 resume 프로세스의 첫 사건: 도구 결과 → progress
    expect(["applied", "ignored"]).toContain((await send("progress")).status);
  }
  expect(await send("message", { text: "Created notes.txt as asked." })).toMatchObject({ applied: true });
  expect(await send("turn_completed")).toMatchObject({ applied: true, task_state: "idle" });

  const messages = await f.q("select role, text from public.conversation_messages where conversation_id=$1 order by seq", [w.conversation]);
  // 질문 세 개(assistant 행)와 승인 줄 뒤, 마지막 행이 그 답이다: 서버는 답을 잃지 않는다
  expect(messages.filter((m) => m.text === "Created notes.txt as asked.")).toEqual([{ role: "assistant", text: "Created notes.txt as asked." }]);
  expect(messages.at(-1)).toEqual({ role: "assistant", text: "Created notes.txt as asked." });
});
