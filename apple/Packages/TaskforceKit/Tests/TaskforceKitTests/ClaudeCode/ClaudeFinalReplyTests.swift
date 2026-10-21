#if os(macOS)
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 도구를 쓴 턴의 **마지막 글**이 사건으로 나가는가 (Claude Code 첫 실사용: 승인 세 번 뒤 Mac 대화에 마지막 답이 나오지 않았다).
/// stream-json이 `text → tool_use → tool_result → 마지막 text → result`로 오는 합성 줄을 매퍼에 먹인다. 매퍼는 마지막 글을 `result`에서 내보내므로
/// 그 글은 `turnCompleted` 앞에 와야 한다 (이 층은 결함이 아니었다: 결함은 서버가 쓴 글을 화면이 다시 읽지 않은 것 — `ChatStoreAgentRepliesTests`)
struct ClaudeFinalReplyTests {
    static let session = "32194c53-9c43-49f8-934c-b005ea771cec"
    static let workspace = "$SCR/proj"

    static func line(_ object: [String: Any]) -> Data {
        var object = object
        object["session_id"] = session
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func assistant(_ message: String, _ block: [String: Any], model: String = "claude-opus-5") -> Data {
        line(["type": "assistant", "message": ["id": message, "type": "message", "role": "assistant", "model": model, "content": [block]]])
    }

    static func text(_ message: String, _ value: String) -> Data { assistant(message, ["type": "text", "text": value]) }
    static func tool(_ message: String, _ id: String, _ name: String) -> Data { assistant(message, ["type": "tool_use", "id": id, "name": name, "input": [:]]) }
    static func hook(_ name: String) -> [Data] {
        [line(["type": "system", "subtype": "hook_started", "hook_name": "PreToolUse:\(name)", "hook_event": "PreToolUse"]),
         line(["type": "system", "subtype": "hook_response", "hook_name": "PreToolUse:\(name)", "hook_event": "PreToolUse", "exit_code": 0, "stdout": ""])]
    }
    static func result(_ id: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }
    static var initLine: Data {
        line(["type": "system", "subtype": "init", "cwd": "$SCR/tf-cwd", "tools": ["Read", "Write", "Bash"], "mcp_servers": [], "permissionMode": "default", "claude_code_version": "2.1.241"])
    }
    static var done: Data {
        line(["type": "result", "subtype": "success", "is_error": false, "stop_reason": "end_turn", "terminal_reason": "completed", "result": "x"])
    }

    /// 줄들을 매퍼에 먹여 나온 사건들 (모든 도구 호출에 bridge가 답했다고 가정)
    static func events(_ lines: [Data], mode: ClaudeMapperConfig.Mode = .turn(newSessionID: nil), answered: Set<String>) -> [AgentEvent] {
        var facts = ClaudeSpawnFacts()
        facts.answered = answered
        facts.toolNames = ClaudeTest.toolUses(in: lines)
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: mode, expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: workspace,
            versionSupported: { ClaudeCodeSupport.supports($0) }
        ))
        var actions: [ClaudeMapperAction] = []
        var now = Date(timeIntervalSince1970: 1000)
        for data in lines {
            now = now.addingTimeInterval(0.1)
            guard let event = ClaudeStreamParser.parse(data) else { continue }
            actions += mapper.consume(event, facts: facts, now: now)
        }
        actions += mapper.finish()
        return actions.compactMap { if case .emit(let event) = $0 { event } else { nil } }
    }

    @Test func theTextAfterTheLastToolResultIsEmittedBeforeTheTurnCompletes() {
        let lines: [Data] = [Self.initLine, Self.text("msg_1", "Let me look.")]
            + [Self.tool("msg_1", "toolu_1", "Bash")] + Self.hook("Bash") + [Self.result("toolu_1")]
            + [Self.tool("msg_2", "toolu_2", "Write")] + Self.hook("Write") + [Self.result("toolu_2")]
            + [Self.text("msg_3", "Created notes.txt as asked."), Self.done]
        let events = Self.events(lines, answered: ["toolu_1", "toolu_2"])
        let messages = events.compactMap { if case .message(let text) = $0 { text } else { nil } }
        #expect(messages == ["Let me look.", "Created notes.txt as asked."])
        #expect(events.last == .turnCompleted)
        #expect(events.dropLast().last == .message(text: "Created notes.txt as asked."), "마지막 글이 끝 사건 바로 앞에 온다")
    }

    @Test func aTurnWithoutTextBeforeItsToolsStillEmitsTheFinalText() {
        // 첫 실사용의 모양: 도구 앞에는 생각뿐이고 글은 마지막에 하나
        let thinking = Self.assistant("msg_1", ["type": "thinking", "thinking": ""])
        let lines: [Data] = [Self.initLine, thinking, Self.tool("msg_1", "toolu_1", "Bash")] + Self.hook("Bash") + [Self.result("toolu_1")]
            + [Self.tool("msg_2", "toolu_2", "Write")] + Self.hook("Write") + [Self.result("toolu_2"), Self.text("msg_3", "Done."), Self.done]
        let events = Self.events(lines, answered: ["toolu_1", "toolu_2"])
        #expect(events.contains(.message(text: "Done.")))
        #expect(events.last == .turnCompleted)
    }

    @Test func theAnswerResumeThatRunsTheApprovedToolThenRepliesEmitsTheReply() {
        // 답 resume의 줄 순서: 보류 id의 훅 → 그 도구의 결과 → init → 마지막 글 → result (r2-cc2mcp-2 · r2-cc5a와 같은 순서)
        let lines: [Data] = Self.hook("Write") + [Self.result("toolu_w"), Self.initLine, Self.text("msg_9", "Created notes.txt as asked."), Self.done]
        var facts = ClaudeSpawnFacts()
        facts.answered = ["toolu_w"]
        facts.toolNames = ["toolu_w": "Write"]
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .answer(requestID: "toolu_w"), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: Self.workspace,
            versionSupported: { ClaudeCodeSupport.supports($0) }
        ))
        var events: [AgentEvent] = []
        var now = Date(timeIntervalSince1970: 1000)
        for data in lines {
            now = now.addingTimeInterval(0.1)
            guard let event = ClaudeStreamParser.parse(data) else { continue }
            events += mapper.consume(event, facts: facts, now: now).compactMap { if case .emit(let event) = $0 { event } else { nil } }
        }
        events += mapper.finish().compactMap { if case .emit(let event) = $0 { event } else { nil } }
        #expect(events.contains(.message(text: "Created notes.txt as asked.")))
        #expect(events.last == .turnCompleted)
    }
}
#endif
