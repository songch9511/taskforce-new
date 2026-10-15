#if os(macOS)
import Foundation
import Synchronization
import TaskforceAgentWire

/// 훅 요청 한 건을 정하는 데 필요한 spawn의 사실 (OA D3a 계약 2.7)
public struct ClaudeGateContext: Sendable {
    public enum Mode: Sendable, Equatable {
        case normal
        /// 답 resume: 보류 id에 답을 한 번 준다
        case answer(ClaudeAnswerBinding)
        /// 닫기 resume: 모든 호출 deny
        case close(requestID: String)
    }

    public var mode: Mode
    public var access: AgentAccess
    public var workspaceRealPath: String
    /// 세션 `cwd/` realpath (Read · Glob · Grep이 볼 수 있는 두 번째 폴더. `config/`는 밖이다)
    public var sessionCwdRealPath: String
    /// 자식에게 넘긴 PATH (13.4.1-1 ①)
    public var childPATH: String
    public var agentSessionID: String
    public var agentTaskID: String
    public var turnSeq: Int
    /// 이 spawn에서 이미 defer를 한 번 냈다 (L6)
    public var deferIssued: Bool
    /// 답 모드: 보류 id에 이미 답을 줬다 (비밀값은 한 번만)
    public var answerDelivered: Bool
    /// 이 spawn에 중단 신호를 보냈거나 자체 점검이 실패했다: 모든 요청 deny (8장 9)
    public var stopped: Bool
    /// 이 spawn에 건넨 비밀값 (밖으로 나가는 명령 · 경로 · 승인 글에서 가린다, 8장 11)
    public var secrets: SecretRedactor

    public init(
        mode: Mode, access: AgentAccess, workspaceRealPath: String, sessionCwdRealPath: String, childPATH: String, agentSessionID: String, agentTaskID: String,
        turnSeq: Int, deferIssued: Bool, answerDelivered: Bool, stopped: Bool = false, secrets: SecretRedactor = SecretRedactor()
    ) {
        self.mode = mode
        self.access = access
        self.workspaceRealPath = workspaceRealPath
        self.sessionCwdRealPath = sessionCwdRealPath
        self.childPATH = childPATH
        self.agentSessionID = agentSessionID
        self.agentTaskID = agentTaskID
        self.turnSeq = turnSeq
        self.deferIssued = deferIssued
        self.answerDelivered = answerDelivered
        self.stopped = stopped
        self.secrets = secrets
    }
}

/// 답 모드 nonce에 메모리로만 묶인 답 (비밀값도 여기만 거친다, 계약 2.11)
public struct ClaudeAnswerBinding: Sendable, Equatable {
    public var requestID: String
    public var kind: BridgeV1PendingQuestionKind
    /// 보류 때 입력 digest (상태 파일). 다르면 deny (G16)
    public var inputSHA256: String?
    public var value: AgentAnswerValue
    /// 보류 때 해석한 Edit · Write 대상의 지문 (상태 파일). 다르면 deny `target_changed` (8장 2)
    public var targetSHA256: String?

    public init(requestID: String, kind: BridgeV1PendingQuestionKind, inputSHA256: String?, value: AgentAnswerValue, targetSHA256: String? = nil) {
        self.requestID = requestID
        self.kind = kind
        self.inputSHA256 = inputSHA256
        self.value = value
        self.targetSHA256 = targetSHA256
    }
}

public struct ClaudeGateOutcome: Sendable, Equatable {
    public enum Source: String, Sendable {
        case local
        case server
    }

    public var response: HookResponse
    public var source: Source
    /// 로그 이유 코드 (값 종류만, 명령 · 경로 · 글 0)
    public var code: String
    /// L8 · P5 · P1: 기록할 보류
    public var deferred: ClaudePendingDeferred?
    /// L3: 보류 id에 답을 줬다
    public var answeredPending = false
    /// L4 · 입력이 바뀐 답: 이 spawn을 멈춘다
    public var abortSpawn = false
}

