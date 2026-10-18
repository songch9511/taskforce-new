#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 겹치는 폴더에서 세션이 동시에 돌지 않게 (계약 13.13 덧붙임, Astra 재검토 5): 새 턴을 띄우기 전에, 이 파티션의 다른 세션이 살아 있고 그 폴더가 이 폴더와 겹치면(조상 · 자손, 같은 실제 경로는 아니다)
/// 막는다 — 기존 "Session didn't start". 살아 있는지 모르거나 읽지 못해도 막는다. 검사와 예약은 한 actor 단계다. 가짜 서버 · 가짜 agent · 임시 폴더만 쓴다
struct WorkspaceLiveOverlapTests {
    private let s1 = BridgeHarness.sessionID
    private let s2 = "5e551011-0000-4000-8000-0000000000c3"

    private struct Setup {
        let r: BridgeWorkspaceRefTests.Rig
        let sub: String
        let parent: String
        let other: String
        var h: BridgeHarness { r.h }
    }

    /// 폴더 `a`, `a/sub`, `b` — 세션 둘은 아직 핀이 없다
    private func setup() async throws -> Setup {
        let r = try await BridgeWorkspaceRefTests.Rig(pinned: nil)
        let sub = r.fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        return Setup(r: r, sub: GateFileSystem.realpath(sub) ?? sub, parent: r.fixture.real("a"), other: r.fixture.real("b"))
    }

    /// 세션별 대본: `running`에 든 세션은 접수한 뒤 오래 돈다(수동 시계를 흘려야 끝난다), 나머지는 한 턴 하고 끝난다
    private func scripts(_ s: Setup, running: Set<String>, folders: [String: String]) {
        let running = Set(running.map { $0.lowercased() })
        s.h.agent.setScript { turn in
            let folder = folders[turn.sessionID.lowercased()]
            if running.contains(turn.sessionID.lowercased()) {
                return FakeAgentProcess.Script([.sessionBound(external: "ext-\(turn.sessionID.prefix(8))", workspace: folder), .accepted, .progress, .wait(100_000), .end(AgentExit(code: 0))])
            }
            return FakeAgentProcess.Script([.sessionBound(external: "ext-\(turn.sessionID.prefix(8))", workspace: folder), .accepted, .turnCompleted, .end(AgentExit(code: 0))])
        }
    }

    @discardableResult
    private func send(_ s: Setup, session: String, turn: Int = 1) async -> FakeBridgeServer.Created {
        let created = s.h.message(session: session, task: UUID().uuidString.lowercased(), turn: turn)
        s.h.clock.jump(by: 6)
        await s.h.runtime.tick()
        return created
    }

    private func finished(_ created: FakeBridgeServer.Created, _ s: Setup) async -> Bool {
        await s.h.settle(timeout: 30) { s.h.server.taskState(created.taskID) == "idle" }
        return s.h.server.taskState(created.taskID) == "idle"
    }

    private func blocked(_ created: FakeBridgeServer.Created, _ s: Setup) async -> Bool {
        await s.h.settle(timeout: 30) { s.h.server.taskState(created.taskID) == "failed" }
        return s.h.server.taskState(created.taskID) == "failed"
    }

    private func running(_ created: FakeBridgeServer.Created, _ s: Setup) async -> Bool {
        await s.h.eventually(timeout: 30) { (await s.h.command(created.commandID))?.state == .accepted }
    }

    // MARK: 섞인 순서 (Astra)

