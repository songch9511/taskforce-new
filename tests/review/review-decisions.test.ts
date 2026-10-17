import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
// 통과 대역: pendingGroupDto가 예상 못하게 던질 때의 전파를 한 시험에서만 켠다 (평소에는 진짜 함수 그대로)
vi.mock("@/lib/review/dto", async (importOriginal) => {
  const original = await importOriginal<typeof import("@/lib/review/dto")>();
  return { ...original, pendingGroupDto: vi.fn(original.pendingGroupDto) };
});

import { reviewDecisionsResponseSchema, type ReviewDecisionGroup } from "@/lib/api/contract";
import { pendingGroupDto } from "@/lib/review/dto";
import { loadReview, loadReviewDecisions } from "@/lib/review/review";

import { adminOf, createCoordinatorDb, queryOf, seed } from "../coordinator/support";
import { sqlAdmin } from "../conversation/sql-admin";
import { asUser } from "../db/local-supabase";
import { BOTH, reviewAgentInputsFixtures, SECRET } from "../db/review-agent-inputs.scenarios";

// OA R-dec 7.2: GET /api/v2/review/decisions의 읽기(loadReviewDecisions)를 실제 SQL(PGlite) 위에서 운영 TS 그대로 돌린다.
// 같은 계산(loadReview의 결정 쪽과 바이트 동일) · 부른 것(rpc 둘뿐, from 0) · 못 읽음 · 빈 사용자 · 상한 없음 · 쓰기 0(+ loadReview는 쓴다는 대조).
// 시계: db_now()는 실제 now()로 둔다 (review-agents.test.ts와 같다). Review의 "지금"(긴급 창)은 시험이 정한다.

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
afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

const SEOUL = async () => "Asia/Seoul";
const NOW = new Date();
const hoursFromNow = (h: number) => new Date(NOW.getTime() + h * 3_600_000).toISOString();
const decisionsOnly = (user: string, agentAdapters?: readonly string[], client: SupabaseClient = admin) => loadReviewDecisions(client, user, NOW, { agentAdapters });
const full = (user: string, agentAdapters?: readonly string[], client: SupabaseClient = admin) => loadReview(client, user, NOW, { coordinatorEnabled: false, timeZone: SEOUL, agentAdapters });
/** rpc · from 호출 이름을 기록한다 */
const spy = (client: SupabaseClient) => {
  const rpcs: string[] = [];
  const tables: string[] = [];
  const wrapped = {
    ...client,
    rpc: (name: string, args: unknown) => (rpcs.push(name), (client.rpc as (n: string, a: unknown) => unknown)(name, args)),
    from: (table: string) => (tables.push(table), (client.from as (t: string) => unknown)(table)),
  } as unknown as SupabaseClient;
  return { admin: wrapped, rpcs, tables };
};
const kindsOf = (groups: ReviewDecisionGroup[] | null) => (groups ?? []).map((g) => g.kind);
const consoleErrors = () => vi.spyOn(console, "error").mockImplementation(() => {});

