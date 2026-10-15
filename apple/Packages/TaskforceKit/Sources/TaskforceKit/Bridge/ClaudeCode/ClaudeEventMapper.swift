#if os(macOS)
import Foundation
import TaskforceAgentWire

/// 한 spawn의 매핑 설정 (OA D3a 계약 2.8 · 2.9)
public struct ClaudeMapperConfig: Sendable {
    public enum Mode: Sendable, Equatable {
        /// 새 턴 (메시지). `newSessionID`가 있으면 init이 그 id를 돌려줄 때 `session_bound`
        case turn(newSessionID: String?)
        /// 답 resume: 보류 id의 훅이 init보다 먼저 와야 한다. 접수를 다시 내지 않는다
        case answer(requestID: String)
        /// 닫기 resume: 사건 0, 닫는 id의 결과(또는 그 훅 없이 온 첫 사건)에서 SIGINT
        case close(requestID: String)
    }

    public var mode: Mode
    /// init `session_id`가 이것이어야 한다 (nil이면 보지 않는다 — 픽스처 시험 전용)
    public var expectedSessionID: String?
    /// init `tools` 집합 + `tf` 연결 (nil이면 보지 않는다 — `--tools` 없이 돈 S0 run 2 픽스처 전용)
    public var expectedTools: Set<String>?
    /// init `cwd` = 세션 `cwd/` realpath (nil이면 보지 않는다 — 픽스처 전용)
    public var expectedCwd: String?
    /// ③ SessionStart 표식이 init 전에 있어야 한다 (S0 run 2 픽스처만 false)
    public var requireSessionStart: Bool
    public var workspaceRealPath: String
    public var versionSupported: @Sendable (String?) -> Bool

    public init(
        mode: Mode, expectedSessionID: String?, expectedTools: Set<String>?, expectedCwd: String?, requireSessionStart: Bool, workspaceRealPath: String,
        versionSupported: @escaping @Sendable (String?) -> Bool
    ) {
        self.mode = mode
        self.expectedSessionID = expectedSessionID
        self.expectedTools = expectedTools
        self.expectedCwd = expectedCwd
        self.requireSessionStart = requireSessionStart
        self.workspaceRealPath = workspaceRealPath
        self.versionSupported = versionSupported
    }
}

/// bridge(결정기)가 이 spawn에 대해 아는 사실 (소켓으로 받은 훅 요청에서)
public struct ClaudeSpawnFacts: Sendable {
    /// bridge가 소켓으로 답을 준 tool_use id (④)
    public var answered: Set<String> = []
    /// 훅 요청에서 본 id → 도구 이름 (앞 프로세스에서 나온 보류 id도)
    public var toolNames: [String: String] = [:]
    /// 훅 요청에서 본 Edit · Write 대상 경로
    public var filePaths: [String: String] = [:]
    /// 이 spawn에서 결정기가 기록한 보류
    public var pending: ClaudePendingDeferred?

    public init() {}
}

/// 보류 하나 (결정기가 L8 · P5에서 기록). 질문 글은 메모리에만 있다 (상태 파일에는 id · 종류 · digest만)
public struct ClaudePendingDeferred: Equatable, Sendable {
    public var id: String
    public var kind: BridgeV1PendingQuestionKind
    public var inputSHA256: String
    public var toolName: String
    public var question: AgentQuestion

    public init(id: String, kind: BridgeV1PendingQuestionKind, inputSHA256: String, toolName: String, question: AgentQuestion) {
        self.id = id
        self.kind = kind
        self.inputSHA256 = inputSHA256
        self.toolName = toolName
        self.question = question
    }
}

public struct ClaudeArtifactCandidate: Equatable, Sendable {
    public var tool: String
    public var filePath: String

    public init(tool: String, filePath: String) {
        self.tool = tool
        self.filePath = filePath
    }
}

public enum ClaudeInterruptCause: Equatable, Sendable {
    /// 자체 점검 ②–⑥ 실패
    case selfCheck(Int)
    /// 닫기 모드가 할 일을 마쳤다
    case closeDone
    /// 답 resume에서 보류 id의 훅보다 init이 먼저 왔다 (상태 유실)
    case answerLost
}

public enum ClaudeMapperAction: Equatable, Sendable {
    case emit(AgentEvent)
    /// SIGINT를 보낸다
    case interrupt(ClaudeInterruptCause)
    /// `result.deferred_tool_use`가 기록한 보류를 보고했다: 상태 파일에 적는다 (질문 사건은 프로세스가 끝날 때 낸다)
    case confirmQuestion(ClaudePendingDeferred)
    /// 기록에 없는 id가 보고됐다 (일어나면 안 됨): 그 id를 닫기 모드로 닫는다
    case unexpectedDeferred(String)
    /// 턴의 Edit · Write 결과 (같은 경로는 마지막 하나). 프로세스가 작업 폴더 기준 상대 경로 · 해시를 붙여 낸다
    case artifacts([ClaudeArtifactCandidate])
    /// 로그인 없음으로 끝났다: probe 로그인 캐시를 버린다
    case signInNeeded
    /// init을 봤다 (로그: 걸린 시간 · plugins · skills · 메시지 소켓 유무)
    case initSeen(ClaudeInitInfo)
    /// result를 봤다 (프로세스가 곧 끝나야 한다)
    case resultSeen
}

