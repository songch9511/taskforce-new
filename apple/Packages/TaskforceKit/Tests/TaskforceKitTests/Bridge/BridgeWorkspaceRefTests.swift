#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 서버에는 경로 대신 불투명 id만 간다 (OA D4a2-03), `.unknown` 중단 (D4a2-09), `forgetSession` (D4a2-08). 가짜 서버 · 가짜 agent · 임시 폴더만 쓴다 (실제 `claude` 0)
struct BridgeWorkspaceRefTests {
    static let otherSession = "5e551011-0000-4000-8000-0000000000b2"

    /// 등록부 resolver를 단 하네스: 세션 `BridgeHarness.sessionID`가 폴더 a에 핀 꽂혀 있다
    struct Rig {
        let h: BridgeHarness
        let fixture: WorkspaceRegistryTests.Fixture
        let registry: WorkspaceRegistry
        let resolver: RegistryWorkspaceResolver

        init(pinned: String? = "a") async throws {
            fixture = try WorkspaceRegistryTests.Fixture()
            registry = fixture.registry()
            let reads = WorkspaceRegistryResolverTests.Reads()
            resolver = RegistryWorkspaceResolver(registry: registry, sessions: reads, contexts: reads)
            if let pinned { try registry.pin(session: BridgeHarness.sessionID, to: fixture.folder(pinned)) }
            h = try BridgeHarness(workspace: nil)
            h.workspaces = resolver
            try await h.restart(reopenLedger: false)
            await h.registerFirst()
        }

        var path: String { fixture.real("a") }

        /// 모든 서버 요청 본문을 한 글로
        var wire: String { h.server.requests.map(\.bodyJSON).joined(separator: "\n") }

        func sessionBound() -> [String: Any]? {
            let events = h.server.requests("events").flatMap { ($0.json["events"] as? [[String: Any]]) ?? [] }
            return events.first { $0["type"] as? String == "session_bound" }?["payload"] as? [String: Any]
        }
    }

    // MARK: 보낼 때: 경로 → id

