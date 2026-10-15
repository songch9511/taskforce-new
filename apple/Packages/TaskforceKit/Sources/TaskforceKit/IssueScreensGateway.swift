import Foundation

/// OA U2 화면(Issues · 이슈 목록 · 이슈 상세 · 세션 패널)이 서버를 읽는 면: 번호 · 이슈 상세 · 세션 (모두 RLS select).
/// 실제 연결은 `LiveChatGateway`(앱이 Chats 런타임에 이미 가진 읽기)가 따른다. 견본 · 시험은 가짜를 넣는다
public protocol IssueScreensGateway: IssueNumberGateway, AgentSessionGateway, IssueDetailGateway {}

extension LiveChatGateway: IssueScreensGateway {
    public func actionNumbers(ids: [UUID]) async throws -> [UUID: Int] { try await reads.actionNumbers(ids: ids) }
    public func issueDetail(id: UUID) async throws -> ActionDetail { try await reads.actionDetail(id: id) }
    public func agentSessionSnapshot() async throws -> AgentSessionSnapshot { try await reads.agentSessionSnapshot() }
}
