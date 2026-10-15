import Foundation

/// 서버 `src/lib/agents/conversation-contract.test.ts`(OA D1d-s, 커밋 cfdb021, 파일 sha1 617e89b5735976c7e13249e8accefc1d7e58cacf)의 `AGENT_CONVERSATION_*` 상수와 **같은 JSON**이다.
/// 서버 시험이 "아래 상수는 Swift 시험이 같은 JSON을 디코딩한다 — 한쪽을 고치면 다른 쪽도 고친다"고 적어 둔 그 상수다.
/// TS 객체를 그대로 `JSON.stringify`해 복사했다 (키 순서 · 값 그대로, 손으로 옮기지 않음). 서버 쪽이 바뀌면 이 파일을 다시 복사한다.
/// 이름 대응: `userMessage` = AGENT_CONVERSATION_USER_MESSAGE · `postResponse` = …_POST_RESPONSE · `needsReferent` = …_NEEDS_REFERENT · `deliverResponse` = …_DELIVER_RESPONSE ·
/// `stopResponse` = …_STOP_RESPONSE · `session` = …_SESSION · `resumeResponse` = …_RESUME_RESPONSE · `targets` = …_TARGETS · `answerResponse` = …_ANSWER_RESPONSE ·
/// `deliveryRead` = …_DELIVERY_READ · `createResponse` = …_CREATE_RESPONSE
enum AgentConversationFixtures {
    /// 서버 시험의 결정적 id들 (`U`): 메시지에서 결정적으로 만든 Action id는 UUID 버전 · 변형 비트가 없다
    static let conversationID = UUID(uuidString: "a1111111-1111-4111-8111-111111111111")!
    static let messageID = UUID(uuidString: "a2222222-2222-4222-8222-222222222222")!
    static let connectionID = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
    static let sessionID = UUID(uuidString: "a4444444-4444-4444-8444-444444444444")!
    static let taskID = UUID(uuidString: "a5555555-5555-4555-8555-555555555555")!
    static let stepID = UUID(uuidString: "a6666666-6666-4666-8666-666666666666")!
    static let contextID = UUID(uuidString: "a7777777-7777-4777-8777-777777777777")!
    static let secondID = UUID(uuidString: "a8888888-8888-4888-8888-888888888888")!
    static let deterministicActionID = UUID(uuidString: "f0000000-0000-f000-f000-000000000001")!

