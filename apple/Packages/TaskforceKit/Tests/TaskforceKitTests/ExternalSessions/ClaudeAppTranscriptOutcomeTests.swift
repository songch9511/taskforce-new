#if os(macOS) && DEBUG
import Darwin
import Foundation
import Testing
@testable import TaskforceKit

extension ExternalSessionSuites {
    /// 기록 읽기가 도구 결과 줄에서 꺼내는 끝 사실 (T1, 검토 뒤 계약 5장): 하위 에이전트의 상태를 메타의 `toolUseId`와 짝지을 때 쓴다.
    /// 나오는 것은 **오류로 끝난 결과**(`is_error`)와 **에이전트가 끝나 돌려준 결과**(`toolUseResult.agentId`가 있고 비동기 시작이 아닌 것)뿐이고, 도구 호출 id · 실패 여부 · 그 줄의 시각만 담는다.
    /// 비동기 시작 줄(`isAsync == true`)은 끝이 아니다 (백그라운드 일의 시작 사건으로만 나간다). 결과 글 · 프롬프트는 읽지 않는다
    struct ClaudeAppTranscriptOutcomeTests {
        typealias F = ExternalSessionFixture
        typealias L = ClaudeAppLine
        typealias V = SessionViewLine
        let id = F.uuid(0xD8)
        let cwd = "/Users/tester/proj"
        var directory: String { ExternalSessionRules.projectDirectoryName(forCwd: cwd) ?? "" }

        private func withHome<T>(_ body: (ExternalHome) throws -> T) throws -> T {
            let home = try ExternalHome()
            defer { home.cleanup() }
            return try body(home)
        }

        private func reader(_ home: ExternalHome) -> ClaudeAppTranscriptReader { ClaudeAppTranscriptReader(claudeDirectory: home.claude) }

        private func page(_ load: ClaudeAppTranscriptLoad, sourceLocation: SourceLocation = #_sourceLocation) -> ClaudeAppTranscriptPage? {
            if case .page(let page) = load { return page }
            Issue.record("기록을 읽지 못했다", sourceLocation: sourceLocation)
            return nil
        }

        @Test func aForegroundAgentsResultIsAnOutcomeWithItsToolIdAndTheTimeOfThatLine() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "toolu_fg", name: "Agent", input: ["description": "Review the copy", "prompt": V.promptSentinel]),
                    V.agentFinished(id: id, toolID: "toolu_fg", agentID: "a02862466294fcd8e", timestamp: "2026-10-22T01:00:40.000Z"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.toolOutcomes == [ClaudeAppToolOutcome(toolUseID: "toolu_fg", failed: false, at: V.date("2026-10-22T01:00:40.000Z"))])
                #expect(page.cursor.signals.background.isEmpty, "끝난 전경 에이전트는 백그라운드 일의 시작이 아니다")
                #expect(page.turns.count == 2, "결과 줄은 대화가 아니다")
            }
        }

        @Test func anAsyncLaunchResultIsNeverAnEndAndStaysOnlyABackgroundStart() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "toolu_a", name: "Agent", input: ["description": "Audit", "prompt": V.promptSentinel, "run_in_background": true]),
                    V.agentStarted(id: id, toolID: "toolu_a", agentID: "a02862466294fcd8e"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.toolOutcomes.isEmpty, "비동기 시작 결과를 끝으로 보지 않는다")
                #expect(page.cursor.signals.background.count == 1)
            }
        }

        @Test func aResultThatSaysItIsNotAsyncWithAnAgentIdIsAnOutcomeAndOneWithoutAnAgentIdIsNot() throws {
            try withHome { home in
                let explicit = F.json([
                    "type": "user", "sessionId": id, "uuid": UUID().uuidString.lowercased(), "timestamp": "2026-10-22T01:00:06.000Z", "isSidechain": false,
                    "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_x", "content": "done"]]],
                    "toolUseResult": ["isAsync": false, "agentId": "a02862466294fcd8e", "status": "completed"],
                ])
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"), explicit,
                    V.result(id: id, toolID: "toolu_bash", isError: false),
                    V.bashStarted(id: id, toolID: "toolu_bg", taskID: "bk1abc9xy"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.toolOutcomes.map(\.toolUseID) == ["toolu_x"], "에이전트 결과만: 평범한 도구 성공 · 백그라운드 명령의 시작은 아니다")
            }
        }

        @Test func anErrorResultIsAFailedOutcomeWhateverToolItBelongsTo() throws {
            try withHome { home in
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.tool(id: id, toolID: "toolu_fg", name: "Agent", input: ["description": "Review the copy"]),
                    V.result(id: id, toolID: "toolu_fg", text: V.errorSentinel, isError: true, timestamp: "2026-10-22T01:00:30.000Z"),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.toolOutcomes == [ClaudeAppToolOutcome(toolUseID: "toolu_fg", failed: true, at: V.date("2026-10-22T01:00:30.000Z"))])
                #expect(page.cursor.signals.failedToolIDs == ["toolu_fg"], "기존 실패 신호는 그대로다")
            }
        }

        @Test func nothingElseIsAnOutcomeAndNoTextTravelsWithIt() throws {
            try withHome { home in
                let sidechain = V.agentFinished(id: id, toolID: "side", agentID: "a1").replacingOccurrences(of: "\"isSidechain\":false", with: "\"isSidechain\":true")
                _ = try home.transcript(directory: directory, id: id, lines: [
                    L.user(id: id, text: "go"),
                    V.result(id: id, toolID: "toolu_ok", isError: false),
                    V.result(id: id, toolID: "toolu_noflag", isError: nil),
                    sidechain,
                    V.agentFinished(id: F.uuid(0xEE), toolID: "other-session", agentID: "a2"),
                    V.result(id: id, toolID: String(repeating: "t", count: 129), isError: true),
                    V.result(id: id, toolID: "", isError: true),
                ])
                guard let page = page(reader(home).open(sessionID: id, cwd: cwd)) else { return }
                #expect(page.cursor.signals.toolOutcomes.isEmpty)
                let dump = String(reflecting: page.cursor.signals) + String(describing: page.cursor.signals)
                for sentinel in V.neverShown { #expect(!dump.contains(sentinel)) }
            }
        }

        @Test func anOutcomeThatArrivesInTheLiveTailIsReportedOnceAndNotAgain() throws {
            try withHome { home in
                let path = try home.transcript(directory: directory, id: id, lines: [L.user(id: id, text: "go"), V.tool(id: id, toolID: "toolu_fg", name: "Agent", input: ["description": "Review"])])
                let reader = reader(home)
                guard let first = page(reader.open(sessionID: id, cwd: cwd)) else { return }
                #expect(first.cursor.signals.toolOutcomes.isEmpty)
                let handle = try #require(FileHandle(forWritingAtPath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((V.agentFinished(id: id, toolID: "toolu_fg", agentID: "a02862466294fcd8e") + "\n").utf8))
                try handle.close()
                guard case .turns(_, let next, _) = reader.newer(first.cursor) else { Issue.record("이어 읽기"); return }
                #expect(next.signals.toolOutcomes.map(\.toolUseID) == ["toolu_fg"])
                guard case .turns(_, let again, _) = reader.newer(next) else { Issue.record("무변경"); return }
                #expect(again.signals.toolOutcomes.isEmpty, "신호는 읽은 그 번에만 있다")
            }
        }
    }
}
#endif
