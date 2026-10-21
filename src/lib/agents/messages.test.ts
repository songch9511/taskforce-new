import { createHash } from "node:crypto";

import { afterEach, describe, expect, it, vi } from "vitest";

import { agentConversationMessageSchema, agentDeliverySchema } from "@/lib/api/contract";

import { fakeAdmin } from "./fake-admin";
import {
  agentMessageExists,
  deliverAgentMessages,
  deterministicActionId,
  expireAgentMessages,
  loadAgentDeliveries,
  loadAgentDeliveriesByIds,
  loadAgentMessageOutcome,
  postAgentUserMessage,
  recordContextAttached,
  requeueAgentMessages,
  setAgentMessageReferent,
  startAgentMessage,
} from "./messages";

const USER = "10000000-0000-4000-8000-000000000001";
const OTHER = "20000000-0000-4000-8000-000000000002";
const CONV = "c1000000-0000-4000-8000-000000000001";
const CONN = "c0000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const MSG = "a1000000-0000-4000-8000-000000000001";
const MSG2 = "a1000000-0000-4000-8000-000000000002";
const ACTION = "ac000000-0000-4000-8000-000000000001";
const ACTION2 = "ac000000-0000-4000-8000-000000000002";
const CONTEXT = "c7000000-0000-4000-8000-000000000001";
const TASK = "7a000000-0000-4000-8000-000000000001";
const STEP = "57000000-0000-4000-8000-000000000001";
const RUN = "20000000-0000-4000-8000-0000000000aa";
const NOW = new Date("2026-10-14T12:00:00.000Z");
// 전달 만료 시각이 아직 안 지난 값. 실제 시계가 흘러도 시험이 변하지 않게 먼 미래로 고정한다
const FUTURE = "2099-01-01T00:00:00.000Z";
// 실행 kill switch(EXECUTION_ENABLED)가 켜진 환경. 꺼진 환경은 아래 OFF (D2a 보안 검토 P1 방어)
const CODEX = { AGENT_BETA_USER_IDS: USER, CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true", EXECUTION_ENABLED: "true" };
const OFF = { AGENT_BETA_USER_IDS: USER, CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" };
const started = { status: "started", action_id: ACTION, run_id: RUN, agent_task_id: TASK, step_id: STEP, turn_seq: 1, created_action: true };

const messageRow = (extra: Record<string, unknown> = {}) => ({
  id: MSG, user_id: USER, conversation_id: CONV, seq: 1, role: "user", client_message_id: "c1c1c1c1-0000-4000-8000-000000000001", text: "이어서 해 줘", refs: {}, selected: { action_ids: [], context_ids: [], attachments: [] },
  intent: null, created_at: "2026-10-14T11:00:00Z", reply_to: null, content: null, delivery_state: "queued", delivery_reason: null, delivery_expires_at: FUTURE, ...extra,
});
type Tables = Record<string, Record<string, unknown>[]>;
function world(extra: Partial<Tables> = {}) {
  const tables: Tables = {
    conversations: [{ id: CONV, user_id: USER, target_kind: "agent", agent_connection_id: CONN, agent_session_id: SESSION }],
    agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }],
    execution_policies: [],
    conversation_messages: [messageRow()],
    agent_tasks: [],
    execution_steps: [],
    execution_runs: [],
    actions: [],
    context_members: [],
    ...extra,
  };
  return tables;
}
const rpcs = (overrides: Record<string, (args: Record<string, unknown>) => unknown> = {}) => ({
  start_agent_turn_auto: () => started,
  next_queued_agent_message: () => null,
  ...overrides,
});

describe("postAgentUserMessage: conversation_post_message를 부른다 (대상 agent의 사용자 메시지 저장)", () => {
  it("SQL 인자와 결과 매핑 (reply_id는 쓰지 않는다)", async () => {
    const fake = fakeAdmin({ rpc: { conversation_post_message: () => ({ status: "created", message_id: MSG, seq: 3, reply_id: null }) } });
    const selected = { action_ids: [], context_ids: [], attachments: [] };
    expect(await postAgentUserMessage(fake.admin, { userId: USER, conversationId: CONV, clientMessageId: MSG2, text: "글", selected })).toEqual({ status: "created", messageId: MSG, seq: 3 });
    expect(fake.rpcCalls("conversation_post_message")[0].args).toEqual({
      p_user_id: USER, p_conversation_id: CONV, p_client_message_id: MSG2, p_text: "글", p_selected: selected, p_lease_seconds: 75,
    });
  });

  it.each(["created", "exists", "mismatch", "refs_mismatch", "not_found"])("%s를 그대로 돌려준다", async (status) => {
    const fake = fakeAdmin({ rpc: { conversation_post_message: () => ({ status, message_id: status === "not_found" ? null : MSG, seq: status === "not_found" ? null : 1, reply_id: null }) } });
    expect((await postAgentUserMessage(fake.admin, { userId: USER, conversationId: CONV, clientMessageId: MSG2, text: "글", selected: {} })).status).toBe(status);
  });

  it("Taskforce 모델의 처리 상태(answered · in_progress · retry · stale)는 대상 agent에서 나올 수 없다: 던진다", async () => {
    for (const status of ["answered", "in_progress", "retry", "stale", "other"]) {
      const fake = fakeAdmin({ rpc: { conversation_post_message: () => ({ status, message_id: MSG, seq: 1, reply_id: null }) } });
      await expect(postAgentUserMessage(fake.admin, { userId: USER, conversationId: CONV, clientMessageId: MSG2, text: "글", selected: {} })).rejects.toThrow();
    }
  });
});

describe("agentMessageExists", () => {
  it("이 대화(내 것)에 같은 client_message_id의 사용자 메시지가 있는가", async () => {
    const fake = fakeAdmin({ tables: world() });
    const clientId = "c1c1c1c1-0000-4000-8000-000000000001";
    expect(await agentMessageExists(fake.admin, USER, CONV, clientId)).toBe(true);
    expect(await agentMessageExists(fake.admin, USER, CONV, MSG2)).toBe(false);
    expect(await agentMessageExists(fake.admin, OTHER, CONV, clientId)).toBe(false);
  });
});

describe("recordContextAttached (OD-17): 칩마다 한 줄, props에는 종류 · 출처 · sent · 대상뿐", () => {
  it("한 번의 insert로 쓴다. 글 · id는 담지 않는다", async () => {
    const fake = fakeAdmin();
    await recordContextAttached(fake.admin, USER, "agent", [
      { kind: "action", origin: "added", sent: true },
      { kind: "context", origin: "auto", sent: false },
    ]);
    const inserts = fake.calls.filter((call) => call.kind === "insert");
    expect(inserts).toHaveLength(1);
    expect(inserts[0].target).toBe("metric_events");
    expect(inserts[0].args).toEqual([
      { user_id: USER, type: "context_attached", props: { kind: "action", origin: "added", sent: true, target_kind: "agent" } },
      { user_id: USER, type: "context_attached", props: { kind: "context", origin: "auto", sent: false, target_kind: "agent" } },
    ]);
  });

  it("칩이 없으면 쓰지 않는다", async () => {
    const fake = fakeAdmin();
    await recordContextAttached(fake.admin, USER, "taskforce", []);
    expect(fake.calls).toEqual([]);
  });
});

