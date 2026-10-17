import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";

import { loadAgentMetrics, loadExecution, loadMetrics } from "./load";

vi.mock("server-only", () => ({}));

// 실행 지표 읽기 (U2): 숫자 열만 읽고(요청 · 초안 · receipt 없음), 실행 표가 없으면(마이그레이션 적용 전) null로 두고 지표 화면은 그대로 뜬다.

const period = { from: new Date("2026-09-21T00:00:00Z"), to: new Date("2026-09-28T00:00:00Z") };

type Call = { table: string; method: string; args: unknown[] };

/** 표마다 정한 행을 돌려주는 가짜 service role 클라이언트. 부른 메서드를 남긴다. Error를 주면 그 표 읽기가 실패한다 */
function fakeAdmin(tables: Record<string, unknown[] | Error>) {
  const calls: Call[] = [];
  const admin = {
    from(table: string) {
      const result = tables[table] ?? [];
      let head = false;
      const builder: Record<string, unknown> = {};
      for (const method of ["gte", "eq", "neq", "or", "order", "like", "in"]) {
        builder[method] = (...args: unknown[]) => {
          calls.push({ table, method, args });
          return builder;
        };
      }
      builder.select = (columns: string, options?: { head?: boolean }) => {
        calls.push({ table, method: "select", args: [columns] });
        head = options?.head ?? false;
        return builder;
      };
      builder.range = async () => (result instanceof Error ? { data: null, error: result } : { data: result, error: null });
      builder.throwOnError = async () => {
        if (result instanceof Error) throw result;
        return head ? { data: null, count: result.length } : { data: result };
      };
      return builder;
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("loadExecution", () => {
  it("숫자 열만 읽어 실행 지표를 만든다: 정산 행만, 결과 불명 단계 수, 막힘 · 승인 대기 이벤트만", async () => {
    const { admin, calls } = fakeAdmin({
      execution_runs: [
        { state: "done", created_at: "2026-09-22T00:00:00Z" },
        { state: "running", created_at: "2026-09-23T00:00:00Z" },
      ],
      execution_events: [
        { type: "hold", to_state: "credit", at: "2026-09-22T00:00:00Z" },
        { type: "run", to_state: "waiting_approval", at: "2026-09-22T00:00:00Z" },
      ],
      execution_steps: [{}, {}, {}],
      // numeric 열은 문자열로 와도 숫자로 읽는다
      execution_usage: [
        { cost_usd: "0.004", cost_status: "confirmed", billable: true, created_at: "2026-09-22T00:00:00Z" },
        { cost_usd: 0.001, cost_status: "confirmed", billable: false, created_at: "2026-09-22T00:00:00Z" },
        { cost_usd: null, cost_status: "unconfirmed", billable: true, created_at: "2026-09-22T00:00:00Z" },
      ],
      credit_ledger: [{ credits: 4, rate_version: "c3-v1", created_at: "2026-09-22T00:00:01Z" }],
      credit_rates: [{ version: "c3-v1", usd_per_credit: "0.001" }],
    });

    const metric = await loadExecution(admin, period);

    expect(metric).toMatchObject({
      runs: 2,
      byState: { done: 1, running: 1 },
      unknownOutcome: 3,
      approvalRequests: 1,
      holds: { credit: 1 },
      cost: { unconfirmed: 1 },
      charged: { credits: 4 },
    });
    expect(metric!.cost.billableUsd).toBeCloseTo(0.004, 10);
    expect(metric!.cost.platformUsd).toBeCloseTo(0.001, 10);
    expect(metric!.charged.usd).toBeCloseTo(0.004, 10);

    const selected = Object.fromEntries(calls.filter((c) => c.method === "select").map((c) => [c.table, c.args[0]]));
    expect(selected).toEqual({
      execution_runs: "state, created_at",
      execution_events: "type, to_state, at",
      execution_steps: "id",
      execution_usage: "cost_usd, cost_status, billable, created_at",
      credit_ledger: "credits, rate_version, created_at",
      credit_rates: "version, usd_per_credit",
    });
    const filters = calls.filter((c) => ["eq", "or", "gte"].includes(c.method)).map((c) => [c.table, c.method, ...c.args]);
    const since = period.from.toISOString();
    expect(filters).toEqual([
      ["execution_runs", "gte", "created_at", since],
      ["execution_events", "or", "type.eq.hold,to_state.eq.waiting_approval"],
      ["execution_events", "gte", "at", since],
      // 결과 불명은 기간과 상관없이 지금 수
      ["execution_steps", "eq", "state", "unknown_outcome"],
      ["execution_usage", "gte", "created_at", since],
      ["credit_ledger", "eq", "kind", "settle"],
      ["credit_ledger", "gte", "created_at", since],
    ]);
  });

  it("실행 표를 읽지 못하면(마이그레이션 적용 전) null, 로그에는 오류 메시지만", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = fakeAdmin({ execution_runs: new Error('relation "public.execution_runs" does not exist') });

    expect(await loadExecution(admin, period)).toBeNull();
    expect(error).toHaveBeenCalledWith("실행 지표 읽기 실패:", 'relation "public.execution_runs" does not exist');
  });
});

describe("loadMetrics: 리텐션의 활동", () => {
  it("사용자 쓰기 이벤트를 활동으로 읽되 본 것 표시(user_seen, U1 바뀜 점)는 빼고 읽는다", async () => {
    const { admin, calls } = fakeAdmin({});
    await loadMetrics(admin, period);
    // action_events는 두 번 읽는다: 기간 안의 이벤트(지표 1 · 4) · 처음부터의 사용자 쓰기(지표 3 활동)
    const writes = calls.filter((c) => c.table === "action_events" && c.method !== "select" && c.method !== "order");
    expect(writes).toEqual([
      { table: "action_events", method: "gte", args: ["created_at", period.from.toISOString()] },
      { table: "action_events", method: "eq", args: ["actor", "user"] },
      { table: "action_events", method: "neq", args: ["type", "user_seen"] },
    ]);
  });
});

// ─── OA I-oa: 에이전트 지표 카드 읽기 (L1–L3) ───

type AgentCall = { table: string; method: string; args: unknown[] };

/** 표마다 정한 행(또는 Error)을 돌려주는 가짜 service role. range는 실제로 자르고 rpc도 흉내 낸다. 부른 메서드를 남긴다 */
function agentFakeAdmin(tables: Record<string, unknown[] | Error> = {}, rpc: number | Error = 0) {
  const calls: AgentCall[] = [];
  const admin = {
    from(table: string) {
      const result = tables[table] ?? [];
      let head = false;
      let throwing = false;
      const builder: Record<string, unknown> = {};
      for (const method of ["gte", "gt", "lt", "lte", "eq", "neq", "in", "or", "like", "is", "not", "order"]) {
        builder[method] = (...args: unknown[]) => {
          calls.push({ table, method, args });
          return builder;
        };
      }
      builder.select = (columns: string, options?: { head?: boolean }) => {
        calls.push({ table, method: "select", args: [columns] });
        head = options?.head ?? false;
        return builder;
      };
      builder.range = async (from: number, to: number) => {
        calls.push({ table, method: "range", args: [from, to] });
        return Array.isArray(result) ? { data: result.slice(from, to + 1), error: null } : { data: null, error: result };
      };
      builder.throwOnError = () => {
        throwing = true;
        return builder;
      };
      builder.then = (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) => {
        if (!Array.isArray(result)) return throwing ? Promise.reject(result).then(resolve, reject) : Promise.resolve({ data: null, count: null, error: result }).then(resolve, reject);
        return Promise.resolve({ data: head ? null : result, count: result.length, error: null }).then(resolve, reject);
      };
      return builder;
    },
    async rpc(name: string, args: unknown) {
      calls.push({ table: "rpc", method: name, args: [args] });
      return rpc instanceof Error ? { data: null, error: rpc } : { data: rpc, error: null };
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

/** 글이 들어 있는 열(통째)과, JSON 열에서 꺼내도 되는 키. 계약 0.3 2항 */
const FORBIDDEN_COLUMNS = ["text", "content", "body", "args", "answers", "receipt", "pending_question", "answered_question", "rel_path", "path_key", "summary", "path", "payload", "refs", "selected"];
const ALLOWED_JSON_KEYS: Record<string, string[]> = {
  args: ["agent_task_id", "provider_request_id", "answer_message_id", "answered_locally"],
  receipt: ["reason"],
  payload: ["event_type", "status", "kind", "question_key"],
  pending_question: ["provider_request_id"],
};

/** select 목록 한 줄이 어긴 것: 금지 열을 통째로 읽거나, 허용하지 않은 JSON 키를 꺼내거나, 모르는 모양 */
function violations(select: string): string[] {
  const found: string[] = [];
  for (const column of select.split(",").map((c) => c.trim())) {
    const match = /^(?:\w+:)?(\w+)((?:->>?\w+)*)$/.exec(column);
    if (!match) {
      found.push(`모르는 모양: ${column}`);
      continue;
    }
    const [, base, path] = match;
    const keys = [...path.matchAll(/->>?(\w+)/g)].map((m) => m[1]);
    if (keys.length === 0 && FORBIDDEN_COLUMNS.includes(base)) found.push(`금지 열 통째: ${base}`);
    for (const key of keys) if (!(ALLOWED_JSON_KEYS[base] ?? []).includes(key)) found.push(`허용하지 않은 키: ${base}->${key}`);
  }
  return found;
}

const inPeriodAt = "2026-09-22T00:00:00Z";
/** 모든 읽기가 일어나도록 표마다 행을 하나씩 준다 (같은 표의 읽기마다 같은 행을 돌려받으므로 넉넉한 모양) */
const richTables = (): Record<string, unknown[]> => ({
  metric_events: [{ user_id: "u1", type: "stop_requested", at: inPeriodAt, props: { surface: "assistant" } }],
  action_events: [{ user_id: "u1", created_at: inPeriodAt }],
  execution_steps: [
    {
      id: "s1", kind: "agent_message", provider: "agent:codex", purpose: "answer:t:r", created_at: inPeriodAt,
      task_id: "t", request_id: "r", answer_message_id: null, answered_locally: null, reason: null,
    },
  ],
  execution_events: [
    { step_id: "s1", to_state: "calling", gate: "bridge_lease", at: inPeriodAt, run_id: "run1", event_type: "question", status: "applied", kind: "input", question_key: ["t", "r"] },
  ],
  conversation_messages: [{ id: "m1", delivery_state: "dispatched", delivery_reason: null, created_at: inPeriodAt }],
  bridge_commands: [{ kind: "message", outcome: "sent", created_at: inPeriodAt }],
  agent_tasks: [{ id: "t", state: "awaiting_answer", request_id: "r" }],
  execution_runs: [{ id: "run1" }],
  agent_path_leases: [{ conflict_at: inPeriodAt }],
});

describe("L1 loadAgentMetrics: 읽는 열 고정 (글 0)", () => {
  it("모든 select가 허용한 열 · JSON 키만 읽는다", async () => {
    const { admin, calls } = agentFakeAdmin(richTables(), 2);
    const agents = await loadAgentMetrics(admin, period);
    expect(Object.values(agents).every((card) => card !== null)).toBe(true);

    const selects = calls.filter((c) => c.method === "select").map((c) => [c.table, String(c.args[0])] as const);
    expect([...new Set(selects.map(([table]) => table))].sort()).toEqual(
      ["action_events", "agent_path_leases", "agent_tasks", "bridge_commands", "conversation_messages", "execution_events", "execution_runs", "execution_steps", "metric_events"],
    );
    for (const [table, select] of selects) expect(violations(select), `${table}: ${select}`).toEqual([]);
    // 단계는 args를 통째로 읽지 않고 필요한 키만 (answers는 글이다)
    expect(selects.find(([table, select]) => table === "execution_steps" && select.includes("purpose"))![1]).toBe(
      "id, kind, provider, purpose, created_at, task_id:args->>agent_task_id, request_id:args->>provider_request_id, answer_message_id:args->>answer_message_id, answered_locally:args->>answered_locally, reason:receipt->>reason",
    );
    expect(selects.find(([table]) => table === "agent_tasks")![1]).toBe("id, state, request_id:pending_question->>provider_request_id");
    expect(selects.find(([table, select]) => table === "execution_events" && select.includes("event_type"))![1]).toBe(
      "at, event_type:payload->>event_type, status:payload->>status, kind:payload->>kind, question_key:payload->question_key",
    );
  });

  it("검사 자체가 잡는다: args · receipt · pending_question 통째, 글 열, 허용하지 않은 키", () => {
    expect(violations("id, args")).toHaveLength(1);
    expect(violations("id, receipt")).toHaveLength(1);
    expect(violations("pending_question")).toHaveLength(1);
    expect(violations("id, text")).toHaveLength(1);
    expect(violations("rel_path, summary")).toHaveLength(2);
    expect(violations("answers:args->>answers")).toEqual(["허용하지 않은 키: args->answers"]);
    expect(violations("id, kind, task_id:args->>agent_task_id")).toEqual([]);
  });

  it("기간 · 30일 보존 · 종류 필터가 읽기에 걸린다", async () => {
    const wide = { from: new Date("2026-06-01T00:00:00Z"), to: new Date("2026-09-28T00:00:00Z") };
    const { admin, calls } = agentFakeAdmin(richTables(), 2);
    await loadAgentMetrics(admin, wide);
    const filters = calls.filter((c) => !["select", "order", "range"].includes(c.method)).map((c) => [c.table, c.method, ...c.args]);
    const since = wide.from.toISOString();
    const until = wide.to.toISOString();
    expect(filters).toEqual(
      expect.arrayContaining([
        ["metric_events", "gte", "at", since],
        ["metric_events", "lt", "at", until],
        ["action_events", "eq", "type", "user_created"],
        ["action_events", "eq", "rule", "assistant_agent"],
        ["execution_steps", "in", "kind", ["agent_message", "agent_cancel"]],
        ["execution_steps", "gte", "created_at", since],
        ["conversation_messages", "in", "delivery_state", ["queued", "not_sent", "dispatched", "expired", "cancelled"]],
        // 명령은 30일 뒤 지워서 기간이 길어도 최근 30일부터만 읽는다
        ["bridge_commands", "gte", "created_at", new Date(wide.to.getTime() - 30 * 86_400_000).toISOString()],
        ["execution_events", "in", "payload->>event_type", ["question", "turn_completed"]],
        ["execution_events", "eq", "to_state", "stopped"],
        ["execution_runs", "eq", "kind", "conversation"],
        ["execution_steps", "eq", "state", "unknown_outcome"],
      ]),
    );
  });
});

describe("L2 loadAgentMetrics: 카드마다 실패를 가둔다", () => {
  const named = (name: string, message: string) => Object.assign(new Error(message), { name });
  const logged = (spy: { mock: { calls: unknown[][] } }) => spy.mock.calls.map(([line]) => JSON.parse(String(line)) as { event: string; card: string; error: string });

  it("한 카드의 읽기가 던지면 그 카드만 null, 로그는 카드 이름 · 오류 이름뿐이다 (메시지 · 값 0)", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = agentFakeAdmin({ ...richTables(), bridge_commands: named("PostgrestError", "relation bridge_commands 본문 CANARY_TEXT") });
    const agents = await loadAgentMetrics(admin, period);
    expect(agents.delivery).toBeNull();
    expect(agents.usage).not.toBeNull();
    expect(agents.questions).not.toBeNull();
    expect(agents.stops).not.toBeNull();
    expect(logged(error)).toEqual([{ event: "agent_metrics_failed", card: "delivery", error: "PostgrestError" }]);
    expect(JSON.stringify(error.mock.calls)).not.toContain("CANARY_TEXT");
  });

  it("공유하는 읽기(열린 작업)가 던지면 그것을 쓰는 카드(질문 · 멈춤)가 각각 null이고 로그도 각각", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = agentFakeAdmin({ ...richTables(), agent_tasks: named("TypeError", "x") });
    const agents = await loadAgentMetrics(admin, period);
    expect(agents).toMatchObject({ questions: null, stops: null });
    expect(agents.usage).not.toBeNull();
    expect(agents.delivery).not.toBeNull();
    expect(logged(error).map((l) => l.card).sort()).toEqual(["questions", "stops"]);
  });

  it("rpc 오류는 멈춤 카드만, 지표 읽기 오류는 사용 카드만 비운다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const rpcFailed = await loadAgentMetrics(agentFakeAdmin(richTables(), named("PostgrestError", "x")).admin, period);
    expect(rpcFailed).toMatchObject({ stops: null });
    expect([rpcFailed.usage, rpcFailed.delivery, rpcFailed.questions].every((card) => card !== null)).toBe(true);
    const usageFailed = await loadAgentMetrics(agentFakeAdmin({ ...richTables(), metric_events: named("Error", "x") }).admin, period);
    expect(usageFailed.usage).toBeNull();
    expect([usageFailed.delivery, usageFailed.questions, usageFailed.stops].every((card) => card !== null)).toBe(true);
  });

  it("Error가 아닌 값이 던져져도 이름 없이 unknown으로만 남긴다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = agentFakeAdmin({ ...richTables(), metric_events: { message: "본문 CANARY_TEXT" } as unknown as Error });
    const agents = await loadAgentMetrics(admin, period);
    expect(agents.usage).toBeNull();
    expect(logged(error)).toEqual([{ event: "agent_metrics_failed", card: "usage", error: "unknown" }]);
  });

  it("loadMetrics: 에이전트 카드가 모두 실패해도 지표 1–5 · 실행은 그대로 나온다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const failing = named("PostgrestError", "x");
    const { admin } = agentFakeAdmin({ agent_tasks: failing, bridge_commands: failing, agent_path_leases: failing, action_events: [] });
    const report = await loadMetrics(admin, period);
    expect(report.agents.delivery).toBeNull();
    expect(report.agents.questions).toBeNull();
    expect(report.agents.stops).toBeNull();
    expect(report.misjudgment).toMatchObject({ aiCreated: 0 });
    expect(report.retention.cohortSize).toBe(0);
    expect(report.execution).not.toBeNull();
  });
});

