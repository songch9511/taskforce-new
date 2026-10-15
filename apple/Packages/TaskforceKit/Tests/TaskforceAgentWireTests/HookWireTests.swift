#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 훅 ↔ bridge 소켓 줄 규약 (OA D3a 계약 2.6 · 4.1 "선 규약"): 인코딩/디코딩, 256KB 상한, 모르는 필드 · 깨진 JSON 거절, 본문 글 빼기, 입력 digest
struct HookWireTests {
    static func request(toolName: String = "Read", input: WireJSON = .object(["file_path": .string("/w/a.txt")])) -> HookRequest {
        HookRequest(
            nonce: String(repeating: "n", count: 43), sessionID: "5e551011-0000-4000-8000-000000000001", providerSessionID: "0e09f680-f476-4f2e-96d9-670f24599f6d",
            hookEvent: "PreToolUse", toolUseID: "toolu_01", toolName: toolName, toolInput: input, inputSHA256: HookWire.inputDigest(input), permissionMode: "default",
            cwd: "/s/cwd"
        )
    }

    // MARK: JSON 값

    @Test func canonicalTextSortsKeysAndIsStableAcrossKeyOrder() throws {
        let a = try WireJSON.parse(Data(#"{"b":1,"a":[true,null,"x"],"c":{"z":1.5,"y":"\n"}}"#.utf8))
        let b = try WireJSON.parse(Data(#"{"c":{"y":"\n","z":1.5},"a":[true,null,"x"],"b":1}"#.utf8))
        #expect(a == b)
        #expect(a.canonicalText == #"{"a":[true,null,"x"],"b":1,"c":{"y":"\n","z":1.5}}"#)
        #expect(b.canonicalText == a.canonicalText)
    }

    @Test func numbersKeepIntegersAndBooleansApart() throws {
        let value = try WireJSON.parse(Data(#"{"i":40000,"f":0.25,"t":true,"n":-3}"#.utf8))
        #expect(value["i"] == .int(40000))
        #expect(value["f"] == .double(0.25))
        #expect(value["t"] == .bool(true))
        #expect(value["n"] == .int(-3))
    }

    @Test func brokenJSONIsRejected() {
        #expect(throws: WireError.self) { try WireJSON.parse(Data("{".utf8)) }
        #expect(throws: WireError.self) { try WireJSON.parse(Data([0xFF, 0xFE])) }
    }

    // MARK: SHA-256 (Foundation · Darwin만으로 구현한 것을 CryptoKit과 대조)

    @Test func sha256MatchesCryptoKit() {
        let samples: [Data] = [Data(), Data("abc".utf8), Data(repeating: 0x61, count: 55), Data(repeating: 0x61, count: 56), Data(repeating: 0x62, count: 64),
                               Data(repeating: 0x63, count: 1_000_003), Data("가나다 tf-hook".utf8)]
        for sample in samples {
            let expected = SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
            #expect(WireSHA256.hex(sample) == expected, "\(sample.count)")
        }
    }

    @Test func inputDigestIsTheSha256OfTheCanonicalText() throws {
        let input = try WireJSON.parse(Data(#"{"file_path":"/w/a.txt","content":"비밀 글"}"#.utf8))
        let expected = SHA256.hash(data: Data(input.canonicalText.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(HookWire.inputDigest(input) == expected)
        let reordered = try WireJSON.parse(Data(#"{"content":"비밀 글","file_path":"/w/a.txt"}"#.utf8))
        #expect(HookWire.inputDigest(reordered) == expected, "키 순서가 달라도 같은 digest")
        let changed = try WireJSON.parse(Data(#"{"file_path":"/w/a.txt","content":"다른 글"}"#.utf8))
        #expect(HookWire.inputDigest(changed) != expected)
    }

    // MARK: 본문 글은 소켓에 싣지 않는다 (Q4)

    @Test func writeContentAndEditStringsAreReplacedByTheirLengths() throws {
        let write = try WireJSON.parse(Data(#"{"file_path":"/w/a.txt","content":"비밀 글"}"#.utf8))
        #expect(HookWire.strippedInput(toolName: "Write", input: write) == .object(["file_path": .string("/w/a.txt"), "content_len": .int(10)]))
        let edit = try WireJSON.parse(Data(#"{"file_path":"/w/a.txt","old_string":"ab","new_string":"가","replace_all":true}"#.utf8))
        #expect(HookWire.strippedInput(toolName: "Edit", input: edit) == .object([
            "file_path": .string("/w/a.txt"), "old_string_len": .int(2), "new_string_len": .int(3), "replace_all": .bool(true),
        ]))
    }

    @Test func toolsTheBridgeDoesNotReadSendNoInputAtAll() throws {
        let notebook = try WireJSON.parse(Data(#"{"notebook_path":"/w/n.ipynb","new_source":"print(1)"}"#.utf8))
        for name in ["NotebookEdit", "Agent", "Task", "Skill", "mcp__evil__ask_user", "WebFetch", "MultiEdit"] {
            #expect(HookWire.strippedInput(toolName: name, input: notebook) == .object([:]), "\(name)")
        }
        let bash = try WireJSON.parse(Data(#"{"command":"ls -la","run_in_background":false}"#.utf8))
        #expect(HookWire.strippedInput(toolName: "Bash", input: bash) == bash)
        let ask = try WireJSON.parse(Data(#"{"questions":[{"id":"a","text":"Which?"}]}"#.utf8))
        #expect(HookWire.strippedInput(toolName: "mcp__tf__ask_user", input: ask) == ask)
    }

    // MARK: 줄 인코딩 · 디코딩

    @Test func requestLineRoundTripsAndEndsWithANewline() throws {
        let request = Self.request()
        let line = try request.encodedLine()
        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        #expect(try HookRequest.decode(line: line) == request)
    }

    @Test func requestAndResponseLinesOver256KBAreRefused() throws {
        let big = WireJSON.object(["command": .string(String(repeating: "x", count: HookWire.maxLineBytes))])
        #expect(throws: WireError.tooLarge) { try Self.request(toolName: "Bash", input: big).encodedLine() }
        var tooLong = Data(#"{"decision":"allow","reason":""#.utf8)
        tooLong.append(Data(repeating: 0x61, count: HookWire.maxLineBytes))
        tooLong.append(Data("\"}\n".utf8))
        #expect(throws: WireError.tooLarge) { try HookResponse.decode(line: tooLong) }
    }

    @Test func unknownFieldsWrongVersionAndBrokenLinesAreRefused() throws {
        var object = try #require(try WireJSON.parse(Self.request().encodedLine()).objectValue)
        object["extra"] = .string("x")
        #expect(throws: WireError.self) { try HookRequest.decode(line: Data((WireJSON.object(object).canonicalText + "\n").utf8)) }
        object["extra"] = nil
        object["v"] = .int(2)
        #expect(throws: WireError.self) { try HookRequest.decode(line: Data((WireJSON.object(object).canonicalText + "\n").utf8)) }
        #expect(throws: WireError.self) { try HookRequest.decode(line: Data("{\"v\":1\n".utf8)) }
        #expect(throws: WireError.self) { try HookResponse.decode(line: Data(#"{"decision":"allow","reason":"x","extra":1}"#.utf8)) }
        #expect(throws: WireError.self) { try HookResponse.decode(line: Data(#"{"decision":"maybe","reason":"x"}"#.utf8)) }
        #expect(throws: WireError.self) { try HookResponse.decode(line: Data(#"{"decision":"allow"}"#.utf8)) }
    }

    @Test func responseCarriesAnswersOrACommand() throws {
        let response = HookResponse(decision: .allow, reason: "Answered.", answers: ["color": .string("blue"), "langs": .array([.string("a"), .string("b")])])
        #expect(try HookResponse.decode(line: response.encodedLine()) == response)
        let command = HookResponse(decision: .allow, reason: "Read-only command.", command: "'/bin/ls' '/w'")
        #expect(try HookResponse.decode(line: command.encodedLine()) == command)
    }
}
#endif
