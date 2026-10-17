#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// OA D4b-m-2 (계약 16.3-3 · 16.8, F2 notes 10장 6 · 7): 값의 수명. 열쇠는 (task, request), TTL 24시간, 정산 때 버리고, 계정이 떠나거나 종료하거나 폐기되면 모두 버린다.
struct BridgeSecretLifetimeTests {
    typealias S = SecretFixture

    // MARK: 열쇠

    @Test func theKeyIsTheTaskAndTheRequestSoTheSameRequestIDOfAnotherTaskNeverMixes() async {
        let secrets = LocalSecretAnswers()
        let a = LocalSecretKey(taskID: "7A5C0001-0000-4000-8000-00000000000A", requestID: "req")
        let b = LocalSecretKey(taskID: "7a5c0001-0000-4000-8000-00000000000b", requestID: "req")
        await secrets.put(key: a, value: AgentAnswerValue(text: "value-of-a"))
        await secrets.put(key: b, value: AgentAnswerValue(text: "value-of-b"))
        #expect(await secrets.take(key: b)?.text == "value-of-b")
        let hasA = await secrets.contains(key: a)
        let hasB = await secrets.contains(key: b)
        #expect(hasA && !hasB)
        #expect(a == LocalSecretKey(taskID: "7a5c0001-0000-4000-8000-00000000000a", requestID: "req"), "task id의 대소문자는 같은 열쇠다")
        #expect(await secrets.take(key: LocalSecretKey(taskID: a.taskID, requestID: "other")) == nil)
    }

