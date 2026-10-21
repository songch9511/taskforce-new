#if os(macOS)
import Foundation
import Testing
import TaskforceAgentWire
@testable import TaskforceKit

/// 자체 점검 ④의 예외 (R1-02 · R1-03). CLI는 도구 입력을 훅 앞에서 검증한다("읽기 전에 쓰기", "없는 도구"): 그 오류 결과에는 훅 답이 없다.
/// 오류 결과이고 (Read · Glob · Grep · Edit · Write이거나 init `tools`에 없는 도구)면 아무것도 실행되지 않았으므로 턴을 잇는다.
/// 훅 답 없는 **성공** 결과, Bash · 그 밖 도구의 오류 결과는 훅을 건너뛴 실행일 수 있으므로 ④가 그대로 막는다
struct ClaudeToolRefusalTests {
    static let writeTools = Array(ClaudeCodeSupport.initTools(for: .write)).sorted()
    static let readOnlyTools = Array(ClaudeCodeSupport.initTools(for: .readOnly)).sorted()

    struct Call {
        var id: String
        var name: String
        /// 훅이 돌았고 bridge가 소켓으로 답했다
        var hooked = false
        var error = false
        var filePath: String?
    }

    struct Run {
        var actions: [ClaudeMapperAction] = []
        var events: [AgentEvent] { actions.compactMap { if case .emit(let event) = $0 { event } else { nil } } }
        var interrupts: [ClaudeInterruptCause] { actions.compactMap { if case .interrupt(let cause) = $0 { cause } else { nil } } }
        var refusals: [ClaudeToolRefusal] { actions.compactMap { if case .toolRefusedBeforeHook(let refusal) = $0 { refusal } else { nil } } }
        var artifacts: [ClaudeArtifactCandidate] {
            var found: [ClaudeArtifactCandidate] = []
            for case .artifacts(let list) in actions { found += list }
            return found
        }
        var continued: Bool { interrupts.isEmpty && events.last == .turnCompleted }
        var failedCheck4: Bool { interrupts == [.selfCheck(4)] && !events.contains(.turnCompleted) }
    }

