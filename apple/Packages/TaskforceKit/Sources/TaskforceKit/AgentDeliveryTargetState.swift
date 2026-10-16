import Foundation

extension AssistantTargetsStore {
    /// 이 연결의 대상 상태 (서버가 판정한 `ready` · `unreachable` …). 대상 목록에 없으면 nil.
    /// 전달 줄 "Queued · Mac is offline"의 조건이다 (D4a-09: 서버가 준 대상 상태를 말로 옮길 뿐이고 앱이 판정하지 않는다)
    public func targetState(forConnection connectionID: UUID) -> AgentTargetState? {
        for case .agent(let agent) in targets where agent.connectionID == connectionID { return agent.state }
        return nil
    }
}

extension AssistantTargetPick {
    /// 연결을 아는 에이전트 대상이면 그 연결 id
    var connectionID: UUID? {
        if case .agent(_, let connectionID) = self { return connectionID }
        return nil
    }
}

extension ChatStore {
    /// 이 대화의 에이전트 세션: 대화 행의 `agent_session_id`, 아직 행을 다시 읽기 전이면 첫 전달의 응답이 알려 준 것 (Stop · 좁은 세션 읽기가 쓴다)
    public func agentSessionID(for conversationID: UUID) -> UUID? {
        guard conversationTarget(for: conversationID).isAgent else { return nil }
        return conversationTarget(for: conversationID).agentSessionID ?? learnedSessions[conversationID]
    }

    /// 지금 보이는 에이전트 대화들의 세션 (좁게 읽는 저장소의 초점)
    public func viewedAgentSessionIDs() -> Set<UUID> {
        Set(shownAgentConversations().compactMap { agentSessionID(for: $0) })
    }
}