/// stream-json 사건 → 형태 있는 사건 + 자체 점검 ②③④⑥ (순수, I/O 0). 처음 `result` 뒤의 사건은 무시한다 (비어 있지 않은 resume가 턴을 하나 더 돌린 r2-cc2mcp-2)
public struct ClaudeEventMapper: Sendable {
    public let config: ClaudeMapperConfig
    private var sessionStartOK = false
    private var accepted: Bool
    public private(set) var terminal = false
    private var interruptRequested = false
    private var authFailed = false
    private var rateLimited = false
    private var lastProgress: Date?
    private var text: (messageID: String?, value: String)?
    private var hookStarted: [String: Int] = [:]
    private var toolUseNames: [String: String] = [:]
    private var toolUseFiles: [String: String] = [:]
    private var artifacts: [ClaudeArtifactCandidate] = []
    private var confirmed: ClaudePendingDeferred?

    public init(config: ClaudeMapperConfig) {
        self.config = config
        if case .turn = config.mode { accepted = false } else { accepted = true }
    }

    /// 우리가 사용자 Stop으로 SIGINT를 보냈다 (`aborted_tools` 결과를 `cancelled`로 본다)
    public mutating func markInterruptRequested() {
        interruptRequested = true
    }

    public var wasAccepted: Bool { accepted }

    public mutating func consume(_ event: ClaudeStreamEvent, facts: ClaudeSpawnFacts, now: Date) -> [ClaudeMapperAction] {
        guard !terminal else { return [] }
        if case .close(let requestID) = config.mode { return consumeClosing(event, requestID: requestID) }
        var out: [ClaudeMapperAction] = []
        switch event {
        case .hookStarted(let name, let hookEvent):
            if hookEvent == "PreToolUse", name.hasPrefix("PreToolUse:") { hookStarted[String(name.dropFirst("PreToolUse:".count)), default: 0] += 1 }
        case .hookResponse(let name, let hookEvent, let exitCode, let markerSeen):
            if hookEvent == "SessionStart", name == "SessionStart:startup" || name == "SessionStart:resume", exitCode == 0, markerSeen { sessionStartOK = true }
        case .systemInit(let info):
            out += flushText()
            out.append(.initSeen(info))
            if case .answer(let requestID) = config.mode, !facts.answered.contains(requestID) {
                terminal = true
                return out + [.interrupt(.answerLost)]
            }
            if case .turn(let newSessionID) = config.mode {
                out.append(.emit(.inputReached))
                if let newSessionID, info.sessionID == newSessionID {
                    out.append(.emit(.sessionBound(externalSessionID: newSessionID, workspaceRef: config.workspaceRealPath)))
                }
            }
            if let failure = initFailure(info) { return out + fail(failure.check, versionOutOfRange: failure.version) }
            if config.requireSessionStart, !sessionStartOK { return out + fail(3) }
        case .assistant(let info):
            guard info.isGenuine else {
                if info.error != nil || info.model == "<synthetic>" { authFailed = authFailed || info.error == "authentication_failed" }
                return out
            }
            if !accepted {
                accepted = true
                out.append(.emit(.accepted))
            }
            for block in info.blocks {
                switch block {
                case .text(let value):
                    if let current = text, current.messageID == info.messageID {
                        text = (current.messageID, current.value + value)
                    } else {
                        out += flushText()
                        text = (info.messageID, value)
                    }
                case .toolUse(let id, let name, let filePath):
                    out += flushText()
                    toolUseNames[id] = name
                    if let filePath { toolUseFiles[id] = filePath }
                    out += progress(now)
                case .thinking, .other:
                    break
                }
            }
        case .toolResults(let results):
            out += flushText()
            for result in results {
                // ④: 이 프로세스에서 그 결과보다 먼저 `hook_started PreToolUse:<tool>`이 있었고 bridge가 그 id에 소켓 답을 줬다
                guard facts.answered.contains(result.toolUseID), let name = toolUseNames[result.toolUseID] ?? facts.toolNames[result.toolUseID],
                      let started = hookStarted[name], started > 0 else {
                    return out + fail(4)
                }
                hookStarted[name] = started - 1
                if !result.isError, name == "Edit" || name == "Write", let file = facts.filePaths[result.toolUseID] ?? toolUseFiles[result.toolUseID] {
                    artifacts.removeAll { $0.filePath == file }
                    artifacts.append(ClaudeArtifactCandidate(tool: name, filePath: file))
                }
            }
            out += progress(now)
        case .task:
            out += progress(now)
        case .rateLimit(let status):
            if let status, status != "allowed" { rateLimited = true }
        case .result(let info):
            out += flushText() + flushArtifacts()
            out.append(.resultSeen)
            terminal = true
            if info.isDeferred {
                if let id = info.deferredToolUseID, let pending = facts.pending, pending.id == id {
                    confirmed = pending
                    out.append(.confirmQuestion(pending))
                } else {
                    out += [.unexpectedDeferred(info.deferredToolUseID ?? ""), .emit(.failed(.agentError))]
                }
            } else if !info.isError, info.subtype == "success" {
                out.append(.emit(.turnCompleted))
            } else if info.isError, info.terminalReason == "api_error", authFailed {
                out += [.signInNeeded, .emit(.failed(.signInNeeded))]
            } else if info.subtype == "error_during_execution", info.terminalReason == "aborted_tools", interruptRequested {
                out.append(.emit(.cancelled))
            } else if rateLimited {
                out.append(.emit(.failed(.usageLimited)))
            } else {
                out.append(.emit(.failed(accepted ? .agentError : .spawnFailed)))
            }
        case .other:
            break
        }
        return out
    }

