#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// Open in Terminal · Resume here가 이 Mac 상태에서 읽는 값 (OA D4a2-06 · 07): Claude 세션 id는 adapter 상태, 작업 폴더는 원장 + 등록부(resolver가 지금도 인정할 때만).
/// 서버가 준 `external_session_id`는 쓰지 않는다. 가짜 서버 · 가짜 agent · 임시 폴더만 쓴다 (실제 `claude` · 터미널 0)
struct BridgeTerminalTargetTests {
    static let providerID = "c0ffee00-0000-4000-8000-000000000001"
    static let executable = "/Users/tester/.local/share/claude/versions/2.1.241"

    /// 세션 하나가 폴더 a에 핀 꽂혀 있고 한 턴을 마친 하네스. 가짜 agent는 터미널 값을 돌려준다
    private func rig(terminal: AgentTerminalSession? = AgentTerminalSession(providerSessionID: providerID, executableRealPath: executable)) async throws -> BridgeWorkspaceRefTests.Rig {
        let r = try await BridgeWorkspaceRefTests.Rig()
        r.h.agent.setTerminalSession(terminal)
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let created = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(created.taskID) == "idle" }
        return r
    }

    private var session: UUID { UUID(uuidString: BridgeHarness.sessionID)! }

    @Test func theTargetIsTheClaudeIDTheRealExecutableAndTheFolderTheMacRecorded() async throws {
        let r = try await rig()
        let target = try #require(await r.h.runtime.terminalTarget(forAgentSession: session))
        #expect(target == AgentTerminalTarget(providerSessionID: Self.providerID, folder: r.path, executableRealPath: Self.executable))
        #expect(await r.h.runtime.providerSessionID(forAgentSession: session) == Self.providerID)
        // 서버가 준 external_session_id("ext-1")는 쓰지 않는다
        #expect(target.providerSessionID != "ext-1")
    }

    @Test func noMacStateMeansNoTargetAndNoProviderID() async throws {
        let r = try await rig(terminal: nil)
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) == nil, "adapter 상태가 묶이지 않았다")
        #expect(await r.h.runtime.providerSessionID(forAgentSession: session) == nil)
        // 이 Mac이 모르는 세션
        #expect(await r.h.runtime.terminalTarget(forAgentSession: UUID()) == nil)
        #expect(await r.h.runtime.providerSessionID(forAgentSession: UUID()) == nil)
    }

    @Test func aFolderTheResolverNoLongerApprovesOrThatIsGoneMeansNoTarget() async throws {
        let r = try await rig()
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) != nil)
        // 폴더가 홈 밖을 가리키는 기호 링크로 바뀌었다: 규칙을 다시 본 resolver가 거절한다
        let outside = r.fixture.temp.appending("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: r.fixture.folder("a"))
        try FileManager.default.createSymbolicLink(atPath: r.fixture.folder("a"), withDestinationPath: outside.path)
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) == nil)
        // 핀 폴더 자체가 지워졌다
        try FileManager.default.removeItem(atPath: r.fixture.folder("a"))
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) == nil)
    }

    @Test func withoutAResolverTheMacHasNoFolderItApprovedSoThereIsNoTarget() async throws {
        let h = try BridgeHarness(workspace: nil)
        h.agent.setTerminalSession(AgentTerminalSession(providerSessionID: Self.providerID, executableRealPath: Self.executable))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "failed" } // resolver가 없어 접수 전 spawn_failed
        #expect(await h.runtime.terminalTarget(forAgentSession: session) == nil)
    }

    /// 무엇이든 인정하고 폴더 대신 파일을 가리키는 resolver (런타임이 디렉터리인지를 따로 본다)
    private struct ApprovesAFile: WorkspaceResolver {
        let path: String
        func workspace(forSession sessionID: String, adapter: String) async -> String? { path }
        func authorize(workspaceRef: String, session sessionID: String, adapter: String) async -> Bool { true }
    }

    @Test func aPathThatIsNotAFolderMeansNoTargetEvenWhenTheResolverApprovesIt() async throws {
        let temp = TempDirectory()
        let file = temp.appending("notes.txt")
        try Data("x".utf8).write(to: file)
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = ApprovesAFile(path: file.path)
        try await h.restart(reopenLedger: false)
        h.agent.setTerminalSession(AgentTerminalSession(providerSessionID: Self.providerID, executableRealPath: Self.executable))
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: file.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        #expect(await h.task(created.taskID)?.workspaceRef == file.path, "원장에는 resolver가 정한 값이 적혀 있다")
        #expect(await h.runtime.terminalTarget(forAgentSession: session) == nil)
    }

    @Test func theLauncherWritesTheGoldenLineFromTheRuntimeTargetAndOpensItOnce() async throws {
        let r = try await rig()
        let temp = TempDirectory()
        let opener = AgentTerminalCommandFileTests.FakeOpener()
        let runtime = r.h.runtime
        let launcher = CommandFileTerminalLauncher(
            target: { await runtime.terminalTarget(forAgentSession: $0) }, store: AgentTerminalCommandStore(directory: temp.appending("Terminal")), opener: opener
        )
        #expect(await launcher.canOpen(sessionID: session))
        try await launcher.open(sessionID: session)
        let file = try #require(opener.opened.first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "#!/bin/sh\ncd '\(r.path)' && exec '\(Self.executable)' --resume '\(Self.providerID)'\n")
        #expect(try AgentTerminalCommandFileTests.mode(file) == 0o700)
    }

    @Test func aFolderNameThatCannotBeQuotedMakesTheLauncherRefuseBeforeAnyServerCall() async throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let quoted = fixture.home + "/Documents/it's here"
        try FileManager.default.createDirectory(atPath: quoted, withIntermediateDirectories: true)
        let registry = fixture.registry()
        let reads = WorkspaceRegistryResolverTests.Reads()
        let resolver = RegistryWorkspaceResolver(registry: registry, sessions: reads, contexts: reads)
        try registry.pin(session: BridgeHarness.sessionID, to: quoted)
        let h = try BridgeHarness(workspace: nil)
        h.workspaces = resolver
        try await h.restart(reopenLedger: false)
        h.agent.setTerminalSession(AgentTerminalSession(providerSessionID: Self.providerID, executableRealPath: Self.executable))
        let real = GateFileSystem.realpath(quoted) ?? quoted
        h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: real), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        await h.registerFirst()
        let created = h.message()
        await h.runtime.tick()
        await h.settle { h.server.taskState(created.taskID) == "idle" }
        let runtime = h.runtime
        let temp = TempDirectory()
        let launcher = CommandFileTerminalLauncher(
            target: { await runtime.terminalTarget(forAgentSession: $0) }, store: AgentTerminalCommandStore(directory: temp.appending("Terminal")),
            opener: AgentTerminalCommandFileTests.FakeOpener()
        )
        #expect(await runtime.terminalTarget(forAgentSession: UUID(uuidString: BridgeHarness.sessionID)!) != nil, "폴더는 인정된다")
        #expect(await !launcher.canOpen(sessionID: UUID(uuidString: BridgeHarness.sessionID)!), "인용을 통과하지 못하면 미리 조건이 false다")
    }
}
#endif
