#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 옛 세션 핀이 정상적인 폴더 변경을 영구히 막지 않는다 (재검토 2, Astra): 세션이 영구히 닫혔고(폐기됨 · 잊음) 프로세스의 끝이 증명되면 핀과 남은 대화 폴더 참조를 푼다.
/// 끝을 증명하지 못한 세션(`unproven` · `unknown` · 아직 도는 중)의 핀은 둔다 — 증명 못 한 것을 끝났다고 하지 않는다. 가짜 서버 · 가짜 agent · 임시 폴더만 쓴다
struct WorkspacePinReleaseTests {
    private let sessionID = BridgeHarness.sessionID

    private struct Setup {
        let r: BridgeWorkspaceRefTests.Rig
        let project: UUID
        let sub: String
        let parent: String
    }

    /// 프로젝트가 `repo/sub`에 있고 세션도 거기 핀 꽂혀 있다
    private func setup() async throws -> Setup {
        let r = try await BridgeWorkspaceRefTests.Rig(pinned: nil)
        let sub = r.fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let project = UUID()
        try r.registry.setFolder(sub, forProject: project)
        try r.registry.pin(session: sessionID, to: sub)
        return Setup(r: r, project: project, sub: GateFileSystem.realpath(sub) ?? sub, parent: r.fixture.folder("a"))
    }

