#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 턴마다 하는 외부 writer 검사 (OA 외부 세션 PR2m, 계약 ES-10 · 5.4 1–4 · 19장 "CLI는 같은 id 동시 resume을 막지 않는다"): **모르면 막는다.**
    /// 우리 혈통의 pid · 우리 마지막 쓰기는 외부로 세지 않는다. 가짜 홈 · 가짜 프로세스 사실만 쓴다 (사용자의 실제 기록 · 프로세스 0)
    struct ExternalWriterCheckTests {
        typealias F = ExternalSessionFixture
        let id = F.uuid(7)
        let workspace = "/Users/tester/proj"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let started = Date(timeIntervalSince1970: 1_799_990_000)
        private var alive: ExternalSessionProcessFacts.Lookup { .present(start: started, uid: 501) }

        private func facts(lookups: [Int32: ExternalSessionProcessFacts.Lookup] = [:], argv: Set<String>? = [], folders: Set<String>? = []) -> ExternalSessionProcessFacts {
            ExternalSessionProcessFacts(userID: 501, lookup: { lookups[$0] ?? .gone }, argumentSessionIDs: { _ in argv }, unregisteredClaudeFolders: { _, _ in folders })
        }

        private func entry(pid: Int, id: String? = nil, entrypoint: String? = "claude-desktop") -> String {
            var object: [String: Any] = ["pid": pid, "sessionId": id ?? self.id, "status": "idle", "version": "2.1.304", "cwd": workspace, "procStart": started.timeIntervalSince1970, "kind": "interactive"]
            if let entrypoint { object["entrypoint"] = entrypoint }
            return F.json(object)
        }

        private func withHome<T>(modified: Date? = nil, transcript: Bool = true, _ body: (ExternalHome, LiveExternalWriterCheck) async throws -> T) async throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            if transcript {
                let directory = try #require(ExternalSessionRules.projectDirectoryName(forCwd: workspace))
                try home.transcript(directory: directory, id: id, lines: [F.user(id: id, cwd: workspace)], modified: modified ?? now.addingTimeInterval(-3600))
            }
            return try await body(home, LiveExternalWriterCheck(claudeDirectory: home.claude, facts: facts(), clock: { [now] in now }))
        }

        private func check(_ home: ExternalHome, _ facts: ExternalSessionProcessFacts, own: Set<Int32> = [], last: Date? = nil, id: String? = nil, workspace: String? = nil, fileSystem: ExternalSessionFileSystem = .live) async -> ExternalWriterVerdict {
            let live = LiveExternalWriterCheck(claudeDirectory: home.claude, facts: facts, fileSystem: fileSystem, clock: { [now] in now })
            return await live.check(sessionID: id ?? self.id, workspace: workspace ?? self.workspace, ownPIDs: own, ownLastActivity: last)
        }

        @Test func aQuietSessionWithNoOwnerIsFree() async throws {
            try await withHome { home, _ in
                #expect(await check(home, facts()) == .free)
            }
        }

        // MARK: 신호 1–4

        @Test func theClaudeAppHoldingTheSessionBlocksIt() async throws {
            try await withHome { home, _ in
                try home.registry(pid: 4242, json: entry(pid: 4242))
                #expect(await check(home, facts(lookups: [4242: alive])) == .held(.claudeApp))
            }
        }

        @Test func aTerminalHoldingTheSessionBlocksIt() async throws {
            try await withHome { home, _ in
                try home.registry(pid: 4242, json: entry(pid: 4242, entrypoint: "cli"))
                #expect(await check(home, facts(lookups: [4242: alive])) == .held(.terminal))
            }
        }

        @Test func aProcessOfAnUnknownKindHoldsItAsUnknown() async throws {
            try await withHome { home, _ in
                try home.registry(pid: 4242, json: entry(pid: 4242, entrypoint: "claude-vscode"))
                #expect(await check(home, facts(lookups: [4242: alive])) == .held(.unknown))
            }
        }

        @Test func aStaleRegistryEntryDoesNotHold() async throws {
            try await withHome { home, _ in
                try home.registry(pid: 4242, json: entry(pid: 4242))
                #expect(await check(home, facts(lookups: [:])) == .free, "pid가 없다")
                #expect(await check(home, facts(lookups: [4242: .present(start: started.addingTimeInterval(500), uid: 501)])) == .free, "pid 재사용(T10)")
            }
        }

        @Test func anArgvResumeOfTheIdBlocksItEvenWithoutARegistryFile() async throws {
            try await withHome { home, _ in
                #expect(await check(home, facts(argv: [id])) == .held(.terminal))
            }
        }

        @Test func anUnregisteredClaudeInTheSameFolderBlocksItConservatively() async throws {
            try await withHome { home, _ in
                #expect(await check(home, facts(folders: [workspace])) == .held(.unknown))
                #expect(await check(home, facts(folders: ["/Users/tester/elsewhere"])) == .free)
            }
        }

        @Test func aTranscriptWrittenInTheLastMinuteWithNoOwnerBlocksIt() async throws {
            try await withHome(modified: Date(timeIntervalSince1970: 1_800_000_000 - 30)) { home, _ in
                #expect(await check(home, facts()) == .held(.unknown))
            }
        }

        // MARK: 우리 혈통은 외부가 아니다

        @Test func ourOwnPidIsNotAnExternalWriter() async throws {
            try await withHome { home, _ in
                try home.registry(pid: 4242, json: entry(pid: 4242, entrypoint: "sdk-cli"))
                #expect(await check(home, facts(lookups: [4242: alive])) == .held(.unknown), "우리 것이라고 알리지 않으면 막는다")
                #expect(await check(home, facts(lookups: [4242: alive]), own: [4242]) == .free, "우리 혈통 pid는 뺀다")
            }
        }

        @Test func ourOwnLastWriteDoesNotLookLikeAnotherWriter() async throws {
            // 우리 앞 턴이 막 끝나 기록이 방금 쓰였다: 그 시각 이전의 쓰기는 우리 것이다
            let modified = Date(timeIntervalSince1970: 1_800_000_000 - 20)
            try await withHome(modified: modified) { home, _ in
                #expect(await check(home, facts(), last: modified.addingTimeInterval(1)) == .free)
                #expect(await check(home, facts(), last: modified) == .free)
                #expect(await check(home, facts(), last: modified.addingTimeInterval(-2)) == .free, "프로세스가 끝나는 몇 초 안의 쓰기는 우리 것으로 본다")
            }
        }

        @Test func aWriteAfterOurLastActivityIsSomeoneElse() async throws {
            let modified = Date(timeIntervalSince1970: 1_800_000_000 - 20)
            try await withHome(modified: modified) { home, _ in
                #expect(await check(home, facts(), last: modified.addingTimeInterval(-10)) == .held(.unknown))
            }
        }

        // MARK: 모르면 막는다

        @Test func anUnreadableRegistryFolderOrAFailedProcessListIsUnknown() async throws {
            try await withHome { home, _ in
                #expect(await check(home, facts(argv: nil)) == .unknown)
                #expect(await check(home, facts(folders: nil)) == .unknown)
                try home.registry(pid: 123, json: "not json")
                #expect(await check(home, facts()) == .unknown, "등록 파일 형식이 바뀌어 하나도 읽지 못했다 (5.4-1은 건너뛰고 2–4도 못 보는 것과 같다)")
            }
        }

        @Test func aMissingTranscriptIsUnknown() async throws {
            try await withHome(transcript: false) { home, _ in
                #expect(await check(home, facts()) == .unknown)
            }
        }

        @Test func aSymlinkedTranscriptIsUnknown() async throws {
            try await withHome(transcript: false) { home, _ in
                let directory = try #require(ExternalSessionRules.projectDirectoryName(forCwd: workspace))
                let real = home.root + "/real.jsonl"
                try Data("{}\n".utf8).write(to: URL(fileURLWithPath: real))
                try FileManager.default.createDirectory(atPath: home.projects + "/" + directory, withIntermediateDirectories: true)
                try home.link(home.projects + "/" + directory + "/" + id + ".jsonl", to: real)
                #expect(await check(home, facts()) == .unknown)
            }
        }

        @Test func aRegistryEntryWithAnotherFolderIsUnknownNotFree() async throws {
            try await withHome { home, _ in
                var object = try #require(try JSONSerialization.jsonObject(with: Data(entry(pid: 4242).utf8)) as? [String: Any])
                object["cwd"] = "/Users/tester/other"
                try home.registry(pid: 4242, json: F.json(object))
                #expect(await check(home, facts(lookups: [4242: alive])) == .unknown, "기록과 등록 파일의 폴더가 다르면 판정하지 않는다 (5.3-3)")
            }
        }

        @Test func anInputThatCouldBeAnArgumentOrAPathIsRefusedWithoutTouchingTheDisk() async throws {
            try await withHome { home, _ in
                let recording = RecordingFileSystem()
                for bad in [id.uppercased(), "-r", "../x", "/tmp/a.jsonl", id + " ", "", "--resume"] {
                    #expect(await check(home, facts(), id: bad, fileSystem: recording.fileSystem) == .unknown, "\(bad)")
                }
                for bad in ["relative/path", "/a/../b", "/a\nb", "", "/" + String(repeating: "a", count: 300)] {
                    #expect(await check(home, facts(), workspace: bad, fileSystem: recording.fileSystem) == .unknown, "\(bad.prefix(20))")
                }
                #expect(recording.statted.isEmpty && recording.listed.isEmpty && recording.reads.isEmpty && recording.resolved.isEmpty)
            }
        }

        @Test func onlyTheSessionRegistryAndThatOneTranscriptAreTouched() async throws {
            try await withHome { home, _ in
                try home.registry(pid: 4242, json: entry(pid: 4242))
                try Data("secret".utf8).write(to: URL(fileURLWithPath: home.claude + "/.credentials.json"))
                try Data("secret".utf8).write(to: URL(fileURLWithPath: home.sessions + "/4242.deadbeef.key"))
                let recording = RecordingFileSystem()
                _ = await check(home, facts(lookups: [4242: alive]), fileSystem: recording.fileSystem)
                let touched = recording.statted + recording.listed + recording.reads.map(\.path)
                #expect(!touched.contains { $0.contains(".credentials") || $0.hasSuffix(".key") || $0.contains("claude.json") }, "T8: 자격 · 열쇠 파일은 열지 않는다")
                #expect(recording.reads.allSatisfy { $0.path.hasPrefix(home.sessions + "/") && $0.path.hasSuffix("4242.json") }, "읽은 것은 등록 파일뿐이다 (기록 본문은 열지 않는다)")
            }
        }
    }
}
#endif
