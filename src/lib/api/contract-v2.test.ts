import { describe, expect, it } from "vitest";

import {
  agentCapabilitySchema,
  agentEventEnvelopeSchema,
  agentEventTypeSchema,
  agentTaskStateSchema,
  billingCheckoutRequestV2Schema,
  billingRefundRequestV2Schema,
  billingRefundResponseV2Schema,
  billingStatusV2Schema,
  bridgeCommandsResponseSchema,
  bridgeEventsRequestSchema,
  bridgeHeartbeatRequestSchema,
  bridgeRegisterRequestSchema,
  CONVERSATION_MESSAGE_MAX_CHARS,
  contextMemberSchema,
  contextMembershipChangeSchema,
  contextMembershipRequestSchema,
  conversationMessageSchema,
  conversationSchema,
  createConversationRequestSchema,
  createWorkContextRequestSchema,
  memoryConfirmRequestSchema,
  memoryEditRequestSchema,
  memoryForgetRequestSchema,
  memoryItemSchema,
  memorySourceRefSchema,
  planStateSchema,
  postConversationMessageRequestSchema,
  postConversationMessageResponseSchema,
  REPORT_PREFERENCE_DEFAULTS,
  reportModeSchema,
  reportPreferencesRequestSchema,
  reportPreferencesSchema,
  reportTimeZoneSchema,
  updateWorkContextRequestSchema,
  workContextSchema,
  isCurrentMemoryItem,
} from "./contract";

// 0.2.0 계약 뼈대 (A2): route가 붙기 전에 모양을 고정한다. 에이전트 · bridge 본문(AGENT_* · BRIDGE_*)은
// TaskforceKit AgentBridgeContractsTests.swift가 같은 JSON을 디코딩한다 — 한쪽을 고치면 다른 쪽도 고친다.

const U = {
  conversation: "a1111111-1111-4111-8111-111111111111",
  message: "a2222222-2222-4222-8222-222222222222",
  reply: "a3333333-3333-4333-8333-333333333333",
  client: "a4444444-4444-4444-8444-444444444444",
  action: "a5555555-5555-4555-8555-555555555555",
  context: "a6666666-6666-4666-8666-666666666666",
  memory: "a7777777-7777-4777-8777-777777777777",
  proposal: "a8888888-8888-4888-8888-888888888888",
  source: "a9999999-9999-4999-8999-999999999999",
  bridge: "b1111111-1111-4111-8111-111111111111",
  command: "b2222222-2222-4222-8222-222222222222",
  task: "b3333333-3333-4333-8333-333333333333",
};

const boundary = (channel: string | null, verified = false) => ({ channel, verified });

/** Claude Code 서술자 예: 공식 통로는 문서로 확인, 실측 전이라 verified는 모두 false (쓰기 0) */
const AGENT_CAPABILITY = {
  adapter: "agent:claude-code",
  transport: "local_bridge",
  session: { list: false, attach_existing: true, create: true, workspace_scoped: true },
  dispatch: { ack_level: "agent", max_instruction_chars: 20000 },
  events: "push",
  question: { receive: true, answer: true },
  cancel: "requested_only",
  resume: "supported",
  enforcement: {
    approval_gate: { channel: "permission_prompt_tool", verified: false, evidence: "docs 2026-10-09, not measured" },
    target_scope: boundary("allowed_tools"),
    revocation: boundary("process_exit"),
    budget: boundary("max_budget_usd"),
  },
  cost: "estimated",
  artifacts: ["files", "diff", "text"],
};

const AGENT_EVENT_QUESTION = {
  adapter: "agent:claude-code",
  session_id: "c0ffee00-0000-4000-8000-000000000001",
  external_task_id: "turn-7",
  event_id: "evt-42",
  seq: 42,
  type: "question",
  directive_version: 2,
  payload: { kind: "approval", question_id: "q-1", tool: "Bash", target: "git push" },
  observed_at: "2026-10-09T05:00:00.123Z",
};

