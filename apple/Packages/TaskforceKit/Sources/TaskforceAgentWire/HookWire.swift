#if os(macOS)
import Foundation

/// 훅 → bridge 소켓의 한 줄 JSON (OA D3a 계약 2.6, Q4). 계약 13.2 :490과 다른 점:
/// - Write `content` · Edit `old_string` · `new_string`은 빼고 길이만 싣는다 (본문 글이 소켓 · 서버로 가지 않는다). bridge가 읽지 않는 도구는 입력을 싣지 않는다
/// - 원래 입력 전체의 정규 글자 sha256을 `input_sha256`로 싣는다 (보류 때와 답 resume 때 입력이 같은지)
/// - `provider_session_id`: 훅 입력의 Claude Code 세션 id (bridge가 그 spawn의 세션 id와 대조한다)
/// - 응답은 `answers` · `command`만 준다. `updatedInput`은 훅이 자기가 받은 원래 입력에서 만든다
public enum HookWire {
    public static let version = 1
    /// 요청 · 응답 한 줄 상한 (`\n` 포함)
    public static let maxLineBytes = 256 * 1024
    /// 훅 stdin 상한 (Write 본문이 크다). 넘으면 deny
    public static let maxStdinBytes = 16 * 1024 * 1024
    /// 훅이 시작부터 bridge 답을 기다리는 시간 (연결 · 쓰기 · 읽기 합계). 넘으면 deny (훅 timeout 10초의 fail-open 경로를 쓰지 않는다).
    /// bridge의 읽기 + 응답 예산보다 넉넉히 크다 (OA D3a 16장 3): 훅은 요청에 자기 기한(`deadline_ns`)을 싣고 bridge는 그보다 앞서 정한다
    public static let budget: TimeInterval = 4.0

    /// 프로세스 사이에 같은 값을 주는 연속 시계 (OA D3a 17장 2): 부팅 뒤 나노초 (`CLOCK_MONOTONIC_RAW`, 시계 바꿈 · 조정을 받지 않는다)
    public static func monotonicNow() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    /// bridge가 입력을 읽는 도구 (그 밖은 이름만 보고 deny한다)
    public static let readTools: Set<String> = ["Read", "Glob", "Grep", "Bash", "Edit", "Write", AskUserSchema.qualifiedName]

    /// 소켓에 싣는 입력: 본문 글을 길이로 바꾸고, bridge가 읽지 않는 도구는 `{}`
    public static func strippedInput(toolName: String, input: WireJSON) -> WireJSON {
        guard readTools.contains(toolName), case .object(var fields) = input else { return .object([:]) }
        let bodies: [String]
        switch toolName {
        case "Write": bodies = ["content"]
        case "Edit": bodies = ["old_string", "new_string"]
        default: bodies = []
        }
        for key in bodies {
            if let value = fields.removeValue(forKey: key) {
                fields[key + "_len"] = .int(Int64(value.stringValue?.utf8.count ?? value.canonicalText.utf8.count))
            }
        }
        return .object(fields)
    }

    /// 원래 입력 전체의 정규 글자 sha256 (hex)
    public static func inputDigest(_ input: WireJSON) -> String {
        WireSHA256.hex(input.canonicalData)
    }

    static func line(_ value: WireJSON) throws -> Data {
        var data = value.canonicalData
        data.append(0x0A)
        guard data.count <= maxLineBytes else { throw WireError.tooLarge }
        return data
    }

    /// 한 줄을 읽어 객체로. 상한 · 깨짐 · 정해진 키 밖의 키는 거절한다
    static func object(fromLine line: Data, allowed: Set<String>) throws -> [String: WireJSON] {
        guard line.count <= maxLineBytes else { throw WireError.tooLarge }
        var body = line
        if body.last == 0x0A { body.removeLast() }
        guard !body.contains(0x0A) else { throw WireError.malformed }
        guard case .object(let fields) = try WireJSON.parse(body) else { throw WireError.malformed }
        guard Set(fields.keys).isSubset(of: allowed) else { throw WireError.unknownField }
        return fields
    }
}

public struct HookRequest: Equatable, Sendable {
    public var v: Int
    /// spawn마다 만든 32바이트 무작위 값 (base64url 43자)
    public var nonce: String
    /// Taskforce `agent_session_id` (settings의 `--session`)
    public var sessionID: String
    /// 훅 입력의 Claude Code 세션 id
    public var providerSessionID: String?
    public var hookEvent: String
    public var toolUseID: String
    public var toolName: String
    /// 본문 글을 뺀 입력 (`HookWire.strippedInput`)
    public var toolInput: WireJSON
    public var inputSHA256: String
    public var permissionMode: String
    /// 훅 입력의 `cwd` 그대로 (계약 13.4.1-3)
    public var cwd: String
    /// 훅의 절대 기한 (17장 2): `HookWire.monotonicNow()` 시계의 나노초. bridge는 같은 시계로 그보다 앞서 응답을 정한다(보낸 뒤 읽기까지의 지연도 센다).
    /// 없으면 bridge 자신의 예산만
    public var deadlineNS: UInt64?

