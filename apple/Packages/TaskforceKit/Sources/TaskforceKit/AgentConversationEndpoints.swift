import Foundation

// 대화 API v2 확장의 요청 (OA U1이 쓰는 셋: 대상 목록 · 대상을 지정한 대화 만들기 · 칩을 실은 메시지 보내기).
// 모양은 `AgentConversationContracts.swift`, 서버는 `src/lib/api/contract.ts`의 `// --- D1d ---` 블록이다.
// 기존 `ChatEndpoints.swift`의 줄은 바꾸지 않는다: 같은 이름의 새 인자 조합(`target:` · `attachments:`)을 이 파일에 더할 뿐이다.
// Send again · referent · Stop · 세션 · 답은 이 PR에서 부르지 않는다 (D4a · D4b-m · U2 몫, DTO만 있다).

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
