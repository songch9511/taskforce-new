#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 서버로 가는 것 (계약 16장 · 17장): 제목 · 상태 · 마지막 활동 · 불투명 id뿐. 모양은 서버 zod(`externalSessionReportRequestSchema`)와 같다
    struct ExternalSessionReportTests {
        typealias F = ExternalSessionFixture
        static let now = Date(timeIntervalSince1970: 1_792_400_000)
        static let key = ExternalSessionKey(bytes: Data(repeating: 3, count: 32))

        static func row(_ n: Int, title: String = "", untitled: Bool = false, status: ExternalSessionStatus = .available, folder: String? = "/Users/tester/proj") -> ExternalSessionRow {
            ExternalSessionRow(
                id: F.uuid(n), ref: key.ref(forSessionID: F.uuid(n)), title: untitled ? nil : (title.isEmpty ? "Title \(n)" : title), folderPath: folder, groupPath: folder, lastActivity: now.addingTimeInterval(-Double(n) * 60),
                created: now.addingTimeInterval(-Double(n) * 3600), client: .terminal, status: status
            )
        }

        @Test func everyStatusFoldsIntoOneOfTheServerSixWords() {
            let table: [(ExternalSessionStatus, String?)] = [
                (.available, "available"), (.held(.claudeApp), "running_claude_app"), (.held(.terminal), "running_terminal"), (.held(.background), "running_elsewhere"),
                (.held(.unknown), "running_elsewhere"), (.couldNotCheck, "unknown"), (.cannotResume(.worktree), "unavailable"), (.cannotResume(.folderNotAllowed), "unavailable"),
                (.cannotResume(.unreadable), "unavailable"), (.cannotResume(.updateClaudeCode), "unavailable"), (.inTaskforce, nil),
            ]
            for (status, word) in table { #expect(ExternalSessionReport.state(for: status) == word, "\(status)") }
            let allowed: Set<String> = ["available", "running_claude_app", "running_terminal", "running_elsewhere", "unknown", "unavailable"]
            #expect(Set(table.compactMap(\.1)).isSubset(of: allowed))
        }

        @Test func aRowCarriesOnlyTheOpaqueIDTheTitleTheStateAndTheTime() throws {
            let rows = ExternalSessionReport.rows(from: [Self.row(1)])
            let data = try JSONEncoder().encode(rows)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            #expect(Set(object[0].keys) == ["id", "title", "state", "last_activity_at"])
            #expect(object[0]["id"] as? String == Self.key.ref(forSessionID: F.uuid(1)))
            #expect(object[0]["title"] as? String == "Title 1")
            #expect(object[0]["state"] as? String == "available")
            #expect(object[0]["last_activity_at"] as? String == "2026-10-21T01:24:20Z" || (object[0]["last_activity_at"] as? String)?.hasSuffix("Z") == true)
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("/Users") && !text.contains("proj") && !text.contains(F.uuid(1)) && !text.contains("5e5e5e5e"))
        }

        @Test func aMissingTitleIsAnExplicitNullBecauseTheServerSchemaIsStrict() throws {
            let data = try JSONEncoder().encode(ExternalSessionReport.rows(from: [Self.row(1, untitled: true)]))
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"title\":null"))
        }

        @Test func theFieldsSatisfyTheServerPatterns() throws {
            let rows = ExternalSessionReport.rows(from: [Self.row(1, title: "Fix\nthe \u{202E}launcher"), Self.row(2, title: String(repeating: "가", count: 500))])
            for item in rows {
                #expect(item.id.wholeMatch(of: /[0-9a-f]{64}/) != nil)
                #expect(item.lastActivityAt.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/) != nil)
                if let title = item.title {
                    #expect(title.utf16.count >= 1 && title.utf16.count <= 200)
                    #expect(title == title.trimmingCharacters(in: .whitespacesAndNewlines))
                    #expect(!title.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) })
                }
            }
            #expect(rows[0].title == "Fix the launcher")
        }

        @Test func sessionsAlreadyInTaskforceAreNotReportedAndTheListIsCappedAt50() {
            let many = (1...80).map { Self.row($0) } + [Self.row(200, status: .inTaskforce)]
            #expect(ExternalSessionReport.rows(from: many).count == 50)
            #expect(ExternalSessionReport.rows(from: [Self.row(1, status: .inTaskforce), Self.row(2)]).count == 1)
            #expect(ExternalSessionReport.maxRows == 50)
            let ids = ExternalSessionReport.rows(from: (1...50).map { Self.row($0) }).map(\.id)
            #expect(Set(ids).count == 50)
        }

        // MARK: 요청

        private func client(status: Int = 200, body: String = "{}") -> (APIClient, String) {
            let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
            StubProtocol.register(host: host, reply: .init(status: status, body: body))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
        }

        @Test func theReportIsAPutToTheV2RouteWithTheBridgeAndTheRows() async throws {
            let (api, host) = client(body: "{\"kept\":1,\"removed\":0}")
            let bridge = UUID()
            try await api.reportExternalSessions(bridgeID: bridge, rows: ExternalSessionReport.rows(from: [Self.row(1)]))
            let sent = try #require(StubProtocol.requests(host: host).last)
            #expect(sent.method == "PUT" && sent.url.path == "/api/v2/external-sessions")
            #expect(sent.headers["Authorization"] == "Bearer token-123")
            let body = try #require(sent.body)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(object.keys) == ["bridge_id", "sessions"])
            #expect(object["bridge_id"] as? String == bridge.uuidString.lowercased())
            #expect((object["sessions"] as? [[String: Any]])?.count == 1)
        }

        @Test func aServerErrorSurfacesSoTheReporterRetriesLater() async {
            let (api, _) = client(status: 404, body: "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
            await #expect(throws: APIError.self) { try await api.reportExternalSessions(bridgeID: UUID(), rows: []) }
        }

        @Test func theShownMetricIsAPostWithBucketsOnlyAndTheEmptyReplyIsFine() async throws {
            let (api, host) = client(status: 204, body: "")
            try await api.externalSessionsShown(rowsBucket: "2-5", heldBucket: "1-2")
            let sent = try #require(StubProtocol.requests(host: host).last)
            #expect(sent.method == "POST" && sent.url.path == "/api/v1/metric-events")
            let body = try #require(sent.body)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
            #expect(object == ["type": "external_sessions_shown", "props": ["rows_bucket": "2-5", "held_bucket": "1-2"]])
        }

        @Test func aFailedMetricPostThrows() async {
            let (api, _) = client(status: 500, body: "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
            await #expect(throws: APIError.self) { try await api.externalSessionsShown(rowsBucket: "1", heldBucket: "0") }
        }

        @Test func theMetricBucketsAreExactlyTheOnesTheServerAccepts() {
            #expect(ExternalSessionsShownBuckets.rows == ["1", "2-5", "6-15", "16+"])
            #expect(ExternalSessionsShownBuckets.held == ["0", "1-2", "3+"])
            for count in 0...60 {
                #expect(ExternalSessionsShownBuckets.rows.contains(ExternalSessionRules.rowsBucket(count)))
                #expect(ExternalSessionsShownBuckets.held.contains(ExternalSessionRules.heldBucket(count)))
            }
        }
    }

    /// 보고 속도 조절 (30초 · 바뀐 것만 · 6시간 keepalive · 실패는 다음에 다시)
    struct ExternalSessionReporterTests {
        typealias R = ExternalSessionReportTests

        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var date = ExternalSessionReportTests.now
            var now: Date { lock.withLock { date } }
            func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
        }

        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var calls: [(UUID, [ExternalSessionReportRow])] = []
            var failing = false
            func send(_ bridge: UUID, _ rows: [ExternalSessionReportRow]) throws {
                lock.lock()
                defer { lock.unlock() }
                if failing { throw URLError(.notConnectedToInternet) }
                calls.append((bridge, rows))
            }
            var count: Int { lock.withLock { calls.count } }
        }

        private func make() -> (ExternalSessionReporter, Sink, Clock) {
            let sink = Sink()
            let clock = Clock()
            return (ExternalSessionReporter(send: { try sink.send($0, $1) }, clock: { clock.now }), sink, clock)
        }

        let bridge = UUID()

        @Test func theFirstReportIsSentAndAnUnchangedOneIsNot() async {
            let (reporter, sink, clock) = make()
            #expect(await reporter.report([R.row(1)], bridgeID: bridge))
            clock.advance(60)
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.count == 1)
        }

        @Test func aChangeIsSentAfterThirtySecondsButNotBefore() async {
            let (reporter, sink, clock) = make()
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(10)
            #expect(await !reporter.report([R.row(1), R.row(2)], bridgeID: bridge))
            clock.advance(25)
            #expect(await reporter.report([R.row(1), R.row(2)], bridgeID: bridge))
            #expect(sink.count == 2)
            #expect(sink.calls.last?.1.count == 2)
        }

        @Test func aTitleOrStateChangeCountsAsAChange() async {
            let (reporter, sink, clock) = make()
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(40)
            #expect(await reporter.report([R.row(1, title: "Renamed")], bridgeID: bridge))
            clock.advance(40)
            #expect(await reporter.report([R.row(1, title: "Renamed", status: .held(.claudeApp))], bridgeID: bridge))
            #expect(sink.count == 3)
        }

        @Test func anUnchangedListIsSentAgainAfterTheSixHourKeepalive() async {
            let (reporter, sink, clock) = make()
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(6 * 3600 - 60)
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            clock.advance(120)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.count == 2)
        }

        @Test func aFailedSendIsRetriedAfterTheIntervalAndNotRememberedAsSent() async {
            let (reporter, sink, clock) = make()
            sink.failing = true
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            clock.advance(10)
            sink.failing = false
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge), "30초 안에는 다시 시도하지 않는다")
            clock.advance(25)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.count == 1)
        }

        @Test func anotherBridgeIsSentEvenWithTheSameRows() async {
            let (reporter, sink, clock) = make()
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(40)
            #expect(await reporter.report([R.row(1)], bridgeID: UUID()))
            #expect(sink.count == 2)
        }

        @Test func clearSendsAnEmptyListWithoutWaitingAndResetForgets() async {
            let (reporter, sink, clock) = make()
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            #expect(await reporter.clear(bridgeID: bridge))
            #expect(sink.calls.last?.1.isEmpty == true)
            clock.advance(40)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge), "비운 뒤에는 같은 목록도 다시 보낸다")
            await reporter.reset()
            clock.advance(1)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge), "초기화하면 마지막으로 보낸 값을 잊고 속도 조절도 잊는다")
        }

        @Test func rowsAlreadyInTaskforceAreNotPartOfTheComparison() async {
            let (reporter, sink, clock) = make()
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(60)
            #expect(await !reporter.report([R.row(1), R.row(2, status: .inTaskforce)], bridgeID: bridge))
            #expect(sink.count == 1)
        }
    }
}
#endif
