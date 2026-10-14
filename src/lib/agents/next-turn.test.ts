import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { MAX_LIVE_EXTERNAL_TASKS } from "@/lib/execution/limits";

import { fakeAdmin } from "./fake-admin";
import { autoStartable, GATE_REASONS, startNextAgentMessage } from "./next-turn";

// 다음 대기 메시지 자동 시작 (OD-10) + D2a 보안 검토 P1 방어 + D1d 검토 반영 7-1 · 8-1 · 8-2.
// 규칙: 자동 시작은 머리가 `queued`일 때만. `not_sent` 머리는 이유가 gate 계열(write_gate_closed · not_connected · adapter_disabled)이고 지금 플래그가 켜져 있을 때만,
// 그 밖의 이유(spawn_failed · sign_in_needed · usage_limited · not_received · unsupported …)는 사용자의 Send again으로만 다시 시작한다 — SQL FIFO(queue_order)가 뒤 메시지를 붙잡는다.
// 실행 kill switch가 꺼져 있으면 지금 시작하려는 메시지만 not_sent/write_gate_closed로 표시하고, 이미 not_sent인 이유는 덮어쓰지 않는다.
// 8-1: 머리를 고른 뒤 그 메시지 id를 고정한다(다시 고르지 않는다). 시작은 SQL 래퍼 start_agent_turn_auto가 잠금 안에서 상태를 다시 확인한다.
// 8-2: 자동 시작에도 처리용 칩 필터(지워진 Action 제외)를 적용한다. 저장된 selected는 그대로 둔다. 진짜 not_found · already_dispatched는 대기열에서 뺀다.
const USER = "10000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const CONN = "c0000000-0000-4000-8000-000000000001";
const MSG = "a1000000-0000-4000-8000-000000000001";
const MSG_B = "a1000000-0000-4000-8000-000000000002";
const ACTION = "ac000000-0000-4000-8000-000000000001";
const ACTION2 = "ac000000-0000-4000-8000-000000000002";
const CONTEXT = "c7000000-0000-4000-8000-000000000001";
const TASK = "7a000000-0000-4000-8000-000000000001";
const started = { status: "started", action_id: TASK, run_id: TASK, agent_task_id: TASK, step_id: TASK, turn_seq: 2, created_action: false };
const ON = { AGENT_ADAPTER_CODEX_ENABLED: "true", EXECUTION_ENABLED: "true" };
const NO_EXECUTION = { AGENT_ADAPTER_CODEX_ENABLED: "true" };
const NO_ADAPTER = { EXECUTION_ENABLED: "true" };
const MIGRATION = readFileSync(path.join(process.cwd(), "supabase/migrations/20261121000000_agent_conversation_api.sql"), "utf8");

type Head = { state: string; reason?: string | null; refs?: Record<string, unknown>; selected?: Record<string, unknown> | null };
function world(head: Head | null = { state: "queued" }, options: { adapter?: string; connection?: string; actions?: string[]; rpc?: Record<string, (args: Record<string, unknown>) => unknown> } = {}) {
  return fakeAdmin({
    tables: {
      agent_sessions: [{ id: SESSION, user_id: USER, connection_id: CONN }],
      agent_connections: [{ id: CONN, user_id: USER, adapter: options.adapter ?? "agent:codex", status: options.connection ?? "active" }],
      execution_policies: [],
      actions: (options.actions ?? [ACTION, ACTION2]).map((id) => ({ id, user_id: USER })),
      conversation_messages: head
        ? [{ id: MSG, user_id: USER, refs: head.refs ?? {}, selected: head.selected === undefined ? { action_ids: [], context_ids: [] } : head.selected, delivery_state: head.state, delivery_reason: head.reason ?? null }]
        : [],
    },
    rpc: {
      next_queued_agent_message: () => (head ? MSG : null),
      start_agent_turn_auto: () => started,
      mark_agent_message_not_sent: (args) => ({ status: "not_sent", reason: args.p_reason }),
      ...options.rpc,
    },
  });
}
const run = (fake: ReturnType<typeof world>, env: Record<string, string>) => startNextAgentMessage(fake.admin, { userId: USER, sessionId: SESSION }, env);
const targets = (fake: ReturnType<typeof world>) => fake.rpcCalls().map((call) => call.target);
const writes = (fake: ReturnType<typeof world>) => fake.calls.filter((call) => call.kind !== "rpc" && call.kind !== "select");

