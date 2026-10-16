import Foundation

// 대화 API v2 확장의 요청 (OA U1이 쓰는 셋: 대상 목록 · 대상을 지정한 대화 만들기 · 칩을 실은 메시지 보내기).
// 모양은 `AgentConversationContracts.swift`, 서버는 `src/lib/api/contract.ts`의 `// --- D1d ---` 블록이다.
// 기존 `ChatEndpoints.swift`의 줄은 바꾸지 않는다: 같은 이름의 새 인자 조합(`target:` · `attachments:`)을 이 파일에 더할 뿐이다.
// Send again · referent · 대화 Stop · 전달 읽기는 D4a-1이 더했다 (아래 `extension APIClient`의 두 번째 블록). 세션 route는 `AgentSessionEndpoints.swift`, 질문 답은 D4b-m이다.

/// `POST /api/v2/conversations` 본문: 기존 `{ id, title?, context_id }` + `target`
struct CreateConversationWithTargetRequest: Encodable {
    let id: UUID
    let title: String?
    let contextID: UUID?
    let target: ChatTarget

    enum CodingKeys: String, CodingKey {
        case id, title, target
        case contextID = "context_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.lowercased, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        if let contextID {
            try c.encode(contextID.lowercased, forKey: .contextID)
        } else {
            try c.encodeNil(forKey: .contextID)
        }
        try c.encode(target, forKey: .target)
    }
}

/// `POST /api/v2/conversations/{id}/messages` 본문: 기존 `{ client_message_id, text }` + `attachments`(≤ 20).
/// 새 앱은 `refs`를 보내지 않는다 (함께 보내면 서버가 400, OD-4). 칩이 없으면 `attachments` 키 자체를 보내지 않는다
struct PostChatMessageWithAttachmentsRequest: Encodable {
    let clientMessageID: UUID
    let text: String
    let attachments: [ChatAttachment]

    enum CodingKeys: String, CodingKey {
        case text, attachments
        case clientMessageID = "client_message_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientMessageID.lowercased, forKey: .clientMessageID)
        try c.encode(text, forKey: .text)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
    }
}

extension APIClient {
    /// 대상 목록: Taskforce + 내 에이전트 연결마다 한 행 (OD-20). 대화 API가 꺼져 있으면 404 (`APIError.isFeatureOff`)
    public func assistantTargets() async throws -> AssistantTargetsResponse {
        try await send(.get, "assistant/targets", version: .v2)
    }

    /// 대상을 지정한 대화 만들기. `id`는 앱이 정한다 (같은 id · 같은 대상이면 200, 다른 대상이면 409 `target_mismatch`).
    /// 응답은 기존 대화 행 + 대상 열이다. 404 = gate 꺼짐 · 남의 연결 · 꺼진 adapter · 지워진 연결
    public func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation {
        try await send(
            .post, "conversations", body: CreateConversationWithTargetRequest(id: id, title: title, contextID: contextID, target: target), version: .v2
        )
    }

    /// Taskforce 대상 대화에 칩을 실어 보내기. 응답은 기존 `ChatPostedMessage`(답 포함) 그대로다
    public func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage {
        try await send(
            .post, "conversations/\(conversationID.lowercased)/messages",
            body: PostChatMessageWithAttachmentsRequest(clientMessageID: clientMessageID, text: text, attachments: attachments),
            timeout: Self.chatTimeout, version: .v2
        )
    }

    /// 에이전트 대상 대화에 보내기. 응답의 `reply`는 null이고 전달 표시(`delivery`)가 온다 — 답은 비동기로 대화에 쓰인다.
    /// 같은 `clientMessageID` · 같은 글 · 같은 칩이면 같은 제출이다. 칩만 다르게 다시 보내면 409 `conflict`
    public func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage {
        try await send(
            .post, "conversations/\(conversationID.lowercased)/messages",
            body: PostChatMessageWithAttachmentsRequest(clientMessageID: clientMessageID, text: text, attachments: attachments), version: .v2
        )
    }
}

/// 앱이 서버에 보내기 전에 막는 요청: Send again의 `message_ids`는 1–50개다 (서버 `deliverAgentMessagesRequestSchema`가 그 밖은 400)
public enum AgentDeliverRequestError: Error, Equatable, Sendable {
    case invalidCount
}

extension APIClient {
    public static let deliverMessageLimit = 50

    private func conversationPath(_ id: UUID, _ tail: String) -> String {
        "conversations/\(id.lowercased)/\(tail)"
    }

    /// Send again (OD-8): 보내지 못한(not_sent) · 만료된(expired) 메시지를 서버 id로 다시 보낸다. `messageIDs`가 nil이면 그 대화의 보류 · 만료 메시지 전부.
    /// 두 번 눌러도 새 전달은 한 번이다 (서버). 1–50개가 아니면 서버가 400이라 보내지 않고 `invalidCount`를 던진다
    public func deliverAgentMessages(conversationID: UUID, messageIDs: [UUID]?) async throws -> AgentDeliverResponse {
        if let messageIDs, !(1...Self.deliverMessageLimit).contains(messageIDs.count) { throw AgentDeliverRequestError.invalidCount }
        return try await send(.post, conversationPath(conversationID, "deliver"), body: AgentDeliverRequest(messageIDs: messageIDs), version: .v2)
    }

    /// `needs_referent` 후보 하나를 고른다. 응답은 보내기 응답과 같다 (새 전달 표시). 404 `not_found` · 409 `conflict` · `busy_retry`는 호출부가 다시 읽는다
    public func setAgentReferent(conversationID: UUID, messageID: UUID, actionID: UUID) async throws -> AgentPostedMessage {
        try await send(
            .post, conversationPath(conversationID, "messages/\(messageID.lowercased)/referent"), body: AgentReferentRequest(actionID: actionID), version: .v2
        )
    }

    /// Assistant 창의 Stop: 그 대화의 열린 작업을 멈춘다 (`requested_only` · `confirmed` · `processes: may_continue`)
    public func stopAgentConversation(id: UUID) async throws -> AgentStopResponse {
        try await send(.post, conversationPath(id, "stop"), body: EmptyAgentSessionRequest(), version: .v2)
    }

    /// 전달 다시 읽기 (OD-13): `since_seq` 뒤의 내 메시지 ≤ 100개의 전달 표시를 서버 계산으로. 읽기만 한다
    public func agentDeliveries(conversationID: UUID, sinceSeq: Int?) async throws -> ConversationDeliveryResponse {
        let query = sinceSeq.map { [URLQueryItem(name: "since_seq", value: String($0))] } ?? []
        return try await send(.get, conversationPath(conversationID, "delivery"), query: query, version: .v2)
    }
}