    static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func run(tools: [String] = writeTools, _ calls: [Call]) -> Run {
        var lines: [Data] = [line([
            "type": "system", "subtype": "init", "session_id": "s1", "cwd": "/w", "tools": tools, "mcp_servers": [["name": "tf", "status": "connected"]],
            "permissionMode": "default", "claude_code_version": "2.1.241",
        ])]
        var facts = ClaudeSpawnFacts()
        for call in calls {
            var input: [String: Any] = [:]
            if let filePath = call.filePath { input["file_path"] = filePath }
            lines.append(line(["type": "assistant", "message": ["id": "m-\(call.id)", "model": "claude-test", "content": [["type": "tool_use", "id": call.id, "name": call.name, "input": input]]]]))
            if call.hooked {
                lines.append(line(["type": "system", "subtype": "hook_started", "hook_name": "PreToolUse:\(call.name)", "hook_event": "PreToolUse"]))
                facts.answered.insert(call.id)
                facts.toolNames[call.id] = call.name
            }
            var result: [String: Any] = ["type": "tool_result", "tool_use_id": call.id, "content": "x"]
            if call.error { result["is_error"] = true }
            lines.append(line(["type": "user", "message": ["content": [result]]]))
        }
        lines.append(line(["type": "assistant", "message": ["id": "m-final", "model": "claude-test", "content": [["type": "text", "text": "done"]]]]))
        lines.append(line(["type": "result", "subtype": "success", "is_error": false, "stop_reason": "end_turn"]))
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/w",
            versionSupported: { ClaudeCodeSupport.supports($0) }
        ))
        var run = Run()
        var now = Date(timeIntervalSince1970: 1000)
        for data in lines {
            now = now.addingTimeInterval(0.1)
            guard let event = ClaudeStreamParser.parse(data) else { continue }
            run.actions += mapper.consume(event, facts: facts, now: now)
        }
        run.actions += mapper.finish()
        return run
    }

    // MARK: 턴을 잇는 둘

    /// (a) 훅 앞에서 CLI가 검증하는 다섯 도구의 오류 결과 (R1-03: "File has not been read yet")
    @Test(arguments: ["Read", "Glob", "Grep", "Edit", "Write"])
    func aCliValidationErrorOnAFileToolWithoutAHookAnswerDoesNotEndTheTurn(tool: String) {
        let run = Self.run([Call(id: "t1", name: tool, error: true, filePath: "/w/a.txt")])
        #expect(run.continued, "\(run.actions)")
        #expect(run.refusals == [.cliValidated])
        #expect(run.artifacts.isEmpty, "거절된 Edit · Write는 산출물이 아니다")
    }

    /// (b) init `tools`에 없는 도구 (R1-02: 읽기 전용 등급의 Edit "No such tool available")
    @Test func aToolThatIsNotAdvertisedIsRefusedAndTheTurnContinues() {
        let edit = Self.run(tools: Self.readOnlyTools, [Call(id: "t1", name: "Edit", error: true, filePath: "/w/a.txt")])
        #expect(edit.continued, "\(edit.actions)")
        #expect(edit.refusals == [.notAdvertised])
        let bash = Self.run(tools: Self.readOnlyTools, [Call(id: "t1", name: "Bash", error: true)])
        #expect(bash.continued, "읽기 전용 등급에서 Bash는 광고되지 않는다: \(bash.actions)")
        #expect(bash.refusals == [.notAdvertised])
        let other = Self.run([Call(id: "t1", name: "NotebookEdit", error: true)])
        #expect(other.continued)
        #expect(other.refusals == [.notAdvertised])
    }

    /// R1-02 · R1-03의 실제 모양: 훅이 허용한 Read 뒤에 거절된 Edit, 다시 훅이 도는 Read — 턴이 끝까지 간다
    @Test func aRefusalBetweenHookedCallsLeavesTheHookedOnesAccounted() {
        let run = Self.run([
            Call(id: "t1", name: "Read", hooked: true, filePath: "/w/a.txt"),
            Call(id: "t2", name: "Edit", error: true, filePath: "/w/a.txt"),
            Call(id: "t3", name: "Read", hooked: true, filePath: "/w/a.txt"),
        ])
        #expect(run.continued, "\(run.actions)")
        #expect(run.refusals == [.cliValidated])
    }

    // MARK: 계속 막는 것 (훅을 건너뛴 실행일 수 있다)

    /// 훅 답 없는 **성공** 결과는 어떤 도구든 ④가 막는다
    @Test(arguments: ["Read", "Glob", "Grep", "Edit", "Write", "Bash", "mcp__tf__ask_user", "NotebookEdit"])
    func aSuccessfulResultWithoutAHookAnswerStillStopsTheTurn(tool: String) {
        let run = Self.run([Call(id: "t1", name: tool, error: false, filePath: "/w/a.txt")])
        #expect(run.failedCheck4, "\(run.actions)")
        #expect(run.refusals.isEmpty)
    }

    /// 광고된 Bash · Taskforce MCP 도구의 오류 결과는 훅 답이 없으면 막는다 (Bash는 CLI가 훅 앞에서 거르는 도구가 아니다)
    @Test(arguments: ["Bash", "mcp__tf__ask_user"])
    func anErrorResultOnAnAdvertisedNonFileToolWithoutAHookAnswerStillStopsTheTurn(tool: String) {
        let run = Self.run([Call(id: "t1", name: tool, error: true)])
        #expect(run.failedCheck4, "\(run.actions)")
        #expect(run.refusals.isEmpty)
    }

    /// 알 수 없는 id(앞선 tool_use가 없다)의 오류 결과는 어떤 도구의 것인지 알 수 없다 → 막는다
    @Test func anErrorResultForAnUnknownToolUseStillStopsTheTurn() {
        var lines: [Data] = [Self.line(["type": "system", "subtype": "init", "session_id": "s1", "cwd": "/w", "tools": Self.writeTools, "mcp_servers": [["name": "tf", "status": "connected"]], "permissionMode": "default", "claude_code_version": "2.1.241"])]
        lines.append(Self.line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "ghost", "is_error": true, "content": "x"]]]]))
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/w", versionSupported: { _ in true }
        ))
        var actions: [ClaudeMapperAction] = []
        for data in lines { if let event = ClaudeStreamParser.parse(data) { actions += mapper.consume(event, facts: ClaudeSpawnFacts(), now: Date()) } }
        #expect(actions.contains(.interrupt(.selfCheck(4))))
    }

    /// 답이 있는데 `hook_started` 사건이 없으면(기존 ④) 오류 결과여도 막는다 — 예외는 훅 답이 **없는** 결과에만 있다
    @Test func aHookAnsweredErrorResultWithoutItsHookStartedEventStillStopsTheTurn() {
        var lines: [Data] = [Self.line(["type": "system", "subtype": "init", "session_id": "s1", "cwd": "/w", "tools": Self.writeTools, "mcp_servers": [["name": "tf", "status": "connected"]], "permissionMode": "default", "claude_code_version": "2.1.241"])]
        lines.append(Self.line(["type": "assistant", "message": ["id": "m1", "model": "claude-test", "content": [["type": "tool_use", "id": "t1", "name": "Edit", "input": [:]]]]]))
        lines.append(Self.line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "x"]]]]))
        var facts = ClaudeSpawnFacts()
        facts.answered = ["t1"]
        facts.toolNames = ["t1": "Edit"]
        var mapper = ClaudeEventMapper(config: ClaudeMapperConfig(
            mode: .turn(newSessionID: nil), expectedSessionID: nil, expectedTools: nil, expectedCwd: nil, requireSessionStart: false, workspaceRealPath: "/w", versionSupported: { _ in true }
        ))
        var actions: [ClaudeMapperAction] = []
        for data in lines { if let event = ClaudeStreamParser.parse(data) { actions += mapper.consume(event, facts: facts, now: Date()) } }
        #expect(actions.contains(.interrupt(.selfCheck(4))))
    }

    /// 거절 뒤에 훅을 건너뛴 성공 결과가 오면 그것은 여전히 막는다 (거절이 뒤 결과를 면제하지 않는다)
    @Test func aBypassAfterARefusalIsStillCaught() {
        let run = Self.run([
            Call(id: "t1", name: "Edit", error: true, filePath: "/w/a.txt"),
            Call(id: "t2", name: "Write", error: false, filePath: "/w/b.txt"),
        ])
        #expect(run.failedCheck4, "\(run.actions)")
        #expect(run.artifacts.isEmpty)
    }

    /// 훅 답이 있는 평소 결과는 그대로다 (거절 사건이 없다)
    @Test func hookedResultsAreUnchanged() {
        let run = Self.run([Call(id: "t1", name: "Write", hooked: true, filePath: "/w/a.txt"), Call(id: "t2", name: "Bash", hooked: true, error: true)])
        #expect(run.continued, "\(run.actions)")
        #expect(run.refusals.isEmpty)
        #expect(run.artifacts == [ClaudeArtifactCandidate(tool: "Write", filePath: "/w/a.txt")])
    }
}
#endif