describe("autoStartable", () => {
  it("queued와, 이유가 gate 계열인 not_sent만 자동 시작 대상이다", () => {
    expect(autoStartable("queued", null)).toBe(true);
    expect(autoStartable("queued", "session_busy")).toBe(true);
    for (const reason of ["write_gate_closed", "not_connected", "adapter_disabled"]) expect(autoStartable("not_sent", reason), reason).toBe(true);
    for (const reason of ["spawn_failed", "sign_in_needed", "usage_limited", "not_received", "unsupported", "version_unsupported", "invalid_referent", "session_closed", "not_found", "already_dispatched", null]) {
      expect(autoStartable("not_sent", reason), String(reason)).toBe(false);
    }
    for (const state of ["dispatched", "expired", "cancelled"]) expect(autoStartable(state, "write_gate_closed"), state).toBe(false);
  });

  it("TS의 gate 이유 목록이 SQL 래퍼(start_agent_turn_auto)의 목록과 글자 그대로 같다", () => {
    const body = MIGRATION.slice(MIGRATION.indexOf("create function public.start_agent_turn_auto"));
    const sql = /delivery_reason in \(([^)]*)\)/.exec(body)?.[1];
    expect(sql).toBeDefined();
    expect(sql!.split(",").map((item) => item.trim().replaceAll("'", ""))).toEqual([...GATE_REASONS]);
  });
});

