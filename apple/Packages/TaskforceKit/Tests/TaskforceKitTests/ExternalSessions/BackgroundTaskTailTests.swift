#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 백그라운드 일의 출력 꼬리 읽기 (DZ v2 E10, 열린 질문 3: 21.4의 읽기 범위를 넓히는 일 — PR-D1과 같은 수준의 하드닝, Opus 보안 검토 대상).
    /// 읽는 것은 **한 일의 출력 파일 하나**의 끝 부분뿐이다: 경로는 기록에서 오지 않고 (세션 id · 일의 id · 작업 폴더)로 **만든다**, 그 길의 모든 폴더는 이 uid의 진짜 폴더(기호 링크 아님)여야 하고,
    /// 파일은 이 uid의 일반 파일이어야 하며, 열기는 `O_NOFOLLOW`다. 에이전트 일의 출력 파일은 기호 링크라서 따라가지 않고 세션 폴더의 `subagents/agent-<id>.jsonl`을 직접 읽는다.
    /// 메모리에만 두고 로그 · `description`에 글을 남기지 않는다. 사용자의 실제 기록 · 임시 폴더는 열지 않는다 (가짜 홈)
    struct BackgroundTaskTailTests {
        typealias F = ExternalSessionFixture
        typealias V = SessionViewLine
        let session = F.uuid(0xE1)
        let cwd = "/Users/tester/proj"
        let taskID = "bk1abc9xy"
        var directory: String { ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "" }
        static let bodySentinel = "SENTINEL-TAIL-BODY-TEXT"

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func tail(_ home: ExternalHome, fileSystem: ExternalSessionFileSystem = .live, limits: BackgroundTaskTail.Limits = .standard) -> BackgroundTaskTail {
            BackgroundTaskTail(fileSystem: fileSystem, claudeDirectory: home.claude, temporaryRoot: home.root + "/tmp", limits: limits)
        }

        private func tasksDirectory(_ home: ExternalHome, project: String? = nil, session: String? = nil) throws -> String {
            let path = "\(home.root)/tmp/claude-\(getuid())/\(project ?? directory)/\(session ?? self.session)/tasks"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }

        @discardableResult
        private func output(_ home: ExternalHome, _ text: String, task: String? = nil) throws -> String {
            let path = try tasksDirectory(home) + "/\(task ?? taskID).output"
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
            return path
        }

        private func text(_ result: BackgroundTaskTail.Result) -> (text: String, hasEarlier: Bool)? {
            if case .output(.text(let text, let earlier)) = result { return (text, earlier) }
            return nil
        }

        private func read(
            _ tail: BackgroundTaskTail, task: String? = nil, kind: BackgroundTaskKind = .command, session: String? = nil, cwd: String?? = nil, window: Int = BackgroundTaskTail.Limits.standard.tailBytes
        ) -> BackgroundTaskTail.Result {
            tail.read(sessionID: session ?? self.session, cwd: cwd ?? self.cwd, taskID: task ?? taskID, kind: kind, window: window)
        }

        // MARK: 명령 일: 끝 부분만

        @Test func aShortOutputIsReadWholeAndHasNothingEarlier() throws {
            try withHome { home in
                try output(home, "> next dev --port 3000\n\n  Local: http://localhost:3000\n")
                let found = text(read(tail(home)))
                #expect(found?.text == "> next dev --port 3000\n\n  Local: http://localhost:3000")
                #expect(found?.hasEarlier == false)
            }
        }

        @Test func aLongOutputIsTheLastSixteenKilobytesStartingAtALineStart() throws {
            try withHome { home in
                let lines = (0..<4000).map { "line \($0) " + String(repeating: "x", count: 40) }
                try output(home, lines.joined(separator: "\n") + "\n")
                let found = try #require(text(read(tail(home))))
                #expect(found.hasEarlier)
                #expect(found.text.utf8.count <= 16 << 10)
                #expect(found.text.hasSuffix("line 3999 " + String(repeating: "x", count: 40)))
                let first = try #require(found.text.split(separator: "\n").first)
                #expect(first.hasPrefix("line "), "잘린 줄의 조각이 맨 앞에 남지 않는다")
            }
        }

        @Test func showEarlierWidensTheWindowStepByStepAndTheWindowHasAHardCap() throws {
            try withHome { home in
                let lines = (0..<40_000).map { "line \($0) " + String(repeating: "y", count: 40) }
                try output(home, lines.joined(separator: "\n") + "\n")
                let reader = tail(home)
                let small = try #require(text(read(reader)))
                let wider = try #require(text(read(reader, window: 64 << 10)))
                #expect(wider.text.utf8.count > small.text.utf8.count && wider.text.utf8.count <= 64 << 10 && wider.text.hasSuffix(small.text))
                let recorder = RecordingFileSystem()
                let capped = try #require(text(read(tail(home, fileSystem: recorder.fileSystem), window: 1 << 30)))
                #expect(capped.text.utf8.count <= BackgroundTaskTail.Limits.standard.maxTailBytes && capped.hasEarlier, "창은 상한을 넘지 않는다")
                #expect(recorder.reads.allSatisfy { $0.length <= BackgroundTaskTail.Limits.standard.maxTailBytes })
                let tiny = text(read(reader, window: 0))
                #expect(tiny != nil, "0 이하의 창은 기본 크기로 본다")
            }
        }

        @Test func aHugeSparseFileReadsOnlyTheTailAndNotTheWholeFile() throws {
            try withHome { home in
                let path = try output(home, "head\n")
                let handle = try #require(FileHandle(forWritingAtPath: path))
                try handle.truncate(atOffset: 5 << 30)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("the very end\n".utf8))
                try handle.close()
                let recorder = RecordingFileSystem()
                let started = ContinuousClock.now
                let found = text(read(tail(home, fileSystem: recorder.fileSystem)))
                #expect(ContinuousClock.now - started < .seconds(5))
                #expect(found?.hasEarlier == true && found?.text.hasSuffix("the very end") == true)
                #expect(recorder.reads.allSatisfy { $0.length <= 16 << 10 }, "한 번에 16 KiB를 넘게 읽지 않는다")
                #expect(recorder.bytesRead <= 16 << 10)
            }
        }

        @Test func aMultiByteCharacterSplitByTheCutDoesNotLeaveABrokenCharacter() throws {
            try withHome { home in
                let body = String(repeating: "한", count: 20_000) + "\nend"
                try output(home, body)
                let found = try #require(text(read(tail(home))))
                #expect(!found.text.contains("\u{FFFD}"))
                #expect(found.text.hasSuffix("end"))
            }
        }

        @Test func aSingleLineLongerThanTheWindowStartsAtACharacterBoundary() throws {
            try withHome { home in
                try output(home, String(repeating: "가", count: 30_000))
                let found = try #require(text(read(tail(home))))
                #expect(!found.text.contains("\u{FFFD}") && found.hasEarlier && !found.text.isEmpty)
            }
        }

        @Test func colourCodesControlCharactersAndInvisibleFormattingAreRemoved() throws {
            try withHome { home in
                let raw = "\u{1B}[31mred\u{1B}[0m text\u{1B}]0;title\u{07} ok\u{0}\u{7}bell\r\nprogress 10%\rprogress 100%\n\u{202E}reversed\u{200B}zero\u{200D}joiner"
                try output(home, raw)
                let found = try #require(text(read(tail(home))))
                #expect(found.text == "red text okbell\nprogress 10%\nprogress 100%\nreversedzero\u{200D}joiner")
                #expect(!found.text.contains("\u{1B}") && !found.text.contains("[31m") && !found.text.contains("\u{202E}"))
            }
        }

        @Test func anEmptyFileIsAnEmptyOutputAndAMissingFileOrFolderIsMissing() throws {
            try withHome { home in
                #expect(read(tail(home)) == .missing, "아무 폴더도 아직 없다")
                _ = try tasksDirectory(home)
                #expect(read(tail(home)) == .missing, "일의 폴더는 있고 파일은 아직 없다")
                try output(home, "")
                #expect(text(read(tail(home)))?.text == "")
            }
        }

        // MARK: 길 확인: 기호 링크 · 폴더 밖 · 남의 것 · 일반 파일 아님

        @Test func anOutputFileThatIsASymbolicLinkIsNeverFollowed() throws {
            try withHome { home in
                let secret = home.root + "/outside-secret.txt"
                try Data(Self.bodySentinel.utf8).write(to: URL(fileURLWithPath: secret))
                let dir = try tasksDirectory(home)
                try home.link(dir + "/\(taskID).output", to: secret)
                let recorder = RecordingFileSystem()
                #expect(read(tail(home, fileSystem: recorder.fileSystem)) == .unreadable)
                #expect(recorder.reads.isEmpty, "기호 링크는 열어 보지도 않는다")
            }
        }

        @Test func aSymbolicLinkInAnyFolderOfThePathIsRefusedBeforeReading() throws {
            for level in ["claude", "project", "session", "tasks"] {
                try withHome { home in
                    let outside = home.root + "/outside"
                    try FileManager.default.createDirectory(atPath: outside + "/tasks", withIntermediateDirectories: true)
                    try Data(Self.bodySentinel.utf8).write(to: URL(fileURLWithPath: outside + "/tasks/\(taskID).output"))
                    let base = "\(home.root)/tmp/claude-\(getuid())"
                    switch level {
                    case "claude":
                        try FileManager.default.createDirectory(atPath: home.root + "/tmp", withIntermediateDirectories: true)
                        try FileManager.default.createDirectory(atPath: outside + "/\(directory)/\(session)", withIntermediateDirectories: true)
                        try FileManager.default.moveItem(atPath: outside + "/tasks", toPath: outside + "/\(directory)/\(session)/tasks")
                        try home.link(base, to: outside)
                    case "project":
                        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
                        try FileManager.default.createDirectory(atPath: outside + "/\(session)", withIntermediateDirectories: true)
                        try FileManager.default.moveItem(atPath: outside + "/tasks", toPath: outside + "/\(session)/tasks")
                        try home.link(base + "/" + directory, to: outside)
                    case "session":
                        try FileManager.default.createDirectory(atPath: base + "/" + directory, withIntermediateDirectories: true)
                        try home.link(base + "/" + directory + "/" + session, to: outside)
                    default:
                        try FileManager.default.createDirectory(atPath: base + "/" + directory + "/" + session, withIntermediateDirectories: true)
                        try home.link(base + "/" + directory + "/" + session + "/tasks", to: outside + "/tasks")
                    }
                    let recorder = RecordingFileSystem()
                    #expect(read(tail(home, fileSystem: recorder.fileSystem)) == .unreadable, "\(level) 폴더가 기호 링크다")
                    #expect(recorder.reads.isEmpty)
                }
            }
        }

        @Test func aTemporaryRootReachedThroughALinkIsRefused() throws {
            try withHome { home in
                let real = home.root + "/real-tmp"
                try FileManager.default.createDirectory(atPath: "\(real)/claude-\(getuid())/\(directory)/\(session)/tasks", withIntermediateDirectories: true)
                try Data("x".utf8).write(to: URL(fileURLWithPath: "\(real)/claude-\(getuid())/\(directory)/\(session)/tasks/\(taskID).output"))
                try home.link(home.root + "/tmp", to: real)
                #expect(read(tail(home)) == .unreadable)
            }
        }

        @Test func aFolderOrFileThatIsNotOursIsRefused() throws {
            try withHome { home in
                try output(home, "hello")
                let base = ExternalSessionFileSystem.live
                for suffix in ["/tasks", "/tasks/\(taskID).output", "/\(session)", "/claude-\(getuid())"] {
                    let strangers = ExternalSessionFileSystem(
                        userID: base.userID, realpath: base.realpath,
                        lstat: { path in
                            guard var entry = base.lstat(path) else { return nil }
                            if path.hasSuffix(suffix) { entry.owner = entry.owner &+ 1 }
                            return entry
                        },
                        list: base.list, read: base.read
                    )
                    #expect(read(tail(home, fileSystem: strangers)) == .unreadable, "남의 것: \(suffix)")
                }
                // 읽기 쪽 검사: 열린 파일이 남의 것이면 nil (실제 파일 시스템 읽기가 거른다)
                let foreignRead = ExternalSessionFileSystem(userID: base.userID, realpath: base.realpath, lstat: base.lstat, list: base.list, read: { _, _, _ in nil })
                #expect(read(tail(home, fileSystem: foreignRead)) == .unreadable)
            }
        }

        @Test func aFolderWhoseRealPathIsNotItsOwnPathIsRefused() throws {
            try withHome { home in
                try output(home, "hello")
                let base = ExternalSessionFileSystem.live
                #expect(text(read(tail(home))) != nil, "바꾸지 않은 파일 시스템은 읽는다")
                // `lstat`은 진짜 폴더라고 하는데 `realpath`가 다른 곳을 가리키는 길(기호 링크가 위에 끼었다): 길 어디에서든 거절한다
                for suffix in ["/tasks", "/\(session)", "/\(directory)", "/claude-\(getuid())"] {
                    let rerouted = ExternalSessionFileSystem(
                        userID: base.userID,
                        realpath: { path in path.hasSuffix(suffix) ? base.realpath(path).map { $0 + "-elsewhere" } : base.realpath(path) },
                        lstat: base.lstat, list: base.list, read: base.read
                    )
                    #expect(read(tail(home, fileSystem: rerouted)) == .unreadable, "다른 곳으로 이어진 길: \(suffix)")
                }
            }
        }

        @Test func aFifoOrADirectoryInPlaceOfTheOutputFileIsRefusedWithoutBlocking() throws {
            try withHome { home in
                let dir = try tasksDirectory(home)
                #expect(mkfifo(dir + "/\(taskID).output", 0o644) == 0)
                let recorder = RecordingFileSystem()
                let started = ContinuousClock.now
                #expect(read(tail(home, fileSystem: recorder.fileSystem)) == .unreadable)
                #expect(ContinuousClock.now - started < .seconds(5) && recorder.reads.isEmpty)
                try FileManager.default.removeItem(atPath: dir + "/\(taskID).output")
                try FileManager.default.createDirectory(atPath: dir + "/\(taskID).output", withIntermediateDirectories: true)
                #expect(read(tail(home, fileSystem: recorder.fileSystem)) == .unreadable)
            }
        }

        @Test func aTaskIdThatCouldEscapeTheFolderNeverTouchesTheFileSystem() throws {
            try withHome { home in
                try output(home, "hello")
                let recorder = RecordingFileSystem()
                let reader = tail(home, fileSystem: recorder.fileSystem)
                for bad in ["", "../x", "a/b", "..", ".", "with space", String(repeating: "z", count: 65), "a\u{0}b", "bk1abc9xy/../bk1abc9xy", "x\n"] {
                    #expect(read(reader, task: bad) == .unreadable, "\(bad.debugDescription)")
                }
                #expect(recorder.statted.isEmpty && recorder.reads.isEmpty && recorder.listed.isEmpty && recorder.resolved.isEmpty, "검사가 파일 시스템보다 먼저다")
            }
        }

        @Test func aSessionIdThatIsNotACanonicalUuidIsRefusedBeforeAnyAccess() throws {
            try withHome { home in
                let recorder = RecordingFileSystem()
                let reader = tail(home, fileSystem: recorder.fileSystem)
                for bad in ["", "../x", "5E5E5E5E-0000-4000-8000-0000000000E1", "not-a-uuid", session + "/../" + session] {
                    #expect(read(reader, session: bad) == .unreadable)
                }
                #expect(recorder.statted.isEmpty && recorder.reads.isEmpty)
            }
        }

        @Test func aFolderNamedByTheWorkingFolderNeverEscapesAndAnUnusableWorkingFolderFallsBackToTheNamesOnly() throws {
            try withHome { home in
                try output(home, "hello")
                // 작업 폴더를 모르면 `claude-<uid>` 아래 폴더 이름만 훑어 그 세션의 폴더를 찾는다 (다른 파일은 열지 않는다)
                #expect(text(read(tail(home), cwd: .some(nil)))?.text == "hello")
                #expect(text(read(tail(home), cwd: "/Users/other/where"))?.text == "hello", "맞지 않는 작업 폴더도 이름 훑기로 찾는다")
                #expect(text(read(tail(home), cwd: "relative/../path"))?.text == "hello", "평범한 절대 경로가 아닌 작업 폴더는 짐작에 쓰지 않는다")
                let recorder = RecordingFileSystem()
                _ = read(tail(home, fileSystem: recorder.fileSystem), cwd: .some(nil))
                #expect(recorder.reads.count == 1, "훑기가 여러 파일을 읽지 않는다")
            }
        }

        @Test func aCrowdedFolderOfNamesIsNotScannedWithoutALimit() throws {
            try withHome { home in
                let base = "\(home.root)/tmp/claude-\(getuid())"
                try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
                for n in 0..<(ExternalSessionRegistry.maxListed + 5) { try FileManager.default.createDirectory(atPath: base + "/p\(n)", withIntermediateDirectories: true) }
                let recorder = RecordingFileSystem()
                #expect(read(tail(home, fileSystem: recorder.fileSystem), cwd: .some(nil)) == .unreadable)
                #expect(recorder.listCalls.allSatisfy { $0.limit <= ExternalSessionRegistry.maxListed + 1 })
            }
        }

        // MARK: 에이전트 일: 세션 폴더의 subagents 파일을 직접

        private func subagentsDirectory(_ home: ExternalHome) throws -> String {
            let path = "\(home.projects)/\(directory)/\(session)/subagents"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }

        private func agentLine(_ kind: String, blocks: [[String: Any]], agent: String = "a02862466294fcd8e", sidechain: Bool = true, timestamp: String = "2026-10-22T01:00:10.000Z") -> String {
            F.json([
                "type": kind, "isSidechain": sidechain, "agentId": agent, "sessionId": session, "timestamp": timestamp, "uuid": UUID().uuidString.lowercased(),
                "message": ["role": kind, "content": blocks],
            ])
        }

        @Test func anAgentTaskReadsTheSubagentFileNotTheSymbolicLinkInTheTaskFolder() throws {
            try withHome { home in
                let agent = "a02862466294fcd8e"
                let sub = try subagentsDirectory(home)
                try [
                    agentLine("user", blocks: [["type": "text", "text": V.promptSentinel]]),
                    agentLine("assistant", blocks: [["type": "text", "text": "Three strings still say 평가판."]]),
                    agentLine("assistant", blocks: [["type": "tool_use", "id": "tu", "name": "Read", "input": ["file_path": "/Users/tester/\(V.pathSentinel)/ko.json"]]]),
                    agentLine("user", blocks: [["type": "tool_result", "tool_use_id": "tu", "content": V.stdoutSentinel]]),
                    agentLine("assistant", blocks: [["type": "tool_use", "id": "tu2", "name": "Bash", "input": ["command": V.commandSentinel, "description": "Count the strings"]]]),
                ].joined(separator: "\n").appending("\n").write(toFile: sub + "/agent-\(agent).jsonl", atomically: false, encoding: .utf8)
                try home.link(try tasksDirectory(home) + "/\(agent).output", to: sub + "/agent-\(agent).jsonl")
                let recorder = RecordingFileSystem()
                guard case .output(.agent(let turns, let earlier)) = read(tail(home, fileSystem: recorder.fileSystem), task: agent, kind: .agent) else {
                    Issue.record("에이전트 꼬리를 읽지 못했다")
                    return
                }
                #expect(!earlier)
                #expect(turns.map(\.kind) == [.assistant("Three strings still say 평가판."), .tool(name: "Read", description: nil), .tool(name: "Bash", description: "Count the strings")])
                #expect(turns.map(\.target) == [nil, "ko.json", nil])
                #expect(recorder.reads.allSatisfy { $0.path == sub + "/agent-\(agent).jsonl" }, "작업 폴더의 기호 링크를 열지 않는다")
                var dump = ""
                Swift.dump(turns, to: &dump)
                for sentinel in V.neverShown { #expect(!(dump + String(reflecting: turns)).contains(sentinel)) }
            }
        }

        @Test func anAgentTaskWithoutItsSubagentFileIsMissingEvenIfTheLinkInTheTaskFolderExists() throws {
            try withHome { home in
                let agent = "a02862466294fcd8e"
                let secret = home.root + "/outside-agent.jsonl"
                try Data(agentLine("assistant", blocks: [["type": "text", "text": Self.bodySentinel]]).utf8).write(to: URL(fileURLWithPath: secret))
                try home.link(try tasksDirectory(home) + "/\(agent).output", to: secret)
                #expect(read(tail(home), task: agent, kind: .agent) == .missing)
            }
        }

        @Test func aSubagentFileOrFolderThatIsALinkOrForeignIsRefused() throws {
            try withHome { home in
                let agent = "a02862466294fcd8e"
                let real = home.root + "/elsewhere.jsonl"
                try Data(agentLine("assistant", blocks: [["type": "text", "text": Self.bodySentinel]]).utf8).write(to: URL(fileURLWithPath: real))
                let sub = try subagentsDirectory(home)
                try home.link(sub + "/agent-\(agent).jsonl", to: real)
                let recorder = RecordingFileSystem()
                #expect(read(tail(home, fileSystem: recorder.fileSystem), task: agent, kind: .agent) == .unreadable)
                #expect(recorder.reads.isEmpty)
                try FileManager.default.removeItem(atPath: sub + "/agent-\(agent).jsonl")
                try FileManager.default.removeItem(atPath: sub)
                try FileManager.default.createDirectory(atPath: home.root + "/other-sub", withIntermediateDirectories: true)
                try Data(agentLine("assistant", blocks: [["type": "text", "text": Self.bodySentinel]]).utf8).write(to: URL(fileURLWithPath: home.root + "/other-sub/agent-\(agent).jsonl"))
                try home.link(sub, to: home.root + "/other-sub")
                #expect(read(tail(home, fileSystem: recorder.fileSystem), task: agent, kind: .agent) == .unreadable)
                #expect(recorder.reads.isEmpty)
            }
        }

        @Test func anAgentFileKeepsTheLastTwoHundredTurnsAndSkipsHugeLines() throws {
            try withHome { home in
                let agent = "a02862466294fcd8e"
                let sub = try subagentsDirectory(home)
                var lines = (0..<300).map { agentLine("assistant", blocks: [["type": "text", "text": "turn \($0)"]]) }
                lines.insert(agentLine("assistant", blocks: [["type": "text", "text": String(repeating: "h", count: (1 << 20) + 10)]]), at: 150)
                try (lines.joined(separator: "\n") + "\n").write(toFile: sub + "/agent-\(agent).jsonl", atomically: false, encoding: .utf8)
                guard case .output(.agent(let turns, let earlier)) = read(tail(home), task: agent, kind: .agent) else {
                    Issue.record("에이전트 꼬리를 읽지 못했다")
                    return
                }
                #expect(turns.count == 200 && earlier)
                #expect(turns.last?.kind == .assistant("turn 299") && turns.first?.kind == .assistant("turn 100"))
            }
        }

        @Test func aNonAgentFileOrAnotherAgentsLinesAreNotShown() throws {
            try withHome { home in
                let agent = "a02862466294fcd8e"
                let sub = try subagentsDirectory(home)
                let lines = [
                    agentLine("assistant", blocks: [["type": "text", "text": "mine"]]),
                    agentLine("assistant", blocks: [["type": "text", "text": "someone else's"]], agent: "affffffffffffffff"),
                    "not json at all",
                    F.json(["type": "attachment", "attachment": ["type": "session_context", "account": ["email": V.pathSentinel]], "agentId": agent]),
                ]
                try (lines.joined(separator: "\n") + "\n").write(toFile: sub + "/agent-\(agent).jsonl", atomically: false, encoding: .utf8)
                guard case .output(.agent(let turns, _)) = read(tail(home), task: agent, kind: .agent) else {
                    Issue.record("에이전트 꼬리를 읽지 못했다")
                    return
                }
                #expect(turns.map(\.kind) == [.assistant("mine")])
            }
        }

        // MARK: 값

        @Test func theValuesNeverPrintTheirText() throws {
            try withHome { home in
                try output(home, Self.bodySentinel)
                let result = read(tail(home))
                let printed = String(describing: result) + String(reflecting: result)
                #expect(!printed.contains(Self.bodySentinel))
                #expect(String(describing: tail(home)).contains(home.root) == false)
            }
        }
    }
}
#endif
