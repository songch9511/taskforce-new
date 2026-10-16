#if os(macOS)
import Darwin
import Foundation
import Synchronization
import TaskforceAgentWire
@testable import TaskforceKit

/// D3a 시험의 임시 폴더 하나: 작업 폴더 · 세션 폴더(cwd · config) · 홈 · 짧은 소켓 경로 (실사용 `~/.claude` · Application Support 0)
final class ClaudeSandbox: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let sessionsRoot: URL
    let home: URL
    let outside: URL

    init() {
        let base = URL(fileURLWithPath: Self.real(FileManager.default.temporaryDirectory.path), isDirectory: true)
        root = base.appending(path: "tfcc-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        workspace = root.appending(path: "work", directoryHint: .isDirectory)
        sessionsRoot = root.appending(path: "ledger/claude-code", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        outside = root.appending(path: "outside", directoryHint: .isDirectory)
        for dir in [workspace, sessionsRoot, home, outside] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var workspacePath: String { workspace.path }

    @discardableResult
    func file(_ relative: String, in base: URL? = nil, _ text: String = "x") -> URL {
        let url = (base ?? workspace).appending(path: relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        return url
    }

    func link(_ relative: String, in base: URL? = nil, to target: URL) {
        let url = (base ?? workspace).appending(path: relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
    }

    static func real(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// 지킴이를 거쳐 `claude`처럼 띄운 대본 하나 (OA D3a 13장): 실제로 빌드한 `tf-agent-keeper`가 `/bin/sh -c <대본> sh --settings …/config/<marker>.settings.json`을 띄운다.
/// 혈통 파일은 adapter처럼 띄운 직후 적고, 지킴이는 감독처럼 거둬 그 상태를 혈통에 적는다 (`lineage`). 다시 뜬 앱은 `ClaudeLineage(file:)`로 본다
struct KeptChild {
    let kept: ClaudeKeptSpawn
    let identity: AgentProcessIdentity
    let lineage: ClaudeLineage
    let file: URL

    var keeper: ClaudeLineage.Keeper { ClaudeLineage.Keeper(pid: kept.keeper.pid, uniqueID: kept.keeperID) }

    /// 지킴이가 끝나고 감독 스레드가 거둔 종료 · 보고 줄을 혈통에 적을 때까지 (기한 안에서) 기다린다 (15장 4: 앱이 부모면 끝은 그 둘로만 정해진다)
    func keeperEnded(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while ClaudeProcessInspector.keeperState(keeper) == .alive || lineage.endAfterKeeperGone() == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ClaudeProcessInspector.keeperState(keeper) != .alive
    }
}

extension ClaudeSandbox {
    func keep(_ script: String, marker: String = UUID().uuidString, extra: [String] = []) throws -> KeptChild {
        let settings = root.appending(path: "config/\(marker).settings.json").path
        let file = sessionsRoot.appending(path: "lineage/\(marker).lineage")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let kept = try ClaudeSpawner.spawnKept(
            keeper: try BuiltProducts.url("tf-agent-keeper").path, ended: ClaudeLineage.keeperFile(file), executable: "/bin/sh", argv0: "/bin/sh",
            arguments: ["-c", script, "sh", "--settings", settings] + extra, environment: ["PATH": "/usr/bin:/bin", ClaudeProcessInspector.markerKey: marker], cwd: root.path
        ).get()
        kept.keeper.closeStandardStreams()
        let lineage = ClaudeLineage(file: file, fresh: true)
        lineage.adopt(ClaudeLineage.Record(
            keeper: ClaudeLineage.Keeper(pid: kept.keeper.pid, uniqueID: kept.keeperID), root: kept.claudeID, rootPID: kept.claudePID, attributable: kept.attributable
        ))
        lineage.save()
        let keeper = kept.keeper
        let report = kept.reportFD
        // 앱처럼 지킴이를 거두고 보고를 닫힐 때까지 읽는다 (15장 4: 정상 끝 = 0 종료 ∧ `ended` 줄)
        DispatchQueue.global(qos: .utility).async { lineage.reportClosed(sawEnded: ClaudeCodeProcess.readReport(report) { _ in }) }
        DispatchQueue.global(qos: .utility).async { lineage.keeperExited(keeper.waitForExit()) }
        return KeptChild(
            kept: kept, identity: AgentProcessIdentity(pid: Int(kept.claudePID), startedAt: kept.claudeStartedAt, processMarker: marker), lineage: lineage, file: file
        )
    }
}

/// 오래 막히는 호출(대기 · 프로세스 기다림)을 협력 스레드 밖에서 돌린다 (시험 전체가 동시에 돌 때 다른 시험의 비동기 작업을 굶기지 않게)
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// 시험 클로저가 나눠 쓰는 값 하나 (탈출 클로저가 잡을 수 있는 참조 상자)
final class Shared<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value { lock.withLock { stored } }

    func mutate<T>(_ change: (inout Value) -> T) -> T { lock.withLock { change(&stored) } }
}

/// 서버 결정기 대역: 부른 요청을 모으고 대본대로 답한다
final class ScriptedDecider: @unchecked Sendable {
    private let state = Mutex<(calls: [BridgeV1ToolDecisionQuery], next: [Result<BridgeV1ToolDecisionResponse, AgentToolDecisionError>], delay: Duration)>(([], [], .zero))

    init(_ replies: [Result<BridgeV1ToolDecisionResponse, AgentToolDecisionError>] = [], delay: Duration = .zero) {
        state.withLock {
            $0.next = replies
            $0.delay = delay
        }
    }

    var calls: [BridgeV1ToolDecisionQuery] { state.withLock { $0.calls } }

    func push(_ reply: Result<BridgeV1ToolDecisionResponse, AgentToolDecisionError>) {
        state.withLock { $0.next.append(reply) }
    }

    func setDelay(_ delay: Duration) {
        state.withLock { $0.delay = delay }
    }

    var function: @Sendable (BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse {
        { [self] query in
            let (reply, delay) = state.withLock { value -> (Result<BridgeV1ToolDecisionResponse, AgentToolDecisionError>?, Duration) in
                value.calls.append(query)
                return (value.next.isEmpty ? nil : value.next.removeFirst(), value.delay)
            }
            if delay > .zero { try await Task.sleep(for: delay) }
            guard let reply else { throw AgentToolDecisionError.unavailable }
            return try reply.get()
        }
    }

    static func response(
        _ decision: BridgeV1ToolDecisionValue, _ reason: BridgeV1ToolDecisionReason, parse: BridgeV1ToolDecisionParse? = nil, note: String? = nil, flags: [String] = []
    ) -> BridgeV1ToolDecisionResponse {
        BridgeV1ToolDecisionResponse(decision: decision, reason: reason, parse: parse, agentNote: note, holder: nil, cardFlags: flags, serverTime: Date())
    }
}

/// 사건 싱크 대역 (adapter가 낸 형태 있는 사건을 차례로 모은다)
final class EventLog: @unchecked Sendable {
    private let events = Mutex<[AgentEvent]>([])
    /// 사건을 받기 전에 기다리는 시험 끼어들기 (emit 대기 중 경쟁 시험, 10장 6)
    private let hook = Mutex<(@Sendable (AgentEvent) async -> Void)?>(nil)

    func before(_ body: @escaping @Sendable (AgentEvent) async -> Void) {
        hook.withLock { $0 = body }
    }

    var sink: AgentEventSink {
        AgentEventSink { [self] event, _ in
            if let body = hook.withLock({ $0 }) { await body(event) }
            events.withLock { $0.append(event) }
        }
    }

    var all: [AgentEvent] { events.withLock { $0 } }

    func contains(_ event: AgentEvent) -> Bool { all.contains(event) }

    func count(where predicate: (AgentEvent) -> Bool) -> Int { all.filter(predicate).count }

    var questions: [AgentQuestion] {
        all.compactMap { if case .question(let question) = $0 { question } else { nil } }
    }

    var ended: AgentExit? {
        for event in all.reversed() { if case .ended(let exit) = event { return exit } }
        return nil
    }

    /// 조건이 맞을 때까지 실제 시간으로 기다린다
    @discardableResult
    func wait(timeout: TimeInterval = 15, _ condition: ([AgentEvent]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(all) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(all)
    }
}

enum ClaudeTest {
    static let session = "5e551011-0000-4000-8000-000000000001"
    static let task = "7a5c0001-0000-4000-8000-000000000001"

    static func request(_ tool: String, _ input: WireJSON, id: String = "toolu_1", mode: String = "default", cwd: String, nonce: String = "n") -> HookRequest {
        HookRequest(
            nonce: nonce, sessionID: session, providerSessionID: nil, hookEvent: "PreToolUse", toolUseID: id, toolName: tool,
            toolInput: HookWire.strippedInput(toolName: tool, input: input), inputSHA256: HookWire.inputDigest(input), permissionMode: mode, cwd: cwd
        )
    }

    static func json(_ text: String) -> WireJSON {
        (try? WireJSON.parse(Data(text.utf8))) ?? .null
    }

    /// 픽스처 줄 (`Fixtures/claude-code-2.1.241/<name>.jsonl`)
    static func fixture(_ name: String) throws -> [Data] {
        guard let url = Bundle.module.url(forResource: "claude-code-2.1.241/\(name)", withExtension: "jsonl") else { throw CocoaError(.fileNoSuchFile) }
        return try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
    }

    /// 픽스처의 모든 `tool_use` id → 도구 이름 (bridge가 그 id에 답했다고 가정할 때 쓴다)
    static func toolUses(in lines: [Data]) -> [String: String] {
        var names: [String: String] = [:]
        for line in lines {
            guard case .assistant(let message)? = ClaudeStreamParser.parse(line) else { continue }
            for case .toolUse(let id, let name, _) in message.blocks { names[id] = name }
        }
        return names
    }
}

/// SwiftPM이 시험 의존으로 빌드한 실행 파일 (helper 둘 · 가짜 claude)
enum BuiltProducts {
    struct Missing: Error {}

    static func url(_ name: String) throws -> URL {
        for index in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(index) else { continue }
            let path = String(cString: raw)
            guard let range = path.range(of: ".xctest/") else { continue }
            let folder = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".xctest").deletingLastPathComponent()
            let candidate = folder.appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw Missing()
    }
}
#endif
