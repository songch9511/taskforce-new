#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 재검토 1–4 → 계약 16.14 (값 수명 단순화): 재검토가 짚은 순서 넷과 "복원 안 됨" · "쉬는 값"을 고정한다.
/// 규칙: 값은 (task, request)마다 하나, `put`은 덮어쓴다. 값은 adapter가 그 요청을 아직 기다리는 동안 둔다 (원장의 사실). `not_received` 정산은 값을 버리지 않는다.
/// 그래서 네 순서는 모두 같은 끝으로 간다: 사용자가 다시 답하면 마지막 값이 **정확히 한 번** 전달되고, 요청이 더는 기다려지지 않으면 값은 0이다.
struct BridgeSecretRereviewFixTests {
    typealias S = SecretFixture

    /// 순서 끝의 두 갈래: 다시 답한다 / 요청이 닫힌다
    private enum Ending: CaseIterable, CustomStringConvertible {
        case reanswer, closed
        var description: String { self == .reanswer ? "다시 답한다" : "요청이 닫힌다" }
    }

    /// 쉬고 있는 값에서 끝낸다.
    /// - reanswer: 사용자가 다시 입력한다 → `put`이 바꿔 넣는다 → 서버가 새 답 명령을 만들고 → lease → 마지막 값이 한 번 전달된다.
    ///   `latest`가 있으면 그 값은 이미 입력돼 서버가 duplicate로 받았다 (다시 입력하지 않고 전달만 본다)
    /// - closed: adapter가 그 요청을 더는 기다리지 않는다 (`cancel`의 버려진 요청) → 값 0 · 전달 0
    private func finish(_ h: BridgeHarness, created: FakeBridgeServer.Created, ending: Ending, latest: String? = nil) async throws {
        switch ending {
        case .reanswer:
            let value: String
            if let latest {
                value = latest
            } else {
                value = S.canary()
                let before = h.server.commandIDs(taskID: created.taskID, kind: "answer").count
                #expect(await S.submit(h, S.answer(created, value: value)) == .sent, "\(ending)")
                #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").count == before + 1, "서버가 복원한 질문에 새 답 명령이 만들어진다")
            }
            let rest = await h.secrets.contains(key: S.key(created))
            #expect(rest, "마지막으로 입력한 값이 있다")
            // 보관 정리가 도는 동안에도 값은 산다 (로컬 task가 failed여도 원장은 그 요청을 연 채다)
            h.clock.jump(by: 6)
            await h.runtime.housekeeping()
            let survived = await h.secrets.contains(key: S.key(created))
            #expect(survived, "보관 정리가 값을 지우지 않는다")
            await S.deliver(h)
            #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
            await h.settle { h.server.taskState(created.taskID) == "idle" }
            #expect(h.agent.deliveredAnswers.count == 1, "정확히 한 번")
            #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(value)], "마지막으로 입력한 값이 전달됐다")
            #expect(h.agent.closedRequests.isEmpty, "request_closed로 닫히지 않았다")
        case .closed:
            let bridgeID = h.bridgeID
            h.server.enqueueCancel(bridgeID: bridgeID, taskID: created.taskID, abandoned: S.requestID)
            h.clock.jump(by: 6)
            await h.runtime.tick()
            #expect(await h.eventually { h.agent.closedRequests.map(\.requestID).contains(S.requestID) }, "요청이 닫혔다")
            #expect(h.agent.deliveredAnswers.isEmpty, "닫힌 요청의 값은 전달되지 않는다")
        }
        let pending = await h.secrets.hasPending
        #expect(!pending, "끝에는 값 0 (\(ending))")
        let busy = await h.runtime.isBusy()
        #expect(!busy)
    }