const BRIDGE_COMMANDS = {
  commands: [
    {
      id: U.command,
      bridge_id: U.bridge,
      kind: "dispatch",
      payload: { bundle_hash: "sha256:abc", marker: "tf-1" },
      lease_until: "2026-10-09T05:00:25+00:00",
      acked_at: null,
      created_at: "2026-10-09T05:00:00.123456+00:00",
    },
  ],
};

const BRIDGE_HEARTBEAT = {
  bridge_id: U.bridge,
  sent_at: "2026-10-09T05:00:30Z",
  tasks: [{ task_id: U.task, process_alive: true, last_seq: 42 }],
};

describe("대화 v2", () => {
  const message = {
    id: U.message,
    conversation_id: U.conversation,
    seq: 1,
    role: "user",
    client_message_id: U.client,
    text: "디자인 확정 뒤 개발 시작해",
    refs: { action_ids: [], run_ids: [], artifact_ids: [], suggestion_ids: [], dependency_ids: [], memory_item_ids: [], context_ids: [], proposal: null },
    intent: { kind: "inform", confidence: 0.92, judge_version: "intent-v1" },
    created_at: "2026-10-09T05:00:00Z",
  };

  it("대화 행 · 만들기 요청", () => {
    const row = {
      id: U.conversation,
      title: "Shape",
      context_id: U.context,
      created_at: "2026-10-09T05:00:00Z",
      last_message_at: null,
      last_read_at: null,
      archived_at: null,
      text_purged_at: null,
    };
    expect(conversationSchema.parse(row)).toEqual(row);
    expect(createConversationRequestSchema.parse({})).toEqual({});
    expect(createConversationRequestSchema.parse({ title: " Shape ", context_id: null })).toEqual({ title: "Shape", context_id: null });
    expect(createConversationRequestSchema.safeParse({ title: "" }).success).toBe(false);
    expect(createConversationRequestSchema.safeParse({ user_id: U.action }).success).toBe(false);
  });

  it("메시지 보내기: client_message_id 필수 · 4,000자까지 · 모르는 키 거부", () => {
    const ok = { client_message_id: U.client, text: "  이 세 건 진행해줘 ", refs: { action_ids: [U.action] } };
    expect(postConversationMessageRequestSchema.parse(ok)).toEqual({ ...ok, text: "이 세 건 진행해줘" });
    expect(postConversationMessageRequestSchema.safeParse({ client_message_id: U.client, text: "가".repeat(CONVERSATION_MESSAGE_MAX_CHARS) }).success).toBe(true);
    expect(CONVERSATION_MESSAGE_MAX_CHARS).toBe(4000);
    for (const bad of [
      { client_message_id: U.client, text: "가".repeat(4001) },
      { client_message_id: U.client, text: "   " },
      { text: "안녕" },
      { client_message_id: "not-a-uuid", text: "안녕" },
      { client_message_id: U.client, text: "안녕", intent: { kind: "instruct" } },
      { client_message_id: U.client, text: "안녕", refs: { memory_item_ids: [U.memory] } },
    ]) {
      expect(postConversationMessageRequestSchema.safeParse(bad).success, JSON.stringify(bad).slice(0, 80)).toBe(false);
    }
  });

  it("메시지 행: refs의 빠진 목록은 빈 목록, memory_item_ids · context_ids · proposal을 담는다", () => {
    expect(conversationMessageSchema.parse(message)).toEqual(message);
    const sparse = conversationMessageSchema.parse({ ...message, refs: { context_ids: [U.context] }, intent: null });
    expect(sparse.refs).toEqual({ ...message.refs, context_ids: [U.context] });
    const withProposal = conversationMessageSchema.parse({
      ...message,
      refs: { ...message.refs, memory_item_ids: [U.memory], proposal: { id: U.proposal, kind: "create_action", payload_hash: "sha256:1", state: "open" } },
    });
    expect(withProposal.refs.proposal?.state).toBe("open");
    expect(conversationMessageSchema.safeParse({ ...message, refs: { ...message.refs, proposal: { id: U.proposal, kind: "remember", payload_hash: "x", state: "open" } } }).success).toBe(false);
    expect(conversationMessageSchema.safeParse({ ...message, role: "system" }).success).toBe(false);
  });

  it.each(["lookup", "consult", "adopt", "instruct", "modify", "answer", "stop", "preference", "inform", "correct", "other"])("의도 %s", (kind) => {
    expect(conversationMessageSchema.safeParse({ ...message, intent: { ...message.intent, kind } }).success).toBe(true);
  });

  it("의도 확신은 0–1, 모르는 의도는 거부", () => {
    expect(conversationMessageSchema.safeParse({ ...message, intent: { ...message.intent, kind: "delete" } }).success).toBe(false);
    expect(conversationMessageSchema.safeParse({ ...message, intent: { ...message.intent, confidence: 1.2 } }).success).toBe(false);
  });

  it("응답: 저장한 사용자 메시지 + assistant 답 (segments 등급 T1–T5 · 인용 · refs)", () => {
    const body = {
      message,
      reply: {
        ...message,
        id: U.reply,
        seq: 2,
        role: "assistant",
        client_message_id: null,
        text: "기억했어요. Shape 범위에 적용했어요.",
        refs: { ...message.refs, memory_item_ids: [U.memory], context_ids: [U.context] },
        intent: null,
        segments: [
          { text: "기억했어요. ", tier: "T2" },
          { text: "Shape 범위에 적용했어요.", tier: "T5" },
        ],
        citations: [
          { action_id: null, source_id: U.source, source_title: "주간 회의", source_kind: "meeting", occurred_at: null, external_url: null, quote: "디자인 확정" },
        ],
      },
    };
    expect(postConversationMessageResponseSchema.parse(body)).toEqual(body);
    for (const tier of ["T1", "T3", "T4"]) {
      expect(postConversationMessageResponseSchema.safeParse({ ...body, reply: { ...body.reply, segments: [{ text: "x", tier }] } }).success).toBe(true);
    }
    expect(postConversationMessageResponseSchema.safeParse({ ...body, reply: { ...body.reply, segments: [{ text: "x", tier: "T6" }] } }).success).toBe(false);
    expect(postConversationMessageResponseSchema.safeParse({ ...body, reply: { ...body.reply, role: "event" } }).success).toBe(false);
  });
});

