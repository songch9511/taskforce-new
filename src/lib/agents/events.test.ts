import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { agentEventSchema, applyAgentEvent } from "./events";

const userId = "10000000-0000-4000-8000-000000000001";
const sessionId = "10000000-0000-4000-8000-000000000002";
const taskId = "10000000-0000-4000-8000-000000000003";
const runId = "10000000-0000-4000-8000-000000000004";
const conversationId = "10000000-0000-4000-8000-000000000005";
const event = { adapter: "agent:codex", session_ref: { agent_session_id: sessionId }, agent_task_id: taskId,
  event_id: "event-1", seq: 1, turn_seq: 1, type: "accepted", observed_at: "2026-10-13T12:00:00Z" };

const questionItem = { id: "choice", header: "Choose", text: "Which?", options: [{ label: "A", description: "First" }], multi_select: true, allow_other: true, secret: false };
const question = { provider_request_id: "request-1", kind: "input", structured: true, questions: [questionItem] };

describe("agentEventSchema", () => {
  it.each([
    { provider_request_id: "" }, { provider_request_id: "x".repeat(201) },
    ...([ ["id", 200], ["header", 200], ["text", 4000] ] as const).map(([key, max]) => ({ questions: [{ ...questionItem, [key]: "🙂".repeat(max + 1) }] })),
    ...([ ["label", 500], ["description", 1000] ] as const).map(([key, max]) => ({ questions: [{ ...questionItem, options: [{ label: "A", description: "D", [key]: "🙂".repeat(max + 1) }] }] })),
    { questions: [{ ...questionItem, options: Array.from({ length: 11 }, () => ({ label: "A", description: "D" })) }] },
    { questions: [questionItem, questionItem] },
  ])("rejects question bounds or duplicate IDs %#", (change) => {
    expect(agentEventSchema.safeParse({ ...event, type: "question", text: "Q", question: { ...question, ...change } }).success).toBe(false);
  });
  it("accepts question field upper bounds and ten options", () => {
    const boundedQuestion = { ...question, provider_request_id: "🙂".repeat(200), questions: [{ ...questionItem,
      id: "🙂".repeat(200), header: "🙂".repeat(200), text: "x".repeat(4000),
      options: Array.from({ length: 10 }, () => ({ label: "x".repeat(500), description: "x".repeat(1000) })),
    }] };
    expect(agentEventSchema.safeParse({ ...event, type: "question", text: "Q", question: boundedQuestion }).success).toBe(true);
  });
  it("counts full pending question JSONB metadata at the 32KB boundary", () => {
    const input = { ...event, type: "question", text: "Q", question: { ...question, questions: Array.from({ length: 4 }, (_, index) => ({ ...questionItem, id: `q${index}`, text: "가".repeat(2600) })) } };
    const pending = { ...input.question, question_key: [taskId, question.provider_request_id], asked_at: event.observed_at };
    // JSONB adds a space after every structural colon and comma (not within strings).
    const bytes = Buffer.byteLength(JSON.stringify(pending)) + 79;
    input.question.questions[0].text += "x".repeat(32768 - bytes);
    expect(agentEventSchema.safeParse(input).success).toBe(true);
    const externalOnly = { ...input, agent_task_id: undefined, external_task_id: "external" };
    expect(agentEventSchema.safeParse(externalOnly).success).toBe(true);
    input.question.questions[0].text += "x";
    expect(agentEventSchema.safeParse(input).success).toBe(false);
    expect(agentEventSchema.safeParse(externalOnly).success).toBe(false);
  });
  it("requires positive sequence", () => {
    expect(agentEventSchema.safeParse({ ...event, seq: 0 }).success).toBe(false);
  });
  it("accepts optional post-acceptance failure reason", () => {
    for (const payload of [undefined, {}, { reason: "agent_error" }]) {
      expect(agentEventSchema.safeParse({ ...event, type: "failed", payload }).success).toBe(true);
    }
  });
  it.each([1, 4])("accepts %i questions in a separate envelope object", (count) => {
    const input = { ...event, type: "question", text: "Conversation question", question: { ...question, questions: Array.from({ length: count }, (_, index) => ({ ...questionItem, id: `choice-${index}` })) } };
    expect(agentEventSchema.parse(input)).toEqual(input);
  });
  it.each([0, 5])("rejects %i questions", (count) => {
    expect(agentEventSchema.safeParse({ ...event, type: "question", text: "Q", question: { ...question, questions: Array.from({ length: count }, (_, index) => ({ ...questionItem, id: `choice-${index}` })) } }).success).toBe(false);
  });
  it.each([
    { provider_request_id: 3 }, { kind: "other" }, { structured: "true" }, { unknown: true },
    ...["id", "header", "text", "options", "multi_select", "allow_other", "secret"].map((key) => ({ questions: [{ ...questionItem, [key]: null }] })),
    { questions: [{ ...questionItem, unknown: true }] },
    { questions: [{ ...questionItem, options: [{ label: 1, description: "D" }] }] },
    { questions: [{ ...questionItem, options: [{ label: "A" }] }] },
    { questions: [{ ...questionItem, options: [{ label: "A", description: "D", unknown: true }] }] },
  ])("rejects malformed nested question %#", (change) => {
    expect(agentEventSchema.safeParse({ ...event, type: "question", text: "Q", question: { ...question, ...change } }).success).toBe(false);
  });
  it("preserves input and approval flags, empty options and full text without payload text", () => {
    for (const kind of ["input", "approval"]) {
      for (const flag of [true, false]) {
        const input = { ...event, type: "question", text: "가🙂".repeat(4000), question: { ...question, kind, structured: flag, questions: [{ ...questionItem, options: [], multi_select: flag, allow_other: flag, secret: flag }] } };
        expect(agentEventSchema.parse(input)).toEqual(input);
      }
    }
  });
  it.each([
    { question: undefined }, { text: undefined }, { agent_task_id: undefined },
    { payload: question }, { payload: { text: "leak" } }, { type: "message" },
  ])("rejects missing or misplaced question fields %#", (change) => {
    expect(agentEventSchema.safeParse({ ...event, type: "question", text: "Q", question, ...change }).success).toBe(false);
  });
  it("counts Unicode code points like SQL char_length", () => {
    expect(agentEventSchema.safeParse({ ...event, event_id: "🙂".repeat(200) }).success).toBe(true);
    expect(agentEventSchema.safeParse({ ...event, event_id: "🙂".repeat(201) }).success).toBe(false);
    expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload: { path: "🙂".repeat(600), hash: "h", summary: "ok" } }).success).toBe(true);
  });
  it.each(["accepted", "progress", "turn_completed", "cancelled", "unreachable"])("accepts %s with an empty payload", (type) => {
    expect(agentEventSchema.parse({ ...event, type }).type).toBe(type);
  });
  it.each([
    { type: "completed" }, { adapter: "codex" }, { seq: -1 }, { seq: 1.5 }, { seq: Number.MAX_SAFE_INTEGER + 1 },
    { turn_seq: 0 }, { observed_at: "yesterday" }, { event_id: "" }, { event_id: "a".repeat(201) },
    { session_ref: { agent_session_id: "bad" } }, { session_ref: { agent_session_id: sessionId, extra: true } },
    { agent_task_id: "bad" }, { external_task_id: "" }, { unknown: true }, { payload: { text: "raw body" } },
    { payload: { body: "raw body" } }, { payload: [] }, { payload: null }, { text: "not a message" },
  ])("rejects malformed or unrecognized envelope %#", (change) => {
    expect(agentEventSchema.safeParse({ ...event, ...change }).success).toBe(false);
  });
  it("allows external identity or session-only identity without inventing a task", () => {
    const withoutTask = { ...event, agent_task_id: undefined };
    expect(agentEventSchema.safeParse({ ...withoutTask, external_task_id: "turn-1" }).success).toBe(true);
    expect(agentEventSchema.safeParse({ ...withoutTask, type: "unreachable" }).success).toBe(true);
  });
  it.each(["accepted", "progress", "message", "artifact", "turn_completed", "failed", "cancelled"])("requires task identity for %s", (type) => {
    expect(agentEventSchema.safeParse({ ...event, type, agent_task_id: undefined }).success).toBe(false);
  });
  it("passes bounded message text intact and rejects oversized UTF-8", () => {
    const text = "가🙂".repeat(4000);
    expect(agentEventSchema.parse({ ...event, type: "message", text }).text).toBe(text);
    expect(agentEventSchema.safeParse({ ...event, type: "message", text: "🙂".repeat(8193) }).success).toBe(false);
    expect(agentEventSchema.safeParse({ ...event, type: "message" }).success).toBe(false);
  });
  it("validates type-specific fields and rejects artifact bodies", () => {
    expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload: { path: "src/a.ts", hash: "sha256:abc", summary: "updated" } }).success).toBe(true);
    for (const payload of [{ path: "a" }, { path: "a".repeat(1001), hash: "h", summary: "s" }, { path: "a", hash: "h".repeat(201), summary: "s" }, { path: "a", hash: "h", summary: "s", body: "raw" }, { path: "a", hash: "h", summary: "a".repeat(2001) }]) {
      expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload }).success).toBe(false);
    }
    expect(agentEventSchema.safeParse({ ...event, type: "failed", payload: { reason: "spawn_failed" } }).success).toBe(true);
    expect(agentEventSchema.safeParse({ ...event, type: "failed", payload: { reason: "unknown" } }).success).toBe(false);
    expect(agentEventSchema.safeParse({ ...event, type: "session_bound", payload: { external_session_id: "actual", workspace_ref: "work" } }).success).toBe(true);
    expect(agentEventSchema.safeParse({ ...event, type: "session_bound", payload: {} }).success).toBe(false);
    expect(agentEventSchema.safeParse({ ...event, type: "session_bound", payload: { external_session_id: "pending:not-real" } }).success).toBe(false);
    expect(agentEventSchema.safeParse({ ...event, type: "reconcile", payload: { state: "running" } }).success).toBe(true);
    expect(agentEventSchema.safeParse({ ...event, type: "reconcile", payload: { state: "unreachable" } }).success).toBe(false);
  });
  it("matches JSONB payload size exactly without counting punctuation inside strings as separators", () => {
    const payload = { path: 'src/"a,b:c".ts', hash: "h", summary: "가".repeat(1300) };
    const baseBytes = Buffer.byteLength(JSON.stringify(payload)) + 5;
    payload.summary += "x".repeat(4096 - baseBytes);
    expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload }).success).toBe(true);
    payload.summary += "x";
    expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload }).success).toBe(false);
  });
  it("limits serialized payload to 4096 UTF-8 bytes rather than characters", () => {
    const payload = { path: "a", hash: "h", summary: "" };
    const overhead = Buffer.byteLength(JSON.stringify(payload)) + 5;
    payload.summary = "가".repeat(Math.floor((4096 - overhead) / 3));
    expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload }).success).toBe(true);
    payload.summary += "가";
    expect(agentEventSchema.safeParse({ ...event, type: "artifact", payload }).success).toBe(false);
  });
});