describe("expireAgentMessages (R11, OD-18): 1,000이면 다시, 최대 10회", () => {
  const counter = (values: number[]) => {
    let call = 0;
    return fakeAdmin({ rpc: { conversation_expire_agent_messages: () => values[Math.min(call++, values.length - 1)] } });
  };

  it("0이면 한 번만 부른다", async () => {
    const fake = counter([0]);
    expect(await expireAgentMessages(fake.admin, NOW)).toEqual({ expired: 0, rounds: 1 });
    expect(fake.rpcCalls("conversation_expire_agent_messages")[0].args).toEqual({ p_now: NOW.toISOString() });
  });

  it("2,500행은 1,000 · 1,000 · 500으로 세 번 돈다", async () => {
    const fake = counter([1000, 1000, 500]);
    expect(await expireAgentMessages(fake.admin, NOW)).toEqual({ expired: 2500, rounds: 3 });
    expect(fake.rpcCalls()).toHaveLength(3);
  });

  it("계속 1,000이면 10회에서 멈춘다 (한 번의 cron이 끝없이 돌지 않는다)", async () => {
    const fake = counter([1000]);
    expect(await expireAgentMessages(fake.admin, NOW)).toEqual({ expired: 10_000, rounds: 10 });
    expect(fake.rpcCalls()).toHaveLength(10);
  });

  it("정확히 1,000이고 다음이 0이면 두 번", async () => {
    const fake = counter([1000, 0]);
    expect(await expireAgentMessages(fake.admin, NOW)).toEqual({ expired: 1000, rounds: 2 });
  });

  it("SQL 오류와 정수가 아닌 결과는 던진다", async () => {
    const failing = fakeAdmin({ rpc: { conversation_expire_agent_messages: () => { throw new Error("db"); } } });
    await expect(expireAgentMessages(failing.admin, NOW)).rejects.toThrow("db");
    await expect(expireAgentMessages(counter([-1]).admin, NOW)).rejects.toThrow();
    await expect(expireAgentMessages(fakeAdmin({ rpc: { conversation_expire_agent_messages: () => "x" } }).admin, NOW)).rejects.toThrow();
  });
});

describe("검토 반영 9-2: 롤백된 경합(40001 · 40P01 · 55P03)은 SQL 호출을 두 번까지 다시 한다", () => {
  const conflict = (code: string) => Object.assign(new Error("conflict"), { code });
  const flaky = (name: string, result: unknown, code: string) => {
    let calls = 0;
    return { [name]: () => { if (++calls < 3) throw conflict(code); return result; } };
  };

  it.each(["40001", "40P01", "55P03"])("requeue_agent_messages · set_agent_message_referent · conversation_post_message가 %s로 두 번 롤백돼도 세 번째에 성공한다", async (code) => {
    const requeue = fakeAdmin({ rpc: flaky("requeue_agent_messages", { status: "ok", messages: [] }, code) });
    expect(await requeueAgentMessages(requeue.admin, { userId: USER, conversationId: CONV })).toEqual({ status: "ok", messages: [] });
    expect(requeue.rpcCalls("requeue_agent_messages")).toHaveLength(3);
    const referent = fakeAdmin({ tables: world(), rpc: flaky("set_agent_message_referent", { status: "selected" }, code) });
    expect(await setAgentMessageReferent(referent.admin, { userId: USER, conversationId: CONV, messageId: MSG, actionId: ACTION })).toBe("selected");
    expect(referent.rpcCalls("set_agent_message_referent")).toHaveLength(3);
    const post = fakeAdmin({ rpc: flaky("conversation_post_message", { status: "created", message_id: MSG, seq: 1, reply_id: null }, code) });
    expect(await postAgentUserMessage(post.admin, { userId: USER, conversationId: CONV, clientMessageId: MSG2, text: "글", selected: {} })).toEqual({ status: "created", messageId: MSG, seq: 1 });
    expect(post.rpcCalls("conversation_post_message")).toHaveLength(3);
  });

  it("세 번 모두 경합이면 던지고, 다른 오류는 한 번만 부른다", async () => {
    const stuck = fakeAdmin({ rpc: { requeue_agent_messages: () => { throw conflict("40P01"); } } });
    await expect(requeueAgentMessages(stuck.admin, { userId: USER, conversationId: CONV })).rejects.toMatchObject({ code: "40P01" });
    expect(stuck.rpcCalls("requeue_agent_messages")).toHaveLength(3);
    const other = fakeAdmin({ rpc: { requeue_agent_messages: () => { throw conflict("XX000"); } } });
    await expect(requeueAgentMessages(other.admin, { userId: USER, conversationId: CONV })).rejects.toMatchObject({ code: "XX000" });
    expect(other.rpcCalls("requeue_agent_messages")).toHaveLength(1);
  });
});

describe("requeueAgentMessages", () => {
  it("SQL 인자 · 결과 매핑", async () => {
    const result = { status: "ok", messages: [{ message_id: MSG, result: "requeued" }, { message_id: MSG2, result: "skipped", reason: "not_eligible" }] };
    const fake = fakeAdmin({ rpc: { requeue_agent_messages: () => result } });
    expect(await requeueAgentMessages(fake.admin, { userId: USER, conversationId: CONV, messageIds: [MSG, MSG2] })).toEqual(result);
    expect(fake.rpcCalls("requeue_agent_messages")[0].args).toEqual({ p_user_id: USER, p_conversation_id: CONV, p_message_ids: [MSG, MSG2] });
    const all = fakeAdmin({ rpc: { requeue_agent_messages: () => ({ status: "wrong_target", messages: [] }) } });
    expect(await requeueAgentMessages(all.admin, { userId: USER, conversationId: CONV })).toEqual({ status: "wrong_target", messages: [] });
    expect(all.rpcCalls()[0].args).toMatchObject({ p_message_ids: null });
  });

  it("모르는 결과는 던진다", async () => {
    await expect(requeueAgentMessages(fakeAdmin({ rpc: { requeue_agent_messages: () => ({ status: "ok", messages: [{ message_id: MSG, result: "maybe" }] }) } }).admin, { userId: USER, conversationId: CONV })).rejects.toThrow();
  });
});

