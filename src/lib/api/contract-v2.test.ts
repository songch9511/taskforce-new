import { describe, expect, it } from "vitest";

import {
  contextMembershipEffectSchema as effectSchema,
  conversationMessageContentSchema as contentSchema,
  intentKindSchema,
  messageRefsSchema,
  organizeContentSchema,
  proposalConfirmResponseSchema,
  proposalPayloadSchema,
  proposalSchema,
} from "./contract";

import {
  apiErrorCodeSchema,
  apiErrorV2CodeSchema,
  apiErrorV2Schema,
  memoryItemResponseSchema,
  memoryScopeRequestSchema,
  memoryUnavailableCodeSchema,
  updateConversationRequestSchema,
  updateConversationResponseSchema,
  agentCapabilitySchema,
  agentEventEnvelopeSchema,
  agentEventTypeSchema,
  agentSessionStatusSchema,
  agentTaskStateSchema,
  billingCheckoutRequestV2Schema,
  billingErrorCodeV2Schema,
  billingErrorV2Schema,
  billingPortalRequestV2Schema,
  billingRefundRequestV2Schema,
  billingRefundResponseV2Schema,
  billingResumeRequestV2Schema,
  billingResumeResponseV2Schema,
  billingStatusV2Schema,
  billingUrlResponseV2Schema,
  bridgeCommandsResponseSchema,
  bridgeEventsRequestSchema,
  bridgeHeartbeatRequestSchema,
  bridgeRegisterRequestSchema,
  CONVERSATION_MESSAGE_MAX_CHARS,
  contextMemberMoveRequestSchema,
  contextMemberMoveResponseSchema,
  contextMemberSchema,
  contextMembershipChangeSchema,
  contextMembershipEffectSchema,
  contextMembershipRequestSchema,
  contextMembershipResponseSchema,
  contextMembershipWriteRequestSchema,
  conversationMessageContentSchema,
  conversationMessageSchema,
  conversationSchema,
  createConversationRequestSchema,
  createConversationResponseSchema,
  createWorkContextRequestSchema,
  projectIconSchema,
  memoryConfirmRequestSchema,
  memoryEditRequestSchema,
  memoryForgetRequestSchema,
  memoryItemSchema,
  memorySourceRefSchema,
  planStateSchema,
  postConversationMessageRequestSchema,
  postConversationMessageResponseSchema,
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

it("accepts optional direct-chat descriptor fields without changing legacy capability DTOs", () => {
  expect(agentCapabilitySchema.parse(AGENT_CAPABILITY)).toEqual(AGENT_CAPABILITY);
  const extended = {
    ...AGENT_CAPABILITY,
    display_name: "Claude Code",
    sign_in: "user_terminal",
    cancel_scope: "turn_and_processes",
    version_range: ">=2.1.241 <2.2",
    question: { ...AGENT_CAPABILITY.question, structured: true },
    enforcement: { ...AGENT_CAPABILITY.enforcement, read_only: boundary(null) },
  };
  expect(agentCapabilitySchema.parse(extended)).toEqual(extended);
  expect(agentCapabilitySchema.safeParse({ ...extended, cancel_scope: "machine" }).success).toBe(false);
});

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

describe("대화 v2 — B2에서 더한 것 (additive)", () => {
  const conversation = {
    id: U.conversation,
    title: null,
    context_id: null,
    created_at: "2026-10-10T05:00:00Z",
    last_message_at: null,
    last_read_at: null,
    archived_at: null,
    text_purged_at: null,
  };

  it("대화 만들기: 앱이 정한 id(선택, 멱등) · 응답 { conversation }", () => {
    expect(createConversationRequestSchema.parse({ id: U.conversation })).toEqual({ id: U.conversation });
    expect(createConversationRequestSchema.safeParse({ id: "x" }).success).toBe(false);
    expect(createConversationResponseSchema.parse({ conversation })).toEqual({ conversation });
  });

  it("메시지 행의 reply_to · content는 없어도 읽고(옛 행 · A2 응답), 있으면 모양을 본다. content의 빠진 값은 기본값", () => {
    const base = {
      id: U.reply,
      conversation_id: U.conversation,
      seq: 2,
      role: "assistant",
      client_message_id: null,
      text: "기억했어요",
      refs: {},
      intent: null,
      created_at: "2026-10-10T05:00:00Z",
    };
    expect(conversationMessageSchema.parse(base)).not.toHaveProperty("reply_to");
    const parsed = conversationMessageSchema.parse({ ...base, reply_to: U.message, content: { segments: [{ text: "기억했어요", tier: "T2" }] } });
    expect(parsed.reply_to).toBe(U.message);
    expect(parsed.content).toEqual({ segments: [{ text: "기억했어요", tier: "T2" }], citations: [], proposal: null, asks: null, used: null, window: null });
    expect(conversationMessageContentSchema.safeParse({ asks: "delete" }).success).toBe(false);
    expect(conversationMessageContentSchema.safeParse({ proposal: { kind: "run", title: "x" } }).success).toBe(false);
    expect(
      conversationMessageContentSchema.parse({
        proposal: { kind: "create_action", title: "Shape 출시 준비" },
        asks: "adopt",
        used: { context_id: null, context_version: null, memory_item_ids: [U.memory] },
        window: { shown: 20, omitted: 3 },
      }),
    ).toMatchObject({ used: { memory_item_ids: [U.memory], source_ids: [], action_ids: [] }, window: { shown: 20, omitted: 3 } });
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

  it("subject(같은 사실의 열쇠, B1)는 문자열 · null · 없음 모두 읽는다 (B1 전 행 · 옛 응답)", () => {
    expect(memoryItemSchema.parse({ ...row, subject: "start" })).toEqual({ ...row, subject: "start" });
    expect(memoryItemSchema.parse({ ...row, subject: null })).toEqual({ ...row, subject: null });
    expect(memoryItemSchema.parse(row)).not.toHaveProperty("subject");
    expect(memoryItemSchema.safeParse({ ...row, subject: 42 }).success).toBe(false);
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

describe("기억 쓰기 · 대화 범위 바꾸기 (B3)", () => {
  it("범위 옮기기 요청: 전체(context_id 없음 · null) 또는 범위(context_id). 정정 요청과 같은 expected_version을 싣고 모르는 키는 거절한다", () => {
    expect(memoryScopeRequestSchema.parse({ expected_version: 2, scope_kind: "context", context_id: U.context })).toEqual({ expected_version: 2, scope_kind: "context", context_id: U.context });
    expect(memoryScopeRequestSchema.parse({ expected_version: 2, scope_kind: "global" })).toEqual({ expected_version: 2, scope_kind: "global", context_id: null });
    expect(memoryScopeRequestSchema.parse({ expected_version: 2, scope_kind: "global", context_id: null }).context_id).toBeNull();
    for (const bad of [
      {},
      { expected_version: 2 },
      { scope_kind: "global" },
      { expected_version: 0, scope_kind: "global" },
      { expected_version: 2, scope_kind: "context" },
      { expected_version: 2, scope_kind: "context", context_id: null },
      { expected_version: 2, scope_kind: "global", context_id: U.context },
      { expected_version: 2, scope_kind: "action", context_id: null },
      { expected_version: 2, scope_kind: "context", context_id: "x" },
      { expected_version: 2, scope_kind: "global", origin: "explicit" },
    ]) {
      expect(memoryScopeRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("기억 쓰기 응답은 { item: MemoryItem } 하나다", () => {
    const item = {
      id: U.memory, kind: "fact", scope_kind: "global", context_id: null, action_id: null, person_id: null, agent_adapter: null, subject: "launch day", statement: "출시는 목요일",
      value: { moved_from: U.reply }, origin: "explicit", source_ref: null, observed_at: "2026-10-10T01:00:00Z", valid_from: null, valid_until: null, superseded_by: null,
      superseded_at: null, revoked_at: null, confidence: null, source_purged: false, version: 1, created_at: "2026-10-10T01:00:00Z", updated_at: "2026-10-10T01:00:00Z",
    };
    expect(memoryItemResponseSchema.parse({ item })).toEqual({ item });
    expect(memoryItemResponseSchema.safeParse({ memory: item }).success).toBe(false);
    expect(memoryItemResponseSchema.safeParse({ item: { ...item, origin: "user" } }).success).toBe(false);
  });

  it("대화 범위 바꾸기: { context_id: uuid | null }뿐 (제목 · 보관 · 소유자는 바꾸지 못한다). 응답은 { conversation }", () => {
    expect(updateConversationRequestSchema.parse({ context_id: U.context })).toEqual({ context_id: U.context });
    expect(updateConversationRequestSchema.parse({ context_id: null })).toEqual({ context_id: null });
    for (const bad of [{}, { context_id: "x" }, { context_id: U.context, title: "x" }, { context_id: U.context, user_id: U.action }, { title: "x" }]) {
      expect(updateConversationRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
    const conversation = { id: U.conversation, title: null, context_id: U.context, created_at: "2026-10-10T01:00:00Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null };
    expect(updateConversationResponseSchema.parse({ conversation })).toEqual({ conversation });
  });

  it("v2 오류 코드 = v1 코드 전부 + 정책 보류 이유 둘. v1 apiErrorCodeSchema는 동결이라 새 코드를 받지 않는다", () => {
    expect(memoryUnavailableCodeSchema.options).toEqual(["confirm_unavailable", "scope_unavailable"]);
    expect(apiErrorV2CodeSchema.options).toEqual([...apiErrorCodeSchema.options, "confirm_unavailable", "scope_unavailable"]);
    expect(apiErrorCodeSchema.safeParse("confirm_unavailable").success).toBe(false);
    expect(apiErrorV2Schema.parse({ error: { code: "scope_unavailable", message: "x" } }).error.code).toBe("scope_unavailable");
    expect(apiErrorV2Schema.parse({ error: { code: "conflict", message: "x" } }).error.code).toBe("conflict");
    expect(apiErrorV2Schema.safeParse({ error: { code: "other", message: "x" } }).success).toBe(false);
  });
});

describe("범위 (work_contexts · context_members)", () => {
  it("범위 행 · 만들기 · 바꾸기", () => {
    const row = {
      id: U.context,
      name: "Shape 출시 준비",
      kind: "project",
      status: "active",
      icon: "compass",
      version: 3,
      context_version: 3,
      last_activity_at: "2026-10-09T05:00:00Z",
      created_at: "2026-10-01T05:00:00Z",
      updated_at: "2026-10-09T05:00:00Z",
    };
    expect(workContextSchema.parse(row)).toEqual(row);
    expect(workContextSchema.safeParse({ ...row, kind: "team" }).success).toBe(false);
    expect(createWorkContextRequestSchema.parse({ name: " Shape ", kind: "project" })).toEqual({ name: "Shape", kind: "project" });
    expect(createWorkContextRequestSchema.safeParse({ name: "Shape", kind: "client" }).success).toBe(false);
    expect(createWorkContextRequestSchema.safeParse({ name: "Shape" }).success).toBe(false);
    expect(updateWorkContextRequestSchema.parse({ status: "archived", expected_version: 1 })).toEqual({ status: "archived", expected_version: 1 });
    expect(updateWorkContextRequestSchema.safeParse({}).success).toBe(false);
    expect(updateWorkContextRequestSchema.safeParse({ context_version: 4, expected_version: 1 }).success).toBe(false);
  });

  it("프로젝트 아이콘과 optimistic version을 검증한다", () => {
    const icons = ["rocket", "briefcase", "flask-conical", "palette", "code-xml", "megaphone", "book-open", "building-2", "leaf", "compass", "target", "users"];
    expect(icons.every((icon) => projectIconSchema.safeParse(icon).success)).toBe(true);
    expect(projectIconSchema.safeParse("star").success).toBe(false);
    expect(createWorkContextRequestSchema.parse({ name: "Shape", kind: "project", icon: "rocket" }).icon).toBe("rocket");
    expect(createWorkContextRequestSchema.safeParse({ name: "Shape", kind: "project", icon: "star" }).success).toBe(false);
    expect(updateWorkContextRequestSchema.parse({ expected_version: 3, icon: "rocket" })).toEqual({ expected_version: 3, icon: "rocket" });
    expect(updateWorkContextRequestSchema.safeParse({ name: "Shape" }).success).toBe(false);
    expect(updateWorkContextRequestSchema.safeParse({ expected_version: 1 }).success).toBe(false);
    expect(updateWorkContextRequestSchema.safeParse({ expected_version: 0, name: "Shape" }).success).toBe(false);
    expect(updateWorkContextRequestSchema.safeParse({ expected_version: 2147483648, name: "Shape" }).success).toBe(false);
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

describe("해시 GUID 이슈의 멤버십 요청 (재검토 P2)", () => {
  it("에이전트가 만든 이슈의 id(sha256에서 나온 해시 GUID, RFC 4122 버전 자리가 아님)로도 넣기 · 빼기를 받는다. 모양이 틀린 id는 여전히 거절한다", () => {
    const hashed = "a3f1c2d4-5e6f-0718-293a-4b5c6d7e8f90";
    for (const op of ["add", "remove"]) {
      const target = { op, member_kind: "action", member_id: hashed };
      expect(contextMembershipRequestSchema.parse(target), op).toEqual(target);
      expect(contextMembershipChangeSchema.parse({ ...target, origin: "user" }), op).toEqual({ ...target, origin: "user", confidence: null });
    }
    expect(contextMembershipRequestSchema.safeParse({ op: "add", member_kind: "action", member_id: "not-a-guid" }).success).toBe(false);
    expect(contextMembershipRequestSchema.safeParse({ op: "add", member_kind: "action", member_id: hashed.replace(/-/g, "") }).success).toBe(false);
  });
});

describe("사용자 멤버십 쓰기 (S3b): 조건부 요청 · 실제 변화 응답", () => {
  const write = { op: "add", member_kind: "action", member_id: U.action, expected_context_version: 4 };
  const member = {
    id: U.memory, context_id: U.context, member_kind: "action", action_id: U.action, source_id: null, person_id: null,
    origin: "user", confidence: null, removed_at: null, created_at: "2026-10-11T05:00:00Z", updated_at: "2026-10-11T05:00:00Z",
  };

  it("넣기 · 빼기 요청은 본 범위 version을 싣고(필수), origin · confidence는 싣지 않으며, S3b는 할 일(action)만 받는다. A2의 조건 없는 스키마는 그대로다", () => {
    expect(contextMembershipWriteRequestSchema.parse(write)).toEqual(write);
    expect(contextMembershipWriteRequestSchema.parse({ ...write, op: "remove" }).op).toBe("remove");
    for (const bad of [
      { op: "add", member_kind: "action", member_id: U.action },
      { ...write, expected_context_version: 0 },
      { ...write, expected_context_version: 1.5 },
      { ...write, expected_context_version: "4" },
      { ...write, op: "move" },
      { ...write, member_kind: "source" },
      { ...write, member_kind: "person" },
      { ...write, origin: "user" },
    ]) {
      expect(contextMembershipWriteRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
    const unconditional = { op: "add", member_kind: "source", member_id: U.source };
    expect(contextMembershipRequestSchema.parse(unconditional)).toEqual(unconditional);
  });

  it("옮기기 요청은 도착(경로) · 출발 범위의 version 둘을 모두 싣는다", () => {
    const move = { member_kind: "action", member_id: U.action, from_context_id: U.context, expected_context_version: 4, expected_from_context_version: 2 };
    expect(contextMemberMoveRequestSchema.parse(move)).toEqual(move);
    for (const bad of [
      { ...move, expected_from_context_version: undefined },
      { ...move, expected_context_version: undefined },
      { ...move, expected_from_context_version: 0 },
      { ...move, member_kind: "source" },
      { ...move, op: "remove" },
    ]) {
      expect(contextMemberMoveRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("응답: member + 쓰기 직후 version + 실제 변화(change). 옮기기 응답은 두 행 · 두 version. change의 version은 양의 정수", () => {
    const change = { added: [{ context_id: U.context, context_version: 5 }], removed: [] };
    expect(contextMembershipEffectSchema.parse(change)).toEqual(change);
    expect(contextMembershipEffectSchema.safeParse({ added: [] }).success).toBe(false);
    expect(contextMembershipEffectSchema.safeParse({ added: [{ context_id: U.context, context_version: 0 }], removed: [] }).success).toBe(false);
    const response = { member, context_version: 5, change };
    expect(contextMembershipResponseSchema.parse(response)).toEqual(response);
    expect(contextMembershipResponseSchema.safeParse({ member, context_version: 5 }).success).toBe(false);
    const moved = { member, from_member: { ...member, removed_at: "2026-10-11T06:00:00Z" }, context_version: 5, from_context_version: 3, change: { added: [], removed: [{ context_id: U.context, context_version: 3 }] } };
    expect(contextMemberMoveResponseSchema.parse(moved)).toEqual(moved);
    expect(contextMemberMoveResponseSchema.safeParse({ ...moved, from_member: undefined }).success).toBe(false);
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

  it("원격 작업 상태 (idle = 턴의 끝, completed가 아니다) · 세션 상태", () => {
    expect(agentTaskStateSchema.options).toEqual([
      "dispatched", "accepted", "running", "awaiting_answer", "idle", "completed", "failed", "cancelled", "unreachable",
    ]);
    expect(agentSessionStatusSchema.options).toEqual(["bound", "external", "unreachable", "closed"]);
    expect(agentSessionStatusSchema.safeParse("paused").success).toBe(false);
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
    notice_ends_at: null,
    refund_until: "2026-10-12T05:00:00Z",
    refund_state: "idle",
    can_use_ai: true,
    can_checkout: false,
    can_buy_lifetime: false,
    with_trial: false,
    terms_version: "2026-10-19",
    prices: { pro_monthly: "$12.99", pro_first_month: "$6.99", pro_yearly: "$119.88", lifetime: "$229" },
    ai_usage_this_month: { since: "2026-10-01T00:00:00Z", prompt_tokens: 1200, completion_tokens: 300, total_tokens: 1500 },
    fair_use_paused_until: null,
    ai_key: "missing",
    ai_key_spend_error_at: null,
  };

  it("PlanSummary 8 상태 · plan lifetime · 이번 달 토큰 사용량 · 표시 가격 · 키 상태", () => {
    expect(planStateSchema.options).toEqual(["none", "trial", "pro", "cancelled", "past_due", "lapsed", "lifetime", "beta"]);
    expect(billingStatusV2Schema.parse(status)).toEqual(status);
    for (const state of planStateSchema.options) expect(billingStatusV2Schema.safeParse({ ...status, state }).success, state).toBe(true);
    expect(billingStatusV2Schema.safeParse({ ...status, state: "legacy_beta" }).success).toBe(false);
    expect(billingStatusV2Schema.safeParse({ ...status, ai_usage_this_month: null, plan: null, state: "none", ai_key: null }).success).toBe(true);
    expect(billingStatusV2Schema.safeParse({ ...status, ai_usage_this_month: { ...status.ai_usage_this_month, total_tokens: -1 } }).success).toBe(false);
    for (const key of ["connected", "missing", "revoked", null]) expect(billingStatusV2Schema.safeParse({ ...status, ai_key: key }).success, String(key)).toBe(true);
    expect(billingStatusV2Schema.safeParse({ ...status, ai_key: "expired" }).success).toBe(false);
    for (const refund_state of ["idle", "requested"]) expect(billingStatusV2Schema.safeParse({ ...status, refund_state }).success).toBe(true);
    expect(billingStatusV2Schema.safeParse({ ...status, refund_state: "done" }).success).toBe(false);
  });

  it("빠진 필수 키는 실패하고 남는 키는 읽는 쪽이 무시한다 (Swift 디코딩 짝)", () => {
    for (const key of Object.keys(status)) {
      const rest = Object.fromEntries(Object.entries(status).filter(([name]) => name !== key));
      expect(billingStatusV2Schema.safeParse(rest).success, key).toBe(false);
    }
    expect(billingStatusV2Schema.parse({ ...status, future_field: 1 })).toEqual(status);
    expect(billingStatusV2Schema.safeParse({ ...status, prices: { pro_monthly: "$12.99" } }).success).toBe(false);
  });

  it("한도 숫자는 응답 모양에 없다 (공정 사용 안전장치는 멈춘 시각만 내린다)", () => {
    expect(Object.keys(billingStatusV2Schema.shape).filter((key) => /cap|limit|budget|allowance/.test(key))).toEqual([]);
    expect(Object.keys(billingStatusV2Schema.shape)).toContain("fair_use_paused_until");
  });

  it("checkout v2는 pro · lifetime만 받고 약관 판은 문자열이다. 클라이언트가 정하는 값은 없다", () => {
    expect(billingCheckoutRequestV2Schema.parse({ plan: "lifetime", terms_version: "2026-10-09" })).toEqual({ plan: "lifetime", terms_version: "2026-10-09" });
    expect(billingCheckoutRequestV2Schema.parse({ plan: "pro", terms_version: "2026-10-19" })).toEqual({ plan: "pro", terms_version: "2026-10-19" });
    expect(billingCheckoutRequestV2Schema.safeParse({ plan: "lifetime", terms_version: "" }).success).toBe(false);
    for (const plan of ["weekly", "monthly", "annual", undefined]) expect(billingCheckoutRequestV2Schema.safeParse({ plan, terms_version: "x" }).success, String(plan)).toBe(false);
    for (const extra of [{ price: 1 }, { user_id: "u" }, { redirect_url: "https://x" }, { variant_id: 1 }, { discount_code: "X" }])
      expect(billingCheckoutRequestV2Schema.safeParse({ plan: "pro", terms_version: "x", ...extra }).success, JSON.stringify(extra)).toBe(false);
    expect(billingUrlResponseV2Schema.parse({ url: "https://taskforce.lemonsqueezy.com/checkout/x" })).toEqual({ url: "https://taskforce.lemonsqueezy.com/checkout/x" });
    expect(billingUrlResponseV2Schema.safeParse({ url: "not a url" }).success).toBe(false);
  });

  it("portal은 manage · payment만, resume · 환불 요청 본문은 비어 있다", () => {
    expect(billingPortalRequestV2Schema.parse({ target: "payment" })).toEqual({ target: "payment" });
    for (const body of [{}, { target: "cancel" }, { target: "manage", url: "x" }]) expect(billingPortalRequestV2Schema.safeParse(body).success).toBe(false);
    for (const schema of [billingResumeRequestV2Schema, billingRefundRequestV2Schema]) {
      expect(schema.parse({})).toEqual({});
      expect(schema.safeParse({ order_id: "1" }).success).toBe(false);
    }
    expect(billingRefundResponseV2Schema.parse({ requested: true })).toEqual({ requested: true });
    expect(billingResumeResponseV2Schema.parse({ requested: true })).toEqual({ requested: true });
    expect(billingResumeResponseV2Schema.safeParse({ requested: false }).success).toBe(false);
  });

  it("오류 코드는 닫힌 목록이다", () => {
    expect(billingErrorCodeV2Schema.options).toEqual(["unauthorized", "invalid_request", "billing_unavailable", "billing_terms_required", "billing_refund_window_closed", "billing_refund_used", "billing_refund_pending"]);
    expect(billingErrorV2Schema.parse({ error: { code: "billing_refund_used", message: "m" } })).toEqual({ error: { code: "billing_refund_used", message: "m" } });
    expect(billingErrorV2Schema.safeParse({ error: { code: "ai_key_missing", message: "m" } }).success).toBe(false);
  });
});

// ─── D4c-2: 이슈 정리의 제안 · 답 내용 ───
describe("organize 계약 (D4c-2)", () => {
  const A = "aaaaaaaa-0000-4000-8000-000000000001";
  const B = "aaaaaaaa-0000-4000-8000-000000000002";
  const C = "c1c1c1c1-0000-4000-8000-000000000001";
  const target = (id: string, number: number) => ({ action_id: id, number, title: `이슈 ${number}`, version: 0, contexts: [{ id: C, name: "Launch" }], open_sessions: 1, evidence_count: 2 });

  it("의도 · 제안 종류에 organize · move · delete · merge가 더해졌다. 옛 값은 그대로", () => {
    expect(intentKindSchema.options).toContain("organize");
    expect(intentKindSchema.options).toContain("inform");
    for (const kind of ["create_action", "run", "modify", "stop", "preference", "move", "delete", "merge"]) {
      expect(proposalSchema.safeParse({ id: A, kind, payload_hash: "sha256:x", state: "open" }).success, kind).toBe(true);
    }
    expect(proposalSchema.safeParse({ id: A, kind: "teleport", payload_hash: "sha256:x", state: "open" }).success).toBe(false);
  });

  it("제안 내용: 옛 create_action 모양은 그대로 읽고, move · delete · merge는 strict (모르는 키 · 0개 · 4개 거절)", () => {
    expect(proposalPayloadSchema.parse({ kind: "create_action", title: "Shape" })).toEqual({ kind: "create_action", title: "Shape" });
    expect(proposalPayloadSchema.safeParse({ kind: "create_action", title: "Shape", extra: 1 }).success).toBe(true);
    const move = { kind: "move", targets: [target(A, 139)], from: { id: C, name: "Taskforce", version: 3 }, to: { id: C, name: "Launch", version: 4 } };
    expect(proposalPayloadSchema.safeParse(move).success).toBe(true);
    expect(proposalPayloadSchema.safeParse({ ...move, from: null, to: null }).success).toBe(true);
    expect(proposalPayloadSchema.safeParse({ ...move, extra: 1 }).success).toBe(false);
    expect(proposalPayloadSchema.safeParse({ ...move, targets: [] }).success).toBe(false);
    expect(proposalPayloadSchema.safeParse({ ...move, targets: [1, 2, 3, 4].map((n) => target(A, n)) }).success).toBe(false);
    expect(proposalPayloadSchema.safeParse({ kind: "delete", targets: [target(A, 1), target(B, 2)] }).success).toBe(true);
    expect(proposalPayloadSchema.safeParse({ kind: "delete", targets: [{ ...target(A, 1), extra: true }] }).success).toBe(false);
    expect(proposalPayloadSchema.safeParse({ kind: "merge", from: target(A, 144), into: target(B, 139) }).success).toBe(true);
    expect(proposalPayloadSchema.safeParse({ kind: "merge", from: target(A, 144) }).success).toBe(false);
  });

  it("답 내용: asks에 confirm · organize, organize는 없어도 읽는다 (옛 행). state마다 strict", () => {
    expect(contentSchema.parse({ asks: "confirm" })).toMatchObject({ asks: "confirm" });
    expect(contentSchema.parse({ asks: "organize" })).toMatchObject({ asks: "organize" });
    expect(contentSchema.parse({})).not.toHaveProperty("organize", expect.anything());
    const pending = { state: "pending", op: "move", action_ids: [A], context_id: null, missing: "project" };
    expect(contentSchema.parse({ asks: "organize", organize: pending }).organize).toEqual(pending);
    expect(organizeContentSchema.safeParse({ ...pending, op: null }).success).toBe(true);
    expect(organizeContentSchema.safeParse({ ...pending, missing: "title" }).success).toBe(false);
    expect(organizeContentSchema.safeParse({ ...pending, action_ids: [A, B, A, B] }).success).toBe(false);
    const moved = { state: "moved", results: [{ action_id: A, number: 139, from_context_id: null, to_context_id: C, change: null }] };
    expect(organizeContentSchema.safeParse(moved).success).toBe(true);
    const filled = { ...moved, results: [{ ...moved.results[0], change: { added: [{ context_id: C, context_version: 5 }], removed: [] } }] };
    expect(organizeContentSchema.safeParse(filled).success).toBe(true);
    expect(organizeContentSchema.safeParse({ state: "moved", results: [] }).success).toBe(false);
    expect(organizeContentSchema.safeParse({ state: "deleted", action_ids: [A] }).success).toBe(true);
    expect(organizeContentSchema.safeParse({ state: "deleted", action_ids: [] }).success).toBe(false);
    expect(organizeContentSchema.safeParse({ state: "merged", from_action_id: A, into_action_id: B }).success).toBe(true);
    expect(organizeContentSchema.safeParse({ state: "merged", from_action_id: A }).success).toBe(false);
  });

  it("에이전트 턴이 만든 이슈 id(sha256에서 만든, 버전 · variant 자리가 RFC 4122와 다른 guid)도 받는다: refs · 카드 · 기록 줄이 읽혀야 삭제 · 병합 카드가 열린다", () => {
    const hashed = "f0b0c918-acd0-b623-d33f-14699a728393";
    expect(messageRefsSchema.safeParse({ action_ids: [hashed] }).success).toBe(true);
    expect(proposalPayloadSchema.safeParse({ kind: "delete", targets: [target(hashed, 1)] }).success).toBe(true);
    expect(proposalPayloadSchema.safeParse({ kind: "merge", from: target(hashed, 144), into: target(B, 139) }).success).toBe(true);
    expect(organizeContentSchema.safeParse({ state: "deleted", action_ids: [hashed] }).success).toBe(true);
    expect(organizeContentSchema.safeParse({ state: "merged", from_action_id: hashed, into_action_id: B }).success).toBe(true);
    expect(organizeContentSchema.safeParse({ state: "moved", results: [{ action_id: hashed, number: 1, from_context_id: null, to_context_id: C, change: null }] }).success).toBe(true);
    expect(proposalConfirmResponseSchema.shape.action_ids.safeParse([hashed]).success).toBe(true);
    expect(messageRefsSchema.safeParse({ action_ids: ["not-a-uuid"] }).success).toBe(false);
  });

  it("상담 답의 content.used.action_ids에 에이전트 턴이 만든 이슈 id(sha256에서 만든 guid)가 있어도 답이 읽히고 그대로 되돌려 읽힌다", () => {
    const hashed = "f0b0c918-acd0-b623-d33f-14699a728393";
    const stored = { segments: [{ text: "열린 일은 하나예요.", tier: "T1" }], used: { context_id: null, context_version: null, memory_item_ids: [], source_ids: [], action_ids: [hashed, A] } };
    const parsed = contentSchema.parse(stored);
    expect(parsed.used?.action_ids).toEqual([hashed, A]);
    // 메시지 행으로도 읽힌다 (content가 null로 떨어지지 않는다) · 다시 직렬화해도 같다
    const row = conversationMessageSchema.parse({
      id: A, conversation_id: B, seq: 2, role: "assistant", client_message_id: null, text: "열린 일은 하나예요.", refs: { action_ids: [hashed] },
      intent: null, created_at: "2026-10-15T01:00:00Z", reply_to: C, content: stored,
    });
    expect(row.content?.used?.action_ids).toEqual([hashed, A]);
    expect(contentSchema.parse(JSON.parse(JSON.stringify(row.content))).used?.action_ids).toEqual([hashed, A]);
    expect(contentSchema.safeParse({ used: { ...stored.used, action_ids: ["not-a-uuid"] } }).success).toBe(false);
  });

  it("moved.results[].change는 S3b 멤버십 변화(contextMembershipEffectSchema)와 같은 모양이다", () => {
    const samples = [
      { added: [{ context_id: C, context_version: 5 }], removed: [{ context_id: B, context_version: 2 }] },
      { added: [], removed: [] },
      { added: [{ context_id: C, context_version: 0 }], removed: [] },
      { added: [{ context_id: "x", context_version: 1 }], removed: [] },
      { added: [] },
    ];
    for (const sample of samples) {
      const organize = organizeContentSchema.safeParse({ state: "moved", results: [{ action_id: A, number: 1, from_context_id: null, to_context_id: C, change: sample }] }).success;
      expect(organize, JSON.stringify(sample)).toBe(effectSchema.safeParse(sample).success);
    }
  });
});
