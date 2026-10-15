import Foundation

// `POST /api/v1/bridge/tool-decision`의 Swift 짝 (OA D3a 계약 3.1). `src/lib/api/contract.ts`의 `// --- D3c-2 ---` 블록과 같은 이름 · 모양이다 (JSON 키는 snake_case).
// - 보낼 때는 엄격하다: 서버 요청 스키마가 strictObject다. 정해진 키만 보낸다. 본문 글(Write `content` · Edit 문자열)은 자리가 없다.
// - 받을 때는 너그럽다: 모르는 `decision` · `reason` · `card_flags` 값은 열린 문자열로 받고, 그런 응답의 결정은 **defer**로 본다 (D2b 3.3 원칙).
// - 보내기 전에 서버와 같은 상한을 검사하고(`BridgeV1ToolDecisionLimits`), 넘으면 서버 400 대신 로컬 defer한다.
// Codex kind 둘은 D3b가 쓴다.

public struct BridgeV1ToolTarget: Equatable, Sendable {
    /// Mac realpath (없는 파일은 가장 가까운 조상의 realpath + 나머지)
    public var realPath: String
    /// 작업 폴더 기준 상대 경로
    public var relPath: String

    public init(realPath: String, relPath: String) {
        self.realPath = realPath
        self.relPath = relPath
    }

    var json: [String: String] { ["real_path": realPath, "rel_path": relPath] }
}

public enum BridgeV1ToolCall: Equatable, Sendable {
    case claudeBash(toolUseID: String, permissionMode: String, cwd: String, command: String, runInBackground: Bool, dangerouslyDisableSandbox: Bool)
    /// `tool`은 `Edit` · `Write`
    case claudeWrite(toolUseID: String, permissionMode: String, tool: String, target: BridgeV1ToolTarget)
    case codexCommand(providerRequestID: String, cwd: String, command: String, commandActions: [String], firstForItem: Bool)
    case codexFileChange(providerRequestID: String, targets: [BridgeV1ToolTarget], firstForItem: Bool)
}

/// adapter가 묻는 것 (bridge id는 런타임이 채운다, Q12)
public struct BridgeV1ToolDecisionQuery: Equatable, Sendable {
    public var agentSessionID: String
    public var agentTaskID: String
    public var turnSeq: Int
    public var workspaceRealPath: String
    public var call: BridgeV1ToolCall

    public init(agentSessionID: String, agentTaskID: String, turnSeq: Int, workspaceRealPath: String, call: BridgeV1ToolCall) {
        self.agentSessionID = agentSessionID
        self.agentTaskID = agentTaskID
        self.turnSeq = turnSeq
        self.workspaceRealPath = workspaceRealPath
        self.call = call
    }
}

public struct BridgeV1ToolDecisionRequest: Encodable, Equatable, Sendable {
    public var bridgeID: String
    public var query: BridgeV1ToolDecisionQuery

    public init(bridgeID: String, query: BridgeV1ToolDecisionQuery) {
        self.bridgeID = bridgeID
        self.query = query
    }

    enum Key: String, CodingKey {
        case bridgeID = "bridge_id", agentSessionID = "agent_session_id", agentTaskID = "agent_task_id", turnSeq = "turn_seq", workspaceRealPath = "workspace_real_path", call
    }

    enum CallKey: String, CodingKey {
        case kind, cwd, command, tool, target, targets
        case toolUseID = "tool_use_id", permissionMode = "permission_mode", runInBackground = "run_in_background"
        case dangerouslyDisableSandbox = "dangerously_disable_sandbox", providerRequestID = "provider_request_id", commandActions = "command_actions"
        case firstForItem = "first_for_item"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(bridgeID, forKey: .bridgeID)
        try c.encode(query.agentSessionID, forKey: .agentSessionID)
        try c.encode(query.agentTaskID, forKey: .agentTaskID)
        try c.encode(query.turnSeq, forKey: .turnSeq)
        try c.encode(query.workspaceRealPath, forKey: .workspaceRealPath)
        var call = c.nestedContainer(keyedBy: CallKey.self, forKey: .call)
        switch query.call {
        case .claudeBash(let id, let mode, let cwd, let command, let background, let sandbox):
            try call.encode("claude_bash", forKey: .kind)
            try call.encode(id, forKey: .toolUseID)
            try call.encode(mode, forKey: .permissionMode)
            try call.encode(cwd, forKey: .cwd)
            try call.encode(command, forKey: .command)
            try call.encode(background, forKey: .runInBackground)
            try call.encode(sandbox, forKey: .dangerouslyDisableSandbox)
        case .claudeWrite(let id, let mode, let tool, let target):
            try call.encode("claude_write", forKey: .kind)
            try call.encode(id, forKey: .toolUseID)
            try call.encode(mode, forKey: .permissionMode)
            try call.encode(tool, forKey: .tool)
            try call.encode(target.json, forKey: .target)
        case .codexCommand(let id, let cwd, let command, let actions, let first):
            try call.encode("codex_command", forKey: .kind)
            try call.encode(id, forKey: .providerRequestID)
            try call.encode(cwd, forKey: .cwd)
            try call.encode(command, forKey: .command)
            try call.encode(actions, forKey: .commandActions)
            try call.encode(first, forKey: .firstForItem)
        case .codexFileChange(let id, let targets, let first):
            try call.encode("codex_file_change", forKey: .kind)
            try call.encode(id, forKey: .providerRequestID)
            try call.encode(targets.map(\.json), forKey: .targets)
            try call.encode(first, forKey: .firstForItem)
        }
    }
}

