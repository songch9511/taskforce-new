#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 재검토 3 (Astra): 원장 읽기가 실패하면 증명하지 못한 것이다 — 핀을 둔다(기준 (a)) · 끝이 증명되면 예전 `unproven`을 정산한다 · "영구히 닫힘"은 원장에 적어 앱을 다시 시작해도 · 원장 정리 전에도 남는다.
/// 가짜 서버 · 가짜 agent · 임시 폴더만 쓴다
struct WorkspacePinReleaseProofTests {
    private let sessionID = BridgeHarness.sessionID

    private struct Setup {
        let r: BridgeWorkspaceRefTests.Rig
        let project: UUID
        let sub: String
        let parent: String
        var h: BridgeHarness { r.h }
    }

    private func setup() async throws -> Setup {
        let r = try await BridgeWorkspaceRefTests.Rig(pinned: nil)
        let sub = r.fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let project = UUID()
        try r.registry.setFolder(sub, forProject: project)
        try r.registry.pin(session: sessionID, to: sub)
        return Setup(r: r, project: project, sub: GateFileSystem.realpath(sub) ?? sub, parent: r.fixture.folder("a"))
    }

    private func finishOneTurn(_ s: Setup) async -> FakeBridgeServer.Created {
        s.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: s.sub), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let created = s.h.message()
        await s.h.runtime.tick()
        await s.h.settle { s.h.server.taskState(created.taskID) == "idle" }
        return created
    }

    /// - endsByItself: 긴 기다림이 지나면 프로세스가 저절로 끝난다 (수동 시계를 넘겨 끝낸다)
    private func startRunningTurn(_ s: Setup, endsByItself: Bool = false) async -> FakeBridgeServer.Created {
        let steps: [FakeAgentProcess.Step] = [.sessionBound(external: "ext-1", workspace: s.sub), .accepted, .progress, .wait(100_000)] + (endsByItself ? [.end(AgentExit(code: 0))] : [])
        s.h.agent.setScript(FakeAgentProcess.Script(steps))
        let created = s.h.message()
        await s.h.runtime.tick()
        #expect(await s.h.eventually(timeout: 30) { (await s.h.command(created.commandID))?.state == .accepted })
        return created
    }

    /// 원장에 "닫힘"이 적혀 있나 (읽지 못하면 nil)
    private func retired(_ s: Setup) async -> Bool? { try? await s.h.ledger.isSessionRetired(sessionID) }

    private func overlapRefused(_ s: Setup) -> Bool {
        do { try s.r.registry.setFolder(s.parent, forProject: s.project) } catch WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder) { return true } catch { return false }
        return false
    }

    // MARK: P1 읽기 실패는 증명이 아니다

    @Test func aLedgerReadFailureKeepsThePinAndTheClosedMark() async throws {
        let s = try await setup()
        _ = await finishOneTurn(s)
        try await s.h.ledger.markSessionRetired(sessionID)
        // 원장이 읽히지 않는다 (닫힌 원장): 끝났다고 증명할 수 없다
        await s.h.ledger.close()
        await s.h.runtime.releaseWorkspaceIfRetired(session: sessionID)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "읽지 못하면 핀을 둔다 (`?? []`가 \"실행 없음\"이 되지 않는다)")
        #expect(overlapRefused(s))
        // 잊기도 원장을 읽지 못하면 아무것도 하지 않는다
        #expect(await s.h.runtime.forgetSessions(adapter: "agent:claude-code") == 0)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub)
        await s.h.runtime.releaseRetiredPins()
        #expect(s.r.registry.pinned(session: sessionID) == s.sub)
    }

    @Test func aRetiredSessionWithNoTaskRecordsAtAllProvesNothingAndKeepsItsPin() async throws {
        let s = try await setup()
        try await s.h.ledger.markSessionRetired(sessionID)
        await s.h.runtime.releaseWorkspaceIfRetired(session: sessionID)
        let marked = await retired(s)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub && marked == true)
    }

    // MARK: P2 예전 unproven

    @Test func stopThatCouldNotBeProvenThenARealEndThenRevokeThenTheParentFolderIsAccepted() async throws {
        let s = try await setup()
        s.h.agent.setInterruptResult(.unknown)
        let created = await startRunningTurn(s, endsByItself: true)
        _ = try #require(s.h.server.enqueueCancel(bridgeID: s.h.bridgeID, taskID: created.taskID))
        s.h.clock.jump(by: 6)
        await s.h.runtime.tick()
        #expect(await s.h.eventually(timeout: 30) { await s.h.task(created.taskID)?.cancelState == "unproven" })
        #expect(await s.h.task(created.taskID)?.alive == true, "중단을 증명하지 못했다: 아직 끝났다고 하지 않는다")
        // 프로세스가 정말 끝난다 (끝 증명)
        await s.h.clock.advance(by: 100_001) // 시계를 흘려 긴 기다림을 끝낸다 (jump는 시각만 옮긴다)
        await s.h.runtime.tick()
        #expect(await s.h.eventually(timeout: 30) { await s.h.task(created.taskID)?.alive == false })
        #expect(await s.h.task(created.taskID)?.cancelState == "requested", "끝이 증명되면 예전 unproven을 정산한다 (중단 의도만 남는다)")
        s.h.server.revoke(bridgeID: s.h.bridgeID)
        s.h.clock.jump(by: 31)
        await s.h.runtime.tick()
        #expect(await s.h.runtime.status == .revoked)
        #expect(s.r.registry.pinned(session: sessionID) == nil, "예전 unproven이 핀 풀기를 영구히 막지 않는다")
        let stored = try s.r.registry.setFolder(s.parent, forProject: s.project)
        #expect(stored == s.r.fixture.real("a"))
    }

    @Test func aStopThatIsStillUnprovenKeepsThePinEvenAfterTheRevoke() async throws {
        let s = try await setup()
        s.h.agent.setInterruptResult(.unknown)
        let created = await startRunningTurn(s)
        _ = try #require(s.h.server.enqueueCancel(bridgeID: s.h.bridgeID, taskID: created.taskID))
        s.h.clock.jump(by: 6)
        await s.h.runtime.tick()
        #expect(await s.h.eventually(timeout: 30) { await s.h.task(created.taskID)?.cancelState == "unproven" })
        s.h.server.revoke(bridgeID: s.h.bridgeID)
        s.h.clock.jump(by: 31)
        await s.h.runtime.tick()
        #expect(s.r.registry.pinned(session: sessionID) == s.sub && overlapRefused(s), "끝이 증명되지 않았다: 핀을 둔다")
        let marked = await retired(s)
        #expect(marked == true, "닫힘 표는 남는다")
    }

    // MARK: 닫힘 표는 원장에 남는다

    @Test func theClosedMarkSurvivesARestartAndTheProvenEndAfterItReleasesThePin() async throws {
        let s = try await setup()
        let created = await startRunningTurn(s)
        #expect(await s.h.runtime.forgetSessions(adapter: "agent:claude-code") == 1)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "돌고 있다: 핀을 둔다")
        let markedBefore = await retired(s)
        #expect(markedBefore == true)
        // 앱이 죽고 그 사이 프로세스가 끝났다
        _ = s.h.agent.abandon()
        await s.h.runtime.abandonForTest()
        s.h.agent.setLiveness(.ended(AgentExit(code: nil)))
        try await s.h.restart()
        await s.h.runtime.tick()
        #expect(await s.h.eventually(timeout: 30) { await s.h.task(created.taskID)?.alive == false })
        #expect(await s.h.eventually(timeout: 30) { s.r.registry.pinned(session: sessionID) == nil }, "다시 시작한 앱이 닫힘 표를 읽고 끝 증명 뒤에 푼다 (다음 잊기를 기다리지 않는다)")
        #expect(await s.h.eventually(timeout: 30) { await retired(s) == false }, "푼 뒤 표를 지운다")
    }

    @Test func aPinThatCouldNotBeWrittenAwayKeepsTheMarkSoTheNextSweepRetries() async throws {
        let s = try await setup()
        _ = await finishOneTurn(s)
        let partition = s.r.fixture.file.deletingLastPathComponent()
        let saved = partition.deletingLastPathComponent().appending(path: "saved-partition")
        try FileManager.default.moveItem(at: partition, to: saved) // 레지스트리가 쓰지 못한다
        #expect(await s.h.runtime.forgetSessions(adapter: "agent:claude-code") == 1)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "쓰지 못했다: 핀이 남는다")
        let kept = await retired(s)
        #expect(kept == true, "그래서 표도 남는다")
        try FileManager.default.moveItem(at: saved, to: partition)
        await s.h.runtime.releaseRetiredPins()
        #expect(s.r.registry.pinned(session: sessionID) == nil)
        let cleared = await retired(s)
        #expect(cleared == false)
    }

    @Test func thePruneSweepReleasesEndedRetiredPinsBeforeAnythingIsPrunedAndNeverPrunesAnUnreleasedOne() async throws {
        let s = try await setup()
        let created = await finishOneTurn(s)
        try await s.h.ledger.markSessionRetired(sessionID)
        // 정리는 task를 지우지만 닫힘 표가 있는 세션의 task는 지우지 않는다
        let later = s.h.clock.now.addingTimeInterval(8 * 86_400)
        let first = try await s.h.ledger.prune(now: later)
        let kept = try await s.h.ledger.task(created.taskID)
        #expect(first.tasks == 0 && kept != nil, "닫힘 표가 있는 동안 증명할 기록을 지우지 않는다")
        // 정리 직전의 훑기가 끝이 증명된 세션의 핀을 푼다 → 표가 지워져 이제 정리할 수 있다
        s.h.clock.jump(by: 3_700)
        await s.h.runtime.pruneIfDue()
        let afterSweep = await retired(s)
        #expect(s.r.registry.pinned(session: sessionID) == nil && afterSweep == false)
        let second = try await s.h.ledger.prune(now: later)
        #expect(second.tasks == 1, "푼 뒤에는 정리된다")
    }
}