    private func runningScript(_ s: Setup) -> FakeAgentProcess.Script {
        FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: s.sub), .accepted, .progress, .wait(100_000)])
    }

    private func finishOneTurn(_ s: Setup) async {
        s.r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: s.sub), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let created = s.r.h.message()
        await s.r.h.runtime.tick()
        await s.r.h.settle { s.r.h.server.taskState(created.taskID) == "idle" }
    }

    private func startRunningTurn(_ s: Setup) async throws -> FakeBridgeServer.Created {
        s.r.h.agent.setScript(runningScript(s))
        let created = s.r.h.message()
        await s.r.h.runtime.tick()
        #expect(await s.r.h.eventually(timeout: 30) { (await s.r.h.command(created.commandID))?.state == .accepted })
        return created
    }

    private func revoke(_ s: Setup) async {
        s.r.h.server.revoke(bridgeID: s.r.h.bridgeID)
        s.r.h.clock.jump(by: 31)
        await s.r.h.runtime.tick()
    }

    private func overlapRefused(_ s: Setup) -> Bool {
        do { try s.r.registry.setFolder(s.parent, forProject: s.project) } catch WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder) { return true } catch { return false }
        return false
    }

    // MARK: 폐기 → 끝 → 재연결 → 상위 폴더

    @Test func revokedThenEndedThenReconnectedThenTheParentFolderIsAccepted() async throws {
        let s = try await setup()
        await finishOneTurn(s)
        #expect(overlapRefused(s), "아직 살아 있는 Mac의 세션 핀이 겹침으로 센다")
        await revoke(s)
        #expect(await s.r.h.runtime.status == .revoked)
        #expect(s.r.registry.pinned(session: sessionID) == nil, "폐기 + 끝 증명 → 핀을 푼다")
        #expect(await s.r.h.runtime.reactivate())
        let stored = try s.r.registry.setFolder(s.parent, forProject: s.project)
        #expect(stored == s.r.fixture.real("a") && s.r.registry.folder(forProject: s.project) == stored, "정상적인 폴더 변경이 된다")
    }

    @Test func aRunningTurnThatEndsAfterTheRevokeReleasesThePinWhenItsEndIsProven() async throws {
        let s = try await setup()
        let created = try await startRunningTurn(s)
        await revoke(s)
        #expect(await s.r.h.eventually(timeout: 30) { await s.r.h.task(created.taskID)?.alive == false }, "폐기가 돌고 있던 턴을 끝냈다")
        #expect(await s.r.h.eventually(timeout: 30) { s.r.registry.pinned(session: sessionID) == nil }, "끝이 증명되는 순간 핀을 푼다")
        #expect(!overlapRefused(s))
    }

    @Test func aTurnWhoseEndCouldNotBeProvenKeepsThePinAndTheOverlapRefusal() async throws {
        let s = try await setup()
        s.r.h.agent.setInterruptResult(.unknown)
        let created = try await startRunningTurn(s)
        await revoke(s)
        #expect(await s.r.h.task(created.taskID)?.alive == true, "중단을 증명하지 못했다: 끝났다고 하지 않는다")
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "핀을 둔다")
        #expect(overlapRefused(s), "그래서 겹침 거절도 그대로다")
    }

    // MARK: 잊기 (Disconnect)

    @Test func forgettingAnEndedSessionReleasesItsPinAndAFreshSessionNeverForgottenKeepsIt() async throws {
        let s = try await setup()
        await finishOneTurn(s)
        try s.r.registry.pin(session: Self.otherSession, to: s.sub)
        #expect(await s.r.h.runtime.forgetSessions(adapter: "agent:claude-code") == 1)
        #expect(s.r.registry.pinned(session: sessionID) == nil, "원장에 있던 끝난 세션의 핀을 푼다")
        #expect(s.r.registry.pinned(session: Self.otherSession) == s.sub, "원장에 없는 세션(이 Mac이 모르는)의 핀은 건드리지 않는다")
        // 다른 adapter만 잊으면 이 adapter의 세션은 그대로다
        let t = try await setup()
        await finishOneTurn(t)
        #expect(await t.r.h.runtime.forgetSessions(adapter: "agent:codex") == 0)
        #expect(t.r.registry.pinned(session: sessionID) == t.sub)
    }

    @Test func forgettingALiveSessionKeepsThePinUntilItsEndIsProven() async throws {
        let s = try await setup()
        let created = try await startRunningTurn(s)
        #expect(await s.r.h.runtime.forgetSessions(adapter: "agent:claude-code") == 1)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "돌고 있는 동안은 둔다")
        #expect(overlapRefused(s))
        s.r.h.server.enqueueCancel(bridgeID: s.r.h.bridgeID, taskID: created.taskID)
        s.r.h.clock.jump(by: 6)
        await s.r.h.runtime.tick()
        #expect(await s.r.h.eventually(timeout: 30) { await s.r.h.task(created.taskID)?.alive == false })
        #expect(await s.r.h.eventually(timeout: 30) { s.r.registry.pinned(session: sessionID) == nil }, "끝이 증명되면 잊어 둔 세션의 핀을 푼다")
        #expect(!overlapRefused(s))
    }

    @Test func anAnswerThatCannotBeDeliveredToAForgottenSessionReleasesItsPinWhenTheLedgerSettlesIt() async throws {
        let s = try await setup()
        let question = AgentQuestion(providerRequestID: "req-1", kind: .input, structured: false, text: "Name?", items: [AgentQuestionItem(id: "q", header: "", text: "Name?", options: [])])
        s.r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: s.sub), .accepted, .question(question), .awaitAnswer]))
        let created = s.r.h.message()
        await s.r.h.runtime.tick()
        await s.r.h.settle { (try? await s.r.h.ledger.task(created.taskID))?.openRequestID == "req-1" }
        #expect(await s.r.h.runtime.forgetSessions(adapter: "agent:claude-code") == 1)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "답을 기다리며 살아 있다: 핀을 둔다")
        s.r.h.agent.setAnswersFail(true)
        _ = try #require(s.r.h.server.enqueueAnswer(bridgeID: s.r.h.bridgeID, taskID: created.taskID, requestID: "req-1", answerText: "x", structured: false))
        s.r.h.clock.jump(by: 6)
        await s.r.h.runtime.tick()
        #expect(await s.r.h.eventually(timeout: 30) { await s.r.h.task(created.taskID)?.alive == false }, "전달하지 못한 답의 정산이 task를 끝냈다")
        #expect(await s.r.h.eventually(timeout: 30) { s.r.registry.pinned(session: sessionID) == nil }, "그 끝이 증명되는 순간 핀을 푼다")
    }

    @Test func aSessionNobodyForgotKeepsItsPinWhenItsTurnEnds() async throws {
        let s = try await setup()
        await finishOneTurn(s)
        #expect(s.r.registry.pinned(session: sessionID) == s.sub, "끝나기만 한 세션은 이어 쓸 수 있다")
    }

    static let otherSession = "5e551011-0000-4000-8000-0000000000c3"
}

/// 레지스트리: 핀 풀기와 남은 대화 폴더 참조
struct WorkspacePinReleaseRegistryTests {
    private let session = "5e551011-0000-4000-8000-000000000001"

