#if os(macOS) && DEBUG
import Darwin
import Foundation
import Synchronization

/// R1 실행 장치 (OA D3a 계약 4.7, Debug 전용 — Release 바이너리에 없다). 실제 `claude`를 Taskforce 서버 없이 adapter로 직접 돌리고,
/// 사건 **종류** · 시간 · 결정 로그 줄만 요약한다 (사용자 글 · 답 · 파일 내용 · 명령 0). 실행은 코디네이터 · 사용자 단계에서만 한다 (시험은 가짜 `claude`만).
/// 작업 폴더는 표식 파일 `.taskforce-disposable`이 있는 일회용 폴더만 받는다
public actor ClaudeCodeEvidenceRunner {
    public enum Step: Sendable {
        /// 새 턴 (첫 턴이면 새 세션)
        case turn(text: String, access: AgentAccess)
        /// 마지막 질문에 답한다
        case answer(AgentAnswerValue)
        /// 마지막 질문을 닫기 모드로 닫는다
        case close
        /// 다음 단계의 턴을 `after` 뒤에 SIGINT로 멈춘다
        case interruptAfter(Duration)
    }

    public struct StepSummary: Codable, Equatable, Sendable {
        public var kind: String
        /// 사건 종류만 (`accepted` · `question:approval` · `failed:sign_in_needed` …)
        public var events: [String]
        public var result: String
        public var milliseconds: Int
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var id: String
        public var steps: [StepSummary]
        /// 값 종류만 있는 로그 줄 (`tool_gate` · `claude_init` · `claude_selfcheck_failed` …)
        public var log: [String]
    }

    /// 값 종류만 모으는 로그 싱크
    final class Lines: BridgeLogSink, Sendable {
        private let storage = Mutex<[String]>([])

        func log(_ event: String, _ fields: [String: BridgeLogValue]) {
            let text = event + " " + fields.sorted { $0.key < $1.key }.map { key, value -> String in
                switch value {
                case .count(let number): "\(key)=\(number)"
                case .id: "\(key)=<id>"
                case .code(let code): "\(key)=\(code)"
                case .status(let status): "\(key)=\(status)"
                case .millis(let millis): "\(key)=\(millis)ms"
                }
            }.joined(separator: " ")
            storage.withLock { $0.append(text) }
        }

        var all: [String] { storage.withLock { $0 } }
    }

    public static let disposableMarker = ".taskforce-disposable"

    let process: ClaudeCodeProcess
    let lines: Lines
    let workspace: String
    let sessionID = UUID().uuidString.lowercased()
    private var providerSession: String?
    private var lastQuestion: AgentQuestion?
    private var lastTask = UUID().uuidString.lowercased()
    private var turn = 0
    private var pendingInterrupt: Duration?

    public struct NotDisposable: Error {}

    /// helper 또는 작업 폴더가 macOS 보호 폴더(Desktop · Documents · Downloads · iCloud Drive · CloudStorage) 안이다 (R1-01 실패 원인). 지킴이는 자기 책임 프로세스라 macOS가 그 이름으로
    /// 폴더 접근을 묻고 답이 올 때까지 막는다 → 첫 보고가 기한을 넘겨 `spawn_failed`. `role`: `workspace` · `hook` · `mcp` · `keeper`, `folder`: 보호 폴더 이름
    public struct ProtectedFolder: Error, CustomStringConvertible {
        public let role: String
        public let folder: String
        public var description: String {
            "\(role) is inside ~/\(folder), which macOS protects: it would ask permission for the disclaimed keeper and block the start. Use a path outside Desktop, Documents, Downloads and iCloud Drive."
        }
    }

    /// macOS가 앱별로 접근을 묻는 홈 아래 폴더 (TCC). 원격 · 이동식 볼륨은 여기서 가르지 않는다
    static let protectedFolders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]

    /// `path`가 `home`의 보호 폴더 안(또는 그 폴더 자체)이면 그 이름. `home`은 실제 경로여야 한다
    static func protectedFolder(containing path: String, home: String) -> String? {
        guard !home.isEmpty else { return nil }
        return protectedFolders.first { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }
    }

    /// 보호 폴더를 가를 홈: 환경의 HOME과 계정 데이터베이스(`getpwuid`)의 홈 (환경이 다른 값이어도 실제 계정의 폴더는 보호된다). 실제 경로로 풀어 중복을 뺀다
    static func homes(environment: [String: String]) -> [String] {
        var found: [String] = []
        let account = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
        for candidate in [environment["HOME"], account] {
            guard let candidate, !candidate.isEmpty else { continue }
            let real = GateFileSystem.realpath(candidate) ?? candidate
            if !found.contains(real) { found.append(real) }
        }
        return found
    }

    /// 한 단계가 끝나기를(`ended`) 기다리는 상한 (R1: 실제 `claude` 턴은 길다)
    let stepTimeout: TimeInterval

    /// `decide`: 서버 대신 쓰는 대본 결정기 (R1-04처럼 실행 중에 바꾸려면 바깥에서 상자로 감싼다).
    /// `timing` · `stepTimeout`: 실제 실행은 기본값(앱 시간 · 600초), 시험은 짧은 상한으로 (18장: 실패가 600초를 기다리지 않게)
    public init(
        workspace: String, sessionsRoot: URL, hookServer: HookSocketServer, helpers: ClaudeCodeHelpers, locator: ClaudeCodeLocator,
        decide: @escaping @Sendable (BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse, environment: [String: String] = ProcessInfo.processInfo.environment,
        timing: ClaudeCodeTiming = .standard, stepTimeout: TimeInterval = 600
    ) throws {
        guard let real = GateFileSystem.realpath(workspace), FileManager.default.fileExists(atPath: real + "/" + Self.disposableMarker) else { throw NotDisposable() }
        let homes = Self.homes(environment: environment)
        for (role, path) in [("workspace", real), ("hook", helpers.hook), ("mcp", helpers.mcp), ("keeper", helpers.keeper)] {
            let resolved = GateFileSystem.realpath(path) ?? path
            if let folder = homes.lazy.compactMap({ Self.protectedFolder(containing: resolved, home: $0) }).first { throw ProtectedFolder(role: role, folder: folder) }
        }
        self.workspace = real
        self.stepTimeout = stepTimeout
        let lines = Lines()
        self.lines = lines
        process = ClaudeCodeProcess(sessionsRoot: sessionsRoot, hookServer: hookServer, helpers: helpers, locator: locator, environment: environment, timing: timing, log: lines)
        process.attach(AgentRuntimeServices(decideTool: decide))
    }

    public func probe() async -> BridgeV1AdapterReport {
        await process.probe()
    }

    public func run(id: String, steps: [Step]) async -> Summary {
        var summaries: [StepSummary] = []
        for step in steps {
            let started = Date()
            let events = Recorder()
            var kind = ""
            var result = ""
            do {
                switch step {
                case .interruptAfter(let delay):
                    pendingInterrupt = delay
                    continue
                case .turn(let text, let access):
                    kind = "turn"
                    turn += 1
                    lastTask = UUID().uuidString.lowercased()
                    let identity = try await process.startTurn(AgentTurnStart(
                        taskID: lastTask, sessionID: sessionID, turnSeq: turn, adapter: ClaudeCodeSupport.adapterID, externalSessionID: providerSession, workspaceRef: workspace,
                        resume: providerSession != nil, access: access, policyMode: .manual, marker: UUID().uuidString.lowercased(), text: text
                    ), events: events.sink)
                    if let delay = pendingInterrupt {
                        pendingInterrupt = nil
                        try? await Task.sleep(for: delay)
                        _ = await process.interrupt(AgentTurnRef(taskID: lastTask, sessionID: sessionID, identity: identity), scope: .turnAndProcesses)
                    }
                    result = "started"
                case .answer(let value):
                    kind = "answer"
                    guard let question = lastQuestion, let providerSession else {
                        result = "no_question"
                        break
                    }
                    let delivery = AgentAnswerDelivery(
                        taskID: lastTask, sessionID: sessionID, turnSeq: turn, adapter: ClaudeCodeSupport.adapterID, externalSessionID: providerSession, workspaceRef: workspace,
                        marker: UUID().uuidString.lowercased(), access: .write, policyMode: .manual, requestID: question.providerRequestID, kind: question.kind,
                        structured: true, value: value
                    )
                    switch try await process.deliverAnswer(delivery, events: events.sink) {
                    case .delivered: result = "delivered"
                    case .requestClosed: result = "request_closed"
                    }
                case .close:
                    kind = "close"
                    guard let question = lastQuestion, let providerSession else {
                        result = "no_question"
                        break
                    }
                    try await process.closeRequest(AgentRequestRef(taskID: lastTask, sessionID: sessionID, requestID: question.providerRequestID, externalSessionID: providerSession, workspaceRef: workspace))
                    result = "closed"
                }
            } catch let error as AgentStartError {
                result = "start_error:\(error.reason.rawValue)"
            } catch {
                result = "error"
            }
            if kind != "close", result == "started" || result == "delivered" {
                _ = await events.waitForEnd(timeout: stepTimeout)
            }
            for event in events.all {
                if case .sessionBound(let external, _) = event { providerSession = external }
                if case .question(let question) = event { lastQuestion = question }
            }
            summaries.append(StepSummary(kind: kind, events: events.all.map(Self.name), result: result, milliseconds: Int(Date().timeIntervalSince(started) * 1000)))
        }
        return Summary(id: id, steps: summaries, log: lines.all)
    }

    /// 사건 종류 이름 (글 0)
    static func name(_ event: AgentEvent) -> String {
        switch event {
        case .sessionBound: "session_bound"
        case .inputReached: "input_reached"
        case .accepted: "accepted"
        case .progress: "progress"
        case .message: "message"
        case .question(let question): "question:\(question.kind.rawValue)"
        case .artifact: "artifact"
        case .turnCompleted: "turn_completed"
        case .failed(let reason): "failed:\(reason?.rawValue ?? "none")"
        case .cancelled: "cancelled"
        case .ended(let exit): "ended:\(exit.code.map(String.init) ?? "-"):\(exit.signal.map(String.init) ?? "-")"
        }
    }

    /// 요약을 JSON으로 쓴다 (`handoffs/oa-d3a-evidence/claude-code-<버전>/`)
    public nonisolated static func write(_ summaries: [Summary], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summaries).write(to: url, options: [.atomic])
    }

    final class Recorder: Sendable {
        private let storage = Mutex<[AgentEvent]>([])

        var sink: AgentEventSink {
            AgentEventSink { [self] event, _ in storage.withLock { $0.append(event) } }
        }

        var all: [AgentEvent] { storage.withLock { $0 } }

        func waitForEnd(timeout: TimeInterval) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if all.contains(where: { if case .ended = $0 { true } else { false } }) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
    }
}
#endif