describe("L3 loadAgentMetrics: 끝까지 읽는다", () => {
  it("1,000행을 넘는 표는 range로 이어서 읽는다 (1,001행 모두 센다)", async () => {
    const rows = Array.from({ length: 1001 }, () => ({ user_id: "u1", type: "stop_requested", at: inPeriodAt, props: { surface: "assistant" } }));
    const { admin, calls } = agentFakeAdmin({ metric_events: rows });
    const agents = await loadAgentMetrics(admin, period);
    expect(agents.usage!.types.find((t) => t.type === "stop_requested")!.n).toBe(1001);
    expect(calls.filter((c) => c.table === "metric_events" && c.method === "range").map((c) => c.args)).toEqual([
      [0, 999],
      [1000, 1999],
    ]);
  });

  it("연체 lease 수는 count_overdue_agent_step_leases({p_grace_seconds: 5}) 한 번, 결과 불명 단계는 head count", async () => {
    const { admin, calls } = agentFakeAdmin({ execution_steps: richTables().execution_steps }, 4);
    const agents = await loadAgentMetrics(admin, period);
    expect(calls.filter((c) => c.table === "rpc")).toEqual([{ table: "rpc", method: "count_overdue_agent_step_leases", args: [{ p_grace_seconds: 5 }] }]);
    expect(agents.stops!.now).toMatchObject({ overdueLeases: 4, unknownOutcome: 1 });
    expect(calls.find((c) => c.table === "execution_steps" && c.method === "select" && c.args[0] === "id")).toBeDefined();
  });
});
