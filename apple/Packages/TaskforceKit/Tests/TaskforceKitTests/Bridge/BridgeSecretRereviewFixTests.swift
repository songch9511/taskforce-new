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

    // MARK: 재검토 2 — 비대칭 heartbeat 지연에도 정산된 제출의 값이 남지 않는다

    @Test func anAsymmetricHeartbeatLatencyNeverLeavesTheSettledValueBehind() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack") // 서버는 lease했지만 응답이 유실된다
        await S.deliver(h)
        h.server.markLeasedUnknown(commandID)
        // 만료 뒤 heartbeat를 서버가 느리게 처리한다 (요청 도중 시계가 30초 흐른다): 왕복 중간점 보정이 +15초 어긋난다. 시각으로 짝을 맞추면 옛 값이 남는다
        let clock = h.clock
        h.server.onRequest = { record in if record.route == "heartbeat" { clock.jump(by: 30) } }
        h.clock.jump(by: 6)
        await h.runtime.tick()
        h.server.onRequest = nil
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.ackFinalAt != nil }, "정산이 끝났다")
        let command = try #require(try await h.ledger.command(commandID))
        #expect(command.state == .settled && command.ackResult == "not_received")
        let offset = try #require(try await h.ledger.meta().clockOffsetMS)
        #expect(abs(offset) > 10_000, "양성 대조: 시계 차이 추정이 실제로 크게 어긋났다 (\(offset)ms)")
        let pending = await h.secrets.hasPending
        #expect(!pending, "정산된 제출의 값 0")
        let busy = await h.runtime.isBusy()
        #expect(!busy, "바쁨이 아니다")
    }

    // MARK: 정산이 재시도보다 먼저 (settle-before-bind)

    @Test func aCommandSettledBeforeTheRetryLeavesTheValueGoneAndTheRetryNeitherPostsNorPutsAgain() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        h.server.dropResponseOnce(route: "answer-local") // 서버는 답 명령을 만들었지만 POST 응답이 유실된다
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 }, "재시도 전의 잠깐")
        // 그 사이 그 명령이 목록에 나오고, lease 응답이 유실되고, 만료돼 not_received로 정산된다
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack")
        await S.deliver(h)
        h.server.markLeasedUnknown(commandID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.ackFinalAt != nil }, "정산이 끝났다")
        let pendingAfterSettle = await h.secrets.hasPending
        #expect(!pendingAfterSettle, "정산이 그 제출의 값을 버렸다")
        // 재시도가 온다: 값이 없고 질문은 복원돼 열려 있다 → 다시 두지도 보내지도 않고 실패로 돌려보낸다
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
        await task.value
        #expect(done.get() == .failed(.generic))
        #expect(h.server.requests("answer-local").count == 1, "두 번째 POST 0")
        let pending = await h.secrets.hasPending
        #expect(!pending, "값을 다시 두지 않았다")
        #expect(h.server.taskState(created.taskID) == "awaiting_answer", "질문은 복원돼 있다: 사용자는 다시 입력할 수 있다")
    }
}
#endif
