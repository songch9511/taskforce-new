#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 독립 검토 반영 C (OA D2b 계약 7장 C, security P2 셋): 서버 숫자 범위 자르기 · 작업 폴더 / 재개 id의 권한은 Mac에 있다 · 종료 / 계정 삭제 뒤 감독 밖 writer 0
struct BridgeReviewCTests {
    // MARK: 10. 서버 숫자는 디코딩 경계와 recover()에서 범위를 자른다

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TaskforceJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func serverNumbersAreClampedWhereTheyAreDecoded() throws {
        func register(_ heartbeat: String, _ unreachable: String, _ poll: String) -> String {
            #"{"bridge_id":"b1111111-1111-4111-8111-111111111111","bridge_secret":"s","heartbeat_interval_seconds":\#(heartbeat),"unreachable_after_seconds":\#(unreachable),"long_poll_max_seconds":\#(poll),"connections":[]}"#
        }
        let high = try decode(BridgeV1RegisterResponse.self, register("9223372036854775807", "9223372036854775807", "9223372036854775807"))
        #expect(high.heartbeatIntervalSeconds == 3600 && high.unreachableAfterSeconds == 3600 && high.longPollMaxSeconds == 25)
        let low = try decode(BridgeV1RegisterResponse.self, register("-9223372036854775808", "0", "-5"))
        #expect(low.heartbeatIntervalSeconds == 5 && low.unreachableAfterSeconds == 30 && low.longPollMaxSeconds == 1)
        let normal = try decode(BridgeV1RegisterResponse.self, register("30", "90", "25"))
        #expect(normal.heartbeatIntervalSeconds == 30 && normal.unreachableAfterSeconds == 90 && normal.longPollMaxSeconds == 25)
        func heartbeat(_ seconds: String) -> String {
            #"{"heartbeat_interval_seconds":\#(seconds),"server_time":"2026-10-14T05:00:00Z","pending_commands":0,"unknown_task_ids":[],"missing_task_ids":[]}"#
        }
        #expect(try decode(BridgeV1HeartbeatResponse.self, heartbeat("9223372036854775807")).heartbeatIntervalSeconds == 3600)
        #expect(try decode(BridgeV1HeartbeatResponse.self, heartbeat("0")).heartbeatIntervalSeconds == 5)
    }