    /// ⑥ stdout 한 줄이 상한을 넘었다
    public mutating func oversizedLine() -> [ClaudeMapperAction] {
        guard !terminal else { return [] }
        if case .close = config.mode {
            terminal = true
            return [.interrupt(.closeDone)]
        }
        return fail(6)
    }

    /// 프로세스가 끝났다: 남은 글 · 산출물을 내고, 보고된 보류가 있으면 이제 질문을 낸다 (프로세스가 끝난 뒤에 답이 와야 writer가 하나다)
    public mutating func finish() -> [ClaudeMapperAction] {
        var out: [ClaudeMapperAction] = []
        if case .close = config.mode {
            terminal = true
            return out
        }
        if !terminal { out += flushText() + flushArtifacts() }
        if let confirmed {
            out.append(.emit(.question(confirmed.question)))
            self.confirmed = nil
        }
        terminal = true
        return out
    }

    // MARK: 닫기 모드

    private mutating func consumeClosing(_ event: ClaudeStreamEvent, requestID: String) -> [ClaudeMapperAction] {
        switch event {
        case .toolResults(let results) where results.contains(where: { $0.toolUseID == requestID }):
            terminal = true
            return [.interrupt(.closeDone)]
        case .systemInit, .assistant, .result, .toolResults:
            // 닫는 id의 결과 전에 다른 일이 시작됐다 (이미 닫혔거나 상태 유실): 바로 멈춘다
            terminal = true
            return [.interrupt(.closeDone)]
        default:
            return []
        }
    }

    // MARK: 도우미

    private func initFailure(_ info: ClaudeInitInfo) -> (check: Int, version: Bool)? {
        if !config.versionSupported(info.version) { return (2, true) }
        if info.permissionMode != "default" { return (2, false) }
        if let tools = config.expectedTools, Set(info.tools) != tools || info.mcpServers[AskUserSchema.serverName] != "connected" { return (2, false) }
        if let cwd = config.expectedCwd, info.cwd != cwd { return (2, false) }
        if let session = config.expectedSessionID, info.sessionID != session { return (2, false) }
        return nil
    }

    private mutating func fail(_ check: Int, versionOutOfRange: Bool = false) -> [ClaudeMapperAction] {
        let flushed = flushText() + flushArtifacts()
        terminal = true
        let reason: BridgeV1FailureReason
        switch check {
        case 4, 6: reason = .agentError
        default: reason = accepted ? .agentError : (versionOutOfRange ? .versionUnsupported : .spawnFailed)
        }
        return flushed + [.interrupt(.selfCheck(check)), .emit(.failed(reason))]
    }

    private mutating func flushText() -> [ClaudeMapperAction] {
        guard let current = text else { return [] }
        text = nil
        return current.value.isEmpty ? [] : [.emit(.message(text: current.value))]
    }

    private mutating func flushArtifacts() -> [ClaudeMapperAction] {
        guard !artifacts.isEmpty else { return [] }
        defer { artifacts = [] }
        return [.artifacts(artifacts)]
    }

    /// 2초에 하나로 묶는다
    private mutating func progress(_ now: Date) -> [ClaudeMapperAction] {
        if let last = lastProgress, now.timeIntervalSince(last) < 2 { return [] }
        lastProgress = now
        return [.emit(.progress)]
    }
}
#endif
