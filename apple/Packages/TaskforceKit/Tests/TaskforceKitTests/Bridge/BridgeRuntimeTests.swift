#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 런타임 · 가짜 서버 · 가짜 agent (OA D2b 계약 4.1 K6): 2.6 원장 표 · lease 응답 표의 칸마다 하나, writer 하나, cancel 먼저, `close_before` 먼저,
/// answer 전달 · `request_closed`, 모르는 kind decline, adapter 없음 · 버전 밖 · 로그인 아님 → 정확한 `failed` 이유, payload 모름 → `readback not_received`
struct BridgeRuntimeTests {
    // MARK: 정상 왕복

    @Test func theFirstTickRegistersHeartbeatsBeforeAnythingElseThenLists() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        #expect(h.routes() == ["register", "heartbeat", "commands"])
        #expect(try await h.ledger.meta().bridgeID == h.bridgeID && !h.bridgeID.isEmpty)
        let register = try #require(h.server.requests("register").first)
        #expect(register.json["device_id"] as? String == (try h.credentials.deviceID(partition: h.partition.id)))
        #expect(register.secret == nil, "등록 요청에는 장치 secret이 없다")
        let heartbeat = try #require(h.server.requests("heartbeat").first)
        #expect(heartbeat.json["app_version"] as? String == "0.2.0-test")
        #expect((heartbeat.json["adapters"] as? [[String: Any]])?.count == 1)
        #expect(heartbeat.secret == (try h.credentials.secret(partition: h.partition.id)))
    }

    @Test func aMessageIsLeasedOnceStartedOnceAndItsEventsReachTheServerInOrder() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message("Please summarize the open tasks.")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let started = try #require(h.agent.startedTurns.first)
        #expect(started.text == "Please summarize the open tasks.")
        #expect(started.taskID == created.taskID && started.marker == created.marker && started.sessionID == created.sessionID)
        #expect(started.workspaceRef == "workspace-test", "새 세션의 작업 폴더는 resolver가 정한다")
        #expect(!started.resume && started.access == .write && started.policyMode == .manual)
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(h.server.commandLeaseCount(created.commandID) == 1)
        #expect(h.server.taskState(created.taskID) == "idle")
        let applied = h.server.eventResults.map(\.type)
        #expect(applied == ["session_bound", "accepted", "progress", "message", "turn_completed"])
        #expect(h.server.eventResults.allSatisfy { $0.status == "applied" })
        #expect(try await h.ledger.outboxRows().isEmpty, "응답의 accepted_event_ids만 outbox를 지운다")
        let session = try #require(h.server.sessionState(created.sessionID))
        #expect(session.externalSessionID == "fake-session-1" && session.workspaceRef == "workspace-fake")
    }

    @Test func eventIDsAreTaskScopedSeqIDsAndSessionBoundUsesTheSessionScopedID() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        let rows = try await h.ledger.outboxRows()
        // 서버 요청에서 event id를 읽는다 (outbox는 이미 비었다)
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        #expect(sent.compactMap { $0["event_id"] as? String } == ["\(created.sessionID):s1", "\(created.taskID):1", "\(created.taskID):2", "\(created.taskID):3", "\(created.taskID):4"])
        #expect(sent.compactMap { $0["seq"] as? Int } == [1, 2, 3, 4])
        #expect(sent.allSatisfy { $0["agent_task_id"] as? String == created.taskID && $0["turn_seq"] as? Int == 1 })
        #expect(rows.isEmpty)
    }

    // MARK: write-ahead (원칙 3)

    @Test func leaseRequestedIsCommittedBeforeTheLeaseIsSent() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        let seen = Locked<BridgeCommandState?>(nil)
        h.server.onRequest = { [h] record in
            guard record.route == "ack", record.json["op"] as? String == "lease" else { return }
            let state = await h.command(created.commandID)?.state
            seen.set(state)
        }
        await h.runtime.tick()
        #expect(seen.get() == .leaseRequested)
    }

    @Test func startIntentAndTheProcessMarkerAreCommittedBeforeTheAgentStarts() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        let observed = Locked<(BridgeCommandState, String?, Bool, String?)?>(nil)
        h.agent.onStart { [h] turn in
            let command = await h.command(created.commandID)
            let task = await h.task(turn.taskID)
            observed.set((command?.state ?? .seen, command?.marker, task?.alive ?? false, task?.processMarker))
        }
        await h.runtime.tick()
        #expect(await h.eventually { observed.get() != nil })
        let value = try #require(observed.get())
        #expect(value.0 == .startIntent && value.1 == created.marker && value.2 && value.3 == created.marker)
    }

    @Test func startedWithTheProcessIdentityIsCommittedAfterTheAgentStarts() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let task = try #require(await h.task(created.taskID))
        #expect(task.alive && task.processMarker == created.marker && task.processStartedAt != nil)
        #expect(task.externalTaskID == "turn-1")
        let command = try #require(await h.command(created.commandID))
        #expect(command.spawnAt != nil && command.signalAt != nil)
    }

    // MARK: 2.6 원장 표 · lease 응답 표

    @Test func anUnknownCommandKindIsDeclinedWithoutALeaseOrAnExecution() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let id = h.server.enqueueRaw(bridgeID: h.bridgeID, kind: "quantum", sessionID: BridgeHarness.sessionID)
        await h.runtime.tick()
        let acks = h.server.requests("ack").map { $0.json["op"] as? String }
        #expect(acks == ["decline"])
        #expect(h.server.commandLeaseCount(id) == 0)
        #expect(h.agent.startedTurns.isEmpty)
        #expect(await h.eventually { (await h.command(id))?.state == .declined })
        #expect(h.server.requests("ack").first?.json["reason"] as? String == "unsupported_kind")
    }

    @Test func aWithdrawnLeaseIsRecordedAndNeverExecuted() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.gateOpen = false
        let created = h.message()
        await h.runtime.tick()
        let command = try #require(await h.command(created.commandID))
        #expect(command.state == .withdrawn && command.reason == "write_gate_closed")
        #expect(h.agent.startedTurns.isEmpty)
    }

    @Test func staleHeartbeatFirstSendsAHeartbeatThenLeasesAgainOnce() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        h.server.sweepSessionUnreachable(BridgeHarness.sessionID)
        h.clock.jump(by: 6) // 서버는 5초 안의 두 번째 heartbeat를 지난 결과로 돌려준다 (throttled)
        await h.runtime.tick()
        // 요청 순서: 목록 → lease(stale/heartbeat_first) → heartbeat(세션을 되살림) → lease → 시작
        let sequence = h.server.requests.map { $0.route == "ack" ? "ack:\($0.json["op"] as? String ?? "")" : $0.route }
        let tail = Array(sequence.drop { $0 != "ack:lease" })
        #expect(Array(tail.prefix(3)) == ["ack:lease", "heartbeat", "ack:lease"])
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(h.server.commandLeaseCount(created.commandID) == 2)
    }

    @Test func aStaleLeaseThatIsNotAHintIsRecordedAsStaleWithoutExecution() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        // 목록에 나온 뒤 lease 직전에 단계가 바뀌었다 (Stop · Done 등)
        h.server.onRequest = { [h] record in
            if record.route == "ack", record.json["op"] as? String == "lease" { h.server.setCommandStep(created.commandID, "failed") }
        }
        await h.runtime.tick()
        let command = try #require(await h.command(created.commandID))
        #expect(command.state == .stale && command.reason == "not_prepared")
        #expect(h.agent.startedTurns.isEmpty)
    }

    @Test func aMissingCommandOnLeaseBecomesGone() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        h.server.failNext("ack", .init(status: 404))
        await h.runtime.tick()
        #expect(await h.command(created.commandID)?.state == .gone)
        #expect(h.agent.startedTurns.isEmpty)
    }

    @Test func aTransportFailureOnLeaseLeavesLeaseRequestedAndTheNextListShowsItLeasedByMe() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        // 서버는 lease했지만 응답이 유실됐다 (ONE-TF-04 a)
        h.server.dropResponseOnce(route: "ack")
        await h.runtime.tick()
        #expect(await h.command(created.commandID)?.state == .leaseRequested)
        #expect(h.agent.startedTurns.isEmpty)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(h.server.commandLeaseCount(created.commandID) == 2)
        #expect(h.agent.startedTurns.count == 1, "replay로 받은 첫 실행은 한 번이다")
    }

    @Test func aReplayAfterStartIntentNeverStartsASecondProcess() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        // 같은 명령이 다시 leased_by_me로 목록에 나온다
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1)
        #expect(h.server.commandLeaseCount(created.commandID) == 1, "원장이 start_intent 이상이면 lease도 다시 하지 않는다")
    }

    @Test func theLeaseFlowItselfRefusesASecondStartWhenTheLedgerAlreadySaysStartIntent() async throws {
        // 방어 한 겹 더: 어떤 경로로든 lease 응답이 replay로 돌아와도 원장이 start_intent 이상이면 띄우지 않는다
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        var record = BridgeCommandRecord(
            commandID: created.commandID, kind: "message", agentSessionID: created.sessionID, agentTaskID: created.taskID, turnSeq: 1, cursor: 1, state: .startIntent, stateAt: h.clock.now
        )
        record.marker = created.marker
        try await h.ledger.saveCommand(record)
        let item = BridgeV1CommandListItem.fixture(id: created.commandID, session: created.sessionID, task: created.taskID, leasedByMe: false)
        let result = await h.runtime.leaseNew(item, existing: record, reason: .realtime, wakeAt: h.clock.now, listedAt: h.clock.now)
        #expect(result == .ignored)
        #expect(h.agent.startedTurns.isEmpty)
    }

    // MARK: kind별 실행

    @Test func theAdapterMustExistBeInstalledInRangeAndSignedInElseTheExactReasonGoesToTheServer() async throws {
        let cases: [(String, (FakeAgentProcess) -> Void, String)] = [
            ("not installed", { $0.setReport { $0.installed = false } }, "spawn_failed"),
            ("out of range", { $0.setVersionSupport { _ in false } }, "version_unsupported"),
            ("signed out", { $0.setReport { $0.signedIn = .no } }, "sign_in_needed"),
        ]
        for (name, configure, reason) in cases {
            let h = try BridgeHarness()
            configure(h.agent)
            await h.registerFirst()
            let created = h.message()
            await h.runtime.tick()
            await h.settle { h.server.taskState(created.taskID) == "failed" }
            #expect(h.agent.startedTurns.isEmpty, "\(name)")
            let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
            #expect(sent.count == 1 && sent[0]["type"] as? String == "failed", "\(name)")
            #expect((sent.first?["payload"] as? [String: Any])?["reason"] as? String == reason, "\(name)")
            #expect(h.server.taskState(created.taskID) == "failed", "\(name)")
        }
    }

    @Test func noAdapterForTheCommandFailsWithSpawnFailed() async throws {
        let h = try BridgeHarness(withAdapter: false)
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "failed" }
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        #expect((sent.first?["payload"] as? [String: Any])?["reason"] as? String == "spawn_failed")
        #expect(h.server.taskState(created.taskID) == "failed")
    }

    @Test func aNewSessionWithoutAWorkspaceFailsWithSpawnFailedAndTheAgentIsNotAsked() async throws {
        let h = try BridgeHarness(workspace: nil)
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "failed" }
        #expect(h.agent.startedTurns.isEmpty)
        let sent = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
        #expect((sent.first?["payload"] as? [String: Any])?["reason"] as? String == "spawn_failed")
    }

    /// 새 폴더를 정해 주지는 않지만 이 Mac이 고른 폴더 하나는 인정하는 resolver (재개한 세션의 폴더)
    private struct AuthorizesOnly: WorkspaceResolver {
        let refs: Set<String>

        func workspace(forSession sessionID: String, adapter: String) async -> String? { nil }

        func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { refs.contains(workspaceRef) }
    }

    @Test func aResumedSessionDoesNotNeedAWorkspaceFromTheResolver() async throws {
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = AuthorizesOnly(refs: ["workspace-a"]) // 폴더를 새로 정하지는 않고, 이 Mac이 고른 폴더만 인정한다
        try await h.restart(reopenLedger: false)
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: "claude-session-9", workspaceRef: "workspace-a")
        h.message()
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let started = try #require(h.agent.startedTurns.first)
        #expect(started.resume && started.externalSessionID == "claude-session-9" && started.workspaceRef == "workspace-a")
    }

    @Test func unknownAccessOrPolicyValuesAreNotStartedAndAreReportedNotReceivedWithAnEndedProcess() async throws {
        for (key, value) in [("access", "root"), ("policy_mode", "yolo")] {
            let h = try BridgeHarness()
            await h.registerFirst()
            let created = h.message(extra: [key: value])
            await h.runtime.tick()
            #expect(h.agent.startedTurns.isEmpty, "\(key)")
            let acks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
            #expect(acks.count == 1, "\(key)")
            #expect(acks.first?["result"] as? String == "not_received" && acks.first?["process_ended"] as? Bool == true, "\(key)")
            #expect(await h.eventually { (await h.command(created.commandID))?.state == .settled }, "\(key)")
            #expect(await h.command(created.commandID)?.reason == "unknown_payload", "\(key)")
        }
    }

    @Test func closeBeforeClosesTheOldRequestBeforeTheNextTurnStarts() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let seenClosed = Locked<Int>(-1)
        h.agent.onStart { [h] _ in seenClosed.set(h.agent.closedRequests.count) }
        h.message(closeBefore: "req-old")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(seenClosed.get() == 1)
        #expect(h.agent.closedRequests.first?.requestID == "req-old")
    }

    // MARK: writer 하나

    @Test func aSecondTurnInTheSameSessionWaitsUntilTheLiveOneEnds() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let first = h.message("first", task: "7a5c0001-0000-4000-8000-0000000000a1", turn: 1)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let second = h.message("second", task: "7a5c0001-0000-4000-8000-0000000000a2", turn: 2)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1)
        #expect(h.server.commandLeaseCount(second.commandID) == 0, "살아 있는 실행이 있는 세션은 lease도 하지 않는다")
        // 첫 실행이 끝나면 둘째가 간다
        h.agent.setScript(.normal())
        _ = await h.agent.interrupt(AgentTurnRef(taskID: first.taskID, sessionID: first.sessionID, identity: nil), scope: .turn)
        #expect(await h.eventually { (await h.task(first.taskID))?.alive == false })
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 2 })
        #expect(h.agent.startedTurns.last?.text == "second")
    }

    @Test func differentSessionsRunTogether() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        h.message("a", session: "5e551011-0000-4000-8000-0000000000b1")
        h.message("b", session: "5e551011-0000-4000-8000-0000000000b2")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 2 })
    }

    // MARK: cancel · answer

    @Test func cancelIsHandledBeforeAnswerAndMessage() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message("first", task: "7a5c0001-0000-4000-8000-0000000000c1")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let message = h.message("other session", session: "5e551011-0000-4000-8000-0000000000c2", task: "7a5c0001-0000-4000-8000-0000000000c2")
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: running.taskID))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let leases = h.server.requests("ack").filter { $0.json["op"] as? String == "lease" }.compactMap { $0.json["command_id"] as? String }
        #expect(leases.suffix(2) == [cancel.commandID, message.commandID])
    }

    @Test func aCancelInterruptsTheLiveTurnCompletesSentAndLaterReportsCancelled() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(running.commandID))?.state == .accepted })
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: running.taskID, scope: "turn_and_processes"))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { !h.agent.interrupts.isEmpty })
        #expect(h.agent.interrupts.first?.1 == .turnAndProcesses)
        let completes = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "complete" }
        #expect(completes.count == 1 && completes[0]["result"] as? String == "sent")
        await h.settle { h.server.taskState(running.taskID) == "cancelled" }
        #expect(h.server.taskState(running.taskID) == "cancelled")
        #expect(await h.eventually { (await h.command(cancel.commandID))?.state == .settled })
        #expect(h.server.eventResults.map(\.type).last == "cancelled")
    }

    @Test func aCancelForATaskThatHasNoLiveRunCompletesTaskUnknownAndNeverReadbacks() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let ran = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(ran.taskID) == "idle" }
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: ran.taskID))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == cancel.commandID }
        #expect(acks.map { $0["op"] as? String } == ["lease", "complete"])
        #expect(acks.last?["result"] as? String == "task_unknown")
        #expect(h.server.taskState(ran.taskID) == "cancelled")
    }

    @Test func aCancelForAnUnknownTaskCompletesTaskUnknown() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        // 이 Mac의 원장에는 이 작업의 기록이 없다 (격리 뒤 등)
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID))
        h.server.setCommandStep(created.commandID, "failed")
        await h.runtime.tick()
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == cancel.commandID }
        #expect(acks.map { $0["op"] as? String } == ["lease", "complete"])
        #expect(acks.last?["result"] as? String == "task_unknown")
    }

    @Test func anAbandonedRequestIsRecordedAsClosedAndTheAgentIsToldToDenyIt() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(running.commandID))?.state == .accepted })
        h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: running.taskID, abandoned: "req-abandoned")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.closedRequests.map(\.requestID) == ["req-abandoned"])
        #expect(try await h.ledger.task(running.taskID)?.closedRequestIDs == ["req-abandoned"])
    }

    @Test func aQuestionIsAnsweredAndTheTurnContinues() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(
            providerRequestID: "req-1", kind: .input, structured: true, text: "Which environment?",
            items: [AgentQuestionItem(id: "q1", header: "Environment", text: "Where?", options: [AgentQuestionOption(label: "staging", description: "s")])]
        )
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        #expect(h.server.taskState(created.taskID) == "awaiting_answer")
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answers: ["q1": "staging"]))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.deliveredAnswers.count == 1 })
        #expect(h.agent.deliveredAnswers.first?.value.answers == ["q1": .one("staging")])
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(h.server.taskState(created.taskID) == "idle")
        #expect(h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == answer.commandID }.map { $0["op"] as? String } == ["lease"])
    }

    @Test func anAnswerToARequestThatIsAlreadyClosedAcksRequestClosedAndDeliversNothing() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        // 이 요청은 취소 명령이 이미 닫았다
        try await h.ledger.updateTask(created.taskID) { $0.closedRequestIDs = ["req-1"] }
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "Alice", structured: false))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == answer.commandID }
        #expect(acks.map { $0["op"] as? String } == ["lease", "request_closed"])
        #expect(h.agent.deliveredAnswers.isEmpty)
    }

    @Test func anAdapterThatReportsTheRequestClosedAcksRequestClosed() async throws {
        let h = try BridgeHarness()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        h.agent.setScript(.asking(question))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { (try? await h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        try await h.agent.closeRequest(AgentRequestRef(taskID: created.taskID, sessionID: created.sessionID, requestID: "req-1", externalSessionID: nil, workspaceRef: nil))
        let answer = try #require(h.server.enqueueAnswer(bridgeID: h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "Alice", structured: false))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == answer.commandID }
        #expect(acks.map { $0["op"] as? String } == ["lease", "request_closed"])
    }
}

extension BridgeV1CommandListItem {
    /// 시험용 목록 항목 (실제 응답 JSON을 디코딩해 만든다)
    static func fixture(id: String, session: String, task: String, kind: String = "message", cursor: Int = 1, leasedByMe: Bool) -> BridgeV1CommandListItem {
        let json = """
        {"id":"\(id)","cursor":\(cursor),"kind":"\(kind)","agent_session_id":"\(session)","agent_task_id":"\(task)","turn_seq":1,"created_at":"2026-10-14T05:00:00Z","leased_by_me":\(leasedByMe)}
        """
        return try! JSONDecoder().decode(BridgeV1CommandListItem.self, from: Data(json.utf8))
    }
}

/// 시험에서 비동기 훅이 값을 남기는 작은 상자
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
#endif
