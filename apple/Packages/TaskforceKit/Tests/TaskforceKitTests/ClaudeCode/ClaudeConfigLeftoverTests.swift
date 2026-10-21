#if os(macOS)
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 앱이 도중에 죽으면 spawn의 설정 파일 셋(`config/<spawn id>.settings.json|mcp.json|prompt.txt`)이 남는다. settings에는 훅 nonce가, prompt에는 프로젝트 지침 글이 있다.
/// 앱이 뜰 때 혈통이 "끝"으로 확정된 spawn의 파일 셋을 함께 지운다 (끝났으니 아무도 읽지 않는다). 아직 끝이 증명되지 않은 spawn의 파일은 건드리지 않는다
struct ClaudeConfigLeftoverTests {
    let box = ClaudeSandbox()

    private func lineageFolder() throws -> URL {
        let folder = box.sessionsRoot.appending(path: "lineage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 세션 폴더의 `config/`에 그 spawn의 파일 셋을 만든다
    @discardableResult
    private func leftovers(of spawn: String, session: String = UUID().uuidString.lowercased()) throws -> [URL] {
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: box.sessionsRoot, agentSessionID: session)
        return try ["settings.json", "mcp.json", "prompt.txt"].map { suffix in
            let url = folder.config.appending(path: "\(spawn).\(suffix)")
            try Data("leftover".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
    }

    private func otherBootLineage(_ spawn: String) throws {
        try "\(ClaudeLineage.header)\nboot \(UUID().uuidString)\npending\n".write(to: try lineageFolder().appending(path: "\(spawn).lineage"), atomically: true, encoding: .utf8)
    }

    private func exists(_ urls: [URL]) -> [Bool] { urls.map { FileManager.default.fileExists(atPath: $0.path) } }

    @Test func startupRemovesTheConfigSetOfASpawnWhoseLineageIsMarkedEnded() throws {
        let crashed = UUID().uuidString.lowercased()
        try otherBootLineage(crashed)
        let files = try leftovers(of: crashed)
        ClaudeRereview3ReproTests.adapter(box).purgeLineageOfOtherBoots()
        #expect(exists(files) == [false, false, false], "settings(nonce) · mcp · prompt(지침 글)가 모두 지워진다")
        #expect(ClaudeLineage.load(try lineageFolder().appending(path: "\(crashed).lineage")) == .ended, "혈통은 끝 기록으로")
    }

    @Test func aSpawnWhoseEndWasAlreadyRecordedBeforeThisVersionGetsItsLeftoversRemovedToo() throws {
        let earlier = UUID().uuidString.lowercased()
        let ended = try lineageFolder().appending(path: "\(earlier).ended")
        try "\(ClaudeLineage.header)\nboot \(UUID().uuidString)\nended\n".write(to: ended, atomically: true, encoding: .utf8)
        let files = try leftovers(of: earlier)
        ClaudeRereview3ReproTests.adapter(box).purgeLineageOfOtherBoots()
        #expect(exists(files) == [false, false, false])
    }

    @Test func theSameSpawnsFilesInEverySessionFolderAreRemoved() throws {
        let crashed = UUID().uuidString.lowercased()
        try otherBootLineage(crashed)
        let a = try leftovers(of: crashed)
        let b = try leftovers(of: crashed)
        ClaudeRereview3ReproTests.adapter(box).purgeLineageOfOtherBoots()
        #expect(exists(a + b).allSatisfy { !$0 })
    }

    @Test func aSpawnWhoseEndIsNotProvenKeepsItsFilesAndNothingElseInTheFolderIsTouched() throws {
        // 이번 부팅의 정체 자리(pending): 아직 끝이 증명되지 않았다
        let live = UUID().uuidString.lowercased()
        let boot = try #require(AgentProcesses.bootSessionID())
        try "\(ClaudeLineage.header)\nboot \(boot)\npending\n".write(to: try lineageFolder().appending(path: "\(live).lineage"), atomically: true, encoding: .utf8)
        let session = UUID().uuidString.lowercased()
        let liveFiles = try leftovers(of: live, session: session)
        // 혈통이 아예 없는 spawn의 파일 · UUID 모양이 아닌 이름 · 폴더
        let unknown = try leftovers(of: UUID().uuidString.lowercased(), session: session)
        let folder = try ClaudeSessionFolder.prepare(sessionsRoot: box.sessionsRoot, agentSessionID: session)
        let stray = folder.config.appending(path: "notes.txt")
        try Data("keep".utf8).write(to: stray)
        let crashed = UUID().uuidString.lowercased()
        try otherBootLineage(crashed)
        let gone = try leftovers(of: crashed, session: session)
        ClaudeRereview3ReproTests.adapter(box).purgeLineageOfOtherBoots()
        #expect(exists(gone) == [false, false, false])
        #expect(exists(liveFiles) == [true, true, true], "끝이 증명되지 않은 spawn")
        #expect(exists(unknown) == [true, true, true], "혈통 기록이 없는 spawn은 건드리지 않는다")
        #expect(FileManager.default.fileExists(atPath: stray.path) && FileManager.default.fileExists(atPath: folder.root.path), "설정 파일 셋 밖의 것은 그대로")
    }
}
#endif
