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

    // MARK: 재검토 3 — 같은 명령에 duplicate로 접수된 재입력 값도 그 명령의 정산에 따라간다

    /// 첫 제출의 POST는 서버가 처리했지만 응답이 유실되고 재시도도 모두 실패한다 (값은 지워지고 실패 카드). 그 사이 `commandSeenDuringFirstFlow`면 명령이 목록에 나와 lease 응답이 유실된다
    private func firstSubmissionLostAndExhausted(_ h: BridgeHarness, created: FakeBridgeServer.Created, commandSeenDuringFirstFlow: Bool) async throws -> String {
        h.server.dropResponseOnce(route: "answer-local") // 서버는 답 명령 C를 만들었지만 응답이 유실된다
        let done = Locked<LocalSecretOutcome?>(nil)
        let task = Task { done.set(await h.runtime.submitLocalSecret(S.answer(created, value: S.canary()), accountStillMatches: { true })) }
        #expect(await h.eventually { h.clock.sleeperCount > 0 }, "첫 요청 뒤 재시도 전의 잠깐")
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        if commandSeenDuringFirstFlow {
            h.server.dropResponseOnce(route: "ack") // C가 목록에 나오고(처음 봄) lease 응답이 유실된다
            h.clock.jump(by: 6)
            await h.runtime.tick()
        }
        h.server.failNext("answer-local", .init(status: 0, transport: true, count: 2)) // 남은 재시도도 모두 실패한다
        let deadline = Date().addingTimeInterval(30)
        while done.get() == nil, Date() < deadline {
            if h.clock.sleeperCount > 0 { await h.clock.advance(by: 1) } else { try? await Task.sleep(for: .milliseconds(2)) }
        }
        await task.value
        #expect(done.get() == .failed(.offline), "재시도가 소진돼 실패 카드가 돌아왔다: \(String(describing: done.get()))")
        let pending = await h.secrets.hasPending
        #expect(!pending, "실패하면 값은 지워졌다")
        return commandID
    }

    private func settleLeaseLostCommandAsNotReceived(_ h: BridgeHarness, commandID: String) async throws {
        h.server.markLeasedUnknown(commandID) // lease가 만료돼 결과 확인 목록에 나온다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually(timeout: 5) { (try? await h.ledger.command(commandID))?.ackFinalAt != nil }, "정산이 끝났다")
        let command = try #require(try await h.ledger.command(commandID))
        #expect(command.state == .settled && command.ackResult == "not_received")
    }

    @Test func aReenteredValueThatTheServerAnswersAsDuplicateOfTheSameCommandIsDroppedWithThatCommandsSettle() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let commandID = try await firstSubmissionLostAndExhausted(h, created: created, commandSeenDuringFirstFlow: true)
        // 실패 카드에서 다시 입력한다: 서버는 같은 명령 C에 대한 duplicate를 돌려준다 (복원 없음)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        #expect(h.server.commandIDs(taskID: created.taskID, kind: "answer") == [commandID], "새 명령은 만들어지지 않았다 (duplicate)")
        try await settleLeaseLostCommandAsNotReceived(h, commandID: commandID)
        let pending = await h.secrets.hasPending
        #expect(!pending, "같은 명령의 정산에 재입력한 값도 버려진다")
        let busy = await h.runtime.isBusy()
        #expect(!busy, "바쁨이 아니다")
    }

    @Test func aDuplicateBeforeTheCommandWasEverSeenIsAlsoCoveredWhenItIsFirstSeenAndSettled() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        let commandID = try await firstSubmissionLostAndExhausted(h, created: created, commandSeenDuringFirstFlow: false)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent) // 아직 C를 본 적 없다
        h.server.dropResponseOnce(route: "ack") // C가 처음 목록에 나오고 lease 응답이 유실된다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        try await settleLeaseLostCommandAsNotReceived(h, commandID: commandID)
        let pending = await h.secrets.hasPending
        #expect(!pending)
        let busy = await h.runtime.isBusy()
        #expect(!busy)
    }

    @Test func bindingADuplicateLowersTheValueToTheUnsettledCommandsMarkOfThatTaskOnly() async throws {
        let value = AgentAnswerValue(text: "v")
        let task = "task-a"
        let key = LocalSecretKey(taskID: task, requestID: "r1")
        // 재입력(duplicate): 명령 c1을 본 뒤에 다시 둔 값은 늦은 차례 → 묶으면 c1의 기준으로 낮아져 c1이 정산될 때 버려진다
        let bound = LocalSecretAnswers()
        await bound.put(key: key, value: value)
        await bound.noteAnswerCommandSeen("c1", taskID: task)
        await bound.put(key: key, value: value)
        await bound.bindToExistingAnswerCommand(key)
        #expect(await bound.discard(taskID: task, settledCommand: "c1") == 1)
        // answered(새 명령): 묶지 않는다 → 늦은 차례 그대로라 옛 명령 c1의 정산에 지워지지 않는다
        let fresh = LocalSecretAnswers()
        await fresh.put(key: key, value: value)
        await fresh.noteAnswerCommandSeen("c1", taskID: task)
        await fresh.put(key: key, value: value)
        #expect(await fresh.discard(taskID: task, settledCommand: "c1") == 0)
        let kept = await fresh.contains(key: key)
        #expect(kept)
        // 아직 명령을 본 적 없다: 그대로 둔다 (처음 볼 때의 기준이 덮는다)
        let unseen = LocalSecretAnswers()
        await unseen.put(key: key, value: value)
        await unseen.bindToExistingAnswerCommand(key)
        await unseen.noteAnswerCommandSeen("c2", taskID: task)
        #expect(await unseen.discard(taskID: task, settledCommand: "c2") == 1)
        // 다른 task의 기준은 쓰지 않는다
        let elsewhere = LocalSecretAnswers()
        await elsewhere.put(key: LocalSecretKey(taskID: "task-b", requestID: "r1"), value: value)
        await elsewhere.noteAnswerCommandSeen("cb", taskID: "task-b")
        await elsewhere.put(key: key, value: value)
        await elsewhere.bindToExistingAnswerCommand(key)
        #expect(await elsewhere.discard(taskID: "task-b", settledCommand: "cb") == 1, "task-b의 기준으로는 task-b의 값만")
        let ownKept = await elsewhere.contains(key: key)
        #expect(ownKept, "task-a의 값은 그대로 (그 task의 명령을 본 적 없다)")
        // 정산되지 않은 명령이 둘이면 가장 늦게 본 것(서버가 지금 duplicate로 가리키는 명령)의 기준을 쓴다: 앞 명령의 정산이 이 값을 지우지 않는다
        let two = LocalSecretAnswers()
        await two.put(key: LocalSecretKey(taskID: task, requestID: "r0"), value: value) // 차례 1
        await two.noteAnswerCommandSeen("old", taskID: task) // 기준 1
        await two.put(key: LocalSecretKey(taskID: task, requestID: "r5"), value: value) // 차례 2
        await two.put(key: LocalSecretKey(taskID: task, requestID: "r6"), value: value) // 차례 3
        await two.noteAnswerCommandSeen("latest", taskID: task) // 기준 3
        await two.put(key: key, value: value) // 차례 4: 재입력
        await two.bindToExistingAnswerCommand(key) // → 3
        #expect(await two.discard(taskID: task, settledCommand: "old") == 1, "앞 명령은 차례 1만")
        let afterOld = await two.contains(key: key)
        #expect(afterOld)
        #expect(await two.discard(taskID: task, settledCommand: "latest") == 3, "가장 늦은 명령의 정산이 r5 · r6과 재입력 값을 버린다")
        // 기준보다 이른 차례는 올리지 않는다: 먼저 본 명령 c0의 제출 값(차례 1)이 가장 늦은 명령 c3의 기준(3)으로 올라가 c0의 정산을 피하지 않는다
        let early = LocalSecretAnswers()
        await early.put(key: key, value: value) // 차례 1
        await early.noteAnswerCommandSeen("c0", taskID: task) // 기준 1
        await early.put(key: LocalSecretKey(taskID: task, requestID: "r9"), value: value) // 2
        await early.put(key: LocalSecretKey(taskID: task, requestID: "r8"), value: value) // 3
        await early.noteAnswerCommandSeen("c3", taskID: task) // 기준 3
        await early.bindToExistingAnswerCommand(key) // 차례 1 < 3: 그대로
        await early.put(key: LocalSecretKey(taskID: task, requestID: "r7"), value: value) // 차례 4: 기준 뒤
        #expect(await early.discard(taskID: task, settledCommand: "c0") == 1, "c0의 정산이 자기 제출 값을 버린다")
        #expect(await early.discard(taskID: task, settledCommand: "c3") == 2, "c3는 r9 · r8만 (r7은 기준 뒤)")
        let late = await early.contains(key: LocalSecretKey(taskID: task, requestID: "r7"))
        #expect(late)
    }

    @Test func anAnsweredNewCommandKeepsItsLateGenerationSoAnOlderUnsettledCommandsSettleNeverWipesIt() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h, endsAfterAsking: true)
        // 같은 task에 정산되지 않은 옛 답 명령이 있다 (이 프로세스가 처음 봤다)
        await h.secrets.noteAnswerCommandSeen("old-command", taskID: created.taskID)
        let again = S.canary()
        #expect(await S.submit(h, S.answer(created, value: again)) == .sent, "서버는 answered (새 명령)")
        // 옛 명령이 not_received로 정산돼도 새 명령의 제출 값은 남는다
        await h.runtime.settleSecretsAfterReadback(commandID: "old-command", taskID: created.taskID, kind: .answer, result: .notReceived)
        let kept = await h.secrets.contains(key: S.key(created))
        #expect(kept, "answered는 새 명령이다: 옛 명령의 정산이 지우지 않는다")
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.answers == [S.itemID: .one(again)])
    }
}
#endif