function db(result: unknown = { status: "applied", applied: true, task_state: "accepted" }) {
  const rows: Record<string, unknown> = {
    agent_tasks: { id: taskId, run_id: runId, turn_seq: 1 },
    execution_events: { payload: { event_type: "unreachable", status: "applied", agent_task_id: taskId }, turn_seq: 1 },
    conversations: [{ id: conversationId }, { id: userId }],
  };
  const queries: Record<string, ReturnType<typeof query>> = {};
  function query(table: string) {
    const q = { select: vi.fn(), eq: vi.fn(), maybeSingle: vi.fn(), order: vi.fn(), limit: vi.fn(), throwOnError: vi.fn() };
    for (const method of ["select", "eq", "maybeSingle", "order", "limit"] as const) q[method].mockReturnValue(q);
    q.throwOnError.mockImplementation(async () => ({ data: rows[table] }));
    return q;
  }
  const from = vi.fn((table: string) => queries[table] ??= query(table));
  const rpc = vi.fn((name: string, args: Record<string, unknown>) => {
    void args;
    return ({ throwOnError: vi.fn().mockResolvedValue({ data: name === "apply_bridge_event" ? result : [{ status: "created", message_id: userId, seq: 1 }] }) });
  });
  return { admin: { rpc, from } as unknown as SupabaseClient, rpc, from, rows, queries };
}

