#if os(macOS) && DEBUG
import Foundation
@testable import TaskforceKit

/// 중계 시험의 가짜들 (PR-D3k): 실제 `claude` · 실제 프로세스 · 실제 사용자 세션은 만지지 않는다.
/// 가짜 중계 프로세스는 stdin 한 줄(stream-json user 메시지)을 받아 정해 둔 stdout 줄을 낸다 (`/tfping`은 nonce를 되돌리고, `/tfsend`는 정해 둔 결과를 낸다)
enum RelayLines {
    static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static let initLine = json(["type": "system", "subtype": "init", "model": "claude-opus-5-5", "session_id": "relay"])

    /// mod 명령의 정상 답: `assistant`(`<synthetic>`) + `result`(custom, 0 턴, 비용 0)
    static func modAnswer(_ payload: [String: Any]) -> [Data] {
        let text = "tf-relay: " + String(decoding: json(payload), as: UTF8.self)
        return [
            json(["type": "assistant", "message": ["model": "<synthetic>", "role": "assistant", "content": [["type": "text", "text": text]]], "session_id": "relay"]),
            json([
                "type": "result", "subtype": "success", "is_error": false, "result": text, "local_command": "custom", "num_turns": 0, "total_cost_usd": 0, "modelUsage": [String: Any](),
                "session_id": "relay",
            ]),
        ]
    }

    static func ping(nonce: String) -> [Data] { modAnswer(["mod": "tf-relay", "version": "1", "ok": true, "nonce": nonce]) }

    static func sent(delivered: Bool, reason: String? = nil) -> [Data] {
        modAnswer(["mod": "tf-relay", "version": "1", "ok": true, "isDelivered": delivered, "reason": reason as Any? ?? NSNull()])
    }

    /// mod가 안 올라와 모델에 간 경우 (탐침: model claude-opus-5-5, 비용 0.026, 예산 초과 오류)
    static var modelTurn: [Data] {
        [
            json(["type": "assistant", "message": ["model": "claude-opus-5-5", "role": "assistant", "content": [["type": "text", "text": "`/tfping` isn't installed"]]], "session_id": "relay"]),
            json(["type": "result", "subtype": "error_max_budget_usd", "is_error": true, "num_turns": 1, "total_cost_usd": 0.026, "modelUsage": ["claude-opus-5-5": ["inputTokens": 3]], "session_id": "relay"]),
        ]
    }
}

/// 가짜 중계 프로세스. stdin으로 받은 줄을 기록하고, 정해 둔 규칙으로 stdout 줄을 낸다
final class FakeRelayProcess: ClaudeAppRelayProcess, @unchecked Sendable {
    /// 받은 stdin 한 줄에 대한 stdout 줄들 (nil이면 아무 답도 안 한다: 멈춘 중계)
    typealias Rule = @Sendable (_ content: String, _ nonce: String?) -> [Data]?

    let pid: Int32
    let startedAt: Date?
    let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var _writes: [String] = []
    private var _stopped = false
    private var _identityOK = true
    private var _rule: Rule
    private var _failWrites = false

    init(pid: Int32 = 4242, startedAt: Date? = Date(timeIntervalSince1970: 1_799_999_000), rule: Rule? = nil) {
        self.pid = pid
        self.startedAt = startedAt
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lines = stream
        self.continuation = continuation
        _rule = rule ?? FakeRelayProcess.defaultRule
        continuation.yield(RelayLines.initLine)
    }

    /// 기본 규칙: `/tfping <nonce>`는 nonce를 되돌리고 `/tfsend`는 전달됐다고 답한다
    static let defaultRule: Rule = { content, _ in
        if content.hasPrefix("/tfping ") { return RelayLines.ping(nonce: String(content.dropFirst("/tfping ".count))) }
        if content.hasPrefix("/tfsend ") { return RelayLines.sent(delivered: true) }
        return nil
    }

