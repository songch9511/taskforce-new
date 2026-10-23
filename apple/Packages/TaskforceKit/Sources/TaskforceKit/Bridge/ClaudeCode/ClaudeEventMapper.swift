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
    /// Edit · Write: 보류할 때 해석한 대상의 지문 (`ClaudeTargetFingerprint`, 8장 2). 재개 때 같아야 한다
    public var targetSHA256: String?

    public init(id: String, kind: BridgeV1PendingQuestionKind, inputSHA256: String, toolName: String, question: AgentQuestion, targetSHA256: String? = nil) {
        self.id = id
        self.kind = kind
        self.inputSHA256 = inputSHA256
        self.toolName = toolName
        self.question = question
        self.targetSHA256 = targetSHA256
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

/// ④의 예외 (R1-02 · R1-03): 훅 답 없이 온 **오류** 결과인데 아무것도 실행되지 않았다고 볼 수 있는 둘. 로그에는 이 고정 코드만 남긴다 (글 0)
public enum ClaudeToolRefusal: String, Equatable, Sendable {
    /// Read · Glob · Grep · Edit · Write: CLI가 훅 앞에서 입력을 검증해 거절했다 (예: 읽기 전에 쓰기). 오류 결과면 실행도 쓰기도 없었다
    case cliValidated = "cli_validated"
    /// init `tools`에 없는 도구: CLI가 "없는 도구"로 거절했다 (읽기 전용 등급의 Edit 등)
    case notAdvertised = "not_advertised"
}

public enum ClaudeMapperAction: Equatable, Sendable {
    case emit(AgentEvent)
    /// 훅 답 없는 오류 결과를 ④ 실패로 보지 않고 넘겼다 (모델이 오류를 보고 이어 간다). `hookStarted`: 그 호출에 훅 시작 사건이 있었다 (훅이 돌다 답 없이 끝난 호출)
    case toolRefusedBeforeHook(ClaudeToolRefusal, hookStarted: Bool)
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
    /// 백그라운드 일의 사건 (로컬 전용: 서버로 가지 않는다. 이름은 모델이 쓴 description만)
    case backgroundTask(BackgroundTaskEvent)
}

/// stream-json 사건 → 형태 있는 사건 + 자체 점검 ②③④⑥ (순수, I/O 0). 처음 `result` 뒤의 사건은 무시한다 (비어 있지 않은 resume가 턴을 하나 더 돌린 r2-cc2mcp-2).
/// 단 하나의 예외: 처음 `result` 뒤에도 CLI는 백그라운드 일이 끝날 때까지 `task_*` · `background_tasks_changed`를 낸다 (실측 2.1.308). 그 줄들은 **이 Mac의 판에만** 가는 사건(`backgroundTask`)이라 계속 반영한다
public struct ClaudeEventMapper: Sendable {
    public let config: ClaudeMapperConfig
    private var sessionStartOK = false
    private var accepted: Bool
    public private(set) var terminal = false
    /// 끝난 까닭이 `result`다 (자체 점검 실패 · 닫기로 멈춘 것이 아니다): 이때만 뒤의 task 줄을 판에 반영한다
    private var endedByResult = false
    private var interruptRequested = false
    private var authFailed = false
    private var rateLimited = false
    private var lastProgress: Date?
    private var text: (messageID: String?, value: String)?
    private var hookStarted: [String: Int] = [:]
    /// init이 알린 도구 집합 (④ 예외: 없는 도구의 거절). init을 보기 전이거나 init이 목록을 주지 않았으면 nil — "아무것도 광고되지 않음"과 다르다
    private var advertisedTools: Set<String>?
    /// 결과를 아직 받지 못한 tool_use (id → 도구 이름). 훅 시작 계수가 이 호출들의 것인지 가를 때 쓴다
    private var outstanding: [String: String] = [:]
    /// 넘긴 거절 수 (한 spawn). 상한을 넘으면 ④로 막는다
    private var tolerated = 0
    /// 거절로 넘기는 오류 결과의 spawn당 상한: 거절 오류로 파일 · 도구의 존재를 더듬는 것을 막는다
    static let toleratedRefusals = 5
    private var toolUseNames: [String: String] = [:]
    private var toolUseFiles: [String: String] = [:]
    /// 도구 호출 id → 모델이 쓴 `input.description` (백그라운드 일의 이름을 확인한다: 명령 글은 이름이 아니다). 한 spawn에서 `maxToolDescriptions`개까지
    private var toolDescriptions: [String: String] = [:]
    static let maxToolDescriptions = 512
    /// 앞에서 돌던 명령(`is_backgrounded == false`)의 일 id: 그 알림 · 갱신은 백그라운드 일이 아니라 무시한다
    private var foregroundTasks: Set<String> = []
    static let maxForegroundTasks = 256
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

    /// 보고된 보류를 열린 요청으로 적지 못했다 (상태 저장 실패, 8장 17): 답할 수 없는 질문은 끝에 내지 않는다
    public mutating func dropConfirmedQuestion() {
        confirmed = nil
    }

    public mutating func consume(_ event: ClaudeStreamEvent, facts: ClaudeSpawnFacts, now: Date) -> [ClaudeMapperAction] {
        guard !terminal else {
            // 서버로 가는 사건 · 진행 신호 · 자체 점검은 끝났다. 판에만 가는 일의 줄은 계속 반영한다
            guard endedByResult, case .task(let payload?) = event else { return [] }
            return backgroundActions(payload, now: now)
        }
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
            advertisedTools = info.tools.isEmpty ? nil : Set(info.tools)
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
            for (id, description) in info.toolDescriptions where toolDescriptions.count < Self.maxToolDescriptions || toolDescriptions[id] != nil { toolDescriptions[id] = description }
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
                    outstanding[id] = name
                    if let filePath { toolUseFiles[id] = filePath }
                    out += progress(now)
                case .thinking, .other:
                    break
                }
            }
        case .toolResults(let results):
            out += flushText()
            for result in results {
                let known = toolUseNames[result.toolUseID] ?? facts.toolNames[result.toolUseID]
                // 이 호출 말고 같은 도구로 결과를 기다리는 호출 수 (훅 시작 계수 중 이 호출 몫을 가를 때)
                let others = outstanding.filter { $0.key != result.toolUseID && $0.value == known }.count
                outstanding[result.toolUseID] = nil
                // ④의 예외: 훅 답이 **없는 오류** 결과인데 아무것도 실행되지 않았다고 볼 수 있다 (CLI가 훅 앞에서 입력을 검증해 거절한 것, R1-02 · R1-03).
                // 성공 결과나 그 밖 도구의 오류 결과는 훅을 건너뛴 실행일 수 있으므로 아래 ④가 그대로 막는다. 상한을 넘은 거절도 막는다
                if !facts.answered.contains(result.toolUseID), let known, let refusal = refusalBeforeHook(tool: known, isError: result.isError) {
                    guard tolerated < Self.toleratedRefusals else { return out + fail(4) }
                    tolerated += 1
                    // 훅이 시작됐으나 답 없이 끝난 호출이면 그 시작을 계수에서 뺀다 (남기면 뒤의 "답은 있으나 훅 시작이 없는" 결과가 그 계수로 ④를 통과한다).
                    // 같은 도구의 다른 호출이 결과를 기다리고 있으면 그 시작이 누구 것인지 알 수 없어 그 호출 몫만큼은 남긴다
                    var leaked = false
                    if let started = hookStarted[known], started > others {
                        hookStarted[known] = started - 1
                        leaked = true
                    }
                    out.append(.toolRefusedBeforeHook(refusal, hookStarted: leaked))
                    continue
                }
                // ④: 이 프로세스에서 그 결과보다 먼저 `hook_started PreToolUse:<tool>`이 있었고 bridge가 그 id에 소켓 답을 줬다
                guard facts.answered.contains(result.toolUseID), let name = known, let started = hookStarted[name], started > 0 else {
                    return out + fail(4)
                }
                hookStarted[name] = started - 1
                if !result.isError, name == "Edit" || name == "Write", let file = facts.filePaths[result.toolUseID] ?? toolUseFiles[result.toolUseID] {
                    artifacts.removeAll { $0.filePath == file }
                    artifacts.append(ClaudeArtifactCandidate(tool: name, filePath: file))
                }
            }
            out += progress(now)
        case .task(let payload):
            // 시작 · 알림은 전처럼 진행 신호로 센다 (모양이 틀린 것도). 그 밖의 task 줄(진행 · 갱신 · 목록)은 전처럼 진행 신호가 아니다
            switch payload {
            case .started?, .notification?, nil: out += progress(now)
            default: break
            }
            if let payload { out += backgroundActions(payload, now: now) }
        case .rateLimit(let status):
            if let status, status != "allowed" { rateLimited = true }
        case .result(let info):
            out += flushText() + flushArtifacts()
            out.append(.resultSeen)
            terminal = true
            endedByResult = true
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

    /// CLI가 입력 검증으로 거절한 오류 결과인가. init `tools`에 없는 도구가 먼저, 아니면 CLI가 훅 앞에서 검증하는 파일 도구 다섯. 성공 결과는 어느 쪽도 아니다
    private func refusalBeforeHook(tool: String, isError: Bool) -> ClaudeToolRefusal? {
        // Bash는 어떤 경우에도 예외가 아니다 (광고되지 않아도): 훅이 판정하는 도구이고, 훅을 건너뛴 셸 실행을 가리지 않는다
        guard isError, tool != "Bash" else { return nil }
        if let advertisedTools, !advertisedTools.contains(tool) { return .notAdvertised }
        return Self.validatedBeforeHook.contains(tool) ? .cliValidated : nil
    }

    private static let validatedBeforeHook: Set<String> = ["Read", "Glob", "Grep", "Edit", "Write"]

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

    // MARK: 백그라운드 일 (로컬 전용: 서버로 가는 사건이 아니다)

    private static func kind(taskType: String?, tool: String?, names: [String: String]) -> BackgroundTaskKind {
        switch taskType {
        case "local_bash": return .command
        case "local_agent": return .agent
        default: break
        }
        switch tool.flatMap({ names[$0] }) {
        case "Bash": return .command
        case "Agent", "Task": return .agent
        default: return .other
        }
    }

    /// 이름: **모델이 쓴 글만**. CLI는 모델이 안 쓰면 명령 글 자체를 description 자리에 주므로, 그 도구 호출의 `input.description`(모델이 쓴 글)과 같다고 확인될 때만 이름으로 쓴다.
    /// 에이전트도 같다 (보안 P3-6: 모델이 늘 쓴다는 보장에 기대지 않는다. 프롬프트가 그 자리에 오면 이름이 아니다). 확인할 수 없으면 nil (화면은 도구 이름을 보인다)
    private func vettedName(_ description: String?, tool: String?, kind: BackgroundTaskKind) -> String? {
        guard let description, !description.isEmpty else { return nil }
        guard let tool, let written = toolDescriptions[tool], written == description else { return nil }
        return description
    }

    private static func finishedStatus(_ word: String) -> BackgroundTaskStatus? {
        switch word {
        case "completed": .done
        case "failed": .failed
        case "stopped", "killed", "cancelled", "canceled": .stopped
        default: nil
        }
    }

    private mutating func backgroundActions(_ event: ClaudeTaskStreamEvent, now: Date) -> [ClaudeMapperAction] {
        switch event {
        case .started(let id, let tool, let type, let description, let backgrounded, let parent, let depth):
            // 앞에서 도는 명령은 백그라운드 일이 아니라 무시한다. **앞에서 도는 에이전트(`local_agent`)는 판에 올린다** (트리의 중첩 자식): 스냅샷이 멈추지 않도록 `foreground`를 단다
            if backgrounded == false, type != "local_agent" {
                if foregroundTasks.count < Self.maxForegroundTasks { foregroundTasks.insert(id) }
                return []
            }
            let kind = Self.kind(taskType: type, tool: tool, names: toolUseNames)
            return [.backgroundTask(.started(
                taskID: id, toolUseID: tool, kind: kind, name: vettedName(description, tool: tool, kind: kind), at: now, parentID: parent, depth: depth, foreground: backgrounded == false
            ))]
        case .progress:
            return []
        case .updated(let id, let status, let endMillis):
            guard !foregroundTasks.contains(id), let status, let finished = Self.finishedStatus(status) else { return [] }
            let end = endMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now
            return [.backgroundTask(.finished(taskID: id, kind: nil, status: finished, exitCode: nil, at: end))]
        case .notification(let id, _, let status, let exitCode, let kind):
            guard !foregroundTasks.contains(id) else { return [] }
            let finished = BackgroundTaskText.status(status ?? "")
            return [.backgroundTask(.finished(taskID: id, kind: kind, status: finished, exitCode: finished == .stopped ? nil : exitCode, at: now))]
        case .changed(let tasks):
            var out: [ClaudeMapperAction] = []
            var running: [String] = []
            for task in tasks where !foregroundTasks.contains(task.taskID) {
                let kind = Self.kind(taskType: task.taskType, tool: nil, names: toolUseNames)
                out.append(.backgroundTask(.started(taskID: task.taskID, toolUseID: nil, kind: kind, name: vettedName(task.description, tool: nil, kind: kind), at: now)))
                running.append(task.taskID)
            }
            out.append(.backgroundTask(.snapshot(runningTaskIDs: running)))
            return out
        }
    }

    /// 2초에 하나로 묶는다
    private mutating func progress(_ now: Date) -> [ClaudeMapperAction] {
        if let last = lastProgress, now.timeIntervalSince(last) < 2 { return [] }
        lastProgress = now
        return [.emit(.progress)]
    }
}
#endif