describe("startAgentMessage: 대화의 연결을 해석해 전달 단계를 시작한다 (D1c-1 startAgentTurn)", () => {
  it("queued 메시지를 registry 등급(Codex read_only)으로 시작한다: 저장된 added 칩만 넘기고 auto 칩은 넘기지 않는다 (AC-6)", async () => {
    const selected = {
      action_ids: [ACTION], context_ids: [CONTEXT],
      attachments: [{ kind: "action", id: ACTION, origin: "added" }, { kind: "action", id: ACTION2, origin: "auto" }, { kind: "context", id: CONTEXT, origin: "added" }, { kind: "context", id: OTHER, origin: "auto" }],
    };
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ selected })], actions: [{ id: ACTION, user_id: USER }] }), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual(started);
    expect(fake.rpcCalls("start_agent_turn_auto")).toHaveLength(1);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toEqual({
      p_user_id: USER, p_message_id: MSG, p_action_ids: [ACTION], p_context_ids: [CONTEXT], p_access: "read_only", p_live_limit: 5,
    });
  });

  it("앞서 start가 저장한 refs.agent_turn 칩이 있으면 그것을 쓴다 (재호출 멱등)", async () => {
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [messageRow({ refs: { agent_turn: { action_ids: [ACTION2], context_ids: [] } }, selected: { action_ids: [ACTION], context_ids: [], attachments: [] } })], actions: [{ id: ACTION, user_id: USER }, { id: ACTION2, user_id: USER }] }),
      rpc: rpcs(),
    });
    await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [ACTION2], p_context_ids: [] });
  });

  it.each(["dispatched", "cancelled", "expired"])("전달 전 상태가 아닌 %s는 건드리지 않는다 (RPC 0)", async (state) => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: state })] }), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls()).toEqual([]);
  });

  it("검토 반영 7-3: 지워진 Action 칩은 처리 입력에서 뺀다 (저장된 selected에는 남는다) — 같은 제출 재전송이 SQL not_found로 막히지 않는다", async () => {
    const selected = { action_ids: [ACTION, ACTION2], context_ids: [CONTEXT], attachments: [{ kind: "action", id: ACTION, origin: "added" }, { kind: "action", id: ACTION2, origin: "added" }, { kind: "context", id: CONTEXT, origin: "added" }] };
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ selected })], actions: [{ id: ACTION, user_id: USER }, { id: ACTION2, user_id: OTHER }] }), rpc: rpcs() });
    await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW);
    // ACTION2는 남의 것(지워진 것과 구별하지 못한다)이라 빠지고, 남은 칩으로 시작한다
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [ACTION], p_context_ids: [CONTEXT] });
    expect(fake.tables.conversation_messages[0].selected).toEqual(selected);
    // 칩이 모두 지워지면 칩 없는 메시지로 시작한다 (새 Action 경로)
    const allGone = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ selected })], actions: [] }), rpc: rpcs() });
    await startAgentMessage(allGone.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW);
    expect(allGone.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_action_ids: [] });
  });

  it.each(["spawn_failed", "sign_in_needed", "usage_limited", "not_received", "unsupported"])("검토 반영 7-1: not_sent/%s는 자동으로 다시 시작하지 않는다 (같은 제출 재전송 · referent도 마찬가지: Send again으로만)", async (reason) => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: "not_sent", delivery_reason: reason })] }), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls()).toEqual([]);
  });

  it.each(["write_gate_closed", "not_connected"])("검토 반영 7-1: not_sent/%s(gate 계열)는 플래그가 이제 켜져 있으면 다시 시작한다", async (reason) => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: "not_sent", delivery_reason: reason })] }), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual(started);
  });

  it.each(["write_gate_closed", "not_connected", "spawn_failed"])("검토 반영 7-1: 실행 플래그가 꺼져 있어도 이미 not_sent/%s인 메시지의 이유는 덮어쓰지 않는다 (표시 0)", async (reason) => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: "not_sent", delivery_reason: reason })] }), rpc: rpcs({ mark_agent_message_not_sent_auto: () => ({ status: "not_sent", reason: "write_gate_closed" }) }) });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, OFF, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls()).toEqual([]);
  });

  it("검토 반영 7-1 (재현): A가 not_sent/spawn_failed인 채 B를 보내면 B는 queue_order로 대기하고 A는 다시 시작되지 않는다. A를 Send again하면 A가 시작된다", async () => {
    const A = "a1000000-0000-4000-8000-0000000000aa";
    const tables = world({
      conversations: [{ id: CONV, user_id: USER, target_kind: "agent", agent_connection_id: CONN, agent_session_id: SESSION }],
      agent_sessions: [{ id: SESSION, user_id: USER, connection_id: CONN }],
      conversation_messages: [messageRow({ id: A, seq: 1, delivery_state: "not_sent", delivery_reason: "spawn_failed" }), messageRow({ id: MSG, seq: 2, client_message_id: "c1c1c1c1-0000-4000-8000-0000000000bb" })],
    });
    const started_ = new Map<string, unknown>([[MSG, { status: "queued", reason: "queue_order" }], [A, started]]);
    const fake = fakeAdmin({ tables, rpc: rpcs({ start_agent_turn_auto: (args) => started_.get(String(args.p_message_id)), next_queued_agent_message: () => A }) });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "queued", reason: "queue_order" });
    expect(fake.rpcCalls("start_agent_turn_auto").map((call) => (call.args as { p_message_id?: string }).p_message_id)).toEqual([MSG]); // A는 시작되지 않았다
    expect(tables.conversation_messages.find((m) => m.id === A)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "spawn_failed" });
    // 사용자가 A를 Send again: 대기로 되돌린 뒤 시작한다
    const again = fakeAdmin({
      tables: { ...tables, conversation_messages: [messageRow({ id: A, seq: 1, delivery_state: "queued" }), tables.conversation_messages[1]] },
      rpc: rpcs({ requeue_agent_messages: () => ({ status: "ok", messages: [{ message_id: A, result: "requeued" }] }), start_agent_turn_auto: (args) => started_.get(String(args.p_message_id)) }),
    });
    await deliverAgentMessages(again.admin, { userId: USER, conversationId: CONV, messageIds: [A] }, CODEX, NOW);
    expect(again.rpcCalls("start_agent_turn_auto").map((call) => (call.args as { p_message_id?: string }).p_message_id)).toEqual([A]);
  });

  it("검토 반영 8-1: 시작은 SQL 래퍼(start_agent_turn_auto)를 지나 잠금 안에서 다시 확인한다 — 래퍼가 skipped이면 그대로 skipped (표시 0)", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs({ start_agent_turn_auto: () => ({ status: "skipped" }) }) });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["start_agent_turn_auto"]);
  });

  it.each(["not_found", "already_dispatched"])("검토 반영 8-2: 진짜 %s이면 대기열에서 뺀다 (mark_agent_message_not_sent_auto, 같은 이유)", async (status) => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs({ start_agent_turn_auto: () => ({ status }), mark_agent_message_not_sent_auto: (args) => ({ status: "not_sent", reason: args.p_reason }) }) });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "not_sent", reason: status });
    expect(fake.rpcCalls("mark_agent_message_not_sent_auto")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: status, p_from_gate: true });
  });

  it("보관 기한이 지난 queued · not_sent도 시작하지 않는다 (만료 sweep이 expired로 바꾼다)", async () => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_expires_at: "2026-10-14T11:59:59.000Z" })] }), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls()).toEqual([]);
  });

  it("없는 메시지 · 다른 대화의 메시지 · 연결을 해석할 수 없는 대화는 건너뛴다", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG2 }, CODEX, NOW)).toEqual({ status: "skipped" });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: "c1000000-0000-4000-8000-0000000000ff", messageId: MSG }, CODEX, NOW)).toEqual({ status: "skipped" });
    const noConnection = fakeAdmin({ tables: world({ agent_connections: [] }), rpc: rpcs() });
    expect(await startAgentMessage(noConnection.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls().concat(noConnection.rpcCalls())).toEqual([]);
  });

  it("adapter gate가 꺼져 있으면 시작하지 않는다 (OD-2: 전달 시작 0)", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, {}, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls()).toEqual([]);
  });

  it("Claude Code(쓰기 gate · read_only 미검증)는 단계를 만들지 않고 not_sent로 표시한다 (AC-10)", async () => {
    const fake = fakeAdmin({
      tables: world({ agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:claude-code", status: "active" }] }),
      rpc: rpcs({ mark_agent_message_not_sent_auto: () => ({ status: "not_sent", reason: "write_gate_closed" }) }),
    });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, { AGENT_BETA_USER_IDS: USER, CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" }, NOW)).toEqual({ status: "not_sent", reason: "write_gate_closed" });
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["mark_agent_message_not_sent_auto"]);
  });

  it("queue_order로 밀렸고 세션이 있으면 다음 대기 메시지를 한 번 시작해 본다 (OD-10)", async () => {
    const fake = fakeAdmin({
      tables: world({ agent_sessions: [{ id: SESSION, user_id: USER, connection_id: CONN }] }),
      rpc: rpcs({ start_agent_turn_auto: () => ({ status: "queued", reason: "queue_order" }), next_queued_agent_message: () => null }),
    });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "queued", reason: "queue_order" });
    expect(fake.rpcCalls("next_queued_agent_message")).toHaveLength(1);
    expect(fake.rpcCalls("next_queued_agent_message")[0].args).toEqual({ p_user_id: USER, p_session_id: SESSION });
  });

  it("queue_order라도 세션이 없으면 부르지 않고, 다른 대기 이유(session_busy)에도 부르지 않는다", async () => {
    const noSession = fakeAdmin({
      tables: world({ conversations: [{ id: CONV, user_id: USER, target_kind: "agent", agent_connection_id: CONN, agent_session_id: null }] }),
      rpc: rpcs({ start_agent_turn_auto: () => ({ status: "queued", reason: "queue_order" }) }),
    });
    await startAgentMessage(noSession.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW);
    const busy = fakeAdmin({ tables: world(), rpc: rpcs({ start_agent_turn_auto: () => ({ status: "queued", reason: "session_busy" }) }) });
    await startAgentMessage(busy.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW);
    expect(noSession.rpcCalls("next_queued_agent_message")).toEqual([]);
    expect(busy.rpcCalls("next_queued_agent_message")).toEqual([]);
  });

  it("다음 메시지 시작이 실패해도 이미 끝난 첫 시작의 결과를 돌려준다 (로그에는 이벤트 이름 · 오류 이름만)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const fake = fakeAdmin({
        tables: world(),
        rpc: rpcs({ start_agent_turn_auto: () => ({ status: "queued", reason: "queue_order" }), next_queued_agent_message: () => { throw Object.assign(new Error("secret text"), { name: "PostgrestError" }); } }),
      });
      expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual({ status: "queued", reason: "queue_order" });
      expect(log).toHaveBeenCalledTimes(1);
      expect(JSON.parse(String(log.mock.calls[0][0]))).toEqual({ event: "agent_start_next_failed", error: "PostgrestError" });
      expect(JSON.stringify(log.mock.calls)).not.toContain("secret text");
    } finally {
      log.mockRestore();
    }
  });

  it("전달 RPC의 오류는 그대로 던진다 (이미 시작한 것으로 오해하지 않는다)", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs({ start_agent_turn_auto: () => { throw Object.assign(new Error("lock"), { code: "55P03" }); } }) });
    await expect(startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).rejects.toMatchObject({ code: "55P03" });
  });
});