    /// 재시도 사이의 잠깐을 시계로 돌려 제출 하나가 끝나기를 기다린다
    private func finishSubmission(_ h: BridgeHarness, _ done: Locked<LocalSecretOutcome?>) async {
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    // MARK: 순서 1 — lease 응답 유실 → not_received → 복원 → 재입력

    @Test func afterANotReceivedSettleTheRestingValueStaysAndTheReenteredOneIsDeliveredExactlyOnce() async throws {
        for ending in Ending.allCases {
            let h = try BridgeHarness()
            let created = try await S.open(h, endsAfterAsking: true)
            let commandID = try await S.submitAndLoseTheLease(h, created: created)
            try await S.settleAsNotReceived(h, commandID: commandID)
            let task = try #require(try await h.ledger.task(created.taskID))
            #expect(task.lastState == "failed" && task.openRequestID == S.requestID, "로컬은 failed로 남고 요청은 열려 있다")
            #expect(h.server.taskState(created.taskID) == "awaiting_answer", "서버는 질문을 복원했다")
            let rests = await h.secrets.contains(key: S.key(created))
            #expect(rests, "정산은 값을 버리지 않는다: 복원된 질문의 값으로 남는다 (\(ending))")
            let busy = await h.runtime.isBusy()
            #expect(!busy, "쉬는 값은 종료 확인을 막지 않는다")
            try await finish(h, created: created, ending: ending)
        }
    }

    // MARK: 순서 2 — 실패 카드에서 재입력 + 서버 duplicate

    /// 첫 제출의 POST는 서버가 처리했지만 응답이 유실되고 재시도도 모두 실패한다 (값은 지워지고 실패 카드). 그 사이 명령이 목록에 나오고 lease 응답이 유실된다
    private func firstSubmissionLostAndExhausted(_ h: BridgeHarness, created: FakeBridgeServer.Created) async throws -> String {
        h.server.dropResponseOnce(route: "answer-local") // 서버는 답 명령 C를 만들었지만 응답이 유실된다
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 }, "첫 요청 뒤 재시도 전의 잠깐")
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack") // C가 목록에 나오고(처음 봄) lease 응답이 유실된다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        h.server.failNext("answer-local", .init(status: 0, transport: true, count: 2)) // 남은 재시도도 모두 실패한다
        await finishSubmission(h, done)
        await task.value
        #expect(done.get() == .failed(.offline), "재시도가 소진돼 실패 카드가 돌아왔다: \(String(describing: done.get()))")
        let pending = await h.secrets.hasPending
        #expect(!pending, "실패하면 값은 지워졌다")
        return commandID
    }

    @Test func aFailureCardReentryAnsweredAsDuplicateRestsThroughTheSettleAndTheNextAnswerIsDeliveredExactlyOnce() async throws {
        for ending in Ending.allCases {
            let h = try BridgeHarness()
            let created = try await S.open(h, endsAfterAsking: true)
            let commandID = try await firstSubmissionLostAndExhausted(h, created: created)
            // 실패 카드에서 다시 입력한다: 서버는 같은 명령 C에 대한 duplicate를 돌려준다 (복원 없음)
            #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
            #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer") == [commandID], "새 명령은 만들어지지 않았다 (duplicate)")
            let inFlight = await h.runtime.isBusy()
            #expect(!inFlight, "duplicate는 세지 않는다 (계약 16.15): 제출이 끝났고 새 answered도 없다")
            // C의 lease는 응답이 유실된 채 만료돼 not_received로 정산된다 → 서버가 질문을 되살린다. 값은 그대로 쉰다
            try await S.settleAsNotReceived(h, commandID: commandID)
            let rests = await h.secrets.contains(key: S.key(created))
            #expect(rests, "같은 명령의 정산이 재입력한 값을 버리지 않는다")
            let busy = await h.runtime.isBusy()
            #expect(!busy)
            // 되살아난 질문에 다시 답한다 (answered: 새 명령). 끝은 같다
            try await finish(h, created: created, ending: ending)
        }
    }

    // MARK: 순서 3 — 미관측 새 명령 duplicate + 옛 명령의 늦은 정산

    @Test func aReenteredValueOnAnUnseenNewCommandSurvivesTheLateSettleOfTheOldCommandAndIsDeliveredExactlyOnce() async throws {
        for ending in Ending.allCases {
            let h = try BridgeHarness()
            let created = try await S.open(h, endsAfterAsking: true)
            // 옛 명령 C1: 제출 · lease 응답 유실. 이 프로세스는 C1을 봤지만 정산하지 못했다
            let oldCommand = try await S.submitAndLoseTheLease(h, created: created)
            // 서버가 질문을 되살렸다 (C1의 정산은 아직 로컬에 닿지 않았다): 둘째 제출의 POST는 서버가 처리해 새 명령 C2를 만들지만 응답이 유실되고 재시도가 모두 실패한다
            h.server.restoreQuestion(taskID: created.taskID)
            h.server.dropResponseOnce(route: "answer-local")
            let done = Locked<LocalSecretOutcome?>(nil)
            let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
            #expect(await h.eventually { h.clock.sleeperCount > 0 })
            h.server.failNext("answer-local", .init(status: 0, transport: true, count: 2))
            await finishSubmission(h, done)
            await task.value
            #expect(done.get() == .failed(.offline), "실패 카드가 돌아왔다: \(String(describing: done.get()))")
            let commands = h.server.commandIDs(taskID: created.taskID, kind: "answer")
            #expect(commands.count == 2 && commands.first == oldCommand, "서버에는 새 명령 C2가 있다 (이 프로세스는 아직 보지 못했다)")
            // 실패 카드에서 다시 입력한다: 서버는 아직 아무도 보지 못한 C2에 대한 duplicate를 돌려준다
            let latest = S.canary()
            #expect(await S.submit(h, S.answer(created, value: latest)) == .sent)
            let ids = h.server.commandIDs(taskID: created.taskID, kind: "answer")
            #expect(ids.count == 2, "duplicate: 새 명령은 만들어지지 않았다")
            let newCommand = try #require(ids.last)
            h.server.setCommandStep(newCommand, "skipped") // C2는 아직 목록에 나오지 않는다: 옛 명령의 늦은 정산이 먼저 닿는다
            // 옛 명령 C1이 이제야 정산된다 (lease 만료 → not_received). 값은 그대로다
            h.server.markLeasedUnknown(oldCommand)
            h.clock.jump(by: 6)
            await h.runtime.tick()
            let settled = await h.eventually(timeout: 5) { (try? await h.ledger.command(oldCommand))?.ackFinalAt != nil }
            #expect(settled, "옛 명령의 정산이 끝났다")
            let survived = await h.secrets.contains(key: S.key(created))
            #expect(survived, "옛 명령의 늦은 정산이 새 명령 몫의 값을 지우지 않는다")
            let busy = await h.runtime.isBusy()
            #expect(!busy, "정산이 끝났으니 바쁘지 않다")
            if ending == .reanswer { h.server.setCommandStep(newCommand, "prepared") } // 이제야 C2가 목록에 나온다
            try await finish(h, created: created, ending: ending, latest: latest)
            if ending == .closed {
                // 요청이 닫힌 뒤에 C2가 나온다: 받아 갈 값이 없다 → 전달 0
                h.server.setCommandStep(newCommand, "prepared")
                h.clock.jump(by: 6)
                await h.runtime.tick()
                let pending = await h.secrets.hasPending
                #expect(h.agent.deliveredAnswers.isEmpty && !pending, "닫힌 요청 뒤의 새 명령은 아무것도 전달하지 않는다")
            }
        }
    }

    // MARK: 순서 4 — 비대칭 heartbeat 지연

    @Test func anAsymmetricHeartbeatLatencyKeepsTheValueAndTheNextAnswerIsDeliveredExactlyOnce() async throws {
        for ending in Ending.allCases {
            let h = try BridgeHarness()
            let created = try await S.open(h, endsAfterAsking: true)
            let commandID = try await S.submitAndLoseTheLease(h, created: created)
            h.server.markLeasedUnknown(commandID)
            // 만료 뒤 heartbeat를 서버가 느리게 처리한다 (요청 도중 시계가 30초 흐른다): 왕복 중간점 보정이 +15초 어긋난다. 시각에 기대면 값이 틀어진다
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
            let rests = await h.secrets.contains(key: S.key(created))
            #expect(rests, "시각과 무관하게 값은 그대로 쉰다")
            let busy = await h.runtime.isBusy()
            #expect(!busy, "바쁨이 아니다")
            try await finish(h, created: created, ending: ending)
        }
    }

    // MARK: 정산이 재시도보다 먼저 — 값이 남아 있으니 재시도가 다시 POST하고 새 명령이 한 번 전달된다

    @Test func aCommandSettledAsNotReceivedBeforeTheRetryLetsTheRetryPostAgainAndTheValueIsDeliveredExactlyOnce() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let sent = S.canary()
        h.server.dropResponseOnce(route: "answer-local") // 서버는 답 명령을 만들었지만 POST 응답이 유실된다
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: sent), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 }, "재시도 전의 잠깐")
        // 그 사이 그 명령이 목록에 나오고, lease 응답이 유실되고, 만료돼 not_received로 정산된다 (서버는 질문을 되살린다)
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack")
        await S.deliver(h)
        try await S.settleAsNotReceived(h, commandID: commandID)
        let rests = await h.secrets.contains(key: S.key(created))
        #expect(rests, "정산이 값을 버리지 않았다")
        // 재시도가 온다: 값이 있고 질문은 복원돼 열려 있다 → 다시 POST하면 서버가 새 답 명령을 만든다
        await finishSubmission(h, done)
        await task.value
        #expect(done.get() == .sent)
        #expect(h.server.requests("answer-local").count == 2, "재시도가 한 번 더 POST했다")
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer").count == 2)
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(sent)])
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
        await finishSubmission(h, done)
        await task.value
        #expect(done.get() == .failed(.generic), "전달되지 않았다: 보냈다고 하지 않는다")
    }

    // MARK: 복원 안 됨 (run 끝) → 값 0

    @Test func whenTheServerDoesNotRestoreTheQuestionBecauseTheRunEndedTheValueIsGone() async throws {
        let h = try BridgeHarness()
        h.server.restoresQuestionOnNotReceived = false // run이 끝났다: 서버는 질문을 되살리지 않고 task를 failed로 둔다
        let created = try await S.open(h, endsAfterAsking: true)
        let commandID = try await S.submitAndLoseTheLease(h, created: created)
        try await S.settleAsNotReceived(h, commandID: commandID)
        #expect(h.server.taskState(created.taskID) == "failed", "서버는 되살리지 않았다")
        // 서버는 끝난 task를 중단으로 정리한다: 이 Mac은 그 task의 열린 요청을 더는 기다리지 않는다
        let bridgeID = h.bridgeID
        h.server.enqueueCancel(bridgeID: bridgeID, taskID: created.taskID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let gone = await h.eventually(timeout: 5) {
            let pending = await h.secrets.hasPending
            return !pending
        }
        #expect(gone, "값 0")
        let busy = await h.runtime.isBusy()
        #expect(!busy)
        #expect(h.agent.deliveredAnswers.isEmpty)
    }

    // MARK: 질문이 열린 채 쉬는 값 → isBusy 거짓, quit에서 버린다

    @Test func aValueRestingForARestoredQuestionIsNotBusyAndIsDroppedAtQuit() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let commandID = try await S.submitAndLoseTheLease(h, created: created)
        try await S.settleAsNotReceived(h, commandID: commandID)
        let rests = await h.secrets.contains(key: S.key(created))
        #expect(rests)
        let busy = await h.runtime.isBusy()
        #expect(!busy, "쉬는 값은 종료 확인 창을 띄우지 않는다")
        await h.runtime.shutdown(interrupt: false)
        let pending = await h.secrets.hasPending
        #expect(!pending, "quit에서 버렸다 (종료 때 비밀값은 보내지 않는다)")
        #expect(h.agent.deliveredAnswers.isEmpty)
    }
}
#endif