    /// AGENT_CONVERSATION_USER_MESSAGE
    static let userMessage = #"""
    {"id":"a2222222-2222-4222-8222-222222222222","conversation_id":"a1111111-1111-4111-8111-111111111111","seq":1,"role":"user","client_message_id":"a8888888-8888-4888-8888-888888888888","text":"이어서 해 줘","refs":{"action_ids":[],"run_ids":[],"artifact_ids":[],"suggestion_ids":[],"dependency_ids":[],"memory_item_ids":[],"context_ids":[],"proposal":null},"intent":null,"created_at":"2026-10-14T01:00:00.000Z","reply_to":null,"content":null,"delivery_state":"dispatched","delivery_reason":null,"delivery_expires_at":"2026-10-15T01:00:00.000Z"}
    """#

    /// AGENT_CONVERSATION_POST_RESPONSE
    static let postResponse = #"""
    {"message":{"id":"a2222222-2222-4222-8222-222222222222","conversation_id":"a1111111-1111-4111-8111-111111111111","seq":1,"role":"user","client_message_id":"a8888888-8888-4888-8888-888888888888","text":"이어서 해 줘","refs":{"action_ids":[],"run_ids":[],"artifact_ids":[],"suggestion_ids":[],"dependency_ids":[],"memory_item_ids":[],"context_ids":[],"proposal":null},"intent":null,"created_at":"2026-10-14T01:00:00.000Z","reply_to":null,"content":null,"delivery_state":"dispatched","delivery_reason":null,"delivery_expires_at":"2026-10-15T01:00:00.000Z"},"reply":null,"delivery":{"state":"sent"},"attachments_dropped":[{"kind":"source","id":"a8888888-8888-4888-8888-888888888888","reason":"slack_purged"}],"created_action":{"id":"f0000000-0000-f000-f000-000000000001","number":139,"title":"이어서 해 줘","context_id":"a7777777-7777-4777-8777-777777777777"},"agent_task":{"id":"a5555555-5555-4555-8555-555555555555","state":"dispatched","agent_session_id":"a4444444-4444-4444-8444-444444444444"}}
    """#

    /// AGENT_CONVERSATION_NEEDS_REFERENT
    static let needsReferent = #"""
    {"message":{"id":"a2222222-2222-4222-8222-222222222222","conversation_id":"a1111111-1111-4111-8111-111111111111","seq":1,"role":"user","client_message_id":"a8888888-8888-4888-8888-888888888888","text":"이어서 해 줘","refs":{"action_ids":[],"run_ids":[],"artifact_ids":[],"suggestion_ids":[],"dependency_ids":[],"memory_item_ids":[],"context_ids":[],"proposal":null},"intent":null,"created_at":"2026-10-14T01:00:00.000Z","reply_to":null,"content":null,"delivery_state":"queued","delivery_reason":null,"delivery_expires_at":"2026-10-15T01:00:00.000Z"},"reply":null,"delivery":{"state":"needs_referent","candidates":[{"action_id":"f0000000-0000-f000-f000-000000000001","title":"가격 문구"},{"action_id":"a8888888-8888-4888-8888-888888888888","title":"온보딩"}]},"attachments_dropped":[],"created_action":null,"agent_task":null}
    """#

    /// AGENT_CONVERSATION_DELIVER_RESPONSE
    static let deliverResponse = #"""
    {"messages":[{"message_id":"a2222222-2222-4222-8222-222222222222","result":"requeued","delivery":{"state":"queued","reason":"session_busy"}},{"message_id":"a8888888-8888-4888-8888-888888888888","result":"skipped","skipped_reason":"unknown_outcome","delivery":{"state":"unknown"}},{"message_id":"a5555555-5555-4555-8555-555555555555","result":"skipped","skipped_reason":"not_found"}]}
    """#

    /// AGENT_CONVERSATION_STOP_RESPONSE
    static let stopResponse = #"""
    {"tasks":[{"agent_task_id":"a5555555-5555-4555-8555-555555555555","cancel":"requested_only","processes":"may_continue"},{"agent_task_id":"a6666666-6666-4666-8666-666666666666","cancel":"confirmed"}]}
    """#

    /// AGENT_CONVERSATION_SESSION
    static let session = #"""
    {"session":{"id":"a4444444-4444-4444-8444-444444444444","connection_id":"a3333333-3333-4333-8333-333333333333","display_name":"Pricing copy","status":"external","last_turn_seq":3,"updated_at":"2026-10-14T01:00:00.000Z"}}
    """#

    /// AGENT_CONVERSATION_RESUME_RESPONSE
    static let resumeResponse = #"""
    {"session":{"id":"a4444444-4444-4444-8444-444444444444","connection_id":"a3333333-3333-4333-8333-333333333333","display_name":"Pricing copy","status":"external","last_turn_seq":3,"updated_at":"2026-10-14T01:00:00.000Z"},"started_message_id":"a2222222-2222-4222-8222-222222222222"}
    """#

    /// AGENT_CONVERSATION_TARGETS
    static let targets = #"""
    {"targets":[{"kind":"taskforce"},{"kind":"agent","adapter":"agent:claude-code","display_name":"Claude Code","connection_id":"a3333333-3333-4333-8333-333333333333","state":"unsupported","access":null},{"kind":"agent","adapter":"agent:codex","display_name":"Codex","connection_id":null,"state":"not_connected","access":"read_only"}]}
    """#

    /// AGENT_CONVERSATION_ANSWER_RESPONSE
    static let answerResponse = #"""
    {"status":"answered","step_id":"f0000000-0000-f000-f000-000000000001"}
    """#

    /// AGENT_CONVERSATION_DELIVERY_READ
    static let deliveryRead = #"""
    {"messages":[{"message_id":"a2222222-2222-4222-8222-222222222222","seq":1,"delivery":{"state":"accepted"}},{"message_id":"a8888888-8888-4888-8888-888888888888","seq":2,"delivery":{"state":"not_sent","reason":"usage_limited"}}]}
    """#

    /// AGENT_CONVERSATION_CREATE_RESPONSE
    static let createResponse = #"""
    {"conversation":{"id":"a1111111-1111-4111-8111-111111111111","title":null,"context_id":null,"created_at":"2026-10-14T01:00:00.000Z","last_message_at":null,"last_read_at":null,"archived_at":null,"text_purged_at":null,"target_kind":"agent","agent_connection_id":"a3333333-3333-4333-8333-333333333333","agent_session_id":null}}
    """#
}