    @Test func sessionBoundCarriesTheOpaqueIDAndNeverTheFolderPath() async throws {
        let r = try await Rig()
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(first.taskID) == "idle" }
        #expect(r.h.agent.startedTurns.first?.workspaceRef == r.path, "adapter는 경로 그대로 받는다")
        let bound = try #require(r.sessionBound())
        let wireRef = try #require(bound["workspace_ref"] as? String)
        // 서버에는 가상 루트 `/taskforce/<ws_id>`가 간다 (13.11): 도구 판정의 `workspace_real_path`와 같은 값이어야 서버가 workspace_mismatch로 보지 않는다
        let ref = try #require(VirtualWorkspacePaths.ref(fromVirtualRoot: wireRef), "\(wireRef)")
        #expect(wireRef == "/taskforce/" + ref && WorkspaceRegistry.isOpaqueRef(ref) && r.registry.path(forRef: ref) == r.path)
        #expect(r.h.server.sessionState(BridgeHarness.sessionID)?.workspaceRef == wireRef)
        #expect(await r.h.task(first.taskID)?.workspaceRef == r.path, "원장은 경로 그대로다 (이 Mac 안)")
        // 가짜 서버가 받은 모든 본문에 경로 · 홈 이름이 0이다
        for needle in [r.path, r.fixture.home, "/Users/", "/private/var", r.fixture.temp.url.lastPathComponent, "Documents"] {
            #expect(!r.wire.contains(needle), "서버 본문에 \(needle)가 있다")
        }
    }

    @Test func aFolderTheRegistryDoesNotKnowIsNotSentAtAll() async throws {
        let r = try await Rig()
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: "/Users/someone/unregistered"), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(first.taskID) == "idle" }
        let bound = try #require(r.sessionBound())
        #expect(bound["workspace_ref"] == nil, "id가 없는 폴더는 workspace_ref를 보내지 않는다")
        #expect(!r.wire.contains("/Users/someone"))
    }

    /// 경로를 id인 척 돌려주는 resolver도 경로를 보내지 못한다 (런타임이 id 모양을 검사한다)
    private struct LeakyResolver: WorkspaceResolver {
        func workspace(forSession sessionID: String, adapter: String) async -> String? { "workspace-test" }
        func workspaceRef(forPath path: String) async -> String? { path }
    }

    @Test func aResolverThatReturnsAPathAsTheIDCannotLeakItToTheServer() async throws {
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = LeakyResolver()
        try await h.restart(reopenLedger: false)
        await h.registerFirst()
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: "/Users/me/secret-client"), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(first.taskID) == "idle" }
        #expect(!h.server.requests.map(\.bodyJSON).joined().contains("secret-client"))
        #expect(h.server.sessionState(BridgeHarness.sessionID)?.workspaceRef == nil)
    }

    @Test func aResolverWithoutMappingSendsNoFolderAtAll() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let first = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(first.taskID) == "idle" }
        #expect(h.server.sessionState(BridgeHarness.sessionID)?.workspaceRef == nil, "기본 resolver는 매핑이 없다: 가짜 agent의 workspace-fake도 가지 않는다")
    }

    // MARK: 받을 때: id → 경로 → authorize

    @Test func theIDTheServerGivesBackBecomesThePinnedFolderForTheNextTurn() async throws {
        let r = try await Rig()
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(first.taskID) == "idle" }
        let second = r.h.message(task: "7a5c0001-0000-4000-8000-0000000000f2", turn: 2)
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        let started = await r.h.eventually { r.h.agent.startedTurns.count == 2 }
        let refusal = await r.h.command(second.commandID)?.reason ?? "-"
        #expect(started, "\(refusal)")
        #expect(r.h.agent.startedTurns.last?.workspaceRef == r.path && r.h.agent.startedTurns.last?.resume == true)
    }

    @Test func anIDTheMacNeverIssuedIsRefusedAsUnauthorized() async throws {
        let r = try await Rig()
        r.h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: r.h.bridgeID, externalSessionID: "ext-1", workspaceRef: "/taskforce/ws_3f1c2c52-1111-4222-8333-444455556666")
        let created = r.h.message()
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(r.h.agent.startedTurns.isEmpty)
        #expect(await r.h.command(created.commandID)?.reason == "workspace_unauthorized")
    }

    /// `authorize`가 무엇이든 인정하는 resolver
    private struct ApproveEverything: WorkspaceResolver {
        func workspace(forSession sessionID: String, adapter: String) async -> String? { "workspace-test" }
        func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { true }
    }

    @Test func anIDNoResolverKnowsIsRefusedBeforeAuthorizeEvenForAResolverThatApprovesEverything() async throws {
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = ApproveEverything()
        try await h.restart(reopenLedger: false)
        await h.registerFirst()
        h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: h.bridgeID, externalSessionID: "ext-1", workspaceRef: "/taskforce/ws_3f1c2c52-1111-4222-8333-444455556666")
        let created = h.message()
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(h.agent.startedTurns.isEmpty, "모르는 id를 경로 글자 그대로 adapter에 넘기지 않는다")
        #expect(await h.command(created.commandID)?.reason == "workspace_unauthorized")
    }

    @Test func theIDOfAnotherSessionsFolderIsRefusedEvenThoughTheRegistryKnowsIt() async throws {
        let r = try await Rig()
        try r.registry.pin(session: Self.otherSession, to: r.fixture.folder("c"))
        let otherRef = try #require(r.registry.ref(forPath: r.fixture.real("c")))
        r.h.server.ensureSession(id: BridgeHarness.sessionID, bridgeID: r.h.bridgeID, externalSessionID: "ext-1", workspaceRef: VirtualWorkspacePaths.virtualRoot(forRef: otherRef))
        let created = r.h.message()
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(r.h.agent.startedTurns.isEmpty, "세션 A에 세션 B의 폴더를 시키지 못한다")
        #expect(await r.h.command(created.commandID)?.reason == "workspace_unauthorized")
    }

    @Test func aRawAbsolutePathFromTheServerCannotReviveAFolderTheRulesNowRefuseJustBecauseTheLedgerRecordedIt() async throws {
        let r = try await Rig()
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(first.taskID) == "idle" }
        #expect(await r.h.task(first.taskID)?.workspaceRef == r.path, "원장에는 이 경로가 적혀 있다")
        // 폴더가 홈 밖을 가리키는 기호 링크로 바뀌었다. 침해된 서버가 id 대신 원장에 적힌 경로 원문을 보낸다
        let outside = r.fixture.temp.appending("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: r.fixture.folder("a"))
        try FileManager.default.createSymbolicLink(atPath: r.fixture.folder("a"), withDestinationPath: outside.path)
        let second = r.h.message(
            task: "7a5c0001-0000-4000-8000-0000000000f3", turn: 2, extra: ["session": ["external_session_id": "ext-1", "workspace_ref": r.path, "resume": true]]
        )
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(r.h.agent.startedTurns.count == 1, "원장 기록으로 authorize의 거절을 뒤집지 못한다")
        #expect(await r.h.command(second.commandID)?.reason == "workspace_unauthorized")
    }

    @Test func theFolderTurnedIntoASymlinkToTheSystemAfterRegistrationIsRefusedOnTheNextTurn() async throws {
        let r = try await Rig()
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(first.taskID) == "idle" }
        // 등록한 폴더를 홈 밖을 가리키는 기호 링크로 바꾼다
        let outside = r.fixture.temp.appending("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: r.fixture.folder("a"))
        try FileManager.default.createSymbolicLink(atPath: r.fixture.folder("a"), withDestinationPath: outside.path)
        let second = r.h.message(task: "7a5c0001-0000-4000-8000-0000000000f4", turn: 2)
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(r.h.agent.startedTurns.count == 1)
        #expect(await r.h.command(second.commandID)?.reason == "workspace_unauthorized")
    }

    @Test func theOldAbsolutePathOfAPriorSessionIsStillApprovedWithADefaultResolver() async throws {
        // 옛 절대 경로 세션(R2 · loopback): 이 Mac의 기록과 같으면 인정한다 (기본 resolver)
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = FixedWorkspace(path: "workspace-test", authorized: [])
        try await h.restart(reopenLedger: false)
        await h.registerFirst()
        let path = "/private/var/work/project"
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(first.taskID) == "idle" }
        let second = h.message(task: "7a5c0001-0000-4000-8000-0000000000f5", turn: 2, extra: ["session": ["external_session_id": "ext-1", "workspace_ref": path, "resume": true]])
        h.clock.jump(by: 6)
        await h.runtime.tick()
        let started = await h.eventually { h.agent.startedTurns.count == 2 }
        let refusal = await h.command(second.commandID)?.reason ?? "-"
        #expect(started, "\(refusal)")
        #expect(h.agent.startedTurns.last?.workspaceRef == path)
    }

    // MARK: .unknown 중단

    @Test func anInterruptThatCouldNotBeProvenKeepsTheRunSupervisedAndAcksSentWithTheStateUnproven() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        h.agent.setInterruptResult(.unknown)
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        let cancel = try #require(h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID))
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(created.taskID)?.cancelState == "unproven" })
        let task = try #require(await h.task(created.taskID))
        #expect(task.alive && task.lastState != "cancelled", "신호를 증명하지 못하면 끝났다고 정리하지 않는다: \(task.lastState)")
        #expect(await h.runtime.isBusy(), "실행은 그대로 감독 · 잠근다")
        #expect(h.agent.liveRunCount == 1)
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == cancel.commandID && $0["op"] as? String == "complete" }
        #expect(acks.map { "\($0["op"] ?? "")/\($0["result"] ?? "")" } == ["complete/sent"], "ack는 sent 그대로다: \(acks)")
    }

    @Test func aSignalledInterruptStillRecordsSignalled() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(created.taskID)?.cancelState == "signalled" })
    }

    @Test func aNotRunningInterruptStillSettlesTheTaskAndNeverRecordsSignalledOrUnproven() async throws {
        let h = try BridgeHarness()
        h.agent.setScript(.staysRunning())
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        #expect(await h.eventually { (await h.command(created.commandID))?.state == .accepted })
        _ = h.agent.abandon() // 프로세스가 이미 사라졌다
        h.server.enqueueCancel(bridgeID: h.bridgeID, taskID: created.taskID)
        h.clock.jump(by: 6)
        await h.runtime.tick()
        #expect(await h.eventually { await h.task(created.taskID)?.alive == false }, "끝난 것으로 정리한다")
        let task = try #require(await h.task(created.taskID))
        #expect(task.cancelState == "requested", "중단 의도만 적혀 있다: \(String(describing: task.cancelState))")
        let acks = h.server.requests("ack").map(\.json).filter { $0["command_id"] as? String == created.commandID || $0["op"] as? String == "complete" }
        #expect(acks.contains { $0["op"] as? String == "complete" && $0["result"] as? String == "task_unknown" }, "돌고 있는 실행이 없으면 기록 없음으로 정산한다: \(acks)")
    }

    // MARK: forgetSession

    @Test func revokingTheMacMakesTheAdapterForgetEverySessionInTheLedger() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        let first = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(first.taskID) == "idle" }
        h.server.ensureSession(id: Self.otherSession, bridgeID: h.bridgeID)
        let second = h.message(session: Self.otherSession, task: "7a5c0001-0000-4000-8000-0000000000f6")
        h.clock.jump(by: 6)
        await h.runtime.tick()
        await h.settle { h.server.taskState(second.taskID) == "idle" }
        #expect(h.agent.forgottenSessions.isEmpty)
        h.server.revoke(bridgeID: h.bridgeID)
        h.clock.jump(by: 31)
        await h.runtime.tick()
        #expect(await h.runtime.status == .revoked)
        #expect(await h.eventually { Set(h.agent.forgottenSessions) == [BridgeHarness.sessionID, Self.otherSession] }, "\(h.agent.forgottenSessions)")
    }

    @Test func forgetSessionsCanBeLimitedToOneAdapterAndCallsEachSessionOnce() async throws {
        let h = try BridgeHarness()
        await h.registerFirst()
        for turn in 1...2 {
            let created = h.message(task: UUID().uuidString.lowercased(), turn: turn)
            h.clock.jump(by: 6)
            await h.runtime.tick()
            await h.settle { h.server.taskState(created.taskID) == "idle" }
        }
        #expect(await h.runtime.forgetSessions(adapter: "agent:codex") == 0)
        #expect(h.agent.forgottenSessions.isEmpty)
        #expect(await h.runtime.forgetSessions(adapter: "agent:claude-code") == 1, "세션은 한 번만 부른다")
        #expect(h.agent.forgottenSessions == [BridgeHarness.sessionID])
    }
}
#endif
