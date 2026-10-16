#if os(macOS)
import Darwin
import Foundation

/// `tf-agent-hook` 본체 (OA D3a 계약 2.3 · 2.6 · 3.4). 하위 명령 둘:
/// - `session-start`: 소켓 없이 표식만 낸다 (자체 점검 ③)
/// - `pre-tool-use --socket <S> --session <id> --nonce <N>`: 훅 입력을 읽어 bridge에 한 줄 묻고, 답을 Claude Code 훅 출력으로 바꾼다
///
/// **fail-closed:** 기한(시작부터 `HookWire.budget` 4초) 초과 · 소켓 없음 · 거부 · 깨진 답 · 모르는 결정 · 어떤 오류든 deny JSON + exit 0. deny JSON마저 쓰지 못하면 exit 2 (Claude Code는 2를 차단으로 본다, S0 CC-3b).
/// 디스크 · 로그 · stderr에 아무것도 쓰지 않는다. 사용자를 기다리지 않는다 (훅 timeout은 fail-open 경로다)
public enum HookMain {
    public typealias Connect = @Sendable (_ socketPath: String, _ request: Data, _ deadline: Date) throws -> Data

    public struct Result: Equatable, Sendable {
        public var stdout: Data
        public var exitCode: Int32

        public init(stdout: Data, exitCode: Int32) {
            self.stdout = stdout
            self.exitCode = exitCode
        }
    }

    struct Invocation {
        var socket: String
        var session: String
        var nonce: String
    }

    static func deny(_ reason: String) -> Result {
        Result(stdout: HookOutput.preToolUse(.deny, reason: reason), exitCode: 0)
    }

    /// 순수 본체: 인자 · stdin · 연결 · 기한을 주입받아 출력과 종료 코드를 돌려준다
    public static func run(arguments: [String], stdin: Data, connect: Connect, deadline: Date, now: () -> Date = Date.init) -> Result {
        if arguments == ["session-start"] {
            return Result(stdout: HookOutput.sessionStart(), exitCode: 0)
        }
        guard let invocation = parse(arguments) else { return deny(HookReason.unreadable) }
        guard stdin.count <= HookWire.maxStdinBytes else { return deny(HookReason.unreadable) }
        guard let input = try? WireJSON.parse(stdin), input["hook_event_name"]?.stringValue == "PreToolUse",
              let toolName = input["tool_name"]?.stringValue, let toolUseID = input["tool_use_id"]?.stringValue,
              let permissionMode = input["permission_mode"]?.stringValue, let cwd = input["cwd"]?.stringValue else {
            return deny(HookReason.unreadable)
        }
        let toolInput = input["tool_input"] ?? .object([:])
        guard toolInput.objectValue != nil else { return deny(HookReason.unreadable) }
        var request = HookRequest(
            nonce: invocation.nonce, sessionID: invocation.session, providerSessionID: input["session_id"]?.stringValue, hookEvent: "PreToolUse", toolUseID: toolUseID,
            toolName: toolName, toolInput: HookWire.strippedInput(toolName: toolName, input: toolInput), inputSHA256: HookWire.inputDigest(toolInput),
            permissionMode: permissionMode, cwd: cwd
        )
        guard now() < deadline else { return deny(HookReason.unavailable) }
        // 남은 시간을 싣는다 (16장 3): bridge는 이 훅이 끊기 전에 응답을 정한다
        request.remainingMS = min(HookWire.maxRemainingMS, max(0, Int((deadline.timeIntervalSince(now()) * 1000).rounded(.down))))
        guard let line = try? request.encodedLine() else { return deny(HookReason.unavailable) }
        let reply: Data
        do {
            reply = try connect(invocation.socket, line, deadline)
        } catch {
            return deny(HookReason.unavailable)
        }
        // 기한을 넘겨 온 답은 쓰지 않는다 (훅 timeout이 끊기 전에 끝낸다)
        guard now() <= deadline, let response = try? HookResponse.decode(line: reply) else { return deny(HookReason.unavailable) }
        switch response.decision {
        case .deny:
            return Result(stdout: HookOutput.preToolUse(.deny, reason: response.reason), exitCode: 0)
        case .defer:
            guard response.answers == nil, response.command == nil else { return deny(HookReason.unavailable) }
            return Result(stdout: HookOutput.preToolUse(.defer, reason: response.reason), exitCode: 0)
        case .allow:
            guard case .object(var fields) = toolInput else { return deny(HookReason.unavailable) }
            switch (response.answers, response.command) {
            case (nil, nil):
                return Result(stdout: HookOutput.preToolUse(.allow, reason: response.reason), exitCode: 0)
            case (let answers?, nil):
                guard toolName == AskUserSchema.qualifiedName else { return deny(HookReason.unavailable) }
                fields["answers"] = .object(answers)
            case (nil, let command?):
                guard toolName == "Bash" else { return deny(HookReason.unavailable) }
                fields["command"] = .string(command)
            default:
                return deny(HookReason.unavailable)
            }
            return Result(stdout: HookOutput.preToolUse(.allow, reason: response.reason, updatedInput: .object(fields)), exitCode: 0)
        }
    }

    static func parse(_ arguments: [String]) -> Invocation? {
        guard arguments.count == 7, arguments[0] == "pre-tool-use" else { return nil }
        var values: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            let key = arguments[index]
            guard ["--socket", "--session", "--nonce"].contains(key), values[key] == nil, !arguments[index + 1].isEmpty else { return nil }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let socket = values["--socket"], let session = values["--session"], let nonce = values["--nonce"] else { return nil }
        return Invocation(socket: socket, session: session, nonce: nonce)
    }

    /// 출력을 쓴다. 쓰기에 실패하면 2 (deny JSON도 못 썼다 → Claude Code가 차단으로 본다)
    public static func emit(_ result: Result, write: (Data) -> Bool) -> Int32 {
        write(result.stdout) ? result.exitCode : 2
    }

    /// 실행 파일의 진입점: 기한은 프로세스 시작 시각부터 `HookWire.budget`. stdin은 상한 + 1바이트까지만 읽는다
    public static func main(arguments: [String]) -> Int32 {
        let deadline = Date().addingTimeInterval(HookWire.budget)
        signal(SIGPIPE, SIG_IGN)
        // SessionStart 입력도 읽고 버린다 (쓰는 쪽이 닫힌 파이프를 만나지 않게)
        let stdin = readAll(fd: STDIN_FILENO, limit: HookWire.maxStdinBytes + 1, deadline: deadline)
        let result = run(arguments: arguments, stdin: stdin, connect: { path, request, deadline in
            try UnixSocket.exchange(path: path, request: request, deadline: deadline)
        }, deadline: deadline)
        return emit(result, write: { writeAll(fd: STDOUT_FILENO, $0) })
    }

    /// 프로세스를 끝낸다 (main.swift 한 줄용)
    public static func exitProcess(_ code: Int32) -> Never {
        exit(code)
    }

    /// stdin을 기한 안에서 `limit` 바이트까지 읽는다 (넘으면 거기서 멈춘다: 상한 검사가 deny로 만든다)
    static func readAll(fd: Int32, limit: Int, deadline: Date) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            let ready = poll(&item, 1, Int32(max(1, (left * 1000).rounded(.up))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress!, min($0.count, limit - data.count)) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                continue
            } else {
                break
            }
        }
        return data
    }

    /// 끝까지 쓴다 (EINTR은 다시). 실패하면 false
    public static func writeAll(fd: Int32, _ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + written, $0.count - written) }
            if count > 0 {
                written += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
#endif
