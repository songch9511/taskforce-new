#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 보내기를 대신하는 가짜: 부른 횟수를 세고, 답(서버에 닿았나)을 정하고, `hold`면 `release()`까지 붙잡는다
final class ClaudeAppSendScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var reached = true
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var calls: Int { lock.withLock { _calls } }
    func answer(_ reached: Bool) { lock.withLock { self.reached = reached } }
    func hold() { lock.withLock { holding = true } }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { waiting = [] }
            return waiting
        }
        for continuation in pending { continuation.resume() }
    }

    var send: @Sendable () async -> Bool {
        { [self] in
            let (answer, held) = lock.withLock { () -> (Bool, Bool) in
                _calls += 1
                return (reached, holding)
            }
            if held { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
            return answer
        }
    }
}

extension ExternalSessionSuites {
    /// 데스크톱 세션 보기를 연 날의 지표 (OA PR-D2, 계약 21.6): 종류만, UTC 날짜마다 한 번 서버에 닿았을 때만 그날을 적는다.
    /// 실패는 `retryInterval` 뒤 다음에 열 때 다시 (서버도 하루 한 번으로 거른다). 세션 id · 제목은 어디에도 가지 않는다 (보내기에 값이 없다)
    @MainActor
    struct ClaudeAppOpenedMetricTests {
        private func make(_ script: ClaudeAppSendScript, clock: ClaudeAppClock = ClaudeAppClock(), scope: AccountScope? = nil, log: any BridgeLogSink = NoBridgeLog()) -> ClaudeAppOpenedMetric {
            ClaudeAppOpenedMetric(send: script.send, scope: scope, now: { clock.now }, log: log)
        }

        private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }

        // MARK: 요청 (종류만)

