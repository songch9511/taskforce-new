import Foundation

public protocol AgentTreeOpenedGateway: Sendable {
    func projectSessionsOpened() async throws
    func subagentRowOpened() async throws
}

extension APIClient: AgentTreeOpenedGateway {
    public func projectSessionsOpened() async throws { try await agentTreeOpened("project-sessions-opened") }
    public func subagentRowOpened() async throws { try await agentTreeOpened("subagent-opened") }

    private func agentTreeOpened(_ route: String) async throws {
        struct Empty: Decodable {}
        struct Body: Encodable {}
        do {
            let _: Empty = try await send(.post, "agent-tree/\(route)", body: Body(), version: .v2)
        } catch APIError.decoding {
        } catch APIError.server(status: 404, _, _) {
        } catch APIError.unexpectedStatus(404) {
        }
    }
}

extension LiveChatGateway: AgentTreeOpenedGateway {
    public func projectSessionsOpened() async throws { try await api.projectSessionsOpened() }
    public func subagentRowOpened() async throws { try await api.subagentRowOpened() }
}

#if os(macOS)
/// Uses the existing account-scoped UTC-day throttle; no session content is sent.
public typealias AgentTreeOpenedMetric = ClaudeAppOpenedMetric

@MainActor
public final class AgentTreeMetrics {
    public let projectSessions: AgentTreeOpenedMetric
    public let subagentRow: AgentTreeOpenedMetric

    public init(projectSessions: AgentTreeOpenedMetric, subagentRow: AgentTreeOpenedMetric) {
        self.projectSessions = projectSessions
        self.subagentRow = subagentRow
    }

    public convenience init(gateway: any AgentTreeOpenedGateway, scope: AccountScope?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(
            projectSessions: AgentTreeOpenedMetric(send: { do { try await gateway.projectSessionsOpened(); return true } catch { return false } }, scope: scope, now: now),
            subagentRow: AgentTreeOpenedMetric(send: { do { try await gateway.subagentRowOpened(); return true } catch { return false } }, scope: scope, now: now)
        )
    }
}
#endif
