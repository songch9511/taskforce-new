#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

/// 실행 중 판정 (계약 5.4 · T7 · T10): 등록 파일 · stale · argv · cwd · mtime · 검사 실패(fail-closed)
struct ExternalSessionHoldTests {
    typealias F = ExternalSessionFixture
    let id = F.uuid(1)
    let cwd = "/Users/tester/proj"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let started = Date(timeIntervalSince1970: 1_799_990_000)

    static func facts(
        lookups: [Int32: ExternalSessionProcessFacts.Lookup] = [:], argv: Set<String>? = [], folders: Set<String>? = [], uid: UInt32 = 501
    ) -> ExternalSessionProcessFacts {
        ExternalSessionProcessFacts(userID: uid, lookup: { lookups[$0] ?? .gone }, argumentSessionIDs: { _ in argv }, unregisteredClaudeFolders: { _, _ in folders })
    }

    private func entry(pid: Int, id: String? = nil, cwd: String? = nil, procStart: Any? = nil, entrypoint: String? = "claude-desktop", kind: String? = "interactive") -> String {
        var object: [String: Any] = ["pid": pid, "sessionId": id ?? self.id, "status": "idle", "version": "2.1.304", "name": "SENTINEL-NAME-\(F.userSentinel)"]
        object["cwd"] = cwd ?? self.cwd
        if let procStart { object["procStart"] = procStart }
        if let entrypoint { object["entrypoint"] = entrypoint }
        if let kind { object["kind"] = kind }
        return F.json(object)
    }

    /// 가짜 홈에 등록 파일을 쓰고 한 번 훑은 스냅샷으로 판정한다
    private func decide(
        _ home: ExternalHome, files: [(Int, String)], facts: ExternalSessionProcessFacts, cwd: String? = "/Users/tester/proj", modified: Date? = nil, own: Set<Int32> = [],
        fileSystem: ExternalSessionFileSystem = .live
    ) -> ExternalSessionHold.Result {
        for (pid, json) in files { try! home.registry(pid: pid, json: json) }
        let snapshot = ExternalSessionHold.snapshot(facts: facts, fileSystem: fileSystem, sessionsDirectory: home.sessions, ownPIDs: own, now: now)
        return ExternalSessionHold.decide(id: id, cwd: cwd, modified: modified ?? now.addingTimeInterval(-3600), snapshot: snapshot)
    }

