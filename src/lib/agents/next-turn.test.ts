import { describe, expect, it } from "vitest";

import { fakeAdmin } from "./fake-admin";
import { startNextAgentMessage } from "./next-turn";

// D2a 보안 검토 P1 방어: 실행 kill switch(EXECUTION_ENABLED)가 꺼져 있으면 턴을 시작하지 않고 대기열 머리를 not_sent/write_gate_closed로 표시한다.
// 켜져 있으면 turns.ts startNextQueuedTurn 그대로다.
const USER = "10000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const CONN = "c0000000-0000-4000-8000-000000000001";
const MSG = "a1000000-0000-4000-8000-000000000001";
const TASK = "7a000000-0000-4000-8000-000000000001";
const started = { status: "started", action_id: TASK, run_id: TASK, agent_task_id: TASK, step_id: TASK, turn_seq: 2, created_action: false };
const ON = { AGENT_ADAPTER_CODEX_ENABLED: "true", EXECUTION_ENABLED: "true" };
const OFF = { AGENT_ADAPTER_CODEX_ENABLED: "true" };

function world(next: string | null = MSG) {
  return fakeAdmin({
    tables: {
      agent_sessions: [{ id: SESSION, user_id: USER, connection_id: CONN }],
      agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }],
      execution_policies: [],
      conversation_messages: [{ id: MSG, user_id: USER, refs: {}, selected: { action_ids: [], context_ids: [] } }],
    },
    rpc: {
      next_queued_agent_message: () => next,
      route_agent_message: () => started,
      mark_agent_message_not_sent: () => ({ status: "not_sent", reason: "write_gate_closed" }),
    },
  });
}

describe("startNextAgentMessage", () => {
  it("실행 플래그가 켜져 있으면 다음 대기 메시지를 평소처럼 시작한다 (동작 불변)", async () => {
    const fake = world();
    expect(await startNextAgentMessage(fake.admin, { userId: USER, sessionId: SESSION }, ON)).toEqual(started);
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["next_queued_agent_message", "route_agent_message"]);
  });

  it("꺼져 있으면 턴을 시작하지 않는다: 대기열 머리를 not_sent/write_gate_closed로 표시할 뿐 (route_agent_message 0 · 작업 · 단계 · 지표 0)", async () => {
    const fake = world();
    expect(await startNextAgentMessage(fake.admin, { userId: USER, sessionId: SESSION }, OFF)).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["next_queued_agent_message", "mark_agent_message_not_sent"]);
    expect(fake.rpcCalls("mark_agent_message_not_sent")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: "write_gate_closed" });
    expect(fake.calls.filter((call) => call.kind !== "rpc")).toEqual([]);
  });

  it.each(["", "TRUE", "1", " false"])("EXECUTION_ENABLED가 %j이면 꺼진 것이다", async (value) => {
    const fake = world();
    expect(await startNextAgentMessage(fake.admin, { userId: USER, sessionId: SESSION }, { ...OFF, EXECUTION_ENABLED: value })).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(fake.rpcCalls("route_agent_message")).toEqual([]);
  });

  it("대기 메시지가 없으면 꺼져 있어도 null (표시 0)", async () => {
    const fake = world(null);
    expect(await startNextAgentMessage(fake.admin, { userId: USER, sessionId: SESSION }, OFF)).toBeNull();
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
  });
});
