#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 깨우기 · 루프 · 절전 (OA D2b 계약 2.9 · 2.10 · 4.1 K8): Realtime 신호 → `wait=0`, 구독 끊김 → `wait=25`, 목록 간격 2초 · 5초, 잠들 때 긴 대기 취소
struct BridgeWakeLoopTests {
    /// 기다림은 사건 순서다: 루프의 시간은 손으로 미는 시계라 기다리는 동안 흐르지 않는다 — "바로 본다 · 2초 간격 · 신호에 본다"는 시계를 밀기 전 · 뒤에 일어난
    /// 요청으로 가르고, 실제 시간은 포기 상한일 뿐이다(맞으면 바로 돌아온다). 첫 목록 요청은 원장 복구(SQLite) · 등록 · heartbeat 왕복 뒤에 나가서,
    /// Kit 전체가 막 시작하는 부하에서는 8초를 넘길 수 있었다 (19장: 그때 다섯이 함께 실패했고 그 뒤 단언은 모두 맞았다)
    static let ceiling: TimeInterval = 60

    private func waits(_ h: BridgeHarness) -> [String] { h.server.requests("commands").map { $0.query["wait"] ?? "" } }

    @Test func withARealtimeSubscriptionTheLoopNeverLongPollsAndAWakeSignalListsAtOnce() async throws {
        let wake = FakeBridgeWake(subscribed: true)
        let h = try BridgeHarness(wake: wake)
        await h.runtime.start()
        defer { Task { await h.runtime.stop() } }
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count == 1 }, "시작 때 한 번 바로 본다")
        #expect(await h.eventually(timeout: Self.ceiling) { wake.startedBridgeIDs.count == 1 })
        #expect(await h.eventually(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 }, "목록 사이 2초 간격")
        await h.clock.advance(by: 2.1)
        #expect(await h.eventually(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 }, "이제 신호를 기다린다 (heartbeat 주기 타이머)")
        let created = h.message()
        wake.fire()
        #expect(await h.eventually(timeout: Self.ceiling) { h.agent.startedTurns.count == 1 })
        #expect(h.server.commandLeaseCount(created.commandID) == 1)
        #expect(waits(h).allSatisfy { $0 == "0" }, "긴 대기는 돌리지 않는다: \(waits(h))")
    }

    @Test func withoutARealtimeSubscriptionTheLoopLongPollsAndTheListGapIsTwoSeconds() async throws {
        let wake = FakeBridgeWake(subscribed: false)
        let h = try BridgeHarness(wake: wake)
        h.agent.setScript(.normal())
        await h.runtime.start()
        defer { Task { await h.runtime.stop() } }
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count == 1 })
        #expect(waits(h) == ["25"])
        // 새 명령이 긴 대기를 끝낸다
        h.message("one", task: "7a5c0001-0000-4000-8000-0000000000a1")
        h.server.notifyChange()
        #expect(await h.eventually(timeout: Self.ceiling) { h.agent.startedTurns.count == 1 })
        await h.settle(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 }
        let before = h.server.requests("commands").count
        await h.clock.advance(by: 1.5)
        #expect(h.server.requests("commands").count == before, "목록 사이 최소 2초")
        await h.clock.advance(by: 0.6)
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count > before })
        #expect(waits(h).allSatisfy { $0 == "25" })
    }

    @Test func whenEveryReturnedItemIsDeferredOrAlreadyHandledTheNextListWaitsFiveSeconds() async throws {
        let wake = FakeBridgeWake(subscribed: false)
        let h = try BridgeHarness(wake: wake)
        h.agent.setScript(.staysRunning())
        await h.registerFirst() // 브리지를 만든다
        h.message("first", task: "7a5c0001-0000-4000-8000-0000000000a1")
        await h.runtime.tick()
        #expect(await h.eventually(timeout: Self.ceiling) { h.agent.startedTurns.count == 1 })
        h.message("second", task: "7a5c0001-0000-4000-8000-0000000000a2", turn: 2) // 같은 세션: writer 하나 때문에 미룬다
        await h.runtime.start()
        defer { Task { await h.runtime.stop() } }
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count >= 3 })
        let before = h.server.requests("commands").count
        await h.settle(timeout: Self.ceiling) { h.clock.sleeperCount >= 2 }
        await h.clock.advance(by: 4.5)
        let during = h.server.requests("commands").count
        #expect(during == before, "미룬 항목만 돌아오면 5초 뒤에 다시 본다")
        await h.clock.advance(by: 1)
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count > before })
    }

    @Test func pollOutcomeKnowsWhenItOnlyHeldKnownOrDeferredItems() {
        #expect(PollOutcome(listed: 2, handled: 0, deferred: 2, failed: false).onlyKnownOrDeferred)
        #expect(!PollOutcome(listed: 2, handled: 1, deferred: 1, failed: false).onlyKnownOrDeferred)
        #expect(!PollOutcome(listed: 0, handled: 0, deferred: 0, failed: false).onlyKnownOrDeferred)
    }

    @Test func aLostSubscriptionFallsBackToLongPollAtTheNextHeartbeatTick() async throws {
        let wake = FakeBridgeWake(subscribed: true)
        let h = try BridgeHarness(wake: wake)
        await h.runtime.start()
        defer { Task { await h.runtime.stop() } }
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count == 1 })
        #expect(await h.eventually(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 })
        await h.clock.advance(by: 2.1) // 목록 사이 간격
        #expect(await h.eventually(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 }, "heartbeat 주기 타이머")
        wake.setSubscribed(false)
        await h.clock.advance(by: 31)
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").contains { $0.query["wait"] == "25" } })
    }

    @Test func theHeartbeatSafetyNetFindsACommandTheRealtimeSignalMissed() async throws {
        let wake = FakeBridgeWake(subscribed: true)
        let h = try BridgeHarness(wake: wake)
        await h.runtime.start()
        defer { Task { await h.runtime.stop() } }
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count == 1 })
        #expect(await h.eventually(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 }, "목록 사이 2초 간격")
        await h.clock.advance(by: 2.1)
        #expect(await h.eventually(timeout: Self.ceiling) { h.clock.sleeperCount >= 1 }, "heartbeat 주기 타이머")
        let created = h.message() // 신호가 없다
        await h.clock.advance(by: 31) // heartbeat 주기: pending_commands > 0
        #expect(await h.eventually(timeout: Self.ceiling) { h.agent.startedTurns.count == 1 })
        #expect(h.server.commandLeaseCount(created.commandID) == 1)
    }

    // MARK: 절전 · 깨어남

    @Test func sleepingCancelsTheLongPollClosesRealtimeAndStopsAllRequests() async throws {
        let wake = FakeBridgeWake(subscribed: false)
        let h = try BridgeHarness(wake: wake)
        await h.runtime.start()
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count == 1 })
        let stopsBefore = wake.stopCount
        await h.runtime.prepareForSleep()
        #expect(await h.runtime.status == .sleeping)
        #expect(wake.stopCount > stopsBefore, "Realtime 채널을 닫는다")
        let count = h.server.requests.count
        await h.clock.advance(by: 120)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.server.requests.count == count, "잠든 동안 요청 0 (긴 대기 취소)")
        // 깨어난 뒤 첫 요청은 heartbeat
        await h.runtime.didWake()
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests.count > count })
        #expect(h.server.requests.dropFirst(count).first?.route == "heartbeat")
        #expect(wake.startedBridgeIDs.count >= 2, "깨어난 뒤 Realtime을 다시 구독한다")
        await h.runtime.stop()
    }

    @Test func aLateResponseFromBeforeTheSleepIsDiscarded() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let pending = Task { await h.runtime.poll(wait: 25, reason: .longPoll) }
        #expect(await h.eventually(timeout: Self.ceiling) { h.server.requests("commands").count == 2 })
        await h.runtime.prepareForSleep()
        let late = h.message()
        h.server.notifyChange()
        let outcome = await pending.value
        #expect(outcome.handled == 0)
        #expect(try await h.ledger.command(late.commandID) == nil, "절전 전에 보낸 요청의 응답은 원장에 쓰지 않는다")
        #expect(h.agent.startedTurns.isEmpty)
    }

    @Test func afterWakingAProcessThatDiedWhileAsleepIsFoundByLivenessAndSettledByTheLedger() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually(timeout: Self.ceiling) { (await h.command(created.commandID))?.state == .accepted })
        await h.settle(timeout: Self.ceiling) { h.server.taskState(created.taskID) == "running" }
        await h.runtime.prepareForSleep()
        h.agent.setLiveness(.ended(AgentExit(code: nil, signal: 9)))
        await h.runtime.didWake()
        #expect(await h.eventually(timeout: Self.ceiling) { (await h.task(created.taskID))?.alive == false })
        await h.runtime.tick()
        await h.settle(timeout: Self.ceiling) { h.server.taskState(created.taskID) == "failed" }
        #expect(h.server.taskState(created.taskID) == "failed", "접수 뒤 조용히 죽음 → failed(agent_error)")
    }

    @Test func aWakeAfterALongGapSendsReconcileEventsForTheTasksTheLedgerStillBelievesAreLive() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually(timeout: Self.ceiling) { (await h.command(created.commandID))?.state == .accepted })
        await h.settle(timeout: Self.ceiling) { h.server.taskState(created.taskID) == "running" }
        await h.runtime.prepareForSleep()
        h.clock.jump(by: 300)
        h.server.sweep() // 서버가 끊김으로 보고 unreachable로 표시했다
        #expect(h.server.taskState(created.taskID) == "unreachable")
        await h.runtime.didWake()
        await h.runtime.tick()
        await h.settle(timeout: Self.ceiling) { h.server.taskState(created.taskID) == "running" }
        #expect(h.server.taskState(created.taskID) == "running", "reconcile이 last_live_state로 되돌렸다")
        let reconcile = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }.filter { $0["type"] as? String == "reconcile" }
        #expect(reconcile.count == 1)
        #expect(reconcile.first?["seq"] == nil && reconcile.first?["payload"] == nil, "seq도 상태도 싣지 않는다")
        #expect((reconcile.first?["event_id"] as? String)?.hasSuffix(":r1") == true)
    }

    @Test func reconcileGoesOutOnlyAfterTheOutboxWasDeliveredInOrder() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually(timeout: Self.ceiling) { (await h.command(created.commandID))?.state == .accepted })
        h.server.failNext("events", .init(status: 0, transport: true, count: 1))
        await h.runtime.flushOutbox()
        await h.runtime.prepareForSleep()
        h.clock.jump(by: 300)
        await h.runtime.didWake()
        await h.runtime.tick()
        await h.runtime.tick()
        let applied = h.server.eventResults.map(\.type)
        #expect(applied == ["session_bound", "accepted", "progress", "reconcile"], "원래 사건을 순서대로 먼저 다 보낸 뒤 reconcile: \(applied)")
    }
}
#endif
