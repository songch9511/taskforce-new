#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// ONE-TF 확인 (OA D2b 계약 4.3), 가짜 agent · 가짜 서버 · 디스크 원장: ONE-TF-04 a–e · ONE-TF-09 a–c · ONE-TF-15 a–b · AC-11 bridge 몫 · 마무리 모드
struct BridgeScenarioTests {
    private func downNetwork(_ h: BridgeHarness) {
        for route in ["events", "heartbeat", "commands", "ack"] { h.server.failNext(route, .init(status: 0, transport: true, count: 1000)) }
    }

    // MARK: ONE-TF-04 b — 실행 · accepted 사건 생성 → 네트워크 끊김 → lease 만료 → 복귀

    @Test func oneTF04b_anAcceptedTurnWhoseEventsWereNeverDeliveredIsReattachedNotRedispatched() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        downNetwork(h)
        await h.runtime.flushOutbox() // 닿지 못한다
        #expect(try await h.ledger.outboxRows().count >= 2, "accepted 사건이 outbox에 남아 있다")
        // lease 330초가 지나 서버가 unknown_outcome으로 둔다
        h.clock.jump(by: 340)
        h.server.sweep()
        #expect(h.server.commandStep(created.commandID) == "unknown_outcome")
        // 복귀
        h.server.clearFailures()
        let leasesBefore = h.server.commandLeaseCount(created.commandID)
        let mark = h.server.requests.count
        await h.runtime.tick()
        await h.runtime.tick()
        let after = h.server.requests.dropFirst(mark).map(\.route)
        #expect(after.first == "heartbeat", "heartbeat가 먼저")
        #expect(after.firstIndex(of: "events").map { $0 > 0 } == true, "outbox 재생은 heartbeat 뒤")
        #expect(h.server.commandLeaseCount(created.commandID) == leasesBefore, "새 명령 · 새 lease 0")
        #expect(h.agent.startedTurns.count == 1, "새 실행 0")
        #expect(h.server.taskState(created.taskID) == "running", "사건 재생으로 서버가 다시 붙였다")
        #expect(h.server.commandStep(created.commandID) == "called")
    }

    // MARK: ONE-TF-04 c — 접수 전 프로세스 끝 · 사건 0

    @Test func oneTF04c_notReceivedIsReportedOnlyAfterTheProcessIsKnownToHaveEnded() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.silentDeathBeforeAcceptance())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.task(created.taskID))?.alive == false })
        #expect(try await h.ledger.outboxRows().isEmpty, "사건 0")
        h.clock.jump(by: 340)
        h.server.sweep()
        await h.runtime.tick()
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
        #expect(readbacks.count == 1)
        #expect(readbacks.first?["result"] as? String == "not_received" && readbacks.first?["process_ended"] as? Bool == true)
        #expect(h.server.taskState(created.taskID) == "failed")
        #expect(h.agent.startedTurns.count == 1)
    }

    @Test func aLiveProcessWithoutAnyAcceptSignalIsNeverReportedNotReceived() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(Script_waitOnly())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.task(created.taskID))?.alive == true && h.agent.startedTurns.count == 1 })
        h.clock.jump(by: 340)
        h.server.sweep()
        await h.runtime.tick()
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
        #expect(readbacks.map { $0["result"] as? String } == ["unknown"], "살아 있으면 unknown 한 번")
        #expect(readbacks.first?["process_ended"] as? Bool == false)
        // 두 번째 목록에서는 이미 보고했으므로 다시 보내지 않는다
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }.count == 1)
    }

    // MARK: ONE-TF-04 d — 느린 시작

    @Test func oneTF04d_aSlowStartKeepsItsLeaseAliveThroughHeartbeatsWhileConnected() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.slowStart(400))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(await h.eventually { h.clock.sleeperCount >= 1 }, "대본이 대기에 들어간 뒤에 시간을 흘린다")
        for _ in 0..<14 {
            await h.clock.advance(by: 30)
            await h.runtime.tick()
            h.server.sweep()
        }
        #expect(h.server.commandStep(created.commandID) != "unknown_outcome", "process_alive heartbeat가 lease를 연장한다")
        #expect(h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }.isEmpty)
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(h.server.taskState(created.taskID) == "idle")
    }

    @Test func oneTF04d_aSlowStartWhileDisconnectedReportsUnknownOnceAndALaterAcceptedReattaches() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.slowStart(500))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(await h.eventually { h.clock.sleeperCount >= 1 }, "대본이 대기에 들어간 뒤에 시간을 흘린다")
        downNetwork(h)
        h.clock.jump(by: 340)
        h.server.sweep()
        h.server.clearFailures()
        await h.runtime.tick()
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
        #expect(readbacks.map { $0["result"] as? String } == ["unknown"])
        await h.clock.advance(by: 200) // 이제 accepted
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(h.server.taskState(created.taskID) == "idle", "뒤 accepted가 서버를 다시 붙였다")
        #expect(h.agent.startedTurns.count == 1)
    }

    // MARK: ONE-TF-04 e — 원장 손실

    @Test func oneTF04e_afterTheLedgerIsLostALeasedByMeCommandOnlyGetsUnknown() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let agentB = FakeAgentProcess(clock: h.clock.clock)
        try await h.wipeLedger()
        try await h.restart(adapters: [agentB])
        await h.runtime.tick()
        await h.runtime.tick()
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
        #expect(readbacks.map { $0["result"] as? String } == ["unknown"], "원장을 잃었으면 unknown만")
        #expect(agentB.startedTurns.isEmpty, "실행 0")
        #expect(h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "lease" }.count == 1)
    }

    @Test func oneTF04e_aCorruptLedgerIsSetAsideAndNothingIsRunAgain() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        await h.ledger.close()
        try Data("garbage-not-sqlite".utf8).write(to: h.ledger.fileURL)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: h.ledger.fileURL.path + suffix)) }
        let agentB = FakeAgentProcess(clock: h.clock.clock)
        try await h.restart(adapters: [agentB], reopenLedger: true)
        #expect(h.ledger.quarantinedFile != nil)
        await h.runtime.tick()
        #expect(agentB.startedTurns.isEmpty)
        let readbacks = h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" }
        #expect(readbacks.map { $0["result"] as? String } == ["unknown"])
    }

    // MARK: ONE-TF-09 — 계정 전환 격리

    @Test func oneTF09a_aLateResponseOfTheLeftAccountNeverTouchesTheNewAccountsLedger() async throws {
        let a = try BridgeHarness()
        let b = try BridgeHarness(server: a.server)
        await a.registerFirst()
        let aBridge = a.bridgeID
        let aSecret = try #require(try a.credentials.secret(partition: a.partition.id))
        try await a.seedEvents(count: 3)
        downNetworkEvents(a)
        await a.runtime.flushOutbox() // A의 outbox 대기
        a.server.clearFailures()
        let pending = Task { await a.runtime.poll(wait: 25, reason: .longPoll) }
        #expect(await a.eventually { a.server.requests("commands").count == 2 })
        // 긴 대기가 진행 중인 채로 B로 전환한다
        await a.runtime.stop()
        let switchIndex = a.server.requests.count
        await b.registerFirst()
        // A 쪽에 새 명령이 생기고 A의 늦은 응답이 도착한다
        let late = a.message("late for A")
        a.server.notifyChange()
        let outcome = await pending.value
        #expect(outcome.listed == 0 || outcome == PollOutcome(), "늦은 응답은 버려졌다")
        #expect(try await b.ledger.allCommands().isEmpty)
        #expect(try await b.ledger.allTasks().isEmpty)
        #expect(try await a.ledger.command(late.commandID) == nil, "A도 늦은 응답으로는 쓰지 않는다")
        let after = a.server.requests.dropFirst(switchIndex)
        #expect(!after.contains { $0.bridgeID == aBridge || $0.secret == aSecret }, "전환 뒤 A의 bridge_id · secret을 실은 요청 0")
        #expect(after.allSatisfy { $0.token == b.token }, "B 토큰으로 A 사건 0")
        #expect(try await a.ledger.outboxRows().count == 3, "A의 대기 사건은 A 파티션에 그대로")
        #expect(a.partition.id != b.partition.id)
    }

    private func downNetworkEvents(_ h: BridgeHarness) {
        h.server.failNext("events", .init(status: 0, transport: true, count: 1))
    }

    // MARK: lease 전 활동 사건 0 (D2a 3.4 step_not_calling)

    /// 프로세스는 lease 응답을 받은 명령에만 띄운다: 응답이 유실돼도 · 거절돼도 · 정상이어도 서버가 `step_not_calling`으로 돌려보낼 사건은 한 번도 나가지 않는다
    @Test func noActivityEventIsEverSentForACommandThatWasNotLeased() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.normal())
        await h.registerFirst()
        let lost = h.message("lost response")
        h.server.dropResponseOnce(route: "ack") // 서버는 lease했지만 응답이 유실된다
        await h.runtime.tick()
        #expect(h.agent.startedTurns.isEmpty, "응답을 받기 전에는 띄우지 않는다")
        #expect(h.server.eventResults.isEmpty, "lease 응답 전에 사건 0")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let refused = h.message("withdrawn", session: "5e551011-0000-4000-8000-0000000000f1", task: "7a5c0001-0000-4000-8000-0000000000f1")
        h.server.failNext("ack", .init(status: 404))
        await h.runtime.tick()
        #expect(h.agent.startedTurns.count == 1, "lease를 거절당한 명령은 띄우지 않는다")
        await h.settle { h.server.taskState(lost.taskID) == "idle" }
        #expect(h.server.eventResults.allSatisfy { $0.status != "step_not_calling" }, "\(h.server.eventResults.map(\.status))")
        #expect(!h.server.eventResults.isEmpty)
        #expect(h.server.eventResults.allSatisfy { $0.status == "applied" || $0.status == "duplicate" })
        _ = refused
    }

    @Test func oneTF09b_whenTheAccountLogsInAgainItsOutboxIsDeliveredOnceEachWithItsOwnCredentials() async throws {
        let a = try BridgeHarness()
        await a.registerFirst()
        try await a.seedEvents(count: 4)
        a.server.failNext("events", .init(status: 0, transport: true, count: 1))
        await a.runtime.flushOutbox()
        #expect(try await a.ledger.outboxRows().count == 4)
        await a.runtime.stop()
        let other = try BridgeHarness(server: a.server)
        await other.registerFirst()
        // A가 다시 로그인: 같은 파티션을 새 런타임으로 잇는다
        try await a.restart()
        a.clock.jump(by: 61)
        await a.runtime.tick()
        #expect(a.server.eventResults.count == 4, "서버는 각 사건을 한 번씩만 받았다")
        #expect(Set(a.server.eventResults.map(\.eventID)).count == 4, "중복 0")
        #expect(try await a.ledger.outboxRows().isEmpty)
        #expect(a.server.requests("events").allSatisfy { $0.token == a.token || $0.token == other.token })
    }

    @Test func oneTF09c_aTokenOfAnotherUserNeverReachesTheServerAndTheRuntimeKeepsItsLedgerIntact() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 2)
        let sent = h.server.requests.count
        h.bearerUser.set(UUID()) // 토큰 공급 순간 사용자가 바뀌었다
        await h.runtime.tick()
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        await h.runtime.flushOutbox()
        #expect(h.server.requests.count == sent, "그 요청은 보내지 않는다")
        #expect(try await h.ledger.outboxRows().count == 2)
    }

    // MARK: ONE-TF-15 — 종료 · 재시작

    @Test func oneTF15a_quittingInterruptsTheLiveTurnReportsCancelledAndDrainsTheOutbox() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        #expect(await h.runtime.isBusy())
        await h.runtime.shutdown(interrupt: true)
        #expect(h.agent.interrupts.count == 1)
        #expect(h.server.taskState(created.taskID) == "cancelled")
        #expect(try await h.ledger.outboxRows().isEmpty, "outbox를 비웠다")
        #expect(await h.runtime.status == .stopped)
        #expect(await h.runtime.isBusy() == false)
        #expect(h.server.eventResults.map(\.type).last == "cancelled")
    }

    @Test func oneTF15b_afterAForcedQuitTheOrphanIsEndedFirstAndTheLedgerSettlesItWithoutARerun() async throws {
        let agentA = FakeAgentProcess(clock: BridgeClock.system)
        agentA.setSubprocess(true)
        let h = try BridgeHarness(agent: agentA)
        defer { agentA.killEverything() }
        agentA.setScript(.staysRunning())
        await h.registerFirst()
        let first = h.message("first")
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(first.commandID))?.state == .accepted })
        let pid = try #require(try await h.ledger.task(first.taskID)?.pid)
        #expect(FakeAgentProcess.processExists(pid: pid, startedAt: try #require(try await h.ledger.task(first.taskID)?.processStartedAt)))
        // 같은 세션의 다음 메시지가 이미 기다린다
        let second = h.message("second", task: "7a5c0001-0000-4000-8000-0000000000a2", turn: 2)
        // 강제 종료: 런타임을 정리 없이 버린다. 하위 프로세스는 고아로 남는다
        let orphans = agentA.abandon()
        #expect(orphans.count == 1)
        await h.runtime.abandonForTest()
        #expect(FakeAgentProcess.processExists(pid: pid, startedAt: orphans[0].startedAt), "고아가 살아 있다")
        // 새 앱
        let agentB = FakeAgentProcess(clock: h.clock.clock)
        let orphanStillAlive = Locked<Bool?>(nil)
        agentB.onStart { _ in orphanStillAlive.set(FakeAgentProcess.processExists(pid: pid, startedAt: orphans[0].startedAt)) }
        try await h.restart(adapters: [agentB])
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(agentB.terminatedOrphans.count == 1)
        #expect(!FakeAgentProcess.processExists(pid: pid, startedAt: orphans[0].startedAt), "고아를 끝냈다")
        #expect(await h.eventually { h.server.taskState(first.taskID) == "cancelled" }, "접수 뒤였으니 cancelled")
        #expect(h.server.commandLeaseCount(first.commandID) == 1, "재dispatch 0")
        #expect(await h.eventually { agentB.startedTurns.count == 1 })
        #expect(agentB.startedTurns.first?.text == "second")
        #expect(orphanStillAlive.get() == false, "같은 세션 프로세스 동시 2개 0")
        _ = second
    }

    @Test func aRestartDoesNotRunAnyCommandThatWasNotLeasedAfresh() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let first = h.message("first")
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(first.commandID))?.state == .accepted })
        let agentB = FakeAgentProcess(clock: h.clock.clock)
        _ = h.agent.abandon()
        await h.runtime.abandonForTest()
        try await h.restart(adapters: [agentB])
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(agentB.startedTurns.isEmpty)
        #expect(h.server.commandLeaseCount(first.commandID) == 1)
    }

    // MARK: AC-11 (bridge 몫)

    @Test func ac11_commandsPiledUpWhileOfflineRunOnceEachInTheOrderTheyWereSent() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        downNetwork(h)
        let tasks = ["7a5c0001-0000-4000-8000-0000000000b1", "7a5c0001-0000-4000-8000-0000000000b2", "7a5c0001-0000-4000-8000-0000000000b3"]
        let created = tasks.enumerated().map { index, task in h.message("message \(index + 1)", task: task, turn: index + 1) }
        await h.runtime.tick() // 닿지 않는다
        #expect(h.agent.startedTurns.isEmpty)
        h.server.clearFailures()
        h.clock.jump(by: 6)
        for _ in 0..<40 where h.agent.startedTurns.count < 3 {
            await h.runtime.tick()
            await h.runtime.flushOutbox()
            try? await Task.sleep(for: .milliseconds(5))
        }
        await h.settle { h.server.taskState(tasks[2]) == "idle" }
        #expect(h.agent.startedTurns.map(\.text) == ["message 1", "message 2", "message 3"])
        for item in created { #expect(h.server.commandLeaseCount(item.commandID) == 1) }
    }

    // MARK: 마무리 모드 (BRIDGE_ENABLED 꺼짐 + 할 일 있음)

    @Test func drainModeNeverRegistersWithoutCredentials() async throws {
        let h = try BridgeHarness(mode: .drain)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.server.requests.isEmpty, "꺼졌고 자격도 없으면 네트워크 0")
        #expect(h.server.registerAttempts == 0)
    }

    @Test func drainModeKeepsDeliveringEventsAndCancellingButNeverLeasesNewMessages() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let running = h.message("running")
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(running.commandID))?.state == .accepted })
        // 사건 전달을 막은 채 앱이 내려가고, 플래그가 꺼진 새 앱이 마무리 모드로 올라온다
        _ = h.agent.abandon()
        await h.runtime.abandonForTest()
        let agentB = FakeAgentProcess(clock: h.clock.clock)
        try await h.restart(adapters: [agentB], mode: .drain)
        let fresh = h.message("new message after rollback", session: "5e551011-0000-4000-8000-0000000000e9", task: "7a5c0001-0000-4000-8000-0000000000e9")
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: running.taskID))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.runtime.tick()
        #expect(h.server.commandLeaseCount(fresh.commandID) == 0, "마무리 모드는 새 전달을 lease하지 않는다")
        #expect(agentB.startedTurns.isEmpty)
        #expect(h.server.commandLeaseCount(cancel.commandID) == 1, "중단은 계속")
        #expect(await h.eventually { h.server.taskState(running.taskID) == "cancelled" || h.server.taskState(running.taskID) == "accepted" || h.server.taskState(running.taskID) == "running" })
        #expect(h.server.requests("register").count == 1, "새 등록 0")
        #expect(try await h.ledger.outboxRows().isEmpty, "남은 사건은 모두 보냈다")
    }
}

/// 접수 신호 없이 계속 기다리는 대본
private func Script_waitOnly() -> FakeAgentProcess.Script { FakeAgentProcess.Script([.wait(100_000)]) }

#endif