    @Test func anUngroupedSessionRunningInSubBlocksTheProjectSessionInTheParentUntilItsEndIsProven() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub) // Ungrouped: 프로젝트 없음
        scripts(s, running: [s1], folders: [s1: s.sub, s2: s.parent])
        let first = await send(s, session: s1)
        #expect(await running(first, s))
        // S1이 도는 동안 새 프로젝트가 부모를 등록한다 (등록은 프로젝트 폴더하고만 비교한다) · 그 프로젝트의 세션 S2
        try s.r.registry.setFolder(s.parent, forProject: UUID())
        try s.r.registry.pin(session: s2, to: s.parent)
        // 프로젝트 세션 S2: 자기 프로젝트 폴더와는 같아 통과하지만 S1이 살아 있다
        let second = await send(s, session: s2)
        #expect(await blocked(second, s), "S1이 살아 있다: 접수 전 실패 (Session didn't start)")
        #expect(s.h.agent.startedTurns.count == 1, "프로세스를 띄우지 않았다")
        // S1의 끝이 증명된다 (수동 시계를 흘려 대본을 끝낸다)
        await s.h.clock.advance(by: 100_001)
        #expect(await s.h.eventually(timeout: 30) { await s.h.task(first.taskID)?.alive == false })
        let again = await send(s, session: s2, turn: 2)
        #expect(await finished(again, s), "S1이 끝난 뒤에는 된다")
        #expect(s.h.agent.startedTurns.count == 2)
        let reservations = await s.h.runtime.startReservations
        #expect(reservations.isEmpty, "예약은 새지 않는다")
    }

    @Test func twoUngroupedSessionsInNestedFoldersNeverRunAtTheSameTime() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        try s.r.registry.pin(session: s2, to: s.parent)
        scripts(s, running: [s1], folders: [s1: s.sub, s2: s.parent])
        let first = await send(s, session: s1)
        #expect(await running(first, s))
        let second = await send(s, session: s2)
        #expect(await blocked(second, s))
        #expect(s.h.agent.startedTurns.count == 1)
    }

    @Test func theSameRealPathOrUnrelatedFoldersRunTogether() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        try s.r.registry.pin(session: s2, to: s.sub) // 같은 실제 경로: 경로 lease 키가 같다
        scripts(s, running: [s1], folders: [s1: s.sub, s2: s.sub])
        let first = await send(s, session: s1)
        #expect(await running(first, s))
        let second = await send(s, session: s2)
        #expect(await finished(second, s), "같은 폴더면 된다")
        // 관계 없는 폴더
        let third = "5e551011-0000-4000-8000-0000000000d4"
        try s.r.registry.pin(session: third, to: s.other)
        scripts(s, running: [s1], folders: [s1: s.sub, s2: s.sub, third: s.other])
        let unrelated = await send(s, session: third)
        #expect(await finished(unrelated, s))
        #expect(s.h.agent.startedTurns.count == 3)
    }

    // MARK: 모르면 막는다 (fail-closed)

    @Test func aLiveStateThatCannotBeReadBlocksTheTurn() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        scripts(s, running: [], folders: [s1: s.sub])
        await s.h.runtime.setLiveStateUnreadableForTest(true)
        let blockedTurn = await send(s, session: s1)
        #expect(await blocked(blockedTurn, s), "다른 세션이 하나도 없어도 상태를 못 읽으면 막는다")
        #expect(s.h.agent.startedTurns.isEmpty)
        await s.h.runtime.setLiveStateUnreadableForTest(false)
        let ok = await send(s, session: s1, turn: 2)
        #expect(await finished(ok, s))
    }

    @Test func aLiveTaskWhoseFolderIsUnknownBlocksEvenAnUnrelatedFolder() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        try s.r.registry.pin(session: s2, to: s.other)
        scripts(s, running: [s1], folders: [s1: s.sub, s2: s.other])
        let first = await send(s, session: s1)
        #expect(await running(first, s))
        _ = try await s.h.ledger.updateTask(first.taskID) { $0.workspaceRef = nil } // 폴더를 모른다
        let second = await send(s, session: s2)
        #expect(await blocked(second, s), "살아 있는 실행의 폴더를 모르면 관계 없는 폴더도 막는다")
    }

    @Test func aSessionTheAdapterSaysIsStillRunningOrCannotBeProvenEndedBlocksButAnEndedOneDoesNot() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        try s.r.registry.pin(session: s2, to: s.parent)
        scripts(s, running: [], folders: [s1: s.sub, s2: s.parent])
        let done = await send(s, session: s1)
        #expect(await finished(done, s)) // 원장은 끝났다고 한다 (alive 아님)
        s.h.agent.setSessionRun(s1, .alive)
        let alive = await send(s, session: s2)
        #expect(await blocked(alive, s), "adapter가 그 세션의 실행이 아직 돈다고 한다")
        s.h.agent.setSessionRun(s1, .unknown)
        let unknown = await send(s, session: s2, turn: 2)
        #expect(await blocked(unknown, s), "끝을 증명하지 못했다: 끝났다고 하지 않는다")
        s.h.agent.setSessionRun(s1, .ended(AgentExit(code: 0)))
        let ended = await send(s, session: s2, turn: 3)
        #expect(await finished(ended, s))
    }

    @Test func aStaleUnprovenWordOnAnEndedTaskDoesNotBlockButAnUnprovenRunningOneDoes() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        try s.r.registry.pin(session: s2, to: s.parent)
        scripts(s, running: [], folders: [s1: s.sub, s2: s.parent])
        let done = await send(s, session: s1)
        #expect(await finished(done, s))
        _ = try await s.h.ledger.updateTask(done.taskID) { $0.cancelState = "unproven" } // 끝이 증명된 뒤 남은 옛 글자 (alive 아님)
        let ok = await send(s, session: s2)
        #expect(await finished(ok, s), "alive가 아니면 끝이 증명된 것이다")
        // 증명 못 한 중단은 늘 alive와 함께 있다: 돌고 있으면 막는다
        _ = try await s.h.ledger.updateTask(done.taskID) { $0.alive = true }
        let blockedTurn = await send(s, session: s2, turn: 2)
        #expect(await blocked(blockedTurn, s))
    }

    @Test func aSupervisedRunAnOrphanAndACloseRunTheLedgerDoesNotYetShowStillBlockAnOverlappingStart() async throws {
        let s = try await setup()
        let runtime = s.h.runtime
        // 원장이 아직 모르는 감독 실행 (방금 띄웠다): 세션 · 폴더가 실행에 적혀 있다
        await runtime.seedSupervisedForTest(taskID: "7a5c0001-0000-4000-8000-0000000000a1", session: s1, workspace: s.sub)
        let overlapsSupervised = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000b1", session: s2, folder: s.parent)
        #expect(!overlapsSupervised, "감독 중인 다른 세션의 폴더와 겹친다")
        let sameFolder = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000b2", session: s2, folder: s.sub)
        #expect(sameFolder, "같은 폴더는 된다")
        // 폴더를 모르는 감독 실행은 관계 없는 폴더도 막는다
        await runtime.seedSupervisedForTest(taskID: "7a5c0001-0000-4000-8000-0000000000a2", session: "5e551011-0000-4000-8000-0000000000e9", workspace: nil)
        let unknownFolder = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000b3", session: s2, folder: s.other)
        #expect(!unknownFolder)
    }

    @Test func anOrphanOrACloseRunOfAnotherSessionBlocksAnOverlappingStart() async throws {
        let s = try await setup()
        try s.r.registry.pin(session: s1, to: s.sub)
        scripts(s, running: [], folders: [s1: s.sub])
        let done = await send(s, session: s1)
        #expect(await finished(done, s)) // 원장에는 끝난 task (폴더 있음)
        let runtime = s.h.runtime
        await runtime.seedOrphanForTest(taskID: done.taskID)
        let orphan = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000b1", session: s2, folder: s.parent)
        #expect(!orphan, "끝을 확인하지 못한 고아")
        await runtime.clearOrphanForTest(taskID: done.taskID)
        let clear = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000b2", session: s2, folder: s.parent)
        #expect(clear)
        await runtime.releaseReservationForTest(taskID: "7a5c0001-0000-4000-8000-0000000000b2")
        await runtime.seedClosingForTest(taskID: done.taskID, session: s1)
        let closing = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000b3", session: s2, folder: s.parent)
        #expect(!closing, "adapter 닫기 실행이 도는 세션")
    }

    // MARK: 같은 단계 (경합)

    @Test func twoOverlappingTurnsStartedAtTheSameTimeCannotBothPass() async throws {
        let s = try await setup()
        let runtime = s.h.runtime
        let sub = s.sub
        let parent = s.parent
        async let first = runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000f1", session: s1, folder: sub)
        async let second = runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000f2", session: s2, folder: parent)
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1, "겹치는 두 턴이 둘 다 통과할 수 없다: \(results)")
        let reservations = await runtime.startReservations
        #expect(reservations.count == 1)
        // 같은 실제 경로는 둘 다 예약된다
        let sameA = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000f3", session: "5e551011-0000-4000-8000-0000000000e1", folder: s.other)
        let sameB = await runtime.reserveStart(taskID: "7a5c0001-0000-4000-8000-0000000000f4", session: "5e551011-0000-4000-8000-0000000000e2", folder: s.other)
        #expect(sameA && sameB)
    }
}
#endif
