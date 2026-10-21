import { createHash, randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, afterEach, beforeEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { handleAnswerQuestion } from "@/lib/api/agent-conversations";
import { handleResolvePathConflict } from "@/lib/api/path-conflicts";
import { resolvePathConflict } from "@/lib/agents/path-leases";
import { reviewWithAgentsResponseSchema, returnSummaryWithAgentsResponseSchema, type ReviewDecisionItem } from "@/lib/api/contract";
import { answerAgentApproval } from "@/lib/agents/approvals";
import { answerFromRoute, loadAnswerTask } from "@/lib/agents/answers";
import { loadSessionAdapter } from "@/lib/agents/sessions";
import { clearReturnSummary, loadReturnSummary } from "@/lib/review/return-summary";
import { loadReview } from "@/lib/review/review";

import { adminOf, createCoordinatorDb, queryOf, seed } from "../coordinator/support";
import { sqlAdmin } from "../conversation/sql-admin";
import { asUser } from "../db/local-supabase";
import { answerQuestionFixture } from "../db/agent-questions-stop.scenarios";
import { ASKED, BOTH, reviewAgentInputsFixtures, SECRET } from "../db/review-agent-inputs.scenarios";

// OA D4b-s: Review · 복귀 요약에 에이전트 입력(질문 셋 · 결과 준비 · 경로 충돌)이 서버 순서로 들어온다. 실제 SQL(PGlite) 위에서 운영 TS(loadReview · loadReturnSummary · 답 handler)를 그대로 돌린다.
// 시계: db_now()는 실제 now()로 둔다(질문 시각을 DB 시각으로 자르는 값이 시험 시계에 기대지 않게). Review의 "지금"(긴급 창)은 시험이 정한다.

let db: PGlite;
let admin: SupabaseClient;
let s: ReturnType<typeof seed>;
let f: ReturnType<typeof reviewAgentInputsFixtures>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  await db.query("select set_config('app.now', '', false)");
  admin = adminOf(db);
  s = seed(db);
  f = reviewAgentInputsFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
}, 120_000);
afterAll(() => db.close());
afterEach(() => vi.unstubAllEnvs());