describe("D2a 보안 검토 P1 방어: 실행 kill switch가 꺼져 있으면 턴을 시작하지 않는다", () => {
  const closed = { status: "not_sent", reason: "write_gate_closed" };
  const gateRpcs = () => rpcs({ mark_agent_message_not_sent_auto: () => closed });

  it("startAgentMessage: start_agent_turn_auto 0, 메시지를 not_sent/write_gate_closed로 표시하고 그 상태를 돌려준다", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: gateRpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, OFF, NOW)).toEqual(closed);
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["mark_agent_message_not_sent_auto"]);
    expect(fake.rpcCalls()[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: "write_gate_closed", p_from_gate: false });
    expect(fake.calls.filter((call) => call.kind === "insert" || call.kind === "update" || call.kind === "upsert")).toEqual([]);
  });

  it("검토 반영 9-1: 읽은 뒤 상태가 바뀌어 SQL이 표시하지 않으면(skipped) 그대로 skipped다 — TS가 읽어 둔 queued로 판단해 쓰지 않는다", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs({ mark_agent_message_not_sent_auto: () => ({ status: "skipped" }) }) });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, OFF, NOW)).toEqual({ status: "skipped" });
    expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
  });

  it("전달 전 상태가 아니거나 adapter gate가 꺼져 있으면 표시도 하지 않는다 (skipped, RPC 0)", async () => {
    const dispatched = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: "dispatched" })] }), rpc: gateRpcs() });
    expect(await startAgentMessage(dispatched.admin, { userId: USER, conversationId: CONV, messageId: MSG }, OFF, NOW)).toEqual({ status: "skipped" });
    const adapterOff = fakeAdmin({ tables: world(), rpc: gateRpcs() });
    expect(await startAgentMessage(adapterOff.admin, { userId: USER, conversationId: CONV, messageId: MSG }, {}, NOW)).toEqual({ status: "skipped" });
    expect(dispatched.rpcCalls().concat(adapterOff.rpcCalls())).toEqual([]);
  });

  it("deliverAgentMessages: 다시 대기시킨 메시지마다 시작하지 않고 표시한다 (작업 · 단계 · 지표를 만드는 start_agent_turn_auto 0)", async () => {
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [messageRow(), messageRow({ id: MSG2, seq: 2 })] }),
      rpc: { ...gateRpcs(), requeue_agent_messages: () => ({ status: "ok", messages: [{ message_id: MSG, result: "requeued" }, { message_id: MSG2, result: "requeued" }] }) },
    });
    await deliverAgentMessages(fake.admin, { userId: USER, conversationId: CONV }, OFF, NOW);
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["requeue_agent_messages", "mark_agent_message_not_sent_auto", "mark_agent_message_not_sent_auto"]);
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });

  it("켜져 있으면 동작이 그대로다: start_agent_turn_auto로 시작하고 표시하지 않는다", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: gateRpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual(started);
    expect(fake.rpcCalls("mark_agent_message_not_sent_auto")).toEqual([]);
  });
});