/// 모델에게 가는 이유 (영어 상수. 사용자 글 · 명령 · 경로를 담지 않는다)
public enum ClaudeGateReason {
    public static let closedRequest = "The user stopped this task. Do not ask again."
    public static let turnStopped = "This turn was stopped."
    public static let permissionMode = "Only the default permission mode is supported."
    public static let inputChanged = "This request changed while it waited for the user, so it was not run."
    public static let answered = "Answered by the user."
    public static let approved = "Approved by the user."
    public static let declined = "The user declined this action. Do not retry it."
    public static let toolNotAllowed = "This tool is not available in Taskforce runs. Do not use it."
    public static let readOnly = "This agent is read-only. Do not run this tool."
    public static let oneAtATime = "Wait for the answer to your earlier request."
    public static let inside = "Inside the workspace."
    public static let outsidePath = "This path is outside the workspace."
    public static let outsideFile = "This file is outside the workspace."
    public static let background = "Background commands are not allowed."
    public static let sandboxDisabled = "Disabling the sandbox is not allowed."
    public static let waitingAnswer = "Waiting for the user's answer."
    public static let waitingApproval = "Waiting for the user's approval."
    public static let readOnlyCommand = "Read-only command."
    public static let policy = "Allowed by Taskforce policy."
    public static let policyDenied = "Not allowed by Taskforce policy."
    public static let accessDisabled = "Tool access is disabled. Do not retry this tool."
    public static let questionsTooLarge = "ask_user was not sent: The questions are too long. Shorten them and try again."
    public static let unreadable = HookReason.unreadable
    public static let targetChanged = "The file changed while this request waited for the user, so it was not run."
    public static let unknownInput = "This tool input has fields Taskforce does not support. Retry with only the standard fields."
    public static let patternNotAllowed = "Use a pattern without '..' or braces."
}

