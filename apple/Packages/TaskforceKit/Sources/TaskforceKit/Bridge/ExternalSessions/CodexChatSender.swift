#if os(macOS)
import Darwin
import Foundation

public enum CodexChatSendError: Error, Equatable, Sendable {
    case unavailable, sessionUnavailable, rejected, deliveryUnknown
}
public struct CodexChatReceipt: Equatable, Sendable {
    public let threadID: String
    public let turnID: String
}
public struct CodexChatQuestion: Equatable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [String]
    public let isSecret: Bool
}
public enum CodexChatEvent: Equatable, Sendable {
    case managedThread(String)
    case contextCompaction(Bool)
    case approval(id: String, kind: String, summary: String)
    case input(id: String, questions: [CodexChatQuestion])
    case turnCompleted(threadID: String, turnID: String)
    case requestResolved(id: String)
    case failure(CodexChatSendError)
}
public enum CodexChatResponse: Equatable, Sendable {
    case approve, deny, input([String: [String]])
}
protocol CodexChatConnection: AnyObject, Sendable {
    func write(_ data: Data) throws
    func read() throws -> Data
    func close()
}

/// Owns one app-server process and an isolated fork. The original desktop thread
/// is never resumed or sent a turn. Owned sessions use workspace-write with
/// on-request approvals routed to the user, regardless of the source settings.
public actor CodexChatSender {
    public struct Configuration: Sendable {
        public let candidates: [String]
        public init(candidates: [String]) { self.candidates = candidates }
        public static var standard: Configuration {
            .init(candidates: [NSHomeDirectory() + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
        }
    }
    public nonisolated let events: AsyncStream<CodexChatEvent>
    private let eventSink: AsyncStream<CodexChatEvent>.Continuation
    private let factory: @Sendable () throws -> any CodexChatConnection
    private let workingDirectory: @Sendable (String) async -> String?
    public var managedThreadID: String? { managedID }
    private var deliveryUncertain = false
    private var completedTurns = Set<String>()
    private var isCompacting = false
    private var fileChanges: [String: (turn: String, summary: String)] = [:]
    private var connection: (any CodexChatConnection)?
    private var reader: Task<Void, Never>?
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var requests: [String: (id: Data, method: String, questions: [String], permissions: Data?, turn: String)] = [:]
    private var nextID = 0
    private var generation = UUID()
    private var connectionID = UUID()
    private var busy = false
    private var initialized = false
    private var managedID: String?
    private var sourceID: String?
    private var resumed = false
    private var turnID: String?

    public init(configuration: Configuration = .standard, managedThreadID: String? = nil, workingDirectory: @escaping @Sendable (String) async -> String? = { CodexLocalSessionReader().workingDirectory(sessionID: $0) }) {
        self.workingDirectory = workingDirectory
        factory = { try CodexStdioConnection(configuration: configuration) }
        managedID = managedThreadID
        let stream = AsyncStream<CodexChatEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = stream.stream; eventSink = stream.continuation
    }
    init(factory: @escaping @Sendable () throws -> any CodexChatConnection, managedThreadID: String? = nil, workingDirectory: @escaping @Sendable (String) async -> String?) {
        self.workingDirectory = workingDirectory
        self.factory = factory; managedID = managedThreadID
        let stream = AsyncStream<CodexChatEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = stream.stream; eventSink = stream.continuation
    }

    public func send(threadID: String, text: String) async throws -> CodexChatReceipt {
        guard ExternalSessionRules.isCanonicalUUID(threadID), sourceID == nil || sourceID == threadID else { throw CodexChatSendError.sessionUnavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768, !busy, !deliveryUncertain, turnID == nil else { throw CodexChatSendError.rejected }
        busy = true
        let token = generation
        defer { if generation == token { busy = false } }
        sourceID = threadID
        try await connect()
        guard generation == token else { throw CodexChatSendError.unavailable }
        if !resumed {
            let method: String
            let target: String
            if let managedID {
                guard managedID != threadID, ExternalSessionRules.isCanonicalUUID(managedID) else { throw CodexChatSendError.sessionUnavailable }
                method = "thread/resume"; target = managedID
            } else { method = "thread/fork"; target = threadID }
            guard let cwd = await workingDirectory(threadID), cwd.hasPrefix("/"), !cwd.contains("\0") else { throw CodexChatSendError.sessionUnavailable }
            let data: Data
            do {
                data = try await request(method, params: ["threadId": target, "excludeTurns": true, "cwd": cwd, "sandbox": "workspace-write", "approvalPolicy": "on-request", "approvalsReviewer": "user"])
            } catch { deliveryUncertain = true; throw error }
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
                  ExternalSessionRules.isCanonicalUUID(id), id != threadID,
                  managedID == nil || managedID == id, result["cwd"] as? String == cwd,
                  result["approvalPolicy"] as? String == "on-request", result["approvalsReviewer"] as? String == "user",
                  let sandbox = result["sandbox"] as? [String: Any],
                  ["workspaceWrite", "readOnly"].contains(sandbox["type"] as? String ?? ""),
                  (sandbox["writableRoots"] as? [String] ?? []).allSatisfy({ $0 == cwd }),
                  sandbox["networkAccess"] as? Bool != true else { throw CodexChatSendError.sessionUnavailable }
            managedID = id; resumed = true
            publish(.managedThread(id))
        }
        guard let managedID, generation == token else { throw CodexChatSendError.unavailable }
        let data: Data
        do {
            data = try await request("turn/start", params: ["threadId": managedID, "input": [["type": "text", "text": text, "text_elements": []]]])
        } catch let error as CodexChatSendError where error == .rejected { throw error }
        catch { deliveryUncertain = true; throw CodexChatSendError.deliveryUnknown }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String, !id.isEmpty else { deliveryUncertain = true; throw CodexChatSendError.deliveryUnknown }
        if !completedTurns.contains(id) { turnID = id }
        return .init(threadID: managedID, turnID: id)
    }

    public func interrupt() async throws {
        guard let managedID, let turnID else { return }
        _ = try await request("turn/interrupt", params: ["threadId": managedID, "turnId": turnID])
    }

    public func respond(requestID: String, response: CodexChatResponse) async throws {
        guard let request = requests[requestID], let connection else { throw CodexChatSendError.rejected }
        let result: [String: Any]
        switch (request.method, response) {
        case ("item/commandExecution/requestApproval", .approve), ("item/fileChange/requestApproval", .approve): result = ["decision": "accept"]
        case ("item/commandExecution/requestApproval", .deny), ("item/fileChange/requestApproval", .deny): result = ["decision": "decline"]
        case ("item/permissions/requestApproval", .approve):
            guard let data = request.permissions, let permissions = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CodexChatSendError.rejected }
            result = ["permissions": permissions, "scope": "turn"]
        case ("item/permissions/requestApproval", .deny): result = ["permissions": [String: String](), "scope": "turn"]
        case ("item/tool/requestUserInput", .input(let answers)):
            guard Set(answers.keys) == Set(request.questions), answers.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.utf8.count <= 32_768 } }) else { throw CodexChatSendError.rejected }
            result = ["answers": answers.mapValues { ["answers": $0] }]
        default: throw CodexChatSendError.rejected
        }
        let id = try JSONSerialization.jsonObject(with: request.id, options: .fragmentsAllowed)
        try connection.write(JSONSerialization.data(withJSONObject: ["id": id, "result": result]))
        requests.removeValue(forKey: requestID)
        publish(.requestResolved(id: requestID))
    }

    public func stop() async {
        generation = UUID()
        connection?.close(); connection = nil
        reader?.cancel(); reader = nil
        initialized = false; resumed = false; busy = false; turnID = nil
        requests.removeAll(); fileChanges.removeAll()
        setCompacting(false)
        failPending(.unavailable)
    }

    deinit { connection?.close(); reader?.cancel(); eventSink.finish() }

    private func connect() async throws {
        if initialized { return }
        if connection == nil {
            let channel: any CodexChatConnection
            do { channel = try factory() } catch { throw CodexChatSendError.unavailable }
            connection = channel
            connectionID = UUID()
            let token = generation
            // Pipe reads block until the server produces a line. Keep them off Swift's
            // cooperative executor so simultaneous sessions cannot starve RPC handling.
            let readQueue = DispatchQueue(label: "taskforce.codex.read.\(connectionID)", qos: .utility)
            reader = Task.detached { [weak self] in
                do {
                    while !Task.isCancelled {
                        let data: Data = try await withCheckedThrowingContinuation { continuation in
                            readQueue.async {
                                do { continuation.resume(returning: try channel.read()) }
                                catch { continuation.resume(throwing: error) }
                            }
                        }
                        await self?.receive(data, token: token)
                    }
                } catch { await self?.disconnected(token: token) }
            }
        }
        _ = try await request("initialize", params: ["clientInfo": ["name": "taskforce", "version": "0.2.0"], "capabilities": ["experimentalApi": true]])
        guard let connection else { throw CodexChatSendError.unavailable }
        try connection.write(JSONSerialization.data(withJSONObject: ["method": "initialized"]))
        initialized = true
    }
    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        guard let connection else { throw CodexChatSendError.unavailable }
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timers[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await self?.timeout(id)
            }
            do { try connection.write(data) } catch { finish(id, result: .failure(CodexChatSendError.unavailable)) }
        }
    }
    private func timeout(_ id: Int) { finish(id, result: .failure(CodexChatSendError.unavailable)) }
    private func finish(_ id: Int, result: Result<Data, any Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func failPending(_ error: CodexChatSendError) {
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }
    private func disconnected(token: UUID) {
        guard generation == token else { return }
        connection?.close(); connection = nil; initialized = false; resumed = false; turnID = nil
        setCompacting(false)
        let staleRequestIDs = Array(requests.keys)
        requests.removeAll(); fileChanges.removeAll()
        for id in staleRequestIDs { publish(.requestResolved(id: id)) }
        failPending(.unavailable)
        publish(.failure(.unavailable))
    }
    private func publish(_ event: CodexChatEvent) {
        if case .dropped = eventSink.yield(event) {
            // Never silently lose a consent request and then keep executing.
            connection?.close(); connection = nil
            failPending(.unavailable)
        }
    }
    private func setCompacting(_ value: Bool) {
        guard isCompacting != value else { return }
        isCompacting = value
        publish(.contextCompaction(value))
    }
    private func receive(_ data: Data, token: UUID) {
        guard token == generation,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                handleServerRequest(id: id, method: method, params: params)
            } else if ["item/started", "item/completed"].contains(method), params["threadId"] as? String == managedID,
                      let item = params["item"] as? [String: Any], item["type"] as? String == "contextCompaction" {
                setCompacting(method == "item/started")
            } else if method == "item/started", params["threadId"] as? String == managedID,
                      let item = params["item"] as? [String: Any], item["type"] as? String == "fileChange",
                      let id = item["id"] as? String, let turn = params["turnId"] as? String,
                      let changes = item["changes"] as? [[String: Any]], fileChanges.count < 64 {
                let detail = changes.map { change in
                    [change["path"] as? String, change["diff"] as? String].compactMap { $0 }.joined(separator: "\n")
                }.joined(separator: "\n\n")
                let bounded = String(detail.prefix(32_768)) + (detail.count > 32_768 ? "\n[Additional changes omitted from this preview]" : "")
                fileChanges[id] = (turn, bounded)
            } else if method == "turn/completed", let thread = params["threadId"] as? String,
                      let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String, thread == managedID {
                setCompacting(false)
                if completedTurns.count >= 128 { completedTurns.removeAll() }
                completedTurns.insert(id)
                fileChanges = fileChanges.filter { $0.value.turn != id }
                if turnID == id { turnID = nil }
                for key in requests.keys.filter({ requests[$0]?.turn == id }) {
                    requests.removeValue(forKey: key); publish(.requestResolved(id: key))
                }
                publish(.turnCompleted(threadID: thread, turnID: id))
                if turn["status"] as? String == "failed" { publish(.failure(.rejected)) }
            } else if method == "serverRequest/resolved", let id = params["requestId"],
                      let encoded = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed) {
                let key = connectionID.uuidString + ":" + encoded.base64EncodedString()
                if requests.removeValue(forKey: key) != nil { publish(.requestResolved(id: key)) }
            }
            // Error notifications may precede automatic retry. Only terminal
            // turn/completed status changes the run state or reports failure.
            return
        }
        guard let id = message["id"] as? Int else { return }
        if message["error"] != nil { finish(id, result: .failure(CodexChatSendError.rejected)) }
        else if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
            finish(id, result: .success(data))
        } else { finish(id, result: .failure(CodexChatSendError.unavailable)) }
    }
    private func rejectRequest(id: Any) {
        guard let connection else { return }
        try? connection.write(JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32602, "message": "Invalid request"]]))
    }
    private func handleServerRequest(id: Any, method: String, params: [String: Any]) {
        guard let encoded = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), let connection else { return }
        let key = connectionID.uuidString + ":" + encoded.base64EncodedString()
        guard requests.count < 64, let managedID, params["threadId"] as? String == managedID,
              let requestTurn = params["turnId"] as? String, !requestTurn.isEmpty,
              turnID == nil || turnID == requestTurn else {
            try? connection.write(JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32601, "message": "Unsupported request"]])); return
        }
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            requests[key] = (encoded, method, [], nil, requestTurn)
            let changeSummary = (params["itemId"] as? String).flatMap { fileChanges[$0]?.summary }
            let summary = [params["reason"] as? String, params["command"] as? String, params["cwd"] as? String, changeSummary].compactMap { $0 }.joined(separator: "\n")
            publish(.approval(id: key, kind: method.contains("commandExecution") ? "command" : "file", summary: String(summary.prefix(40_960))))
        case "item/permissions/requestApproval":
            guard let permissions = params["permissions"] as? [String: Any],
                  Set(permissions.keys).isSubset(of: ["fileSystem", "network"]),
                  let data = try? JSONSerialization.data(withJSONObject: permissions, options: [.sortedKeys]), data.count <= 32_768 else {
                rejectRequest(id: id); return
            }
            requests[key] = (encoded, method, [], data, requestTurn)
            let reason = params["reason"] as? String ?? "Permission requested for this turn"
            publish(.approval(id: key, kind: "permissions", summary: reason + "\n" + String(decoding: data, as: UTF8.self)))
        case "item/tool/requestUserInput":
            guard let raw = params["questions"] as? [[String: Any]], !raw.isEmpty, raw.count <= 16 else { rejectRequest(id: id); return }
            let questions = raw.compactMap { item -> CodexChatQuestion? in
                guard let id = item["id"] as? String, let text = item["question"] as? String else { return nil }
                let options = (item["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
                return .init(id: id, header: item["header"] as? String ?? "", question: text, options: options, isSecret: item["isSecret"] as? Bool ?? false)
            }
            guard questions.count == raw.count, Set(questions.map(\.id)).count == questions.count else { rejectRequest(id: id); return }
            requests[key] = (encoded, method, questions.map(\.id), nil, requestTurn)
            publish(.input(id: key, questions: questions))
        default:
            try? connection.write(JSONSerialization.data(withJSONObject: ["id": id, "error": ["code": -32601, "message": "Unsupported request"]]))
        }
    }
}

