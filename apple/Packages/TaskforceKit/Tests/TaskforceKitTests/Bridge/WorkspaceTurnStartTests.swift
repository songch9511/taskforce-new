#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 턴 시작의 겹침 막기 (계약 13.13): 런타임이 접수 전에 막는다 — 기존 "Session didn't start"(`spawn_failed`) 길, 새 문구 없음. 가짜 서버 · 가짜 agent · 임시 폴더만 쓴다
struct WorkspaceTurnStartTests {
    private let sessionID = BridgeHarness.sessionID
    private let otherSession = "5e551011-0000-4000-8000-0000000000c3"

    private struct Setup {
        let r: BridgeWorkspaceRefTests.Rig
        let project: UUID
        let sub: String
        let parent: String
        var h: BridgeHarness { r.h }
    }

    /// 프로젝트가 `repo/sub`에 있고 세션 하나가 거기 핀 꽂혀 있다
    private func setup() async throws -> Setup {
        let r = try await BridgeWorkspaceRefTests.Rig(pinned: nil)
        let sub = r.fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let project = UUID()
        try r.registry.setFolder(sub, forProject: project)
        try r.registry.pin(session: sessionID, to: sub)
        return Setup(r: r, project: project, sub: GateFileSystem.realpath(sub) ?? sub, parent: r.fixture.folder("a"))
    }

    private func runTurn(_ s: Setup, session: String? = nil, task: String? = nil, turn: Int = 1, folder: String? = nil) async -> FakeBridgeServer.Created {
        s.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: folder ?? s.sub), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let created = s.h.message(session: session ?? sessionID, task: task ?? UUID().uuidString.lowercased(), turn: turn)
        s.h.clock.jump(by: 6)
        await s.h.runtime.tick()
        return created
    }

    private func started(_ created: FakeBridgeServer.Created, _ s: Setup) async -> Bool {
        await s.h.settle(timeout: 30) { s.h.server.taskState(created.taskID) == "idle" }
        return s.h.server.taskState(created.taskID) == "idle"
    }

    private func blocked(_ created: FakeBridgeServer.Created, _ s: Setup) async -> Bool {
        await s.h.settle(timeout: 30) { s.h.server.taskState(created.taskID) == "failed" }
        return s.h.server.taskState(created.taskID) == "failed"
    }

    @Test func aSessionInItsProjectsFolderRunsAndAfterTheProjectMovesToTheParentFolderItsOldSessionDoesNotStartWhileANewOneDoes() async throws {
        let s = try await setup()
        let first = await runTurn(s)
        #expect(await started(first, s), "프로젝트 폴더에서 도는 세션")
        // 프로젝트 폴더를 상위로 바꾼다: 옛 세션 핀과 상관없이 된다
        try s.r.registry.setFolder(s.parent, forProject: s.project)
        let again = await runTurn(s, turn: 2)
        #expect(await blocked(again, s), "옛 세션은 이어 갈 수 없다: 접수 전 실패 (Session didn't start)")
        #expect(s.h.agent.startedTurns.count == 1, "프로세스를 띄우지 않았다")
        // 새 세션은 새 폴더에서 된다
        try s.r.registry.pin(session: otherSession, to: s.parent)
        let fresh = await runTurn(s, session: otherSession, folder: s.r.fixture.real("a"))
        #expect(await started(fresh, s))
        #expect(s.h.agent.startedTurns.count == 2)
    }

    @Test func aFirstTurnWhoseResolvedFolderOverlapsAProjectsCurrentFolderDoesNotStartEither() async throws {
        let s = try await setup()
        try s.r.registry.setFolder(s.parent, forProject: s.project)
        // 서버가 폴더를 주지 않는 첫 턴 (새 세션): resolver가 핀 폴더를 돌려주지만 겹친다
        let created = s.h.message()
        s.h.clock.jump(by: 6)
        await s.h.runtime.tick()
        #expect(await blocked(created, s))
        #expect(s.h.agent.startedTurns.isEmpty)
    }

    @Test func aSessionThatOverlapsAnotherProjectsCurrentFolderIsBlockedButOneInAnUnrelatedFolderIsNot() async throws {
        let s = try await setup()
        let ok = await runTurn(s)
        #expect(await started(ok, s))
        // 프로젝트가 관계 없는 폴더로 옮겼다 → 옛 세션은 옛 폴더에서 계속 된다
        try s.r.registry.setFolder(s.r.fixture.folder("b"), forProject: s.project)
        let stillFine = await runTurn(s, turn: 2)
        #expect(await started(stillFine, s))
        // 다른 프로젝트가 옛 폴더를 품는 폴더를 쓴다 → 옛 세션은 막힌다
        try s.r.registry.setFolder(s.parent, forProject: UUID())
        let blockedTurn = await runTurn(s, turn: 3)
        #expect(await blocked(blockedTurn, s))
        #expect(s.h.agent.startedTurns.count == 2)
    }

    @Test func twoProjectsOnTheSameRealPathBothRunTheirSessions() async throws {
        let s = try await setup()
        try s.r.registry.setFolder(s.sub, forProject: UUID())
        try s.r.registry.pin(session: otherSession, to: s.sub)
        let one = await runTurn(s)
        let two = await runTurn(s, session: otherSession)
        let firstStarted = await started(one, s)
        let secondStarted = await started(two, s)
        #expect(firstStarted && secondStarted)
        #expect(s.h.agent.startedTurns.count == 2)
    }

    @Test func aRegistryThatCannotTellWhichFolderTheSessionIsPinnedToFailsClosed() async throws {
        let s = try await setup()
        // 이 세션의 핀을 모르는 레지스트리(깨진 파일을 다시 읽은 것과 같다): 서버가 준 폴더가 있어도 띄우지 않는다
        let empty = WorkspaceRegistry(file: s.r.fixture.temp.appending("empty-partition/workspaces.json"), rules: s.r.fixture.rules)
        #expect(!empty.sessionMayRun(in: s.sub, session: sessionID))
        let reads = WorkspaceRegistryResolverTests.Reads()
        let resolver = RegistryWorkspaceResolver(registry: empty, sessions: reads, contexts: reads)
        let allowed = await resolver.allowsTurn(in: s.sub, session: sessionID, adapter: "agent:claude-code")
        #expect(!allowed)
    }

    @Test func aLedgerThatCannotBeReadForgetsAndOpensNothing() async throws {
        let s = try await setup()
        _ = await runTurn(s)
        s.h.agent.setTerminalSession(AgentTerminalSession(
            providerSessionID: BridgeTerminalTargetTests.providerID, executableRealPath: BridgeTerminalTargetTests.executable, sessionCwd: BridgeTerminalTargetTests.cwd
        ))
        await s.h.ledger.close()
        #expect(await s.h.runtime.forgetSessions(adapter: "agent:claude-code") == 0, "어느 세션인지 모르면 잊지 않는다 (없다고 읽지 않는다)")
        #expect(s.h.agent.forgottenSessions.isEmpty)
    }
}
#endif