describe("기억 (memory_items)", () => {
  const row = {
    id: U.memory,
    kind: "condition",
    scope_kind: "context",
    context_id: U.context,
    action_id: null,
    person_id: null,
    agent_adapter: null,
    statement: "디자인 확정 뒤 개발 시작",
    value: { start_after: { kind: "design_approved" } },
    origin: "explicit",
    source_ref: { message_id: U.message },
    observed_at: "2026-10-09T05:00:00Z",
    valid_from: null,
    valid_until: null,
    superseded_by: null,
    superseded_at: null,
    revoked_at: null,
    confidence: null,
    source_purged: false,
    version: 1,
    created_at: "2026-10-09T05:00:00Z",
    updated_at: "2026-10-09T05:00:00Z",
  };

  it("행 모양 (DB 열과 같다)", () => {
    expect(memoryItemSchema.parse(row)).toEqual(row);
    const observed = { ...row, origin: "observed", source_ref: { source_id: U.source, quote: "디자인 확정" }, statement: "", source_purged: true };
    expect(memoryItemSchema.parse(observed)).toEqual(observed);
    expect(memoryItemSchema.safeParse({ ...row, kind: "preference" }).success).toBe(false);
    expect(memoryItemSchema.safeParse({ ...row, scope_kind: "team" }).success).toBe(false);
    expect(memoryItemSchema.safeParse({ ...row, origin: "user" }).success).toBe(false);
  });

  it("지금 쓰는 기억 = 정정 · 잊기 시각이 모두 없음. 정정한 새 항목이 지워져 포인터가 비어도 옛 항목은 지금 것이 아니다", () => {
    expect(isCurrentMemoryItem(row)).toBe(true);
    const corrected = { ...row, superseded_by: U.context, superseded_at: "2026-10-09T06:00:00Z" };
    expect(isCurrentMemoryItem(memoryItemSchema.parse(corrected))).toBe(false);
    // 새 항목이 지워진 뒤 (on delete set null)
    expect(isCurrentMemoryItem(memoryItemSchema.parse({ ...corrected, superseded_by: null }))).toBe(false);
    expect(isCurrentMemoryItem(memoryItemSchema.parse({ ...row, revoked_at: "2026-10-09T06:00:00Z" }))).toBe(false);
    expect(memoryItemSchema.safeParse({ ...row, superseded_at: undefined }).success).toBe(false);
  });

  it("출처는 원문 id를 하나 이상", () => {
    expect(memorySourceRefSchema.safeParse({ quote: "인용만" }).success).toBe(false);
    expect(memorySourceRefSchema.safeParse({ event_id: "123" }).success).toBe(true);
    expect(memorySourceRefSchema.safeParse({ artifact_id: U.memory }).success).toBe(true);
  });

  it("확인 · 정정 · 잊기 요청은 expected_version을 싣는다", () => {
    expect(memoryConfirmRequestSchema.parse({ expected_version: 1 })).toEqual({ expected_version: 1 });
    expect(memoryForgetRequestSchema.safeParse({ expected_version: 0 }).success).toBe(false);
    expect(memoryForgetRequestSchema.safeParse({}).success).toBe(false);
    expect(memoryEditRequestSchema.parse({ expected_version: 2, statement: " 이제는 기획 확정 뒤 " })).toEqual({ expected_version: 2, statement: "이제는 기획 확정 뒤" });
    expect(
      memoryEditRequestSchema.safeParse({ expected_version: 2, statement: "x", valid_from: "2026-10-10T00:00:00Z", valid_until: "2026-10-09T00:00:00Z" }).success,
    ).toBe(false);
    expect(memoryEditRequestSchema.safeParse({ expected_version: 2, statement: "x".repeat(1001) }).success).toBe(false);
    expect(memoryEditRequestSchema.safeParse({ expected_version: 2, statement: "x", origin: "explicit" }).success).toBe(false);
  });
});

