import { describe, expect, it } from "vitest";

import {
  agentAccessSchema,
  agentAttachErrorCodeSchema,
  agentConversationErrorCodeSchema,
  agentConversationMessageSchema,
  agentDeliveryReasonSchema,
  agentDeliverySchema,
  agentDeliveryStateSchema,
  agentEmptyRequestSchema,
  agentSessionResponseSchema,
  agentSessionSchema,
  agentStopResponseSchema,
  agentTargetStateSchema,
  answerAgentQuestionRequestSchema,
  answerAgentQuestionResponseSchema,
  apiErrorV2AgentCodeSchema,
  apiErrorV2CodeSchema,
  assistantTargetsResponseSchema,
  assistantTargetsWithDeviceResponseSchema,
  attachmentDroppedSchema,
  attachmentKindSchema,
  attachmentOriginSchema,
  attachmentSchema,
  bridgeV1HeartbeatRequestSchema,
  bridgeV1HeartbeatRequestWithDeviceSchema,
  bridgeV1RegisterRequestSchema,
  bridgeV1RegisterRequestWithDeviceSchema,
  conversationDeliveryResponseSchema,
  conversationTargetKindSchema,
  conversationTargetSchema,
  conversationWithTargetSchema,
  createConversationRequestSchema,
  createConversationV2RequestSchema,
  createConversationV2ResponseSchema,
  deliverAgentMessagesRequestSchema,
  deliverAgentMessagesResponseSchema,
  postAgentMessageResponseSchema,
  postConversationMessageRequestSchema,
  postConversationMessageV2RequestSchema,
  resumeAgentSessionRequestSchema,
  resumeAgentSessionResponseSchema,
  setReferentRequestSchema,
  updateAgentSessionRequestSchema,
} from "@/lib/api/contract";

// OA D1d-s 대화 API v2 확장의 모양 (Assistant 계약 v3 2–5장). 아래 AGENT_CONVERSATION_* 상수는 Swift 시험
// (TaskforceKit AgentConversationContractsTests.swift, D1d-m)이 같은 JSON을 디코딩한다 — 한쪽을 고치면 다른 쪽도 고친다.
// 결정적 Action id는 UUID 버전 비트가 없다: 응답 · 입력의 Action id는 z.guid()다 (src/lib/agents/turns.ts).
// (계약 4장은 이 시험을 src/lib/api/contract-v2-agent-conversation.test.ts로 적었으나 허용 파일 목록에 없어 agents/ 아래에 둔다 — handoffs/oa-d1d-notes.md 이탈 항목)

const U = {
  conversation: "a1111111-1111-4111-8111-111111111111",
  message: "a2222222-2222-4222-8222-222222222222",
  connection: "a3333333-3333-4333-8333-333333333333",
  session: "a4444444-4444-4444-8444-444444444444",
  task: "a5555555-5555-4555-8555-555555555555",
  step: "a6666666-6666-4666-8666-666666666666",
  context: "a7777777-7777-4777-8777-777777777777",
  bridge: "a9999999-9999-4999-8999-999999999999",
  second: "a8888888-8888-4888-8888-888888888888",
  /** 메시지 id에서 결정적으로 만든 Action id: 버전 · 변형 비트가 없다 */
  deterministic: "f0000000-0000-f000-f000-000000000001",
};
const NOW = "2026-10-14T01:00:00.000Z";

export const AGENT_CONVERSATION_USER_MESSAGE = {
  id: U.message,
  conversation_id: U.conversation,
  seq: 1,
  role: "user",
  client_message_id: U.second,
  text: "이어서 해 줘",
  refs: { action_ids: [], run_ids: [], artifact_ids: [], suggestion_ids: [], dependency_ids: [], memory_item_ids: [], context_ids: [], proposal: null },
  intent: null,
  created_at: NOW,
  reply_to: null,
  content: null,
  delivery_state: "dispatched",
  delivery_reason: null,
  delivery_expires_at: "2026-10-15T01:00:00.000Z",
};