describe("startNextAgentMessage", () => {
  it("머리가 queued이고 플래그가 켜져 있으면 평소처럼 시작한다: 머리는 한 번만 고르고 그 id를 래퍼에 넘긴다", async () => {
    const fake = world();
    expect(await run(fake, ON)).toEqual(started);
    expect(targets(fake)).toEqual(["next_queued_agent_message", "start_agent_turn_auto"]);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toEqual({
      p_user_id: USER, p_message_id: MSG, p_access: "read_only", p_live_limit: MAX_LIVE_EXTERNAL_TASKS, p_action_ids: [], p_context_ids: [],
    });
    expect(writes(fake)).toEqual([]);
  });

  it.each(["write_gate_closed", "not_connected", "adapter_disabled"])("머리가 not_sent/%s(gate 계열)이고 플래그가 이제 켜져 있으면 다시 시작한다", async (reason) => {
    const fake = world({ state: "not_sent", reason });
    expect(await run(fake, ON)).toEqual(started);
    expect(fake.rpcCalls("start_agent_turn_auto")).toHaveLength(1);
  });

  it.each(["spawn_failed", "sign_in_needed", "usage_limited", "not_received", "unsupported", "version_unsupported"])("머리가 not_sent/%s(실패 이유)이면 자동으로 다시 시작하지 않는다: 사용자 Send again으로만 (시작 0 · 표시 0)", async (reason) => {
    const fake = world({ state: "not_sent", reason });
    expect(await run(fake, ON)).toBeNull();
    expect(targets(fake)).toEqual(["next_queued_agent_message"]);
    expect(await run(world({ state: "not_sent", reason }), NO_EXECUTION)).toBeNull();
  });

  it("검토 반영 8-1 (경합 재현): A(queued)를 고른 뒤 A가 만료돼도 머리를 다시 고르지 않는다 — B(not_sent/spawn_failed)에 새 회차 0", async () => {
    // 첫 호출은 A, 그 뒤 호출은 모두 B를 돌려준다(예전 구현은 시작 함수가 머리를 다시 골라 B를 시작했다)
    let picks = 0;
    const fake = world({ state: "queued" }, {
      rpc: {
        next_queued_agent_message: () => (++picks === 1 ? MSG : MSG_B),
        // A는 그 사이 만료돼 잠금 안 재확인에서 skipped
        start_agent_turn_auto: (args) => (args.p_message_id === MSG ? { status: "skipped" } : started),
      },
    });
    expect(await run(fake, ON)).toBeNull();
    expect(fake.rpcCalls("next_queued_agent_message")).toHaveLength(1);
    expect(fake.rpcCalls("start_agent_turn_auto").map((call) => (call.args as { p_message_id: string }).p_message_id)).toEqual([MSG]);
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
  });

  it("검토 반영 8-2: 처리용 칩에서 지워진 Action을 뺀다 — 저장된 selected는 그대로(쓰기 0), context는 그대로", async () => {
    const selected = { action_ids: [ACTION, ACTION2], context_ids: [CONTEXT], attachments: [{ kind: "action", id: ACTION, origin: "added" }, { kind: "action", id: ACTION2, origin: "added" }] };
    const fake = world({ state: "queued", selected }, { actions: [ACTION] });
    expect(await run(fake, ON)).toEqual(started);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [ACTION], p_context_ids: [CONTEXT] });
    expect(fake.tables.conversation_messages[0].selected).toEqual(selected);
    expect(writes(fake)).toEqual([]);
    // 모두 지워졌으면 칩 없는 메시지로 시작한다
    const gone = world({ state: "queued", selected }, { actions: [] });
    await run(gone, ON);
    expect(gone.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [], p_context_ids: [CONTEXT] });
  });

  it("앞서 시작을 시도해 저장한 refs.agent_turn 칩이 있으면 selected보다 먼저 쓴다 (그것도 지워진 Action은 뺀다)", async () => {
    const fake = world({ state: "queued", refs: { agent_turn: { action_ids: [ACTION2], context_ids: [] } }, selected: { action_ids: [ACTION], context_ids: [] } }, { actions: [ACTION] });
    await run(fake, ON);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [] });
    const both = world({ state: "queued", refs: { agent_turn: { action_ids: [ACTION2], context_ids: [] } }, selected: { action_ids: [ACTION], context_ids: [] } });
    await run(both, ON);
    expect(both.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [ACTION2] });
  });

  it.each(["not_found", "already_dispatched"])("진짜 %s(칩 때문이 아니라 대상이 정말 없음)이면 대기열에서 뺀다: mark_agent_message_not_sent(같은 이유)", async (status) => {
    const fake = world({ state: "queued" }, { rpc: { start_agent_turn_auto: () => ({ status }) } });
    expect(await run(fake, ON)).toEqual({ status: "not_sent", reason: status });
    expect(fake.rpcCalls("mark_agent_message_not_sent")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: status });
  });

  it.each([["queued", { status: "queued", reason: "session_busy" }], ["expired", { status: "expired" }], ["needs_referent", { status: "needs_referent", candidates: [] }]])("그 밖의 결과(%s)는 표시 없이 그대로 돌려준다", async (_name, result) => {
    const fake = world({ state: "queued" }, { rpc: { start_agent_turn_auto: () => result } });
    expect(await run(fake, ON)).toEqual(result);
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
  });

  it("래퍼가 skipped이면 null: 표시 0", async () => {
    const fake = world({ state: "queued" }, { rpc: { start_agent_turn_auto: () => ({ status: "skipped" }) } });
    expect(await run(fake, ON)).toBeNull();
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
  });

  it("연결이 active가 아니면 시작 대신 not_sent/not_connected로 표시한다 (queued 머리). 이미 같은 이유인 머리는 다시 쓰지 않는다", async () => {
    const queued = world({ state: "queued" }, { connection: "revoked" });
    expect(await run(queued, ON)).toEqual({ status: "not_sent", reason: "not_connected" });
    expect(queued.rpcCalls("start_agent_turn_auto")).toEqual([]);
    const already = world({ state: "not_sent", reason: "not_connected" }, { connection: "revoked" });
    expect(await run(already, ON)).toBeNull();
    expect(already.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
  });

  it("쓰기 등급을 못 받는 adapter(Claude Code)는 시작 대신 not_sent/write_gate_closed로 표시한다", async () => {
    const fake = world({ state: "queued" }, { adapter: "agent:claude-code" });
    expect(await run(fake, { AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", EXECUTION_ENABLED: "true" })).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });

  it("실행 kill switch가 꺼져 있으면: queued 머리만 not_sent/write_gate_closed로 표시한다 (시작 0)", async () => {
    const fake = world({ state: "queued" });
    expect(await run(fake, NO_EXECUTION)).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(targets(fake)).toEqual(["next_queued_agent_message", "mark_agent_message_not_sent"]);
    expect(fake.rpcCalls("mark_agent_message_not_sent")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: "write_gate_closed" });
    expect(writes(fake)).toEqual([]);
  });

  it.each(["spawn_failed", "usage_limited", "write_gate_closed", "not_connected"])("꺼져 있어도 이미 not_sent/%s인 머리의 이유는 덮어쓰지 않는다 (표시 0)", async (reason) => {
    const fake = world({ state: "not_sent", reason });
    expect(await run(fake, NO_EXECUTION)).toBeNull();
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });

  it.each(["", "TRUE", "1", " false"])("EXECUTION_ENABLED가 %j이면 꺼진 것이다", async (value) => {
    const fake = world();
    expect(await run(fake, { ...NO_EXECUTION, EXECUTION_ENABLED: value })).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });

  it("adapter 플래그가 꺼져 있으면 시작도 표시도 하지 않는다 (queued 머리라도 그대로: Stop 뒤 등 플래그를 따른다)", async () => {
    const fake = world();
    expect(await run(fake, NO_ADAPTER)).toBeNull();
    expect(targets(fake)).toEqual(["next_queued_agent_message"]);
  });

  it("대기 메시지가 없거나 머리 행을 읽을 수 없으면 null (표시 0)", async () => {
    const empty = world({ state: "queued" }, { rpc: { next_queued_agent_message: () => null } });
    expect(await run(empty, NO_EXECUTION)).toBeNull();
    expect(empty.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
    const gone = world(null, { rpc: { next_queued_agent_message: () => MSG } });
    expect(await run(gone, ON)).toBeNull();
    expect(gone.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });

  it("세션이나 연결을 읽을 수 없으면 null", async () => {
    const noSession = fakeAdmin({ tables: { conversation_messages: [{ id: MSG, user_id: USER, refs: {}, selected: null, delivery_state: "queued", delivery_reason: null }] }, rpc: { next_queued_agent_message: () => MSG } });
    expect(await startNextAgentMessage(noSession.admin, { userId: USER, sessionId: SESSION }, ON)).toBeNull();
    expect(noSession.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });
});