describe("범위 (work_contexts · context_members)", () => {
  it("범위 행 · 만들기 · 바꾸기", () => {
    const row = {
      id: U.context,
      name: "Shape 출시 준비",
      kind: "project",
      status: "active",
      context_version: 3,
      last_activity_at: "2026-10-09T05:00:00Z",
      created_at: "2026-10-01T05:00:00Z",
      updated_at: "2026-10-09T05:00:00Z",
    };
    expect(workContextSchema.parse(row)).toEqual(row);
    expect(workContextSchema.safeParse({ ...row, kind: "team" }).success).toBe(false);
    expect(createWorkContextRequestSchema.parse({ name: " Shape ", kind: "client" })).toEqual({ name: "Shape", kind: "client" });
    expect(createWorkContextRequestSchema.safeParse({ name: "Shape" }).success).toBe(false);
    expect(updateWorkContextRequestSchema.parse({ status: "archived" })).toEqual({ status: "archived" });
    expect(updateWorkContextRequestSchema.safeParse({}).success).toBe(false);
    expect(updateWorkContextRequestSchema.safeParse({ context_version: 4 }).success).toBe(false);
  });

  it("멤버 행: 종류마다 열 하나", () => {
    const member = {
      id: U.memory,
      context_id: U.context,
      member_kind: "action",
      action_id: U.action,
      source_id: null,
      person_id: null,
      origin: "auto",
      confidence: null,
      removed_at: null,
      created_at: "2026-10-09T05:00:00Z",
      updated_at: "2026-10-09T05:00:00Z",
    };
    expect(contextMemberSchema.parse(member)).toEqual(member);
    // 사용자가 뺀 멤버도 행으로 읽힌다 (자동 규칙이 다시 넣지 않게)
    const removed = { ...member, origin: "user", removed_at: "2026-10-09T06:00:00Z" };
    expect(contextMemberSchema.parse(removed)).toEqual(removed);
  });

  it("앱의 멤버십 변경에는 origin이 없다 (언제나 user). 서버 쪽 변경은 origin · confidence를 싣는다", () => {
    const target = { op: "add", member_kind: "source", member_id: U.source };
    expect(contextMembershipRequestSchema.parse(target)).toEqual(target);
    expect(contextMembershipRequestSchema.safeParse({ ...target, origin: "auto" }).success).toBe(false);
    expect(contextMembershipChangeSchema.parse({ ...target, origin: "user" })).toEqual({ ...target, origin: "user", confidence: null });
    expect(contextMembershipChangeSchema.parse({ ...target, origin: "inferred", confidence: 0.7 })).toEqual({ ...target, origin: "inferred", confidence: 0.7 });
    expect(contextMembershipChangeSchema.safeParse({ ...target, origin: "inferred" }).success).toBe(false);
    expect(contextMembershipChangeSchema.safeParse({ ...target, origin: "auto", confidence: 0.5 }).success).toBe(false);
    expect(contextMembershipChangeSchema.safeParse({ ...target, member_kind: "session", origin: "user" }).success).toBe(false);
  });
});

