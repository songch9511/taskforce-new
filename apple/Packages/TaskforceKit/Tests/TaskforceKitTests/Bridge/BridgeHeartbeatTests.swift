#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// heartbeat (OA D2b 계약 2.9 · 4.1 K7)와 요청 한도 (2.11 · K9)
struct BridgeHeartbeatTests {
    private func heartbeats(_ h: BridgeHarness) -> [FakeBridgeServer.Recorded] { h.server.requests("heartbeat") }

    // MARK: 주기

    @Test func heartbeatsGoOutEveryThirtySecondsAndNotSooner() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        #expect(heartbeats(h).count == 1)
        await h.runtime.tick()
        #expect(heartbeats(h).count == 1)
        h.clock.jump(by: 29)
        await h.runtime.tick()
        #expect(heartbeats(h).count == 1)
        h.clock.jump(by: 2)
        await h.runtime.tick()
        #expect(heartbeats(h).count == 2)
    }

    @Test func theIntervalIsShakenByAtMostTwoSeconds() async throws {
        let h = try BridgeHarness(jitter: 2)
        await h.registerFirst()
        var samples: Set<Int> = []
        for _ in 0..<60 {
            let remaining = await h.runtime.secondsUntilHeartbeat()
            #expect(remaining >= 28 && remaining <= 32)
            samples.insert(Int((remaining * 100).rounded()))
        }
        #expect(samples.count > 5, "흔들림이 있다")
    }

    // MARK: 바로 보내는 때

    @Test func aHeartbeatGoesOutAtOnceWhenTheConnectionComesBack() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.failNext("commands", .init(status: 0, transport: true))
        await h.runtime.tick()
        #expect(await h.runtime.status == .offline)
        let before = heartbeats(h).count
        h.clock.jump(by: 6) // 서버의 5초 throttle 밖
        await h.runtime.tick()
        #expect(heartbeats(h).count == before + 1, "30초가 안 됐어도 다시 붙으면 바로")
        let routes = h.routes()
        let failed = try #require(routes.lastIndex(of: "commands"))
        _ = failed
        #expect(Array(routes.suffix(2)) == ["heartbeat", "commands"])
        #expect(await h.runtime.status == .connected)
    }

    @Test func leaseWaitsForAHeartbeatWhenTheLastGoodOneIsOlderThanNinetySeconds() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.clock.jump(by: 100)
        let created = h.message()
        h.server.sweepSessionUnreachable(created.sessionID) // heartbeat가 끊겨 세션이 unreachable이 됐다
        // 목록만 보고(heartbeat 단계 없이) 바로 lease하려는 경로: lease 바로 앞 요청이 heartbeat여야 한다
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        let sequence = h.server.requests.map { $0.route == "ack" ? "ack:\($0.json["op"] as? String ?? "")" : $0.route }
        let lease = try #require(sequence.firstIndex(of: "ack:lease"))
        #expect(sequence[..<lease].last == "heartbeat", "lease 바로 앞 요청은 heartbeat: \(sequence)")
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
    }

    @Test func noLeaseIsSentWhileTheHeartbeatCannotReachTheServer() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let created = h.message()
        h.clock.jump(by: 100)
        h.server.failNext("heartbeat", .init(status: 0, transport: true))
        _ = await h.runtime.poll(wait: 0, reason: .realtime)
        #expect(h.server.commandLeaseCount(created.commandID) == 0)
        #expect(h.agent.startedTurns.isEmpty)
    }

    @Test func aWakeSendsAHeartbeatFirstBeforeAnythingElse() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let count = h.server.requests.count
        await h.runtime.prepareForSleep()
        #expect(await h.runtime.status == .sleeping)
        await h.runtime.didWake()
        await h.runtime.tick()
        let after = h.server.requests.dropFirst(count).map(\.route)
        #expect(after.first == "heartbeat")
    }

    // MARK: 본문 모양

    @Test func tasksCarryEveryUnfinishedTaskLiveFirstThenWaitingThenRecentCappedAtFifty() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        func id(_ index: Int) -> String { String(format: "7a5c0001-0000-4000-8000-%012d", index) }
        for index in 0..<60 {
            var task = BridgeTest.task(id(index), at: BridgeTest.t0.addingTimeInterval(Double(index)))
            switch index {
            case 0..<5:
                task.alive = true
                task.lastState = "running"
                task.lastSeq = index + 1
            case 5..<10:
                task.lastState = "awaiting_answer"
                task.openRequestID = "req-\(index)"
            default:
                task.lastState = "accepted"
            }
            try await h.ledger.saveTask(task)
        }
        var finished = BridgeTest.task(id(100), at: BridgeTest.t0.addingTimeInterval(500))
        finished.lastState = "idle"
        try await h.ledger.saveTask(finished)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let request = try #require(heartbeats(h).last)
        let tasks = try #require(request.json["tasks"] as? [[String: Any]])
        let ids = tasks.compactMap { $0["task_id"] as? String }
        #expect(ids.count == 50)
        #expect(Set(ids.prefix(5)) == Set((0..<5).map(id)), "살아 있는 것이 먼저")
        #expect(Set(ids[5..<10]) == Set((5..<10).map(id)), "그다음 질문 대기")
        #expect(Set(ids[10...]) == Set((20..<60).map(id)), "나머지는 최근 순")
        #expect(!ids.contains(id(100)), "idle은 끝난 것이라 넣지 않는다")
        #expect(tasks.allSatisfy { $0["process_alive"] is Bool && $0.keys.contains("last_seq") })
    }

    @Test func lastSeqIsNullWhenNothingWasSentButTheKeyIsAlwaysThere() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        var fresh = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000f1")
        fresh.lastState = "dispatched"
        var sent = BridgeTest.task("7a5c0001-0000-4000-8000-0000000000f2")
        sent.lastState = "running"
        sent.lastSeq = 4
        try await h.ledger.saveTask(fresh)
        try await h.ledger.saveTask(sent)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let tasks = try #require(heartbeats(h).last?.json["tasks"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0["task_id"] as? String ?? "", $0) })
        #expect(byID[fresh.agentTaskID]?["last_seq"] is NSNull)
        #expect(byID[sent.agentTaskID]?["last_seq"] as? Int == 4)
    }

    @Test func appVersionAndAdaptersGoOnlyWhenNeeded() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let first = try #require(heartbeats(h).first)
        #expect(first.json["app_version"] as? String == "0.2.0-test" && first.json["adapters"] != nil)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let second = try #require(heartbeats(h).last)
        #expect(second.json["app_version"] == nil && second.json["adapters"] == nil, "null이 아니라 키를 뺀다")
        // 바뀌어도 10분 안에는 다시 probe하지 않는다
        h.agent.setReport { $0.signedIn = .no }
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(heartbeats(h).last?.json["adapters"] == nil)
        h.clock.jump(by: 600)
        await h.runtime.tick()
        let changed = try #require(heartbeats(h).last)
        let reports = try #require(changed.json["adapters"] as? [[String: Any]])
        #expect(reports.first?["signed_in"] as? String == "no" && changed.json["app_version"] == nil)
        // 같은 값이면 다시 보내지 않는다
        h.clock.jump(by: 700)
        await h.runtime.tick()
        #expect(heartbeats(h).last?.json["adapters"] == nil)
    }

    @Test func aThrottledResponseCountsAsSuccess() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let before = heartbeats(h).count
        await h.runtime.sendHeartbeat()
        #expect(heartbeats(h).count == before + 1, "서버가 5초 안의 두 번째에는 지난 결과를 준다")
        #expect(await h.runtime.status == .connected)
        #expect(try await h.ledger.meta().lastHeartbeatOKAt == h.clock.now)
    }

    // MARK: 응답 처리

    @Test func aTaskTheServerDoesNotKnowIsMarkedDroppedFromLaterHeartbeatsAndItsLiveRunIsStopped() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        h.server.removeTask(created.taskID)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(await h.eventually { !h.agent.interrupts.isEmpty })
        #expect(try await h.ledger.task(created.taskID)?.serverUnknownAt != nil)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        let tasks = (heartbeats(h).last?.json["tasks"] as? [[String: Any]]) ?? []
        #expect(!tasks.contains { $0["task_id"] as? String == created.taskID })
    }

    @Test func pendingCommandsMakeTheNextListIgnoreTheCursorFilter() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.message("first")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        // after가 올랐다
        _ = await h.runtime.poll(wait: 0, reason: .longPoll)
        let normal = try #require(h.server.requests("commands").last)
        #expect(normal.query["after"] != "0")
        h.message("second", session: "5e551011-0000-4000-8000-0000000000d2")
        h.clock.jump(by: 31)
        await h.runtime.housekeeping() // heartbeat가 pending_commands > 0을 돌려준다
        _ = await h.runtime.poll(wait: 0, reason: .longPoll)
        #expect(h.server.requests("commands").last?.query["after"] == "0")
    }

    @Test func aDeferredCommandStaysVisibleBecauseTheLongPollCursorStopsBeforeIt() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        h.message("first", task: "7a5c0001-0000-4000-8000-0000000000a1")
        await h.runtime.tick()
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        let second = h.message("second", task: "7a5c0001-0000-4000-8000-0000000000a2", turn: 2)
        _ = await h.runtime.poll(wait: 0, reason: .longPoll) // 둘째는 writer 하나 때문에 미룬다
        _ = await h.runtime.poll(wait: 0, reason: .longPoll)
        let afters = h.server.requests("commands").suffix(2).compactMap { Int($0.query["after"] ?? "") }
        let secondCursor = try #require(h.server.commandCursor(second.commandID))
        #expect(afters.allSatisfy { $0 < secondCursor }, "미룬 명령의 cursor 앞까지만 after로 보낸다: \(afters) < \(secondCursor)")
    }

    // MARK: 요청 한도 (K9)

    @Test func eventsAreSentAtMostNinetySixTimesPerMinuteAndTheRestWaitWithoutBeingDeleted() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 1)
        for _ in 0..<100 {
            await h.runtime.flushOutbox()
            try await h.seedEvents(count: 1)
        }
        #expect(h.server.requests("events").count == 96)
        #expect(try await h.ledger.outboxRows().count >= 4, "한도를 넘은 사건은 지우지 않고 남는다")
        h.clock.jump(by: 61)
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
    }

    @Test func listsAreRequestedAtMostSeventyTwoTimesPerMinute() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        for _ in 0..<80 { _ = await h.runtime.poll(wait: 0, reason: .longPoll) }
        #expect(h.server.requests("commands").count == 72)
        h.clock.jump(by: 61)
        _ = await h.runtime.poll(wait: 0, reason: .longPoll)
        #expect(h.server.requests("commands").count == 73)
    }

    @Test func acksAreSentAtMostOneHundredNinetyTwoTimesPerMinute() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        for index in 0..<200 {
            try await h.ledger.saveCommand(BridgeTest.command("c0000000-0000-4000-8000-\(String(format: "%012d", index))", state: .ended))
            _ = try await h.ledger.enqueueAck(commandID: "c0000000-0000-4000-8000-\(String(format: "%012d", index))", op: "complete", result: "sent", bodyJSON: "{\"bridge_id\":\"\(h.bridgeID)\",\"command_id\":\"c-\(index)\",\"op\":\"complete\",\"result\":\"sent\"}")
        }
        for _ in 0..<10 { await h.runtime.flushAcks() }
        #expect(h.server.requests("ack").count == 192)
        #expect(try await h.ledger.allAcks().count == 8)
    }

    @Test func aRateLimitedRoutePausesForRetryAfterAndOtherRoutesKeepGoing() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.seedEvents(count: 3)
        h.server.failNext("events", .init(status: 429, headers: ["Retry-After": "17"]))
        await h.runtime.flushOutbox()
        let afterLimit = h.server.requests("events").count
        #expect(afterLimit == 1)
        #expect(try await h.ledger.outboxRows().count == 3, "429는 지우지 않는다")
        h.clock.jump(by: 16)
        await h.runtime.flushOutbox()
        #expect(h.server.requests("events").count == afterLimit, "Retry-After 동안은 그 route만 멈춘다")
        _ = await h.runtime.poll(wait: 0, reason: .longPoll)
        #expect(h.server.requests("commands").count == 2, "다른 route는 계속")
        h.clock.jump(by: 2)
        await h.runtime.flushOutbox()
        #expect(try await h.ledger.outboxRows().isEmpty)
    }
}
#endif
