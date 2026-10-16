#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import TaskforceAgentWire

/// 재검토 7 · 8 (OA D3a 16장 3 · 17장 2, sec F5 · S8-2): 훅 예산은 bridge 예산보다 넉넉하고, 훅은 요청에 자기 **절대 기한**(`deadline_ns`, 프로세스 사이에 같은 연속 시계)을
/// 실어 bridge가 보낸 뒤의 지연까지 세어 그보다 앞서 정하게 한다
struct HookRereview7Tests {
    static func request(deadlineNS: UInt64?) -> HookRequest {
        HookRequest(
            nonce: HookMainTests.nonce, sessionID: HookMainTests.session, providerSessionID: "p", hookEvent: "PreToolUse", toolUseID: "toolu_1", toolName: "Read",
            toolInput: .object([:]), inputSHA256: "d", permissionMode: "default", cwd: "/c", deadlineNS: deadlineNS
        )
    }

    @Test func theDeadlineRoundTripsAndHasAShape() throws {
        #expect(try HookRequest.decode(line: Self.request(deadlineNS: 123_456_789_000).encodedLine()).deadlineNS == 123_456_789_000)
        #expect(try HookRequest.decode(line: Self.request(deadlineNS: nil).encodedLine()).deadlineNS == nil, "없으면 bridge 자신의 예산만")
        let head = #"{"cwd":"/c","hook_event":"PreToolUse","input_sha256":"d","nonce":"n","permission_mode":"default","session_id":"s","tool_input":{},"tool_name":"Read","tool_use_id":"t","v":1,"deadline_ns":"#
        #expect(try HookRequest.decode(line: Data((head + "1}\n").utf8)).deadlineNS == 1)
        for bad in ["0", "-1", #""9""#, "1.5", "null"] {
            #expect(throws: (any Error).self, "\(bad)") { try HookRequest.decode(line: Data((head + bad + "}\n").utf8)) }
        }
        #expect(throws: (any Error).self, "옛 상대 시간 키는 없다") { try HookRequest.decode(line: Data((head.replacingOccurrences(of: "deadline_ns", with: "remaining_ms") + "5}\n").utf8)) }
    }

    /// 훅은 연결하기 직전에 그 시계로 절대 기한(지금 + 남은 시간)을 싣는다
    @Test func theHookSendsItsAbsoluteDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sent = Mutex<Data?>(nil)
        let result = HookMain.run(arguments: HookMainTests.arguments, stdin: HookMainTests.stdin(tool: "Read", input: #"{"file_path":"/w/a"}"#), connect: { _, line, _ in
            sent.withLock { $0 = line }
            return Data(#"{"decision":"allow","reason":"ok"}"#.utf8)
        }, deadline: start.addingTimeInterval(3.25), now: { start }, monotonic: { 7_000_000_000 })
        #expect(try HookMainTests.output(result).decision == "allow")
        let line = try #require(sent.withLock { $0 })
        #expect(try HookRequest.decode(line: line).deadlineNS == 10_250_000_000)
    }

    /// 실제 시계는 프로세스 사이에 같은 값이다 (부팅 뒤 나노초, 거꾸로 가지 않는다)
    @Test func theSharedClockMovesForwardAcrossProcesses() throws {
        let before = HookWire.monotonicNow()
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // 다른 프로세스에서 같은 시계를 읽는다 (`CLOCK_MONOTONIC_RAW` = 4: Time::HiRes)
        probe.arguments = ["-MTime::HiRes=clock_gettime", "-e", "printf(\"%.0f\", clock_gettime(4) * 1e9)"]
        let output = Pipe()
        probe.standardOutput = output
        try probe.run()
        probe.waitUntilExit()
        let after = HookWire.monotonicNow()
        let other = try #require(UInt64(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
        #expect(before <= other && other <= after, "\(before) \(other) \(after)")
    }

    /// 훅 예산은 Claude Code 훅 timeout(10초, settings) 안이다
    @Test func theHookBudgetStaysInsideTheHookTimeout() {
        #expect(HookWire.budget < 10)
    }
}
#endif