describe("에이전트 · bridge", () => {
  it("capability 서술자 (Boundary {channel, verified, evidence?})", () => {
    expect(agentCapabilitySchema.parse(AGENT_CAPABILITY)).toEqual(AGENT_CAPABILITY);
    expect(agentCapabilitySchema.safeParse({ ...AGENT_CAPABILITY, adapter: "claude-code" }).success).toBe(false);
    expect(agentCapabilitySchema.safeParse({ ...AGENT_CAPABILITY, transport: "websocket" }).success).toBe(false);
    expect(
      agentCapabilitySchema.safeParse({ ...AGENT_CAPABILITY, enforcement: { ...AGENT_CAPABILITY.enforcement, budget: { channel: null } } }).success,
    ).toBe(false);
  });

  it("사건 봉투: 열 가지 종류, observed_at은 시간대가 붙은 ISO", () => {
    expect(agentEventEnvelopeSchema.parse(AGENT_EVENT_QUESTION)).toEqual(AGENT_EVENT_QUESTION);
    expect(agentEventTypeSchema.options).toEqual([
      "accepted", "progress", "question", "artifact", "completed", "failed", "cancelled", "unreachable", "reconcile", "unsupported",
    ]);
    // seq · directive_version · result_revision은 선택
    const minimal = {
      adapter: "agent:claude-code",
      session_id: "s-1",
      external_task_id: "turn-1",
      event_id: "evt-1",
      type: "completed",
      payload: {},
      observed_at: "2026-10-09T05:00:00+09:00",
    };
    expect(agentEventEnvelopeSchema.parse(minimal)).toEqual(minimal);
    expect(agentEventEnvelopeSchema.safeParse({ ...AGENT_EVENT_QUESTION, type: "heartbeat" }).success).toBe(false);
    expect(agentEventEnvelopeSchema.safeParse({ ...AGENT_EVENT_QUESTION, observed_at: "2026-10-09 05:00:00" }).success).toBe(false);
    expect(agentEventEnvelopeSchema.safeParse({ ...AGENT_EVENT_QUESTION, event_id: "" }).success).toBe(false);
  });

  it("원격 작업 상태", () => {
    expect(agentTaskStateSchema.options).toEqual([
      "dispatched", "accepted", "running", "awaiting_answer", "completed", "failed", "cancelled", "unreachable",
    ]);
  });

  it("bridge 등록 · 명령 · 사건 · heartbeat", () => {
    const register = { device_id: "mac-1", app_version: "0.2.0", capabilities: [AGENT_CAPABILITY] };
    expect(bridgeRegisterRequestSchema.parse(register)).toEqual(register);
    expect(bridgeCommandsResponseSchema.parse(BRIDGE_COMMANDS)).toEqual(BRIDGE_COMMANDS);
    for (const kind of ["message", "cancel", "reconcile", "check"]) {
      expect(bridgeCommandsResponseSchema.safeParse({ commands: [{ ...BRIDGE_COMMANDS.commands[0], kind }] }).success).toBe(true);
    }
    expect(bridgeCommandsResponseSchema.safeParse({ commands: [{ ...BRIDGE_COMMANDS.commands[0], kind: "spawn" }] }).success).toBe(false);
    const events = { bridge_id: U.bridge, events: [AGENT_EVENT_QUESTION] };
    expect(bridgeEventsRequestSchema.parse(events)).toEqual(events);
    expect(bridgeEventsRequestSchema.safeParse({ bridge_id: U.bridge, events: [] }).success).toBe(false);
    expect(bridgeHeartbeatRequestSchema.parse(BRIDGE_HEARTBEAT)).toEqual(BRIDGE_HEARTBEAT);
    expect(bridgeHeartbeatRequestSchema.safeParse({ ...BRIDGE_HEARTBEAT, tasks: [{ ...BRIDGE_HEARTBEAT.tasks[0], last_seq: -1 }] }).success).toBe(false);
  });

  it("Swift(TaskforceKit)가 보내는 모양도 받는다: 대문자 UUID, 밀리초가 붙은 UTC 시각", () => {
    const fromSwift = {
      bridge_id: U.bridge.toUpperCase(),
      sent_at: "2026-10-09T05:00:30.000Z",
      tasks: [{ task_id: U.task.toUpperCase(), process_alive: true, last_seq: 42 }],
    };
    expect(bridgeHeartbeatRequestSchema.safeParse(fromSwift).success).toBe(true);
    expect(agentEventEnvelopeSchema.safeParse({ ...AGENT_EVENT_QUESTION, observed_at: "2026-10-09T05:00:00.000Z" }).success).toBe(true);
    // Swift AgentBoundary는 channel이 없으면 null을 보낸다 (키를 빼지 않는다)
    expect(agentCapabilitySchema.safeParse({ ...AGENT_CAPABILITY, enforcement: { ...AGENT_CAPABILITY.enforcement, budget: { channel: null, verified: false } } }).success).toBe(true);
  });
});

