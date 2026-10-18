#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 재검토 1 반영 (코디네이터 13.12, Astra 1 · 2): 겹치는 작업 폴더는 받지 않는다(같은 파일이 폴더마다 다른 가상 경로가 되어 서버의 경로 잠금이 갈라진다) ·
/// 민감 디렉터리 이름(`.git` · `.claude` …)이 성분에 든 폴더는 받지 않는다(가상 루트에서 그 성분이 사라져 서버의 `tool_config_write` 확인이 빠진다). 임시 폴더만 쓴다
struct WorkspaceOverlapTests {
    private func nested(_ fixture: WorkspaceRegistryTests.Fixture) throws {
        try FileManager.default.createDirectory(atPath: fixture.folder("a") + "/sub/deep", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: fixture.folder("a-other"), withIntermediateDirectories: true)
    }

    @Test func aFolderThatContainsOrIsInsideARegisteredFolderIsRefused() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.folder("a") + "/sub", forProject: UUID()) }
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.folder("a") + "/sub/deep", forProject: UUID()) }
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.home + "/Documents", forProject: UUID()) }
        #expect(registry.projectFolders().count == 1, "거절한 폴더는 표에 없다")
    }

    @Test func theSameRealPathForTwoProjectsIsAllowedAndSharesOneID() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        // 기호 링크 별칭도 같은 실제 경로다
        let alias = fixture.home + "/Documents/alias-of-a"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: fixture.folder("a"))
        try registry.setFolder(alias, forProject: UUID())
        try registry.setPending(fixture.folder("a"), conversation: UUID())
        #expect(Set(registry.projectFolders().values) == [fixture.real("a")])
        let ref = try #require(registry.ref(forPath: fixture.real("a")))
        #expect(WorkspaceRegistry.isOpaqueRef(ref))
    }

    @Test func siblingsAndFoldersWithTheSameNamePrefixAreNotOverlapping() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        try registry.setFolder(fixture.folder("b"), forProject: UUID())
        try registry.setFolder(fixture.folder("a-other"), forProject: UUID())
        #expect(registry.projectFolders().count == 3)
    }

    @Test func sessionPinsAndConversationFoldersCountAsRegisteredFoldersToo() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.pin(session: "5e551011-0000-4000-8000-000000000001", to: fixture.folder("a") + "/sub")
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.folder("a"), forProject: UUID()) }
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setPending(fixture.folder("a"), conversation: UUID()) }
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.pin(session: "5e551011-0000-4000-8000-000000000002", to: fixture.folder("a")) }
        // 이미 핀이 있는 세션의 핀은 바꾸지 않으므로 겹침 검사로 던지지 않는다
        try registry.pin(session: "5e551011-0000-4000-8000-000000000001", to: fixture.folder("a"))
        #expect(registry.pinned(session: "5e551011-0000-4000-8000-000000000001") == fixture.real("a") + "/sub")
    }

    @Test func aProjectMayMoveItsOwnFolderIntoItsOldFolderAndAFreedFolderOverlapsNoMore() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        let project = UUID()
        let other = UUID()
        try registry.setFolder(fixture.folder("a"), forProject: project)
        try registry.setFolder(fixture.folder("a") + "/sub", forProject: project) // 자기 옛 폴더 안으로: 옛 폴더는 더 쓰이지 않는다
        #expect(registry.folder(forProject: project) == fixture.real("a") + "/sub")
        #expect(throws: WorkspaceRegistry.RegistryError.rejected(.overlapsRegisteredFolder)) { try registry.setFolder(fixture.folder("a"), forProject: other) }
        registry.removeFolder(forProject: project)
        try registry.setFolder(fixture.folder("a"), forProject: other)
        #expect(registry.folder(forProject: other) == fixture.real("a"))
    }

    @Test func thePickerSeesOverlapAsNotAcceptedWithTheApprovedSentenceAndSensitiveWithItsOwn() throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        try FileManager.default.createDirectory(atPath: fixture.folder("b") + "/.git", withIntermediateDirectories: true)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        #expect(!registry.accepts(path: fixture.folder("a") + "/sub") && registry.accepts(path: fixture.folder("a")) && registry.accepts(path: fixture.folder("b")))
        #expect(registry.rejectionMessage(forPath: fixture.folder("a") + "/sub") == "Another project already uses this folder or one inside it.")
        #expect(registry.rejectionMessage(forPath: fixture.folder("b") + "/.git") == "Choose a project folder, not a .git or settings folder.")
        #expect(registry.rejectionMessage(forPath: fixture.home) == AgentWorkspaceCopy.rejected, "그 밖의 거절은 일반 문구")
        #expect(registry.rejectionMessage(forPath: fixture.folder("missing")) == AgentWorkspaceCopy.rejected)
    }

    /// 이유별 문구를 받는 폴더 창 대역
    @MainActor
    private final class ReasonPicker: AgentWorkspacePicking {
        var reason: (@Sendable (String) -> String)?
        var accepts: (@Sendable (String) -> Bool)?

        func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String? { nil }

        func pickFolder(
            message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool, reason: @escaping @Sendable (String) -> String
        ) async -> String? {
            self.reason = reason
            self.accepts = accepts
            return nil
        }
    }

    @MainActor
    @Test func theSendGateHandsThePickerTheRegistrysOwnReasonPerFolder() async throws {
        let fixture = try WorkspaceRegistryTests.Fixture()
        try nested(fixture)
        let registry = fixture.registry()
        try registry.setFolder(fixture.folder("a"), forProject: UUID())
        let picker = ReasonPicker()
        let gate = AgentWorkspaceSendGate(folders: registry, picker: picker, isThisMac: { _ in true })
        let outcome = await gate.prepare(
            conversationID: UUID(), hasSession: false, target: .agent(adapter: "agent:claude-code", connectionID: UUID()), projects: [.init(id: UUID(), name: "Acme")]
        )
        #expect(outcome == .cancelled, "창에서 취소")
        let reason = try #require(picker.reason)
        #expect(reason(fixture.folder("a") + "/sub") == AgentWorkspaceCopy.overlappingFolder)
        let accepts = try #require(picker.accepts)
        let overlapping = fixture.folder("a") + "/sub"
        #expect(accepts(overlapping) == false)
    }
}

