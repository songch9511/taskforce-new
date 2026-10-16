#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import TaskforceAgentWire

/// 재검토 7 (OA D3a 16장 3, sec F5): 훅 예산은 bridge 예산보다 넉넉하고, 훅은 요청에 남은 시간(`remaining_ms`)을 실어 bridge가 그보다 앞서 정하게 한다
struct HookRereview7Tests {
    static func request(remainingMS: Int?) -> HookRequest {
        HookRequest(
            nonce: HookMainTests.nonce, sessionID: HookMainTests.session, providerSessionID: "p", hookEvent: "PreToolUse", toolUseID: "toolu_1", toolName: "Read",
            toolInput: .object([:]), inputSHA256: "d", permissionMode: "default", cwd: "/c", remainingMS: remainingMS
        )
    }

    @Test func theRemainingTimeRoundTripsAndHasBounds() throws {
        #expect(try HookRequest.decode(line: Self.request(remainingMS: 3_210).encodedLine()).remainingMS == 3_210)
        #expect(try HookRequest.decode(line: Self.request(remainingMS: nil).encodedLine()).remainingMS == nil, "없으면 bridge 자신의 예산만")
        let head = #"{"cwd":"/c","hook_event":"PreToolUse","input_sha256":"d","nonce":"n","permission_mode":"default","session_id":"s","tool_input":{},"tool_name":"Read","tool_use_id":"t","v":1,"remaining_ms":"#
        #expect(try HookRequest.decode(line: Data((head + "0}\n").utf8)).remainingMS == 0)
        for bad in ["-1", "10001", #""9""#, "1.5", "null"] {
            #expect(throws: (any Error).self, "\(bad)") { try HookRequest.decode(line: Data((head + bad + "}\n").utf8)) }
        }
    }

    /// 훅은 연결하기 직전에 기한까지 남은 밀리초(내림)를 싣는다
    @Test func theHookSendsItsRemainingTimeWithTheRequest() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sent = Mutex<Data?>(nil)
        let result = HookMain.run(arguments: HookMainTests.arguments, stdin: HookMainTests.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#), connect: { _, line, _ in
            sent.withLock { $0 = line }
            return Data(#"{"decision":"allow","reason":"ok"}"#.utf8)
        }, deadline: start.addingTimeInterval(3.2509), now: { start })
        #expect(try HookMainTests.output(result).decision == "allow")
        let line = try #require(sent.withLock { $0 })
        #expect(try HookRequest.decode(line: line).remainingMS == 3_250)
    }

    /// 훅 예산은 Claude Code 훅 timeout(10초, settings) 안이다
    @Test func theHookBudgetStaysInsideTheHookTimeout() {
        #expect(HookWire.budget < 10)
        #expect(Int(HookWire.budget * 1000) <= HookWire.maxRemainingMS)
    }
}
#endif
