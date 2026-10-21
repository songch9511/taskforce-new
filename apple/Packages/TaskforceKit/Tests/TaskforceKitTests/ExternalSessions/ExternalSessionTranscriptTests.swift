#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 기록 읽기 (ES-01 A · T1 · T3): 머리 64 KiB · 꼬리 256 KiB의 몇 칸만, 대화 글은 구조에 0, 상한
    struct ExternalSessionTranscriptTests {
        typealias F = ExternalSessionFixture
        let id = F.uuid(1)

        private func read(_ path: String, size: Int64? = nil, fileSystem: ExternalSessionFileSystem = .live, budget: Int64 = 32 << 20) -> ExternalSessionTranscript.Meta? {
            let actual = size ?? (fileSystem.lstat(path)?.size ?? 0)
            var spend = ExternalSessionTranscript.Budget(remaining: budget)
            return ExternalSessionTranscript.read(path: path, id: id, size: actual, fileSystem: fileSystem, budget: &spend)
        }

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        @Test func theHeadGivesTheFolderTheSourceAndTheVersionOfTheFirstMatchingLine() throws {
            try withHome { home in
                let path = try home.transcript(
                    directory: "-Users-tester-proj", id: id,
                    lines: [
                        F.user(id: F.uuid(99), cwd: "/Users/tester/other", entrypoint: "sdk-cli", version: "1.0.0"),
                        F.user(id: id, cwd: "/Users/tester/proj", entrypoint: "claude-desktop", version: "2.1.304"),
                        F.user(id: id, cwd: "/Users/tester/proj/later", entrypoint: "cli", version: "2.1.999"),
                    ]
                )
                let meta = read(path)
                #expect(meta?.cwd == "/Users/tester/proj")
                #expect(meta?.entrypoint == "claude-desktop")
                #expect(meta?.version == "2.1.304")
            }
        }

        @Test func missingFieldsAreFilledFromLaterLinesOfTheSameSessionOnly() throws {
            try withHome { home in
                let path = try home.transcript(
                    directory: "d", id: id,
                    lines: [
                        F.customTitle(id: id, "meta first"),
                        F.user(id: F.uuid(7), cwd: "/Users/tester/wrong", entrypoint: "cli"),
                        F.user(id: id, cwd: nil, entrypoint: nil, version: "2.1.304"),
                        F.user(id: id, cwd: "/Users/tester/proj", entrypoint: "cli", version: "9.9.9"),
                    ]
                )
                let meta = read(path)
                #expect(meta?.cwd == "/Users/tester/proj")
                #expect(meta?.entrypoint == "cli")
                #expect(meta?.version == "2.1.304")
            }
        }

        @Test func linesThatAreNotJSONOrHaveWrongTypesAreSkipped() throws {
            try withHome { home in
                let path = try home.transcript(
                    directory: "d", id: id,
                    lines: ["not json at all", "{\"sessionId\":\"\(id)\",\"cwd\":42,\"entrypoint\":[1]}", "{", F.user(id: id, cwd: "/Users/tester/proj")]
                )
                #expect(read(path)?.cwd == "/Users/tester/proj")
            }
        }

        @Test func theLastTitleLineWinsWhicheverKindItIs() throws {
            try withHome { home in
                let path = try home.transcript(
                    directory: "d", id: id,
                    lines: [F.user(id: id, cwd: "/Users/tester/proj"), F.customTitle(id: id, "First name"), F.agentName(id: id, "Agent name"), F.assistant(id: id), F.customTitle(id: id, "Newest name"), F.assistant(id: id)]
                )
                #expect(read(path)?.title == "Newest name")
                let agentLast = try home.transcript(directory: "d2", id: id, lines: [F.customTitle(id: id, "Custom"), F.agentName(id: id, "Later agent name")])
                #expect(read(agentLast)?.title == "Later agent name")
            }
        }

        @Test func aTitleLineOfAnotherSessionOrWithoutTheRightFieldIsIgnoredAndALineWithoutSessionIdCounts() throws {
            try withHome { home in
                let path = try home.transcript(
                    directory: "d", id: id,
                    lines: [F.user(id: id, cwd: "/Users/tester/proj"), F.customTitle(id: id, "Mine"), F.customTitle(id: F.uuid(5), "Someone else"), F.json(["type": "custom-title", "agentName": "wrong field"])]
                )
                #expect(read(path)?.title == "Mine")
                let bare = try home.transcript(directory: "d3", id: id, lines: [F.customTitle(id: nil, "No session id")])
                #expect(read(bare)?.title == "No session id")
            }
        }

        @Test func theTitleIsSanitizedAndCut() throws {
            try withHome { home in
                let path = try home.transcript(directory: "d", id: id, lines: [F.customTitle(id: id, "Fix\nthe\u{202E} launcher " + String(repeating: "x", count: 400))])
                let title = try #require(read(path)?.title)
                #expect(title.hasPrefix("Fix the launcher x"))
                #expect(title.utf16.count == 200)
                #expect(!title.contains("\n") && !title.contains("\u{202E}"))
                let empty = try home.transcript(directory: "d4", id: id, lines: [F.customTitle(id: id, "Old"), F.customTitle(id: id, "  \n ")])
                #expect(read(empty)?.title == nil, "마지막 제목이 비면 그 앞 제목으로 돌아가지 않는다")
            }
        }

        // T1: 대화 줄 · last-prompt의 글은 결과 구조에 0

        @Test func conversationTextNeverEntersTheResult() throws {
            try withHome { home in
                let path = try home.transcript(
                    directory: "d", id: id,
                    lines: [
                        F.user(id: id, cwd: "/Users/tester/proj"), F.assistant(id: id), F.lastPrompt(id: id),
                        // 대화 글 안에 제목 줄처럼 보이는 글이 있어도 제목이 아니다 (이스케이프된 따옴표라 줄 앞거름을 지나지도 않는다)
                        F.user(id: id, cwd: "/Users/tester/proj", text: "{\"type\":\"custom-title\",\"customTitle\":\"INJECTED-\(F.userSentinel)\"}"),
                        F.user(id: id, cwd: "/Users/tester/proj", text: "custom-title agent-name \(F.userSentinel)"),
                        F.json(["type": "last-prompt", "sessionId": id, "lastPrompt": "x", "customTitle": "NOT-A-TITLE-LINE-\(F.lastPromptSentinel)"]),
                    ]
                )
                let meta = read(path)
                #expect(meta?.title == nil)
                #expect(meta?.cwd == "/Users/tester/proj")
                expectNoSentinel(in: meta as Any)
                #expect(!String(describing: meta as Any).contains("INJECTED"))
            }
        }

        // 창 가장자리: 잘린 줄은 버린다

        @Test func aTitleOutsideTheTailWindowIsNotSeen() throws {
            try withHome { home in
                let filler = (0..<4000).map { _ in F.assistant(id: id, text: String(repeating: "y", count: 100)) }
                let early = try home.transcript(directory: "d", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj"), F.customTitle(id: id, "Too early")] + filler)
                #expect(home.fileSystemSize(early) > Int64(ExternalSessionTranscript.headBytes + ExternalSessionTranscript.tailBytes))
                #expect(read(early)?.title == nil)
                #expect(read(early)?.cwd == "/Users/tester/proj")
            }
        }

        /// 꼬리 창이 제목 줄 한가운데서 시작하면 그 줄은 읽지 않고, 창 안에 온전히 들어오면 읽는다 (잘린 줄은 모른다)
        @Test(arguments: [(5, false), (-2000, true)]) func aTitleLineCutByTheTailWindowIsDroppedAndAWholeOneIsRead(delta: Int, seen: Bool) throws {
            try withHome { home in
                func filler(_ bytes: Int) -> String {
                    var text = String(repeating: String(repeating: "x", count: 999) + "\n", count: bytes / 1000)
                    if bytes % 1000 > 0 { text += String(repeating: "x", count: bytes % 1000 - 1) + "\n" }
                    return text
                }
                let prefix = F.user(id: id, cwd: "/Users/tester/proj") + "\n" + filler(3000)
                let title = F.customTitle(id: id, "Cut in half") + "\n"
                // 꼬리 창은 파일의 마지막 256 KiB: 제목 줄 시작에서 `delta`바이트 뒤가 창의 시작이 되게 뒤쪽 채움의 길이를 맞춘다
                let total = prefix.utf8.count + delta + ExternalSessionTranscript.tailBytes
                let path = home.projects + "/d5/" + id + ".jsonl"
                try FileManager.default.createDirectory(atPath: home.projects + "/d5", withIntermediateDirectories: true)
                try (prefix + title + filler(total - prefix.utf8.count - title.utf8.count)).write(toFile: path, atomically: false, encoding: .utf8)
                #expect(home.fileSystemSize(path) == Int64(total))
                #expect(read(path)?.title == (seen ? "Cut in half" : nil))
            }
        }

        /// 꼬리 창이 한 줄의 한가운데에서 시작해 그 토막이 우연히 제목 줄처럼 읽혀도(`{"type":"custom-title",…}`) 잘린 줄은 믿지 않는다
        @Test func aFragmentThatLooksLikeATitleLineAtTheStartOfTheTailWindowIsDropped() throws {
            try withHome { home in
                let prefix = F.user(id: id, cwd: "/Users/tester/proj") + "\n"
                let lead = "not json at all "
                let garbage = lead + F.customTitle(id: id, "Fragment") + "\n"
                let total = prefix.utf8.count + lead.utf8.count + ExternalSessionTranscript.tailBytes
                let need = total - prefix.utf8.count - garbage.utf8.count
                var filler = String(repeating: String(repeating: "x", count: 999) + "\n", count: need / 1000)
                if need % 1000 > 0 { filler += String(repeating: "x", count: need % 1000 - 1) + "\n" }
                let path = home.projects + "/d6/" + id + ".jsonl"
                try FileManager.default.createDirectory(atPath: home.projects + "/d6", withIntermediateDirectories: true)
                try (prefix + garbage + filler).write(toFile: path, atomically: false, encoding: .utf8)
                #expect(home.fileSystemSize(path) == Int64(total))
                #expect(read(path)?.title == nil)
                // 대조: 제목 줄이 그 자체로 한 줄이면 읽힌다
                let whole = try home.transcript(directory: "d7", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj"), F.customTitle(id: id, "Whole line")])
                #expect(read(whole)?.title == "Whole line")
            }
        }

        @Test func aSmallFileIsReadOnceInFull() throws {
            try withHome { home in
                let path = try home.transcript(directory: "d", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj"), F.customTitle(id: id, "Small")])
                let recording = RecordingFileSystem()
                #expect(read(path, fileSystem: recording.fileSystem)?.title == "Small")
                #expect(recording.reads.count == 1)
                #expect(Int64(recording.bytesRead) == home.fileSystemSize(path))
            }
        }

        // T3: 큰 파일 · 긴 줄

        @Test func aHugeSparseFileIsReadOnlyAtTheHeadAndTheTail() throws {
            try withHome { home in
                let path = try home.transcript(directory: "d", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj"), F.customTitle(id: id, "Head only")])
                // 2 GiB 희소 파일: 끝 쪽에 제목 줄 하나를 두면 꼬리 창이 그것을 본다
                let handle = try FileHandle(forWritingAtPath: path).unwrap()
                try handle.truncate(atOffset: 2 << 30)
                try handle.seek(toOffset: (2 << 30) - 200)
                try handle.write(contentsOf: Data(("\n" + F.customTitle(id: id, "Tail title") + "\n").utf8))
                try handle.close()
                let recording = RecordingFileSystem()
                let started = Date()
                let meta = read(path, fileSystem: recording.fileSystem)
                #expect(Date().timeIntervalSince(started) < 2)
                #expect(meta?.cwd == "/Users/tester/proj")
                #expect(meta?.title == "Tail title")
                #expect(recording.bytesRead <= ExternalSessionTranscript.headBytes + ExternalSessionTranscript.tailBytes)
                #expect(recording.reads.count == 2)
            }
        }

        @Test func aTenMegabyteSingleLineGivesNothingAndReadsOnlyTheWindows() throws {
            try withHome { home in
                let path = home.projects + "/d/" + id + ".jsonl"
                try FileManager.default.createDirectory(atPath: home.projects + "/d", withIntermediateDirectories: true)
                let line = "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/Users/tester/proj\",\"pad\":\"" + String(repeating: "p", count: 10 << 20) + "\"}\n"
                try line.write(toFile: path, atomically: false, encoding: .utf8)
                let recording = RecordingFileSystem()
                let meta = read(path, fileSystem: recording.fileSystem)
                #expect(meta?.cwd == nil)
                #expect(meta?.title == nil)
                #expect(recording.bytesRead <= ExternalSessionTranscript.headBytes + ExternalSessionTranscript.tailBytes)
            }
        }

        @Test func aLineLongerThan64KiBInsideTheWindowIsDropped() throws {
            try withHome { home in
                let huge = F.json(["type": "custom-title", "sessionId": id, "customTitle": "Huge", "pad": String(repeating: "p", count: 70_000)])
                let path = try home.transcript(directory: "d", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj"), huge, F.customTitle(id: id, "Normal")])
                #expect(read(path)?.title == "Normal")
                let onlyHuge = try home.transcript(directory: "d2", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj"), huge])
                #expect(read(onlyHuge)?.title == nil)
            }
        }

        @Test func theReadBudgetIsSpentByTheBytesActuallyReturned() throws {
            try withHome { home in
                let path = try home.transcript(directory: "d", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj")])
                var budget = ExternalSessionTranscript.Budget(remaining: 1_000_000)
                let size = home.fileSystemSize(path)
                _ = ExternalSessionTranscript.read(path: path, id: id, size: size, fileSystem: .live, budget: &budget)
                #expect(budget.remaining == 1_000_000 - size)
            }
        }

        @Test func anUnreadableOrEmptyFileGivesNil() throws {
            try withHome { home in
                let path = try home.transcript(directory: "d", id: id, lines: [F.user(id: id, cwd: "/Users/tester/proj")])
                #expect(read(path + ".nope", size: 100) == nil)
                #expect(read(path, size: 0) == nil)
                let denied = ExternalSessionFileSystem(userID: 0, realpath: { $0 }, lstat: { _ in nil }, list: { _ in .failed }, read: { _, _, _ in nil })
                #expect(read(path, size: 100, fileSystem: denied) == nil)
            }
        }
    }

}
extension ExternalHome {
    func fileSystemSize(_ path: String) -> Int64 { ExternalSessionFileSystem.live.lstat(path)?.size ?? 0 }
}

extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw NSError(domain: "unwrap", code: 1) }
        return self
    }
}
#endif