describe("결제 계약 22장: 만료된 계정은 에이전트 실행을 시작하지 못한다 (수동 시작 · 다시 전달 · 읽기 표시)", () => {
  afterEach(() => vi.unstubAllEnvs());
  const DAY = 86_400_000;
  const billingRow = (over: Record<string, unknown>) => ({
    user_id: USER, legacy_beta: false, notice_ends_at: null, trial_ends_at: null, subscription_id: "s", customer_id: null, order_id: null, plan: null, status: "expired",
    current_period_ends_at: null, deleting: false, first_subscription_at: null, lifetime_order_id: null, lifetime_status: null, lifetime_paid_at: null,
    last_payment_at: null, last_invoice_id: null, refund_requested_at: null, self_refund_used_at: null, ...over,
  });
  const EXPIRED = billingRow({});
  const PAID = billingRow({ status: "active", current_period_ends_at: new Date(Date.now() + 5 * DAY).toISOString() });
  const closed = { status: "not_sent", reason: "write_gate_closed" };
  const billed = (row: Record<string, unknown>, extra: Partial<Tables> = {}) => {
    vi.stubEnv("BILLING_ENABLED", "true");
    return world({ billing_accounts: [row], ...extra });
  };

  it("startAgentMessage: 시작하지 않고 not_sent/write_gate_closed로 표시한다 (막힌 일은 이어 갈 수 있다)", async () => {
    const fake = fakeAdmin({ tables: billed(EXPIRED), rpc: rpcs({ mark_agent_message_not_sent_auto: () => closed, billing_mark_agent_block: () => true }) });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual(closed);
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
    expect(fake.rpcCalls("billing_mark_agent_block").map((call) => call.args)).toEqual([{ p_user_id: USER, p_message_id: MSG, p_blocked: true }]); // 막은 이유가 결제임을 남긴다
    expect(fake.rpcCalls("mark_agent_message_not_sent_auto")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_reason: "write_gate_closed", p_from_gate: false });
  });

  it("deliverAgentMessages(다시 전달): 다시 대기시킨 메시지마다 시작하지 않는다", async () => {
    const fake = fakeAdmin({
      tables: billed(EXPIRED, { conversation_messages: [messageRow(), messageRow({ id: MSG2, seq: 2 })] }),
      rpc: rpcs({ mark_agent_message_not_sent_auto: () => closed, billing_mark_agent_block: () => true, requeue_agent_messages: () => ({ status: "ok", messages: [{ message_id: MSG, result: "requeued" }, { message_id: MSG2, result: "requeued" }] }) }),
    });
    await deliverAgentMessages(fake.admin, { userId: USER, conversationId: CONV }, CODEX, NOW);
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
    expect(fake.rpcCalls("mark_agent_message_not_sent_auto")).toHaveLength(2);
  });

  it("권한이 있으면 평소처럼 시작한다", async () => {
    const fake = fakeAdmin({ tables: billed(PAID), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual(started);
  });

  it("결제가 꺼져 있으면 동작이 그대로다: billing_accounts를 읽지 않는다", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs() });
    expect(await startAgentMessage(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG }, CODEX, NOW)).toEqual(started);
    expect(fake.calls.some((call) => call.target === "billing_accounts")).toBe(false);
  });

  describe("읽기 표시: 만료 때문에 멈춘 메시지는 billing_required로 보인다 (저장된 이유는 write_gate_closed 그대로)", () => {
    // 막을 때 메시지에 남기는 결제 표시(billing_mark_agent_block)가 있어야 결제 때문에 멈춘 것으로 읽는다
    const stopped = (refs: Record<string, unknown> = { blocked_by: "billing" }) => messageRow({ delivery_state: "not_sent", delivery_reason: "write_gate_closed", refs });
    it("만료된 계정: delivery.reason이 billing_required", async () => {
      const fake = fakeAdmin({ tables: billed(EXPIRED, { conversation_messages: [stopped()] }) });
      const read = await loadAgentDeliveries(fake.admin, USER, CONV, {});
      expect(read[0].delivery).toEqual({ state: "not_sent", reason: "billing_required" });
      expect(agentDeliverySchema.safeParse(read[0].delivery).success).toBe(true);
      expect(Object.values(await loadAgentDeliveriesByIds(fake.admin, USER, CONV, [MSG]))[0]).toEqual({ state: "not_sent", reason: "billing_required" });
      expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: "not_sent", reason: "billing_required" });
      expect(fake.tables.conversation_messages[0].delivery_reason).toBe("write_gate_closed");
      expect(fake.calls.filter((call) => call.kind !== "select")).toEqual([]);
    });
    it("결제 표시가 없는 멈춤(킬 스위치)은 계정이 만료돼 있어도 write_gate_closed 그대로다 (결제 때문이라고 말하지 않는다)", async () => {
      const fake = fakeAdmin({ tables: billed(EXPIRED, { conversation_messages: [stopped({})] }) });
      expect((await loadAgentDeliveries(fake.admin, USER, CONV, {}))[0].delivery).toEqual({ state: "not_sent", reason: "write_gate_closed" });
      expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: "not_sent", reason: "write_gate_closed" });
    });
    it("권한이 있는 계정이 멈춘 것은 다른 이유(kill switch 등)라 그대로 write_gate_closed", async () => {
      const fake = fakeAdmin({ tables: billed(PAID, { conversation_messages: [stopped()] }) });
      expect((await loadAgentDeliveries(fake.admin, USER, CONV, {}))[0].delivery).toEqual({ state: "not_sent", reason: "write_gate_closed" });
    });
    it("다른 이유로 멈춘 메시지는 건드리지 않고, 계정도 읽지 않는다", async () => {
      const fake = fakeAdmin({ tables: billed(EXPIRED, { conversation_messages: [messageRow({ delivery_state: "not_sent", delivery_reason: "spawn_failed" }), messageRow({ id: MSG2, seq: 2 })] }) });
      expect((await loadAgentDeliveries(fake.admin, USER, CONV, {})).map((item) => item.delivery)).toEqual([{ state: "not_sent", reason: "spawn_failed" }, { state: "queued" }]);
      expect(fake.calls.some((call) => call.target === "billing_accounts")).toBe(false);
    });
    it("결제가 꺼져 있으면 그대로 write_gate_closed이고 계정을 읽지 않는다", async () => {
      const fake = fakeAdmin({ tables: world({ conversation_messages: [stopped()] }) });
      expect((await loadAgentDeliveries(fake.admin, USER, CONV, {}))[0].delivery).toEqual({ state: "not_sent", reason: "write_gate_closed" });
      expect(fake.calls.some((call) => call.target === "billing_accounts")).toBe(false);
    });
    it("계정을 읽지 못해도 표시는 깨지지 않는다 (저장된 이유 그대로)", async () => {
      vi.stubEnv("BILLING_ENABLED", "true");
      const fake = fakeAdmin({ tables: world({ billing_accounts: [EXPIRED], conversation_messages: [stopped()] }), fail: { "billing_accounts.select": { code: "XX000", message: "db" } } });
      expect((await loadAgentDeliveries(fake.admin, USER, CONV, {}))[0].delivery).toEqual({ state: "not_sent", reason: "write_gate_closed" });
    });
  });
});