public enum BridgeV1ToolDecisionValue: OpenStringValue {
    case allow, deny, `defer`
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "allow": self = .allow
        case "deny": self = .deny
        case "defer": self = .defer
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .allow: "allow"
        case .deny: "deny"
        case .defer: "defer"
        case .unknown(let raw): raw
        }
    }
}

/// `toolDecisionReasonSchema` (contract.ts D3c-2)
public enum BridgeV1ToolDecisionReason: OpenStringValue {
    case readonlyCommand, policyAuto, manualWrite, commandNotReadonly, actionsNotRead, notFirstRequest, runsWithoutSandbox, serverBusy, writeGateClosed, readOnly
    case permissionMode, background, sandboxDisabled, outsideWorkspace, workspaceMismatch, pathInUse, notLive, rateLimited, toolConfigWrite, pathTooLong
    case unknown(String)

    static let table: [(BridgeV1ToolDecisionReason, String)] = [
        (.readonlyCommand, "readonly_command"), (.policyAuto, "policy_auto"), (.manualWrite, "manual_write"), (.commandNotReadonly, "command_not_readonly"),
        (.actionsNotRead, "actions_not_read"), (.notFirstRequest, "not_first_request"), (.runsWithoutSandbox, "runs_without_sandbox"), (.serverBusy, "server_busy"),
        (.writeGateClosed, "write_gate_closed"), (.readOnly, "read_only"), (.permissionMode, "permission_mode"), (.background, "background"),
        (.sandboxDisabled, "sandbox_disabled"), (.outsideWorkspace, "outside_workspace"), (.workspaceMismatch, "workspace_mismatch"), (.pathInUse, "path_in_use"),
        (.notLive, "not_live"), (.rateLimited, "rate_limited"), (.toolConfigWrite, "tool_config_write"), (.pathTooLong, "path_too_long"),
    ]

    public init(raw: String) {
        self = Self.table.first { $0.1 == raw }?.0 ?? .unknown(raw)
    }

