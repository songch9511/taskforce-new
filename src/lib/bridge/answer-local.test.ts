import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ owns: vi.fn() }));
vi.mock("@/lib/bridge/auth", () => ({ bridgeOwnsSession: mocks.owns }));

import { answerSecretLocally } from "./answer-local";

// OA F2 U3 (결과 매핑 · 재시도 · 로그) + U5 (단일 입구 가드).
const USER = "11111111-1111-4111-8111-111111111111";
const BRIDGE = "22222222-2222-4222-8222-222222222222";
const TASK = "33333333-3333-4333-8333-333333333333";
const SESSION = "55555555-5555-4555-8555-555555555555";
const STEP = "44444444-4444-4444-8444-444444444444";
const DIGEST = "a".repeat(64);
const SECRET = "S".repeat(43);
const input = { bridge_id: BRIDGE, agent_task_id: TASK, request_digest: DIGEST };
const ADAPTERS = ["agent:codex"];

type RpcOutcome = unknown | Error;
function fakeAdmin(options: { task?: unknown; rpc?: RpcOutcome[] } = {}) {
  const rpcOutcomes = [...(options.rpc ?? [{ status: "answered", step_id: STEP }])];
  const query = {
    select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(),
    throwOnError: vi.fn(async () => ({ data: "task" in options ? options.task : { agent_session_id: SESSION } })),
  };
  const from = vi.fn(() => query);
  const rpc = vi.fn<(name: string, args: unknown) => { throwOnError: () => Promise<{ data: unknown }> }>(() => ({
    throwOnError: async () => {
      const next = rpcOutcomes.length > 1 ? rpcOutcomes.shift() : rpcOutcomes[0];
      if (next instanceof Error) throw next;
      return { data: next };
    },
  }));
  return { admin: { from, rpc } as never, from, rpc, query };
}
const run = (admin: never, over: Partial<{ adapters: string[] }> = {}) => answerSecretLocally(admin, { userId: USER, bridgeId: BRIDGE, deviceSecret: SECRET, input, adapters: ADAPTERS, ...over });
const conflict = (code: string) => Object.assign(new Error("private-detail"), { code });

let logs: ReturnType<typeof vi.spyOn>[];
beforeEach(() => {
  vi.clearAllMocks();
  mocks.owns.mockResolvedValue(true);
  logs = (["log", "info", "warn", "error", "debug"] as const).map((level) => vi.spyOn(console, level).mockImplementation(() => {}));
});
afterEach(() => vi.restoreAllMocks());