describe("deliverAgentMessages (Send again, AC-22): 다시 대기시킨 메시지를 seq 순으로 하나씩 시작한다", () => {
  const requeueResult = (...ids: [string, string][]) => ({ status: "ok", messages: ids.map(([id, result]) => (result === "requeued" ? { message_id: id, result } : { message_id: id, result, reason: "not_eligible" })) });

  it("requeued만 시작한다. 첫째가 시작되면 둘째는 SQL이 session_busy로 대기시킨다. skipped는 시작하지 않는다", async () => {
    const order: string[] = [];
    const results: Record<string, unknown> = { [MSG]: started, [MSG2]: { status: "queued", reason: "session_busy" } };
    const third = "a1000000-0000-4000-8000-000000000003";
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [messageRow(), messageRow({ id: MSG2, seq: 2 }), messageRow({ id: third, seq: 3, delivery_state: "dispatched" })] }),
      rpc: rpcs({
        requeue_agent_messages: () => requeueResult([MSG, "requeued"], [MSG2, "requeued"], [third, "skipped"]),
        start_agent_turn_auto: (args) => { order.push(String(args.p_message_id)); return results[String(args.p_message_id)]; },
      }),
    });
    const outcome = await deliverAgentMessages(fake.admin, { userId: USER, conversationId: CONV, messageIds: undefined }, CODEX, NOW);
    expect(outcome.status).toBe("ok");
    expect(order).toEqual([MSG, MSG2]);
    // requeue가 commit된 뒤에 시작한다 (함수 호출 순서)
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["requeue_agent_messages", "start_agent_turn_auto", "start_agent_turn_auto"]);
  });

  it("다시 눌러 모두 skipped이면 새 시작 0", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpcs({ requeue_agent_messages: () => requeueResult([MSG, "skipped"], [MSG2, "skipped"]) }) });
    await deliverAgentMessages(fake.admin, { userId: USER, conversationId: CONV, messageIds: [MSG, MSG2] }, CODEX, NOW);
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
  });

  it("대화가 없거나 taskforce 대화면 시작하지 않는다", async () => {
    for (const status of ["not_found", "wrong_target"]) {
      const fake = fakeAdmin({ tables: world(), rpc: rpcs({ requeue_agent_messages: () => ({ status, messages: [] }) }) });
      expect((await deliverAgentMessages(fake.admin, { userId: USER, conversationId: CONV }, CODEX, NOW)).status).toBe(status);
      expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
    }
  });

  it("중간 메시지의 시작이 실패하면 던진다 (이미 다시 대기된 메시지는 queued로 남아 다음 계기가 집는다)", async () => {
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [messageRow(), messageRow({ id: MSG2, seq: 2 })] }),
      rpc: rpcs({ requeue_agent_messages: () => requeueResult([MSG, "requeued"], [MSG2, "requeued"]), start_agent_turn_auto: () => { throw Object.assign(new Error("lock"), { code: "55P03" }); } }),
    });
    await expect(deliverAgentMessages(fake.admin, { userId: USER, conversationId: CONV }, CODEX, NOW)).rejects.toMatchObject({ code: "55P03" });
    expect(fake.rpcCalls("start_agent_turn_auto")).toHaveLength(3); // 검토 반영 9-2: 롤백된 경합은 같은 메시지로 두 번 더 시도한 뒤에야 던진다 (다음 메시지로 넘어가지 않는다)
  });
});

describe("deterministicActionId: 메시지 id에서 start_agent_turn이 만드는 Action id와 같다", () => {
  it("sha256('tf:assistant_agent:action:' + 메시지 id)의 앞 32자 uuid", () => {
    const hex = createHash("sha256").update(`tf:assistant_agent:action:${MSG}`).digest("hex").slice(0, 32);
    expect(deterministicActionId(MSG)).toBe(`${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`);
  });
});