export const AGENT_CONVERSATION_POST_RESPONSE = {
  message: AGENT_CONVERSATION_USER_MESSAGE,
  reply: null,
  delivery: { state: "sent" },
  attachments_dropped: [{ kind: "source", id: U.second, reason: "slack_purged" }],
  created_action: { id: U.deterministic, number: 139, title: "이어서 해 줘", context_id: U.context },
  agent_task: { id: U.task, state: "dispatched", agent_session_id: U.session },
};

export const AGENT_CONVERSATION_NEEDS_REFERENT = {
  ...AGENT_CONVERSATION_POST_RESPONSE,
  message: { ...AGENT_CONVERSATION_USER_MESSAGE, delivery_state: "queued" },
  delivery: { state: "needs_referent", candidates: [{ action_id: U.deterministic, title: "가격 문구" }, { action_id: U.second, title: "온보딩" }] },
  attachments_dropped: [],
  created_action: null,
  agent_task: null,
};

export const AGENT_CONVERSATION_DELIVER_RESPONSE = {
  messages: [
    { message_id: U.message, result: "requeued", delivery: { state: "queued", reason: "session_busy" } },
    { message_id: U.second, result: "skipped", skipped_reason: "unknown_outcome", delivery: { state: "unknown" } },
    { message_id: U.task, result: "skipped", skipped_reason: "not_found" },
  ],
};

export const AGENT_CONVERSATION_STOP_RESPONSE = {
  tasks: [{ agent_task_id: U.task, cancel: "requested_only", processes: "may_continue" }, { agent_task_id: U.step, cancel: "confirmed" }],
};

export const AGENT_CONVERSATION_SESSION = {
  session: { id: U.session, connection_id: U.connection, display_name: "Pricing copy", status: "external", last_turn_seq: 3, updated_at: NOW },
};

export const AGENT_CONVERSATION_RESUME_RESPONSE = { ...AGENT_CONVERSATION_SESSION, started_message_id: U.message };

