import AppKit
import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit

/// 종료 때 보류 중인 답 (OA D4b-m-1, D4bm-22): 비밀값이 아닌 답은 곧바로 보내고 끝나거나 3초가 지나면 bridge 종료 응답으로 넘긴다. **비밀값 답은 보내지 않고 값을 버린다**.
/// 서버는 가짜(`AgentChatSampleGateway`)이고 종료 응답(`NSApp.reply`)은 가짜 함수로 받는다 — 실제 앱을 끝내지 않는다
@MainActor
struct MacQuitAnswersTests {
    typealias Data = AgentChatSampleData
    typealias Q = QuestionSampleData

    final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Bool] = []
        var values: [Bool] { lock.withLock { _values } }
        func add(_ value: Bool) { lock.withLock { _values.append(value) } }
    }

    private func store(_ pending: [String: Any], secrets: (any LocalSecretAnswerSubmitting)? = nil) async throws -> (AgentQuestionStore, AgentChatSampleGateway, QuestionTicker) {
        let gateway = AgentChatSampleGateway()
        gateway.state = Q.world(pending)
        let ticker = QuestionTicker()
        let store = AgentQuestionStore(gateway: gateway, scope: AccountScope(currentAccount: { UUID(uuidString: "00000000-0000-4000-8000-0000000000aa") }), secrets: secrets, sleep: { await ticker.sleep($0) })
        store.thisMacBridgeID = Data.thisMacBridge
        store.sessionsRead([QFxItem.make()])
        await store.settle()
        return (store, gateway, ticker)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func withNothingHeldItIsExactlyTheBridgesReply() async throws {
        let (store, gateway, _) = try await store(Q.single)
        let replies = Replies()
        for bridge in [NSApplication.TerminateReply.terminateNow, .terminateCancel, .terminateLater] {
            let reply = MacAppDelegate.terminationReply(questions: store, bridgeReply: { bridge }, reply: { replies.add($0) })
            #expect(reply == bridge)
        }
        #expect(MacAppDelegate.terminationReply(questions: nil, bridgeReply: { .terminateNow }, reply: { replies.add($0) }) == .terminateNow)
        #expect(replies.values.isEmpty && gateway.calls(prefix: "answer:").isEmpty, "보류가 없으면 아무것도 보내지 않고 응답도 따로 하지 않는다")
    }

    @Test func aHeldAnswerIsSentAtOnceThenTheBridgeReplyDecidesQuit() async throws {
        let (store, gateway, ticker) = try await store(Q.single)
        store.choose(row: 1, session: Data.sessionID)
        let replies = Replies()
        let reply = MacAppDelegate.terminationReply(questions: store, bridgeReply: { .terminateNow }, reply: { replies.add($0) })
        #expect(reply == .terminateLater, "보낸 뒤에 응답한다")
        #expect(await eventually { replies.values == [true] })
        #expect(gateway.calls(prefix: "answer:").count == 1, "2초를 기다리지 않고 곧바로 한 번")
        #expect(ticker.pendingDelays.isEmpty)
    }

    @Test func aCancelledQuitConfirmationRepliesCancelAfterTheFlush() async throws {
        let (store, gateway, _) = try await store(Q.single)
        store.choose(row: 0, session: Data.sessionID)
        let replies = Replies()
        _ = MacAppDelegate.terminationReply(questions: store, bridgeReply: { .terminateCancel }, reply: { replies.add($0) })
        #expect(await eventually { replies.values == [false] })
        #expect(gateway.calls(prefix: "answer:").count == 1)
    }

    @Test func whenTheBridgeRepliesLaterWeDoNotReplyOurselves() async throws {
        let (store, _, _) = try await store(Q.single)
        store.choose(row: 0, session: Data.sessionID)
        let replies = Replies()
        _ = MacAppDelegate.terminationReply(questions: store, bridgeReply: { .terminateLater }, reply: { replies.add($0) })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(replies.values.isEmpty, "bridge가 자기 확인 창 뒤에 직접 응답한다")
    }

    @Test func aHeldSecretIsDroppedNotSentAtQuit() async throws {
        let submitter = SpySecretSubmitter()
        let (store, gateway, _) = try await store(Q.secret, secrets: submitter)
        store.submitSecret(SecretBox("DO_NOT_STORE_SECRET_D4BM"), session: Data.sessionID)
        #expect(store.hasHeldAnswers)
        let replies = Replies()
        let reply = MacAppDelegate.terminationReply(questions: store, bridgeReply: { .terminateNow }, reply: { replies.add($0) })
        #expect(reply == .terminateLater)
        #expect(await eventually { replies.values == [true] })
        #expect(submitter.count == 0 && gateway.calls(prefix: "answer:").isEmpty, "표시만 서버에 가면 다음 실행이 값 없이 거절로 닫는다")
        #expect(store.entry(session: Data.sessionID)?.phase == .open, "질문은 열린 채 남는다: 다음 실행에서 다시 묻는다")
    }
}

final class SpySecretSubmitter: LocalSecretAnswerSubmitting, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func submit(_ answer: LocalSecretAnswer) async -> LocalSecretOutcome {
        lock.withLock { _count += 1 }
        return .sent
    }
}
