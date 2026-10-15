#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import TaskforceAgentWire

/// 오래 막히는 호출을 협력 스레드 밖에서 돌린다 (시험 전체가 동시에 돌 때 다른 시험을 굶기지 않게)
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// `Process`를 다른 스레드로 넘기는 상자
final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

/// 훅 쪽 소켓 연결 (OA D3a 계약 2.6): 한 줄 보내고 한 줄 받기, 1.5초 기한, 104바이트 경로 상한, 응답 256KB 상한.
/// 실제로 빌드한 `tf-agent-hook`도 띄워 소켓이 없을 때 1.6초 안에 deny JSON · exit 0인지 본다 (계약 4.4 M1의 Kit 짝)
@Suite(.serialized)
struct UnixSocketTests {
    /// 시험용 아주 작은 서버: 연결 하나를 받아 `reply`가 준 바이트를 쓰고 닫는다 (nil이면 답하지 않고 붙잡는다)
    final class TinyServer: @unchecked Sendable {
        let path: String
        let fd: Int32
        private let lock = NSLock()
        private var held: [Int32] = []
        private(set) var received = Data()

        init(reply: @escaping @Sendable (Data) -> Data?) throws {
            let dir = FileManager.default.temporaryDirectory.appending(path: "tfw-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let socketPath = dir.appending(path: "s.sock").path
            path = socketPath
            let listener = socket(AF_UNIX, SOCK_STREAM, 0)
            fd = listener
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: Array(socketPath.utf8) + [0])
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) } }
            guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
            Thread.detachNewThread { [weak self] in
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 65536)
                var data = Data()
                while !data.contains(0x0A) {
                    let count = read(client, &buffer, buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                if let answer = reply(data) {
                    self?.store(data, holding: nil)
                    _ = answer.withUnsafeBytes { write(client, $0.baseAddress, answer.count) }
                    close(client)
                } else if let self {
                    self.store(data, holding: client)
                } else {
                    close(client)
                }
            }
        }

        deinit {
            for client in held { close(client) }
            close(fd)
            unlink(path)
        }

        var receivedLine: Data { lock.withLock { received } }

        private func store(_ data: Data, holding client: Int32?) {
            lock.withLock {
                received = data
                if let client { held.append(client) }
            }
        }
    }

    @Test func oneLineGoesOutAndOneLineComesBack() throws {
        let server = try TinyServer { _ in Data(#"{"decision":"allow","reason":"ok"}"#.utf8 + [0x0A]) }
        let reply = try UnixSocket.exchange(path: server.path, request: Data("{\"v\":1}\n".utf8), deadline: Date().addingTimeInterval(1.5))
        #expect(String(decoding: reply, as: UTF8.self) == #"{"decision":"allow","reason":"ok"}"# + "\n")
        #expect(server.receivedLine == Data("{\"v\":1}\n".utf8))
    }

    @Test func aSilentBridgeRunsIntoTheDeadline() async throws {
        let server = try TinyServer { _ in nil }
        let started = Date()
        let path = server.path
        let outcome = try await offPool { () -> WireError? in
            do {
                _ = try UnixSocket.exchange(path: path, request: Data("{}\n".utf8), deadline: Date().addingTimeInterval(0.3))
                return nil
            } catch let error as WireError {
                return error
            }
        }
        #expect(outcome == .timedOut)
        #expect(Date().timeIntervalSince(started) < 0.8)
        _ = server
    }

    @Test func aMissingSocketAndAnOverlongPathFailFast() {
        #expect(throws: WireError.self) { try UnixSocket.exchange(path: "/tmp/tf-no-such-\(UUID().uuidString)/hook.sock", request: Data("{}\n".utf8), deadline: Date().addingTimeInterval(1)) }
        let long = "/tmp/" + String(repeating: "x", count: 120) + "/hook.sock"
        #expect(throws: WireError.pathTooLong) { try UnixSocket.exchange(path: long, request: Data("{}\n".utf8), deadline: Date().addingTimeInterval(1)) }
    }

    @Test func anOversizedReplyIsRefused() throws {
        let server = try TinyServer { _ in Data(repeating: 0x61, count: HookWire.maxLineBytes + 10) }
        #expect(throws: WireError.tooLarge) { try UnixSocket.exchange(path: server.path, request: Data("{}\n".utf8), deadline: Date().addingTimeInterval(1.5)) }
    }

    /// 빌드한 helper: 소켓이 없으면 기다리지 않고 deny JSON · exit 0 (stderr · 디스크 0)
    @Test func theBuiltHookDeniesQuicklyWithoutASocket() throws {
        let process = Process()
        process.executableURL = try HelperBinaries.url("tf-agent-hook")
        process.arguments = ["pre-tool-use", "--socket", "/tmp/tf-none-\(UUID().uuidString.prefix(6))/hook.sock", "--session", "5e551011-0000-4000-8000-000000000001", "--nonce", "Zm9v"]
        process.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(HookMainTests.stdin(tool: "Write", input: #"{"file_path":"/w/a","content":"x"}"#))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)
        #expect(process.terminationStatus == 0)
        #expect(elapsed < 1.6)
        let out = output.fileHandleForReading.readDataToEndOfFile()
        #expect(try HookMainTests.output(HookMain.Result(stdout: out, exitCode: 0)).decision == "deny")
        #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    /// 빌드한 helper: bridge가 답하지 않으면 1.5초에서 끊고 deny (G1)
    @Test func theBuiltHookGivesUpAfterTheBudget() async throws {
        let server = try TinyServer { _ in nil }
        let process = Process()
        process.executableURL = try HelperBinaries.url("tf-agent-hook")
        process.arguments = ["pre-tool-use", "--socket", server.path, "--session", "5e551011-0000-4000-8000-000000000001", "--nonce", "Zm9v"]
        process.environment = ["HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(HookMainTests.stdin(tool: "Write", input: #"{"file_path":"/w/a","content":"x"}"#))
        try input.fileHandleForWriting.close()
        let waiting = ProcessBox(process)
        _ = try await offPool { waiting.process.waitUntilExit() }
        let elapsed = Date().timeIntervalSince(started)
        #expect(process.terminationStatus == 0)
        #expect(elapsed >= 1.4 && elapsed < 1.9, "\(elapsed)")
        let out = output.fileHandleForReading.readDataToEndOfFile()
        #expect(try HookMainTests.output(HookMain.Result(stdout: out, exitCode: 0)).decision == "deny")
    }
}
#endif
