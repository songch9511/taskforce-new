#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 검토 1 반영 (코디네이터 13.11): 지워진 파티션에는 쓰지 않는다(보안 F4) · 자격 폴더와 `$CLAUDE_CONFIG_DIR` 거절(I2) · 옮긴 `~/.claude`의 조상도 거절(Astra P2-5) ·
/// 핀 저장 실패는 닫는다(P2-6) · 돌고 있거나 중단을 증명하지 못한 세션은 터미널로 넘기지 않는다(I1)
struct WorkspaceRegistryReviewTests {
    // MARK: F4 지워진 파티션

    @Test func aWriteAfterThePartitionFolderIsGoneIsRefusedAndTheFolderIsNotBroughtBack() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        let project = UUID()
        try registry.setFolder(fixture.folder("a"), forProject: project)
        // 계정 삭제가 파티션 폴더를 지웠다
        let partition = fixture.file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: partition)
        #expect(throws: WorkspaceRegistry.RegistryError.writeFailed) { try registry.setFolder(fixture.folder("b"), forProject: UUID()) }
        #expect(throws: WorkspaceRegistry.RegistryError.writeFailed) { try registry.pin(session: "5e551011-0000-4000-8000-000000000001", to: fixture.folder("a")) }
        #expect(throws: WorkspaceRegistry.RegistryError.writeFailed) { try registry.setPending(fixture.folder("c"), conversation: UUID()) }
        #expect(!FileManager.default.fileExists(atPath: partition.path), "늦게 온 쓰기가 폴더도 옛 표도 되살리지 못한다")
        #expect(registry.folder(forProject: project) == fixture.real("a"), "실패한 쓰기는 표를 바꾸지 않는다")
    }

    // MARK: P2-6 핀 저장 실패

    private func resolver(_ f: WorkspaceRegistryResolverTests.Fixture, log: any BridgeLogSink) -> RegistryWorkspaceResolver {
        RegistryWorkspaceResolver(registry: f.registry, sessions: f.reads, contexts: f.reads, log: log)
    }

    @Test func aConversationFolderWhosePinCannotBeSavedMeansNoWorkspaceAndNoPin() async throws {
        let f = try WorkspaceRegistryResolverTests.Fixture()
        let log = CapturingLog()
        let conversation = UUID()
        f.link(project: UUID(), conversation: conversation)
        try f.registry.setPending(f.fixture.folder("c"), conversation: conversation)
        try FileManager.default.removeItem(at: f.fixture.file.deletingLastPathComponent())
        let found = await resolver(f, log: log).workspace(forSession: WorkspaceRegistryResolverTests.sessionID, adapter: "agent:claude-code")
        #expect(found == nil, "핀 없이 띄우면 다음 턴이 authorize에서 거절된다: 닫는다")
        #expect(f.registry.pinned(session: WorkspaceRegistryResolverTests.sessionID) == nil)
        #expect(log.events.contains("workspace_pin_failed"))
        #expect(!log.lines.joined().contains(f.fixture.home), "경로 원문은 로그에 없다")
    }

    @Test func aProjectFolderWhosePinCannotBeSavedMeansNoWorkspaceAndNoPin() async throws {
        let f = try WorkspaceRegistryResolverTests.Fixture()
        let project = UUID()
        f.link(project: project)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: project)
        try FileManager.default.removeItem(at: f.fixture.file.deletingLastPathComponent())
        #expect(await f.found() == nil)
        #expect(f.registry.pinned(session: WorkspaceRegistryResolverTests.sessionID) == nil)
    }

    @Test func aPinThatWasSavedIsReturnedAsTheRealPinNotTheRequestedPath() async throws {
        let f = try WorkspaceRegistryResolverTests.Fixture()
        let project = UUID()
        f.link(project: project)
        try f.registry.setFolder(f.fixture.folder("b"), forProject: project)
        #expect(await f.found() == f.fixture.real("b"))
        #expect(f.registry.pinned(session: WorkspaceRegistryResolverTests.sessionID) == f.fixture.real("b"))
    }

    // MARK: I2 자격 폴더 · CLAUDE_CONFIG_DIR

    private func rejection(_ path: String, rules: WorkspaceFolderRules) -> WorkspaceFolderRules.Rejection? {
        if case .failure(let why) = rules.validate(path) { return why }
        return nil
    }

    @Test func theSshAwsAndGnupgFoldersAreRejectedInsideAndAround() {
        let rules = WorkspaceRegistryRulesTests.standard()
        let home = WorkspaceRegistryRulesTests.home
        for name in [".ssh", ".aws", ".gnupg"] {
            #expect(rejection(home + "/" + name, rules: rules) == .credentials, "\(name)")
            #expect(rejection(home + "/" + name + "/keys/work", rules: rules) == .credentials, "안: \(name)")
        }
        #expect(rejection(home + "/.sshfoo", rules: rules) == nil, "글자 접두가 같은 형제는 받는다 (경로 성분으로 본다)")
        #expect(rejection(home + "/Documents/.ssh-notes", rules: rules) == nil)
    }

    @Test func theConfigFolderNamedByTheEnvironmentIsRejectedInsideAndAround() {
        let facts = WorkspaceRegistryRulesTests.facts()
        let rules = WorkspaceFolderRules(
            home: WorkspaceRegistryRulesTests.home, extraClaudeConfig: "/Volumes/Disk/team/claude-config", systemRoots: [], protectedRoots: [], facts: facts
        )
        #expect(rejection("/Volumes/Disk/team/claude-config", rules: rules) == .claudeConfig)
        #expect(rejection("/Volumes/Disk/team/claude-config/projects", rules: rules) == .claudeConfig)
        #expect(rejection("/Volumes/Disk/team", rules: rules) == .claudeConfig, "설정 폴더를 품는 폴더")
        #expect(rejection("/Volumes/Disk/team-other", rules: rules) == nil)
    }

    @Test func theStandardRulesReadTheClaudeConfigDirFromTheEnvironmentAndIgnoreARelativeOne() {
        let withEnv = WorkspaceFolderRules.standard(home: "/Users/tester", protectedRoots: [], environment: ["CLAUDE_CONFIG_DIR": "/Volumes/Disk/cfg"])
        #expect(withEnv.denyAround.contains { $0.root == "/Volumes/Disk/cfg" && $0.why == .claudeConfig })
        let relative = WorkspaceFolderRules.standard(home: "/Users/tester", protectedRoots: [], environment: ["CLAUDE_CONFIG_DIR": "cfg"])
        #expect(!relative.denyAround.contains { $0.root.hasSuffix("cfg") })
        let none = WorkspaceFolderRules.standard(home: "/Users/tester", protectedRoots: [], environment: [:])
        #expect(none.denyAround.contains { $0.why == .credentials } && none.denyAround.contains { $0.why == .claudeConfig })
    }

    // MARK: P2-5 옮긴 ~/.claude

    @Test func aClaudeFolderMovedBehindASymlinkRejectsItsRealPathItsAncestorsAndAnyAlias() throws {
        let temp = TempDirectory()
        let home = temp.appending("home")
        let store = home.appending(path: "Documents/store")
        let realClaude = store.appending(path: "claude-real")
        for url in [realClaude, home.appending(path: "Documents/project")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // ~/.claude 는 다른 곳의 폴더로 가는 기호 링크다
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.claude", withDestinationPath: realClaude.path)
        let alias = home.appending(path: "Documents/alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: realClaude.path)
        let rules = WorkspaceFolderRules(home: home.path, systemRoots: [])
        #expect(rejection(home.path + "/.claude", rules: rules) == .claudeConfig)
        #expect(rejection(realClaude.path, rules: rules) == .claudeConfig, "실제 위치")
        #expect(rejection(store.path, rules: rules) == .claudeConfig, "옮긴 설정 폴더를 품는 조상도 받지 않는다")
        #expect(rejection(alias.path, rules: rules) == .claudeConfig, "기호 링크 별칭")
        #expect(rejection(home.path + "/Documents/project", rules: rules) == nil, "관계 없는 폴더는 받는다")
    }

    @Test func aFolderThatContainsTheEnvironmentsClaudeConfigThroughASymlinkIsRejected() throws {
        let temp = TempDirectory()
        let home = temp.appending("home")
        let shared = home.appending(path: "Documents/shared")
        let config = shared.appending(path: "cfg")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let link = temp.appending("cfg-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: config.path)
        let rules = WorkspaceFolderRules(home: home.path, extraClaudeConfig: link.path, systemRoots: [])
        #expect(rejection(shared.path, rules: rules) == .claudeConfig, "환경 변수가 기호 링크로 가리킨 실제 폴더를 품는 조상")
    }
}

/// I1: 돌고 있는 턴이나 중단을 증명하지 못한 턴이 있으면 Open in Terminal의 값은 nil이다 (서버 `busy`에만 기대지 않는다)
struct BridgeTerminalTargetGuardTests {
    private var session: UUID { UUID(uuidString: BridgeHarness.sessionID)! }

    /// 접수한 뒤 계속 도는 턴 (작업 폴더는 이 Mac이 인정하는 폴더라, 터미널 값이 nil인 이유가 폴더가 아니라 도는 턴뿐이게 한다)
    private static func staysRunningInTheFolder(_ r: BridgeWorkspaceRefTests.Rig) -> FakeAgentProcess.Script {
        FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .progress, .wait(100_000)])
    }

    private func rig() async throws -> BridgeWorkspaceRefTests.Rig {
        let r = try await BridgeWorkspaceRefTests.Rig()
        let terminal = AgentTerminalSession(
            providerSessionID: BridgeTerminalTargetTests.providerID, executableRealPath: BridgeTerminalTargetTests.executable, sessionCwd: BridgeTerminalTargetTests.cwd
        )
        r.h.agent.setTerminalSession(terminal)
        r.h.agent.setScript(FakeAgentProcess.Script([.sessionBound(external: "ext-1", workspace: r.path), .accepted, .turnCompleted, .end(AgentExit(code: 0))]))
        let first = r.h.message()
        await r.h.runtime.tick()
        await r.h.settle { r.h.server.taskState(first.taskID) == "idle" }
        return r
    }

    @Test func aFinishedSessionHasATargetAndARunningTurnTakesItAway() async throws {
        let r = try await rig()
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) != nil, "끝난 세션")
        r.h.agent.setScript(Self.staysRunningInTheFolder(r))
        let second = r.h.message(task: "7a5c0001-0000-4000-8000-0000000000f7", turn: 2)
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(await r.h.eventually { (await r.h.command(second.commandID))?.state == .accepted })
        #expect(await r.h.task(second.taskID)?.alive == true)
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) == nil, "이 Mac이 돌고 있다고 보는 턴이 있으면 터미널로 넘기지 않는다")
    }

    @Test func aTurnWhoseInterruptCouldNotBeProvenKeepsTheTargetAway() async throws {
        let r = try await rig()
        r.h.agent.setScript(Self.staysRunningInTheFolder(r))
        r.h.agent.setInterruptResult(.unknown)
        let second = r.h.message(task: "7a5c0001-0000-4000-8000-0000000000f8", turn: 2)
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(await r.h.eventually { (await r.h.command(second.commandID))?.state == .accepted })
        r.h.server.enqueueCancel(bridgeID: r.h.bridgeID, taskID: second.taskID)
        r.h.clock.jump(by: 6)
        await r.h.runtime.tick()
        #expect(await r.h.eventually { await r.h.task(second.taskID)?.cancelState == "unproven" })
        #expect(await r.h.runtime.terminalTarget(forAgentSession: session) == nil)
    }
}
#endif