/// 결정표 (OA D3a 계약 2.7): 위에서 처음 맞는 행. L = 로컬(서버 호출 0), S = 서버, P = 서버 응답 뒤 로컬.
/// **판정은 서버다:** Bash · Edit · Write는 서버 판정 없이 자동 허용하지 않는다. 로컬 행은 계약이 정한 정적 행과 파일 시스템 사실뿐이다
public struct ClaudeToolGate: Sendable {
    public var fileSystem: GateFileSystem
    public var decide: (@Sendable (BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse)?
    /// 서버 왕복 예산 (D3c-2 3.5): 넘으면 로컬 defer
    public var serverTimeout: Duration

    public init(fileSystem: GateFileSystem, decide: (@Sendable (BridgeV1ToolDecisionQuery) async throws -> BridgeV1ToolDecisionResponse)?, serverTimeout: Duration = .seconds(1)) {
        self.fileSystem = fileSystem
        self.decide = decide
        self.serverTimeout = serverTimeout
    }

    static let writeTools: Set<String> = ["Read", "Glob", "Grep", "Edit", "Write", "Bash", AskUserSchema.qualifiedName]
    static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", AskUserSchema.qualifiedName]

    /// 도구마다 알려진 입력 키 (8장 6). 훅은 Write `content` · Edit `old_string` · `new_string`을 길이(`*_len`)로 바꿔 보낸다.
    /// 이 밖의 키가 있으면 읽기 도구는 deny, 쓰기 · Bash는 서버 없이 defer (모르는 키가 무엇을 바꾸는지 짐작하지 않는다)
    static let knownInputKeys: [String: Set<String>] = [
        "Read": ["file_path", "offset", "limit", "pages"],
        "Glob": ["pattern", "path"],
        "Grep": ["pattern", "path", "glob", "output_mode", "-B", "-A", "-C", "-n", "-i", "type", "head_limit", "offset", "multiline"],
        "Edit": ["file_path", "old_string_len", "new_string_len", "replace_all"],
        "Write": ["file_path", "content_len"],
        "Bash": ["command", "timeout", "description", "run_in_background", "runInBackground", "dangerouslyDisableSandbox", "dangerously_disable_sandbox"],
    ]

    static func hasUnknownKeys(tool: String, input: WireJSON) -> Bool {
        guard let known = knownInputKeys[tool] else { return false }
        guard case .object(let fields) = input else { return true }
        return !fields.keys.allSatisfy(known.contains)
    }

    static func local(_ decision: HookDecision, _ reason: String, _ code: String) -> ClaudeGateOutcome {
        ClaudeGateOutcome(response: HookResponse(decision: decision, reason: reason), source: .local, code: code)
    }

    public func evaluate(_ request: HookRequest, context: ClaudeGateContext) async -> ClaudeGateOutcome {
        let tool = request.toolName
        let input = request.toolInput
        // L0 멈춘 spawn: 중단 신호 뒤 · 자체 점검 실패 뒤에는 모두 deny (8장 9)
        if context.stopped { return Self.local(.deny, ClaudeGateReason.turnStopped, "stopped") }
        // L1 닫기 모드
        if case .close(let closing) = context.mode {
            return Self.local(.deny, request.toolUseID == closing ? ClaudeGateReason.closedRequest : ClaudeGateReason.turnStopped, "closing")
        }
        // L2 권한 모드
        guard request.permissionMode == "default" else { return Self.local(.deny, ClaudeGateReason.permissionMode, "permission_mode") }
        // L3 · L4 답 모드
        if case .answer(let binding) = context.mode {
            if request.toolUseID == binding.requestID {
                guard !context.answerDelivered else { return Self.local(.deny, ClaudeGateReason.turnStopped, "answer_repeat") }
                return answer(request, binding: binding, context: context)
            }
            if !context.answerDelivered {
                var outcome = Self.local(.deny, ClaudeGateReason.turnStopped, "answer_order")
                outcome.abortSpawn = true
                return outcome
            }
        }
        // L5 도구 집합
        if let refused = Self.outsideToolSet(tool, access: context.access) { return refused }
        // L6 spawn당 보류 하나
        if context.deferIssued { return Self.local(.deny, ClaudeGateReason.oneAtATime, "one_defer") }
        switch tool {
        case "Read", "Glob", "Grep":
            // L7 읽기 범위 (모르는 입력 키 · `..` · 중괄호 경로 패턴은 deny)
            if Self.hasUnknownKeys(tool: tool, input: input) { return Self.local(.deny, ClaudeGateReason.unknownInput, "unknown_input") }
            if Self.hasUnsafePattern(tool: tool, input: input) { return Self.local(.deny, ClaudeGateReason.patternNotAllowed, "pattern") }
            guard let targets = readTargets(tool: tool, input: input, cwd: request.cwd), !targets.isEmpty,
                  targets.allSatisfy({ insideReadable($0, context: context) }) else {
                return Self.local(.deny, ClaudeGateReason.outsidePath, "outside_workspace_read")
            }
            return Self.local(.allow, ClaudeGateReason.inside, "inside")
        case AskUserSchema.qualifiedName:
            // L8 질문: 검사 → defer (모델의 answers는 보지 않는다)
            return askUser(request, input: input)
        case "Edit", "Write":
            // L9 쓰기 대상
            guard let target = writeTarget(input: input, cwd: request.cwd, context: context) else {
                return Self.local(.deny, ClaudeGateReason.outsideFile, "outside_workspace")
            }
            let fingerprint = Self.targetFingerprint(target.realPath)
            let shown = context.secrets.redact(target.relPath)
            let question = Self.approvalQuestion(id: request.toolUseID, tool: tool, relPath: shown, command: nil)
            // 모르는 입력 키 · 하드 링크(작업 폴더 밖과 같은 파일일 수 있다)는 서버에 묻지 않고 사용자에게 (8장 6 · 7)
            if Self.hasUnknownKeys(tool: tool, input: input) { return Self.deferLocally(request, question: question, target: fingerprint, code: "unknown_input") }
            if Self.isHardLinked(target.realPath) { return Self.deferLocally(request, question: question, target: fingerprint, code: "hard_link") }
            let sent = BridgeV1ToolTarget(realPath: context.secrets.redact(target.realPath), relPath: shown)
            let call = BridgeV1ToolCall.claudeWrite(toolUseID: request.toolUseID, permissionMode: request.permissionMode, tool: tool, target: sent)
            return await server(request, call: call, context: context, question: question, target: fingerprint, command: nil)
        default:
            // L10 Bash
            guard let command = input["command"]?.stringValue else { return Self.local(.deny, ClaudeGateReason.unreadable, "malformed") }
            if Self.flag(input, "run_in_background", "runInBackground") { return Self.local(.deny, ClaudeGateReason.background, "background") }
            if Self.flag(input, "dangerouslyDisableSandbox", "dangerously_disable_sandbox") { return Self.local(.deny, ClaudeGateReason.sandboxDisabled, "sandbox") }
            // 건넨 비밀값은 서버로 가는 명령 · 경로와 승인 글에서 가린다 (8장 11). 재구성은 원래 명령으로 대조하므로 가린 명령이 실행되지 않는다
            let shown = context.secrets.redact(command)
            let question = Self.approvalQuestion(id: request.toolUseID, tool: tool, relPath: nil, command: shown)
            if Self.hasUnknownKeys(tool: tool, input: input) { return Self.deferLocally(request, question: question, target: nil, code: "unknown_input") }
            let call = BridgeV1ToolCall.claudeBash(
                toolUseID: request.toolUseID, permissionMode: request.permissionMode, cwd: context.secrets.redact(request.cwd), command: shown, runInBackground: false,
                dangerouslyDisableSandbox: false
            )
            return await server(request, call: call, context: context, question: question, target: nil, command: command)
        }
    }

    /// L5: 등급의 도구 집합 밖이면 deny (답 모드에서도 본다, 8장 9)
    static func outsideToolSet(_ tool: String, access: AgentAccess) -> ClaudeGateOutcome? {
        let allowed = access == .write ? writeTools : readOnlyTools
        guard !allowed.contains(tool) else { return nil }
        if access == .readOnly, ["Edit", "Write", "Bash"].contains(tool) { return local(.deny, ClaudeGateReason.readOnly, "read_only") }
        return local(.deny, ClaudeGateReason.toolNotAllowed, "tool_not_allowed")
    }

    /// Glob `pattern` · Grep `glob`(파일 경로 패턴)에 `..`이나 중괄호가 있으면 정적 접두 검사를 벗어날 수 있다 (8장 5). Grep `pattern`은 파일 내용 정규식이라 보지 않는다
    static func hasUnsafePattern(tool: String, input: WireJSON) -> Bool {
        let key: String
        switch tool {
        case "Glob": key = "pattern"
        case "Grep": key = "glob"
        default: return false
        }
        guard let value = input[key] else { return false }
        guard let pattern = value.stringValue else { return true }
        return pattern.contains("..") || pattern.contains("{") || pattern.contains("}")
    }

    /// 서버를 부르지 않고 승인 질문으로 미룬다
    static func deferLocally(_ request: HookRequest, question: AgentQuestion, target: String?, code: String, source: ClaudeGateOutcome.Source = .local) -> ClaudeGateOutcome {
        var outcome = ClaudeGateOutcome(response: HookResponse(decision: .defer, reason: ClaudeGateReason.waitingApproval), source: source, code: code)
        outcome.deferred = ClaudePendingDeferred(id: request.toolUseID, kind: .approval, inputSHA256: request.inputSHA256, toolName: request.toolName, question: question, targetSHA256: target)
        return outcome
    }

    /// 없거나 `false`가 아니면 켜진 것으로 본다 (모양이 이상한 값도 거절 쪽)
    static func flag(_ input: WireJSON, _ keys: String...) -> Bool {
        keys.contains { key in
            guard let value = input[key] else { return false }
            return value != .bool(false) && value != .null
        }
    }

    // MARK: L3 답

    func answer(_ request: HookRequest, binding: ClaudeAnswerBinding, context: ClaudeGateContext) -> ClaudeGateOutcome {
        if let expected = binding.inputSHA256, expected != request.inputSHA256 {
            var outcome = Self.local(.deny, ClaudeGateReason.inputChanged, "input_changed")
            outcome.abortSpawn = true
            return outcome
        }
        var outcome: ClaudeGateOutcome
        // 답 모드에서도 지금 등급의 도구 집합을 본다 (8장 9): 질문 뒤에 등급이 내려갔으면 승인도 거절이다
        if var refused = Self.outsideToolSet(request.toolName, access: context.access) {
            refused.answeredPending = true
            return refused
        }
        switch binding.kind {
        case .input:
            guard request.toolName == AskUserSchema.qualifiedName, let answers = Self.answers(binding.value, input: request.toolInput) else {
                outcome = Self.local(.deny, ClaudeGateReason.turnStopped, "answer_shape")
                outcome.abortSpawn = true
                return outcome
            }
            outcome = ClaudeGateOutcome(response: HookResponse(decision: .allow, reason: ClaudeGateReason.answered, answers: answers), source: .local, code: "answered")
        case .approval:
            switch Self.approval(binding.value) {
            case true?:
                if ["Edit", "Write"].contains(request.toolName) {
                    guard let target = writeTarget(input: request.toolInput, cwd: request.cwd, context: context) else {
                        // 승인 뒤에 대상이 밖을 가리키게 바뀌었다 (기호 링크 바꿔치기)
                        outcome = Self.local(.deny, ClaudeGateReason.outsideFile, "outside_workspace")
                        break
                    }
                    // 보류 때 해석한 대상과 같을 때만 (8장 2): 안의 다른 파일로 바뀐 링크 · 바뀐 부모 폴더 · 새 하드 링크. 지문이 없으면 확인할 수 없다
                    guard let expected = binding.targetSHA256, Self.targetFingerprint(target.realPath) == expected else {
                        outcome = Self.local(.deny, ClaudeGateReason.targetChanged, "target_changed")
                        outcome.abortSpawn = true
                        return outcome
                    }
                }
                outcome = Self.local(.allow, ClaudeGateReason.approved, "approved")
            case false?:
                outcome = Self.local(.deny, ClaudeGateReason.declined, "declined")
            case nil:
                outcome = Self.local(.deny, ClaudeGateReason.declined, "approval_unreadable")
            }
        }
        outcome.answeredPending = true
        return outcome
    }

    /// 답 모양 `{<question id>: <label> | [<label>] | <글>}` (13.2 :510). 자유 글(`text`)은 하나뿐인 질문 id에
    static func answers(_ value: AgentAnswerValue, input: WireJSON) -> [String: WireJSON]? {
        if let answers = value.answers, !answers.isEmpty {
            return answers.mapValues { answer in
                switch answer {
                case .one(let text): .string(text)
                case .many(let texts): .array(texts.map { .string($0) })
                }
            }
        }
        if let text = value.text, let questions = input["questions"]?.arrayValue, questions.count == 1, let id = questions[0]["id"]?.stringValue {
            return [id: .string(text)]
        }
        return nil
    }

    /// 승인 답 (`answers.approval` = `allow` · `deny`, D3c-2 3.6). 모르는 값은 nil (거절로 닫는다)
    static func approval(_ value: AgentAnswerValue) -> Bool? {
        guard case .one(let raw)? = value.answers?["approval"] else { return nil }
        switch raw.lowercased() {
        case "allow": return true
        case "deny": return false
        default: return nil
        }
    }

    // MARK: L7 · L9 경로

    /// Read `file_path` · Glob · Grep `path`(없으면 cwd) · Glob 절대 `pattern`의 글로브 문자 앞 정적 접두. 모양이 틀리면 nil (거절)
    func readTargets(tool: String, input: WireJSON, cwd: String) -> [String]? {
        switch tool {
        case "Read":
            guard let path = input["file_path"]?.stringValue else { return nil }
            return GateFileSystem.absolute(path, cwd: cwd).map { [$0] }
        case "Grep":
            if input["path"] != nil, input["path"]?.stringValue == nil { return nil }
            return GateFileSystem.absolute(input["path"]?.stringValue ?? cwd, cwd: cwd).map { [$0] }
        default:
            if input["path"] != nil, input["path"]?.stringValue == nil { return nil }
            let base = input["path"]?.stringValue ?? cwd
            guard let root = GateFileSystem.absolute(base, cwd: cwd), let pattern = input["pattern"]?.stringValue, !pattern.hasPrefix("~") else { return nil }
            if pattern.hasPrefix("/") {
                return [root, Self.staticPrefix(pattern)]
            }
            guard !pattern.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
            return [root]
        }
    }

    /// 글로브 문자(`*` `?` `[` `{`) 앞까지의 폴더
    static func staticPrefix(_ pattern: String) -> String {
        let glob = pattern.firstIndex { "*?[{".contains($0) }
        guard let glob else { return pattern }
        let head = pattern[..<glob]
        guard let slash = head.lastIndex(of: "/") else { return "/" }
        let prefix = String(head[..<slash])
        return prefix.isEmpty ? "/" : prefix
    }

    func insideReadable(_ path: String, context: ClaudeGateContext) -> Bool {
        guard let real = fileSystem.resolve(path) else { return false }
        return GateFileSystem.isInside(real, root: context.workspaceRealPath) || GateFileSystem.isInside(real, root: context.sessionCwdRealPath)
    }

    /// Edit · Write 대상: realpath(없으면 가장 가까운 조상 + 나머지)가 작업 폴더 안일 때만 (작업 폴더 자신은 아니다)
    func writeTarget(input: WireJSON, cwd: String, context: ClaudeGateContext) -> BridgeV1ToolTarget? {
        guard let raw = input["file_path"]?.stringValue, let absolute = GateFileSystem.absolute(raw, cwd: cwd), let real = fileSystem.resolve(absolute),
              real != context.workspaceRealPath, GateFileSystem.isInside(real, root: context.workspaceRealPath) else { return nil }
        let relative = context.workspaceRealPath == "/" ? String(real.dropFirst()) : String(real.dropFirst(context.workspaceRealPath.count + 1))
        return BridgeV1ToolTarget(realPath: real, relPath: relative)
    }

    /// 대상 지문 (8장 2): 있으면 realpath + 장치 · inode · 링크 수, 없으면 있는 가장 가까운 조상의 장치 · inode + 그 아래 이름.
    /// 상태 파일에 경로를 쓰지 않도록 sha256 hex로 둔다. 조상도 없으면 nil
    static func targetFingerprint(_ realPath: String) -> String? {
        var info = stat()
        if lstat(realPath, &info) == 0 {
            return digest(["file", realPath, "\(info.st_dev)", "\(info.st_ino)", "\(info.st_nlink)"])
        }
        var ancestor = realPath
        var rest: [String] = []
        while ancestor != "/", !ancestor.isEmpty {
            rest.insert((ancestor as NSString).lastPathComponent, at: 0)
            ancestor = (ancestor as NSString).deletingLastPathComponent
            if lstat(ancestor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
                return digest(["parent", realPath, "\(info.st_dev)", "\(info.st_ino)", rest.joined(separator: "/")])
            }
        }
        return nil
    }

    static func digest(_ parts: [String]) -> String {
        WireSHA256.hex(Data(parts.joined(separator: "\u{0}").utf8))
    }

    /// 일반 파일이고 다른 이름(하드 링크)이 더 있다 (8장 7)
    static func isHardLinked(_ realPath: String) -> Bool {
        var info = stat()
        return lstat(realPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink > 1
    }

    // MARK: L8 질문

    func askUser(_ request: HookRequest, input: WireJSON) -> ClaudeGateOutcome {
        let questions: [AskUserSchema.Question]
        switch AskUserSchema.validate(input) {
        case .failure(let problem): return Self.local(.deny, problem.message, "ask_user_invalid")
        case .success(let value): questions = value
        }
        let items = questions.map { question in
            AgentQuestionItem(
                id: question.id, header: question.header, text: question.text, options: question.options.map { AgentQuestionOption(label: $0.label, description: $0.description) },
                multiSelect: question.multiSelect, allowOther: question.allowOther, secret: question.secret
            )
        }
        let question = AgentQuestion(providerRequestID: request.toolUseID, kind: .input, structured: true, text: questions[0].text, items: items)
        // 서버 질문 모양에 담을 수 없으면 (줄여도 32KB를 넘는 등) 지금 거절한다 (defer 뒤 닫히는 것보다 모델이 바로 고친다)
        guard case .fits = Outbox.fit(question: question, taskID: "00000000-0000-0000-0000-000000000000", observedAt: Date()) else {
            return Self.local(.deny, ClaudeGateReason.questionsTooLarge, "ask_user_too_large")
        }
        var outcome = Self.local(.defer, ClaudeGateReason.waitingAnswer, "ask_user")
        outcome.deferred = ClaudePendingDeferred(id: request.toolUseID, kind: .input, inputSHA256: request.inputSHA256, toolName: request.toolName, question: question)
        return outcome
    }

    // MARK: 승인 질문 글 (Q8: 무엇을 하는지 보인다. diff · 본문 0)

    static let commandPreviewChars = 300

    /// 승인 카드 글 (Q8 · 8장 4): Edit · Write는 상대 경로, Bash는 명령 앞 300자. 줄바꿈 `⏎` · 탭 `⇥` · 제어 · 양방향 · 폭 없는 글자 `\u{XXXX}`로 보이게 하고,
    /// 300자에서 잘랐으면 `… (+남은 글자 수)`를 붙인다 (보이지 않는 글자로 실제 명령을 숨기지 못하게)
    static func approvalQuestion(id: String, tool: String, relPath: String?, command: String?) -> AgentQuestion {
        let header: String
        let text: String
        switch tool {
        case "Edit":
            header = "Edit file"
            text = "Edit " + visible(relPath ?? "")
        case "Write":
            header = "Write file"
            text = "Write " + visible(relPath ?? "")
        default:
            header = "Run command"
            let full = command ?? ""
            let rest = full.count - commandPreviewChars
            text = "Run: " + visible(String(full.prefix(commandPreviewChars))) + (rest > 0 ? "… (+\(rest))" : "")
        }
        let item = AgentQuestionItem(id: "approval", header: header, text: text, options: [AgentQuestionOption(label: "Allow", description: ""), AgentQuestionOption(label: "Deny", description: "")])
        return AgentQuestion(providerRequestID: id, kind: .approval, structured: true, text: text, items: [item])
    }

    /// 보이지 않거나 글 방향을 바꾸는 글자를 보이는 표기로
    static func visible(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out.append(contentsOf: "⏎".unicodeScalars)
            case "\t": out.append(contentsOf: "⇥".unicodeScalars)
            default:
                let hidden: Bool
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: hidden = true
                default: hidden = false
                }
                if hidden { out.append(contentsOf: String(format: "\\u{%04X}", scalar.value).unicodeScalars) } else { out.append(scalar) }
            }
        }
        return String(out)
    }

    // MARK: S · P

    /// - `target`: Edit · Write 대상 지문 (보류 기록에 둔다). - `command`: Bash 원래 명령 (재구성 대조용, 서버로는 가린 명령이 간다)
    func server(_ request: HookRequest, call: BridgeV1ToolCall, context: ClaudeGateContext, question: AgentQuestion, target: String?, command: String?) async -> ClaudeGateOutcome {
        func deferLocally(_ code: String, source: ClaudeGateOutcome.Source = .local) -> ClaudeGateOutcome {
            Self.deferLocally(request, question: question, target: target, code: code, source: source)
        }
        let query = BridgeV1ToolDecisionQuery(
            agentSessionID: context.agentSessionID, agentTaskID: context.agentTaskID, turnSeq: context.turnSeq, workspaceRealPath: context.workspaceRealPath, call: call
        )
        guard BridgeV1ToolDecisionLimits.fits(query) else { return deferLocally("over_limit") }
        guard let decide else { return deferLocally("not_attached") }
        // P1: 1.0초 초과 · 2xx 아님 · 디코딩 실패 · 등록 전 → defer, 403 → deny
        let result = await Self.race(serverTimeout) { try await decide(query) }
        let response: BridgeV1ToolDecisionResponse
        switch result {
        case nil: return deferLocally("server_timeout")
        case .failure(let error)?:
            if (error as? AgentToolDecisionError) == .revoked {
                var outcome = Self.local(.deny, ClaudeGateReason.accessDisabled, "revoked")
                outcome.source = .server
                return outcome
            }
            return deferLocally("server_error")
        case .success(let value)?:
            response = value
        }
        guard response.isUnderstood else { return deferLocally("unknown_response", source: .server) }
        // 로그에는 아는 이유 코드만 (서버가 준 모르는 글 · agent_note는 쓰지 않는다, 8장 21)
        let code = response.reason.raw
        switch (response.decision, call) {
        case (.allow, .claudeBash):
            // P2: 서버 파서가 허용했다. 원래 명령 · 넘긴 PATH의 실행 파일 · 경로 realpath를 확인하고 명령을 다시 만든다
            guard response.reason == .readonlyCommand, let parse = response.parse, let command,
                  let rebuilt = CommandRebuild.rebuild(parse, command: command, childPATH: context.childPATH, workspaceRealPath: context.workspaceRealPath, fileSystem: fileSystem) else {
                return deferLocally("parse_check_failed", source: .server)
            }
            return ClaudeGateOutcome(response: HookResponse(decision: .allow, reason: ClaudeGateReason.readOnlyCommand, command: rebuilt), source: .server, code: code)
        case (.allow, .claudeWrite):
            // P3: Auto/Full 쓰기 (입력 그대로)
            guard response.reason == .policyAuto else { return deferLocally("allow_unexpected", source: .server) }
            return ClaudeGateOutcome(response: HookResponse(decision: .allow, reason: ClaudeGateReason.policy), source: .server, code: code)
        case (.deny, _):
            // P4
            let note = response.agentNote.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) } ?? ClaudeGateReason.policyDenied
            return ClaudeGateOutcome(response: HookResponse(decision: .deny, reason: note), source: .server, code: code)
        case (.defer, _):
            // P5: 승인 질문
            return deferLocally(code, source: .server)
        default:
            return deferLocally("allow_unexpected", source: .server)
        }
    }

    /// `operation`을 `limit` 안에서 기다린다. 넘으면 nil (작업은 취소하지만 끝나기를 기다리지 않는다)
    static func race<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        let gate = OnceResult<Result<T, Error>?>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let work = Task {
                let value: Result<T, Error>
                do { value = .success(try await operation()) } catch { value = .failure(error) }
                gate.resume(value)
            }
            // 시계는 Dispatch로 잰다 (협력 스레드가 바쁠 때도 제때 끊는다)
            let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if gate.resume(nil) { work.cancel() }
            }
        }
    }
}

/// 한 번만 이어지는 continuation (먼저 온 쪽이 이긴다)
final class OnceResult<Value: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Value, Never>?, done: Bool)>((nil, false))

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        state.withLock { $0.continuation = continuation }
    }

    /// 이번에 이어졌으면 true
    @discardableResult
    func resume(_ value: Value) -> Bool {
        let continuation: CheckedContinuation<Value, Never>? = state.withLock { current in
            guard !current.done, let continuation = current.continuation else { return nil }
            current.done = true
            current.continuation = nil
            return continuation
        }
        continuation?.resume(returning: value)
        return continuation != nil
    }
}

#endif