describe("U2/U3 앞단: 내 작업의 세션만 읽고 bridgeOwnsSession을 거친다", () => {
  it("agent_tasks에서 agent_session_id만, user_id · id로 좁혀 읽고 bridgeOwnsSession(user, bridge, secret, session)을 부른다", async () => {
    const { admin, from, query, rpc } = fakeAdmin();
    expect(await run(admin)).toEqual({ status: "answered", step_id: STEP });
    expect(from).toHaveBeenCalledExactlyOnceWith("agent_tasks");
    expect(query.select).toHaveBeenCalledExactlyOnceWith("agent_session_id");
    expect(query.eq.mock.calls).toEqual([["user_id", USER], ["id", TASK]]);
    expect(mocks.owns).toHaveBeenCalledExactlyOnceWith(USER, BRIDGE, SECRET, SESSION);
    expect(mocks.owns.mock.invocationCallOrder[0]).toBeLessThan(rpc.mock.invocationCallOrder[0]);
  });

  it("RPC 인자는 정확히 다섯 키이고 값 자리가 없다 (answers · answered_locally 인자 0)", async () => {
    const { admin, rpc } = fakeAdmin();
    await run(admin);
    expect(rpc).toHaveBeenCalledExactlyOnceWith("answer_agent_question_locally", {
      p_user_id: USER, p_bridge_id: BRIDGE, p_agent_task_id: TASK, p_request_digest: DIGEST, p_adapters: ADAPTERS,
    });
  });

  it("내 작업이 아니면(없음) not_found이고 bridgeOwnsSession · RPC를 부르지 않는다", async () => {
    const { admin, rpc } = fakeAdmin({ task: null });
    expect(await run(admin)).toEqual({ status: "not_found" });
    expect(mocks.owns).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalled();
  });

  it("작업이 세션에 묶여 있지 않거나 모양이 틀리면 not_found", async () => {
    for (const task of [{ agent_session_id: null }, {}, { agent_session_id: "not-a-uuid" }]) {
      const { admin, rpc } = fakeAdmin({ task });
      expect(await run(admin)).toEqual({ status: "not_found" });
      expect(rpc).not.toHaveBeenCalled();
    }
    expect(mocks.owns).not.toHaveBeenCalled();
  });

  it("bridgeOwnsSession이 false면 not_found이고 RPC 0", async () => {
    mocks.owns.mockResolvedValue(false);
    const { admin, rpc } = fakeAdmin();
    expect(await run(admin)).toEqual({ status: "not_found" });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("열린 adapter가 없으면 아무것도 읽지 않고 not_found", async () => {
    const { admin, from, rpc } = fakeAdmin();
    expect(await run(admin, { adapters: [] })).toEqual({ status: "not_found" });
    expect(from).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalled();
  });
});

describe("U3 결과 매핑 (3A.3)", () => {
  it.each([
    [{ status: "answered", step_id: STEP }, { status: "answered", step_id: STEP }],
    [{ status: "duplicate", step_id: STEP }, { status: "duplicate", step_id: STEP }],
    [{ status: "stale", reason: "question_closed" }, { status: "stale", reason: "question_closed" }],
    [{ status: "stale", reason: "not_live" }, { status: "stale", reason: "not_live" }],
    [{ status: "stale", reason: "not_secret" }, { status: "stale", reason: "not_secret" }],
    [{ status: "not_found" }, { status: "not_found" }],
    [{ status: "invalid" }, { status: "invalid" }],
  ])("SQL %j → %j", async (sql, expected) => {
    const { admin } = fakeAdmin({ rpc: [sql] });
    expect(await run(admin)).toEqual(expected);
  });

  it.each([
    ["secret_requires_local", { status: "secret_requires_local" }],
    ["invalid_answer", { status: "invalid_answer" }],
    ["question_stale(래퍼가 번역하지 않은 값)", { status: "question_stale" }],
    ["모르는 이유", { status: "stale", reason: "other" }],
    ["step_id 없음", { status: "answered" }],
    ["덧붙은 키", { status: "answered", step_id: STEP, answers: { a: "b" } }],
    ["null", null],
  ])("%s → 던진다 (route가 500)", async (_name, sql) => {
    const { admin } = fakeAdmin({ rpc: [sql] });
    await expect(run(admin)).rejects.toBeDefined();
  });
});

describe("U3 경합 재시도", () => {
  it.each(["55P03", "40001", "40P01"])("%s가 세 번이면 busy이고 RPC는 3번", async (code) => {
    const { admin, rpc } = fakeAdmin({ rpc: [conflict(code)] });
    expect(await run(admin)).toEqual({ status: "busy" });
    expect(rpc).toHaveBeenCalledTimes(3);
  });

  it("두 번 물러난 뒤 성공하면 그 결과 (멱등이라 같은 호출을 다시 한다)", async () => {
    const { admin, rpc } = fakeAdmin({ rpc: [conflict("55P03"), conflict("40P01"), { status: "answered", step_id: STEP }] });
    expect(await run(admin)).toEqual({ status: "answered", step_id: STEP });
    expect(rpc).toHaveBeenCalledTimes(3);
  });

  it("그 밖의 오류는 다시 하지 않고 던진다", async () => {
    const { admin, rpc } = fakeAdmin({ rpc: [conflict("XX000")] });
    await expect(run(admin)).rejects.toMatchObject({ code: "XX000" });
    expect(rpc).toHaveBeenCalledTimes(1);
  });

  it("앞단 조회가 던져도 RPC는 부르지 않는다", async () => {
    const { admin, query, rpc } = fakeAdmin();
    query.throwOnError.mockRejectedValue(new Error("db down"));
    await expect(run(admin)).rejects.toThrow("db down");
    expect(rpc).not.toHaveBeenCalled();
  });
});

describe("U3 로그", () => {
  it("이 모듈은 어떤 경우에도 아무것도 쓰지 않는다 (id · digest · secret 0)", async () => {
    mocks.owns.mockResolvedValueOnce(false);
    await run(fakeAdmin().admin);
    mocks.owns.mockResolvedValue(true);
    await run(fakeAdmin({ rpc: [conflict("55P03")] }).admin);
    await run(fakeAdmin({ rpc: [{ status: "stale", reason: "not_live" }] }).admin);
    await expect(run(fakeAdmin({ rpc: [{ status: "invalid_answer" }] }).admin)).rejects.toBeDefined();
    for (const log of logs) expect(log).not.toHaveBeenCalled();
  });
});

describe("U5 단일 입구 가드 (정적 스캔)", () => {
  const root = path.resolve(import.meta.dirname, "..", "..");
  const production = (dir: string): string[] => readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return production(full);
    return /\.(ts|tsx)$/.test(name) && !/\.(test|fixtures?)\.(ts|tsx)$/.test(name) ? [full] : [];
  });
  const files = production(root);

  // 규칙은 "부르는 곳이 하나"다: .rpc( 의 첫 인자가 이 함수 이름인 곳만 센다 (공백 · 줄바꿈 허용). 이름을 적기만 하는 곳(주석 · 지표 등록부 src/lib/metrics/agents.ts)은 부르는 곳이 아니다
  const CALLS_LOCAL_ANSWER = /\.rpc\s*(?:<[^>]*>)?\s*\(\s*["'`]answer_agent_question_locally["'`]/;

  it("생산 코드에서 answer_agent_question_locally를 부르는 곳은 src/lib/bridge/answer-local.ts 하나다", () => {
    expect(files.length).toBeGreaterThan(100);
    const hits = files.filter((file) => CALLS_LOCAL_ANSWER.test(readFileSync(file, "utf8"))).map((file) => path.relative(root, file));
    expect(hits).toEqual(["lib/bridge/answer-local.ts"]);
  });

  it("가드 자체: .rpc( 호출은 잡고(공백 · 줄바꿈 · 따옴표 종류 무관) 이름만 적은 곳은 잡지 않는다", () => {
    const calls = [
      'admin.rpc("answer_agent_question_locally", { p_user_id: user })',
      "client\n  .rpc(\n    'answer_agent_question_locally',\n    {},\n  )",
      "admin.rpc(`answer_agent_question_locally`)",
      'admin.rpc< Result >( "answer_agent_question_locally" )',
      'await retryOnConflict(async () => admin?.rpc("answer_agent_question_locally", args))',
    ];
    for (const source of calls) expect(CALLS_LOCAL_ANSWER.test(source), source).toBe(true);
    const mentions = [
      'const sources = [sql("answer_agent_question_locally")];',
      "// 이 모듈이 answer_agent_question_locally를 부르는 단 하나의 곳이다.",
      'admin.rpc("answer_agent_question_recorded", { note: "answer_agent_question_locally" })',
      'admin.rpc("other_function", {})\nconst name = "answer_agent_question_locally"',
    ];
    for (const source of mentions) expect(CALLS_LOCAL_ANSWER.test(source), source).toBe(false);
  });

  it("answeredLocally: true를 answerAgentQuestion에 넘기는 곳이 없다 (questions.ts 'server proof' 규칙을 고정)", () => {
    const hits = files.filter((file) => /answeredLocally\s*:\s*true/.test(readFileSync(file, "utf8"))).map((file) => path.relative(root, file));
    expect(hits).toEqual([]);
  });

  it("answer-local.ts는 answerAgentQuestion · p_answers · p_answered_locally를 쓰지 않는다 (값 자리 0)", () => {
    const source = readFileSync(path.join(root, "lib/bridge/answer-local.ts"), "utf8");
    for (const forbidden of ["answerAgentQuestion", "p_answers", "p_answered_locally", "p_answer_message_id", "provider_request_id"]) expect(source, forbidden).not.toContain(forbidden);
  });
});
