#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 독립 검토 반영 2 (OA D2b 계약 8장 정정 2): 재현 시험은 검토자가 만든 E7을 그대로 가져왔다
struct BridgeReviewETests {
    private func reports(_ h: BridgeHarness, _ commandID: String) -> [String] {
        h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == commandID }.map { "\($0["op"] ?? "-") \($0["result"] ?? "-")" }
    }

    private func failureReasons(_ h: BridgeHarness) -> [String] {
        h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }.compactMap { ($0["payload"] as? [String: Any])?["reason"] as? String }
    }

    /// 수동 시계를 조금씩 흘려 보내는 일꾼 (유예 3초를 기다리는 코드가 멈추지 않게)
    private func advancing(_ h: BridgeHarness) -> Task<Void, Never> {
        Task {
            for _ in 0..<200 {
                if Task.isCancelled { return }
                await h.clock.advance(by: 0.25)
                try? await Task.sleep(for: .milliseconds(3))
            }
        }
    }

    // MARK: 1. Stop(cancel)은 24시간 전달 창의 적용을 받지 않는다 (E7)

    @Test func aStopOlderThanADayStillStopsTheRunAndSettlesSent() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID))
        h.clock.jump(by: 25 * 3600) // Mac이 하루 넘게 잠들어 있었다
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.agent.interrupts.count == 1, "Stop은 명령이 하루 넘게 기다렸어도 agent에 닿아야 한다")
        #expect(h.agent.liveRunCount == 0)
        #expect(reports(h, cancel.commandID) == ["lease -", "complete sent"], "\(reports(h, cancel.commandID))")
        #expect(await h.command(cancel.commandID)?.reason != "expired")
    }

    /// 창을 건너뛰는 것은 목록이 아니라 lease가 준 내용이 cancel일 때다: 목록에서 cancel로 보이는 낡은 message가 창을 우회하지 못한다
    @Test func aLeaseOfAnotherKindThanTheListedOneIsRefusedSoNoOldMessageSlipsThroughAsAStop() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(running.commandID))?.state == .accepted })
        // 목록은 cancel인데 lease가 주는 내용은 message다
        let disguised = try #require(h.server.enqueueCancel(
            bridgeID: h.bridgeID, taskID: running.taskID,
            extra: ["kind": "message", "access": "write", "policy_mode": "manual", "message": ["id": UUID().uuidString.lowercased(), "text": "old"], "close_before": NSNull()]
        ))
        h.clock.jump(by: 25 * 3600)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1, "다른 일을 시키는 lease 내용은 띄우지 않는다")
        let reason = await h.command(disguised.commandID)?.reason
        #expect(reason == "payload_mismatch", "\(String(describing: reason))")
    }

    @Test func aMessageListedButLeasedAsAStopIsRefusedAndStopsNothing() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(running.commandID))?.state == .accepted })
        let swapped = h.message(session: "5e551011-0000-4000-8000-0000000000c3", task: "7a5c0001-0000-4000-8000-0000000000c3", extra: ["kind": "cancel", "cancel_scope": "turn", "abandoned_request_id": NSNull()])
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.interrupts.isEmpty, "목록이 message인 명령으로 중단하지 않는다")
        #expect(await h.command(swapped.commandID)?.reason == "payload_mismatch")
    }

    // MARK: 2. 모든 실행은 이 Mac이 승인한 작업 폴더가 있어야 한다

    private struct EmptyWorkspace: WorkspaceResolver {
        func workspace(forSession sessionID: String, adapter: String) async -> String? { "" }
    }

    @Test func anExternalSessionIDWithoutAnyFolderIsNeverStarted() async throws {
        let h = try BridgeHarness(workspace: nil)
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: "sess_from_server", workspaceRef: nil)
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "failed" }
        #expect(h.agent.startedTurns.isEmpty, "승인된 폴더 없이 재개하지 않는다")
        #expect(failureReasons(h) == ["spawn_failed"], "\(failureReasons(h))")
    }

    @Test func anEmptyFolderFromTheResolverIsNotAFolderEither() async throws {
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = EmptyWorkspace()
        try await h.restart(reopenLedger: false)
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: "sess_from_server", workspaceRef: nil)
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "failed" }
        #expect(h.agent.startedTurns.isEmpty)
        #expect(failureReasons(h) == ["spawn_failed"])
    }

    @Test func aResumeWithoutAServerFolderUsesTheFolderTheMacChose() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: "sess_from_server", workspaceRef: nil)
        h.message()
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let started = try #require(h.agent.startedTurns.first)
        #expect(started.resume && started.externalSessionID == "sess_from_server" && started.workspaceRef == "workspace-test")
    }

    // MARK: 3. 이 Mac이 그 세션에 기록한 작업 폴더는 승인된 것으로 본다

    private func canonical(_ h: BridgeHarness) async throws -> (first: FakeBridgeServer.Created, path: String) {
        h.workspaces = FixedWorkspace(path: "workspace-test", authorized: [])
        try await h.restart(reopenLedger: false)
        let path = "/private/var/work/project"
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let first = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(first.taskID) == "idle" }
        return (first, path)
    }

    @Test func aFolderTheMacReportedForTheSessionIsApprovedOnTheNextTurn() async throws {
        let h = try BridgeHarness(workspace: nil)
        let (first, path) = try await canonical(h)
        #expect(await h.task(first.taskID)?.workspaceRef == path)
        #expect(h.server.sessionState(BridgeHarness.sessionID)?.workspaceRef == path)
        let second = h.message(task: "7a5c0001-0000-4000-8000-0000000000f2", turn: 2)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let started = await h.eventually { h.agent.startedTurns.count == 2 }
        let refusal = await h.command(second.commandID)?.reason ?? "-"
        #expect(started, "\(refusal)")
        #expect(h.agent.startedTurns.last?.workspaceRef == path && h.agent.startedTurns.last?.resume == true)
    }

    @Test func theRecordedFolderOfOneSessionApprovesNothingInAnotherOrADifferentValue() async throws {
        let h = try BridgeHarness(workspace: nil)
        let (_, path) = try await canonical(h)
        // 다른 세션이 같은 값을 보낸다
        let otherSession = "5e551011-0000-4000-8000-0000000000b2"
        h.server.ensureSession(id: otherSession, bridgeID: h.bridgeID, externalSessionID: "ext-2", workspaceRef: path)
        let other = h.message(session: otherSession, task: "7a5c0001-0000-4000-8000-0000000000f3")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1, "다른 세션에는 승인이 옮겨 가지 않는다")
        #expect(await h.command(other.commandID)?.reason == "workspace_unauthorized")
        // 같은 세션이지만 기록과 다른 값
        let third = h.message(task: "7a5c0001-0000-4000-8000-0000000000f4", turn: 2, extra: ["session": ["external_session_id": "ext-1", "workspace_ref": "/Users/someone/.ssh", "resume": true]])
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1, "기록과 다른 값은 승인되지 않는다")
        #expect(await h.command(third.commandID)?.reason == "workspace_unauthorized")
    }

    // MARK: 5. 답을 기다리던 task를 cancel로 정산하면 원장도 cancelled다

    @Test func cancellingATaskThatWaitsForAnAnswerClosesItAndPruneRemovesIt() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .question(question), .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        #expect(await h.task(created.taskID)?.lastState == "awaiting_answer")
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID, abandoned: "req-1"))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.commandOutcome(cancel.commandID) != nil }
        #expect(reports(h, cancel.commandID).last?.hasPrefix("complete") == true, "\(reports(h, cancel.commandID))")
        let task = try #require(await h.task(created.taskID))
        #expect(task.lastState == "cancelled", "답을 기다리던 task가 열린 채로 남으면 heartbeat · reconcile에 영원히 실린다")
        #expect(!task.isUnfinished)
        for _ in 0..<3 {
            h.clock.jump(by: 6)
            await h.runtime.tick()
        }
        await h.settle {
            let sent = (try? await h.ledger.outboxRows().isEmpty) == true
            let finished = (try? await h.ledger.allCommands().allSatisfy { $0.state.isFinished }) == true
            return sent && finished
        }
        h.clock.jump(by: 8 * 86400)
        let report = try await h.ledger.prune(now: h.clock.now)
        #expect(report.tasks == 1)
        #expect(await h.task(created.taskID) == nil)
    }

    /// 닫는 규칙의 표: 돌고 있지 않고 아직 끝나지 않은 상태만 `cancelled`로 닫는다. 끝난 기록(idle · failed)과 살아 있는 프로세스는 그대로 둔다
    @Test func aStopClosesOnlyTasksThatAreNotRunningAndNotAlreadyFinished() async throws {
        let h = try BridgeHarness()
        let table: [(state: String, alive: Bool, expected: String)] = [
            ("awaiting_answer", false, "cancelled"), ("dispatched", false, "cancelled"), ("accepted", false, "cancelled"), ("running", false, "cancelled"),
            ("idle", false, "idle"), ("failed", false, "failed"), ("cancelled", false, "cancelled"),
            ("running", true, "running"), ("awaiting_answer", true, "awaiting_answer"),
        ]
        for (index, row) in table.enumerated() {
            var task = BridgeTest.task("7a5c0001-0000-4000-8000-0000000001\(String(format: "%02d", index))", session: "5e551011-0000-4000-8000-0000000001\(String(format: "%02d", index))", at: h.clock.now)
            task.lastState = row.state
            task.alive = row.alive
            try await h.ledger.saveTask(task)
            await h.runtime.settleIdleTaskAsCancelled(task.agentTaskID)
            #expect(await h.task(task.agentTaskID)?.lastState == row.expected, "\(row.state) alive=\(row.alive)")
        }
    }

    @Test func aStopThatComesBackAsAReadbackAlsoClosesATaskThatWaitsForAnAnswer() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .question(question), .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID))
        h.server.markLeasedUnknown(cancel.commandID) // 이 Mac이 lease했지만 결과를 모른다 -> 서버가 결과 확인으로 다시 묻는다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.commandOutcome(cancel.commandID) != nil }
        #expect(await h.task(created.taskID)?.lastState == "cancelled", "\(reports(h, cancel.commandID))")
    }

    // MARK: 4. 호스트가 런타임을 놓을지 가르는 값: 멈춘 런타임의 상태는 늦게 끝나는 일이 되돌리지 못한다

    @Test func aStoppedRuntimeKeepsItsStoppedStatusWhenALateRequestFinishes() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        await h.runtime.stop()
        #expect(await h.runtime.status == .stopped)
        // 멈추기 전에 시작한 heartbeat · 등록이 뒤늦게 끝나는 모양 (`stop()` 뒤에 상태를 다시 쓰려 한다)
        for late in [BridgeStatus.connected, .connecting, .offline] {
            await h.runtime.setStatus(late)
            #expect(await h.runtime.status == .stopped, "\(late)")
        }
        await h.runtime.resume()
        #expect(await h.runtime.status != .stopped, "resume은 네트워크를 다시 켜고 상태를 되살린다")
    }

    // MARK: 6a. 계정 삭제: 끝내지 못한 프로세스를 알린다

    @Test func accountDeletionCountsARunItCouldNotEnd() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        h.agent.setIgnoreInterruptForever(true)
        h.agent.setTerminateResult(.alive) // SIGKILL도 듣지 않는다
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let worker = advancing(h)
        let unresolved = await h.runtime.interruptLiveTurns()
        worker.cancel()
        #expect(unresolved == 1, "끝내지 못한 프로세스 수를 돌려준다")
    }

    @Test func accountDeletionCountsAnOrphanWhoseEndCannotBeProven() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        _ = h.agent.abandon()
        await h.runtime.abandonForTest()
        h.agent.setLiveness(.unknown)
        try await h.restart()
        await h.runtime.tick()
        let unresolved = await h.runtime.interruptLiveTurns()
        #expect(unresolved == 1, "끝을 증명하지 못한 감독 밖 프로세스도 센다")
    }

    @Test func accountDeletionCountsNothingWhenEveryRunEnded() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let worker = advancing(h)
        let unresolved = await h.runtime.interruptLiveTurns()
        worker.cancel()
        #expect(unresolved == 0)
    }

    // MARK: 6b. marker는 UUID 모양만 adapter에 넘긴다

    @Test func aMarkerThatIsNotUUIDShapedNeverReachesTheAdapter() async throws {
        for bad in ["tf-abcdef123456", "--dangerously-skip-permissions", "a b", "12345678-1234-1234-1234-12345678901", "12345678123412341234123456789012", "12345678-1234-1234-1234-1234567890123", "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz", "../../etc"] {
            let h = try BridgeHarness()
            await h.registerFirst()
            let created = h.message(extra: ["marker": bad])
            await h.runtime.tick()
            #expect(h.agent.startedTurns.isEmpty, "\(bad): 띄우지 않는다")
            #expect(await h.command(created.commandID)?.reason == "unsafe_marker", "\(bad)")
            #expect(reports(h, created.commandID).contains("readback not_received"), "\(bad): \(reports(h, created.commandID))")
        }
    }

    @Test func aUUIDMarkerIsPassedAsIs() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let marker = UUID().uuidString.lowercased()
        h.message(extra: ["marker": marker])
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(h.agent.startedTurns.first?.marker == marker)
    }

    @Test func theFakeServerHandsOutUUIDMarkersLikeTheRealOne() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        #expect(UUID(uuidString: created.marker) != nil, "실제 서버의 marker는 uuid다 (execution_intents.marker)")
    }

    @Test func anAnswerWithAMarkerThatIsNotUUIDShapedIsRefusedBeforeDelivery() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false, extra: ["marker": "--evil"]))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.deliveredAnswers.isEmpty)
        #expect(await h.command(answer.commandID)?.reason == "unsafe_marker")
    }

    @Test func aReadbackWithAMarkerThatIsNotUUIDShapedAsksTheAdapterNothing() async throws {
        let h = try BridgeHarness()
        h.agent.setReadback(.received)
        await h.registerFirst()
        var record = BridgeTest.command("c0000000-0000-4000-8000-0000000000a1", state: .startIntent, at: h.clock.now)
        record.marker = "tf-notauuid"
        try await h.ledger.saveCommand(record)
        let task = BridgeTest.task(at: h.clock.now)
        try await h.ledger.saveTask(task)
        let facts = await h.runtime.readbackFacts(source: .readbackList, command: record, marker: "tf-notauuid")
        #expect(facts.adapterReadback == .unsupported, "UUID 모양이 아닌 marker는 adapter에 묻지 않는다")
        let good = await h.runtime.readbackFacts(source: .readbackList, command: record, marker: UUID().uuidString.lowercased())
        #expect(good.adapterReadback == .received)
    }

    // MARK: 6d. 살아 있지 않은 dispatched · awaiting_answer task도 기한 뒤 지운다

    @Test func prunePutsAnEndToDeadDispatchedAndAwaitingAnswerTasksAfterAWeek() async throws {
        let dir = TempDirectory()
        let ledger = try BridgeLedger(directory: dir.appending("p"), now: { BridgeTest.t0 })
        let old = BridgeTest.t0.addingTimeInterval(-8 * 86400)
        let recent = BridgeTest.t0.addingTimeInterval(-6 * 86400)
        func save(_ id: String, state: String, alive: Bool = false, at: Date = old) async throws {
            var task = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000\(id)", session: "5e551011-0000-4000-8000-0000000000\(id)", at: at)
            task.lastState = state
            task.alive = alive
            try await ledger.saveTask(task)
        }
        try await save("01", state: "dispatched")
        try await save("02", state: "awaiting_answer")
        try await save("03", state: "dispatched", at: recent)
        try await save("04", state: "awaiting_answer", alive: true)
        try await save("05", state: "running")
        let report = try await ledger.prune(now: BridgeTest.t0)
        #expect(report.tasks == 2)
        let left = Set(try await ledger.allTasks().map(\.lastState))
        #expect(try await ledger.allTasks().count == 3 && left == ["dispatched", "awaiting_answer", "running"])
        #expect(try await ledger.task("7a5c0001-0000-4000-8000-000000000004")?.alive == true)
    }

    @Test func pruneKeepsAnOldDispatchedTaskThatStillHasUnsentEventsOrAnOpenCommand() async throws {
        let dir = TempDirectory()
        let ledger = try BridgeLedger(directory: dir.appending("p"), now: { BridgeTest.t0.addingTimeInterval(-8 * 86400) })
        let old = BridgeTest.t0.addingTimeInterval(-8 * 86400)
        var withEvent = BridgeTest.task("7a5c0001-0000-4000-8000-000000000011", session: "5e551011-0000-4000-8000-000000000011", at: old)
        withEvent.lastState = "awaiting_answer"
        try await ledger.saveTask(withEvent)
        _ = try await ledger.appendEvent(taskID: withEvent.agentTaskID, numbering: .taskSequence, build: BridgeTest.build(at: BridgeTest.t0), update: { _ in })
        var withCommand = BridgeTest.task("7a5c0001-0000-4000-8000-000000000012", session: "5e551011-0000-4000-8000-000000000012", at: old)
        withCommand.lastState = "dispatched"
        try await ledger.saveTask(withCommand)
        try await ledger.saveCommand(BridgeTest.command("c0000000-0000-4000-8000-000000000012", task: withCommand.agentTaskID, state: .leased, at: old))
        _ = try await ledger.prune(now: BridgeTest.t0)
        #expect(try await ledger.allTasks().count == 2)
    }

    // MARK: 6c. 응답 4MB 상한은 읽으면서 센다

    private func streamingClient(host: String) -> BridgeClient {
        let user = UUID()
        return BridgeClient(baseURL: URL(string: "https://\(host)")!, session: StubURLProtocol.session(), expectedUserID: user, bearer: { BridgeBearer(userID: user, accessToken: "user-jwt") })
    }

    private static let bridgeID = "b1111111-1111-4111-8111-111111111111"
    private static let secret = "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI"

    @Test func aResponseIsCutOffWhileItStreamsOncePastTheCap() async throws {
        let host = "\(UUID().uuidString.lowercased()).stream.test"
        // 대역은 쉬지 않고 보낸다(조각마다 4ms, 끊기면 멈춘다). 다 보내려면 24초(375MB) — 클라이언트가 붐비는 기계에서 4MB를 읽는 데 걸리는 시간보다 훨씬 길다:
        // 보내는 쪽이 읽는 쪽을 앞질러 끝까지 보내 버리는 일 없이, "끝까지 받기 전에 끊었다"를 셀 수 있다
        let total = 6000
        let chunk = 64 * 1024
        StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(chunks: total, chunkSize: chunk, chunkInterval: 0.004) }
        let client = streamingClient(host: host)
        await #expect(throws: BridgeClientError.server(status: 200)) {
            _ = try await client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        }
        // 끊긴 그때 보낸 조각 수: 상한(4MB)을 넘긴 뒤에 끊었고(그 전이면 상한 검사가 아니다), 끝까지 받기 전에 끊었다
        let delivered = StubURLProtocol.delivered(host: host)
        #expect(delivered >= BridgeClient.maxResponseBytes / chunk, "상한까지는 받았다: \(delivered)/\(total)")
        #expect(delivered < total, "상한을 넘으면 끊는다. 끝까지 받고 센 것이 아니다: \(delivered)/\(total)")
    }

    @Test func aResponseThatAnnouncesAHugeBodyIsRefusedBeforeReadingIt() async throws {
        let host = "\(UUID().uuidString.lowercased()).announce.test"
        StubURLProtocol.install(host: host) { _ in StubURLProtocol.Reply(headers: ["Content-Length": String(BridgeClient.maxResponseBytes + 1)], body: Data("{}".utf8)) }
        let client = streamingClient(host: host)
        await #expect(throws: BridgeClientError.server(status: 200)) {
            _ = try await client.commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        }
    }

    @Test func aBodyJustUnderTheCapStillDecodesNormally() async throws {
        let host = "\(UUID().uuidString.lowercased()).normal.test"
        StubURLProtocol.install(host: host) { _ in
            StubURLProtocol.Reply(body: Data(#"{"commands":[],"readbacks":[],"next_cursor":0,"server_time":"2026-10-14T05:00:00Z"}"#.utf8))
        }
        let response = try await streamingClient(host: host).commands(bridgeID: Self.bridgeID, secret: Self.secret, after: 0, wait: 0)
        #expect(response.commands.isEmpty)
    }
}
#endif