describe("loadAgentMessageOutcome: 다시 읽은 행으로 계산한다 (계약 2.4)", () => {
  const taskRow = (extra: Record<string, unknown> = {}) => ({ id: TASK, user_id: USER, message_id: MSG, state: "dispatched", agent_session_id: SESSION, run_id: RUN, step_id: STEP, turn_seq: 1, ...extra });
  const dispatched = (extra: Partial<Tables> = {}) => world({
    conversation_messages: [messageRow({ delivery_state: "dispatched" })],
    agent_tasks: [taskRow()],
    execution_steps: [{ id: STEP, user_id: USER, state: "prepared", kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } }],
    execution_runs: [{ id: RUN, user_id: USER, action_id: deterministicActionId(MSG) }],
    actions: [{ id: deterministicActionId(MSG), user_id: USER, title: "이어서 해 줘", number: 139 }],
    context_members: [{ user_id: USER, member_kind: "action", action_id: deterministicActionId(MSG), context_id: CONTEXT, removed_at: null, created_at: "2026-10-14T00:00:00Z" }],
    ...extra,
  });

  it("dispatched + 단계 prepared → sent, 새 Action(created_action)과 작업(agent_task)을 함께 돌려준다", async () => {
    const fake = fakeAdmin({ tables: dispatched() });
    const outcome = await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG);
    expect(outcome).toMatchObject({
      delivery: { state: "sent" },
      created_action: { id: deterministicActionId(MSG), number: 139, title: "이어서 해 줘", context_id: CONTEXT },
      agent_task: { id: TASK, state: "dispatched", agent_session_id: SESSION },
    });
    expect(agentConversationMessageSchema.safeParse(outcome!.message).success).toBe(true);
    expect(outcome!.message).toMatchObject({ id: MSG, delivery_state: "dispatched", delivery_expires_at: FUTURE });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it.each([["prepared", "queued"], ["calling", "sent"], ["called", "accepted"], ["unknown_outcome", "unknown"]] as const)("끊긴 세션의 %s → %s: 소유 세션을 읽어 lease 전만 대기로 표시한다", async (state, expected) => {
    const fake = fakeAdmin({ tables: dispatched({
      agent_sessions: [{ id: SESSION, user_id: USER, status: "unreachable" }],
      execution_steps: [{ id: STEP, user_id: USER, state, kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } }],
    }) });
    expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: expected });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it("단계 called → accepted, unknown_outcome → unknown", async () => {
    for (const [state, expected] of [["called", "accepted"], ["unknown_outcome", "unknown"]] as const) {
      const fake = fakeAdmin({ tables: dispatched({ execution_steps: [{ id: STEP, user_id: USER, state, kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } }] }) });
      expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: expected });
    }
  });

  it("같은 메시지의 작업이 여럿이면(실패한 앞 회차) 마지막 턴의 작업 · 단계로 계산한다", async () => {
    const first = { ...taskRow(), id: "7a000000-0000-4000-8000-0000000000f1", turn_seq: 1, step_id: "57000000-0000-4000-8000-0000000000f1", state: "failed" };
    const fake = fakeAdmin({
      tables: dispatched({
        agent_tasks: [taskRow({ turn_seq: 2 }), first],
        execution_steps: [{ id: first.step_id, user_id: USER, state: "failed", kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } }, { id: STEP, user_id: USER, state: "called", kind: "agent_message", seq: 2, run_id: RUN, args: { message_id: MSG } }],
      }),
    });
    const outcome = await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG);
    expect(outcome).toMatchObject({ delivery: { state: "accepted" }, agent_task: { id: TASK } });
  });

  it("검토 반영 7-4: 원문 메시지의 전달 표시는 task.step_id(답 단계로 바뀐다)가 아니라 그 메시지의 전달 단계로 계산한다: 원문 accepted → 답 단계 실패 → 원문은 accepted 그대로, 답 메시지만 not_sent", async () => {
    const ANSWER_MSG = "a1000000-0000-4000-8000-0000000000ab";
    const ANSWER_STEP = "57000000-0000-4000-8000-0000000000ab";
    const tables = dispatched({
      conversation_messages: [messageRow({ delivery_state: "dispatched" }), messageRow({ id: ANSWER_MSG, seq: 3, client_message_id: "c1c1c1c1-0000-4000-8000-0000000000ac", delivery_state: "dispatched", refs: { answer_for: [TASK, "q-1"] } })],
      agent_tasks: [taskRow({ step_id: ANSWER_STEP })], // 답을 제출하면 task.step_id가 답 단계로 옮겨 간다
      execution_steps: [
        { id: STEP, user_id: USER, state: "called", kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } },
        { id: ANSWER_STEP, user_id: USER, state: "failed", kind: "agent_message", seq: 2, run_id: RUN, receipt: { reason: "usage_limited" }, args: { agent_task_id: TASK, provider_request_id: "q-1", answer_message_id: ANSWER_MSG } },
      ],
    });
    const fake = fakeAdmin({ tables });
    expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: "accepted" });
    expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, ANSWER_MSG))!.delivery).toEqual({ state: "not_sent", reason: "usage_limited" });
    const read = await loadAgentDeliveries(fake.admin, USER, CONV, {});
    expect(read.map((item) => [item.message_id, item.delivery.state])).toEqual([[MSG, "accepted"], [ANSWER_MSG, "not_sent"]]);
  });

  it("검토 반영 7-4: 원문의 실패한 앞 회차 단계가 있어도 마지막 회차(seq 최대) 단계로 계산한다", async () => {
    const fake = fakeAdmin({
      tables: dispatched({
        execution_steps: [
          { id: "57000000-0000-4000-8000-0000000000e2", user_id: USER, state: "prepared", kind: "agent_message", seq: 5, run_id: RUN, args: { message_id: MSG } },
          { id: "57000000-0000-4000-8000-0000000000e1", user_id: USER, state: "failed", kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } },
        ],
      }),
    });
    expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: "sent" });
  });

  it("검토 반영 8-3: 원문 전달 단계는 그 메시지의 최신 task의 run 안에서 찾는다 — 옛 run에서 실패(seq 2) → Done → 다시 열기 → 재전송이 새 run seq 1에서 called면 accepted (run 구분 없는 seq 최댓값이면 not_sent)", async () => {
    const OLD_RUN = "20000000-0000-4000-8000-0000000000bb";
    const OLD_TASK = "7a000000-0000-4000-8000-0000000000f2";
    const fake = fakeAdmin({
      tables: dispatched({
        agent_tasks: [
          { ...taskRow(), id: OLD_TASK, run_id: OLD_RUN, turn_seq: 1, state: "failed", step_id: "57000000-0000-4000-8000-0000000000f2" },
          taskRow({ turn_seq: 2 }),
        ],
        execution_steps: [
          { id: "57000000-0000-4000-8000-0000000000f2", user_id: USER, state: "failed", kind: "agent_message", seq: 2, run_id: OLD_RUN, args: { message_id: MSG } },
          { id: STEP, user_id: USER, state: "called", kind: "agent_message", seq: 1, run_id: RUN, args: { message_id: MSG } },
        ],
      }),
    });
    expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery).toEqual({ state: "accepted" });
    expect((await loadAgentDeliveries(fake.admin, USER, CONV, {})).map((item) => item.delivery.state)).toEqual(["accepted"]);
    expect(Object.values(await loadAgentDeliveriesByIds(fake.admin, USER, CONV, [MSG])).map((delivery) => delivery.state)).toEqual(["accepted"]);
  });

  it("검토 반영 8-3: 같은 run을 다른 메시지가 쓰고 있어도(옛 run에 두 메시지의 단계가 함께 있다) 각 메시지는 자기 최신 task의 run 단계만 본다", async () => {
    const OLD_RUN = "20000000-0000-4000-8000-0000000000bb";
    const stepRow = (id: string, message: string, run: string, seq: number, state: string) => ({ id, user_id: USER, state, kind: "agent_message", seq, run_id: run, args: { message_id: message } });
    const fake = fakeAdmin({
      tables: dispatched({
        conversation_messages: [messageRow({ delivery_state: "dispatched" }), messageRow({ id: MSG2, seq: 2, client_message_id: "c1c1c1c1-0000-4000-8000-0000000000ad", delivery_state: "dispatched" })],
        agent_tasks: [
          { ...taskRow(), id: "7a000000-0000-4000-8000-0000000000f2", run_id: OLD_RUN, turn_seq: 1, state: "failed" }, // MSG의 옛 run
          { ...taskRow(), id: "7a000000-0000-4000-8000-0000000000f3", message_id: MSG2, run_id: OLD_RUN, turn_seq: 2 }, // MSG2는 옛 run을 계속 쓴다
          taskRow({ turn_seq: 3 }), // MSG의 새 run(다시 열기 뒤 재전송)
        ],
        execution_steps: [
          stepRow("57000000-0000-4000-8000-0000000000f2", MSG, OLD_RUN, 2, "failed"),
          stepRow("57000000-0000-4000-8000-0000000000f4", MSG2, OLD_RUN, 3, "called"),
          stepRow(STEP, MSG, RUN, 1, "called"),
        ],
      }),
    });
    const read = await loadAgentDeliveries(fake.admin, USER, CONV, {});
    expect(read.map((item) => [item.message_id, item.delivery.state])).toEqual([[MSG, "accepted"], [MSG2, "accepted"]]);
  });

  it("검토 반영 8-3: 최신 task의 run에 원문 단계가 아직 없으면 옛 run의 단계로 대신하지 않는다 (not_sent 방어 표시)", async () => {
    const OLD_RUN = "20000000-0000-4000-8000-0000000000bb";
    const fake = fakeAdmin({
      tables: dispatched({
        agent_tasks: [{ ...taskRow(), id: "7a000000-0000-4000-8000-0000000000f2", run_id: OLD_RUN, turn_seq: 1 }, taskRow({ turn_seq: 2 })],
        execution_steps: [{ id: "57000000-0000-4000-8000-0000000000f2", user_id: USER, state: "called", kind: "agent_message", seq: 4, run_id: OLD_RUN, args: { message_id: MSG } }],
      }),
    });
    expect((await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG))!.delivery.state).toBe("not_sent");
  });

  it("기존 Action에 붙인 턴이면 created_action은 null (이 메시지가 만든 Action이 아니다)", async () => {
    const fake = fakeAdmin({ tables: dispatched({ execution_runs: [{ id: RUN, user_id: USER, action_id: ACTION }] }) });
    const outcome = await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG);
    expect(outcome!.created_action).toBeNull();
    expect(outcome!.agent_task).toMatchObject({ id: TASK });
  });

  it("작업이 아직 없으면(queued · not_sent) agent_task · created_action은 null", async () => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: "queued", delivery_reason: "session_busy" })] }) });
    expect(await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG)).toMatchObject({ delivery: { state: "queued", reason: "session_busy" }, created_action: null, agent_task: null });
  });

  it("D2a 보안 검토 P1 방어로 표시된 메시지는 not_sent/write_gate_closed로 읽힌다 (작업 · 새 Action 없음, 보통 응답 모양)", async () => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: [messageRow({ delivery_state: "not_sent", delivery_reason: "write_gate_closed" })] }) });
    expect(await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG)).toMatchObject({
      delivery: { state: "not_sent", reason: "write_gate_closed" }, created_action: null, agent_task: null,
      message: { delivery_state: "not_sent", delivery_reason: "write_gate_closed" },
    });
  });

  it("후보를 고르지 않은 queued 메시지는 needs_referent + 후보 제목을 읽어 돌려준다", async () => {
    const fake = fakeAdmin({
      tables: world({
        conversation_messages: [messageRow({ refs: { referent_candidates: [ACTION, ACTION2] } })],
        actions: [{ id: ACTION, user_id: USER, title: "가격 문구", number: 1 }, { id: ACTION2, user_id: OTHER, title: "남의 제목", number: 1 }],
      }),
    });
    const outcome = await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG);
    expect(outcome!.delivery).toEqual({ state: "needs_referent", candidates: [{ action_id: ACTION, title: "가격 문구" }] });
    expect(agentDeliverySchema.safeParse(outcome!.delivery).success).toBe(true);
  });

  it("질문에 자유 글로 답한 메시지: 답 단계가 failed면 not_sent + 이유, 그 밖에는 answered", async () => {
    const answered = (stepState: string, receipt: unknown = null) => world({
      conversation_messages: [messageRow({ delivery_state: "dispatched", refs: { answer_for: [TASK, "q-1"] } })],
      execution_steps: [{ id: "57000000-0000-4000-8000-0000000000a1", user_id: USER, state: stepState, receipt, seq: 2, args: { answer_message_id: MSG } }],
    });
    expect((await loadAgentMessageOutcome(fakeAdmin({ tables: answered("called") }).admin, USER, CONV, MSG))!.delivery).toEqual({ state: "answered" });
    expect((await loadAgentMessageOutcome(fakeAdmin({ tables: answered("failed", { reason: "usage_limited" }) }).admin, USER, CONV, MSG))!.delivery).toEqual({ state: "not_sent", reason: "usage_limited" });
    expect((await loadAgentMessageOutcome(fakeAdmin({ tables: answered("failed") }).admin, USER, CONV, MSG))!.delivery).toEqual({ state: "not_sent" });
  });

  it("없는 메시지 · 다른 대화의 메시지 · 남의 메시지는 null", async () => {
    const fake = fakeAdmin({ tables: world() });
    expect(await loadAgentMessageOutcome(fake.admin, USER, CONV, MSG2)).toBeNull();
    expect(await loadAgentMessageOutcome(fake.admin, USER, "c1000000-0000-4000-8000-0000000000ff", MSG)).toBeNull();
    expect(await loadAgentMessageOutcome(fake.admin, OTHER, CONV, MSG)).toBeNull();
  });
});