// These integration worlds exercise admitted beta accounts; membership-denial cases live in agent-beta tests.
beforeEach(() => vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true"));
function enrollFixture(user: string): void {
  const enrolled = process.env.AGENT_BETA_USER_IDS;
  vi.stubEnv("AGENT_BETA_USER_IDS", enrolled ? `${enrolled},${user}` : user);
}

const SEOUL = async () => "Asia/Seoul";
const NOW = new Date();
const hoursFromNow = (h: number) => new Date(NOW.getTime() + h * 3_600_000).toISOString();
const review = (user: string, agentAdapters?: readonly string[], client: SupabaseClient = admin) => { enrollFixture(user); return loadReview(client, user, NOW, { coordinatorEnabled: false, timeZone: SEOUL, agentAdapters }); };
/** 지평(horizon)을 고정한다: 같은 입력이면 커서 · 토큰까지 바이트가 같다 */
const HORIZON = NOW.toISOString().replace("Z", "000Z");
const summary = (user: string, agentAdapters?: readonly string[], client: SupabaseClient = admin) => { enrollFixture(user); return loadReturnSummary(client, user, NOW, { agentAdapters, horizon: HORIZON }); };
/** admin.rpc 호출 이름을 기록한다 */
const spy = (client: SupabaseClient) => {
  const calls: string[] = [];
  const wrapped = { ...client, rpc: (name: string, args: unknown) => (calls.push(name), (client.rpc as (n: string, a: unknown) => unknown)(name, args)) } as unknown as SupabaseClient;
  return { admin: wrapped, calls };
};
const sha16 = (text: string) => createHash("sha256").update(text).digest("hex").slice(0, 16);
const itemsOf = (response: Awaited<ReturnType<typeof review>>) => (response.decisions ?? []).flatMap((group) => group.items);

/** 다섯 종류가 한 사용자에게 모두 있는 세계. 시각은 직접 정한다 (순서 시험): confirm < 질문 < 승인(긴급) < 비밀값 질문 < 결과 준비 < 충돌 */
async function richWorld() {
  const w = await f.agentWorld();
  await f.updateRow("actions", w.action, { title: "비밀 이슈 제목" });
  const confirm = await s.action(w.user, { title: "확인 요청 일", needsConfirmation: true });
  await s.q("update public.actions set last_activity_at = $2 where id = $1", [confirm, "2026-10-10T00:00:00Z"]);
  // agent_question: w의 작업
  await f.ask(w, { asked_at: "2026-10-11T00:00:00Z" }, "req-q");
  // agent_approval (기한 2시간 → 긴급)
  const approvalRun = await f.otherRun(w);
  const approvalTask = await f.asking(w.user, approvalRun, { kind: "approval", asked_at: "2026-10-11T01:00:00Z" });
  await f.updateRow("actions", approvalRun.action, { due_at: hoursFromNow(2) });
  // agent_secret_question
  const secretRun = await f.otherRun(w);
  const secretTask = await f.asking(w.user, secretRun, { secrets: [false, true], asked_at: "2026-10-11T02:00:00Z" });
  // result_ready: 턴 하나가 끝났고 산출물이 있다
  const resultRun = await f.otherRun(w);
  const resultTask = await f.task(w.user, resultRun.run, resultRun.session, { turn_seq: 1, state: "idle" });
  await f.insertRow("agent_artifacts", { user_id: w.user, run_id: resultRun.run, agent_task_id: resultTask, turn_seq: 1, path: "비밀 파일.md", content_hash: "hash", summary: SECRET, created_at: "2026-10-11T03:00:00Z" });
  // path_conflict: w의 run이 쥔 lease를 늦게 쓴 run이 건드렸다
  const laterRun = await f.otherRun(w);
  const lease = await f.insertRow("agent_path_leases", {
    user_id: w.user, bridge_id: w.bridge, run_id: w.run, agent_session_id: w.session, workspace_ref: "/w/proj", path_key: `/w/proj/${randomUUID()}.mdx`, rel_path: "/w/proj/비밀 경로.mdx",
    source: "observed", conflict_run_id: laterRun.run, conflict_at: "2026-10-11T04:00:00Z", conflict_version: 1,
  });
  return { w, confirm, approvalRun, approvalTask, secretRun, secretTask, resultRun, laterRun, lease };
}

describe("U7 Review: 켜진 gate에서 다섯 종류가 서버 순서로 온다", () => {
  it("긴급(기한 창) → 오래 기다린 순 → 종류 순. 계약 모양이고 empty가 아니며 글이 없다", async () => {
    const r = await richWorld();
    const response = await review(r.w.user, BOTH);
    expect(reviewWithAgentsResponseSchema.parse(response)).toEqual(response);
    expect(response).toMatchObject({ complete: true, empty: false, sources: { decisions: "ok", suggestions: "ok", time_zone: "ok" } });
    expect(Object.keys(response).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources", "suggestion_batch", "suggestions"]);
    const groups = response.decisions!;
    expect(groups.map((g) => [g.kind, g.action_id, g.urgent])).toEqual([
      ["agent_approval", r.approvalRun.action, true],
      ["confirm", r.confirm, false],
      ["agent_question", r.w.action, false],
      ["agent_secret_question", r.secretRun.action, false],
      ["result_ready", r.resultRun.action, false],
      ["path_conflict", r.laterRun.action, false],
    ]);
    const byKind = Object.fromEntries(itemsOf(response).map((item) => [item.kind, item]));
    expect(byKind.agent_question).toMatchObject({ id: `agent_question:${r.w.task}`, run_id: r.w.run, step_id: null, question_id: null, version: `question:${r.w.task}:req-q`, agent: { task_id: r.w.task, session_id: r.w.session, provider_request_id: "req-q", adapter: "agent:claude-code", bridge_id: r.w.bridge } });
    expect(byKind.agent_approval).toMatchObject({ id: `agent_approval:${r.approvalTask}`, run_id: r.approvalRun.run, urgent: true, urgent_reason: "due_window" });
    expect(byKind.agent_secret_question).toMatchObject({ id: `agent_secret_question:${r.secretTask}`, run_id: r.secretRun.run });
    expect(byKind.result_ready).toMatchObject({ id: `result_ready:${r.resultRun.run}`, version: `result:${r.resultRun.run}:0:1:1`, result: { session_id: r.resultRun.session, reviewed_turn_seq: 0, last_turn_seq: 1, changed_at: "2026-10-11T03:00:00.000Z" } });
    expect(byKind.path_conflict).toMatchObject({
      id: `path_conflict:${r.lease}`, run_id: r.laterRun.run, version: `conflict:${r.lease}:1`,
      conflict: { lease_id: r.lease, conflict_version: 1, holder_action_id: r.w.action, holder_run_id: r.w.run, later_run_id: r.laterRun.run, released: false, stopped: false },
    });
    // C3 종류에는 새 키가 없다. 새 종류는 자기 ref 하나뿐이다
    expect(Object.keys(byKind.confirm)).not.toEqual(expect.arrayContaining(["agent"]));
    for (const item of Object.values(byKind) as ReviewDecisionItem[]) {
      const present = (["agent", "result", "conflict"] as const).filter((key) => key in item);
      expect(present, item.kind).toEqual(item.kind === "result_ready" ? ["result"] : item.kind === "path_conflict" ? ["conflict"] : item.kind === "confirm" ? [] : ["agent"]);
    }
    // 응답에는 글이 없다: 질문 글 · 헤더 · 파일 이름 · 경로 · 이슈 제목 · 산출물 요약
    const json = JSON.stringify(response);
    for (const text of [SECRET, "비밀 파일", "비밀 경로", "비밀 이슈 제목", "/w/proj"]) expect(json).not.toContain(text);
  });

  it("AC-24: 같은 세션 × 이슈에서 산출물 있는 턴 셋이 끝나도 결과 준비 항목은 하나이고 마지막 변경(last_turn_seq=3)을 가리킨다", async () => {
    const w = await f.agentWorld();
    await f.turns(w, [{ state: "idle", artifacts: 1 }, { state: "idle", artifacts: 2 }, { state: "idle", artifacts: 1 }]);
    const items = itemsOf(await review(w.user, BOTH)).filter((item) => item.kind === "result_ready");
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({ id: `result_ready:${w.run}`, version: `result:${w.run}:0:3:4`, result: { last_turn_seq: 3, reviewed_turn_seq: 0 } });
    // 새 턴이 진행 중이면 사라지고, 끝나면 다시 나온다 (같은 id)
    await f.task(w.user, w.run, w.session, { turn_seq: 4, state: "running" });
    expect(itemsOf(await review(w.user, BOTH))).toEqual([]);
  });

  it("adapter gate가 응답을 거른다: 연결 adapter가 꺼진 세션의 질문만 빠지고, 결과 준비 · 충돌은 남는다", async () => {
    const r = await richWorld();
    const kinds = async (adapters: readonly string[]) => itemsOf(await review(r.w.user, adapters)).map((item) => item.kind).sort();
    expect(await kinds(["agent:codex"])).toEqual(["confirm", "path_conflict", "result_ready"]); // 세계의 연결은 모두 agent:claude-code
    expect(await kinds(["agent:claude-code"])).toEqual(["agent_approval", "agent_question", "agent_secret_question", "confirm", "path_conflict", "result_ready"]);
  });

  it("환경 기본값: 대화 v2 ∧ adapter 플래그가 켜져야 읽는다. 켜지면 켜진 adapter의 세션만 본다", async () => {
    const r = await richWorld();
    const off = spy(admin);
    const kindsOff = itemsOf(await review(r.w.user, undefined, off.admin)).map((item) => item.kind);
    expect(kindsOff).toEqual(["confirm"]);
    expect(off.calls).not.toContain("review_agent_inputs");

    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
    const on = spy(admin);
    const kindsOn = itemsOf(await review(r.w.user, undefined, on.admin)).map((item) => item.kind);
    expect(on.calls.filter((name) => name === "review_agent_inputs")).toHaveLength(1);
    expect(kindsOn).toContain("agent_question");
    expect(kindsOn).toContain("path_conflict");
  });
});

describe("U4 일부를 읽지 못하면 결정 전체가 unavailable이다 (일부만 보이지 않고, 비었다고 하지 않는다)", () => {
  const failing = (rows: unknown | Error) =>
    ({
      ...admin,
      rpc: (name: string, args: unknown) =>
        name === "review_agent_inputs"
          ? { throwOnError: () => (rows instanceof Error ? Promise.reject(rows) : Promise.resolve({ data: rows })) }
          : (admin.rpc as (n: string, a: unknown) => unknown)(name, args),
    }) as unknown as SupabaseClient;

  const cases: [string, unknown][] = [
    ["함수 실패", new Error("boom")],
    ["모르는 종류", [{ kind: "from_the_future", item_ref: randomUUID(), action_id: randomUUID(), run_id: randomUUID(), version: "v", created_at: ASKED, due_at: null, detail: {} }]],
    ["ref 모양 틀림", [{ kind: "agent_question", item_ref: randomUUID(), action_id: randomUUID(), run_id: randomUUID(), version: "v", created_at: ASKED, due_at: null, detail: { task_id: "x" } }]],
  ];

  it.each(cases)("Review: %s → sources.decisions unavailable · decisions null · complete false · empty false (C2 항목도 일부만 내보내지 않는다)", async (_name, rows) => {
    const w = await f.agentWorld();
    await s.action(w.user, { title: "확인 요청", needsConfirmation: true });
    const response = await review(w.user, BOTH, failing(rows));
    expect(response).toMatchObject({ sources: { decisions: "unavailable" }, decisions: null, complete: false, empty: false });
  });

  it.each(cases)("복귀 요약: %s → sources.decisions unavailable · complete false · 결정 정보 없이 변화만", async (_name, rows) => {
    const w = await f.agentWorld();
    await s.action(w.user, { title: "확인 요청", needsConfirmation: true });
    const response = await summary(w.user, BOTH, failing(rows));
    expect(response).toMatchObject({ sources: { decisions: "unavailable" }, complete: false, empty: false });
    expect(response.items.every((item) => item.decisions.length === 0)).toBe(true);
  });
});

describe("U6 바이트 동일: gate가 꺼져 있으면 Review · 복귀 요약이 에이전트 데이터가 있어도 C3 그대로다", () => {
  async function legacyWorld() {
    const r = await richWorld();
    const row = await s.one("select title, version, last_activity_at from public.actions where id = $1", [r.confirm]);
    const created = new Date(String(row.last_activity_at)).toISOString();
    const itemId = `confirm:${r.confirm}`;
    const version = `action:${r.confirm}:${row.version}`;
    // C3가 만들던 모양을 그대로 적은 기대값 (키 순서까지)
    const group = {
      key: `${r.confirm}:confirm`, action_id: r.confirm, kind: "confirm", urgent: false, version: sha16(`${itemId}@${version}`), created_at: created,
      items: [{ id: itemId, kind: "confirm", action_id: r.confirm, run_id: null, step_id: null, question_id: null, version, urgent: false, urgent_reason: null, created_at: created }],
    };
    const line = {
      action_id: r.confirm, title: "확인 요청 일", status: "open", state: "to_do", needs_answer: true, urgent: false,
      decisions: [{ id: itemId, kind: "confirm", version, urgent: false }], changes: [],
      next: { kind: "answer", decision_kinds: ["confirm"] }, version: sha16(JSON.stringify({ c: [], d: [[itemId, version]] })),
    };
    return { r, group, line };
  }

  it("Review: gate가 닫히면(빈 배열 · 환경 꺼짐) decisions JSON이 C3 모양과 바이트 단위로 같고 review_agent_inputs를 부르지 않는다", async () => {
    const { r, group } = await legacyWorld();
    const closed = spy(admin);
    const viaOption = await review(r.w.user, [], closed.admin);
    expect(closed.calls).not.toContain("review_agent_inputs");
    expect(JSON.stringify(viaOption.decisions)).toBe(JSON.stringify([group]));
    const viaEnv = spy(admin);
    const byDefault = await review(r.w.user, undefined, viaEnv.admin);
    expect(viaEnv.calls).not.toContain("review_agent_inputs");
    expect(JSON.stringify(byDefault.decisions)).toBe(JSON.stringify([group]));
    expect(JSON.stringify(viaOption)).not.toMatch(/agent_|result_ready|path_conflict/);
  });

  it("복귀 요약: gate가 닫히면 그 Action의 줄이 C3 모양과 바이트 단위로 같고 에이전트 결정이 없다. 옛 스키마로도 그대로 읽힌다", async () => {
    const { r, line } = await legacyWorld();
    const closed = spy(admin);
    const response = await summary(r.w.user, [], closed.admin);
    expect(closed.calls).not.toContain("review_agent_inputs");
    expect(JSON.stringify(response.items.filter((item) => item.action_id === r.confirm))).toBe(JSON.stringify([line]));
    expect(JSON.stringify(response)).not.toMatch(/agent_|result_ready|path_conflict/);
    const byDefault = await summary(r.w.user);
    expect(JSON.stringify(byDefault)).toBe(JSON.stringify(response));
    // 켜면 같은 사용자의 응답이 달라진다 (닫힘이 우연히 같은 게 아니다)
    const open = await summary(r.w.user, BOTH);
    expect(JSON.stringify(open)).not.toBe(JSON.stringify(response));
  });
});

describe("U8 복귀 요약: 에이전트 결정이 줄에 실린다", () => {
  it("에이전트 결정만 있는 Action도 줄(제목 · 상태)이다. needs_answer · next 규칙, decisions[].id/version은 Review 항목과 같다", async () => {
    const r = await richWorld();
    const [body, board] = [await summary(r.w.user, BOTH), await review(r.w.user, BOTH)];
    expect(returnSummaryWithAgentsResponseSchema.parse(body)).toEqual(body);
    expect(body.sources.decisions).toBe("ok");
    const line = (action: string) => body.items.find((item) => item.action_id === action)!;
    expect(line(r.w.action)).toMatchObject({ title: "비밀 이슈 제목", needs_answer: true, next: { kind: "answer", decision_kinds: ["agent_question"] } });
    expect(line(r.approvalRun.action)).toMatchObject({ needs_answer: true, urgent: true, next: { kind: "answer", decision_kinds: ["agent_approval"] } });
    expect(line(r.secretRun.action)).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["agent_secret_question"] } });
    expect(line(r.laterRun.action)).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["path_conflict"] } });
    // 결과 준비만: 답할 것이 아니라 검토할 것
    expect(line(r.resultRun.action)).toMatchObject({ needs_answer: false, next: { kind: "review_result", decision_kinds: ["result_ready"] }, decisions: [{ kind: "result_ready" }] });
    // 줄의 결정 = Review 항목 (id · version · 종류 · 긴급)
    const reviewItems = new Map(itemsOf(board).map((item) => [item.id, item]));
    const lineItems = body.items.flatMap((item) => item.decisions);
    expect(lineItems.length).toBe(reviewItems.size);
    for (const decision of lineItems) {
      const same = reviewItems.get(decision.id)!;
      expect([decision.kind, decision.version, decision.urgent]).toEqual([same.kind, same.version, same.urgent]);
    }
    expect(JSON.stringify(body)).not.toContain(SECRET);
  });

  it("Clear 뒤에도 결정 줄은 남는다 (읽음은 결정이 아니다)", async () => {
    const r = await richWorld();
    const first = await summary(r.w.user, BOTH);
    expect(first.cursor).not.toBeNull();
    const cleared = await clearReturnSummary(admin, r.w.user, first.cursor!);
    expect(cleared.status).toBe("cleared");
    const again = await summary(r.w.user, BOTH);
    expect(again.items.flatMap((item) => item.decisions.map((d) => d.id)).sort()).toEqual(first.items.flatMap((item) => item.decisions.map((d) => d.id)).sort());
    expect(again.items.filter((item) => item.needs_answer).length).toBeGreaterThan(0);
  });
});