    private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
        let home = try ExternalHome()
        defer { home.cleanup() }
        return try body(home)
    }

    private var alive: ExternalSessionProcessFacts.Lookup { .present(start: started, uid: 501) }

    // MARK: 신호 1: 등록 파일

    @Test func aLiveRegistryEntryNamesTheHolderByItsEntrypoint() throws {
        try withHome { home in
            let cases: [(String?, String?, ExternalSessionHolder)] = [
                ("claude-desktop", "interactive", .claudeApp), ("cli", "interactive", .terminal), ("claude-vscode", "interactive", .unknown), (nil, nil, .unknown),
                ("cli", "background", .background), ("claude-desktop", "Background", .background),
            ]
            for (entrypoint, kind, expected) in cases {
                let json = entry(pid: 4242, procStart: started.timeIntervalSince1970, entrypoint: entrypoint, kind: kind)
                let result = decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: alive]))
                #expect(result == .held(expected), "\(entrypoint ?? "nil") \(kind ?? "nil")")
            }
        }
    }

    @Test func aStaleEntryDoesNotHoldTheSession() throws {
        try withHome { home in
            let json = entry(pid: 4242, procStart: started.timeIntervalSince1970)
            // pid가 없다 (프로세스가 끝나도 파일은 남는다)
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [:])) == .free)
            // 같은 pid가 다른 시작 시각으로 다시 쓰였다 (T10)
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: .present(start: started.addingTimeInterval(500), uid: 501)])) == .free)
            // 다른 사용자의 프로세스
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: .present(start: started, uid: 0)])) == .free)
        }
    }

    @Test func theStartTimeToleranceIsOneSecond() throws {
        try withHome { home in
            let json = entry(pid: 4242, procStart: started.timeIntervalSince1970)
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: .present(start: started.addingTimeInterval(0.9), uid: 501)])) == .held(.claudeApp))
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: .present(start: started.addingTimeInterval(-0.9), uid: 501)])) == .held(.claudeApp))
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: .present(start: started.addingTimeInterval(1.1), uid: 501)])) == .free)
        }
    }

    @Test func aFailedLookupOrAnUnknownStartTimeCountsAsAliveFailClosed() throws {
        try withHome { home in
            let withStart = entry(pid: 4242, procStart: started.timeIntervalSince1970)
            #expect(decide(home, files: [(4242, withStart)], facts: Self.facts(lookups: [4242: .failed])) == .held(.claudeApp))
            let withoutStart = entry(pid: 4242, procStart: nil)
            #expect(decide(home, files: [(4242, withoutStart)], facts: Self.facts(lookups: [4242: alive])) == .held(.claudeApp))
            let garbage = entry(pid: 4242, procStart: "tomorrow-ish")
            #expect(decide(home, files: [(4242, garbage)], facts: Self.facts(lookups: [4242: alive])) == .held(.claudeApp))
        }
    }

    @Test func procStartIsReadInSecondsMillisecondsISOAndLstartForms() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let lstart = DateFormatter()
        lstart.locale = Locale(identifier: "en_US_POSIX")
        lstart.timeZone = .current
        lstart.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let forms: [Any] = [started.timeIntervalSince1970, started.timeIntervalSince1970 * 1000, String(Int(started.timeIntervalSince1970)), iso.string(from: started), lstart.string(from: started)]
        try withHome { home in
            for form in forms {
                let json = entry(pid: 4242, procStart: form)
                // 시작 시각이 같으면 쥔 것, 5초 어긋나면 stale: 모양을 읽었다는 증거다
                #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: alive])) == .held(.claudeApp), "\(form)")
                #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: .present(start: started.addingTimeInterval(5), uid: 501)])) == .free, "\(form)")
            }
        }
    }

    @Test func ourOwnProcessesAreNotAnOutsideWriter() throws {
        try withHome { home in
            let json = entry(pid: 4242, procStart: started.timeIntervalSince1970)
            #expect(decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: alive]), own: [4242]) == .free)
        }
    }

    @Test func aRegistryCwdThatDiffersFromTheTranscriptCwdIsNotJudged() throws {
        try withHome { home in
            let elsewhere = entry(pid: 4242, cwd: "/Users/tester/other", procStart: started.timeIntervalSince1970)
            #expect(decide(home, files: [(4242, elsewhere)], facts: Self.facts(lookups: [4242: alive])) == .cwdMismatch)
        }
    }

    @Test func entriesOfOtherSessionsDoNotHoldThisOne() throws {
        try withHome { home in
            let other = entry(pid: 4242, id: F.uuid(2), procStart: started.timeIntervalSince1970)
            #expect(decide(home, files: [(4242, other)], facts: Self.facts(lookups: [4242: alive])) == .free)
        }
    }

    // MARK: 신호 1이 읽히지 않을 때

    @Test func aRegistryThatCannotBeInterpretedMeansWeCannotRuleOutAHolder() throws {
        try withHome { home in
            // 형식이 바뀌어 하나도 해석하지 못했다: 다른 신호가 아무것도 못 찾아도 unknown (fail-closed)
            let result = decide(home, files: [(4242, "{\"v\":2,\"data\":\"opaque\"}"), (4243, "not json")], facts: Self.facts())
            #expect(result == .unknown)
        }
    }

    @Test func oneGarbageFileAmongReadableOnesDoesNotHideTheOthers() throws {
        try withHome { home in
            let json = entry(pid: 4242, procStart: started.timeIntervalSince1970)
            #expect(decide(home, files: [(4242, json), (4243, "garbage")], facts: Self.facts(lookups: [4242: alive])) == .held(.claudeApp))
            #expect(decide(home, files: [(4242, entry(pid: 4242, id: F.uuid(3))), (4243, "garbage")], facts: Self.facts()) == .free)
        }
    }

    @Test func aMissingSessionsFolderMeansNothingIsRegistered() throws {
        try withHome { home in
            try FileManager.default.removeItem(atPath: home.sessions)
            #expect(decide(home, files: [], facts: Self.facts()) == .free)
        }
    }

    @Test func anUnreadableSessionsFolderIsUnknown() throws {
        try withHome { home in
            let denied = ExternalSessionFileSystem(userID: 501, realpath: { $0 }, lstat: { _ in nil }, list: { _ in .failed }, read: { _, _, _ in nil })
            #expect(decide(home, files: [], facts: Self.facts(), fileSystem: denied) == .unknown)
        }
    }

    // MARK: 신호 2–4

    @Test func anArgvThatNamesTheSessionHoldsItInTheTerminal() throws {
        try withHome { home in
            #expect(decide(home, files: [], facts: Self.facts(argv: [id])) == .held(.terminal))
            #expect(decide(home, files: [], facts: Self.facts(argv: [F.uuid(9)])) == .free)
        }
    }

    @Test func anUnregisteredClaudeInTheSameFolderHoldsItConservatively() throws {
        try withHome { home in
            #expect(decide(home, files: [], facts: Self.facts(folders: [cwd])) == .held(.unknown))
            #expect(decide(home, files: [], facts: Self.facts(folders: ["/Users/tester/else"])) == .free)
            // 기록 cwd를 모르면(폴더가 없다) 이 신호는 쓰지 않는다
            #expect(decide(home, files: [], facts: Self.facts(folders: [cwd]), cwd: nil) == .free)
        }
    }

    @Test func aTranscriptWrittenInTheLastMinuteIsHeldWhenNobodyIsFound() throws {
        try withHome { home in
            #expect(decide(home, files: [], facts: Self.facts(), modified: now.addingTimeInterval(-59)) == .held(.unknown))
            #expect(decide(home, files: [], facts: Self.facts(), modified: now.addingTimeInterval(-61)) == .free)
            #expect(decide(home, files: [], facts: Self.facts(), modified: now.addingTimeInterval(+30)) == .held(.unknown), "미래 시각도 방금으로 본다")
        }
    }

    @Test func aFoundHolderBeatsEverythingAndAClaudeAppBeatsTheTerminal() throws {
        try withHome { home in
            let desktop = entry(pid: 4242, procStart: started.timeIntervalSince1970, entrypoint: "claude-desktop")
            let terminal = entry(pid: 4243, procStart: started.timeIntervalSince1970, entrypoint: "cli")
            let facts = Self.facts(lookups: [4242: alive, 4243: alive], argv: nil, folders: nil)
            #expect(decide(home, files: [(4243, terminal), (4242, desktop)], facts: facts) == .held(.claudeApp))
        }
    }

    @Test func aSignalThatCouldNotBeReadAndNoHolderFoundIsUnknown() throws {
        try withHome { home in
            #expect(decide(home, files: [], facts: Self.facts(argv: nil)) == .unknown)
            #expect(decide(home, files: [], facts: Self.facts(folders: nil)) == .unknown)
            #expect(decide(home, files: [], facts: Self.facts(argv: nil, folders: nil)) == .unknown)
            // 하나라도 쥔 곳을 찾았으면 unknown이 아니라 그 곳
            #expect(decide(home, files: [], facts: Self.facts(argv: nil, folders: [cwd])) == .held(.unknown))
            #expect(decide(home, files: [], facts: Self.facts(argv: [id], folders: nil)) == .held(.terminal))
        }
    }

    // MARK: 등록 파일 읽기의 안전 (T2 · T3 · T8)

    @Test func theRegistryReaderOpensOnlyNumberedJsonFilesNeverKeysOrCredentials() throws {
        try withHome { home in
            try home.registry(pid: 4242, json: entry(pid: 4242, procStart: started.timeIntervalSince1970))
            for decoy in ["4242.abcdef0123.key", ".credentials.json", "settings.json", "4242.json.bak", "x.json", "12345678901.json", ".json"] {
                try "SECRET".write(toFile: home.sessions + "/" + decoy, atomically: false, encoding: .utf8)
            }
            let recording = RecordingFileSystem()
            _ = ExternalSessionRegistry.read(fileSystem: recording.fileSystem, sessionsDirectory: home.sessions)
            #expect(recording.reads.map(\.path) == [home.sessions + "/4242.json"])
        }
    }

    @Test func aSymlinkedAndAnOversizedRegistryFileAreNotRead() throws {
        try withHome { home in
            let outside = home.root + "/outside.json"
            try entry(pid: 1, procStart: nil).write(toFile: outside, atomically: false, encoding: .utf8)
            try home.link(home.sessions + "/4242.json", to: outside)
            let big = entry(pid: 4243, procStart: nil) + String(repeating: " ", count: 70_000)
            try big.write(toFile: home.sessions + "/4243.json", atomically: false, encoding: .utf8)
            let recording = RecordingFileSystem()
            let result = ExternalSessionRegistry.read(fileSystem: recording.fileSystem, sessionsDirectory: home.sessions)
            #expect(result == .unavailable, "읽을 수 있는 것이 하나도 없다")
            #expect(recording.reads.isEmpty)
        }
    }

    @Test func registryFilesOfAnotherOwnerAreSkipped() throws {
        try withHome { home in
            try home.registry(pid: 4242, json: entry(pid: 4242, procStart: nil))
            let base = ExternalSessionFileSystem.live
            let strangers = ExternalSessionFileSystem(
                userID: base.userID, realpath: base.realpath, lstat: base.lstat,
                list: { path in
                    guard case .entries(let items) = base.list(path) else { return base.list(path) }
                    return .entries(items.map { var copy = $0; copy.owner = base.userID &+ 1; return copy })
                },
                read: base.read
            )
            #expect(ExternalSessionRegistry.read(fileSystem: strangers, sessionsDirectory: home.sessions) == .entries([]))
        }
    }

    @Test func nothingFromTheRegistryOrTheDecisionReachesTheResultAsText() throws {
        try withHome { home in
            let json = entry(pid: 4242, procStart: started.timeIntervalSince1970)
            let result = decide(home, files: [(4242, json)], facts: Self.facts(lookups: [4242: alive]))
            expectNoSentinel(in: result)
            if case .entries(let entries) = ExternalSessionRegistry.read(fileSystem: .live, sessionsDirectory: home.sessions) { expectNoSentinel(in: entries) }
        }
    }
}
#endif
