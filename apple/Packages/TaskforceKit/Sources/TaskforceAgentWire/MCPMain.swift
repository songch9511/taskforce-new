#if os(macOS)
import Darwin
import Foundation

/// `tf-agent-mcp` 본체: Taskforce MCP 서버 `tf`의 stdio JSON-RPC (OA D3a 계약 3.3). 도구는 `ask_user` 하나다.
/// 도구 본문은 훅이 `updatedInput.answers`로 넣어 준 답을 결과로 돌려줄 뿐이다 (답 없이 불리면 오류 결과 "No answer yet").
/// 디스크 · 네트워크 · 소켓 0, stdin EOF에 끝난다. 줄마다 JSON 하나 (MCP stdio 전송)
public enum MCPMain {
    static let maxLineBytes = 4 * 1024 * 1024
    static let defaultProtocolVersion = "2024-11-05"

    /// 한 줄에 대한 답 (알림이면 nil)
    public static func respond(to line: Data) -> Data? {
        guard line.count <= maxLineBytes, let message = try? WireJSON.parse(line), case .object(let fields) = message else {
            return reply(id: .null, error: -32700, message: "Parse error")
        }
        guard let method = fields["method"]?.stringValue else {
            // 응답 · 모양이 틀린 요청: id가 있으면 오류로 답한다
            return fields["id"].map { reply(id: $0, error: -32600, message: "Invalid request") }
        }
        guard let id = fields["id"] else { return nil } // 알림
        let params = fields["params"]
        switch method {
        case "initialize":
            let version = params?["protocolVersion"]?.stringValue ?? defaultProtocolVersion
            return reply(id: id, result: .object([
                "protocolVersion": .string(version),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string(AskUserSchema.serverName), "version": .string("1.0.0")]),
            ]))
        case "ping":
            return reply(id: id, result: .object([:]))
        case "tools/list":
            return reply(id: id, result: .object(["tools": .array([.object([
                "name": .string(AskUserSchema.toolName), "description": .string(AskUserSchema.toolDescription), "inputSchema": AskUserSchema.inputSchema,
            ])])]))
        case "tools/call":
            guard params?["name"]?.stringValue == AskUserSchema.toolName else { return reply(id: id, result: toolError("Unknown tool")) }
            guard case .object(let answers)? = params?["arguments"]?["answers"], !answers.isEmpty else { return reply(id: id, result: toolError("No answer yet")) }
            return reply(id: id, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("The user answered: " + WireJSON.object(answers).canonicalText)])]),
            ]))
        default:
            return reply(id: id, error: -32601, message: "Method not found")
        }
    }

    static func toolError(_ text: String) -> WireJSON {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(true)])
    }

    static func reply(id: WireJSON, result: WireJSON) -> Data {
        line(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    static func reply(id: WireJSON, error code: Int, message: String) -> Data {
        line(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .int(Int64(code)), "message": .string(message)])]))
    }

    static func line(_ value: WireJSON) -> Data {
        var data = value.canonicalData
        data.append(0x0A)
        return data
    }

    /// 실행 파일의 진입점: stdin 줄마다 답한다. EOF면 0으로 끝난다. 인자(`--session <id>`)는 쓰지 않는다
    public static func main(arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { read(STDIN_FILENO, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                if let answer = respond(to: Data(line)), !HookMain.writeAll(fd: STDOUT_FILENO, answer) { return 0 }
            }
            if pending.count > maxLineBytes {
                pending.removeAll()
                if !HookMain.writeAll(fd: STDOUT_FILENO, reply(id: .null, error: -32700, message: "Parse error")) { return 0 }
            }
        }
        return 0
    }
}
#endif