describe("U9 답 연결 (ONE-TF-03 서버 몫): Review 항목의 ref로 D1d 답 route를 부른다", () => {
  /** D1d의 실제 답 handler를 PGlite admin 위에서 그대로 돌린다 (realAnswerDeps와 같은 구성, 인증만 고정) */
  const answerWith = (user: string, env: Record<string, string | undefined> = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" }) =>
    async (task: string, body: unknown) => {
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
  const itemFor = async (user: string, kind: string) => itemsOf(await review(user, BOTH)).find((item) => item.kind === kind);

  it("입력 질문: Review 항목의 ref로 답하면 200 answered이고 항목이 사라진다. 같은 답을 다시 보내면 duplicate", async () => {
    const w = await f.questionWorld(answerQuestionFixture(), "agent:codex");
    const item = (await itemFor(w.user, "agent_question"))!;
    expect(item.agent).toMatchObject({ task_id: w.task, provider_request_id: "request", adapter: "agent:codex" });
    const answer = answerWith(w.user);
    const body = { provider_request_id: item.agent!.provider_request_id, answers: { choice: "A" } };
    const first = await answer(item.agent!.task_id, body);
    expect(first).toMatchObject({ status: 200, body: { status: "answered" } });
    expect(await itemFor(w.user, "agent_question")).toBeUndefined(); // 다음 읽기에서 사라진다 (pending_question이 비었다)
    expect(await answer(item.agent!.task_id, body)).toMatchObject({ status: 200, body: { status: "duplicate", step_id: first.body.step_id } });
    expect(await f.answerSteps(w.task)).toHaveLength(1);
  });

  it("질문이 교체된 뒤 옛 ref로 답하면 409 question_stale이고 답 단계는 0이다. 같은 항목 id가 새 version으로 보인다", async () => {
    const w = await f.questionWorld(answerQuestionFixture(), "agent:codex");
    const stale = (await itemFor(w.user, "agent_question"))!;
    await f.ask(w, {}, "request-2"); // 같은 작업에 새 질문 (옛 질문 교체)
    const result = await answerWith(w.user)(w.task, { provider_request_id: stale.agent!.provider_request_id, answers: { q0: "아무 값" } });
    expect(result).toMatchObject({ status: 409, body: { error: { code: "question_stale" } } });
    expect(await f.answerSteps(w.task)).toEqual([]);
    const now = (await itemFor(w.user, "agent_question"))!;
    expect([now.id, now.version]).toEqual([stale.id, `question:${w.task}:request-2`]);
    expect(now.version).not.toBe(stale.version);
  });

  it("승인: Review 항목의 ref로 allow → 예약 lease가 approved가 되고 항목이 사라진다", async () => {
    const w = await f.live();
    await f.decide(w); // 예약 lease (request_id=request)
    await f.apply(w.user, f.event(w, "question", { text: "Approval", question: { provider_request_id: "request", kind: "approval", structured: true, questions: [{ id: "approval", header: "Approval", text: "Allow?", options: [{ label: "Allow", description: "Allow" }, { label: "Deny", description: "Deny" }], multi_select: false, allow_other: false, secret: false }] } }));
    const item = (await itemFor(w.user, "agent_approval"))!;
    expect(item).toMatchObject({ id: `agent_approval:${w.task}`, agent: { task_id: w.task, provider_request_id: "request", adapter: "agent:codex" } });
    expect((await f.leases(w.run))[0]).toMatchObject({ source: "requested" });
    const result = await answerWith(w.user)(item.agent!.task_id, { provider_request_id: item.agent!.provider_request_id, answers: { approval: "allow" } });
    expect(result).toMatchObject({ status: 200, body: { status: "answered" } });
    expect((await f.leases(w.run))[0]).toMatchObject({ source: "approved", released_at: null });
    expect(await itemFor(w.user, "agent_approval")).toBeUndefined();
  });

  it("비밀값 질문은 Review에 보이되 서버로 답할 수 없다: 409 secret_requires_local, 답 단계 0, 항목은 그대로", async () => {
    const w = await f.questionWorld(answerQuestionFixture({ secret: true }), "agent:codex");
    const item = (await itemFor(w.user, "agent_secret_question"))!;
    expect(item.agent).toMatchObject({ task_id: w.task, bridge_id: w.bridge });
    const result = await answerWith(w.user)(w.task, { provider_request_id: item.agent!.provider_request_id, answers: { choice: "A" } });
    expect(result).toMatchObject({ status: 409, body: { error: { code: "secret_requires_local" } } });
    expect(await f.answerSteps(w.task)).toEqual([]);
    expect((await itemFor(w.user, "agent_secret_question"))?.version).toBe(item.version);
  });

  it("adapter gate가 닫히면 답 route도 404이고 Review에도 그 항목이 없다 (같은 판단, 같은 결과)", async () => {
    const w = await f.questionWorld(answerQuestionFixture(), "agent:codex");
    const closedEnv = { CONVERSATIONS_V2_ENABLED: "true" };
    expect((await answerWith(w.user, closedEnv)(w.task, { provider_request_id: "request", answers: { choice: "A" } })).status).toBe(404);
    expect(itemsOf(await review(w.user, [])).filter((item) => item.kind === "agent_question")).toEqual([]);
    expect(await f.answerSteps(w.task)).toEqual([]);
  });
});

describe("U10 경로 충돌 해소 (실제 SQL): Review 항목의 conflict_version으로 해소 route를 부른다", () => {
  const resolveWith = (user: string) => async (lease: string, body: unknown) => {
    enrollFixture(user);
    const response = await handleResolvePathConflict(new Request(`https://api.example.test/api/v2/path-conflicts/${lease}/resolve`, { method: "POST", body: JSON.stringify(body) }), lease, {
      enabled: () => true,
      authenticate: async () => ({ user: { id: user } }),
      resolve: (_u, input) => resolvePathConflict(admin, { userId: user, ...input }),
    });
    return { status: response.status, body: (await response.json()) as Record<string, unknown> };
  };
  const resolvedMetrics = (user: string) => s.q("select props from public.metric_events where user_id = $1 and type = 'path_conflict_resolved'", [user]);
  const conflictItem = async (user: string) => itemsOf(await review(user, BOTH)).find((item) => item.kind === "path_conflict");
  const leaseRow = (lease: string) => s.one("select conflict_run_id, conflict_at, released_at, release_reason, conflict_version from public.agent_path_leases where id = $1", [lease]);

  it("holder: 200 resolved → 충돌 열이 비고 항목이 사라지고 지표가 한 줄이다. 같은 요청을 다시 보내면 409 conflict(쓰기 0 · 지표 그대로)", async () => {
    const r = await richWorld();
    const item = (await conflictItem(r.w.user))!;
    const resolve = resolveWith(r.w.user);
    const body = { keep: "holder", conflict_version: item.conflict!.conflict_version };
    expect(await resolve(item.conflict!.lease_id, body)).toEqual({ status: 200, body: { status: "resolved" } });
    expect(await leaseRow(r.lease)).toMatchObject({ conflict_run_id: null, conflict_at: null, released_at: null });
    expect(await resolvedMetrics(r.w.user)).toEqual([{ props: { keep: "holder" } }]);
    expect(await conflictItem(r.w.user)).toBeUndefined();
    const again = await resolve(item.conflict!.lease_id, body);
    expect([again.status, (again.body.error as { code: string }).code]).toEqual([409, "conflict"]);
    expect(await resolvedMetrics(r.w.user)).toHaveLength(1);
  });

  it("later: holder의 살아 있는 lease를 conflict_resolved로 푼다. 멈춘 run은 다시 시작하지 않는다 (SQL 그대로)", async () => {
    const r = await richWorld();
    const item = (await conflictItem(r.w.user))!;
    expect((await resolveWith(r.w.user)(item.conflict!.lease_id, { keep: "later", conflict_version: item.conflict!.conflict_version })).status).toBe(200);
    expect(await leaseRow(r.lease)).toMatchObject({ conflict_run_id: null, release_reason: "conflict_resolved" });
    expect((await leaseRow(r.lease)).released_at).not.toBeNull();
    expect(await resolvedMetrics(r.w.user)).toEqual([{ props: { keep: "later" } }]);
    expect(await s.one("select state from public.execution_runs where id = $1", [r.laterRun.run])).toEqual({ state: "queued" }); // 이 route는 run 상태를 건드리지 않는다
  });

  it("해소 뒤 같은 lease에 새 충돌이 생기면 항목이 새 version으로 다시 나오고, 화면에 있던 옛 version으로 해소하면 409이다 (지표 0)", async () => {
    const r = await richWorld();
    const first = (await conflictItem(r.w.user))!;
    const resolve = resolveWith(r.w.user);
    await resolve(first.conflict!.lease_id, { keep: "holder", conflict_version: first.conflict!.conflict_version });
    await s.q("update public.agent_path_leases set conflict_run_id = $2, conflict_at = now(), conflict_version = conflict_version + 1 where id = $1", [r.lease, r.laterRun.run]);
    const second = (await conflictItem(r.w.user))!;
    expect([second.id, second.version]).toEqual([first.id, `conflict:${r.lease}:2`]);
    const metricsBefore = (await resolvedMetrics(r.w.user)).length;
    const stale = await resolve(r.lease, { keep: "later", conflict_version: first.conflict!.conflict_version });
    expect(stale.status).toBe(409);
    expect((await resolvedMetrics(r.w.user)).length).toBe(metricsBefore);
    expect(await conflictItem(r.w.user)).toBeDefined();
    expect((await resolve(r.lease, { keep: "later", conflict_version: second.conflict!.conflict_version })).status).toBe(200);
  });

  it("남의 lease · 없는 lease는 404이고 아무것도 바뀌지 않는다", async () => {
    const mine = await richWorld();
    const theirs = await richWorld();
    const before = await leaseRow(theirs.lease);
    const attempt = await resolveWith(mine.w.user)(theirs.lease, { keep: "holder", conflict_version: 1 });
    expect([attempt.status, (attempt.body.error as { code: string }).code]).toEqual([404, "not_found"]);
    expect(await leaseRow(theirs.lease)).toEqual(before);
    expect((await resolveWith(mine.w.user)(randomUUID(), { keep: "holder", conflict_version: 1 })).status).toBe(404);
    expect(await resolvedMetrics(mine.w.user)).toEqual([]);
    expect(await resolvedMetrics(theirs.w.user)).toEqual([]);
  });
});

describe("P2 개수 상한: 입력이 1,001개여도 Review · 복귀 요약이 모두 받고 완전하다 (PostgREST db-max-rows 흉내)", () => {
  // PostgREST db-max-rows는 응답 "행" 수에 걸린다. 같은 상한(1,000행)을 SQL 결과에 씌운 admin으로 운영 TS를 돌린다.
  // review_agent_inputs가 TABLE이면 1,001행이 1,000으로 잘려 일부가 빠진 채 complete가 되고, scalar jsonb(행 하나)면 영향이 없다.
  const capped = () => sqlAdmin(async (sql, params) => (await queryOf(db)(sql, params)).slice(0, 1000));

  it("경로 충돌 1,001개: 항목 1,001개 · decisions ok · complete true. 복귀 요약 줄의 결정도 1,001개", async () => {
    const w = await f.conflictWorld();
    await s.q(
      `insert into public.agent_path_leases (user_id, bridge_id, run_id, agent_session_id, workspace_ref, path_key, rel_path, source, conflict_run_id, conflict_at, conflict_version)
       select $1, $2, $3, $4, '/w/proj', '/w/proj/bulk-' || g, 'bulk-' || g, 'observed', $5, '2026-10-13T09:00:00Z', 1 from generate_series(1, 1000) g`,
      [w.user, w.bridge, w.run, w.session, w.later.run],
    );
    const client = capped();
    const board = await review(w.user, BOTH, client);
    expect(board).toMatchObject({ complete: true, empty: false, sources: { decisions: "ok" } });
    expect(itemsOf(board)).toHaveLength(1001);
    expect(new Set(itemsOf(board).map((item) => item.id)).size).toBe(1001);
    const lines = (await summary(w.user, BOTH, client)).items.filter((item) => item.action_id === w.later.action);
    expect(lines).toHaveLength(1);
    expect(lines[0].decisions).toHaveLength(1001);
    expect(lines[0]).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["path_conflict"] } });
  });
});

describe("결정적 Action id (start_agent_turn이 sha256에서 만든 id)의 복귀 요약", () => {
  it("UUID 버전 비트가 없는 id의 Action도 변화 줄이 읽힌다 (변화 원천이 통째로 unavailable이 되지 않는다)", async () => {
    const user = await s.user();
    const action = "d1b2c3d4-e5f6-0a7b-8c9d-0e1f2a3b4c5d";
    await s.q("insert into public.actions (id, user_id, title) values ($1, $2, '결정적 id 이슈')", [action, user]);
    await s.q("insert into public.action_events (user_id, action_id, type, actor, created_at) values ($1, $2, 'due_changed', 'ai', $3)", [user, action, "2026-10-12T12:00:00.000000Z"]);
    const response = await summary(user, []);
    expect(response.sources.changes).toBe("ok");
    const line = response.items.find((item) => item.action_id === action);
    expect(line).toMatchObject({ title: "결정적 id 이슈", changes: [{ source: "action_event", kind: "due_changed" }] });
    expect(returnSummaryWithAgentsResponseSchema.parse(response)).toEqual(response);
  });
});
