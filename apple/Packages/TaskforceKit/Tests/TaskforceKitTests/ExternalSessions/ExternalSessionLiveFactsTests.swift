#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
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

        /// 프로세스 표를 훑는 일은 가벼운 일이 아니라서 한 번에 모아 본다: 세션을 가리키는 네 모양(`--resume <id>` · `--resume=<id>` · `--session-id <id>` · `-r <id>`)을 한 번의 훑기로
        @Test func anArgvThatNamesASessionIsSeenInEveryFormAndOurOwnPIDsAreSkipped() throws {
            let ids = (0xA1...0xA4).map { F.uuid($0) }
            let notThere = F.uuid(0xA9)
            let children = [
                try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--resume", ids[0]]),
                try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--resume=\(ids[1])"]),
                try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "--session-id", ids[2]]),
                // `-r` 뒤의 값이 정규 UUID가 아니면 세션 id가 아니다 (경로 · 옵션 · 대문자)
                try Child(executable: "/bin/sh", arguments: ["-c", "sleep 30; :", "claude", "-r", ids[3], "--resume", "/tmp/a.jsonl", "-r", "--x", "--resume", F.uuid(0xC1).uppercased()]),
            ]
            defer { children.forEach { $0.stop() } }
            var seen = Set<String>()
            for _ in 0..<40 {
                seen = ExternalSessionProcessFacts.live.argumentSessionIDs([]) ?? []
                if ids.allSatisfy(seen.contains) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            #expect(ids.allSatisfy(seen.contains))
            #expect(!seen.contains(notThere))
            #expect(!seen.contains("/tmp/a.jsonl") && !seen.contains(F.uuid(0xC1).uppercased()) && !seen.contains(F.uuid(0xC1)))
            let skipped = ExternalSessionProcessFacts.live.argumentSessionIDs(Set(children.map(\.pid))) ?? []
            #expect(ids.allSatisfy { !skipped.contains($0) }, "우리 혈통의 pid는 센 값에서 뺀다")
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
            // 복사한 실행 파일의 첫 실행은 시스템 검사(syspolicyd)로 몇 초 걸릴 수 있다: 일찍 찾으면 바로 끝낸다
            for _ in 0..<150 {
                folders = ExternalSessionProcessFacts.live.unregisteredClaudeFolders([], []) ?? []
                if folders.contains(folder) { break }
                Thread.sleep(forTimeInterval: 0.1)
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
}
#endif
