#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// `GET claude-app-chats/status`를 대신하는 가짜: 정해 둔 답을 차례로 내고 부른 횟수를 센다
final class ClaudeAppStatusScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<ClaudeAppChatsStatus, APIError>] = []
    private var _calls = 0
    private var _onCall: (@Sendable () -> Void)?
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var calls: Int { lock.withLock { _calls } }
    func queue(_ answer: Result<ClaudeAppChatsStatus, APIError>...) { lock.withLock { answers += answer } }

    /// 답을 내지 않고 붙들어 둔다 (느린 서버): `release()`가 풀어 줄 때까지 `status()`가 돌아오지 않는다
    func hold() { lock.withLock { holding = true } }

    func release() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    private func waitWhileHeld() async {
        guard lock.withLock({ holding }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                guard holding else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
    /// 부를 때마다 (답을 내기 전에) 한 번 부른다: 부르는 순서를 본다
    var onCall: (@Sendable () -> Void)? {
        get { lock.withLock { _onCall } }
        set { lock.withLock { _onCall = newValue } }
    }

    var status: ClaudeAppChatSaver.Status {
        { [self] in
            onCall?()
            await waitWhileHeld()
            let answer = lock.withLock { () -> Result<ClaudeAppChatsStatus, APIError> in
                _calls += 1
                return answers.isEmpty ? .success(ClaudeAppChatsStatus(save: true)) : (answers.count == 1 ? answers[0] : answers.removeFirst())
            }
            return try answer.get()
        }
    }
}

extension ExternalSessionSuites {
    /// 저장 켜짐 확인 + 업로더의 주인 (PR-D3k, 계약 25.4.5 · 위협 DT14): 글을 보내기 전에 `status`를 묻고, 저장이 켜졌을 때만 업로더가 있다. 404면 서버로 가는 것이 하나도 없다.
    /// 앱 시작 · 로그인 때와 1시간마다 다시 묻는다 (확인 못 했으면 1분 뒤). 실제 서버는 부르지 않는다
    struct ClaudeAppChatSaverTests {
        let bridge = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let clock = ClaudeAppClock()

        private func row(_ n: Int) -> ClaudeAppChatRow {
            ClaudeAppChatRow(
                macRef: String(format: "%064x", n), role: n == 1 ? .user : .assistant, replyToRef: n == 1 ? nil : String(format: "%064x", 1), body: "row \(n)", truncated: false,
                saidAt: Date(timeIntervalSince1970: 1_800_000_000), toolNames: []
            )
        }

        private func batch(_ count: Int, exchange: String = "x1") -> ClaudeAppChatBatch {
            ClaudeAppChatBatch(exchangeID: exchange, context: ClaudeAppChatContext(bridgeID: bridge, sessionRef: String(repeating: "b", count: 64), title: nil), rows: (1...count).map(row))
        }

        private func saver(_ status: ClaudeAppStatusScript, _ put: ClaudeAppPutScript, sleeper: ClaudeAppManualSleeper = ClaudeAppManualSleeper(), log: RelayLog = RelayLog()) -> ClaudeAppChatSaver {
            ClaudeAppChatSaver(status: status.status, put: put.put, now: { [clock] in clock.now }, sleep: { await sleeper.sleep($0) }, log: log)
        }

        private func notFound() -> APIError { .server(status: 404, code: .notFound, message: "") }

        // MARK: DT14 — 저장이 꺼져 있으면 서버로 한 바이트도 가지 않는다

        @Test func aNotFoundStatusMeansNoUploaderAndNothingIsEverPut() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.failure(notFound()))
            let put = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            #expect(await saver.refresh() == false, "404는 확정이다: 1시간 뒤에 다시 묻는다")
            #expect(await !saver.isSaving)
            await saver.enqueue(batch(3))
            sleeper.advance(600)
            try await Task.sleep(for: .milliseconds(40))
            #expect(put.requests.isEmpty, "업로더가 없으니 올릴 길이 없다")
        }

        @Test func aStatusWithSaveFalseIsTheSameAsNotFound() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: false)))
            let put = ClaudeAppPutScript()
            let saver = saver(status, put)
            _ = await saver.refresh()
            await saver.enqueue(batch(2))
            #expect(await !saver.isSaving && put.requests.isEmpty)
        }

        @Test func aStatusThatCouldNotBeAskedLeavesNoUploaderAndAsksAgainSoon() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.failure(.transport("offline")))
            let put = ClaudeAppPutScript()
            let saver = saver(status, put)
            #expect(await saver.refresh() == true, "못 물었다: 1분 뒤 다시")
            #expect(await !saver.isSaving, "모를 때는 올리지 않는다")
            await saver.enqueue(batch(2))
            #expect(put.requests.isEmpty)
        }

        // MARK: 켜졌을 때

        @Test func aStatusOfSaveTrueCreatesTheUploaderWithTheServersLimitsAndRowsGoOutOnTheLoop() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: true, maxBatch: 5, maxBytes: 262_144)))
            let put = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            _ = await saver.refresh()
            #expect(await saver.isSaving)
            await saver.enqueue(batch(12))
            #expect(await relayEventually { sleeper.pending >= 1 })
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 3 })
            #expect(put.requests.map(\.messages.count) == [5, 5, 2], "서버가 말한 max_batch(5)로 나눈다")
        }

        @Test func askingAgainWhileOnKeepsTheSameUploaderAndItsQueue() async throws {
            let status = ClaudeAppStatusScript()
            let put = ClaudeAppPutScript()
            put.queue(.retry)
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            _ = await saver.refresh()
            await saver.enqueue(batch(2))
            #expect(await relayEventually { sleeper.pending >= 1 })
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 1 })
            _ = await saver.refresh()
            clock.advance(2)
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 2 }, "다시 물어도 큐는 그대로: 물러난 행이 이어서 올라간다")
        }

        @Test func aLaterNotFoundTearsTheUploaderDownAndDropsWhatWasQueued() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: true)), .failure(notFound()))
            let put = ClaudeAppPutScript()
            put.queue(.retry)
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            _ = await saver.refresh()
            await saver.enqueue(batch(2))
            #expect(await relayEventually { sleeper.pending >= 1 })
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 1 })
            _ = await saver.refresh()
            #expect(await !saver.isSaving)
            clock.advance(100)
            sleeper.advance(100)
            try await Task.sleep(for: .milliseconds(40))
            #expect(put.requests.count == 1, "꺼진 뒤에는 한 바이트도 안 간다")
        }

        @Test func aTransientFailureOfALaterStatusKeepsTheRunningUploader() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: true)), .failure(.transport("offline")))
            let put = ClaudeAppPutScript()
            let saver = saver(status, put)
            _ = await saver.refresh()
            #expect(await saver.refresh() == true)
            #expect(await saver.isSaving, "네트워크가 잠깐 끊겼다고 큐를 버리지 않는다")
        }

        @Test func theUploaderTurningItselfOffOnANotFoundPutLeavesTheSaverNotSaving() async throws {
            let status = ClaudeAppStatusScript()
            let put = ClaudeAppPutScript()
            put.queue(.disabled)
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            _ = await saver.refresh()
            await saver.enqueue(batch(2))
            #expect(await relayEventually { sleeper.pending >= 1 })
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 1 })
            var off = false
            for _ in 0..<400 {
                if await !saver.isSaving {
                    off = true
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(off, "업로더가 스스로 꺼지면 주인도 저장 중이 아니다")
        }

        // MARK: 버린 업로더 (OA PR-D3 검토 P3-7) · 느린 status (P2-3)

        @Test func aLateDisabledReportFromARetiredUploaderDoesNotTearDownTheCurrentOne() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: true)), .success(ClaudeAppChatsStatus(save: false)), .success(ClaudeAppChatsStatus(save: true)))
            let saver = saver(status, ClaudeAppPutScript())
            _ = await saver.refresh()
            let first = try #require(await saver.uploaderIdentity)
            _ = await saver.refresh()
            let gone = await saver.uploaderIdentity
            let goneSaving = await saver.isSaving
            #expect(gone == nil && !goneSaving)
            _ = await saver.refresh()
            let second = try #require(await saver.uploaderIdentity)
            #expect(first != second)
            await saver.uploaderDisabled(first)
            let stillOn = await saver.isSaving
            #expect(stillOn, "버린 업로더의 늦은 `disabled` 알림은 지금 업로더를 끄지 못한다")
            await saver.uploaderDisabled(second)
            let off = await saver.isSaving
            #expect(!off, "지금 업로더의 알림은 끈다")
        }

        @Test func theSaverSaysWhetherAnExchangesUserRowWasSaved() async throws {
            let status = ClaudeAppStatusScript()
            let put = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            _ = await saver.refresh()
            await saver.enqueue(batch(2, exchange: "x9"))
            #expect(await relayEventually { sleeper.pending >= 1 })
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 1 })
            var saved = false
            for _ in 0..<200 {
                saved = await saver.userRowSaved("x9")
                if saved { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(saved)
            let other = await saver.userRowSaved("x-other")
            #expect(!other)
        }

        @Test func aStatusCallThatNeverAnswersEndsAsAnUnknownAnswerAfterTheTimeoutAndAFastOneIsLeftAlone() async throws {
            do {
                _ = try await ClaudeAppChatSaver.timed(seconds: 0.05) {
                    try await Task.sleep(for: .seconds(30))
                    return ClaudeAppChatsStatus(save: true)
                }
                Issue.record("답이 없는데 던지지 않았다")
            } catch {
                #expect((error as? APIError) == .transport("status timed out"), "모르는 답으로 끝난다: 저장은 켜지 않고 1분 뒤 다시 묻는다")
            }
            let fast = try await ClaudeAppChatSaver.timed(seconds: 5) { ClaudeAppChatsStatus(save: true) }
            #expect(fast == ClaudeAppChatsStatus(save: true))
        }

        // MARK: 다시 묻기

        @Test func theLoopAsksAtOnceThenEveryHourAndAfterAFailureInAMinute() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: true)), .failure(.transport("offline")), .success(ClaudeAppChatsStatus(save: true)))
            let put = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            await saver.startRefreshing()
            #expect(await relayEventually { status.calls == 1 && sleeper.requested.contains(3600) })
            sleeper.advance(3600)
            #expect(await relayEventually { status.calls == 2 && sleeper.requested.contains(60) }, "못 물었으면 1분 뒤")
            sleeper.advance(60)
            #expect(await relayEventually { status.calls == 3 })
            await saver.stopRefreshing()
        }

        @Test func ensureAskedAsksOnceBeforeTheFirstSendThenHourlyAndNeverAtStartup() async throws {
            let status = ClaudeAppStatusScript()
            let put = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            #expect(status.calls == 0, "만들기만 해서는 서버를 부르지 않는다")
            await saver.ensureAsked()
            let saving = await saver.isSaving
            #expect(status.calls == 1 && saving)
            await saver.ensureAsked()
            #expect(status.calls == 1, "처음 한 번만")
            #expect(await relayEventually { sleeper.requested.contains(3600) })
            sleeper.advance(3600)
            #expect(await relayEventually { status.calls == 2 }, "그 뒤 1시간마다")
            await saver.stopRefreshing()
        }

        @Test func ensureAskedThatCouldNotAskRetriesInAMinuteAndAfterALogoutItAsksAgain() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.failure(.transport("offline")), .success(ClaudeAppChatsStatus(save: true)))
            let put = ClaudeAppPutScript()
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            await saver.ensureAsked()
            #expect(await !saver.isSaving && status.calls == 1)
            #expect(await relayEventually { sleeper.requested.contains(60) })
            sleeper.advance(60)
            #expect(await relayEventually { status.calls == 2 })
            #expect(await relayEventually { sleeper.requested.contains(3600) })
            await saver.clear()
            await saver.ensureAsked()
            #expect(status.calls == 3, "로그아웃 뒤 처음 보내는 글 앞에서 다시 묻는다")
            await saver.stopRefreshing()
        }

        // MARK: 로그아웃

        @Test func clearingOnLogoutDropsTheUploaderAndTheQueueAndALoginAsksAgain() async throws {
            let status = ClaudeAppStatusScript()
            let put = ClaudeAppPutScript()
            put.queue(.retry)
            let sleeper = ClaudeAppManualSleeper()
            let saver = saver(status, put, sleeper: sleeper)
            _ = await saver.refresh()
            await saver.enqueue(batch(2))
            #expect(await relayEventually { sleeper.pending >= 1 })
            sleeper.advance(2)
            #expect(await relayEventually { put.requests.count == 1 })
            await saver.clear()
            #expect(await !saver.isSaving)
            clock.advance(100)
            sleeper.advance(100)
            try await Task.sleep(for: .milliseconds(40))
            #expect(put.requests.count == 1, "로그아웃 뒤에는 보내지 않는다")
            _ = await saver.refresh()
            #expect(await saver.isSaving, "다시 로그인하면 새 업로더")
        }

        @Test func theLogHoldsFixedCodesOnly() async throws {
            let status = ClaudeAppStatusScript()
            status.queue(.success(ClaudeAppChatsStatus(save: true)), .failure(notFound()))
            let log = RelayLog()
            let saver = saver(status, ClaudeAppPutScript(), log: log)
            _ = await saver.refresh()
            _ = await saver.refresh()
            #expect(log.events("claude_app_chat_status").map { $0["result"] } == [.code("on"), .code("off")])
            #expect(!log.text.contains("11111111"))
        }
    }
}
#endif