/** 다섯 종류가 한 사용자에게 모두 있는 세계 (review-agents.test.ts richWorld와 같은 모양). 시각은 직접 정한다: confirm < 질문 < 승인(긴급) < 비밀값 질문 < 결과 준비 < 충돌 */
async function richWorld() {
  const w = await f.agentWorld();
  await f.updateRow("actions", w.action, { title: "비밀 이슈 제목" });
  const confirm = await s.action(w.user, { title: "확인 요청 일", needsConfirmation: true });
  await s.q("update public.actions set last_activity_at = $2 where id = $1", [confirm, "2026-10-10T00:00:00Z"]);
  // C3 입력 대기 하나 더: run이 needs_input으로 끝난 열린 Action → run_input. 에이전트 gate와 무관한 C3 종류라 새 경로가 빠뜨리면 같음 시험이 빨개진다
  const inputAction = await s.action(w.user, { title: "답이 필요한 일" });
  const inputRun = await s.run(w.user, inputAction);
  await s.q("update public.execution_runs set state = 'running' where id = $1", [inputRun]);
  await s.q("update public.execution_runs set state = 'done', outcome = 'needs_input' where id = $1", [inputRun]);
  await f.ask(w, { asked_at: "2026-10-11T00:00:00Z" }, "req-q");
  const approvalRun = await f.otherRun(w);
  await f.asking(w.user, approvalRun, { kind: "approval", asked_at: "2026-10-11T01:00:00Z" });
  await f.updateRow("actions", approvalRun.action, { due_at: hoursFromNow(2) });
  const secretRun = await f.otherRun(w);
  await f.asking(w.user, secretRun, { secrets: [false, true], asked_at: "2026-10-11T02:00:00Z" });
  const resultRun = await f.otherRun(w);
  const resultTask = await f.task(w.user, resultRun.run, resultRun.session, { turn_seq: 1, state: "idle" });
  await f.insertRow("agent_artifacts", { user_id: w.user, run_id: resultRun.run, agent_task_id: resultTask, turn_seq: 1, path: "비밀 파일.md", content_hash: "hash", summary: SECRET, created_at: "2026-10-11T03:00:00Z" });
  const laterRun = await f.otherRun(w);
  await f.insertRow("agent_path_leases", {
    user_id: w.user, bridge_id: w.bridge, run_id: w.run, agent_session_id: w.session, workspace_ref: "/w/proj", path_key: `/w/proj/${randomUUID()}.mdx`, rel_path: "/w/proj/비밀 경로.mdx",
    source: "observed", conflict_run_id: laterRun.run, conflict_at: "2026-10-11T04:00:00Z", conflict_version: 1,
  });
  return { w, confirm, inputAction, approvalRun, secretRun, resultRun, laterRun };
}