/// 원장의 "영구히 닫힘" 표 (기존 `counters` 표의 `retired:<세션>` 줄, 스키마 변경 없음)
struct BridgeLedgerRetiredMarkTests {
    @Test func marksAreIdempotentCaseFoldedListedClearedAndSurviveReopening() async throws {
        let temp = TempDirectory()
        let ledger = try BridgeLedger(directory: temp.url)
        let id = "5E551011-0000-4000-8000-000000000001"
        let before = try await ledger.isSessionRetired(id)
        #expect(!before)
        try await ledger.markSessionRetired(id)
        try await ledger.markSessionRetired(id.lowercased())
        let upper = try await ledger.isSessionRetired(id)
        let lower = try await ledger.isSessionRetired(id.lowercased())
        let listed = try await ledger.retiredSessions()
        #expect(upper && lower && listed == [id.lowercased()])
        await ledger.close()
        let reopened = try BridgeLedger(directory: temp.url)
        let persisted = try await reopened.isSessionRetired(id)
        #expect(persisted, "다시 열어도 남는다")
        try await reopened.clearSessionRetired(id)
        try await reopened.clearSessionRetired(id)
        let afterClear = try await reopened.isSessionRetired(id)
        let left = try await reopened.retiredSessions()
        #expect(left.isEmpty && !afterClear)
    }

    @Test func theMarkDoesNotDisturbTheSessionNumberCountersOrThePruneOfThem() async throws {
        let temp = TempDirectory()
        let ledger = try BridgeLedger(directory: temp.url)
        try await ledger.markSessionRetired("5e551011-0000-4000-8000-000000000001")
        let report = try await ledger.prune(now: Date().addingTimeInterval(40 * 86_400))
        let still = try await ledger.isSessionRetired("5e551011-0000-4000-8000-000000000001")
        #expect(report.counters == 0 && still, "세션 번호표 정리는 닫힘 표를 건드리지 않는다")
    }
}
#endif
