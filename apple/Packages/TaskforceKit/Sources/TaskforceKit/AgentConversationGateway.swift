import Foundation

/// 에이전트 대화의 쓰기 · 읽기 넷이 서버와 닿는 면 (OA D4a-20b): Send again(deliver) · 후보 고르기(referent) · 대화 Stop · 전달 읽기.
/// `AssistantGateway`에 더하지 않고 새 프로토콜로 둔다: 그 프로토콜을 따르는 가짜 · 견본을 고치지 않아도 되고 (`ChatRuntime`이 `as?`로 꺼낸다), 이 프로토콜이 없는 런타임은
/// 에이전트 동작(Send again · Stop · 후보 고르기 · 전달 다시 읽기)이 없을 뿐 나머지는 그대로다.
/// 모두 서버 `/api/v2` 요청이고 판정은 서버가 한다 (앱은 응답을 줄로 옮길 뿐이다).
public protocol AgentConversationGateway: Sendable {
    /// Send again. `messageIDs`가 nil이면 그 대화의 보류 · 만료 메시지 전부, 아니면 1–50개
    func deliver(conversationID: UUID, messageIDs: [UUID]?) async throws -> AgentDeliverResponse
    /// `needs_referent` 후보 하나를 고른다
    func setReferent(conversationID: UUID, messageID: UUID, actionID: UUID) async throws -> AgentPostedMessage
    /// 그 대화의 열린 작업을 멈춘다
    func stopConversation(id: UUID) async throws -> AgentStopResponse
    /// `since_seq` 뒤의 내 메시지 ≤ 100개의 전달 표시 (seq 순)
    func deliveries(conversationID: UUID, sinceSeq: Int?) async throws -> ConversationDeliveryResponse
}

/// 에이전트 세션 route의 쓰기 셋 (알약 · 세션 패널 Stop): 서버 `/api/v2/agent-sessions/{id}/…`
public protocol AgentSessionRequests: Sendable {
    func openExternal(sessionID: UUID) async throws -> AgentSessionResponse
    func resumeHere(sessionID: UUID) async throws -> AgentResumeResponse
    func stopSession(id: UUID) async throws -> AgentStopResponse
}

extension LiveChatGateway: AgentConversationGateway {
    public func deliver(conversationID: UUID, messageIDs: [UUID]?) async throws -> AgentDeliverResponse {
        try await api.deliverAgentMessages(conversationID: conversationID, messageIDs: messageIDs)
    }

    public func setReferent(conversationID: UUID, messageID: UUID, actionID: UUID) async throws -> AgentPostedMessage {
        try await api.setAgentReferent(conversationID: conversationID, messageID: messageID, actionID: actionID)
    }

    public func stopConversation(id: UUID) async throws -> AgentStopResponse {
        try await api.stopAgentConversation(id: id)
    }

    public func deliveries(conversationID: UUID, sinceSeq: Int?) async throws -> ConversationDeliveryResponse {
        try await api.agentDeliveries(conversationID: conversationID, sinceSeq: sinceSeq)
    }
}

extension LiveChatGateway: AgentSessionRequests {
    public func openExternal(sessionID: UUID) async throws -> AgentSessionResponse {
        try await api.openAgentSessionExternal(id: sessionID)
    }

    public func resumeHere(sessionID: UUID) async throws -> AgentResumeResponse {
        try await api.resumeAgentSessionHere(id: sessionID)
    }

    public func stopSession(id: UUID) async throws -> AgentStopResponse {
        try await api.stopAgentSession(id: id)
    }
}