describe("applyAgentEvent", () => {
  it("sends question separately to SQL without copying it into payload or fanout", async () => {
    const d = db({ status: "applied", applied: true, task_state: "awaiting_answer" });
    const input = { ...event, type: "question", text: "Q", question };
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: input });
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("apply_bridge_event", { p_user_id: userId, p_bridge_id: userId, p_event: input });
    expect(d.from).not.toHaveBeenCalled();
  });
  it("validates before RPC and sends the internal envelope", async () => {
    const d = db();
    await expect(applyAgentEvent(d.admin, { userId, bridgeId: userId, event })).resolves.toEqual({ status: "applied", applied: true, task_state: "accepted" });
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("apply_bridge_event", { p_user_id: userId, p_bridge_id: userId, p_event: agentEventSchema.parse(event) });
    expect(d.from).not.toHaveBeenCalled();
    await expect(applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, payload: { text: "raw" } } })).rejects.toThrow();
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });
  it.each([{ status: "unknown", applied: false }, { status: "applied", applied: false }, { status: "late", applied: true }, { status: "applied", applied: true, task_state: "bogus" }])("rejects malformed RPC result %#", async (result) => {
    await expect(applyAgentEvent(db(result).admin, { userId, bridgeId: userId, event })).rejects.toThrow();
  });
  it.each(["late", "step_not_calling", "conflict", "question_conflict", "reconcile_conflict", "not_found", "invalid_state", "ignored"])("never fans out %s", async (status) => {
    const d = db({ status, applied: false });
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type: "unreachable" } });
    expect(d.from).not.toHaveBeenCalled();
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });
  it.each(["applied", "duplicate"])("fans out persisted %s events to every bound conversation", async (status) => {
    const d = db({ status, applied: status === "applied" });
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type: "unreachable" } });
    expect(d.rpc).toHaveBeenCalledTimes(3);
    for (const id of [conversationId, userId]) expect(d.rpc).toHaveBeenCalledWith("conversation_append_agent_message", expect.objectContaining({
      p_user_id: userId, p_conversation_id: id, p_agent_task_id: taskId, p_turn_seq: 1, p_kind: "event", p_text: "Connection lost · progress unknown",
    }));
    expect(d.queries.agent_tasks.eq).toHaveBeenCalledWith("user_id", userId);
    expect(d.queries.agent_tasks.eq).toHaveBeenCalledWith("agent_session_id", sessionId);
    expect(d.queries.execution_events.eq).toHaveBeenCalledWith("user_id", userId);
    expect(d.queries.execution_events.eq).toHaveBeenCalledWith("type", "agent");
    expect(d.queries.execution_events.eq).toHaveBeenCalledWith("run_id", runId);
    expect(d.queries.execution_events.eq).toHaveBeenCalledWith("external_event_id", event.event_id);
    expect(d.queries.conversations.eq).toHaveBeenCalledWith("user_id", userId);
    expect(d.queries.conversations.eq).toHaveBeenCalledWith("agent_session_id", sessionId);
    const ids = d.rpc.mock.calls.filter(([name]) => name === "conversation_append_agent_message").map((call) => (call[1] as {p_event_id: string}).p_event_id);
    expect(new Set(ids).size).toBe(2);
    expect(ids.every((id) => id.length <= 200)).toBe(true);
  });
  it("recovers session-only duplicate from its persisted task instead of the latest turn", async () => {
    const d = db({ status: "duplicate", applied: false });
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, agent_task_id: undefined, type: "unreachable" } });
    expect(d.queries.execution_events.eq).toHaveBeenCalledWith("execution_runs.agent_session_id", sessionId);
    expect(d.queries.agent_tasks.eq).toHaveBeenCalledWith("id", taskId);
    expect(d.rpc).toHaveBeenCalledTimes(3);
  });
  it.each([undefined, 1, 2])("attributes reused taskless raw event IDs using type and turn %s", async (turnSeq) => {
    const d = db({ status: "duplicate", applied: false });
    const otherTaskId = "10000000-0000-4000-8000-000000000006";
    const otherRunId = "10000000-0000-4000-8000-000000000007";
    const tasks = [{ id: taskId, run_id: runId, turn_seq: 1 }, { id: otherTaskId, run_id: otherRunId, turn_seq: 2 }];
    const events = [
      { id: 1, run_id: userId, turn_seq: 2, payload: { event_type: "reconcile", status: "applied", agent_task_id: userId } },
      ...tasks.map((task, index) => ({ id: 3 - index, at: `2026-10-13T12:00:0${index}Z`, run_id: task.run_id, turn_seq: task.turn_seq, payload: { event_type: "unreachable", status: "applied", agent_task_id: task.id } })),
    ];
    const queries: { table: string; filters: Record<string, unknown>; ordered: boolean; limit?: number }[] = [];
    d.from.mockImplementation((table: string) => {
      const state = { table, filters: {} as Record<string, unknown>, ordered: false, limit: undefined as number | undefined };
      queries.push(state);
      const q = {
        select: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(),
        eq: vi.fn((key: string, value: unknown) => { state.filters[key] = value; return q; }),
        order: vi.fn((key: string, options: { ascending: boolean }) => { if (key === "at" && options.ascending) state.ordered = true; return q; }),
        limit: vi.fn((count: number) => { state.limit = count; return q; }),
        throwOnError: vi.fn(async () => {
          if (table === "conversations") return { data: [{ id: conversationId }] };
          const rows = (table === "agent_tasks" ? tasks : events).filter((row) => Object.entries(state.filters).every(([key, value]) => {
            if (key === "payload->>event_type") return "payload" in row && row.payload.event_type === value;
            return !(key in row) || row[key as keyof typeof row] === value;
          }));
          if (state.ordered) rows.sort((a, b) => String("at" in a ? a.at : "").localeCompare(String("at" in b ? b.at : "")));
          const matches = state.limit ? rows.slice(0, state.limit) : rows;
          if (matches.length > 1) throw new Error("multiple rows");
          return { data: matches[0] ?? null };
        }),
      };
      return q;
    });
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, agent_task_id: undefined, type: "unreachable", turn_seq: turnSeq } });
    const expected = tasks[turnSeq === 2 ? 1 : 0];
    expect(queries[0].filters["payload->>event_type"]).toBe("unreachable");
    expect(queries[0].filters.turn_seq).toBe(turnSeq);
    expect(queries[0]).toMatchObject({ ordered: true, limit: 1 });
    expect(queries[1].filters.id).toBe(expected.id);
    expect(queries[2].filters.run_id).toBe(expected.run_id);
    expect(d.rpc).toHaveBeenCalledWith("conversation_append_agent_message", expect.objectContaining({ p_agent_task_id: expected.id, p_turn_seq: expected.turn_seq }));
  });
  it("resolves external task identity within the user's session", async () => {
    const d = db();
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, agent_task_id: undefined, external_task_id: "turn-1", type: "unreachable" } });
    expect(d.queries.agent_tasks.eq).toHaveBeenCalledWith("external_task_id", "turn-1");
    expect(d.rpc).toHaveBeenCalledTimes(3);
  });
  it.each(["agent_tasks", "execution_events"])("does not fan out missing %s", async (table) => {
    const d = db({ status: "duplicate", applied: false });
    d.rows[table] = null;
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type: "unreachable" } });
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });
  it.each(["cancelled", "reconcile"])("uses fixed %s copy instead of bridge text", async (type) => {
    const d = db({ status: "applied", applied: true });
    d.rows.execution_events = { payload: { event_type: type, status: "applied", agent_task_id: taskId }, turn_seq: 1 };
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type } });
    expect(d.rpc).toHaveBeenCalledWith("conversation_append_agent_message", expect.objectContaining({
      p_text: type === "cancelled" ? "Agent stopped" : "Connection restored", p_kind: "event",
    }));
  });
  it.each([
    { event_type: "message", status: "applied", agent_task_id: taskId },
    { event_type: "unreachable", status: "late", agent_task_id: taskId },
    { event_type: "unreachable", status: "applied", agent_task_id: userId },
  ])("does not fan out changed or unapplied duplicate %#", async (payload) => {
    const d = db({ status: "duplicate", applied: false });
    d.rows.execution_events = { payload, turn_seq: 1 };
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type: "unreachable" } });
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });
  it("propagates append failure and retries with identical conversation ids", async () => {
    const d = db({ status: "applied", applied: true });
    let attempt = 0;
    d.rpc.mockImplementation((name: string) => ({ throwOnError: vi.fn().mockImplementation(async () => {
      if (name === "apply_bridge_event") return { data: { status: attempt === 0 ? "applied" : "duplicate", applied: attempt === 0 } };
      attempt += 1;
      if (attempt === 2) throw new Error("append failed");
      return { data: [{ status: "duplicate", message_id: userId, seq: 1 }] };
    }) }));
    const input = { userId, bridgeId: userId, event: { ...event, type: "unreachable", event_id: "x".repeat(200) } };
    await expect(applyAgentEvent(d.admin, input)).rejects.toThrow("append failed");
    await expect(applyAgentEvent(d.admin, input)).resolves.toEqual({ status: "duplicate", applied: false });
    const calls = d.rpc.mock.calls.filter(([name]) => name === "conversation_append_agent_message");
    expect(calls).toHaveLength(4);
    expect(calls[0][1]).toEqual(calls[2][1]);
    expect(calls[1][1]).toEqual(calls[3][1]);
  });
  it("does not fan out a duplicate from a different turn", async () => {
    const d = db({ status: "duplicate", applied: false });
    d.rows.execution_events = { payload: { event_type: "unreachable", status: "applied", agent_task_id: taskId }, turn_seq: 2 };
    await applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type: "unreachable" } });
    expect(d.rpc).toHaveBeenCalledTimes(1);
  });
  it("rejects malformed or rejected append results", async () => {
    for (const response of [null, [], [{ status: "unknown" }], [{ status: "wrong_session", message_id: null, seq: null }]]) {
      const d = db();
      d.rpc.mockImplementation((name: string) => ({ throwOnError: vi.fn().mockResolvedValue({ data: name === "apply_bridge_event" ? { status: "applied", applied: true } : response }) }));
      await expect(applyAgentEvent(d.admin, { userId, bridgeId: userId, event: { ...event, type: "unreachable" } })).rejects.toThrow();
    }
  });
  it("propagates errors without fanout", async () => {
    const d = db();
    d.rpc.mockImplementation((name: string) => ({ throwOnError: vi.fn().mockRejectedValue(new Error(name)) }));
    await expect(applyAgentEvent(d.admin, { userId, bridgeId: userId, event })).rejects.toThrow("apply_bridge_event");
  });
});

it("requires bridge identity at the event application boundary", () => {
  const input: Parameters<typeof applyAgentEvent>[1] = { userId, bridgeId: userId, event };
  expect(input.bridgeId).toBe(userId);
  // @ts-expect-error Bridge callers cannot bypass device ownership.
  const missingBridge: Parameters<typeof applyAgentEvent>[1] = { userId, event };
  void missingBridge;
});