struct WorkspaceSensitiveNamesTests {
    private func rejection(_ path: String) -> WorkspaceFolderRules.Rejection? {
        if case .failure(let why) = WorkspaceRegistryRulesTests.standard().validate(path) { return why }
        return nil
    }

    @Test func aFolderWithASensitiveDirectoryComponentIsRejectedAtAnyDepthAndInAnyCase() {
        let home = WorkspaceRegistryRulesTests.home
        for name in WorkspaceFolderRules.sensitiveDirectoryNames {
            #expect(rejection(home + "/Documents/repo/" + name) == .sensitiveFolder, "\(name)")
            #expect(rejection(home + "/Documents/repo/" + name + "/hooks/nested") == .sensitiveFolder, "안: \(name)")
            #expect(rejection(home + "/Documents/" + name + "/repo") == .sensitiveFolder, "상위 성분: \(name)")
        }
        #expect(rejection(home + "/Documents/repo/.GIT") == .sensitiveFolder, "서버처럼 대소문자를 접는다")
        #expect(rejection(home + "/Documents/repo/.Claude/x") == .sensitiveFolder)
        #expect(rejection(home + "/Documents/repo/.hu\u{17F}ky") == .sensitiveFolder, "서버처럼 긴 s(ſ)를 s로 접는다")
    }

    @Test func nearMissesAndTheOnesTheSpecificRulesAlreadyHandleKeepTheirOwnAnswer() {
        let home = WorkspaceRegistryRulesTests.home
        for ok in [".github", ".gitlab", ".git-notes", "my.git", ".vscode-old", ".ideas", "git", "claude"] {
            #expect(rejection(home + "/Documents/repo/" + ok) == nil, "\(ok)")
        }
        #expect(rejection(home + "/.claude") == .claudeConfig, "구체적인 규칙이 먼저다")
        #expect(rejection(home + "/.claude/projects/x") == .claudeConfig)
        #expect(rejection(home + "/Library/.git") == .userLibrary)
    }

    @Test func aSymlinkAliasOfASensitiveFolderIsRejectedByItsRealPath() throws {
        let temp = TempDirectory()
        let home = temp.appending("home")
        try FileManager.default.createDirectory(at: home.appending(path: "Documents/repo/.git/hooks"), withIntermediateDirectories: true)
        let alias = home.appending(path: "Documents/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home.appending(path: "Documents/repo/.git/hooks"))
        let rules = WorkspaceFolderRules(home: home.path, systemRoots: [])
        for path in [alias.path, home.path + "/Documents/repo/.git"] {
            if case .failure(let why) = rules.validate(path) { #expect(why == .sensitiveFolder, "\(path)") } else { Issue.record("받았다: \(path)") }
        }
        if case .failure(let why) = rules.validate(home.path + "/Documents/repo") { Issue.record("받아야 할 폴더가 거절됐다: \(why)") }
    }

    /// 서버 원천 `src/lib/agents/tool-decision.ts`의 `TOOL_SENSITIVE_PATH_PATTERN`에서 폴더 성분 목록을 읽는다
    private func serverNames() throws -> [String] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() } // Bridge → TaskforceKitTests → Tests → TaskforceKit → Packages → apple → 저장소
        let source = try String(contentsOf: root.appending(path: "src/lib/agents/tool-decision.ts"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("export const TOOL_SENSITIVE_PATH_PATTERN") }, "서버에 패턴 줄이 없다")
        let open = try #require(line.range(of: "String.raw`/("))
        let close = try #require(line.range(of: ")(/|$)", range: open.upperBound..<line.endIndex))
        return line[open.upperBound..<close.lowerBound].split(separator: "|").map { $0.replacingOccurrences(of: "\\.", with: ".") }
    }

    @Test func theSwiftListIsTheServersDirectoryListNotAnOldCopy() throws {
        let server = try serverNames()
        #expect(server.count >= 8 && server.allSatisfy { $0.hasPrefix(".") }, "서버 목록을 읽었다: \(server)")
        #expect(Set(server) == Set(WorkspaceFolderRules.sensitiveDirectoryNames), "서버 \(server) ↔ Swift \(WorkspaceFolderRules.sensitiveDirectoryNames)")
        #expect(server.count == WorkspaceFolderRules.sensitiveDirectoryNames.count, "중복 없이 같은 개수")
    }
}
#endif