    @Test func anAnswerCommandOfAnotherTasksValueClosesTheRequestAndDeliversNothing() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        // 같은 request id의 값이 다른 task의 열쇠로만 있다
        let stranger = LocalSecretKey(taskID: UUID().uuidString, requestID: S.requestID)
        await h.secrets.put(key: stranger, value: AgentAnswerValue(text: "belongs-to-another-task"))
        h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: S.requestID, locally: true, structured: true)
        h.clock.jump(by: 6)
        _ = await h.runtime.poll(wait: 0, reason: .heartbeat) // housekeeping 없이 목록만: 다른 task의 값이 섞이지 않는지만 본다
        #expect(h.agent.deliveredAnswers.isEmpty, "다른 task의 값은 전달되지 않는다")
        #expect(h.agent.closedRequests.map(\.requestID) == [S.requestID], "값이 없으니 요청을 닫는다")
        #expect(await h.secrets.contains(key: stranger), "남의 값은 건드리지 않는다")
    }

    // MARK: TTL · 원장과 대조

    @Test func aValueOlderThanTheDeliveryWindowIsDroppedByHousekeepingAndNotBefore() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        h.clock.jump(by: 24 * 3600 - 120)
        await h.runtime.housekeeping()
        #expect(await h.secrets.contains(key: S.key(created)), "창 안에서는 둔다 (Mac이 잠든 사이에도 답이 사라지지 않는다)")
        h.clock.jump(by: 240)
        await h.runtime.housekeeping()
        #expect(await h.secrets.hasPending == false, "24시간이 지났다")
        #expect(h.log.events.contains("secret_answers_dropped"))
    }

    @Test func aValueWhoseRequestIsNoLongerOpenInTheLedgerIsDropped() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        _ = try await h.ledger.updateTask(created.taskID) {
            $0.closedRequestIDs.append(S.requestID)
            $0.openRequestID = nil
        }
        await h.runtime.housekeeping()
        #expect(await h.secrets.hasPending == false)
    }

    @Test func aValueForATaskTheLedgerDoesNotKnowIsDropped() async throws {
        let h = try BridgeHarness()
        _ = try await S.open(h)
        await h.secrets.put(key: LocalSecretKey(taskID: UUID().uuidString, requestID: S.requestID), value: AgentAnswerValue(text: "orphan-value"))
        await h.runtime.housekeeping()
        #expect(await h.secrets.hasPending == false)
    }

    @Test func aValueWhoseRequestIsStillOpenSurvivesHousekeeping() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        await h.runtime.housekeeping()
        #expect(await h.secrets.contains(key: S.key(created)))
    }

    // MARK: 정산 때 버린다

    @Test func aWithdrawnAnswerCommandDropsTheValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        h.server.gateOpen = false // lease가 withdrawn/write_gate_closed로 거둔다
        h.clock.jump(by: 6)
        _ = await h.runtime.poll(wait: 0, reason: .heartbeat)
        #expect(h.agent.deliveredAnswers.isEmpty)
        #expect(await h.secrets.hasPending == false, "정산(withdrawn)에서 값이 0이 된다")
    }

    @Test func aStaleAnswerCommandDropsTheValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        // 서버가 만든 답 명령의 lease가 stale(run_closed)을 받는다 (다시 시도하지 않는 끝)
        let commandID = try #require(h.server.commandIDs(taskID: created.taskID, kind: "answer").first)
        h.server.staleOnNextLease(commandID, reason: "run_closed")
        h.clock.jump(by: 6)
        _ = await h.runtime.poll(wait: 0, reason: .heartbeat)
        #expect(h.agent.deliveredAnswers.isEmpty)
        #expect(await h.secrets.hasPending == false, "정산(stale)에서 값이 0이 된다")
    }

    @Test func closingTheRequestDropsItsValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        let record = BridgeTest.command(kind: "answer", task: created.taskID)
        await h.runtime.closeRequestAndAck(record: record, taskID: created.taskID, requestID: S.requestID, adapterID: "agent:claude-code", session: created.sessionID, adapterClose: false)
        #expect(await h.secrets.hasPending == false)
    }

    @Test func aDeclinedAnswerCommandDropsTheValue() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        let record = BridgeTest.command(kind: "answer", task: created.taskID)
        await h.secrets.noteAnswerCommandSeen(record.commandID, taskID: created.taskID) // 목록에 나와 이 Mac이 처음 본 뒤에 거절한다
        await h.runtime.refuseUnknownPayload(record: record, why: "unknown_payload")
        #expect(await h.secrets.hasPending == false)
    }

    @Test func aValuePutAgainDuringDeliveryDoesNotSurviveTheDelivery() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        let canary = S.canary()
        #expect(await S.submit(h, S.answer(created, value: canary)) == .sent)
        // `take` 뒤에 `duplicate` 응답을 받은 submit이 같은 열쇠로 다시 `put`한 경우를 흉내 낸다
        let key = S.key(created)
        h.agent.onDeliver { [secrets = h.secrets] _ in await secrets.put(key: key, value: AgentAnswerValue(answers: [S.itemID: .one(canary)])) }
        await S.deliver(h)
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(await h.secrets.hasPending == false, "전달이 끝난 뒤 같은 열쇠를 한 번 더 버린다")
    }

    @Test func aDeliveryThatThrowsLeavesNoValueBehind() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        h.agent.setAnswersFail(true)
        await S.deliver(h)
        #expect(await h.eventually { (try? await h.ledger.task(created.taskID))?.closedRequestIDs.contains(S.requestID) == true })
        #expect(await h.secrets.hasPending == false)
    }

    // MARK: 전부 버리는 때

    @Test func accountLeftShutdownInterruptRevokeAndStopAllClearEveryValue() async throws {
        for trigger in ["accountLeft", "shutdown", "interruptLiveTurns", "revoked", "stop"] {
            let h = try BridgeHarness()
            let created = try await S.open(h)
            #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent, Comment(rawValue: trigger))
            #expect(await h.secrets.hasPending, "\(trigger): 시작 전에는 값이 있다")
            switch trigger {
            case "accountLeft": await h.runtime.accountLeft()
            case "shutdown": await h.runtime.shutdown(interrupt: false)
            case "interruptLiveTurns": _ = await h.runtime.interruptLiveTurns()
            case "revoked":
                h.server.revoke(bridgeID: h.bridgeID)
                h.clock.jump(by: 40)
                await h.runtime.tick()
            default: await h.runtime.stop()
            }
            #expect(await h.secrets.hasPending == false, "\(trigger): 값 0")
        }
    }

    @Test func busyMeansAValueIsWaitingInMemory() async {
        let secrets = LocalSecretAnswers()
        let flag = Locked<[Bool]>([])
        await secrets.observe { flag.set(flag.get() + [$0]) }
        let key = LocalSecretKey(taskID: UUID().uuidString, requestID: "r")
        await secrets.put(key: key, value: AgentAnswerValue(text: "x"))
        #expect(await secrets.hasPending)
        _ = await secrets.take(key: key)
        #expect(await secrets.hasPending == false && flag.get() == [true, false])
    }

    // MARK: 덤프

    @Test func theBoxNeverSpeaksTheValueThroughAnyReflectionPath() async {
        let secrets = LocalSecretAnswers()
        let canary = S.canary()
        let key = LocalSecretKey(taskID: UUID().uuidString, requestID: "r")
        await secrets.put(key: key, value: AgentAnswerValue(answers: [S.itemID: .one(canary)], text: canary))
        var text = ""
        dump(secrets, to: &text)
        text += String(describing: secrets) + String(reflecting: secrets) + String(describing: Mirror(reflecting: secrets).children.map { "\($0)" })
        let box = LocalAnswerBox(AgentAnswerValue(answers: [S.itemID: .one(canary)], text: canary))
        dump(box, to: &text)
        text += String(describing: box) + String(reflecting: box) + String(describing: Mirror(reflecting: box).children.map { "\($0)" })
        #expect(!text.contains(canary), "덤프 · describing · reflecting · Mirror 어디에도 값이 없다")
        #expect(await secrets.take(key: key)?.text == canary, "양성 대조: 값은 take로만 나온다")
    }

    @Test func shutdownDropsTheValueBeforeItFlushesAnythingToTheServer() async throws {
        let h = try BridgeHarness()
        let created = try await S.open(h)
        #expect(await S.submit(h, S.answer(created, value: S.canary())) == .sent)
        #expect(await h.secrets.hasPending)
        try await h.seedEvents(count: 1) // 종료 때 비울 사건이 있어야 비우는 도중을 볼 수 있다
        let duringFlush = Locked<[Bool]>([])
        h.server.onRequest = { [secrets = h.secrets] record in
            if record.route == "events" { duringFlush.set(duringFlush.get() + [await secrets.hasPending]) }
        }
        await h.runtime.shutdown(interrupt: false)
        #expect(!duringFlush.get().isEmpty, "양성 대조: 종료 도중 사건을 실제로 비웠다")
        #expect(duringFlush.get().allSatisfy { !$0 }, "종료가 시작되면 비밀값은 바로 버린다: 사건을 비우는 동안에도 값이 없다 (D4bm-22)")
    }
}
#endif
