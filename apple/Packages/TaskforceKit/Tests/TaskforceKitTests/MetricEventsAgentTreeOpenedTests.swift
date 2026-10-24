#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 트리 열기 지표 둘(T3m): `project_sessions_opened` · `subagent_row_opened`. 종류만 알린다 — 본문은 빈 객체이고 세션 id · 이름 · 폴더는 어디에도 없다.
/// v1 `metric-events`는 동결이라 v2 route다 (`POST /api/v2/agent-tree/project-sessions-opened` · `/subagent-opened`, 서버는 204). 실패는 던지고 앱은 조용히 버린다
@MainActor
struct MetricEventsAgentTreeOpenedTests {
    private func client(status: Int = 204, body: String = "") -> (APIClient, String) {
        let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
        StubProtocol.register(host: host, reply: .init(status: status, body: body))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
    }

    private func assertKindOnly(_ host: String, path: String) throws {
        let sent = try #require(StubProtocol.requests(host: host).last)
        #expect(sent.method == "POST" && sent.url.path == path, "v2 route")
        #expect(sent.headers["Authorization"] == "Bearer token-123")
        let body = try #require(sent.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
        #expect(object == [:], "종류만: 세션 id · 제목 · 폴더 · 그 밖의 칸이 하나도 없다")
    }

    @Test func theProjectSessionsMetricIsAnEmptyObjectPostToItsV2Route() async throws {
        let (api, host) = client()
        try await api.projectSessionsOpened()
        try assertKindOnly(host, path: "/api/v2/agent-tree/project-sessions-opened")
    }

    @Test func theSubagentRowMetricIsAnEmptyObjectPostToItsV2Route() async throws {
        let (api, host) = client()
        try await api.subagentRowOpened()
        try assertKindOnly(host, path: "/api/v2/agent-tree/subagent-opened")
    }

    /// 서버에 닿았지만 세지 않았다 (아직 이 route가 없는 서버 = 404): 던지지 않는다 — 앱이 그날을 닿은 것으로 적어 열 때마다 서버를 두드리지 않는다
    @Test func aNotFoundAnswerIsReachedButNotCountedSoNeitherCallThrows() async throws {
        for body in [#"{"error":{"code":"not_found","message":"x"}}"#, "<html>Not Found</html>", ""] {
            let (api, host) = client(status: 404, body: body)
            try await api.projectSessionsOpened()
            try await api.subagentRowOpened()
            #expect(StubProtocol.requests(host: host).count == 2)
        }
    }

    @Test func otherFailuresThrowSoTheyAreRetriedLaterAndNeverBreakTheScreen() async {
        for status in [400, 401, 403, 429, 500, 502, 503] {
            let (api, _) = client(status: status, body: "")
            await #expect(throws: APIError.self, "\(status)") { try await api.projectSessionsOpened() }
            await #expect(throws: APIError.self, "\(status)") { try await api.subagentRowOpened() }
        }
    }

    // MARK: 지표 묶음: 하루 한 번 · 서버에 닿았을 때만

    final class FakeGateway: AgentTreeOpenedGateway, @unchecked Sendable {
        private let lock = NSLock()
        private var _shown = 0
        private var _opened = 0
        var reaches = true
        var shown: Int { lock.withLock { _shown } }
        var opened: Int { lock.withLock { _opened } }
        func projectSessionsOpened() async throws {
            lock.withLock { _shown += 1 }
            if !reaches { throw APIError.unexpectedStatus(500) }
        }
        func subagentRowOpened() async throws {
            lock.withLock { _opened += 1 }
            if !reaches { throw APIError.unexpectedStatus(500) }
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    @Test func eachMetricGoesToItsOwnCallOncePerDayEvenIfAskedManyTimes() async {
        let gateway = FakeGateway()
        let clock = ClaudeAppClock()
        let metrics = AgentTreeMetrics(gateway: gateway, scope: nil, now: { clock.now })
        for _ in 0..<5 { metrics.projectSessions.opened() }
        #expect(await eventually { gateway.shown == 1 })
        for _ in 0..<5 { metrics.subagentRow.opened() }
        #expect(await eventually { gateway.opened == 1 })
        try? await Task.sleep(for: .milliseconds(40))
        #expect(gateway.shown == 1 && gateway.opened == 1, "같은 UTC 날에는 각각 한 번")
        clock.advance(86_400)
        metrics.projectSessions.opened()
        #expect(await eventually { gateway.shown == 2 }, "다음 날에는 다시")
    }

    @Test func aMetricThatDidNotReachTheServerIsNotRecordedAsTheDay() async {
        let gateway = FakeGateway()
        gateway.reaches = false
        let clock = ClaudeAppClock()
        let metrics = AgentTreeMetrics(gateway: gateway, scope: nil, now: { clock.now })
        metrics.projectSessions.opened()
        #expect(await eventually { gateway.shown == 1 && !metrics.projectSessions.isSending })
        #expect(metrics.projectSessions.lastSentDay == nil)
    }

    @Test func leavingTheAccountForgetsBothDays() async {
        let gateway = FakeGateway()
        let user = UUID()
        let scope = AccountScope(currentAccount: { user })
        let metrics = AgentTreeMetrics(gateway: gateway, scope: scope, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        metrics.projectSessions.opened()
        metrics.subagentRow.opened()
        #expect(await eventually { metrics.projectSessions.lastSentDay != nil && metrics.subagentRow.lastSentDay != nil })
        scope.accountLeft()
        #expect(metrics.projectSessions.lastSentDay == nil && metrics.subagentRow.lastSentDay == nil)
    }
}
#endif
