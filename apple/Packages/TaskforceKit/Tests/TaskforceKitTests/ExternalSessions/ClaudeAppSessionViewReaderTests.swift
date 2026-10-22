#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 세션 보기 V1이 기록 읽기에 더하는 것 (DZ oa-session-view-dz v2): 단계 줄의 파일 이름 · 실패(`tool_result.is_error`) · 백그라운드 일의 시작과 끝 줄.
    /// PR-D1 읽기의 약속은 그대로다: 선언한 칸만 꺼내고(파일 **이름**만, 불리언 하나, 아이디 · 상태 · 끝낸 코드) 명령 · 경로 · 결과 · 요약 · 프롬프트의 글은 값으로 남지 않는다
    struct ClaudeAppSessionViewReaderTests {
        typealias F = ExternalSessionFixture
        typealias L = ClaudeAppLine
        typealias V = SessionViewLine
        let id = F.uuid(0xD7)
        let cwd = "/Users/tester/proj"
        var directory: String { ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "" }

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func reader(_ home: ExternalHome, limits: ClaudeAppTranscriptReader.Limits = .standard) -> ClaudeAppTranscriptReader {
            ClaudeAppTranscriptReader(claudeDirectory: home.claude, limits: limits)
        }

        private func page(_ load: ClaudeAppTranscriptLoad, sourceLocation: SourceLocation = #_sourceLocation) -> ClaudeAppTranscriptPage? {
            if case .page(let page) = load { return page }
            Issue.record("기록을 읽지 못했다", sourceLocation: sourceLocation)
            return nil
        }

        private func append(_ path: String, _ text: String) throws {
            let handle = try #require(FileHandle(forWritingAtPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        private func dumped(_ value: Any) -> String {
            var text = ""
            Swift.dump(value, to: &text)
            return text + String(describing: value) + String(reflecting: value)
        }

        // MARK: 단계 줄의 대상: 파일 이름만 (E2)

        @Test func aFileToolStepCarriesTheFileNameAndNeverThePath() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "t1", name: "Read", input: ["file_path": "/Users/tester/\(V.pathSentinel)/content/pricing.mdx"]),
                    V.tool(id: id, toolID: "t2", name: "Edit", input: ["file_path": "/Users/tester/\(V.pathSentinel)/i18n/ko.json", "old_string": V.commandSentinel, "new_string": "x"]),
                    V.tool(id: id, toolID: "t3", name: "Write", input: ["file_path": "/Users/tester/\(V.pathSentinel)/CHANGELOG.md", "content": V.commandSentinel]),
                    V.tool(id: id, toolID: "t4", name: "NotebookEdit", input: ["notebook_path": "/Users/tester/\(V.pathSentinel)/analysis.ipynb"]),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.dropFirst().map(\.target) == ["pricing.mdx", "ko.json", "CHANGELOG.md", "analysis.ipynb"])
                let text = dumped(page)
                for sentinel in V.neverShown { #expect(!text.contains(sentinel), "\(sentinel)이 값에 남았다") }
            }
        }

        @Test func bashGrepGlobAndOtherToolsHaveNoTargetOnlyTheirDescription() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "t1", name: "Bash", input: ["command": V.commandSentinel, "description": "Run the copy lint"]),
                    V.tool(id: id, toolID: "t2", name: "Grep", input: ["pattern": V.patternSentinel, "path": "/Users/tester/\(V.pathSentinel)"]),
                    V.tool(id: id, toolID: "t3", name: "Glob", input: ["pattern": "**/*.\(V.patternSentinel)"]),
                    V.tool(id: id, toolID: "t4", name: "WebFetch", input: ["url": "https://example.com/\(V.pathSentinel)"]),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.dropFirst().map(\.target) == [nil, nil, nil, nil])
                #expect(page.turns[1].kind == .tool(name: "Bash", description: "Run the copy lint"))
                let text = dumped(page)
                for sentinel in V.neverShown { #expect(!text.contains(sentinel)) }
            }
        }

        @Test func aFilePathThatIsNotAStringOrHasNoNameGivesNoTarget() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "t1", name: "Read", input: ["file_path": 12]),
                    V.tool(id: id, toolID: "t2", name: "Read", input: ["file_path": "/Users/tester/dir/"]),
                    V.tool(id: id, toolID: "t3", name: "Read", input: ["file_path": ""]),
                    V.tool(id: id, toolID: "t4", name: "Read", input: [:]),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.dropFirst().map(\.target) == [nil, nil, nil, nil])
            }
        }

        // MARK: 실패 (E2 "Failed")

        @Test func aResultWithIsErrorTrueNamesItsToolAndTheErrorTextIsNeverRead() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "t1", name: "Bash", input: ["command": "x"]),
                    V.result(id: id, toolID: "t1", text: V.errorSentinel, isError: true),
                    V.tool(id: id, toolID: "t2", name: "Bash", input: ["command": "x"]),
                    V.result(id: id, toolID: "t2", text: V.errorSentinel, isError: false),
                    V.tool(id: id, toolID: "t3", name: "Read", input: [:]),
                    V.result(id: id, toolID: "t3", text: V.errorSentinel, isError: nil),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.failedToolIDs == ["t1"])
                #expect(page.turns.map(\.kind).count == 4, "결과 줄은 대화가 아니다")
                let text = dumped(page)
                #expect(!text.contains(V.errorSentinel))
            }
        }

        @Test func aFailureThatArrivesInALaterReadIsReportedByThatReadOnlyOnce() throws {
            try withHome { home in
                let path = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), V.tool(id: id, toolID: "t1", name: "Bash", input: [:])])
                let reader = reader(home)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(first.cursor.signals.failedToolIDs.isEmpty)
                try append(path, V.result(id: id, toolID: "t1", isError: true) + "\n")
                guard case .turns(let none, let next, _) = reader.newer(first.cursor) else { Issue.record("이어 읽기"); return }
                #expect(none.isEmpty && next.signals.failedToolIDs == ["t1"])
                guard case .turns(_, let again, _) = reader.newer(next) else { Issue.record("무변경"); return }
                #expect(again.signals == ClaudeAppTranscriptSignals(), "신호는 읽은 그 번에만 있다")
            }
        }

        @Test func aToolIdThatIsTooLongOrEmptyIsNotReportedAsAFailure() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.result(id: id, toolID: String(repeating: "t", count: 129), isError: true),
                    V.result(id: id, toolID: "", isError: true),
                    V.result(id: id, toolID: "ok-id_1", isError: true),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.failedToolIDs == ["ok-id_1"])
            }
        }

        @Test func aResultInASidechainOrAnotherSessionIsNotThisSessionsFailure() throws {
            try withHome { home in
                let sidechain = V.result(id: id, toolID: "side", isError: true).replacingOccurrences(of: "\"isSidechain\":false", with: "\"isSidechain\":true")
                _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), sidechain, V.result(id: F.uuid(0xEE), toolID: "other", isError: true)])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.failedToolIDs.isEmpty)
            }
        }

        // MARK: 백그라운드 일의 시작 (BG-1)

        @Test func aBackgroundBashStartIsAnEventWithItsToolIdAndTimeAndNotATurn() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "toolu_b", name: "Bash", input: ["command": V.commandSentinel, "description": "Run the dev server", "run_in_background": true]),
                    V.bashStarted(id: id, toolID: "toolu_b", taskID: "bk1abc9xy"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.count == 2, "시작 줄은 대화가 아니다")
                #expect(page.cursor.signals.background == [
                    .started(taskID: "bk1abc9xy", toolUseID: "toolu_b", kind: .command, name: nil, at: V.date("2026-10-22T01:00:05.000Z")),
                ])
                let text = dumped(page)
                for sentinel in V.neverShown { #expect(!text.contains(sentinel)) }
            }
        }

        @Test func aBackgroundAgentStartIsAnAgentEventAndItsPromptAndDescriptionAreNotKept() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "toolu_a", name: "Agent", input: ["description": "Audit the pricing strings", "prompt": V.promptSentinel, "run_in_background": true]),
                    V.agentStarted(id: id, toolID: "toolu_a", agentID: "a02862466294fcd8e"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background == [
                    .started(taskID: "a02862466294fcd8e", toolUseID: "toolu_a", kind: .agent, name: nil, at: V.date("2026-10-22T01:00:06.000Z")),
                ])
                #expect(page.turns[1].kind == .tool(name: "Agent", description: "Audit the pricing strings"))
                let text = dumped(page)
                for sentinel in V.neverShown { #expect(!text.contains(sentinel)) }
            }
        }

        @Test func anAgentResultThatIsNotAsyncIsNotABackgroundTask() throws {
            try withHome { home in
                let line = F.json([
                    "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:06.000Z", "isSidechain": false,
                    "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_a", "content": "done"]]],
                    "toolUseResult": ["isAsync": false, "agentId": "a02862466294fcd8e", "status": "completed"],
                ])
                _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), line])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background.isEmpty)
            }
        }

        @Test func aToolUseResultThatIsAStringOrHasAHostileIdIsIgnored() throws {
            try withHome { home in
                func line(_ result: Any) -> String {
                    F.json([
                        "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:06.000Z", "isSidechain": false,
                        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_q", "content": "x"]]], "toolUseResult": result,
                    ])
                }
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"), line("Error: something"), line(["backgroundTaskId": "../../etc/passwd"]), line(["backgroundTaskId": ""]),
                    line(["backgroundTaskId": String(repeating: "z", count: 65)]), line(["backgroundTaskId": 42]), line(["backgroundTaskId": "bad id"]),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background.isEmpty)
            }
        }

        // MARK: 백그라운드 일의 끝 (BG-2)

        @Test func aNotificationLineIsAFinishedEventAndNeverATurnAndTheSummaryQuoteIsNotKept() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.notification(id: id, taskID: "bk1abc9xy", status: "failed", summary: "Background command \"\(V.summarySentinel)\" failed with exit code 3"),
                    V.notification(id: id, taskID: "bk2def0za", status: "completed", summary: "Background command \"\(V.summarySentinel)\" completed (exit code 0)", timestamp: "2026-10-22T01:00:40.000Z"),
                    V.notification(id: id, taskID: "a02862466294fcd8e", status: "completed", summary: "Agent \"\(V.summarySentinel)\" finished", timestamp: "2026-10-22T01:00:50.000Z"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.count == 1, "알림 줄은 대화가 아니다")
                #expect(page.cursor.signals.background == [
                    .finished(taskID: "bk1abc9xy", kind: .command, status: .failed, exitCode: 3, at: V.date("2026-10-22T01:00:30.000Z")),
                    .finished(taskID: "bk2def0za", kind: .command, status: .done, exitCode: 0, at: V.date("2026-10-22T01:00:40.000Z")),
                    .finished(taskID: "a02862466294fcd8e", kind: .agent, status: .done, exitCode: nil, at: V.date("2026-10-22T01:00:50.000Z")),
                ])
                let text = dumped(page)
                for sentinel in V.neverShown { #expect(!text.contains(sentinel)) }
            }
        }

        @Test func theQueuedAttachmentShapeOfANotificationIsReadTheSameWay() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.queuedNotification(id: id, taskID: "bk3ghi1ab", status: "failed", summary: "Background command \"\(V.summarySentinel)\" failed with exit code 12"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.count == 1)
                #expect(page.cursor.signals.background == [
                    .finished(taskID: "bk3ghi1ab", kind: .command, status: .failed, exitCode: 12, at: V.date("2026-10-22T01:00:31.000Z")),
                ])
                let text = dumped(page)
                for sentinel in V.neverShown { #expect(!text.contains(sentinel)) }
            }
        }

        @Test func anUnknownStatusIsStoppedNotDoneAndAMissingStatusIsNoEvent() throws {
            try withHome { home in
                let noStatus = V.notification(id: id, taskID: "bk4jkl2cd", status: "completed", summary: "x").replacingOccurrences(of: "<status>completed</status>", with: "")
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.notification(id: id, taskID: "bk5mno3ef", status: "killed", summary: "Background command \"q\" was stopped"),
                    V.notification(id: id, taskID: "bk6pqr4gh", status: "mystery", summary: "?"),
                    noStatus,
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background.map { event -> String in
                    if case .finished(let task, _, let status, let code, _) = event { return "\(task):\(status):\(code.map(String.init) ?? "-")" }
                    return "other"
                } == ["bk5mno3ef:stopped:-", "bk6pqr4gh:stopped:-"])
            }
        }

        @Test func hostileTaskIdsAndHugeExitCodesAreNotEvents() throws {
            try withHome { home in
                var lines = [L.user(id: id, text: "go")]
                for bad in ["", "../x", "a/b", "with space", String(repeating: "z", count: 65), "a\u{0}b", "<x>"] {
                    lines.append(V.notification(id: id, taskID: bad, status: "completed", summary: "completed (exit code 0)"))
                }
                lines.append(V.notification(id: id, taskID: "bk7stu5ij", status: "failed", summary: "Background command \"x\" failed with exit code 99999999999999999999"))
                _ = try home.transcript(directory: directory, id: id, lines: lines)
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background == [.finished(taskID: "bk7stu5ij", kind: .command, status: .failed, exitCode: nil, at: V.date("2026-10-22T01:00:30.000Z"))])
            }
        }

        @Test func aNotificationLookalikeTypedByTheUserOrWrittenByTheAssistantIsNotAnEvent() throws {
            try withHome { home in
                let text = V.notificationText(taskID: "bk8vwx6kl", status: "completed", summary: "completed (exit code 0)")
                _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: text), L.assistant(id: id, text: text)])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background.isEmpty, "사용자가 친 글 · 어시스턴트의 글은 알림이 아니다")
                #expect(page.turns.count == 2, "그 글은 그대로 대화로 보인다")
            }
        }

        @Test func aNotificationShapedTextFromAnotherOriginKindIsNotAnEvent() throws {
            try withHome { home in
                // 출처 표시가 있어도 `task-notification`이 아니면(훅 · 다른 도구 · 낯선 값) 알림이 아니다: 글 모양만으로 일 사건을 만들지 않는다
                let real = V.notification(id: id, taskID: "bk5efg3hi", status: "completed", summary: "Background command done (exit code 0)")
                for kind in ["hook", "system-reminder", "human", "task-notification-x", ""] {
                    let impostor = real.replacingOccurrences(of: "\"kind\":\"task-notification\"", with: "\"kind\":\"\(kind)\"")
                    #expect(impostor != real, "시험 자체: 출처 종류가 바뀌었다 (\(kind))")
                    _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), impostor])
                    guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                    #expect(page.cursor.signals.background.isEmpty, "출처 \(kind)")
                }
            }
        }

        @Test func aNotificationOfAnotherSessionOrASidechainIsIgnored() throws {
            try withHome { home in
                let other = V.notification(id: F.uuid(0xEE), taskID: "bk9yza7mn", status: "completed", summary: "completed (exit code 0)")
                let side = V.notification(id: id, taskID: "bk0bcd8op", status: "completed", summary: "completed (exit code 0)").replacingOccurrences(of: "\"isSidechain\":false", with: "\"isSidechain\":true")
                _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), other, side])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.background.isEmpty)
            }
        }

        @Test func aPeerMessageAndTheOtherOriginLinesBehaveAsBefore() throws {
            try withHome { home in
                let hook = F.json([
                    "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:30.000Z", "isSidechain": false,
                    "origin": ["kind": "hook"], "message": ["role": "user", "content": "hook says hello"],
                ])
                _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), hook])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.turns.map(\.kind) == [.user("go")], "task-notification이 아닌 origin 줄은 지금처럼 버린다")
                #expect(page.cursor.signals == ClaudeAppTranscriptSignals())
            }
        }

        // MARK: 신호는 읽은 번의 것

        @Test func theEarlierPageReportsOnlyTheSignalsOfItsOwnWindow() throws {
            try withHome { home in
                var lines = [L.user(id: id, text: "old"), V.tool(id: id, toolID: "old1", name: "Bash", input: [:]), V.result(id: id, toolID: "old1", isError: true)]
                lines += (0..<40).map { L.assistant(id: id, text: "filler \($0) " + String(repeating: "x", count: 600)) }
                lines += [V.tool(id: id, toolID: "new1", name: "Bash", input: [:]), V.result(id: id, toolID: "new1", isError: true)]
                _ = try home.transcript(directory: directory, id: id, lines: lines)
                let limits = ClaudeAppTranscriptReader.Limits(windowBytes: 8_000, pageTurns: 5)
                let reader = reader(home, limits: limits)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(first.cursor.signals.failedToolIDs.contains("new1") && !first.cursor.signals.failedToolIDs.contains("old1"))
                var cursor = first.cursor
                var seen = Set(first.cursor.signals.failedToolIDs)
                for _ in 0..<12 {
                    guard case .page(let next) = reader.earlier(cursor) else { break }
                    seen.formUnion(next.cursor.signals.failedToolIDs)
                    cursor = next.cursor
                    if !next.hasEarlier { break }
                }
                #expect(seen == ["new1", "old1"])
            }
        }

        @Test func theNoChangeReadsCarryNoSignals() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), V.tool(id: id, toolID: "t1", name: "Bash", input: [:]), V.result(id: id, toolID: "t1", isError: true)])
                let reader = reader(home)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(first.cursor.signals.failedToolIDs == ["t1"])
                guard case .turns(_, let same, _) = reader.newer(first.cursor) else { Issue.record("무변경"); return }
                #expect(same.signals == ClaudeAppTranscriptSignals() && same.nextOffset == first.cursor.nextOffset)
            }
        }

        @Test func theValuesNeverPrintTheirSignalsAsText() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "toolu_b", name: "Bash", input: ["description": "d"]),
                    V.bashStarted(id: id, toolID: "toolu_b", taskID: "bk1abc9xy"),
                    V.result(id: id, toolID: "toolu_b", isError: true),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                let described = String(describing: page.cursor) + String(reflecting: page.cursor) + String(describing: page.cursor.signals)
                #expect(!described.contains("bk1abc9xy") && !described.contains("toolu_b"), "description은 아이디를 찍지 않는다")
            }
        }
    }
}
#endif
