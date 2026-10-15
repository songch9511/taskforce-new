#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import TaskforceAgentWire

/// 훅 본체 `HookMain.run` (OA D3a 계약 2.6 · 3.4 · 4.1): 주입한 연결 · 시계로 fail-closed 갈래를 하나씩 본다.
/// 기대: 모르는 것은 모두 deny JSON + exit 0, deny JSON마저 못 쓰면 exit 2. 훅은 bridge가 준 `answers` · `command`만 원래 입력에 끼워 넣는다
struct HookMainTests {
    static let socket = "/tmp/tf-test/hook.sock"
    static let nonce = "Zm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyZm9vYmFyMDA"
    static let session = "5e551011-0000-4000-8000-000000000001"
    static let arguments = ["pre-tool-use", "--socket", socket, "--session", session, "--nonce", nonce]

    static func stdin(tool: String, input: String, mode: String = "default", event: String = "PreToolUse") -> Data {
        Data(#"{"session_id":"0e09f680-f476-4f2e-96d9-670f24599f6d","transcript_path":"/x/t.jsonl","cwd":"/s/cwd","permission_mode":"\#(mode)","hook_event_name":"\#(event)","tool_name":"\#(tool)","tool_input":\#(input),"tool_use_id":"toolu_01"}"#.utf8)
    }

    static func output(_ result: HookMain.Result) throws -> (decision: String, reason: String, updated: WireJSON?) {
        let value = try WireJSON.parse(result.stdout)
        let specific = try #require(value["hookSpecificOutput"])
        #expect(specific["hookEventName"] == .string("PreToolUse"))
        return (specific["permissionDecision"]?.stringValue ?? "", specific["permissionDecisionReason"]?.stringValue ?? "", specific["updatedInput"])
    }

    static func replying(_ line: String) -> HookMain.Connect {
        { _, _, _ in Data(line.utf8) }
    }

    static var later: Date { Date().addingTimeInterval(HookWire.budget) }

    // MARK: SessionStart

    @Test func sessionStartPrintsOnlyTheMarkerAndNeverTheNonce() throws {
        let result = HookMain.run(arguments: ["session-start"], stdin: Data(#"{"hook_event_name":"SessionStart","source":"startup"}"#.utf8), connect: { _, _, _ in
            Issue.record("SessionStart must not open the socket")
            return Data()
        }, deadline: Self.later)
        #expect(result.exitCode == 0)
        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(text == #"{"hookSpecificOutput":{"additionalContext":"tf-hook-ready","hookEventName":"SessionStart"}}"#)
        #expect(!text.contains(Self.nonce))
    }

    // MARK: fail-closed

    @Test func aConnectionFailureDenies() throws {
        struct Refused: Error {}
        let result = HookMain.run(arguments: Self.arguments, stdin: Self.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#), connect: { _, _, _ in throw Refused() }, deadline: Self.later)
        #expect(result.exitCode == 0)
        #expect(try Self.output(result).decision == "deny")
    }

    @Test func aPastDeadlineDeniesWithoutConnecting() throws {
        let result = HookMain.run(arguments: Self.arguments, stdin: Self.stdin(tool: "Write", input: #"{"file_path":"/w/a","content":"x"}"#), connect: { _, _, _ in
            Issue.record("must not connect after the deadline")
            return Data(#"{"decision":"allow","reason":"late"}"#.utf8)
        }, deadline: Date().addingTimeInterval(-0.01))
        #expect(try Self.output(result).decision == "deny")
    }

    @Test func aBridgeThatAnswersAfterTheBudgetIsTreatedAsNoAnswer() throws {
        // 연결이 기한을 넘겨 돌아오면(가짜 연결이 기한을 무시해도) 답을 쓰지 않는다
        let result = HookMain.run(arguments: Self.arguments, stdin: Self.stdin(tool: "Write", input: #"{"file_path":"/w/a","content":"x"}"#), connect: { _, _, deadline in
            Thread.sleep(until: deadline.addingTimeInterval(0.05))
            return Data(#"{"decision":"allow","reason":"late"}"#.utf8)
        }, deadline: Date().addingTimeInterval(0.1))
        #expect(try Self.output(result).decision == "deny")
    }

    @Test func aRejectedNonceAnUnknownDecisionAndABrokenReplyAllDeny() throws {
        let input = Self.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#)
        for reply in [#"{"decision":"deny","reason":"Unknown spawn."}"#, #"{"decision":"maybe","reason":"x"}"#, "not json", "", #"{"decision":"allow","reason":"x","updated_input":{}}"#] {
            let result = HookMain.run(arguments: Self.arguments, stdin: input, connect: Self.replying(reply), deadline: Self.later)
            #expect(result.exitCode == 0, "\(reply)")
            #expect(try Self.output(result).decision == "deny", "\(reply)")
        }
    }

    @Test func malformedInvocationsDeny() throws {
        let input = Self.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#)
        let allow = Self.replying(#"{"decision":"allow","reason":"ok"}"#)
        for arguments in [[], ["pre-tool-use"], ["pre-tool-use", "--socket", Self.socket, "--session", Self.session], ["other"]] {
            #expect(try Self.output(HookMain.run(arguments: arguments, stdin: input, connect: allow, deadline: Self.later)).decision == "deny", "\(arguments)")
        }
        for stdin in [Data(), Data("{".utf8), Data(#"{"tool_name":"Read"}"#.utf8), Self.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#, event: "PostToolUse")] {
            #expect(try Self.output(HookMain.run(arguments: Self.arguments, stdin: stdin, connect: allow, deadline: Self.later)).decision == "deny")
        }
    }

    @Test func anOversizedStdinDeniesWithoutConnecting() throws {
        var big = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"content":""#.utf8)
        big.append(Data(repeating: 0x61, count: HookWire.maxStdinBytes))
        big.append(Data("\"}}".utf8))
        let result = HookMain.run(arguments: Self.arguments, stdin: big, connect: { _, _, _ in
            Issue.record("must not connect")
            return Data()
        }, deadline: Self.later)
        #expect(try Self.output(result).decision == "deny")
    }

    // MARK: 요청 모양

    @Test func theRequestCarriesTheArgumentsAndNoFileBody() throws {
        let captured = Mutex<Data?>(nil)
        let result = HookMain.run(arguments: Self.arguments, stdin: Self.stdin(tool: "Write", input: #"{"file_path":"/w/a.txt","content":"SECRET-BODY"}"#), connect: { path, line, _ in
            #expect(path == Self.socket)
            captured.withLock { $0 = line }
            return Data(#"{"decision":"defer","reason":"Waiting for approval."}"#.utf8)
        }, deadline: Self.later)
        #expect(try Self.output(result).decision == "defer")
        let line = try #require(captured.withLock { $0 })
        #expect(String(decoding: line, as: UTF8.self).contains("SECRET-BODY") == false)
        let request = try HookRequest.decode(line: line)
        #expect(request.nonce == Self.nonce && request.sessionID == Self.session && request.providerSessionID == "0e09f680-f476-4f2e-96d9-670f24599f6d")
        #expect(request.toolName == "Write" && request.toolUseID == "toolu_01" && request.permissionMode == "default" && request.cwd == "/s/cwd")
        #expect(request.toolInput == .object(["file_path": .string("/w/a.txt"), "content_len": .int(11)]))
        #expect(request.inputSHA256 == HookWire.inputDigest(try WireJSON.parse(Data(#"{"file_path":"/w/a.txt","content":"SECRET-BODY"}"#.utf8))))
    }

    // MARK: 답 · 명령 끼워 넣기

    @Test func theModelsOwnAnswersAreReplacedByTheBridgesAnswers() throws {
        let input = #"{"questions":[{"id":"color","text":"Which?","options":[{"label":"red"},{"label":"blue"}]}],"answers":{"color":"red-from-model"}}"#
        let result = HookMain.run(arguments: Self.arguments, stdin: Self.stdin(tool: "mcp__tf__ask_user", input: input),
                                  connect: Self.replying(#"{"decision":"allow","reason":"Answered.","answers":{"color":"blue"}}"#), deadline: Self.later)
        let output = try Self.output(result)
        #expect(output.decision == "allow")
        let updated = try #require(output.updated)
        #expect(updated["answers"] == .object(["color": .string("blue")]))
        #expect(updated["questions"] == (try WireJSON.parse(Data(input.utf8)))["questions"], "질문은 원래 입력 그대로")
    }

    @Test func aRebuiltCommandReplacesOnlyTheCommand() throws {
        let input = #"{"command":"ls src","description":"List","timeout":40000}"#
        let result = HookMain.run(arguments: Self.arguments, stdin: Self.stdin(tool: "Bash", input: input),
                                  connect: Self.replying(#"{"decision":"allow","reason":"Read-only command.","command":"'/bin/ls' '/w/src'"}"#), deadline: Self.later)
        let updated = try #require(try Self.output(result).updated)
        #expect(updated == .object(["command": .string("'/bin/ls' '/w/src'"), "description": .string("List"), "timeout": .int(40000)]))
    }

    @Test func answersOrACommandForTheWrongToolDeny() throws {
        let write = Self.stdin(tool: "Write", input: #"{"file_path":"/w/a","content":"x"}"#)
        #expect(try Self.output(HookMain.run(arguments: Self.arguments, stdin: write, connect: Self.replying(#"{"decision":"allow","reason":"x","answers":{"a":"b"}}"#), deadline: Self.later)).decision == "deny")
        #expect(try Self.output(HookMain.run(arguments: Self.arguments, stdin: write, connect: Self.replying(#"{"decision":"allow","reason":"x","command":"'/bin/ls'"}"#), deadline: Self.later)).decision == "deny")
        let bash = Self.stdin(tool: "Bash", input: #"{"command":"ls"}"#)
        #expect(try Self.output(HookMain.run(arguments: Self.arguments, stdin: bash, connect: Self.replying(#"{"decision":"allow","reason":"x","answers":{"a":"b"},"command":"ls"}"#), deadline: Self.later)).decision == "deny")
    }

    @Test func plainAllowAndDeferPassTheInputThrough() throws {
        let read = Self.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#)
        let allow = try Self.output(HookMain.run(arguments: Self.arguments, stdin: read, connect: Self.replying(#"{"decision":"allow","reason":"Inside the workspace."}"#), deadline: Self.later))
        #expect(allow.decision == "allow" && allow.updated == nil && allow.reason == "Inside the workspace.")
    }

    // MARK: 출력 실패

    @Test func whenEvenTheDenyCannotBeWrittenTheExitCodeIs2() {
        let result = HookMain.Result(stdout: HookOutput.preToolUse(.deny, reason: "x"), exitCode: 0)
        #expect(HookMain.emit(result, write: { _ in false }) == 2)
        #expect(HookMain.emit(result, write: { _ in true }) == 0)
    }
}
#endif
