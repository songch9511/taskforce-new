import Foundation

/// 질문 저장소가 서버와 닿는 면 (OA D4b-m-1): 열린 질문 읽기(RLS select) · 답 요청(`/api/v2`) · Mac 이름 읽기.
/// 저장소는 이 프로토콜만 안다: 시험은 가짜로 붙잡기 · 실패 · 순서를 정확히 다룬다 (실제 연결은 `LiveChatGateway`, 견본 · 시험용 가짜 서버는 따로).
/// `AgentConversationGateway`에 더하지 않고 새 프로토콜로 둔다: 이 프로토콜이 없는 런타임은 질문 카드가 없을 뿐 나머지는 그대로다
public protocol AgentQuestionGateway: Sendable {
    /// 그 세션들의 열린 질문
    func openQuestions(sessionIDs: Set<UUID>) async throws -> [AgentQuestionRecord]
    /// 질문에 답한다 (비밀값이 섞인 질문은 이 길로 오지 않는다)
    func answerQuestion(taskID: UUID, request: AgentAnswerRequest) async throws -> AgentAnswerResponse
    /// "Answer on <Mac>"의 이름. 모르면 nil
    func deviceName(bridgeID: UUID) async throws -> String?
}

extension LiveChatGateway: AgentQuestionGateway {
    public func openQuestions(sessionIDs: Set<UUID>) async throws -> [AgentQuestionRecord] {
        try await reads.openQuestions(sessionIDs: sessionIDs)
    }

    public func answerQuestion(taskID: UUID, request: AgentAnswerRequest) async throws -> AgentAnswerResponse {
        try await api.answerAgentQuestion(taskID: taskID, request)
    }

    public func deviceName(bridgeID: UUID) async throws -> String? {
        try await reads.bridgeDeviceName(id: bridgeID)
    }
}