    public var raw: String {
        if case .unknown(let raw) = self { return raw }
        return Self.table.first { $0.0 == self }?.1 ?? ""
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public struct BridgeV1ToolDecisionParse: Decodable, Equatable, Sendable {
    public struct Path: Decodable, Equatable, Sendable {
        /// argv 안의 위치. nil이면 명령에 없던 경로(`implicit_cwd`)라 끝에 덧붙인다
        public var index: Int?
        public var absolute: String

        public init(index: Int?, absolute: String) {
            self.index = index
            self.absolute = absolute
        }
    }

    /// `none`(Claude Code) · `zsh_lc`(Codex)
    public var wrapper: String
    public var argv: [String]
    public var paths: [Path]
    public var implicitCwd: Bool

    public init(wrapper: String, argv: [String], paths: [Path], implicitCwd: Bool) {
        self.wrapper = wrapper
        self.argv = argv
        self.paths = paths
        self.implicitCwd = implicitCwd
    }

    enum CodingKeys: String, CodingKey {
        case wrapper, argv, paths
        case implicitCwd = "implicit_cwd"
    }
}

public struct BridgeV1ToolDecisionHolder: Decodable, Equatable, Sendable {
    public var actionNumber: Int?
    public var relPath: String

    public init(actionNumber: Int?, relPath: String) {
        self.actionNumber = actionNumber
        self.relPath = relPath
    }

    enum CodingKeys: String, CodingKey {
        case actionNumber = "action_number"
        case relPath = "rel_path"
    }
}

public struct BridgeV1ToolDecisionResponse: Decodable, Equatable, Sendable {
    public var decision: BridgeV1ToolDecisionValue
    public var reason: BridgeV1ToolDecisionReason
    public var parse: BridgeV1ToolDecisionParse?
    /// deny일 때만: 모델에게 줄 고정 문구 (서버 `TOOL_DECISION_NOTES`, 영어)
    public var agentNote: String?
    public var holder: BridgeV1ToolDecisionHolder?
    public var cardFlags: [String]
    public var serverTime: Date

    public init(
        decision: BridgeV1ToolDecisionValue, reason: BridgeV1ToolDecisionReason, parse: BridgeV1ToolDecisionParse?, agentNote: String?, holder: BridgeV1ToolDecisionHolder?,
        cardFlags: [String], serverTime: Date
    ) {
        self.decision = decision
        self.reason = reason
        self.parse = parse
        self.agentNote = agentNote
        self.holder = holder
        self.cardFlags = cardFlags
        self.serverTime = serverTime
    }

    enum CodingKeys: String, CodingKey {
        case decision, reason, parse, holder
        case agentNote = "agent_note"
        case cardFlags = "card_flags"
        case serverTime = "server_time"
    }

    /// 이 앱이 아는 값으로만 된 응답인가. 아니면 결정은 defer다
    public var isUnderstood: Bool {
        if case .unknown = decision { return false }
        return reason.isKnown && cardFlags.allSatisfy { $0 == "runs_without_sandbox" }
    }
}

/// 서버 스키마와 같은 상한 (contract.ts D3c-2). 넘는 요청은 보내지 않고 로컬 defer한다 (서버 400 대신)
public enum BridgeV1ToolDecisionLimits {
    public static let pathMaxChars = 1000
    public static let commandMaxChars = 4096
    public static let workspaceMaxChars = 500
    public static let requestIDMaxChars = 200
    public static let cwdMaxChars = 4096
    public static let permissionModeMaxChars = 50

    /// 절대 경로이고 `.` · `..` · 빈 성분 · 제어 글자가 없다 (`toolRealPathSchema`)
    public static func isRealPath(_ value: String) -> Bool {
        guard value.hasPrefix("/") else { return false }
        if value != "/" {
            guard !value.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        }
        return !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    static func chars(_ value: String) -> Int { value.unicodeScalars.count }

    static func isGUID(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    public static func fits(_ query: BridgeV1ToolDecisionQuery) -> Bool {
        guard isGUID(query.agentSessionID), isGUID(query.agentTaskID), query.turnSeq >= 1 else { return false }
        guard isRealPath(query.workspaceRealPath), chars(query.workspaceRealPath.precomposedStringWithCanonicalMapping) <= workspaceMaxChars else { return false }
        func id(_ value: String) -> Bool { (1...requestIDMaxChars).contains(chars(value)) }
        func mode(_ value: String) -> Bool { (1...permissionModeMaxChars).contains(chars(value)) }
        func cwd(_ value: String) -> Bool { value.hasPrefix("/") && (1...cwdMaxChars).contains(chars(value)) }
        func command(_ value: String) -> Bool { (1...commandMaxChars).contains(chars(value)) }
        func target(_ value: BridgeV1ToolTarget) -> Bool {
            isRealPath(value.realPath) && chars(value.realPath) <= pathMaxChars && (1...pathMaxChars).contains(chars(value.relPath))
        }
        switch query.call {
        case .claudeBash(let toolUseID, let permissionMode, let cwdValue, let commandValue, _, _):
            return id(toolUseID) && mode(permissionMode) && cwd(cwdValue) && command(commandValue)
        case .claudeWrite(let toolUseID, let permissionMode, let tool, let targetValue):
            return id(toolUseID) && mode(permissionMode) && ["Edit", "Write"].contains(tool) && target(targetValue)
        case .codexCommand(let requestID, let cwdValue, let commandValue, let actions, _):
            return id(requestID) && cwd(cwdValue) && command(commandValue) && actions.count <= 32 && actions.allSatisfy { (1...50).contains(chars($0)) }
        case .codexFileChange(let requestID, let targets, _):
            return id(requestID) && (1...20).contains(targets.count) && targets.allSatisfy(target)
        }
    }
}