    @Test func hostileNumbersInTheLedgerNeverCrashTheLoopAndAreClamped() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        try await h.ledger.updateMeta {
            $0.heartbeatIntervalSeconds = Int.max
            $0.unreachableAfterSeconds = Int.max
            $0.longPollMaxSeconds = Int.max
        }
        try await h.restart()
        let before = h.server.requests("commands").count
        await h.runtime.start() // 클램프가 없으면 `Int(Double(Int.max).rounded(.up))`에서 앱이 죽는다
        #expect(await h.eventually { h.server.requests("commands").count > before })
        let wait = Int(h.server.requests("commands").dropFirst(before).first?.query["wait"] ?? "")
        #expect(wait.map { (1...25).contains($0) } == true, "긴 대기는 서버 약속 25초 이하: \(String(describing: wait))")
        await h.runtime.stop()
    }

    @Test func collidingAnswerKeysNeverCrashTheMapBack() {
        let map = Outbox.QuestionMap(ids: ["cut-id": "original-id"], labels: [:])
        let answers: [String: BridgeV1AnswerValue] = ["cut-id": .one("a"), "original-id": .one("b")] // 둘 다 "original-id"로 돌아간다
        let restored = Outbox.originalAnswers(answers, map: map)
        #expect(restored.keys.sorted() == ["original-id"] && restored["original-id"] != nil)
    }

    private func hostileList(cursor: Int, next: String) -> String {
        #"{"commands":[{"id":"c0000000-0000-4000-8000-0000000000ff","cursor":\#(cursor),"kind":"message","agent_session_id":"5e551011-0000-4000-8000-000000000001","agent_task_id":"7a5c0001-0000-4000-8000-0000000000ff","turn_seq":1,"created_at":"2026-10-14T05:00:00Z","leased_by_me":false}],"readbacks":[],"next_cursor":\#(next),"server_time":"2026-10-14T05:00:00Z"}"#
    }

    @Test func aNegativeCursorFromTheServerIsSkippedAndNeverLeased() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.failNext("commands", .init(status: 200, count: 1, bodyJSON: hostileList(cursor: -5, next: "-5")))
        await h.runtime.tick()
        #expect(h.server.requests("ack").isEmpty, "서버 약속(양의 정수)을 깬 cursor의 명령은 lease하지 않는다")
        #expect(h.agent.startedTurns.isEmpty)
    }

    @Test func anExtremeNextCursorNeverBlindsLaterLongPolls() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        h.server.failNext("commands", .init(status: 200, count: 1, bodyJSON: #"{"commands":[],"readbacks":[],"next_cursor":9223372036854775807,"server_time":"2026-10-14T05:00:00Z"}"#))
        await h.runtime.tick()
        h.clock.jump(by: 6)
        _ = await h.runtime.poll(wait: 1, reason: .longPoll)
        let afters = h.server.requests("commands").compactMap { Int($0.query["after"] ?? "") }
        #expect(afters.allSatisfy { $0 < 1_000_000 }, "극값 cursor를 그대로 올리지 않는다: \(afters)")
    }

    // MARK: 11. 작업 폴더 · 재개 id의 권한은 Mac에 있다

    private func start(_ h: BridgeHarness, externalSession: String?, workspaceRef: String?) async throws -> FakeBridgeServer.Created {
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: externalSession, workspaceRef: workspaceRef)
        let created = h.message()
        await h.runtime.tick()
        return created
    }

    private func readbacks(_ h: BridgeHarness, _ created: FakeBridgeServer.Created) -> [[String: Any]] {
        h.server.requests("ack").map(\.json).filter { $0["op"] as? String == "readback" && $0["command_id"] as? String == created.commandID }
    }

    @Test func aWorkspaceTheServerSentAndTheMacNeverChoseIsRefusedAsNotReceived() async throws {
        let h = try BridgeHarness()
        let created = try await start(h, externalSession: "sess_abc123", workspaceRef: "/Users/someone/.ssh")
        #expect(h.agent.startedTurns.isEmpty, "이 Mac이 고르지 않은 폴더에서는 실행하지 않는다")
        let reports = readbacks(h, created)
        #expect(reports.map { "\($0["result"] ?? "")/\($0["process_ended"] ?? "")" } == ["not_received/1"], "\(reports)")
        #expect(await h.command(created.commandID)?.reason == "workspace_unauthorized")
        #expect(await h.task(created.taskID)?.workspaceRef == nil, "검사 전에는 서버 값을 원장 task에 쓰지 않는다")
    }

    @Test func aWorkspaceWithoutAnyResolverIsRefusedToo() async throws {
        let h = try BridgeHarness(workspace: nil)
        let created = try await start(h, externalSession: "sess_abc123", workspaceRef: "/Users/someone/work")
        #expect(h.agent.startedTurns.isEmpty)
        #expect(readbacks(h, created).count == 1)
    }

    @Test func aWorkspaceTheMacChoseIsUsed() async throws {
        let h = try BridgeHarness()
        _ = try await start(h, externalSession: "sess_abc123", workspaceRef: "workspace-test")
        #expect(await h.eventually { h.agent.startedTurns.count == 1 })
        #expect(h.agent.startedTurns.first?.workspaceRef == "workspace-test")
    }

    @Test func aSessionIDThatCouldBeAnOptionOrAPathIsRefused() async throws {
        for bad in ["--dangerously-skip-permissions", "../../etc/passwd", "a b", "with/slash", String(repeating: "a", count: 129), "한글"] {
            let h = try BridgeHarness()
            let created = try await start(h, externalSession: bad, workspaceRef: "workspace-test")
            #expect(h.agent.startedTurns.isEmpty, "\(bad.prefix(20)): 띄우지 않는다")
            #expect(await h.command(created.commandID)?.reason == "unsafe_session_id", "\(bad.prefix(20))")
        }
    }

    @Test func aSafeSessionIDShapeIsAccepted() {
        for good in ["sess_abc-123", "5e551011-0000-4000-8000-000000000001", "A", String(repeating: "z", count: 128)] {
            #expect(BridgeRuntime.isSafeSessionID(good), "\(good.prefix(20))")
        }
        for bad in ["", ".", "a.b", " a", "a b", "한글", "-x", "--resume", String(repeating: "z", count: 129)] {
            #expect(!BridgeRuntime.isSafeSessionID(bad), "\(bad.prefix(20))")
        }
    }

    // MARK: 12. 종료 · 계정 삭제에서 감독 밖 writer를 남기지 않는다

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

    private func runningHarness() async throws -> (BridgeHarness, FakeBridgeServer.Created) {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        h.agent.setIgnoreInterruptForever(true) // SIGTERM을 무시하는 프로세스 (F6)
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        return (h, created)
    }

    @Test func shuttingDownEndsARunThatIgnoresTheInterruptSignal() async throws {
        let (h, created) = try await runningHarness()
        let worker = advancing(h)
        await h.runtime.shutdown(interrupt: true)
        worker.cancel()
        #expect(h.agent.liveRunCount == 0, "신호를 무시해도 종료 뒤 감독 밖 writer가 남지 않는다")
        #expect(h.agent.terminatedOrphans.count == 1, "유예 뒤 terminateOrphan으로 끝냈다")
        #expect(await h.task(created.taskID)?.alive == false)
        #expect(h.agent.interrupts.count == 1, "먼저 중단 신호를 보냈다")
    }

    @Test func deletingTheAccountEndsARunThatIgnoresTheInterruptSignal() async throws {
        let (h, created) = try await runningHarness()
        let worker = advancing(h)
        await h.runtime.interruptLiveTurns()
        worker.cancel()
        #expect(h.agent.liveRunCount == 0)
        #expect(h.agent.terminatedOrphans.count == 1)
        #expect(await h.task(created.taskID)?.alive == false)
    }

    @Test func deletingTheAccountTriesAgainToEndAnOrphanThatCouldNotBeEndedAtStartup() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        _ = h.agent.abandon()
        await h.runtime.abandonForTest()
        h.agent.setLiveness(.alive)
        h.agent.setTerminateResult(.alive) // 시작 때는 끝내지 못했다
        try await h.restart()
        await h.runtime.tick()
        #expect(await h.task(created.taskID)?.alive == true, "감독 밖에 남은 writer")
        h.agent.setTerminateResult(nil)
        h.agent.setLiveness(nil)
        await h.runtime.interruptLiveTurns() // 계정 삭제: 원장을 지우기 전에 다시 끝내 본다
        #expect(await h.task(created.taskID)?.alive == false, "감독 밖 프로세스의 끝도 확인한 뒤에 원장을 지운다")
    }

    @Test func aRunThatEndsInTheGraceTimeIsNotTerminatedAgain() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        await h.runtime.shutdown(interrupt: true)
        #expect(h.agent.terminatedOrphans.isEmpty, "신호에 끝났으면 terminateOrphan은 필요 없다")
        #expect(h.agent.liveRunCount == 0)
    }

    @Test func theSnapshotKnowsAboutALiveProcessEvenWhenTheTurnIsIdle() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        #expect(await h.runtime.hasLiveProcess())
        _ = try await h.ledger.updateTask(created.taskID) { $0.lastState = "idle" }
        #expect(await h.runtime.isBusy() == false, "턴이 idle이면 바쁘지 않다")
        #expect(await h.runtime.hasLiveProcess(), "그래도 프로세스가 살아 있다는 것은 안다 (종료 때 끝낸다)")
    }
}
#endif