        private func client(status: Int = 204, body: String = "") -> (APIClient, String) {
            let host = "t\(UUID().uuidString.lowercased().prefix(8)).test"
            StubProtocol.register(host: host, reply: .init(status: status, body: body))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubProtocol.self]
            return (APIClient(baseURL: URL(string: "https://\(host)")!, session: URLSession(configuration: configuration), token: { "token-123" }), host)
        }

        @Test func theMetricIsAPostToTheV2RouteWithAnEmptyObjectAndNothingElse() async throws {
            let (api, host) = client()
            try await api.claudeAppSessionOpened()
            let sent = try #require(StubProtocol.requests(host: host).last)
            #expect(sent.method == "POST" && sent.url.path == "/api/v2/external-sessions/claude-app-opened", "v1 metric-events는 동결이라 새 지표는 v2다")
            #expect(sent.headers["Authorization"] == "Bearer token-123")
            let body = try #require(sent.body)
            let object = try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
            #expect(object == [:], "종류만: 세션 id · 제목 · 폴더 · 그 밖의 칸이 하나도 없다")
        }

        @Test func aFailedMetricPostThrowsSoTheDayIsNotRecorded() async {
            let (api, _) = client(status: 500, body: "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
            await #expect(throws: APIError.self) { try await api.claudeAppSessionOpened() }
        }

        /// 서버에 닿았지만 세지 않았다 (아직 이 route가 없는 서버 = 404): 그날은 닿은 것으로 적는다 — 열 때마다 다시 보내 서버를 두드리지 않는다 (코드 검토 P3)
        @Test func aNotFoundAnswerIsReachedButNotCountedSoItDoesNotThrow() async throws {
            for body in [#"{"error":{"code":"not_found","message":"x"}}"#, "<html>Not Found</html>", ""] {
                let (api, host) = client(status: 404, body: body)
                try await api.claudeAppSessionOpened()
                #expect(StubProtocol.requests(host: host).count == 1, "한 번 보냈다")
            }
        }

        @Test func otherFailuresStillThrowSoTheyRetryLater() async {
            for status in [400, 401, 403, 429, 500, 502, 503] {
                let (api, _) = client(status: status, body: "")
                await #expect(throws: APIError.self, "\(status)") { try await api.claudeAppSessionOpened() }
            }
        }

        @Test func anOlderServerThatAnswers404IsAskedOnceADayNotOnEveryOpen() async {
            let (api, host) = client(status: 404, body: "<html>Not Found</html>")
            let clock = ClaudeAppClock(Date(timeIntervalSince1970: 1_800_000_000))
            let metric = ClaudeAppOpenedMetric(send: { (try? await api.claudeAppSessionOpened()) != nil }, now: { clock.now })
            metric.opened()
            #expect(await eventually { metric.lastSentDay != nil })
            for _ in 0..<5 {
                clock.advance(ClaudeAppOpenedMetric.retryInterval + 1)
                metric.opened()
            }
            try? await Task.sleep(for: .milliseconds(40))
            #expect(StubProtocol.requests(host: host).count == 1, "404는 그날 다시 보내지 않는다 (재시도 폭주 없음)")
        }

        // MARK: 하루 한 번

        @Test func theFirstOpenOfTheDaySendsOnceAndTheRestOfThatDayDoNot() async {
            let script = ClaudeAppSendScript()
            let clock = ClaudeAppClock(Date(timeIntervalSince1970: 1_800_000_000))
            let metric = make(script, clock: clock)
            metric.opened()
            #expect(await eventually { script.calls == 1 && metric.lastSentDay != nil })
            for _ in 0..<5 {
                clock.advance(60)
                metric.opened()
            }
            try? await Task.sleep(for: .milliseconds(40))
            #expect(script.calls == 1, "같은 UTC 날에는 한 번만 (열 때마다 보내지 않는다)")
        }

        @Test func theNextUTCDaySendsAgain() async {
            let script = ClaudeAppSendScript()
            // 2027-01-15 23:00 UTC
            let clock = ClaudeAppClock(Date(timeIntervalSince1970: 1_800_000_000 + 15 * 3600))
            let metric = make(script, clock: clock)
            metric.opened()
            #expect(await eventually { script.calls == 1 && metric.lastSentDay != nil })
            clock.advance(3599)
            metric.opened()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(script.calls == 1, "자정 1초 전")
            clock.advance(2)
            metric.opened()
            #expect(await eventually { script.calls == 2 }, "UTC 날짜가 바뀌면 다시")
        }

        @Test func aSendThatDidNotReachTheServerIsRetriedAfterTheIntervalNotBefore() async {
            let script = ClaudeAppSendScript()
            script.answer(false)
            let clock = ClaudeAppClock()
            let metric = make(script, clock: clock)
            metric.opened()
            #expect(await eventually { script.calls == 1 && !metric.isSending })
            #expect(metric.lastSentDay == nil, "닿지 못했으면 그날을 적지 않는다")
            clock.advance(ClaudeAppOpenedMetric.retryInterval - 1)
            metric.opened()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(script.calls == 1, "다시 보내기 전 간격 안")
            clock.advance(1)
            script.answer(true)
            metric.opened()
            #expect(await eventually { script.calls == 2 && metric.lastSentDay != nil })
        }

        @Test func aSendThatIsStillRunningIsNotStartedASecondTime() async {
            let script = ClaudeAppSendScript()
            script.hold()
            let metric = make(script)
            metric.opened()
            #expect(await eventually { script.calls == 1 })
            metric.opened()
            metric.opened()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(script.calls == 1)
            script.release()
            #expect(await eventually { metric.lastSentDay != nil })
        }

        @Test func leavingTheAccountForgetsTheDayAndDropsALateAnswer() async {
            let script = ClaudeAppSendScript()
            let user = UUID()
            let scope = AccountScope(currentAccount: { user })
            let metric = make(script, scope: scope)
            metric.opened()
            #expect(await eventually { metric.lastSentDay != nil })
            scope.accountLeft()
            #expect(metric.lastSentDay == nil)
            metric.opened()
            #expect(await eventually { script.calls == 2 }, "다른 계정은 그날 다시 보낸다")
            // 붙잡힌 보내기가 계정이 떠난 뒤에 돌아와도 새 계정의 날을 적지 않는다
            let slow = ClaudeAppSendScript()
            slow.hold()
            let second = make(slow, scope: scope)
            second.opened()
            #expect(await eventually { slow.calls == 1 })
            scope.accountLeft()
            slow.release()
            try? await Task.sleep(for: .milliseconds(40))
            #expect(second.lastSentDay == nil, "옛 계정의 늦은 답은 버린다")
        }

        @Test func aFailureIsLoggedAsAFixedCodeWithNoValues() async {
            let script = ClaudeAppSendScript()
            script.answer(false)
            let log = RecordingLog()
            let metric = make(script, log: log)
            metric.opened()
            #expect(await eventually { script.calls == 1 && !metric.isSending })
            #expect(log.events.map(\.event) == ["claude_app_opened_failed"])
            #expect(log.events.allSatisfy { $0.fields.isEmpty }, "값 없음")
        }
    }
}
#endif
