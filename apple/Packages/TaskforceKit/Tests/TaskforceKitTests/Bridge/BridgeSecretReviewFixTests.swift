#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 검토 1 반영 (Astra P2 · 보안 F-1 · F-2 · F-3 · F-4): 먼저 빨갛게 만들고(고치기 전 실패 이름은 노트 "검토 1 반영") 고친 뒤 초록이 된다.
struct BridgeSecretReviewFixTests {
    typealias S = SecretFixture

    /// put(`LocalSecretAnswers`에 값이 들어간) 횟수를 센다
    private func countPuts(_ h: BridgeHarness) async -> Locked<Int> {
        let puts = Locked<Int>(0)
        await h.secrets.observe { busy in if busy { puts.set(puts.get() + 1) } }
        return puts
    }

    // MARK: F-1 — answer-local의 도메인 404는 bridge를 지우지 않는다

    @Test func aDomain404FromAnswerLocalNeverClearsTheBridgeOrRegistersAgain() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let registers = h.server.registerAttempts
        let deviceSecret = try h.credentials.secret(partition: h.partition.id)
        let bridgeBefore = await h.runtime.bridgeID
        h.server.failNext("answer-local", .init(status: 404))
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .questionClosed, "결과 표: 값을 지우고 질문을 다시 읽는다")
        h.clock.jump(by: 1)
        await h.runtime.tick()
        #expect(!h.log.events.contains("bridge_gone"), "bridge를 지우지 않았다")
        #expect(h.server.registerAttempts == registers, "다시 등록하지 않았다")
        #expect(try h.credentials.secret(partition: h.partition.id) == deviceSecret, "장치 secret이 바뀌지 않았다")
        #expect(await h.runtime.bridgeID == bridgeBefore)
        let pending = await h.secrets.hasPending
        #expect(!pending)
    }

    // MARK: F-2 (Astra P2) — 결과 확인으로 정산한 답 명령 뒤에 값이 남지 않는다

    @Test func aReadbackNotReceivedSettleLeavesNoValueAndNoQuitPrompt() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.dropResponseOnce(route: "ack") // 서버는 lease했지만 응답이 유실된다
        await S.deliver(h)
        h.server.markLeasedUnknown(commandID) // lease가 만료돼 결과 확인 목록에 나온다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.ackFinalAt != nil }, "정산이 끝났다")
        let command = try #require(try await h.ledger.command(commandID))
        #expect(command.state == .settled && command.ackResult == "not_received", "양성 대조: readback not_received로 정산됐다: \(command.state) \(String(describing: command.ackResult))")
        #expect(h.agent.deliveredAnswers.isEmpty)
        let pendingAtSettle = await h.secrets.hasPending
        #expect(!pendingAtSettle, "정산 바로 뒤(보관 정리 전)에 값 0: 정산이 직접 버린다")
        h.clock.jump(by: 120)
        await h.runtime.housekeeping()
        let pending = await h.secrets.hasPending
        #expect(!pending, "보관 정리 뒤에도 값 0")
        let busy = await h.runtime.isBusy()
        #expect(!busy, "바쁨이 아니다: 종료 확인 창이 뜨지 않는다")
    }

    @Test func aTaskThatEndedFailedOrCancelledDropsItsValuesAtHousekeeping() async throws {
        for terminal in ["failed", "cancelled"] {
            let h = try BridgeHarness()
            let created = try await S.open(h)
            #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent, Comment(rawValue: terminal))
            _ = try await h.ledger.updateTask(created.taskID) { $0.lastState = terminal } // 열린 요청은 그대로다
            await h.runtime.housekeeping()
            let pending = await h.secrets.hasPending
            #expect(!pending, Comment(rawValue: "\(terminal): 끝난 task의 값 0"))
        }
    }

    @Test func onlyANotReceivedSettleOfAnAnswerCommandDropsTheTasksValuesAndALateOtherSettleNeverWipesANewerValue() async throws {
        let h = try BridgeHarness()
        let task = UUID().uuidString.lowercased()
        let other = LocalSecretKey(taskID: UUID().uuidString, requestID: "r1")
        let first = LocalSecretKey(taskID: task, requestID: "r1")
        let newer = LocalSecretKey(taskID: task, requestID: "r2")
        func fill() async {
            for key in [other, first, newer] { await h.secrets.put(key: key, value: AgentAnswerValue(text: "v-\(key.requestID)")) }
        }
        await fill()
        // 받았다 · 모른다: task는 계속 열려 있을 수 있다 → 같은 task의 값을 지우지 않는다 (늦은 정산이 새로 입력한 값을 지우지 않는다)
        for result in [BridgeV1ReadbackResult.received, .unknown] {
            await h.runtime.settleSecretsAfterReadback(taskID: task, kind: .answer, result: result)
            let kept = await [h.secrets.contains(key: first), h.secrets.contains(key: newer), h.secrets.contains(key: other)]
            #expect(kept == [true, true, true], Comment(rawValue: "\(result)"))
        }
        // message 명령의 정산은 비밀값과 상관없다
        await h.runtime.settleSecretsAfterReadback(taskID: task, kind: .message, result: .notReceived)
        let afterMessage = await [h.secrets.contains(key: first), h.secrets.contains(key: newer)]
        #expect(afterMessage == [true, true])
        // answer가 not_received로 끝났다: task가 `failed`(끝남)이 된다 → 그 task의 값만 모두 버린다
        await h.runtime.settleSecretsAfterReadback(taskID: task, kind: .answer, result: .notReceived)
        let dropped = await [h.secrets.contains(key: first), h.secrets.contains(key: newer), h.secrets.contains(key: other)]
        #expect(dropped == [false, false, true], "다른 task의 값은 그대로")
    }

    // MARK: F-3 — put 앞에서 원장이 그 (task, request)를 열린 비밀값 요청으로 아는지 본다

    @Test func aRequestTheLedgerDoesNotKnowAsAnOpenSecretIsNeverStoredNorPostedFor() async throws {
        // 원장이 모르는 task (다른 계정의 낡은 카드가 이 런타임에 닿은 경우)
        do {
            let h = try BridgeHarness()
            _ = try await S.open(h)
            let puts = await countPuts(h)
            let stranger = FakeBridgeServer.Created(commandID: "x", taskID: UUID().uuidString.lowercased(), sessionID: "y", stepID: "z", marker: "m")
            #expect(await S.submit(h, S.answer(stranger, value: S.canary())) == .failed(.generic), "원장이 모르는 task")
            #expect(h.server.requests("answer-local").isEmpty && puts.get() == 0, "POST 0 · put 0")
            let pending = await h.secrets.hasPending
            #expect(!pending)
        }
        // 이미 닫힌 요청 (낡은 카드): 질문이 닫혔다
        do {
            let h = try BridgeHarness()
            let created = try await S.open(h)
            let puts = await countPuts(h)
            // `cancel`의 `abandoned_request_id`는 닫힌 목록에만 적고 열린 요청 표시를 지우지 않는다: 열려 있다고 적힌 채 닫힌 요청
            _ = try await h.ledger.updateTask(created.taskID) { $0.closedRequestIDs.append(S.requestID) }
            #expect(await S.submit(h, S.answer(created, value: S.canary())) == .questionClosed, "닫힌 요청")
            #expect(h.server.requests("answer-local").isEmpty && puts.get() == 0)
        }
        // 이 런타임에 없는 adapter의 task
        do {
            let h = try BridgeHarness()
            let created = try await S.open(h)
            let puts = await countPuts(h)
            _ = try await h.ledger.updateTask(created.taskID) { $0.adapter = "agent:not-here" }
            #expect(await S.submit(h, S.answer(created, value: S.canary())) == .failed(.generic), "이 런타임이 돌리지 않는 adapter")
            #expect(h.server.requests("answer-local").isEmpty && puts.get() == 0)
        }
        // 지금 열린 요청이 다른 것 (질문이 바뀐 뒤의 낡은 카드)
        do {
            let h = try BridgeHarness()
            let created = try await S.open(h)
            let puts = await countPuts(h)
            #expect(await S.submit(h, S.answer(created, request: "some-other-request", value: S.canary())) == .failed(.generic), "다른 요청")
            #expect(h.server.requests("answer-local").isEmpty && puts.get() == 0)
        }
        // 비밀값 질문이 아니다
        do {
            let h = try BridgeHarness()
            let created = try await S.open(h, secret: false)
            let puts = await countPuts(h)
            #expect(await S.submit(h, S.answer(created, value: S.canary())) == .failed(.generic), "비밀값 질문이 아님")
            #expect(h.server.requests("answer-local").isEmpty && puts.get() == 0)
        }
    }

    // MARK: F-4 — 재시도 때 값이 이미 전달됐으면 거짓 "Couldn't send"가 아니다

    private func startSubmit(_ h: BridgeHarness, _ answer: LocalSecretAnswer) -> (done: Locked<LocalSecretOutcome?>, task: Task<Void, Never>) {
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(answer, accountStillMatches: { true })) }
        return (done, task)
    }

    private func finish(_ h: BridgeHarness, _ done: Locked<LocalSecretOutcome?>) async -> LocalSecretOutcome? {
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
        return done.get()
    }

    @Test func aRetryAfterTheValueWasAlreadyDeliveredIsSentNotCouldntSend() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let canary = S.canary()
        h.server.dropResponseOnce(route: "answer-local") // 서버는 답을 받았지만 응답이 유실된다
        let (done, task) = startSubmit(h, S.answer(created, value: canary))
        #expect(await h.eventually { h.clock.sleeperCount > 0 }, "첫 요청 뒤 재시도 전의 잠깐")
        await S.deliver(h) // 그 사이 서버가 만든 답 명령을 lease해 전달한다 (값을 take해 버린다)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        let outcome = await finish(h, done)
        await task.value
        #expect(outcome == .sent, "전달됐으니 보낸 것이다: \(String(describing: outcome))")
        #expect(h.server.requests("answer-local").count == 1, "값이 없으니 두 번째 요청은 나가지 않았다")
        #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(canary)])
    }

    @Test func aRetryAfterTheRequestWasClosedIsAClosedQuestion() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        h.server.dropResponseOnce(route: "answer-local")
        let (done, task) = startSubmit(h, S.answer(created, value: S.canary()))
        #expect(await h.eventually { h.clock.sleeperCount > 0 })
        // 그 사이 요청이 닫혔다 (정산이 값을 버렸다)
        _ = try await h.ledger.updateTask(created.taskID) {
            $0.closedRequestIDs.append(S.requestID)
            $0.openRequestID = nil
        }
        await h.runtime.settleSecret(taskID: created.taskID, requestID: S.requestID)
        let outcome = await finish(h, done)
        await task.value
        #expect(outcome == .questionClosed)
        #expect(h.server.requests("answer-local").count == 1)
    }

    @Test func aRetryWhoseValueIsGoneAndWhoseRequestIsStillOpenIsStillAFailure() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        h.server.dropResponseOnce(route: "answer-local")
        let (done, task) = startSubmit(h, S.answer(created, value: S.canary()))
        #expect(await h.eventually { h.clock.sleeperCount > 0 })
        await h.secrets.discard(key: S.key(created)) // 어떤 길이든 값만 사라졌다: 전달도 닫힘도 아니다
        let outcome = await finish(h, done)
        await task.value
        #expect(outcome == .failed(.generic), "전달 · 닫힘 어느 쪽도 아니면 실패다")
    }
}
#endif