describe("D1 같음: 결정만 읽기 = loadReview의 결정 쪽 (바이트 동일)", () => {
  let r: Awaited<ReturnType<typeof richWorld>>;
  beforeAll(async () => {
    r = await richWorld();
  }, 60_000);

  const ALL = ["agent_approval", "agent_question", "agent_secret_question", "confirm", "path_conflict", "result_ready", "run_input"];
  const cases: [string, readonly string[] | undefined, Record<string, string>, string[]][] = [
    ["adapter 빈 배열", [], {}, ["confirm", "run_input"]],
    ["adapter codex만", ["agent:codex"], {}, ["confirm", "path_conflict", "result_ready", "run_input"]], // 세계의 연결은 모두 agent:claude-code
    ["adapter claude-code만", ["agent:claude-code"], {}, ALL],
    ["adapter 둘", BOTH, {}, ALL],
    ["undefined + 환경 꺼짐", undefined, {}, ["confirm", "run_input"]],
    ["undefined + 환경 켜짐 (대화 v2 ∧ claude-code)", undefined, { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" }, ALL],
  ];

  it.each(cases)("%s: decisions JSON · sources.decisions가 loadReview와 같고 빈 비교가 아니다", async (_name, adapters, env, expectedKinds) => {
    for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
    // 결정만을 먼저, 그다음 loadReview (loadReview가 쓰는 것이 결정 쪽에 영향이 없다는 것도 함께 본다)
    const only = await decisionsOnly(r.w.user, adapters);
    const both = await full(r.w.user, adapters);
    expect(JSON.stringify(only.decisions)).toBe(JSON.stringify(both.decisions));
    expect(only.sources.decisions).toBe(both.sources.decisions);
    // 종류도 순서까지 같고, C3 종류(confirm · run_input)는 adapter가 꺼져 있어도 켜져 있어도 빠지지 않는다 (C3 입력 대기 동등성)
    expect(kindsOf(only.decisions)).toEqual(kindsOf(both.decisions));
    for (const c3 of ["confirm", "run_input"]) expect(kindsOf(only.decisions), c3).toContain(c3);
    const c3Json = (response: typeof only) => JSON.stringify((response.decisions ?? []).filter((g) => g.kind === "confirm" || g.kind === "run_input"));
    expect(c3Json(only)).toBe(c3Json(both));
    expect([...new Set(kindsOf(only.decisions))].sort()).toEqual(expectedKinds);
    expect(only).toMatchObject({ complete: true, empty: false, sources: { decisions: "ok" } });
  });

  it("응답은 계약 모양이고 최상위 키가 정확히 다섯이며, 서버 순서(긴급 → 오래 기다린 순 → 종류 순)와 글 없음을 지킨다. generated_at은 주입한 now다", async () => {
    const only = await decisionsOnly(r.w.user, BOTH);
    expect(reviewDecisionsResponseSchema.parse(only)).toEqual(only);
    expect(Object.keys(only).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources"]);
    expect(Object.keys(only.sources)).toEqual(["decisions"]);
    expect(only.generated_at).toBe(NOW.toISOString());
    expect(only.decisions!.map((g) => [g.kind, g.action_id, g.urgent])).toEqual([
      ["agent_approval", r.approvalRun.action, true],
      ["confirm", r.confirm, false],
      ["agent_question", r.w.action, false],
      ["agent_secret_question", r.secretRun.action, false],
      ["result_ready", r.resultRun.action, false],
      ["path_conflict", r.laterRun.action, false],
      ["run_input", r.inputAction, false],
    ]);
    const json = JSON.stringify(only);
    for (const text of [SECRET, "비밀 파일", "비밀 경로", "비밀 이슈 제목", "/w/proj"]) expect(json).not.toContain(text);
    expect(json).not.toMatch(/"(suggestions|suggestion_batch|time_zone)"/);
  });

  it("같은 입력으로 두 번 읽으면 같은 JSON이다 (읽기는 멱등이고 매번 다시 계산한다)", async () => {
    const [first, second] = [await decisionsOnly(r.w.user, BOTH), await decisionsOnly(r.w.user, BOTH)];
    expect(JSON.stringify(second)).toBe(JSON.stringify(first));
  });
});

describe("D2 부른 것: 결정 원천 rpc뿐이다 (제안 생산 · 노출 · 시간대 읽기 · 표 읽기 0)", () => {
  it("adapter가 있으면 coordinator_pending_inputs + review_agent_inputs, from() 0", async () => {
    const r = await richWorld();
    const t = spy(admin);
    await decisionsOnly(r.w.user, BOTH, t.admin);
    expect(t.rpcs.sort()).toEqual(["coordinator_pending_inputs", "review_agent_inputs"]);
    expect(t.tables).toEqual([]);
  });

  it("adapter가 비면(빈 배열 · 환경 꺼짐) coordinator_pending_inputs 하나뿐이다 — review_agent_inputs를 부르지 않는다", async () => {
    const r = await richWorld();
    const viaOption = spy(admin);
    await decisionsOnly(r.w.user, [], viaOption.admin);
    expect(viaOption.rpcs).toEqual(["coordinator_pending_inputs"]);
    expect(viaOption.tables).toEqual([]);
    const viaEnv = spy(admin);
    await decisionsOnly(r.w.user, undefined, viaEnv.admin);
    expect(viaEnv.rpcs).toEqual(["coordinator_pending_inputs"]);
    expect(viaEnv.tables).toEqual([]);
  });

  it("대조: 같은 세계에서 loadReview는 제안 생산 · 노출 rpc와 시간대 읽기(from)를 부른다 (이 spy가 그것을 볼 수 있다)", async () => {
    const r = await richWorld();
    const t = spy(admin);
    await loadReview(t.admin, r.w.user, NOW, { coordinatorEnabled: false, agentAdapters: BOTH });
    expect(t.rpcs).toEqual(expect.arrayContaining(["suggestions_produce", "suggestions_expose", "coordinator_pending_inputs", "review_agent_inputs"]));
    expect(t.tables).toContain("report_preferences");
  });
});

describe("D3 못 읽음: 결정 원천을 못 읽으면 비었다고 하지 않는다 (loadReview의 결정 쪽과 같은 값)", () => {
  const failingInputs = (rows: unknown | Error) =>
    ({
      ...admin,
      rpc: (name: string, args: unknown) =>
        name === "review_agent_inputs"
          ? { throwOnError: () => (rows instanceof Error ? Promise.reject(rows) : Promise.resolve({ data: rows })) }
          : (admin.rpc as (n: string, a: unknown) => unknown)(name, args),
    }) as unknown as SupabaseClient;
  const failingPending = (error: unknown) =>
    ({
      ...admin,
      rpc: (name: string, args: unknown) => {
        if (name === "coordinator_pending_inputs") throw error;
        return (admin.rpc as (n: string, a: unknown) => unknown)(name, args);
      },
    }) as unknown as SupabaseClient;

  class NamedFailure extends Error {
    name = "NamedFailure";
  }
  const cases: [string, () => SupabaseClient, string][] = [
    ["review_agent_inputs 실패", () => failingInputs(new NamedFailure("boom 카나리 글")), "NamedFailure"],
    ["모르는 종류", () => failingInputs([{ kind: "from_the_future", item_ref: randomUUID(), action_id: randomUUID(), run_id: randomUUID(), version: "v", created_at: "2026-01-02T03:04:05Z", due_at: null, detail: {} }]), "ZodError"],
    ["ref 모양 틀림", () => failingInputs([{ kind: "agent_question", item_ref: randomUUID(), action_id: randomUUID(), run_id: randomUUID(), version: "v", created_at: "2026-01-02T03:04:05Z", due_at: null, detail: { task_id: "x" } }]), "ZodError"],
    ["coordinator_pending_inputs 실패", () => failingPending(new NamedFailure("permission denied 카나리 글")), "NamedFailure"],
    ["Error가 아닌 값이 던져짐", () => failingPending("카나리 문자열"), "unknown"],
  ];

  it.each(cases)("%s → decisions null · sources.decisions unavailable · complete false · empty false. 로그는 사건 이름 + 오류 이름뿐", async (_name, makeClient, errorName) => {
    const w = await f.agentWorld();
    await s.action(w.user, { title: "확인 요청", needsConfirmation: true }); // 읽을 수 있는 C2 항목이 있어도 일부만 내보내지 않는다
    const client = makeClient();
    const log = consoleErrors();
    const only = await decisionsOnly(w.user, BOTH, client);
    expect(only).toEqual({ generated_at: NOW.toISOString(), complete: false, empty: false, sources: { decisions: "unavailable" }, decisions: null });
    expect(reviewDecisionsResponseSchema.parse(only)).toEqual(only);
    expect(log).toHaveBeenCalledTimes(1);
    expect(JSON.parse(String(log.mock.calls[0][0]))).toEqual({ event: "review_decisions_pending_failed", error: errorName });
    expect(JSON.stringify(log.mock.calls)).not.toContain("카나리");
    log.mockClear();
    // loadReview의 결정 쪽과 같은 값이다 (같은 실패를 같은 방식으로 알린다)
    const both = await full(w.user, BOTH, client);
    expect(both.decisions).toBeNull();
    expect(both.sources.decisions).toBe(only.sources.decisions);
  });

  it("성공하면 로그가 없다 (읽기에 글 · 오류 이름을 남길 일이 없다)", async () => {
    const r = await richWorld();
    const log = consoleErrors();
    await decisionsOnly(r.w.user, BOTH);
    expect(log).not.toHaveBeenCalled();
  });

  it("예상 못한 오류(pendingGroupDto가 던짐)는 unavailable로 바꾸지 않고 그대로 올라간다 — 처리 함수가 500으로 바꾼다 (loadReview와 같다)", async () => {
    const w = await f.agentWorld();
    await s.action(w.user, { needsConfirmation: true });
    vi.mocked(pendingGroupDto).mockImplementationOnce(() => {
      throw new Error("dto 카나리");
    });
    await expect(decisionsOnly(w.user, BOTH)).rejects.toThrow("dto 카나리");
    vi.mocked(pendingGroupDto).mockImplementationOnce(() => {
      throw new Error("dto 카나리");
    });
    await expect(full(w.user, BOTH)).rejects.toThrow("dto 카나리");
  });
});

describe("D4 빈 사용자", () => {
  it("아무 결정도 없으면 complete true · empty true · decisions []", async () => {
    const user = await s.user();
    for (const adapters of [BOTH, [], undefined]) {
      expect(await decisionsOnly(user, adapters)).toEqual({ generated_at: NOW.toISOString(), complete: true, empty: true, sources: { decisions: "ok" }, decisions: [] });
    }
  });

  it("남의 결정은 보이지 않는다 (service role이어도 user_id로 좁힌다)", async () => {
    const [alice, bob] = [await s.user(), await s.user()];
    await s.action(bob, { needsConfirmation: true });
    const theirs = await richWorld();
    expect(await decisionsOnly(alice, BOTH)).toMatchObject({ decisions: [], empty: true });
    expect((await decisionsOnly(bob, BOTH)).decisions).toHaveLength(1);
    expect(JSON.stringify(await decisionsOnly(alice, BOTH))).not.toContain(theirs.w.user);
  });
});

describe("D5 개수 상한이 없다 (PostgREST db-max-rows 흉내)", () => {
  it("경로 충돌 1,001개: 항목 1,001개 · sources.decisions ok · complete true, loadReview와 같다", async () => {
    const w = await f.conflictWorld();
    await s.q(
      `insert into public.agent_path_leases (user_id, bridge_id, run_id, agent_session_id, workspace_ref, path_key, rel_path, source, conflict_run_id, conflict_at, conflict_version)
       select $1, $2, $3, $4, '/w/proj', '/w/proj/bulk-' || g, 'bulk-' || g, 'observed', $5, '2026-10-13T09:00:00Z', 1 from generate_series(1, 1000) g`,
      [w.user, w.bridge, w.run, w.session, w.later.run],
    );
    const capped = sqlAdmin(async (sql, params) => (await queryOf(db)(sql, params)).slice(0, 1000));
    const only = await decisionsOnly(w.user, BOTH, capped);
    expect(only).toMatchObject({ complete: true, empty: false, sources: { decisions: "ok" } });
    const items = only.decisions!.flatMap((g) => g.items);
    expect(items).toHaveLength(1001);
    expect(new Set(items.map((item) => item.id)).size).toBe(1001);
    expect(JSON.stringify(only.decisions)).toBe(JSON.stringify((await full(w.user, BOTH, capped)).decisions));
  });
});

// ─── D6 쓰기 0 ───────────────────────────────────────────

type Row = Record<string, unknown>;
/** 제안이 생길 세계: 생산 후보 둘(due_window · run_failed), snooze가 끝난 제안, 하루 묶음에 들어갈 비긴급 제안 둘, 증거 있는 만료 후보 하나 + 결정 대기 항목들 */
async function suggestionWorld() {
  const r = await richWorld();
  const user = r.w.user;
  // 생산 후보: 기한이 10시간 뒤인 열린 Action → due_window(긴급)
  await s.action(user, { title: "곧 마감", dueAt: hoursFromNow(10) });
  // 생산 후보: 가장 최근 run이 failed인 열린 Action → run_failed(긴급)
  const failedAction = await s.action(user, { title: "실패한 일" });
  await s.q("update public.execution_runs set state = 'failed' where id = $1", [await s.run(user, failedAction)]);
  // 이미 있는 비긴급 제안 셋: 주제(run)가 살아 있어 만료되지 않는다. 둘은 열린 채 batch_day 없음, 하나는 snooze가 이미 끝났다
  const plainAction = await s.action(user, { title: "다시 검토할 일" });
  const plainRun = await s.run(user, plainAction);
  const plain: string[] = [];
  for (let i = 0; i < 3; i++) {
    plain.push(
      await s.id(
        `insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key, created_at)
         values ($1, 'source_revised_run', $2, $3, $4, $5, $6, now() + make_interval(secs => $7)) returning id`,
        [user, plainAction, plainRun, `run:${plainRun}:${i}`, `r${i}`, `source_revised_run:run:${plainRun}:${i}:${randomUUID()}`, i],
      ),
    );
  }
  await s.q("update public.suggestions set state = 'snoozed', snooze_until = $2 where id = $1", [plain[2], hoursFromNow(-1)]);
  // 증거 있는 만료 후보: 닫힌 Action의 열린 due_window 제안 → expose가 expired로 닫는다
  const closed = await s.action(user, { title: "이미 끝난 일", status: "done" });
  const stale = await s.id(
    `insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key, urgent) values ($1, 'due_window', $2, $3, '1', $4, true) returning id`,
    [user, closed, `action:${closed}`, `due_window:action:${closed}:1`],
  );
  return { ...r, user, plain, stale };
}

/** public의 모든 표: 행 수 + 내용 digest. update만 하는 쓰기(shown_at · state)도 digest가 달라진다 */
async function tableDigests(): Promise<Record<string, string>> {
  const names = (await s.q(`select table_name from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by 1`)).map((row) => String(row.table_name));
  const out: Record<string, string> = {};
  for (const name of names) {
    const row = await s.one(`select count(*)::int as n, coalesce(md5(string_agg(x::text, '|' order by x::text)), '') as h from public.${name} x`);
    out[name] = `${row.n}:${row.h}`;
  }
  return out;
}
const suggestionRows = async (user: string): Promise<Row[]> =>
  (await s.q(`select * from public.suggestions where user_id = $1 order by id`, [user])).map((row) => JSON.parse(JSON.stringify(row)) as Row);
const changedColumns = (before: Row[], after: Row[]) => {
  const byId = new Map(before.map((row) => [row.id, row]));
  const changed = new Set<string>();
  for (const row of after) {
    const old = byId.get(row.id);
    if (!old) continue;
    for (const key of Object.keys(row)) if (JSON.stringify(row[key]) !== JSON.stringify(old[key])) changed.add(key);
  }
  return [...changed].sort();
};

describe("D6 쓰기 0: 결정만 읽으면 어떤 표도 바뀌지 않는다 (loadReview는 바꾼다는 대조)", () => {
  it("제안이 생길 세계에서 결정만 읽은 전후: public 모든 표의 행 수 · 내용 digest와 suggestions 전 열이 같다", async () => {
    const w = await suggestionWorld();
    const [tablesBefore, rowsBefore] = [await tableDigests(), await suggestionRows(w.user)];
    expect(rowsBefore).toHaveLength(4); // 시드한 제안 넷 (읽기 전에는 생산도 노출도 없다)
    for (const adapters of [BOTH, [], undefined]) {
      const only = await decisionsOnly(w.user, adapters);
      expect(only.sources.decisions).toBe("ok");
    }
    expect(await tableDigests()).toEqual(tablesBefore);
    expect(await suggestionRows(w.user)).toEqual(rowsBefore);
  }, 60_000);

  it("대조: 같은 세계에서 loadReview는 새 제안 · shown_at · batch_day · state · version을 바꾼다 (이 시험이 변화를 볼 수 있다)", async () => {
    const w = await suggestionWorld();
    const [tablesBefore, rowsBefore] = [await tableDigests(), await suggestionRows(w.user)];
    await decisionsOnly(w.user, BOTH);
    expect(await tableDigests()).toEqual(tablesBefore); // 결정만은 그대로
    const review = await full(w.user, BOTH);
    const rowsAfter = await suggestionRows(w.user);
    const tablesAfter = await tableDigests();

    // 생산: due_window · run_failed가 새로 생겼다
    const known = new Set(rowsBefore.map((row) => row.id));
    const added = rowsAfter.filter((row) => !known.has(row.id));
    expect(added.map((row) => row.kind)).toEqual(expect.arrayContaining(["due_window", "run_failed"]));
    expect(rowsAfter).toHaveLength(rowsBefore.length + added.length);
    // 노출: shown_at · batch_day가 새로 찍혔고, snooze가 끝난 제안은 다시 열렸고(version + 1), 증거 있는 제안은 expired가 됐다
    const byId = (rows: Row[], id: string) => rows.find((row) => row.id === id)!;
    expect(rowsBefore.filter((row) => row.shown_at !== null)).toHaveLength(0);
    expect(rowsAfter.filter((row) => row.shown_at !== null).length).toBeGreaterThan(0);
    expect(rowsBefore.filter((row) => row.batch_day !== null)).toHaveLength(0);
    expect(rowsAfter.filter((row) => row.batch_day !== null).length).toBeGreaterThan(0);
    expect(byId(rowsAfter, w.plain[2])).toMatchObject({ state: "open", snooze_until: null, version: 2 });
    expect(byId(rowsAfter, w.stale)).toMatchObject({ state: "expired", stale_evidence: "action_closed", version: 2 });
    expect(changedColumns(rowsBefore, rowsAfter)).toEqual(expect.arrayContaining(["batch_day", "decided_at", "shown_at", "snooze_until", "stale_evidence", "state", "version"]));
    expect(review.suggestions!.length).toBeGreaterThan(0);
    // 어떤 표가 바뀌었나: suggestions 하나뿐이다 (Action · run · Claim은 건드리지 않는다)
    const changedTables = Object.keys(tablesAfter).filter((name) => tablesAfter[name] !== tablesBefore[name]);
    expect(changedTables).toEqual(["suggestions"]);
  }, 60_000);

  it("시간대가 없어도 · 제안이 하나도 없어도 결정만 읽기는 같은 결정을 낸다 (제안 쪽 사정이 결정 응답에 새지 않는다)", async () => {
    const w = await suggestionWorld();
    const only = await decisionsOnly(w.user, BOTH);
    const bareUser = await s.user();
    expect(only.decisions!.length).toBeGreaterThan(0);
    expect(await decisionsOnly(bareUser, BOTH)).toMatchObject({ decisions: [], complete: true, empty: true });
  });
});
