import { describe, expect, it } from "vitest";

import { fakeAdmin } from "./fake-admin";
import { autoStartable, startNextAgentMessage } from "./next-turn";

// 다음 대기 메시지 자동 시작 (OD-10) + D2a 보안 검토 P1 방어 + D1d 검토 반영 7-1.
// 규칙: 자동 시작은 머리가 `queued`일 때만. `not_sent` 머리는 이유가 gate 계열(write_gate_closed · not_connected · adapter_disabled)이고 지금 플래그가 켜져 있을 때만,
// 그 밖의 이유(spawn_failed · sign_in_needed · usage_limited · not_received · unsupported …)는 사용자의 Send again으로만 다시 시작한다 — SQL FIFO(queue_order)가 뒤 메시지를 붙잡는다.
// 실행 kill switch가 꺼져 있으면 지금 시작하려는 메시지만 not_sent/write_gate_closed로 표시하고, 이미 not_sent인 이유는 덮어쓰지 않는다.
const USER = "10000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const CONN = "c0000000-0000-4000-8000-000000000001";
const MSG = "a1000000-0000-4000-8000-000000000001";
const TASK = "7a000000-0000-4000-8000-000000000001";
const started = { status: "started", action_id: TASK, run_id: TASK, agent_task_id: TASK, step_id: TASK, turn_seq: 2, created_action: false };
const ON = { AGENT_ADAPTER_CODEX_ENABLED: "true", EXECUTION_ENABLED: "true" };
const NO_EXECUTION = { AGENT_ADAPTER_CODEX_ENABLED: "true" };
const NO_ADAPTER = { EXECUTION_ENABLED: "true" };

function world(head: { state: string; reason?: string | null } | null = { state: "queued" }, next: string | null = MSG) {
  return fakeAdmin({
    tables: {
      agent_sessions: [{ id: SESSION, user_id: USER, connection_id: CONN }],
      agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }],
      execution_policies: [],
      conversation_messages: head ? [{ id: MSG, user_id: USER, refs: {}, selected: { action_ids: [], context_ids: [] }, delivery_state: head.state, delivery_reason: head.reason ?? null }] : [],
    },
    rpc: {
      next_queued_agent_message: () => next,
      route_agent_message: () => started,
      mark_agent_message_not_sent: () => ({ status: "not_sent", reason: "write_gate_closed" }),
    },
  });
}
const run = (fake: ReturnType<typeof world>, env: Record<string, string>) => startNextAgentMessage(fake.admin, { userId: USER, sessionId: SESSION }, env);
const targets = (fake: ReturnType<typeof world>) => fake.rpcCalls().map((call) => call.target);

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
});

describe("startNextAgentMessage", () => {
  it("머리가 queued이고 플래그가 켜져 있으면 평소처럼 시작한다 (동작 불변)", async () => {
    const fake = world();
    expect(await run(fake, ON)).toEqual(started);
    expect(targets(fake)).toEqual(["next_queued_agent_message", "next_queued_agent_message", "route_agent_message"]);
  });

  it.each(["write_gate_closed", "not_connected", "adapter_disabled"])("머리가 not_sent/%s(gate 계열)이고 플래그가 이제 켜져 있으면 다시 시작한다", async (reason) => {
    const fake = world({ state: "not_sent", reason });
    expect(await run(fake, ON)).toEqual(started);
    expect(fake.rpcCalls("route_agent_message")).toHaveLength(1);
  });

  it.each(["spawn_failed", "sign_in_needed", "usage_limited", "not_received", "unsupported", "version_unsupported"])("머리가 not_sent/%s(실패 이유)이면 자동으로 다시 시작하지 않는다: 사용자 Send again으로만 (route_agent_message 0 · 표시 0)", async (reason) => {
    const fake = world({ state: "not_sent", reason });
    expect(await run(fake, ON)).toBeNull();
    expect(targets(fake)).toEqual(["next_queued_agent_message"]);
    expect(await run(world({ state: "not_sent", reason }), NO_EXECUTION)).toBeNull();
  });

  it("실행 kill switch가 꺼져 있으면: queued 머리만 not_sent/write_gate_closed로 표시한다 (route_agent_message 0)", async () => {
    const fake = world({ state: "queued" });
    expect(await run(fake, NO_EXECUTION)).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(targets(fake)).toEqual(["next_queued_agent_message", "mark_agent_message_not_sent"]);
    expect(fake.rpcCalls("mark_agent_message_not_sent")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: "write_gate_closed" });
    expect(fake.calls.filter((call) => call.kind !== "rpc" && call.kind !== "select")).toEqual([]);
  });

  it.each(["spawn_failed", "usage_limited", "write_gate_closed", "not_connected"])("꺼져 있어도 이미 not_sent/%s인 머리의 이유는 덮어쓰지 않는다 (표시 0)", async (reason) => {
    const fake = world({ state: "not_sent", reason });
    expect(await run(fake, NO_EXECUTION)).toBeNull();
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
    expect(fake.rpcCalls("route_agent_message")).toEqual([]);
  });

  it.each(["", "TRUE", "1", " false"])("EXECUTION_ENABLED가 %j이면 꺼진 것이다", async (value) => {
    const fake = world();
    expect(await run(fake, { ...NO_EXECUTION, EXECUTION_ENABLED: value })).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(fake.rpcCalls("route_agent_message")).toEqual([]);
  });

  it("adapter 플래그가 꺼져 있으면 시작도 표시도 하지 않는다 (queued 머리라도 그대로: Stop 뒤 등 플래그를 따른다)", async () => {
    const fake = world();
    expect(await run(fake, NO_ADAPTER)).toBeNull();
    expect(targets(fake)).toEqual(["next_queued_agent_message"]);
  });

  it("대기 메시지가 없거나 머리 행을 읽을 수 없으면 null (표시 0)", async () => {
    const empty = world({ state: "queued" }, null);
    expect(await run(empty, NO_EXECUTION)).toBeNull();
    expect(empty.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
    const gone = world(null);
    expect(await run(gone, ON)).toBeNull();
    expect(gone.rpcCalls("route_agent_message")).toEqual([]);
  });
});
