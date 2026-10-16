import Foundation

// 앱의 실제 연결이 세션을 좁게 읽는 길 (OA D4a-13b): `IssueScreensGateway`(U2)의 `LiveChatGateway` 확장은 전체 읽기뿐이라, 좁게 읽기는 여기서 `TaskforceReads`로 잇는다.
extension LiveChatGateway {
    public func agentSessionSnapshot(sessionIDs: Set<UUID>) async throws -> AgentSessionSnapshot {
        try await reads.agentSessionSnapshot(sessionIDs: sessionIDs)
    }
}
