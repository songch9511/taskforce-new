#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 실제 프로세스를 보는 부분 (일회용 자식만): argv · 시작 시각 · 같은 폴더의 `claude`. 실제 `claude`는 띄우지 않는다 (이름만 같은 `sleep`)
struct ExternalSessionLiveFactsTests {
    typealias F = ExternalSessionFixture

    /// 끝까지 거두는 일회용 자식
    final class Child {
        let process = Process()
        init(executable: String, arguments: [String], directory: String? = nil) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
        var pid: Int32 { process.processIdentifier }
        func stop() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    @Test func anArgvThatResumesASessionIsSeenAndOurOwnPIDsAreSkipped() throws {
        let id = F.uuid(0xA1)
        let child = try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--resume", id])
        defer { child.stop() }
        // (`sleep 30; :`: 명령이 하나뿐이면 셸이 `sleep`으로 exec해 argv가 바뀐다)
        // 프로세스가 argv를 갖출 때까지 잠깐
        var seen = Set<String>()
        for _ in 0..<50 {
            seen = ExternalSessionProcessFacts.live.argumentSessionIDs([]) ?? []
            if seen.contains(id) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(seen.contains(id))
        #expect(ExternalSessionProcessFacts.live.argumentSessionIDs([child.pid])?.contains(id) == false, "우리 혈통의 pid는 센 값에서 뺀다")
        #expect(ExternalSessionProcessFacts.live.argumentSessionIDs([])?.contains(F.uuid(0xA2)) == false)
    }

    @Test func theEqualsFormsAndSessionIdFlagAreSeenToo() throws {
        let a = F.uuid(0xB1), b = F.uuid(0xB2), c = F.uuid(0xB3)
        let children = [
            try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--resume=\(a)"]),
            try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--session-id", b]),
            try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "-r", c]),
        ]
        defer { children.forEach { $0.stop() } }
        var seen = Set<String>()
        for _ in 0..<50 {
            seen = ExternalSessionProcessFacts.live.argumentSessionIDs([]) ?? []
            if [a, b, c].allSatisfy(seen.contains) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect([a, b, c].allSatisfy(seen.contains))
    }

    @Test func aNonCanonicalValueAfterTheFlagIsNotASessionID() throws {
        let child = try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--resume", "/tmp/a.jsonl", "-r", "--x", "--resume", F.uuid(0xC1).uppercased()])
        defer { child.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let seen = ExternalSessionProcessFacts.live.argumentSessionIDs([]) ?? []
        #expect(!seen.contains("/tmp/a.jsonl") && !seen.contains(F.uuid(0xC1).uppercased()) && !seen.contains(F.uuid(0xC1)))
    }

    @Test func aLiveProcessHasItsKernelStartTimeAndOurUserAndAGoneOneIsGone() throws {
        let own = ExternalSessionProcessFacts.live.lookup(getpid())
        guard case .present(let start, let uid) = own else {
            Issue.record("자기 프로세스를 못 읽었다")
            return
        }
        #expect(uid == getuid())
        #expect(abs(start.timeIntervalSince(ClaudeProcessInspector.startTime(pid: getpid()) ?? .distantPast)) < 0.001)
        #expect(start < Date())
        let child = try Child(executable: "/bin/sleep", arguments: ["30"])
        let before = ExternalSessionProcessFacts.live.lookup(child.pid)
        child.stop()
        if case .present(_, let childUID) = before { #expect(childUID == getuid()) } else { Issue.record("자식을 못 읽었다") }
        #expect(ExternalSessionProcessFacts.live.lookup(child.pid) == .gone)
        #expect(ExternalSessionProcessFacts.live.lookup(0) == .failed || ExternalSessionProcessFacts.live.lookup(0) == .gone)
    }

    @Test func anUnregisteredProcessNamedClaudeIsFoundByItsFolderAndARegisteredOneIsNot() throws {
        let home = try ExternalHome()
        defer { home.cleanup() }
        let folder = home.root + "/work"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // 이름만 `claude`인 `sleep` (실제 claude 0): 같은 실행 파일의 복사본
        let binary = home.root + "/claude"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary)
        let child = try Child(executable: binary, arguments: ["30"], directory: folder)
        defer { child.stop() }
        var folders = Set<String>()
        for _ in 0..<50 {
            folders = ExternalSessionProcessFacts.live.unregisteredClaudeFolders([], []) ?? []
            if folders.contains(folder) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(folders.contains(folder), "복사한 sleep이 claude 이름으로 돌지 못하는 환경이면 이 시험은 실패로 알려 준다")
        #expect(ExternalSessionProcessFacts.live.unregisteredClaudeFolders([child.pid], [])?.contains(folder) == false, "등록 파일이 있는 pid는 신호 3이 아니다")
        #expect(ExternalSessionProcessFacts.live.unregisteredClaudeFolders([], [child.pid])?.contains(folder) == false, "우리 혈통의 pid는 뺀다")
        // 다른 이름의 프로세스는 보지 않는다
        let other = try Child(executable: "/bin/sleep", arguments: ["30"], directory: folder)
        defer { other.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(ExternalSessionProcessFacts.live.unregisteredClaudeFolders([child.pid], [])?.contains(folder) == false)
    }
}
#endif