describe("결제 v2", () => {
  const status = {
    state: "lifetime",
    plan: "lifetime",
    trial_ends_at: null,
    current_period_ends_at: null,
    cancel_at: null,
    refund_until: "2026-10-12T05:00:00Z",
    can_use_ai: true,
    can_checkout: false,
    ai_usage_this_month: { since: "2026-10-01T00:00:00Z", prompt_tokens: 1200, completion_tokens: 300, total_tokens: 1500 },
  };

  it("PlanSummary 8 상태 · plan lifetime · 이번 달 토큰 사용량", () => {
    expect(planStateSchema.options).toEqual(["none", "trial", "pro", "cancelled", "past_due", "lapsed", "lifetime", "beta"]);
    expect(billingStatusV2Schema.parse(status)).toEqual(status);
    for (const state of planStateSchema.options) expect(billingStatusV2Schema.safeParse({ ...status, state }).success, state).toBe(true);
    expect(billingStatusV2Schema.safeParse({ ...status, state: "legacy_beta" }).success).toBe(false);
    expect(billingStatusV2Schema.safeParse({ ...status, ai_usage_this_month: null, plan: null, state: "none" }).success).toBe(true);
    expect(billingStatusV2Schema.safeParse({ ...status, ai_usage_this_month: { ...status.ai_usage_this_month, total_tokens: -1 } }).success).toBe(false);
  });

  it("checkout v2는 lifetime을 받고 약관 판은 문자열이다 (새 literal 없음). 환불 요청 본문은 비어 있다", () => {
    expect(billingCheckoutRequestV2Schema.parse({ plan: "lifetime", terms_version: "2026-10-09" })).toEqual({ plan: "lifetime", terms_version: "2026-10-09" });
    expect(billingCheckoutRequestV2Schema.safeParse({ plan: "lifetime", terms_version: "" }).success).toBe(false);
    expect(billingCheckoutRequestV2Schema.safeParse({ plan: "weekly", terms_version: "x" }).success).toBe(false);
    expect(billingRefundRequestV2Schema.parse({})).toEqual({});
    expect(billingRefundRequestV2Schema.safeParse({ order_id: "1" }).success).toBe(false);
    expect(billingRefundResponseV2Schema.parse({ requested: true })).toEqual({ requested: true });
  });
});

