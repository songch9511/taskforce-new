#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 재검토 1 반영 (Astra 새 P2 · 보안 R-1): 먼저 빨갛게 만들고 고친다.
struct BridgeSecretRereviewFixTests {
    typealias S = SecretFixture

    /// 실제 서버처럼: 답 명령이 not_received로 정산되면 서버가 질문을 복원하지만 로컬 task는 failed로 남는다
    private func settleAsNotReceived(_ h: BridgeHarness, created: FakeBridgeServer.Created) async throws {
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack") // 서버는 lease했지만 응답이 유실된다
        await S.deliver(h)
        h.server.markLeasedUnknown(commandID) // lease가 만료돼 결과 확인 목록에 나온다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.ackFinalAt != nil }, "정산이 끝났다")
        let task = try #require(try await h.ledger.task(created.taskID))
        #expect(task.lastState == "failed" && task.openRequestID == S.requestID, "로컬은 failed로 남고 요청은 열려 있다")
        #expect(h.server.taskState(created.taskID) == "awaiting_answer", "서버는 질문을 복원했다")
    }

    @Test func aQuestionRestoredAfterANotReceivedSettleTakesTheReenteredValueAndDeliversItExactlyOnce() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        try await settleAsNotReceived(h, created: created)
        let firstPending = await h.secrets.hasPending
        #expect(!firstPending, "첫 제출의 값은 정산 때 버려졌다")
        // 사용자가 다시 입력한다
        let again = S.canary()
        #expect(await S.submit(h, S.answer(created, value: again)) == .sent, "서버가 복원한 질문에 새 답 명령이 만들어진다")
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").count == 2)
        // 보관 정리가 도는 동안에도 값은 산다 (로컬 task가 failed여도)
        h.clock.jump(by: 6)
        await h.runtime.housekeeping()
        let survived = await h.secrets.contains(key: S.key(created))
        #expect(survived, "보관 정리가 다시 입력한 값을 지우지 않는다")
        // lease → take → 답 훅 한 번
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(h.agent.deliveredAnswers.count == 1)
        #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(again)], "다시 입력한 값이 한 번 전달됐다")
        #expect(h.agent.closedRequests.isEmpty, "request_closed로 닫히지 않았다")
        let pending = await h.secrets.hasPending
        #expect(!pending)
    }

    // MARK: R-1 — 질문이 교체된 뒤의 재시도는 보냈다가 아니다

    @Test func aRetryWhoseRequestWasReplacedByAnotherQuestionIsNotSent() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        h.server.dropResponseOnce(route: "answer-local")
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 })
        // 그 사이 adapter가 R을 닫지 않고 새 질문 R2를 냈다 (전달된 것이 아니다: 열린 요청 표시가 비지 않고 R2로 바뀐다). 보관 정리가 R의 값을 버렸다
        _ = try await h.ledger.updateTask(created.taskID) { $0.openRequestID = "req-secret-2" }
        await h.secrets.discard(key: S.key(created))
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
        await task.value
        #expect(done.get() == .failed(.generic), "전달되지 않았다: 보냈다고 하지 않는다")
    }

    // MARK: 서버 시각 → 로컬 시각

    @Test func theLeaseTimeOfTheSettledCommandIsConvertedWithTheClockOffset() async throws {
        let h = try BridgeHarness(serverClockOffset: 1000) // 서버 시계가 로컬보다 1,000초 앞선다
        await h.registerFirst()
        let offset = try #require(try await h.ledger.meta().clockOffsetMS)
        #expect(abs(offset - 1_000_000) < 2_000, "heartbeat가 시계 차이를 쟀다: \(offset)ms")
        let task = UUID().uuidString.lowercased()
        let settled = LocalSecretKey(taskID: task, requestID: "r1")
        let newer = LocalSecretKey(taskID: task, requestID: "r2")
        let leasedLocal = h.clock.now
        await h.secrets.put(key: settled, value: AgentAnswerValue(text: "v-old"), at: leasedLocal.addingTimeInterval(-5))
        await h.secrets.put(key: newer, value: AgentAnswerValue(text: "v-new"), at: leasedLocal.addingTimeInterval(400))
        // 서버가 적은 lease 시각은 서버 시계다 (로컬 + 1,000초)
        await h.runtime.settleSecretsAfterReadback(taskID: task, kind: .answer, result: .notReceived, leasedAt: leasedLocal.addingTimeInterval(1000))
        let after = await [h.secrets.contains(key: settled), h.secrets.contains(key: newer)]
        #expect(after == [false, true], "시계 차이를 빼서 비교한다: 정산된 제출의 값만 버린다")
    }
}
#endif