export const AGENT_CONVERSATION_TARGETS = {
  targets: [
    { kind: "taskforce" },
    { kind: "agent", adapter: "agent:claude-code", display_name: "Claude Code", connection_id: U.connection, state: "unsupported", access: null },
    { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only" },
  ],
};

/** F1s: 대상 행마다 기기 이름 · bridge id. F1m의 Swift 시험이 같은 JSON을 디코딩한다 (옛 AGENT_CONVERSATION_TARGETS는 F1s 전 응답의 기록으로 그대로 둔다) */
export const AGENT_CONVERSATION_TARGETS_WITH_DEVICE = {
  targets: [
    { kind: "taskforce" },
    { kind: "agent", adapter: "agent:claude-code", display_name: "Claude Code", connection_id: U.connection, state: "unsupported", access: null, device_name: "Studio", bridge_id: U.bridge },
    { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: U.second, state: "ready", access: "read_only", device_name: null, bridge_id: U.bridge },
    { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only", device_name: null, bridge_id: null },
  ],
};

export const AGENT_CONVERSATION_ANSWER_RESPONSE = { status: "answered", step_id: U.deterministic };

export const AGENT_CONVERSATION_DELIVERY_READ = {
  messages: [{ message_id: U.message, seq: 1, delivery: { state: "accepted" } }, { message_id: U.second, seq: 2, delivery: { state: "not_sent", reason: "usage_limited" } }],
};

export const AGENT_CONVERSATION_CREATE_RESPONSE = {
  conversation: {
    id: U.conversation, title: null, context_id: null, created_at: NOW, last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null,
    target_kind: "agent", agent_connection_id: U.connection, agent_session_id: null,
  },
};

describe("대화 대상", () => {
  it("대상은 taskforce 또는 agent(연결 필수, 세션 선택)다", () => {
    expect(conversationTargetKindSchema.options).toEqual(["taskforce", "agent"]);
    expect(conversationTargetSchema.parse({ kind: "taskforce" })).toEqual({ kind: "taskforce" });
    expect(conversationTargetSchema.parse({ kind: "agent", connection_id: U.connection })).toEqual({ kind: "agent", connection_id: U.connection });
    expect(conversationTargetSchema.parse({ kind: "agent", connection_id: U.connection, session_id: U.session }).kind).toBe("agent");
    for (const bad of [{ kind: "agent" }, { kind: "agent", connection_id: "x" }, { kind: "taskforce", connection_id: U.connection }, { kind: "other" }, { kind: "agent", connection_id: U.connection, extra: 1 }]) {
      expect(conversationTargetSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("만들기 요청: 기존 필드 + target(선택). 기존 요청 스키마는 그대로 target을 거절한다", () => {
    expect(createConversationV2RequestSchema.parse({})).toEqual({});
    expect(createConversationV2RequestSchema.parse({ id: U.conversation, title: "t", context_id: null, target: { kind: "taskforce" } }).target).toEqual({ kind: "taskforce" });
    expect(createConversationV2RequestSchema.safeParse({ target: { kind: "agent", connection_id: U.connection }, extra: 1 }).success).toBe(false);
    expect(createConversationRequestSchema.safeParse({ target: { kind: "taskforce" } }).success).toBe(false);
  });

  it("만들기 응답: 기존 대화 행 + target_kind · agent_connection_id · agent_session_id", () => {
    expect(createConversationV2ResponseSchema.parse(AGENT_CONVERSATION_CREATE_RESPONSE)).toEqual(AGENT_CONVERSATION_CREATE_RESPONSE);
    expect(conversationWithTargetSchema.safeParse({ ...AGENT_CONVERSATION_CREATE_RESPONSE.conversation, target_kind: "x" }).success).toBe(false);
    const withoutTarget: Record<string, unknown> = { ...AGENT_CONVERSATION_CREATE_RESPONSE.conversation };
    delete withoutTarget.target_kind;
    expect(conversationWithTargetSchema.safeParse(withoutTarget).success).toBe(false);
  });
});

describe("맥락 칩 (attachments)", () => {
  it("종류 여섯 · 출처 둘, strict", () => {
    expect(attachmentKindSchema.options).toEqual(["action", "context", "agent_session", "run", "artifact", "source"]);
    expect(attachmentOriginSchema.options).toEqual(["auto", "added"]);
    expect(attachmentSchema.parse({ kind: "action", id: U.deterministic, origin: "added" }).id).toBe(U.deterministic);
    for (const bad of [{ kind: "decision", id: U.task, origin: "added" }, { kind: "action", id: "x", origin: "added" }, { kind: "action", id: U.task, origin: "manual" }, { kind: "action", id: U.task, origin: "added", extra: 1 }]) {
      expect(attachmentSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("요청: 기존 필드 + attachments(≤ 20). refs와 attachments를 함께 보내면 거절(OD-4). 기존 요청 스키마는 attachments를 거절한다", () => {
    const base = { client_message_id: U.second, text: "안녕" };
    const chip = { kind: "context", id: U.context, origin: "auto" };
    expect(postConversationMessageV2RequestSchema.parse(base)).toEqual(base);
    expect(postConversationMessageV2RequestSchema.parse({ ...base, attachments: [chip] }).attachments).toEqual([chip]);
    expect(postConversationMessageV2RequestSchema.parse({ ...base, refs: { action_ids: [U.task] } }).refs).toEqual({ action_ids: [U.task] });
    expect(postConversationMessageV2RequestSchema.safeParse({ ...base, refs: {}, attachments: [chip] }).success).toBe(false);
    expect(postConversationMessageV2RequestSchema.safeParse({ ...base, attachments: Array.from({ length: 21 }, () => chip) }).success).toBe(false);
    expect(postConversationMessageV2RequestSchema.parse({ ...base, attachments: Array.from({ length: 20 }, () => chip) }).attachments).toHaveLength(20);
    expect(postConversationMessageV2RequestSchema.safeParse({ ...base, extra: 1 }).success).toBe(false);
    expect(postConversationMessageRequestSchema.safeParse({ ...base, attachments: [chip] }).success).toBe(false);
  });
});

describe("전달 표시", () => {
  it("상태 아홉, 이유는 계약 아홉 + SQL이 쓰는 여덟 + 읽을 때 계산하는 하나(billing_required: 만료된 계정이 멈춘 것)의 합 열여덟", () => {
    expect(agentDeliveryStateSchema.options).toEqual(["answered", "queued", "needs_referent", "not_sent", "expired", "cancelled", "sent", "accepted", "unknown"]);
    expect([...agentDeliveryReasonSchema.options].sort()).toEqual(
      [
        "not_connected", "sign_in_needed", "unsupported", "write_gate_closed", "session_external", "version_unsupported", "usage_limited", "spawn_failed", "not_received",
        "session_busy", "live_limit", "queue_order", "session_closed", "invalid_referent", "not_found", "already_dispatched", "question_open", "billing_required",
      ].sort(),
    );
    expect(agentDeliveryReasonSchema.options).toHaveLength(18);
  });

  it("delivery: state + reason? + candidates?(≤ 3), strict", () => {
    expect(agentDeliverySchema.parse({ state: "sent" })).toEqual({ state: "sent" });
    expect(agentDeliverySchema.parse(AGENT_CONVERSATION_NEEDS_REFERENT.delivery).candidates).toHaveLength(2);
    for (const bad of [{ state: "done" }, { state: "queued", reason: "other" }, { state: "sent", extra: 1 }, { state: "needs_referent", candidates: Array.from({ length: 4 }, () => ({ action_id: U.task, title: "t" })) }]) {
      expect(agentDeliverySchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("에이전트 대화 메시지는 기존 메시지 + delivery_state · delivery_reason · delivery_expires_at", () => {
    expect(agentConversationMessageSchema.parse(AGENT_CONVERSATION_USER_MESSAGE)).toEqual(AGENT_CONVERSATION_USER_MESSAGE);
    expect(agentConversationMessageSchema.safeParse({ ...AGENT_CONVERSATION_USER_MESSAGE, delivery_state: "sent" }).success).toBe(false);
  });
});

describe("응답", () => {
  it("보내기 응답: reply는 null, created_action.id는 버전 비트 없는 id도 받는다, number는 null 가능", () => {
    const parsed = postAgentMessageResponseSchema.parse(AGENT_CONVERSATION_POST_RESPONSE);
    expect(parsed.created_action?.id).toBe(U.deterministic);
    expect(postAgentMessageResponseSchema.parse({ ...AGENT_CONVERSATION_POST_RESPONSE, created_action: { ...AGENT_CONVERSATION_POST_RESPONSE.created_action, number: null } }).created_action?.number).toBeNull();
    expect(postAgentMessageResponseSchema.parse(AGENT_CONVERSATION_NEEDS_REFERENT).agent_task).toBeNull();
    expect(postAgentMessageResponseSchema.safeParse({ ...AGENT_CONVERSATION_POST_RESPONSE, reply: { id: U.message } }).success).toBe(false);
    expect(postAgentMessageResponseSchema.safeParse({ ...AGENT_CONVERSATION_POST_RESPONSE, attachments_dropped: [{ kind: "source", id: U.task, reason: "gone" }] }).success).toBe(false);
  });

  it("dropped 이유는 deleted · access_lost · slack_purged", () => {
    for (const reason of ["deleted", "access_lost", "slack_purged"]) expect(attachmentDroppedSchema.parse({ kind: "run", id: U.task, reason }).reason).toBe(reason);
  });

  it("Send again: 요청은 message_ids 1–50(선택), 응답 항목은 requeued · skipped(+ 이유)", () => {
    expect(deliverAgentMessagesRequestSchema.parse({})).toEqual({});
    expect(deliverAgentMessagesRequestSchema.parse({ message_ids: [U.message] }).message_ids).toHaveLength(1);
    expect(deliverAgentMessagesRequestSchema.safeParse({ message_ids: [] }).success).toBe(false);
    expect(deliverAgentMessagesRequestSchema.safeParse({ message_ids: Array.from({ length: 51 }, () => U.message) }).success).toBe(false);
    expect(deliverAgentMessagesRequestSchema.safeParse({ message_ids: [U.message], extra: 1 }).success).toBe(false);
    expect(deliverAgentMessagesResponseSchema.parse(AGENT_CONVERSATION_DELIVER_RESPONSE)).toEqual(AGENT_CONVERSATION_DELIVER_RESPONSE);
    expect(deliverAgentMessagesResponseSchema.safeParse({ messages: [{ message_id: U.message, result: "skipped", skipped_reason: "later" }] }).success).toBe(false);
  });

  it("referent 요청은 action_id 하나 (버전 비트 없는 id도 받는다)", () => {
    expect(setReferentRequestSchema.parse({ action_id: U.deterministic })).toEqual({ action_id: U.deterministic });
    expect(setReferentRequestSchema.safeParse({}).success).toBe(false);
    expect(setReferentRequestSchema.safeParse({ action_id: U.task, extra: 1 }).success).toBe(false);
  });

  it("Stop 응답: 작업마다 cancel 결과, processes는 may_continue뿐", () => {
    expect(agentStopResponseSchema.parse(AGENT_CONVERSATION_STOP_RESPONSE)).toEqual(AGENT_CONVERSATION_STOP_RESPONSE);
    expect(agentStopResponseSchema.parse({ tasks: [] })).toEqual({ tasks: [] });
    expect(agentStopResponseSchema.safeParse({ tasks: [{ agent_task_id: U.task, cancel: "done" }] }).success).toBe(false);
    expect(agentStopResponseSchema.safeParse({ tasks: [{ agent_task_id: U.task, cancel: "confirmed", processes: "stopped" }] }).success).toBe(false);
    expect(agentEmptyRequestSchema.parse({})).toEqual({});
    expect(agentEmptyRequestSchema.safeParse({ a: 1 }).success).toBe(false);
  });

  it("세션: 이름 바꾸기 요청은 trim 1–200자, 응답 세션 모양, Resume here 본문은 confirmed_terminal_closed: true", () => {
    expect(updateAgentSessionRequestSchema.parse({ display_name: "  Pricing  " })).toEqual({ display_name: "Pricing" });
    for (const bad of [{ display_name: "   " }, { display_name: "x".repeat(201) }, {}, { display_name: "a", extra: 1 }]) expect(updateAgentSessionRequestSchema.safeParse(bad).success).toBe(false);
    expect(updateAgentSessionRequestSchema.parse({ display_name: "x".repeat(200) }).display_name).toHaveLength(200);
    expect(agentSessionSchema.parse(AGENT_CONVERSATION_SESSION.session)).toEqual(AGENT_CONVERSATION_SESSION.session);
    expect(agentSessionResponseSchema.parse(AGENT_CONVERSATION_SESSION)).toEqual(AGENT_CONVERSATION_SESSION);
    expect(agentSessionSchema.safeParse({ ...AGENT_CONVERSATION_SESSION.session, status: "paused" }).success).toBe(false);
    expect(resumeAgentSessionRequestSchema.parse({ confirmed_terminal_closed: true })).toEqual({ confirmed_terminal_closed: true });
    for (const bad of [{ confirmed_terminal_closed: false }, {}, { confirmed_terminal_closed: "true" }]) expect(resumeAgentSessionRequestSchema.safeParse(bad).success).toBe(false);
    expect(resumeAgentSessionResponseSchema.parse(AGENT_CONVERSATION_RESUME_RESPONSE)).toEqual(AGENT_CONVERSATION_RESUME_RESPONSE);
    expect(resumeAgentSessionResponseSchema.parse({ ...AGENT_CONVERSATION_SESSION, started_message_id: null }).started_message_id).toBeNull();
  });

  it("대상 목록: taskforce + agent(adapter · display_name · connection_id? · state · access)", () => {
    expect(agentTargetStateSchema.options).toEqual(["ready", "not_connected", "sign_in_needed", "unreachable", "unsupported"]);
    expect(agentAccessSchema.options).toEqual(["write", "read_only"]);
    expect(assistantTargetsResponseSchema.parse(AGENT_CONVERSATION_TARGETS)).toEqual(AGENT_CONVERSATION_TARGETS);
    expect(assistantTargetsResponseSchema.safeParse({ targets: [{ kind: "agent", adapter: "codex", display_name: "Codex", connection_id: null, state: "ready", access: null }] }).success).toBe(false);
  });

  it("F1s 대상 목록: agent 행에 device_name(1–64 코드 포인트 또는 null) · bridge_id(guid 또는 null)가 더해진다 (C5)", () => {
    expect(assistantTargetsWithDeviceResponseSchema.parse(AGENT_CONVERSATION_TARGETS_WITH_DEVICE)).toEqual(AGENT_CONVERSATION_TARGETS_WITH_DEVICE);
    // F1s 전 응답의 기록: 옛 fixture는 옛 스키마로 그대로 통과하고, 옛 스키마는 새 키를 strict로 거절한다
    expect(assistantTargetsResponseSchema.parse(AGENT_CONVERSATION_TARGETS)).toEqual(AGENT_CONVERSATION_TARGETS);
    expect(assistantTargetsResponseSchema.safeParse(AGENT_CONVERSATION_TARGETS_WITH_DEVICE).success).toBe(false);
    // 새 스키마는 키가 모두 있어야 한다 (서버는 항상 낸다)
    expect(assistantTargetsWithDeviceResponseSchema.safeParse(AGENT_CONVERSATION_TARGETS).success).toBe(false);
    const agent = AGENT_CONVERSATION_TARGETS_WITH_DEVICE.targets[1];
    const row = (extra: Record<string, unknown>) => assistantTargetsWithDeviceResponseSchema.safeParse({ targets: [{ ...agent, ...extra }] }).success;
    expect(row({ device_name: "\u{1f34e}".repeat(64) })).toBe(true);
    for (const bad of ["", "\u{1f34e}".repeat(65), 5, undefined]) expect(row({ device_name: bad }), JSON.stringify(bad)).toBe(false);
    for (const bad of ["not-a-guid", 5, undefined]) expect(row({ bridge_id: bad }), JSON.stringify(bad)).toBe(false);
    expect(row({ hostname: "mac.local" })).toBe(false);
    expect(assistantTargetsWithDeviceResponseSchema.safeParse({ targets: [{ kind: "taskforce", device_name: null }] }).success).toBe(false);
  });

  it("F1s 요청: register · heartbeat의 device_name은 선택이고 원문 256 코드 포인트까지다. 모르는 키는 여전히 거절한다 (C5)", () => {
    const register = { device_id: "installation-random-id", app_version: "0.2.0", adapters: [] };
    const heartbeat = { bridge_id: U.bridge, sent_at: NOW, tasks: [] };
    const cases = [
      { old: bridgeV1RegisterRequestSchema, next: bridgeV1RegisterRequestWithDeviceSchema, body: register },
      { old: bridgeV1HeartbeatRequestSchema, next: bridgeV1HeartbeatRequestWithDeviceSchema, body: heartbeat },
    ];
    for (const { old, next, body } of cases) {
      expect(old.safeParse({ ...body, device_name: "Studio" }).success).toBe(false); // 옛 스키마는 그대로 strict
      expect(next.parse(body)).toEqual(old.parse(body)); // 이름이 없으면 옛 본문과 같은 결과
      expect(next.parse({ ...body, device_name: "Studio" })).toMatchObject({ device_name: "Studio" });
      expect(next.safeParse({ ...body, device_name: "\u{1f34e}".repeat(256) }).success).toBe(true);
      for (const bad of ["\u{1f34e}".repeat(257), 5, null, ["Studio"]]) expect(next.safeParse({ ...body, device_name: bad }).success, JSON.stringify(bad)).toBe(false);
      expect(next.safeParse({ ...body, device_name: "Studio", hostname: "mac.local" }).success).toBe(false);
      expect(next.safeParse({ ...body, hostname: "mac.local" }).success).toBe(false);
    }
  });

  it("질문 답: 요청은 provider_request_id + answers(단일 글 또는 배열), 응답은 answered · duplicate + step_id", () => {
    expect(answerAgentQuestionRequestSchema.parse({ provider_request_id: "q-1", answers: { a: "x", b: ["y", "z"] } }).answers.b).toEqual(["y", "z"]);
    for (const bad of [{ answers: {} }, { provider_request_id: "", answers: {} }, { provider_request_id: "q", answers: { a: 1 } }, { provider_request_id: "q", answers: { a: "x" }, extra: 1 }, { provider_request_id: "q", answers: { a: Array.from({ length: 11 }, () => "x") } }]) {
      expect(answerAgentQuestionRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
    expect(answerAgentQuestionResponseSchema.parse(AGENT_CONVERSATION_ANSWER_RESPONSE)).toEqual(AGENT_CONVERSATION_ANSWER_RESPONSE);
    expect(answerAgentQuestionResponseSchema.safeParse({ status: "question_stale", step_id: U.step }).success).toBe(false);
  });

  it("전달 읽기 응답: 메시지마다 seq + delivery, 100개까지", () => {
    expect(conversationDeliveryResponseSchema.parse(AGENT_CONVERSATION_DELIVERY_READ)).toEqual(AGENT_CONVERSATION_DELIVERY_READ);
    expect(conversationDeliveryResponseSchema.safeParse({ messages: Array.from({ length: 101 }, (_, i) => ({ message_id: U.message, seq: i + 1, delivery: { state: "sent" } })) }).success).toBe(false);
  });
});

describe("오류 코드", () => {
  it("v2 에이전트 코드는 기존 v2 코드를 모두 포함하고 새 코드 여섯을 더하고 이어받기가 둘을 더 얹는다 (기존 목록은 그대로)", () => {
    expect(agentConversationErrorCodeSchema.options).toEqual(["target_mismatch", "question_stale", "secret_requires_local", "session_busy", "approval_via_review", "busy_retry"]);
    for (const code of apiErrorV2CodeSchema.options) expect(apiErrorV2AgentCodeSchema.options).toContain(code);
    for (const code of agentConversationErrorCodeSchema.options) expect(apiErrorV2AgentCodeSchema.options).toContain(code);
    // 이어받기(PR2s)가 둘을 더한다: session_in_use(409) · forbidden(403). 위 여섯 목록은 그대로다
    for (const code of agentAttachErrorCodeSchema.options) expect(apiErrorV2AgentCodeSchema.options).toContain(code);
    expect(apiErrorV2AgentCodeSchema.options).toHaveLength(apiErrorV2CodeSchema.options.length + agentConversationErrorCodeSchema.options.length + agentAttachErrorCodeSchema.options.length);
    expect(apiErrorV2CodeSchema.options).not.toContain("target_mismatch");
    expect(agentConversationErrorCodeSchema.options).not.toContain("session_in_use");
  });
});