    var writes: [String] { lock.withLock { _writes } }
    var isStopped: Bool { lock.withLock { _stopped } }
    var identityOK: Bool {
        get { lock.withLock { _identityOK } }
        set { lock.withLock { _identityOK = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }
    func setRule(_ rule: @escaping Rule) { lock.withLock { _rule = rule } }

    /// stdin 줄에서 `content`를 꺼낸다
    static func content(of line: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let message = object["message"] as? [String: Any] else { return nil }
        return message["content"] as? String
    }

    func write(_ data: Data) async -> Bool {
        let (fails, rule) = lock.withLock { (_failWrites, _rule) }
        if fails { return false }
        let text = String(decoding: data, as: UTF8.self)
        let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
        lock.withLock { _writes.append(line) }
        guard let content = Self.content(of: line) else { return true }
        let nonce = content.hasPrefix("/tfping ") ? String(content.dropFirst("/tfping ".count)) : nil
        for answer in rule(content, nonce) ?? [] { continuation.yield(answer) }
        return true
    }

    func stop() async {
        lock.withLock { _stopped = true }
        continuation.finish()
    }

    func identityMatches() -> Bool { identityOK }

    /// 시험이 직접 낸다
    func emit(_ line: Data) { continuation.yield(line) }
    func emit(_ lines: [Data]) { for line in lines { continuation.yield(line) } }
    /// 프로세스가 스스로 끝났다 (EOF)
    func die() { continuation.finish() }

    /// stdin에 쓴 `content`들 (JSON을 벗긴 글)
    var contents: [String] { writes.compactMap { Self.content(of: $0) } }
}

/// 띄우는 쪽을 대신하는 가짜: 받은 인자 · 폴더를 기록하고, 정해 둔 프로세스를 차례로 내준다
final class FakeRelayLauncher: ClaudeAppRelayLauncher, @unchecked Sendable {
    struct Launch: Equatable, Sendable {
        let arguments: [String]
        let cwd: String
    }

    private let lock = NSLock()
    private var _launches: [Launch] = []
    private var queue: [FakeRelayProcess] = []
    private var _processes: [FakeRelayProcess] = []
    private var _failNext = 0
    private let make: @Sendable (Int) -> FakeRelayProcess

    init(make: @escaping @Sendable (Int) -> FakeRelayProcess = { FakeRelayProcess(pid: Int32(4000 + $0)) }) { self.make = make }

    var launches: [Launch] { lock.withLock { _launches } }
    var processes: [FakeRelayProcess] { lock.withLock { _processes } }
    func failNext(_ count: Int = 1) { lock.withLock { _failNext = count } }
    func enqueue(_ process: FakeRelayProcess) { lock.withLock { queue.append(process) } }

    func launch(arguments: [String], cwd: String) async throws -> any ClaudeAppRelayProcess {
        struct Refused: Error {}
        let (process, refused): (FakeRelayProcess?, Bool) = lock.withLock {
            _launches.append(Launch(arguments: arguments, cwd: cwd))
            if _failNext > 0 {
                _failNext -= 1
                return (nil, true)
            }
            let made = queue.isEmpty ? make(_launches.count) : queue.removeFirst()
            _processes.append(made)
            return (made, false)
        }
        if refused { throw Refused() }
        return process!
    }
}

/// 손으로 흘리는 잠자기: `advance`가 시각을 올리면 그 안에 끝날 잠이 깬다 (명령 시간 초과 · 2분 유휴 시험)
final class ClaudeAppManualSleeper: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var waiters: [Waiter] = []
    private var _requested: [TimeInterval] = []

    var pending: Int { lock.withLock { waiters.count } }
    var requested: [TimeInterval] { lock.withLock { _requested } }

    func sleep(_ delay: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock {
                    _requested.append(delay)
                    waiters.append(Waiter(id: id, deadline: now + delay, continuation: continuation))
                }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).continuation
        }
        continuation?.resume()
    }

    /// 시각을 올리고 그 안에 끝날 잠을 모두 깨운다
    func advance(_ seconds: TimeInterval) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            now += seconds
            let ready = waiters.filter { $0.deadline <= now }
            waiters.removeAll { $0.deadline <= now }
            return ready.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

/// 앱 번들에 들어가는 mod 세 파일의 사본 (시험이 해시 검사를 통과하는 mod 폴더를 만든다)
enum ClaudeAppModFixture {
    static func copy() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tf-relay-fixture-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let real = GateFileSystem.realpath(root.path) ?? root.path
        let target = real + "/tf-relay"
        for file in ClaudeAppRelayMod.files {
            let destination = target + "/" + file.path
            try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: ExternalSessionSuites.ClaudeAppRelayModTests.repositoryMod + "/" + file.path, toPath: destination)
        }
        return target
    }

    static func cleanup(_ target: String) { try? FileManager.default.removeItem(atPath: (target as NSString).deletingLastPathComponent) }
}

/// 조건이 될 때까지 짧게 기다린다 (상한 안에 안 되면 false)
func relayEventually(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// 로그를 모으는 가짜 (글 · id가 새지 않는지 본다)
final class RelayLog: BridgeLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(String, [String: BridgeLogValue])] = []

    func log(_ event: String, _ fields: [String: BridgeLogValue]) { lock.withLock { _entries.append((event, fields)) } }

    var entries: [(event: String, fields: [String: BridgeLogValue])] { lock.withLock { _entries.map { (event: $0.0, fields: $0.1) } } }
    var text: String { entries.map { "\($0.event) \($0.fields.sorted { $0.key < $1.key })" }.joined(separator: "\n") }
    func events(_ name: String) -> [[String: BridgeLogValue]] { entries.filter { $0.event == name }.map(\.fields) }
}
#endif
