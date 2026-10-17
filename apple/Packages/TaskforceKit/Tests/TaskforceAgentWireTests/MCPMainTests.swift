#if os(macOS)
import Foundation
import Testing
@testable import TaskforceAgentWire

/// `ask_user` stdio JSON-RPC 본체 (OA D3a 계약 3.3 · 4.1): initialize · tools/list 스키마 · tools/call 두 갈래 · 모르는 메서드
struct MCPMainTests {
    static func reply(_ line: String) throws -> WireJSON? {
        try MCPMain.respond(to: Data(line.utf8)).map { try WireJSON.parse($0) }
    }

    @Test func initializeEchoesTheProtocolVersionAndNamesTheServerTf() throws {
        let response = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.241"}}}"#))
        #expect(response["id"] == .int(1))
        #expect(response["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(response["result"]?["serverInfo"]?["name"] == .string("tf"))
        #expect(response["result"]?["capabilities"]?["tools"] == .object([:]))
    }

    @Test func notificationsGetNoReply() throws {
        #expect(try Self.reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try Self.reply(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) == nil)
    }

    @Test func toolsListOffersExactlyAskUserWithTheQuestionSchema() throws {
        let response = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        let tools = try #require(response["result"]?["tools"]?.arrayValue)
        #expect(tools.count == 1)
        #expect(tools[0]["name"] == .string("ask_user"))
        let schema = try #require(tools[0]["inputSchema"])
        #expect(schema == AskUserSchema.inputSchema)
        #expect(schema["properties"]?["questions"]?["maxItems"] == .int(4))
        #expect(schema["properties"]?["questions"]?["items"]?["required"] == .array([.string("id"), .string("text")]))
    }

    @Test func toolsCallReturnsTheAnswersTheHookPutIn() throws {
        let response = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ask_user","arguments":{"questions":[{"id":"color","text":"Which?"}],"answers":{"color":"blue"}}}}"#))
        let content = try #require(response["result"]?["content"]?.arrayValue)
        #expect(content == [.object(["type": .string("text"), "text": .string(#"The user answered: {"color":"blue"}"#)])])
        #expect(response["result"]?["isError"] == nil || response["result"]?["isError"] == .bool(false))
    }

    @Test func toolsCallWithoutAnswersIsAnErrorResult() throws {
        for arguments in [#"{"questions":[{"id":"a","text":"?"}]}"#, #"{"questions":[{"id":"a","text":"?"}],"answers":{}}"#] {
            let response = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"ask_user","arguments":\#(arguments)}}"#))
            #expect(response["result"]?["isError"] == .bool(true))
            #expect(response["result"]?["content"]?.arrayValue?.first?["text"] == .string("No answer yet"))
        }
        let unknown = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"run_shell","arguments":{}}}"#))
        #expect(unknown["result"]?["isError"] == .bool(true))
    }

    @Test func unknownMethodsAreMethodNotFoundAndPingIsEmpty() throws {
        let unknown = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#))
        #expect(unknown["error"]?["code"] == .int(-32601))
        #expect(unknown["id"] == .int(3))
        let ping = try #require(try Self.reply(#"{"jsonrpc":"2.0","id":4,"method":"ping"}"#))
        #expect(ping["result"] == .object([:]))
    }

    @Test func aBrokenLineIsAParseError() throws {
        let response = try #require(try Self.reply("{nope"))
        #expect(response["error"]?["code"] == .int(-32700))
        #expect(response["id"] == .null)
    }

    /// 실제로 빌드한 helper를 띄워 stdio로 한 번 왕복한다 (디스크 · 네트워크 0, stdin EOF에 끝남)
    @Test func theBuiltHelperAnswersOverStdioAndExitsAtEOF() async throws {
        let process = Process()
        process.executableURL = try HelperBinaries.url("tf-agent-mcp")
        process.arguments = ["--session", "5e551011-0000-4000-8000-000000000001"]
        process.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let waiting = ProcessBox(process)
        _ = try #require(try await offPool { try waiting.run(input: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8 + [0x0A])) }, "stdin EOF에 끝났다")
        let data = output.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        let line = try #require(data.split(separator: 0x0A).first)
        #expect(try WireJSON.parse(Data(line))["result"]?["tools"]?.arrayValue?.count == 1)
    }
}

/// SwiftPM이 시험 의존으로 빌드한 helper 실행 파일 (시험 번들 `.xctest`가 있는 빌드 폴더)
enum HelperBinaries {
    struct Missing: Error {}

    static func url(_ name: String) throws -> URL {
        guard let folder = productsFolder() else { throw Missing() }
        let candidate = folder.appending(path: name)
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else { throw Missing() }
        return candidate
    }

    /// 올라온 이미지 중 `.xctest` 번들 안의 실행 파일을 찾아 그 번들이 있는 폴더를 돌려준다
    static func productsFolder() -> URL? {
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            guard let range = path.range(of: ".xctest/") else { continue }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".xctest").deletingLastPathComponent()
        }
        return nil
    }
}
#endif
