#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 민감 디렉터리 이름(`.git` · `.claude` …)이 성분에 든 폴더는 받지 않는다 (재검토 1, 코디네이터 13.12, Astra 2): 가상 루트에서 그 성분이 사라지면 서버의 `tool_config_write` 확인이 빠진다.
/// 겹치는 폴더 규칙은 `WorkspaceOverlapRuleTests.swift` (계약 13.13). 임시 폴더만 쓴다
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
