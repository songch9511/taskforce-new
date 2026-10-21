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
            #expect(sent.method == "POST" && sent.url.path == "/api/v2/external-sessions/shown", "v1 metric-events는 동결이라 새 지표는 v2다")
            let body = try #require(sent.body)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
            #expect(object == ["rows_bucket": "2-5", "held_bucket": "1-2"])
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
            /// 성공한 보내기
            private(set) var calls: [(UUID, [ExternalSessionReportRow])] = []
            /// 시도한 모든 보내기 (실패 포함)
            private(set) var attempts: [(UUID, [ExternalSessionReportRow])] = []
            var failing = false
            /// 시도마다 앞에서 하나씩 쓴다: 오류면 던지고 nil이면 성공한다. 비면 `failing`을 따른다
            var script: [Error?] = []
            func send(_ bridge: UUID, _ rows: [ExternalSessionReportRow]) throws {
                lock.lock()
                defer { lock.unlock() }
                attempts.append((bridge, rows))
                if !script.isEmpty {
                    if let error = script.removeFirst() { throw error }
                    calls.append((bridge, rows))
                    return
                }
                if failing { throw URLError(.notConnectedToInternet) }
                calls.append((bridge, rows))
            }
            var count: Int { lock.withLock { calls.count } }
            var attemptCount: Int { lock.withLock { attempts.count } }
        }

        private func make(log: any BridgeLogSink = NoBridgeLog()) -> (ExternalSessionReporter, Sink, Clock) {
            let sink = Sink()
            let clock = Clock()
            return (ExternalSessionReporter(send: { try sink.send($0, $1) }, clock: { clock.now }, log: log), sink, clock)
        }

        static func http(_ status: Int, _ code: APIErrorCode = .notFound) -> APIError { .server(status: status, code: code, message: "") }

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

        // MARK: 서버가 꺼 둔 길 (404): 6시간 물러난다

        @Test func aNotFoundAnswerBacksOffForSixHoursInsteadOfRetryingEveryThirtySeconds() async {
            let (reporter, sink, clock) = make()
            sink.script = [Self.http(404)]
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.attemptCount == 1)
            for _ in 0..<10 {
                clock.advance(35)
                #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            }
            #expect(sink.attemptCount == 1, "30초마다 다시 부르지 않는다")
            #expect(await !reporter.report([R.row(1), R.row(2)], bridgeID: bridge), "목록이 바뀌어도 물러나는 동안은 보내지 않는다")
            clock.advance(6 * 3600 - 400)
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.attemptCount == 1, "6시간이 되기 전")
            clock.advance(120)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge), "6시간이 지나면 다시 시도하고 이번엔 닿는다")
            #expect(sink.attemptCount == 2 && sink.count == 1)
        }

        @Test func anUnexpectedFourOhFourWithoutTheEnvelopeBacksOffToo() async {
            let (reporter, sink, clock) = make()
            sink.script = [APIError.unexpectedStatus(404)]
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(3600)
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.attemptCount == 1)
        }

        @Test func otherFailuresStillRetryAfterThirtySecondsWithoutTheLongBackoff() async {
            for error in [Self.http(500, .internalError), Self.http(429, .rateLimited), Self.http(401, .unauthorized)] as [Error] {
                let (reporter, sink, clock) = make()
                sink.script = [error]
                _ = await reporter.report([R.row(1)], bridgeID: bridge)
                clock.advance(31)
                #expect(await reporter.report([R.row(1)], bridgeID: bridge), "\(error)")
                #expect(sink.attemptCount == 2)
            }
        }

        @Test func clearIgnoresTheBackoffBecauseItIsOneBestEffortCallAtSignOut() async {
            let (reporter, sink, clock) = make()
            sink.script = [Self.http(404)]
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            clock.advance(60)
            #expect(await reporter.clear(bridgeID: bridge))
            #expect(sink.calls.last?.1.isEmpty == true)
        }

        @Test func aSuccessfulSendEndsTheBackoffBookkeeping() async {
            let (reporter, sink, clock) = make()
            sink.script = [Self.http(404)]
            _ = await reporter.report([R.row(1)], bridgeID: bridge)
            #expect(await reporter.clear(bridgeID: bridge), "clear가 닿았다")
            clock.advance(40)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge), "닿았다면 물러남은 끝났다")
        }

        // MARK: 400: 제목을 모두 null로 해서 한 번 더

        @Test func anInvalidRequestIsResentOnceWithEveryTitleSetToNull() async {
            let (reporter, sink, clock) = make()
            sink.script = [Self.http(400, .invalidRequest), nil]
            let rows = [R.row(1), R.row(2, title: "Other")]
            #expect(await reporter.report(rows, bridgeID: bridge))
            #expect(sink.attemptCount == 2 && sink.count == 1)
            guard sink.attempts.count == 2 else { return }
            #expect(sink.attempts[0].1.map(\.title) == ["Title 1", "Other"])
            #expect(sink.attempts[1].1.map(\.title) == [nil, nil], "두 번째는 제목이 모두 null")
            #expect(sink.attempts[1].1.map(\.id) == sink.attempts[0].1.map(\.id), "id · 상태 · 시각은 그대로")
            #expect(sink.attempts[1].1.map(\.state) == sink.attempts[0].1.map(\.state))
            clock.advance(60)
            #expect(await !reporter.report(rows, bridgeID: bridge), "같은 목록을 30초마다 400으로 되풀이하지 않는다")
            #expect(sink.attemptCount == 2)
        }

        @Test func ifTheTitleFreeResendIsRejectedTooTheReporterBacksOff() async {
            let (reporter, sink, clock) = make()
            sink.script = [Self.http(400, .invalidRequest), Self.http(400, .invalidRequest)]
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.attemptCount == 2)
            clock.advance(40)
            #expect(await !reporter.report([R.row(1)], bridgeID: bridge))
            #expect(sink.attemptCount == 2, "제목을 빼도 거절하면 6시간 물러난다")
            clock.advance(6 * 3600)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge))
        }

        @Test func aRejectedListWithoutTitlesIsNotResentAndAnotherFailureIsNotResentEither() async {
            let (untitled, sinkA, _) = make()
            sinkA.script = [Self.http(400, .invalidRequest)]
            #expect(await !untitled.report([R.row(1, untitled: true)], bridgeID: bridge))
            #expect(sinkA.attemptCount == 1, "보낼 제목이 없으면 다시 보내도 소용없다")
            let (server, sinkB, _) = make()
            sinkB.script = [Self.http(500, .internalError)]
            #expect(await !server.report([R.row(1)], bridgeID: bridge))
            #expect(sinkB.attemptCount == 1, "400만 다시 보낸다")
        }

        // MARK: 스캔한 계정과 같은 계정으로만 보낸다

        @Test func aReportIsDroppedWhenTheAccountOrBridgeChangedSinceTheScan() async {
            let (reporter, sink, _) = make()
            let scanned = ExternalSessionOrigin(partition: "account-a", bridgeID: bridge)
            #expect(await !reporter.report([R.row(1)], origin: scanned, current: { ExternalSessionOrigin(partition: "account-b", bridgeID: UUID()) }), "다른 계정")
            #expect(await !reporter.report([R.row(1)], origin: scanned, current: { ExternalSessionOrigin(partition: "account-a", bridgeID: UUID()) }), "같은 파티션의 다른 bridge")
            #expect(await !reporter.report([R.row(1)], origin: scanned, current: { nil }), "로그아웃 · bridge 없음")
            #expect(sink.attemptCount == 0)
            // 버린 보고는 속도 조절을 쓰지 않는다
            #expect(await reporter.report([R.row(1)], origin: scanned, current: { scanned }))
            #expect(sink.calls.first?.0 == bridge, "스캔할 때 잡은 bridge로 보낸다")
        }

        @Test func theCurrentOriginIsAskedOnceAndBeforeTheSendNotAfter() async {
            let (reporter, sink, clock) = make()
            let scanned = ExternalSessionOrigin(partition: "account-a", bridgeID: bridge)
            let asked = Counter()
            let attemptsWhenAsked = Counter()
            let sent = await reporter.report([R.row(1)], origin: scanned, current: {
                asked.value += 1
                attemptsWhenAsked.value = sink.attemptCount
                return scanned
            })
            #expect(sent && sink.count == 1)
            #expect(asked.value == 1, "한 번 확인한다")
            #expect(attemptsWhenAsked.value == 0, "확인은 보내기 전에 한다")
            // 속도 조절에 걸려 안 보낼 때는 묻지도 않는다
            clock.advance(5)
            #expect(await !reporter.report([R.row(1), R.row(2)], origin: scanned, current: {
                asked.value += 1
                return scanned
            }))
            #expect(asked.value == 1)
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = 0
            var value: Int {
                get { lock.withLock { _value } }
                set { lock.withLock { _value = newValue } }
            }
        }

        // MARK: 로그: 구간 코드뿐

        @Test func failuresAreLoggedAsBucketCodesOnlyWithNoTextPathOrID() async {
            let table: [(Error, String)] = [
                (Self.http(404), "not_enabled"), (APIError.unexpectedStatus(404), "not_enabled"), (Self.http(400, .invalidRequest), "rejected"), (Self.http(401, .unauthorized), "auth"),
                (APIError.notSignedIn, "auth"), (Self.http(429, .rateLimited), "rate_limited"), (Self.http(500, .internalError), "server"), (APIError.unexpectedStatus(502), "server"),
                (APIError.transport("The request to /Users/tester/secret-title failed"), "network"), (URLError(.notConnectedToInternet), "network"), (CocoaError(.fileNoSuchFile), "other"),
            ]
            for (error, bucket) in table {
                let log = RecordingLog()
                let (reporter, sink, _) = make(log: log)
                sink.script = [error]
                _ = await reporter.report([R.row(1, untitled: true)], bridgeID: bridge)
                #expect(log.events.count == 1, "\(error)")
                #expect(log.events.first?.event == "external_sessions_report_failed")
                #expect(log.events.first?.fields == ["bucket": .code(bucket)], "\(error)")
                expectNoSentinel(in: log.events.map { "\($0.event) \($0.fields)" })
                let text = log.events.map { "\($0.event) \($0.fields)" }.joined()
                #expect(!text.contains("/Users") && !text.contains("secret") && !text.contains(ExternalSessionFixture.uuid(1)), "\(error)")
            }
            let quiet = RecordingLog()
            let (reporter, _, _) = make(log: quiet)
            #expect(await reporter.report([R.row(1)], bridgeID: bridge))
            #expect(quiet.events.isEmpty, "성공은 로그를 남기지 않는다")
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
