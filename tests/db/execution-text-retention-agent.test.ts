import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agentQuestionsStopFixtures, answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
const f = agentQuestionsStopFixtures(() => ({
  query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
  asUser: (user, fn) => asUser(db, user, fn),
}));

describe("agent answer retention", () => {
  it.each(["prepared", "called", "failed", "skipped"])("removes answers from %s steps while preserving ids and execution history", async state => {
    const w = await f.questionWorld(answerQuestionFixture({ allow_other: true }));
    const answer = await f.answer(w.user, w.task, "request", { choice: "PRIVATE CARD ANSWER" });
    await f.updateRow("execution_steps", answer.step_id!, { state });
    await f.updateRow("execution_runs", w.run, { state: "stopped", created_at: "2020-01-01T00:00:00Z" });
    const step = () => f.one(`select id,state,version,intent_key,policy_version,args from public.execution_steps where id=$1`, [answer.step_id]);
    const before = await step();
    const events = await f.events(w);
    await f.q(`select public.purge_expired_execution_text(now() - interval '90 days')`);
    expect(await step()).toEqual({ ...before, args: { agent_task_id: w.task, provider_request_id: "request" } });
    expect(await f.events(w)).toEqual(events);
    expect(await f.one(`select text_purged_at is not null as purged from public.execution_runs where id=$1`, [w.run])).toEqual({ purged: true });
  });

  it("retention still defers calling answers and does not unfreeze their ids or other plan fields", async () => {
    const w = await f.questionWorld();
    const answer = await f.answer(w.user, w.task);
    await f.updateRow("execution_steps", answer.step_id!, { state: "calling", lease_owner: "retention-test" });
    await f.updateRow("execution_runs", w.run, { state: "stopped", created_at: "2020-01-01T00:00:00Z" });
    await f.q(`select public.purge_expired_execution_text(now() - interval '90 days')`);
    expect(await f.one(`select text_purged_at from public.execution_runs where id=$1`, [w.run])).toEqual({ text_purged_at: null });
    expect((await f.answerSteps(w.task))[0].args).toEqual({ agent_task_id: w.task, provider_request_id: "request", answers: { choice: "A" } });
    await expect(db.transaction(async tx => {
      await tx.query(`select set_config('execution.gate','retention',true)`);
      await tx.query(`update public.execution_steps set args=args-array['answers','agent_task_id'] where id=$1`, [answer.step_id]);
    })).rejects.toThrow(/plan is frozen/);
  });
});