    public init(
        nonce: String, sessionID: String, providerSessionID: String?, hookEvent: String, toolUseID: String, toolName: String, toolInput: WireJSON, inputSHA256: String,
        permissionMode: String, cwd: String, deadlineNS: UInt64? = nil
    ) {
        self.deadlineNS = deadlineNS
        self.v = HookWire.version
        self.nonce = nonce
        self.sessionID = sessionID
        self.providerSessionID = providerSessionID
        self.hookEvent = hookEvent
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.toolInput = toolInput
        self.inputSHA256 = inputSHA256
        self.permissionMode = permissionMode
        self.cwd = cwd
    }

    static let keys: Set<String> = [
        "v", "nonce", "session_id", "provider_session_id", "hook_event", "tool_use_id", "tool_name", "tool_input", "input_sha256", "permission_mode", "cwd", "deadline_ns",
    ]

    public func encodedLine() throws -> Data {
        var fields: [String: WireJSON] = [
            "v": .int(Int64(v)), "nonce": .string(nonce), "session_id": .string(sessionID), "hook_event": .string(hookEvent), "tool_use_id": .string(toolUseID),
            "tool_name": .string(toolName), "tool_input": toolInput, "input_sha256": .string(inputSHA256), "permission_mode": .string(permissionMode), "cwd": .string(cwd),
        ]
        if let providerSessionID { fields["provider_session_id"] = .string(providerSessionID) }
        if let deadlineNS, deadlineNS <= UInt64(Int64.max) { fields["deadline_ns"] = .int(Int64(deadlineNS)) }
        return try HookWire.line(.object(fields))
    }

    public static func decode(line: Data) throws -> HookRequest {
        let fields = try HookWire.object(fromLine: line, allowed: keys)
        guard fields["v"] == .int(Int64(HookWire.version)) else { throw WireError.unsupportedVersion }
        func text(_ key: String) throws -> String {
            guard let value = fields[key]?.stringValue else { throw WireError.missingField }
            return value
        }
        guard let input = fields["tool_input"], input.objectValue != nil else { throw WireError.missingField }
        var provider: String?
        if let value = fields["provider_session_id"] {
            guard let id = value.stringValue else { throw WireError.malformed }
            provider = id
        }
        var deadline: UInt64?
        if let value = fields["deadline_ns"] {
            guard case .int(let ns) = value, ns > 0 else { throw WireError.malformed }
            deadline = UInt64(ns)
        }
        return HookRequest(
            nonce: try text("nonce"), sessionID: try text("session_id"), providerSessionID: provider, hookEvent: try text("hook_event"), toolUseID: try text("tool_use_id"),
            toolName: try text("tool_name"), toolInput: input, inputSHA256: try text("input_sha256"), permissionMode: try text("permission_mode"), cwd: try text("cwd"),
            deadlineNS: deadline
        )
    }
}

public enum HookDecision: String, Equatable, Sendable {
    case allow
    case deny
    case `defer`
}

/// bridge → 훅 한 줄
public struct HookResponse: Equatable, Sendable {
    public var decision: HookDecision
    /// 모델에게 가는 이유 (영어 상수. 사용자 글 · 명령 · 경로를 담지 않는다)
    public var reason: String
    /// `ask_user` 답. 훅이 원래 입력의 `answers`를 이것으로 **바꾼다** (모델이 넣은 값은 버린다)
    public var answers: [String: WireJSON]?
    /// 다시 만든 Bash 명령. 훅이 원래 입력의 `command`만 바꾼다
    public var command: String?

    public init(decision: HookDecision, reason: String, answers: [String: WireJSON]? = nil, command: String? = nil) {
        self.decision = decision
        self.reason = reason
        self.answers = answers
        self.command = command
    }

    static let keys: Set<String> = ["decision", "reason", "answers", "command"]

    public func encodedLine() throws -> Data {
        var fields: [String: WireJSON] = ["decision": .string(decision.rawValue), "reason": .string(reason)]
        if let answers { fields["answers"] = .object(answers) }
        if let command { fields["command"] = .string(command) }
        return try HookWire.line(.object(fields))
    }

    public static func decode(line: Data) throws -> HookResponse {
        let fields = try HookWire.object(fromLine: line, allowed: keys)
        guard let raw = fields["decision"]?.stringValue, let decision = HookDecision(rawValue: raw) else { throw WireError.malformed }
        guard let reason = fields["reason"]?.stringValue else { throw WireError.missingField }
        var answers: [String: WireJSON]?
        if let value = fields["answers"] {
            guard let object = value.objectValue else { throw WireError.malformed }
            answers = object
        }
        var command: String?
        if let value = fields["command"] {
            guard let text = value.stringValue else { throw WireError.malformed }
            command = text
        }
        return HookResponse(decision: decision, reason: reason, answers: answers, command: command)
    }
}
#endif
