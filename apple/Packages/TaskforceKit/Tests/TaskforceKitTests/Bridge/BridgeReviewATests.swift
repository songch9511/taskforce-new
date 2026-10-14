#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 독립 검토 반영 A (OA D2b 계약 7장 A, code P1 넷): 재현 시험은 검토자가 만든 E1 · E1b · E2 · E4 · E6를 그대로 가져왔다
struct BridgeReviewATests {
    // MARK: A1 — 한 task의 외부 작업 id는 처음 묶인 값을 바꾸지 않는다

    @Test func anAnswerThatStartsANewProcessNeverChangesTheTasksExternalTaskID() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        // Claude Code 모양: 질문을 낸 프로세스는 답이 오기 전에 끝나고, 답은 새 프로세스(새 외부 작업 id)로 이어진다
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .question(question), .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        let first = try #require(await h.task(created.taskID)?.externalTaskID)
        h.clock.jump(by: 1)
        await h.runtime.tick()
        _ = h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.agent.deliveredAnswers.count == 1 }
        for _ in 0..<3 {
            h.clock.jump(by: 6)
            await h.runtime.tick()
        }
        let results = h.server.eventResults.map { "\($0.type):\($0.status)" }
        #expect(!h.server.eventResults.contains { $0.status == "conflict" }, "\(results)")
        #expect(h.server.taskState(created.taskID) == "idle", "\(results)")
        #expect(await h.task(created.taskID)?.externalTaskID == first, "처음 묶인 값을 유지한다")
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }.compactMap { $0["external_task_id"] as? String }
        #expect(Set(sent) == [first], "서버로 간 외부 작업 id는 하나뿐이다: \(sent)")
    }

    // MARK: A2 — 2xx인데 본문을 읽을 수 없으면 일시 실패다

    @Test func a200ThatIsNotTheExpectedJSONNeverDeadLettersOrSplitsEvents() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 3)
        let before = h.server.requests("events").count
        h.server.failNext("events", .init(status: 200, count: 10)) // 로그인 안내 창 같은 2xx
        await h.runtime.flushOutbox()
        let all = try await h.ledger.outboxRows(includeDead: true)
        #expect(all.count == 3 && all.allSatisfy { $0.deadReason == nil }, "행 유지: \(all.map { $0.deadReason ?? "live" })")
        #expect(all.allSatisfy { $0.attempts == 1 }, "물러서며 시도 횟수만 오른다")
        #expect(h.server.requests("events").count == before + 1, "묶음을 쪼개 다시 보내지 않는다")
        // 서버가 돌아오면 같은 행이 같은 event id로 나간다
        h.server.clearFailures()
        h.clock.jump(by: 120)
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
    }

    @Test func aRealHTTP400StillSplitsAndDeadLettersButA200DoesNot() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 1)
        h.server.failNext("events", .init(status: 400, count: 10))
        await h.runtime.flushOutbox()
        let dead = try await h.ledger.outboxRows(includeDead: true)
        #expect(dead.count == 1 && dead[0].deadReason == "bad_request")
    }

    @Test func a200ThatIsNotTheExpectedJSONOnAnAckKeepsTheAckForALaterRetry() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let request = BridgeV1AckRequest(bridgeID: h.bridgeID, commandID: "c0000000-0000-4000-8000-0000000000aa", op: .decline)
        let body = String(decoding: try TaskforceJSON.encoder().encode(request), as: UTF8.self)
        try await h.ledger.enqueueAck(commandID: request.commandID, op: "decline", result: nil, bodyJSON: body)
        h.server.failNext("ack", .init(status: 200, count: 1))
        await h.runtime.flushAcks()
        let rows = try await h.ledger.allAcks()
        #expect(rows.count == 1 && rows[0].attempts == 1, "읽을 수 없는 2xx로 ack를 지우지 않는다")
    }

    // MARK: A3 — 확인할 수 없는 고아

    /// 시작 의도만 있고 정체를 적기 전에 죽었다. adapter는 끝을 증명하지 못해 `.unknown`을 준다
    private func unverifiedOrphanHarness() async throws -> (BridgeHarness, FakeBridgeServer.Created) {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        h.agent.onStart { [h] _ in await h.runtime.abandonForTest() }
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        h.agent.onStart(nil)
        h.agent.setLiveness(.unknown)
        try await h.restart()
        return (h, created)
    }

    @Test func anOrphanWhoseEndCannotBeProvenAnswersTheServersQuestionWithUnknownOnce() async throws {
        let (h, created) = try await unverifiedOrphanHarness()
        h.clock.jump(by: 400)
        h.server.sweep()
        #expect(h.server.commandStep(created.commandID) == "unknown_outcome")
        for _ in 0..<4 {
            h.clock.jump(by: 6)
            await h.runtime.tick()
        }
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == created.commandID }
        let readbacks = acks.filter { $0["op"] as? String == "readback" }
        #expect(readbacks.map { $0["result"] as? String } == ["unknown"], "한 번만 unknown: \(acks)")
        #expect(h.agent.startedTurns.count == 1, "다시 띄우지 않는다")
    }

    @Test func anUnverifiedOrphanDoesNotKeepTheLeaseAliveThroughHeartbeats() async throws {
        let (h, created) = try await unverifiedOrphanHarness()
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let firstTasks = (h.server.requests("heartbeat").last?.json["tasks"] as? [[String: Any]]) ?? []
        let entry = firstTasks.first { $0["task_id"] as? String == created.taskID }
        #expect(entry != nil && entry?["process_alive"] as? Bool == false, "확인하지 못한 프로세스를 살아 있다고 보내지 않는다: \(firstTasks)")
        for _ in 0..<20 {
            h.clock.jump(by: 31)
            await h.runtime.tick()
            h.server.sweep()
        }
        #expect(h.server.commandStep(created.commandID) != "calling", "낡은 lease가 영원히 살아 있지 않다")
    }

    @Test func anUnverifiedOrphanIsNotBusyForTheUpdateRelaunchButStillBlocksTheSession() async throws {
        let (h, created) = try await unverifiedOrphanHarness()
        await h.runtime.tick()
        #expect(await h.runtime.isBusy() == false, "Sparkle 재시작을 막지 않는다")
        let blocker = try await h.ledger.liveTask(inSession: created.sessionID, excluding: nil)
        #expect(blocker?.agentTaskID == created.taskID, "같은 세션의 다음 실행은 계속 막는다 (writer 하나)")
    }

    @Test func reconcileTreatsAnUnverifiedOrphanLikeAnUnknownProcessAndReportsItOnce() {
        var record = BridgeTest.command(state: .startIntent)
        #expect(
            Reconcile.readback(ReadbackFacts(source: .readbackList, command: record, process: .unverifiedOrphan)) == .report(.unknown, processEnded: false),
            "시작 중에 죽음 + 끝을 증명 못 함 -> unknown"
        )
        record.state = .accepted
        record.signalAt = BridgeTest.t0
        #expect(Reconcile.readback(ReadbackFacts(source: .readbackList, command: record, process: .unverifiedOrphan)) == .report(.received, processEnded: false))
        #expect(
            Reconcile.readback(ReadbackFacts(source: .readbackList, command: record, process: .unverifiedOrphan, outboxPending: true)) == .replayOutboxFirst,
            "접수 신호가 있고 보낼 사건이 있으면 먼저 재생"
        )
        record.state = .startIntent
        record.signalAt = nil
        record.ackOp = "readback"
        record.ackResult = "unknown"
        #expect(Reconcile.readback(ReadbackFacts(source: .readbackList, command: record, process: .unverifiedOrphan)) == .none, "unknown은 한 번만")
    }

    @Test func aVerifiedLiveOrphanIsReportedAliveAndEndedFirst() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        _ = h.agent.abandon()
        await h.runtime.abandonForTest()
        h.agent.setLiveness(.alive)
        try await h.restart()
        await h.runtime.tick()
        #expect(h.agent.terminatedOrphans.count == 1, "살아 있는 고아는 먼저 끝낸다")
    }

    // MARK: A4 — reactivate가 성공하면 루프를 다시 시작한다

    @Test func reactivateAfterARevokeBringsTheLoopBack() async throws {
        let wake = FakeBridgeWake(subscribed: true)
        let h = try BridgeHarness(wake: wake)
        await h.runtime.start()
        #expect(await h.eventually { h.server.requests("commands").count >= 1 })
        h.server.revoke(bridgeID: h.bridgeID)
        for _ in 0..<60 {
            await h.clock.advance(by: 5)
            try? await Task.sleep(for: .milliseconds(30))
            if await h.runtime.status == .revoked { break }
        }
        #expect(await h.runtime.status == .revoked)
        #expect(await h.runtime.reactivate())
        let heartbeatsBefore = h.server.requests("heartbeat").count
        for _ in 0..<20 {
            await h.clock.advance(by: 5)
            try? await Task.sleep(for: .milliseconds(20))
        }
        _ = h.message()
        wake.fire()
        for _ in 0..<6 {
            await h.clock.advance(by: 5)
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(h.server.requests("heartbeat").count > heartbeatsBefore, "Reconnect this Mac 뒤 heartbeat가 다시 간다")
        #expect(await h.eventually { h.agent.startedTurns.count == 1 }, "새 명령이 실행된다")
        await h.runtime.stop()
    }
}
#endif