describe("loadAgentDeliveries (OD-13): 사용자 메시지의 전달 표시를 서버 계산으로, 최대 100", () => {
  const rows = Array.from({ length: 120 }, (_, i) => messageRow({ id: `a1000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`, seq: i + 1 }));

  it("seq 순, since_seq 뒤만, 100개까지. 사용자 메시지만", async () => {
    const assistant = messageRow({ id: "a1000000-0000-4000-8000-0000000009ff", seq: 130, role: "assistant", delivery_state: null });
    const fake = fakeAdmin({ tables: world({ conversation_messages: [...rows, assistant] }) });
    const all = await loadAgentDeliveries(fake.admin, USER, CONV, {});
    expect(all).toHaveLength(100);
    expect(all[0]).toMatchObject({ seq: 1, delivery: { state: "queued" } });
    expect(all[99].seq).toBe(100);
    const later = await loadAgentDeliveries(fake.admin, USER, CONV, { sinceSeq: 110 });
    expect(later.map((item) => item.seq)).toEqual(Array.from({ length: 10 }, (_, i) => 111 + i));
    expect(later.map((item) => item.message_id)).not.toContain(assistant.id);
  });

  it("쓰기 0, 사용자 · 대화로 좁힌다", async () => {
    const fake = fakeAdmin({ tables: world({ conversation_messages: rows.slice(0, 3) }) });
    expect(await loadAgentDeliveries(fake.admin, OTHER, CONV, {})).toEqual([]);
    await loadAgentDeliveries(fake.admin, USER, CONV, {});
    expect(fake.calls.filter((call) => call.kind !== "select")).toEqual([]);
  });
});

describe("setAgentMessageReferent (AC-4): SQL 함수는 대화를 보지 않으므로 이 대화의 사용자 메시지인지 먼저 확인한다", () => {
  const rpc = (status: string) => ({ set_agent_message_referent: () => ({ status, action_id: ACTION }) });

  it("이 대화의 내 사용자 메시지면 후보 선택을 SQL에 맡기고 결과를 돌려준다", async () => {
    for (const status of ["selected", "not_found", "already_dispatched", "expired"] as const) {
      const fake = fakeAdmin({ tables: world(), rpc: rpc(status) });
      expect(await setAgentMessageReferent(fake.admin, { userId: USER, conversationId: CONV, messageId: MSG, actionId: ACTION })).toBe(status);
      expect(fake.rpcCalls("set_agent_message_referent")[0].args).toEqual({ p_user_id: USER, p_message_id: MSG, p_action_id: ACTION });
    }
  });

  it("다른 대화의 메시지 · 남의 메시지 · 없는 메시지 · assistant 글은 not_found (SQL 0)", async () => {
    const tables = world({ conversation_messages: [messageRow(), messageRow({ id: MSG2, role: "assistant" })] });
    for (const input of [
      { userId: USER, conversationId: "c1000000-0000-4000-8000-0000000000ff", messageId: MSG },
      { userId: OTHER, conversationId: CONV, messageId: MSG },
      { userId: USER, conversationId: CONV, messageId: "a1000000-0000-4000-8000-0000000000ff" },
      { userId: USER, conversationId: CONV, messageId: MSG2 },
    ]) {
      const fake = fakeAdmin({ tables, rpc: rpc("selected") });
      expect(await setAgentMessageReferent(fake.admin, { ...input, actionId: ACTION })).toBe("not_found");
      expect(fake.rpcCalls()).toEqual([]);
    }
  });

  it("모르는 결과는 던진다", async () => {
    await expect(setAgentMessageReferent(fakeAdmin({ tables: world(), rpc: rpc("later") }).admin, { userId: USER, conversationId: CONV, messageId: MSG, actionId: ACTION })).rejects.toThrow();
  });
});

describe("loadAgentDeliveriesByIds: Send again 응답용 (이 대화 · 이 사용자의 사용자 메시지만)", () => {
  it("메시지 id별 전달 표시를 돌려준다", async () => {
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [messageRow(), messageRow({ id: MSG2, seq: 2, delivery_state: "not_sent", delivery_reason: "usage_limited" }), messageRow({ id: "a1000000-0000-4000-8000-000000000003", conversation_id: "c1000000-0000-4000-8000-0000000000ff" })] }),
    });
    expect(await loadAgentDeliveriesByIds(fake.admin, USER, CONV, [MSG, MSG2, "a1000000-0000-4000-8000-000000000003"])).toEqual({
      [MSG]: { state: "queued" },
      [MSG2]: { state: "not_sent", reason: "usage_limited" },
    });
    expect(await loadAgentDeliveriesByIds(fake.admin, USER, CONV, [])).toEqual({});
    expect(await loadAgentDeliveriesByIds(fake.admin, OTHER, CONV, [MSG])).toEqual({});
  });
});