enum CodexChatEnvironment {
    static func child(app: [String: String], executable: ClaudeCodeExecutable, files: ExternalSessionFileSystem = .live) throws -> [String: String] {
        var environment = ClaudeCodeEnvironment.child(app: app, executable: executable)
        if let configured = app["CODEX_HOME"] {
            guard configured.hasPrefix("/"), !configured.contains("\0"),
                  let resolved = files.realpath(configured), let entry = files.lstat(resolved),
                  entry.kind == .directory, entry.owner == files.userID, !entry.othersCanWrite else {
                throw CodexChatSendError.unavailable
            }
            environment["CODEX_HOME"] = resolved
        }
        return environment
    }
}

/// Bounded JSONL transport. stderr, transcript text and prompts never reach logs.
final class CodexStdioConnection: CodexChatConnection, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output: Pipe
    private let lock = NSLock()
    private var closed = false
    private var buffer = Data()
    init(configuration: CodexChatSender.Configuration) throws {
        output = Pipe()
        guard let executable = ClaudeCodeLocator(candidates: configuration.candidates).locate() else { throw CodexChatSendError.unavailable }
        process.executableURL = URL(fileURLWithPath: executable.realPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = try CodexChatEnvironment.child(app: ProcessInfo.processInfo.environment, executable: executable)
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    // Internal pipe initializer exercises the actual JSONL reader without a provider.
    init(output: Pipe) {
        self.output = output
    }
    deinit { close() }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
    func write(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw CodexChatSendError.rejected }
        lock.lock(); defer { lock.unlock() }
        guard !closed, process.isRunning else { throw CodexChatSendError.unavailable }
        var line = data; line.append(10)
        try input.fileHandleForWriting.write(contentsOf: line)
    }
    func read() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= 2 * 1024 * 1024 else { throw CodexChatSendError.unavailable }
                let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if !data.isEmpty { return data }; continue
            }
            guard buffer.count <= 2 * 1024 * 1024 else { throw CodexChatSendError.unavailable }
            lock.lock(); let stopped = closed; lock.unlock()
            guard !stopped else { throw CodexChatSendError.unavailable }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw CodexChatSendError.unavailable }
            if ready == 0 { continue }
            // Foundation read(upToCount:) fills the requested count on a pipe.
            // JSONL responses can be much shorter and the server keeps stdout open,
            // so consume only the currently available bytes with a single POSIX read.
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexChatSendError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}
#endif