    private func nested(_ fixture: WorkspaceRegistryTests.Fixture) throws -> String {
        let sub = fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        return sub
    }

    @Test func releasingASessionDropsItsPinAndTheConversationFolderItCameFromAndFreesTheOverlap() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let sub = try nested(fixture)
        let registry = fixture.registry()
        let conversation = UUID()
        let other = UUID()
        try registry.setPending(sub, conversation: conversation)
        try registry.pin(session: session, to: sub, conversation: conversation)
        try registry.setPending(sub, conversation: other) // 같은 폴더를 고른 다른 대화 (세션 없음)
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.folder("a"), forProject: UUID()) }
        #expect(registry.releaseSession(session))
        #expect(registry.pinned(session: session) == nil && registry.pending(conversation: conversation) == nil, "핀과 그 세션을 만든 대화 참조를 푼다")
        #expect(registry.pending(conversation: other) == fixture.real("a") + "/sub", "다른 대화가 고른 폴더는 건드리지 않는다")
        // 다른 대화의 폴더가 남아 있으니 아직 겹침이다
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.folder("a"), forProject: UUID()) }
        registry.removePending(conversation: other)
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
    }

    @Test func releaseSurvivesARestartAndAnUnknownSessionIsANoOp() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let sub = try nested(fixture)
        let registry = fixture.registry()
        let conversation = UUID()
        try registry.setPending(sub, conversation: conversation)
        try registry.pin(session: session, to: sub, conversation: conversation)
        #expect(fixture.registry().pinned(session: session) == fixture.real("a") + "/sub", "핀을 파일에 쓴다")
        #expect(!registry.releaseSession("5e551011-0000-4000-8000-0000000000ff"), "모르는 세션")
        // 다시 시작한 앱(새 인스턴스)이 파일에서 연결을 읽어 대화 폴더 참조까지 푼다
        let restarted = fixture.registry()
        #expect(restarted.releaseSession(session.uppercased()), "세션 id는 대소문자를 가리지 않는다")
        #expect(restarted.pinned(session: session) == nil && restarted.pending(conversation: conversation) == nil, "연결을 파일에 썼다")
        let again = fixture.registry()
        #expect(again.pinned(session: session) == nil && again.pending(conversation: conversation) == nil, "푼 것을 파일에 썼다")
        #expect(!again.releaseSession(session), "두 번째는 할 일이 없다")
    }

    @Test func aFileWrittenBeforeTheConversationLinkExistedStillReads() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let ref = "ws_3f1c2c52-1111-4222-8333-444455556666"
        let text = #"{"v":1,"refs":{"\#(ref)":"\#(fixture.real("a"))"},"projects":{},"sessions":{"\#(session)":"\#(ref)"},"pending":{}}"#
        try Data(text.utf8).write(to: fixture.file)
        let registry = fixture.registry()
        #expect(registry.pinned(session: session) == fixture.real("a"))
        #expect(registry.releaseSession(session) && registry.pinned(session: session) == nil)
    }

    @Test func aWriteThatFailsLeavesThePinInPlace() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.pin(session: session, to: fixture.folder("a"))
        try FileManager.default.removeItem(at: fixture.file.deletingLastPathComponent()) // 파티션 폴더가 없어 쓰지 못한다
        #expect(!registry.releaseSession(session))
        #expect(registry.pinned(session: session) == fixture.real("a"), "쓰지 못하면 핀을 둔다 (안전한 쪽)")
    }

    @Test func theResolverRemembersTheConversationWhenItPinsFromAConversationFolderAndReleasesBoth() async throws {
        let f = try WorkspaceRegistryResolverTests.Fixture()
        let sub = f.fixture.folder("a") + "/sub"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let conversation = UUID()
        f.link(project: UUID(), conversation: conversation)
        try f.registry.setPending(sub, conversation: conversation)
        #expect(await f.found() == f.fixture.real("a") + "/sub")
        #expect(f.registry.pinned(session: WorkspaceRegistryResolverTests.sessionID) != nil)
        await f.resolver.releaseSession(WorkspaceRegistryResolverTests.sessionID)
        #expect(f.registry.pinned(session: WorkspaceRegistryResolverTests.sessionID) == nil && f.registry.pending(conversation: conversation) == nil)
        try f.registry.setFolder(f.fixture.folder("a"), forProject: UUID())
    }
}
#endif
