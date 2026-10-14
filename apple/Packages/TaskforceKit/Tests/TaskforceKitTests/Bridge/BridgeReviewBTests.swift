#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 독립 검토 반영 B (OA D2b 계약 7장 B, code P2 다섯): drain 멈춤 · 한 트랜잭션 · 나가는 값 정리기 · 살아남은 변이를 잡는 값 시험
struct BridgeReviewBTests {
    private func ackBody(_ h: BridgeHarness, op: BridgeV1AckOp = .decline, command: String = UUID().uuidString.lowercased()) throws -> (command: String, body: String) {
        let request = BridgeV1AckRequest(bridgeID: h.bridgeID, commandID: command, op: op)
        return (command, String(decoding: try TaskforceJSON.encoder().encode(request), as: UTF8.self))
    }

    // MARK: 5. drain 모드는 할 일이 없으면 멈춘다

    @Test func drainModeWithNothingLeftSendsNothingAndStops() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.restart(mode: .drain)
        #expect(try await h.ledger.hasPendingWork() == false)
        let before = h.server.requests.count
        for _ in 0..<5 {
            h.clock.jump(by: 31)
            await h.runtime.tick()
        }
        #expect(h.server.requests.count == before, "할 일이 없으면 heartbeat도 목록도 보내지 않는다: \(h.server.requests.dropFirst(before).map(\.route))")
        #expect(await h.runtime.status == .stopped)
    }

    @Test func drainModeStopsOnceTheLastUnsentEventIsDelivered() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 2) // 서버는 이 task를 모른다: 최종 not_found로 지워진다
        try await h.restart(mode: .drain)
        #expect(try await h.ledger.hasPendingWork())
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(try await h.ledger.outboxRows().isEmpty, "남은 사건을 모두 보냈다")
        #expect(await h.runtime.status == .stopped, "끝나면 멈춘다")
    }

    @Test func aDrainRuntimeNeverLeasesAnAnswer() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "fake-session-1", workspace: "workspace-fake"), .accepted, .question(question), .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(created.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        // 다른 세션의 보내지 못한 사건이 남아 있어 마무리 모드가 계속 돈다
        try await h.seedEvents(count: 1, task: "7a5c0001-0000-4000-8000-0000000000e2", session: "5e551011-0000-4000-8000-0000000000e2")
        try await h.restart(mode: .drain)
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false))
        h.server.failNext("events", .init(status: 0, transport: true, count: 1000))
        for _ in 0..<3 {
            h.clock.jump(by: 6)
            await h.runtime.tick()
        }
        #expect(h.server.commandLeaseCount(answer.commandID) == 0, "마무리 모드는 새 전달(답 포함)을 lease하지 않는다")
        #expect(h.agent.deliveredAnswers.isEmpty)
    }

    // MARK: 6. 원장 분실 · 기록 없음

    @Test func aDeclinedRecordMadeFromALostLedgerIsNeverProvenNotReceived() {
        for reason in ["ledger_lost", "no_record"] {
            var record = BridgeTest.command(state: .declined)
            record.reason = reason
            #expect(
                Reconcile.readback(ReadbackFacts(source: .readbackList, command: record, process: .unknown)) == .report(.unknown, processEnded: false),
                "\(reason): 띄웠는지 모르므로 unknown"
            )
            record.ackOp = "readback"
            record.ackResult = "unknown"
            #expect(Reconcile.readback(ReadbackFacts(source: .readbackList, command: record, process: .unknown)) == .none, "unknown은 한 번만")
        }
        var refused = BridgeTest.command(state: .declined)
        refused.reason = "unknown_payload"
        #expect(
            Reconcile.readback(ReadbackFacts(source: .readbackList, command: refused, process: .unknown)) == .report(.notReceived, processEnded: true),
            "payload를 거절한 명령은 띄운 적이 없다는 것이 증명된다"
        )
    }

    @Test func theLostLedgerRecordAndItsAckAreWrittenInOneTransaction() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        try await h.wipeLedger()
        try await h.restart(adapters: [FakeAgentProcess(clock: h.clock.clock)])
        // ack 행을 쓰는 순간 실패한다: 기록만 `declined`로 남으면 반쪽 상태다
        await h.ledger.debugFailWrite(containing: "INTO ack_outbox")
        await h.runtime.tick()
        #expect(await h.command(created.commandID) == nil, "ack가 안 적혔으면 명령 기록도 없다 (한 트랜잭션)")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let record = try #require(await h.command(created.commandID))
        #expect(record.reason == "ledger_lost" && record.ackOp == "readback" && (record.state == .declined || record.state == .settled), "\(record)")
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
        #expect(readbacks.map { $0["result"] as? String } == ["unknown"])
    }

    // MARK: 7. run 시작은 한 트랜잭션

    @Test func beginRunWritesTheTaskAndTheCommandTogetherOrNotAtAll() async throws {
        let ledger = try BridgeLedger(directory: TempDirectory().url)
        try await ledger.saveTask(BridgeTest.task())
        try await ledger.saveCommand(BridgeTest.command(state: .leased))
        await ledger.debugFailWrite(containing: "INTO commands")
        await #expect(throws: BridgeLedgerError.self) {
            try await ledger.beginRun(
                taskID: BridgeTest.task().agentTaskID, task: { $0.alive = true; $0.lastState = "dispatched" },
                commandID: BridgeTest.command().commandID, command: { $0.state = .startIntent }
            )
        }
        #expect(try await ledger.task(BridgeTest.task().agentTaskID)?.alive == false, "명령 쓰기가 실패하면 task도 되돌린다")
        try await ledger.beginRun(
            taskID: BridgeTest.task().agentTaskID, task: { $0.alive = true }, commandID: BridgeTest.command().commandID, command: { $0.state = .startIntent }
        )
        #expect(try await ledger.task(BridgeTest.task().agentTaskID)?.alive == true)
        #expect(try await ledger.command(BridgeTest.command().commandID)?.state == .startIntent)
        await ledger.close()
    }

    @Test func aFailedStartIntentWriteLeavesNoHalfRunAndTheReplayStartsExactlyOnce() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        // lease_requested(1) · leased(2)를 지나 start_intent의 명령 쓰기(3번째)에서 실패한다
        await h.ledger.debugFailWrite(containing: "INTO commands", after: 2)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.isEmpty, "start_intent를 못 적었으면 띄우지 않는다")
        let task = try #require(await h.task(created.taskID))
        #expect(!task.alive && task.currentCommandID == nil, "task만 살아 있는 반쪽 상태 0: \(task)")
        #expect(await h.command(created.commandID)?.state == .leased)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(await h.command(created.commandID)?.state.hasStartIntent == true)
    }

    // MARK: 9. 살아남은 변이를 잡는 값 시험

    @Test func aCancelWhoseResultTheServerDoesNotKnowStillStopsTheLiveRunThenReportsTaskUnknown() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID))
        h.server.markLeasedUnknown(cancel.commandID) // lease가 만료돼 결과 확인 목록(readbacks)에 나온다
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.interrupts.count == 1, "결과 확인 대신 중단을 다시 실행한다 (M3)")
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == cancel.commandID }
        #expect(acks.map { "\($0["op"] ?? "")/\($0["result"] ?? "")" } == ["complete/task_unknown"], "\(acks)")
    }

    @Test func aProcessThatCannotBeEndedIsEndedFirstAndNeverAnsweredNotReceived() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        _ = h.agent.abandon()
        await h.runtime.abandonForTest()
        h.agent.setLiveness(.alive)
        h.agent.setTerminateResult(.alive) // 신호를 보내도 끝나지 않는다
        try await h.restart()
        await h.runtime.tick() // recover가 한 번 시도
        let attemptsBefore = h.agent.terminatedOrphans.count
        h.server.markLeasedUnknown(created.commandID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" && $0["command_id"] as? String == created.commandID }
        #expect(readbacks.isEmpty, "살아 있는 고아는 끝낸 뒤에만 답한다: \(readbacks) (M4)")
        #expect(h.agent.terminatedOrphans.count > attemptsBefore, "답하기 전에 다시 끝내 본다")
    }

    @Test func anOrphanFoundAlreadyEndedAfterAcceptanceIsReportedFailedNotCancelled() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        await h.settle { h.server.taskState(created.taskID) == "running" }
        _ = h.agent.abandon() // 대본은 멈췄고 가짜 run은 끝난 것으로 보인다 (끝 사건은 못 봤다)
        await h.runtime.abandonForTest()
        try await h.restart()
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "failed" }
        #expect(h.server.taskState(created.taskID) == "failed", "우리가 멈춘 것이 아니다: failed(agent_error) (M11)")
        #expect(h.agent.terminatedOrphans.isEmpty, "이미 끝난 것을 다시 끝내지 않는다")
    }

    @Test func aCancelMarksItsIntentInTheLedgerBeforeTheProcessIsSignalled() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        let seen = Locked<String?>(nil)
        h.agent.onInterrupt { [h] ref in seen.set((try? await h.ledger.task(ref.taskID))?.cancelState) }
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        _ = h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(seen.get() == "requested", "신호 앞에 중단 의도를 원장에 적는다 (M7): \(String(describing: seen.get()))")
    }

    @Test func shuttingDownMarksTheCancelIntentBeforeSignallingToo() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        let seen = Locked<String?>(nil)
        h.agent.onInterrupt { [h] ref in seen.set((try? await h.ledger.task(ref.taskID))?.cancelState) }
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        await h.runtime.shutdown(interrupt: true)
        #expect(seen.get() == "requested", "\(String(describing: seen.get()))")
    }

    @Test func aRateLimitedAckStaysQueuedAndGoesOutAfterRetryAfter() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let ack = try ackBody(h)
        try await h.ledger.enqueueAck(commandID: ack.command, op: "decline", result: nil, bodyJSON: ack.body)
        h.server.failNext("ack", .init(status: 429, headers: ["Retry-After": "30"]))
        await h.runtime.flushAcks()
        #expect(try await h.ledger.allAcks().count == 1, "429는 ack를 지우지 않는다 (M6)")
        #expect(h.server.requests("ack").count == 1)
        h.clock.jump(by: 31)
        await h.runtime.flushAcks()
        #expect(h.server.requests("ack").count == 2, "Retry-After 뒤에 같은 ack가 다시 나간다")
    }

    @Test func anAckStatusThisAppDoesNotKnowIsNeverTreatedAsFinal() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let ack = try ackBody(h)
        try await h.ledger.enqueueAck(commandID: ack.command, op: "decline", result: nil, bodyJSON: ack.body)
        h.server.failNext("ack", .init(status: 200, count: 1, bodyJSON: "{\"status\":\"from_the_future\"}"))
        await h.runtime.flushAcks()
        let rows = try await h.ledger.allAcks()
        #expect(rows.count == 1 && rows[0].attempts == 1, "모르는 상태는 final로 보지 않는다: 남기고 물러선다 (M14)")
    }

    @Test func aPolicyChangedStaleLeaseIsRetriedOnceThenRuns() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        h.server.staleOnNextLease(created.commandID, reason: "policy_changed")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 }, "policy_changed는 한 번 다시 lease한다 (M12)")
        #expect(h.server.commandLeaseCount(created.commandID) == 2)
    }

    @Test func aStaleLeaseOfAnyOtherReasonIsRecordedAndNeverRetried() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        h.server.staleOnNextLease(created.commandID, reason: "run_closed")
        await h.runtime.tick()
        #expect(await h.command(created.commandID)?.state == .stale)
        #expect(h.agent.startedTurns.isEmpty)
        #expect(h.server.commandLeaseCount(created.commandID) == 1)
    }

    @Test func heartbeatSaysAliveOnlyForTheProcessesThatAreRunning() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        let waitingSession = "5e551011-0000-4000-8000-0000000000a1"
        h.agent.setScript { turn in
            turn.sessionID == waitingSession
                ? FakeAgentProcess.Script([.sessionBound(external: "fake-session-2", workspace: "workspace-fake"), .accepted, .question(question), .end(AgentExit(code: 0))])
                : .staysRunning()
        }
        await h.registerFirst()
        let running = h.message("running")
        let waiting = h.message("waiting", session: waitingSession, task: "7a5c0001-0000-4000-8000-0000000000a1")
        await h.runtime.tick()
        await h.settle { let t = try? await h.ledger.task(waiting.taskID); return t?.openRequestID == "req-1" && t?.alive == false }
        #expect(await h.eventually { (await h.task(running.taskID))?.alive == true })
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let tasks = (h.server.requests("heartbeat").last?.json["tasks"] as? [[String: Any]]) ?? []
        let alive = Dictionary(uniqueKeysWithValues: tasks.compactMap { entry -> (String, Bool)? in
            guard let id = entry["task_id"] as? String, let flag = entry["process_alive"] as? Bool else { return nil }
            return (id, flag)
        })
        #expect(alive[running.taskID] == true, "돌고 있는 프로세스: \(tasks)")
        #expect(alive[waiting.taskID] == false, "질문을 내고 끝난 프로세스는 살아 있다고 하지 않는다 (M10): \(tasks)")
    }

    @Test func theFakeServerCountsPreparedCallingAndUnknownOutcomeAsPendingLikeTheRealOne() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        #expect(h.server.pendingCommandCount(bridgeID: h.bridgeID) == 0)
        let created = h.message()
        #expect(h.server.pendingCommandCount(bridgeID: h.bridgeID) == 1, "prepared")
        await h.runtime.tick()
        #expect(h.server.commandStep(created.commandID) == "calling")
        #expect(h.server.pendingCommandCount(bridgeID: h.bridgeID) == 1, "calling도 센다")
        h.server.setCommandStep(created.commandID, "unknown_outcome")
        #expect(h.server.pendingCommandCount(bridgeID: h.bridgeID) == 1, "unknown_outcome도 센다")
        h.server.setCommandStep(created.commandID, "called")
        #expect(h.server.pendingCommandCount(bridgeID: h.bridgeID) == 0)
    }

    // MARK: 8. 나가는 값 정리기

    private func limits() throws -> [String: Int] {
        let url = try #require(Bundle.module.url(forResource: "sanitizer-limits", withExtension: "json", subdirectory: "bridge-v1"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Int])
    }

    @Test func theSanitizerLimitsAreTheServerZodLimitsFromTheSharedFixture() throws {
        let limits = try limits()
        #expect(OutgoingValues.identityMaxChars == limits["identity_max_chars"])
        #expect(OutgoingValues.workspaceRefMaxChars == limits["workspace_ref_max_chars"])
        #expect(OutgoingValues.adapterVersionMaxChars == limits["adapter_version_max_chars"])
        #expect(OutgoingValues.artifactPathMaxChars == limits["artifact_path_max_chars"])
        #expect(OutgoingValues.artifactSummaryMaxChars == limits["artifact_summary_max_chars"])
        #expect(OutgoingValues.artifactPayloadMaxBytes == limits["artifact_payload_max_bytes"])
        #expect(Outbox.maxTextBytes == limits["text_max_bytes"])
    }

    @Test func anIdentityIsOneToTwoHundredCharactersWithoutNUL() {
        #expect(OutgoingValues.identity("turn-1") == "turn-1")
        #expect(OutgoingValues.identity("") == nil, "빈 값")
        #expect(OutgoingValues.identity(nil) == nil)
        #expect(OutgoingValues.identity(String(repeating: "e", count: 200)) != nil)
        #expect(OutgoingValues.identity(String(repeating: "e", count: 201)) == nil, "201자는 자르지 않고 거절")
        #expect(OutgoingValues.identity("a\u{0}b") == nil, "NUL")
        #expect(OutgoingValues.identity(String(repeating: "가", count: 200)) != nil, "글자 수는 스칼라 기준")
    }

    @Test func aWorkspaceRefIsNonEmptyAndAtMostFiveHundredCharactersAndNeverCut() {
        #expect(OutgoingValues.workspaceRef(nil) == .absent)
        #expect(OutgoingValues.workspaceRef("") == .absent, "빈 값은 보내지 않는다")
        #expect(OutgoingValues.workspaceRef("/Users/me/work") == .value("/Users/me/work"))
        #expect(OutgoingValues.workspaceRef(String(repeating: "w", count: 500)) == .value(String(repeating: "w", count: 500)))
        #expect(OutgoingValues.workspaceRef(String(repeating: "w", count: 501)) == .refused, "500자 초과는 자르지 않고 거절")
        #expect(OutgoingValues.workspaceRef("a\u{0}b") == .refused)
    }

    @Test func anAdapterVersionIsCutAtFiftyCharacters() {
        #expect(OutgoingValues.adapterVersion(nil) == nil)
        #expect(OutgoingValues.adapterVersion("2.1.241") == "2.1.241")
        #expect(OutgoingValues.adapterVersion(String(repeating: "9", count: 80)) == String(repeating: "9", count: 50))
        #expect(OutgoingValues.adapterVersion("1\u{0}2") == "12")
    }

    @Test func anArtifactIsCutToFourThousandNinetySixPayloadBytesAndNulIsRemoved() {
        let long = String(repeating: "가", count: 2000) // 6,000바이트
        let cut = OutgoingValues.artifact(path: "out/report.md", hash: "sha256:abc", summary: long)
        #expect(cut != nil)
        if let cut {
            #expect(OutgoingValues.artifactPayloadBytes(path: cut.path, hash: cut.hash, summary: cut.summary) <= 4096)
            #expect(cut.path == "out/report.md" && cut.hash == "sha256:abc", "먼저 요약을 줄인다")
            #expect(!cut.summary.isEmpty && cut.summary.hasPrefix("가"))
        }
        let nul = OutgoingValues.artifact(path: "a\u{0}b", hash: "h\u{0}", summary: "s\u{0}")
        #expect(nul?.path == "ab" && nul?.hash == "h" && nul?.summary == "s", "NUL을 제거한다")
        #expect(OutgoingValues.artifact(path: "", hash: "h", summary: "s") == nil, "path가 비면 거절")
        #expect(OutgoingValues.artifact(path: "p", hash: "", summary: "s") == nil, "hash가 비면 거절")
        let pathHeavy = OutgoingValues.artifact(path: String(repeating: "가", count: 1000), hash: String(repeating: "h", count: 200), summary: long)
        #expect(pathHeavy.map { OutgoingValues.artifactPayloadBytes(path: $0.path, hash: $0.hash, summary: $0.summary) <= 4096 } == true, "요약을 비워도 안 들어가면 path도 줄인다")
    }

    @Test func questionTextsLoseTheirNulBytes() {
        let question = AgentQuestion(
            providerRequestID: "r1", kind: .input, structured: true, text: "t",
            items: [AgentQuestionItem(id: "i\u{0}d", header: "h\u{0}", text: "te\u{0}xt", options: [AgentQuestionOption(label: "la\u{0}bel", description: "de\u{0}sc")])]
        )
        guard case .fits(let fitted, _) = Outbox.fit(question: question, taskID: "t", observedAt: BridgeTest.t0) else {
            Issue.record("must fit")
            return
        }
        let json = String(decoding: (try? TaskforceJSON.encoder().encode(fitted)) ?? Data(), as: UTF8.self)
        #expect(!json.contains("\\u0000"), "\(json)")
        #expect(fitted.questions[0].text == "text" && fitted.questions[0].options[0].label == "label")
    }

    @Test func runtimeSendsOnlyZodValidValuesForSessionBoundArtifactsAndExternalIds() async throws {
        let h = try BridgeHarness()
        let long = String(repeating: "가", count: 2000)
        h.agent.setScript(FakeAgentProcess.Script([
            .sessionBound(external: String(repeating: "x", count: 201), workspace: "workspace-fake"), // 거절: 201자
            .sessionBound(external: "fake-session-1", workspace: String(repeating: "w", count: 501)), // 거절: workspace 501자
            .sessionBound(external: "fake-session-1", workspace: ""), // workspace는 보내지 않는다
            .accepted,
            .artifact(path: "out/a.md", hash: "sha256:1", summary: long),
            .artifact(path: "", hash: "sha256:2", summary: "empty path"),
            .turnCompleted, .end(AgentExit(code: 0)),
        ]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        let events = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        let bound = events.filter { $0["type"] as? String == "session_bound" }
        #expect(bound.count == 1, "거절된 session_bound는 보내지 않는다: \(bound)")
        #expect((bound.first?["payload"] as? [String: Any])?["workspace_ref"] == nil, "빈 workspace_ref는 키를 뺀다")
        let artifacts = events.filter { $0["type"] as? String == "artifact" }
        #expect(artifacts.count == 1, "path가 빈 산출물은 보내지 않는다")
        let payload = artifacts.first?["payload"] as? [String: String]
        #expect(payload.map { OutgoingValues.artifactPayloadBytes(path: $0["path"] ?? "", hash: $0["hash"] ?? "", summary: $0["summary"] ?? "") <= 4096 } == true)
    }

    @Test func anExternalTaskIDThatIsNotOneToTwoHundredCharactersIsNeverSent() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        h.agent.setExternalTaskID(String(repeating: "t", count: 201))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        await h.settle { h.server.taskState(created.taskID) == "running" }
        #expect(await h.task(created.taskID)?.externalTaskID == nil)
        let events = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        #expect(events.allSatisfy { $0["external_task_id"] == nil }, "서버가 final로 거절할 값을 보내지 않는다")
    }

    @Test func aProbeReportCutsTheVersionAndConnectNeedsAnAdapterWithAReport() async throws {
        let h = try BridgeHarness()
        h.agent.setReport { $0.version = String(repeating: "9", count: 80) }
        await h.registerFirst()
        let register = try #require(h.server.requests("register").first?.json["adapters"] as? [[String: Any]])
        #expect((register.first?["version"] as? String)?.count == 50, "adapter version은 50자까지")
        let before = h.server.requests("register").count
        #expect(await h.runtime.connect(adapters: ["agent:codex"]) == false, "probe 보고가 없는 adapter는 connect하지 않는다")
        #expect(h.server.requests("register").count == before)
        #expect(await h.runtime.connect(adapters: ["agent:claude-code"]))
        let connect = h.server.requests("register").last?.json["connect"] as? [String]
        #expect(connect == ["agent:claude-code"])
    }
}
#endif