describe("보고 설정 (H1)", () => {
  it("모드 셋과 D06 기본값 (Both · 08:30 · 22:00–08:00 · Respect Focus 켬, 시간대 기본값 없음)", () => {
    expect(reportModeSchema.options).toEqual(["both", "daily", "meaningful"]);
    expect(REPORT_PREFERENCE_DEFAULTS).toEqual({ mode: "both", daily_time: "08:30", quiet_start: "22:00", quiet_end: "08:00", respect_focus: true });
    expect("time_zone" in REPORT_PREFERENCE_DEFAULTS).toBe(false);
  });

  it("시간대는 IANA 이름을 받은 그대로 (고정 오프셋 · 없는 이름은 거부)", () => {
    for (const tz of ["Asia/Seoul", "Europe/London", "America/Argentina/Buenos_Aires", "America/Port-au-Prince", "UTC", "Etc/GMT+9"]) {
      expect(reportTimeZoneSchema.parse(tz), tz).toBe(tz);
    }
    for (const tz of ["+09:00", "-05:00", "UTC+9", "Mars/Base", "", "Asia/Seoul ", "../etc/passwd", "a".repeat(65)]) {
      expect(reportTimeZoneSchema.safeParse(tz).success, tz).toBe(false);
    }
  });

  it("요청 · 응답 모양: 조용한 시간 끄기는 둘 다 null, 응답의 시간대 · version은 저장 전이면 null", () => {
    const request = { mode: "both", daily_time: "08:30", quiet_start: null, quiet_end: null, respect_focus: true, time_zone: "Asia/Seoul", expected_version: null };
    expect(reportPreferencesRequestSchema.parse(request)).toEqual(request);
    expect(reportPreferencesRequestSchema.parse({ ...request, expected_version: 3 }).expected_version).toBe(3);
    expect(reportPreferencesRequestSchema.safeParse({ ...request, quiet_start: "22:00" }).success).toBe(false);
    // expected_version은 꼭 보낸다 (처음이면 null). 0 · 소수는 거부
    const { expected_version: _omitted, ...withoutVersion } = request;
    void _omitted;
    expect(reportPreferencesRequestSchema.safeParse(withoutVersion).success).toBe(false);
    for (const bad of [0, 1.5, "1"]) expect(reportPreferencesRequestSchema.safeParse({ ...request, expected_version: bad }).success, String(bad)).toBe(false);
    expect(reportPreferencesSchema.parse({ ...REPORT_PREFERENCE_DEFAULTS, time_zone: null, saved: false, version: null })).toMatchObject({ time_zone: null, saved: false, version: null });
  });
});
