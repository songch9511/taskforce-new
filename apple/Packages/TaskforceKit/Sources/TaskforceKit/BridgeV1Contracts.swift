import Foundation

// Mac bridge v1 계약의 Swift 짝 (OA D2b 계약 3장). `src/lib/api/contract.ts`의 `// --- D2a ---` 블록(`bridgeV1*Schema`)과 같은 이름 · 모양이다 (JSON 키는 snake_case).
// 옛 뼈대(`AgentBridgeContracts.swift`의 `AgentEventEnvelope` · `BridgeCommand` · `BridgeRegisterRequest` · `BridgeHeartbeat` 등)는 모양이 달라 쓰지 않는다.
//
// - **보낼 때는 엄격하다:** 서버 요청 스키마가 모두 strictObject다. 정해진 키만, optional은 값이 없으면 **키를 뺀다**, nullable은 `null`을 넣는다.
// - **받을 때는 너그럽다:** 모르는 키는 무시하고 모르는 문자열 값은 `.unknown(raw)`로 받는다 (`OpenStringValue`). 모르는 값으로 무엇을 할지는 런타임이 정한다 (계약 3.3).
// - 시각은 보낼 때 UTC ISO 8601(밀리초, `Z`), 받을 때는 `PostgresTimestamp`가 읽는 모든 모양 (디코더 설정과 상관없이).
// - 순수 Codable이라 플랫폼 조건이 없다. 실행하는 쪽(`Bridge/`)만 macOS다.

// MARK: - 열린 문자열 값

public enum BridgeV1ConnectionStatus: OpenStringValue {
    case active, error, revoked
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "active": self = .active
        case "error": self = .error
        case "revoked": self = .revoked
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .active: "active"
        case .error: "error"
        case .revoked: "revoked"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1RevokeCancel: OpenStringValue {
    case requestedOnly, confirmed
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "requested_only": self = .requestedOnly
        case "confirmed": self = .confirmed
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .requestedOnly: "requested_only"
        case .confirmed: "confirmed"
        case .unknown(let raw): raw
        }
    }
}

/// 명령 종류 (`bridge_commands.kind`). 모르는 값은 lease하지 않고 `decline`한다 (추측 실행 금지, 계약 2.6)
public enum BridgeV1CommandKind: OpenStringValue {
    case message, answer, cancel
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "message": self = .message
        case "answer": self = .answer
        case "cancel": self = .cancel
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .message: "message"
        case .answer: "answer"
        case .cancel: "cancel"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1Access: OpenStringValue {
    case write, readOnly
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "write": self = .write
        case "read_only": self = .readOnly
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .write: "write"
        case .readOnly: "read_only"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1PolicyMode: OpenStringValue {
    case manual, auto, full
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "manual": self = .manual
        case "auto": self = .auto
        case "full": self = .full
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .manual: "manual"
        case .auto: "auto"
        case .full: "full"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1QuestionKind: OpenStringValue {
    case input, approval
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "input": self = .input
        case "approval": self = .approval
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .input: "input"
        case .approval: "approval"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1CancelScope: OpenStringValue {
    case turn, turnAndProcesses
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "turn": self = .turn
        case "turn_and_processes": self = .turnAndProcesses
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .turn: "turn"
        case .turnAndProcesses: "turn_and_processes"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1WithdrawnReason: OpenStringValue {
    case writeGateClosed, adapterDisabled, notConnected, sessionClosed, sessionExternal, expired, actionClosed, staleAnswer, unsupported
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "write_gate_closed": self = .writeGateClosed
        case "adapter_disabled": self = .adapterDisabled
        case "not_connected": self = .notConnected
        case "session_closed": self = .sessionClosed
        case "session_external": self = .sessionExternal
        case "expired": self = .expired
        case "action_closed": self = .actionClosed
        case "stale_answer": self = .staleAnswer
        case "unsupported": self = .unsupported
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .writeGateClosed: "write_gate_closed"
        case .adapterDisabled: "adapter_disabled"
        case .notConnected: "not_connected"
        case .sessionClosed: "session_closed"
        case .sessionExternal: "session_external"
        case .expired: "expired"
        case .actionClosed: "action_closed"
        case .staleAnswer: "stale_answer"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1StaleReason: OpenStringValue {
    case notPrepared, heartbeatFirst, policyChanged, runClosed, wrongState, writeGateClosed
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "not_prepared": self = .notPrepared
        case "heartbeat_first": self = .heartbeatFirst
        case "policy_changed": self = .policyChanged
        case "run_closed": self = .runClosed
        case "wrong_state": self = .wrongState
        case "write_gate_closed": self = .writeGateClosed
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .notPrepared: "not_prepared"
        case .heartbeatFirst: "heartbeat_first"
        case .policyChanged: "policy_changed"
        case .runClosed: "run_closed"
        case .wrongState: "wrong_state"
        case .writeGateClosed: "write_gate_closed"
        case .unknown(let raw): raw
        }
    }
}

public enum BridgeV1EventResultStatus: OpenStringValue {
    case applied, duplicate, ignored, late, conflict, questionConflict, reconcileConflict, invalidState, stepNotCalling, notFound, wrongBridge
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "applied": self = .applied
        case "duplicate": self = .duplicate
        case "ignored": self = .ignored
        case "late": self = .late
        case "conflict": self = .conflict
        case "question_conflict": self = .questionConflict
        case "reconcile_conflict": self = .reconcileConflict
        case "invalid_state": self = .invalidState
        case "step_not_calling": self = .stepNotCalling
        case "not_found": self = .notFound
        case "wrong_bridge": self = .wrongBridge
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .applied: "applied"
        case .duplicate: "duplicate"
        case .ignored: "ignored"
        case .late: "late"
        case .conflict: "conflict"
        case .questionConflict: "question_conflict"
        case .reconcileConflict: "reconcile_conflict"
        case .invalidState: "invalid_state"
        case .stepNotCalling: "step_not_calling"
        case .notFound: "not_found"
        case .wrongBridge: "wrong_bridge"
        case .unknown(let raw): raw
        }
    }
}

// MARK: - 시각

/// 보내는 시각: UTC ISO 8601 밀리초. 밀리초 정수로 반올림한 뒤 글자로 만든다
/// (`Date`를 그대로 포맷하면 부동소수 오차로 `.123`이 `.122`로 잘린다)
enum BridgeV1Time {
    static func string(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Int64((Double(milliseconds) / 1000).rounded(.down))
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(Date.ISO8601FormatStyle())
        return String(whole.dropLast()) + String(format: ".%03dZ", Int(milliseconds - seconds * 1000))
    }
}

// MARK: - 등록 · 폐기

public enum BridgeV1SignedIn: String, Codable, Sendable {
    case yes, no, unknown
}

/// adapter 하나의 설치 · 로그인 보고. 권한 주장이 아니다 (서버가 등급을 따로 계산한다). `version`은 값이 없으면 `null`(키는 있어야 한다)
public struct BridgeV1AdapterReport: Codable, Equatable, Sendable {
    public var adapter: String
    public var installed: Bool
    public var version: String?
    public var signedIn: BridgeV1SignedIn
    public var managedSettings: Bool

    public init(adapter: String, installed: Bool, version: String?, signedIn: BridgeV1SignedIn, managedSettings: Bool) {
        self.adapter = adapter
        self.installed = installed
        self.version = version
        self.signedIn = signedIn
        self.managedSettings = managedSettings
    }

    enum CodingKeys: String, CodingKey {
        case adapter, installed, version
        case signedIn = "signed_in"
        case managedSettings = "managed_settings"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(adapter, forKey: .adapter)
        try c.encode(installed, forKey: .installed)
        if let version { try c.encode(version, forKey: .version) } else { try c.encodeNil(forKey: .version) }
        try c.encode(signedIn, forKey: .signedIn)
        try c.encode(managedSettings, forKey: .managedSettings)
    }
}

public struct BridgeV1RegisterRequest: Encodable, Equatable, Sendable {
    public var deviceID: String
    public var appVersion: String
    public var adapters: [BridgeV1AdapterReport]
    public var connect: [String]
    public var reactivate: Bool

    public init(deviceID: String, appVersion: String, adapters: [BridgeV1AdapterReport], connect: [String], reactivate: Bool) {
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.adapters = adapters
        self.connect = connect
        self.reactivate = reactivate
    }

    enum CodingKeys: String, CodingKey {
        case adapters, connect, reactivate
        case deviceID = "device_id"
        case appVersion = "app_version"
    }
}

public struct BridgeV1Connection: Decodable, Equatable, Sendable {
    public let connectionID: String
    public let adapter: String
    public let status: BridgeV1ConnectionStatus

    enum CodingKeys: String, CodingKey {
        case adapter, status
        case connectionID = "connection_id"
    }
}

/// 서버가 준 숫자를 쓰기 전에 범위를 자른다 (OA D2b 검토 반영 7장 C10): 서버 값은 신뢰 경계 밖이라 극값이 `Int(Double)` 변환 같은 곳에서 앱을 죽이거나
/// 대기를 영원히 늘리지 않게 한다. 서버 약속은 30 · 90 · 25이고 이 범위는 그 둘레다
public enum BridgeV1Clamp {
    public static let heartbeatSeconds: ClosedRange<Int> = 5...3600
    public static let unreachableSeconds: ClosedRange<Int> = 30...3600
    public static let longPollSeconds: ClosedRange<Int> = 1...25

    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
}

public struct BridgeV1RegisterResponse: Decodable, Equatable, Sendable {
    public let bridgeID: String
    public let bridgeSecret: String
    public let heartbeatIntervalSeconds: Int
    public let unreachableAfterSeconds: Int
    public let longPollMaxSeconds: Int
    public let connections: [BridgeV1Connection]

    enum CodingKeys: String, CodingKey {
        case connections
        case bridgeID = "bridge_id"
        case bridgeSecret = "bridge_secret"
        case heartbeatIntervalSeconds = "heartbeat_interval_seconds"
        case unreachableAfterSeconds = "unreachable_after_seconds"
        case longPollMaxSeconds = "long_poll_max_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bridgeID = try c.decode(String.self, forKey: .bridgeID)
        bridgeSecret = try c.decode(String.self, forKey: .bridgeSecret)
        heartbeatIntervalSeconds = BridgeV1Clamp.clamp(try c.decode(Int.self, forKey: .heartbeatIntervalSeconds), to: BridgeV1Clamp.heartbeatSeconds)
        unreachableAfterSeconds = BridgeV1Clamp.clamp(try c.decode(Int.self, forKey: .unreachableAfterSeconds), to: BridgeV1Clamp.unreachableSeconds)
        longPollMaxSeconds = BridgeV1Clamp.clamp(try c.decode(Int.self, forKey: .longPollMaxSeconds), to: BridgeV1Clamp.longPollSeconds)
        connections = try c.decode([BridgeV1Connection].self, forKey: .connections)
    }
}

public struct BridgeV1RevokeRequest: Encodable, Equatable, Sendable {
    public var bridgeID: String

    public init(bridgeID: String) {
        self.bridgeID = bridgeID
    }

    enum CodingKeys: String, CodingKey {
        case bridgeID = "bridge_id"
    }
}

public struct BridgeV1RevokedTask: Decodable, Equatable, Sendable {
    public let agentTaskID: String
    public let cancel: BridgeV1RevokeCancel
    /// `may_continue`: 프로세스가 아직 돌고 있을 수 있다 (종료를 확인하지 않았다)
    public let processes: String?

    enum CodingKeys: String, CodingKey {
        case cancel, processes
        case agentTaskID = "agent_task_id"
    }
}

public struct BridgeV1RevokeResponse: Decodable, Equatable, Sendable {
    public let status: String
    public let tasks: [BridgeV1RevokedTask]
}

// MARK: - 명령 목록

public struct BridgeV1CommandsQuery: Equatable, Sendable {
    public var bridgeID: String
    public var after: Int
    public var wait: Int

    public init(bridgeID: String, after: Int, wait: Int) {
        self.bridgeID = bridgeID
        self.after = after
        self.wait = wait
    }

    public var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "bridge_id", value: bridgeID),
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "wait", value: String(wait)),
        ]
    }
}

/// 목록의 명령 한 줄 (글 0). `kind`가 모르는 값이어도 목록 전체가 깨지지 않는다
public struct BridgeV1CommandListItem: Decodable, Equatable, Sendable {
    public let id: String
    public let cursor: Int
    public let kind: BridgeV1CommandKind
    public let agentSessionID: String
    public let agentTaskID: String
    public let turnSeq: Int
    public let createdAt: Date
    public let leasedByMe: Bool

    enum CodingKeys: String, CodingKey {
        case id, cursor, kind
        case agentSessionID = "agent_session_id"
        case agentTaskID = "agent_task_id"
        case turnSeq = "turn_seq"
        case createdAt = "created_at"
        case leasedByMe = "leased_by_me"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cursor = try c.decode(Int.self, forKey: .cursor)
        kind = try c.decode(BridgeV1CommandKind.self, forKey: .kind)
        agentSessionID = try c.decode(String.self, forKey: .agentSessionID)
        agentTaskID = try c.decode(String.self, forKey: .agentTaskID)
        turnSeq = try c.decode(Int.self, forKey: .turnSeq)
        createdAt = try BridgeTime.decode(c, .createdAt)
        leasedByMe = try c.decode(Bool.self, forKey: .leasedByMe)
    }
}

/// 결과를 모르는 명령 (lease가 만료돼 `unknown_outcome`): bridge가 원장으로 답한다
public struct BridgeV1ReadbackItem: Decodable, Equatable, Sendable {
    public let commandID: String
    public let kind: BridgeV1CommandKind
    public let agentSessionID: String
    public let agentTaskID: String
    public let turnSeq: Int
    public let marker: String
    public let leasedAt: Date

    enum CodingKeys: String, CodingKey {
        case kind, marker
        case commandID = "command_id"
        case agentSessionID = "agent_session_id"
        case agentTaskID = "agent_task_id"
        case turnSeq = "turn_seq"
        case leasedAt = "leased_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commandID = try c.decode(String.self, forKey: .commandID)
        kind = try c.decode(BridgeV1CommandKind.self, forKey: .kind)
        agentSessionID = try c.decode(String.self, forKey: .agentSessionID)
        agentTaskID = try c.decode(String.self, forKey: .agentTaskID)
        turnSeq = try c.decode(Int.self, forKey: .turnSeq)
        marker = try c.decode(String.self, forKey: .marker)
        leasedAt = try BridgeTime.decode(c, .leasedAt)
    }
}

public struct BridgeV1CommandsResponse: Decodable, Equatable, Sendable {
    public let commands: [BridgeV1CommandListItem]
    public let readbacks: [BridgeV1ReadbackItem]
    public let nextCursor: Int
    public let serverTime: Date

    enum CodingKeys: String, CodingKey {
        case commands, readbacks
        case nextCursor = "next_cursor"
        case serverTime = "server_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commands = try c.decode([BridgeV1CommandListItem].self, forKey: .commands)
        readbacks = try c.decode([BridgeV1ReadbackItem].self, forKey: .readbacks)
        nextCursor = try c.decode(Int.self, forKey: .nextCursor)
        serverTime = try BridgeTime.decode(c, .serverTime)
    }
}

// MARK: - ack

public enum BridgeV1CompleteResult: String, Sendable {
    case sent
    case taskUnknown = "task_unknown"
}

public enum BridgeV1ReadbackResult: String, Sendable {
    case received
    case notReceived = "not_received"
    case unknown
}

public enum BridgeV1AckOp: Equatable, Sendable {
    case lease
    case complete(BridgeV1CompleteResult)
    /// `notReceived`는 앞 프로세스가 끝난 것을 확인했을 때만 (`processEnded: true`). 아니면 인코딩 자체를 거부한다 (계약 13.1)
    case readback(BridgeV1ReadbackResult, processEnded: Bool)
    case requestClosed
    case decline

    /// 로그 · 원장에 적는 이름 (op 문자열)
    public var name: String {
        switch self {
        case .lease: "lease"
        case .complete: "complete"
        case .readback: "readback"
        case .requestClosed: "request_closed"
        case .decline: "decline"
        }
    }

    /// 원장에 적는 결과 (`complete` · `readback`만)
    public var resultName: String? {
        switch self {
        case .complete(let result): result.rawValue
        case .readback(let result, _): result.rawValue
        case .lease, .requestClosed, .decline: nil
        }
    }
}

public struct BridgeV1AckRequest: Encodable, Equatable, Sendable {
    public var bridgeID: String
    public var commandID: String
    public var op: BridgeV1AckOp

    public init(bridgeID: String, commandID: String, op: BridgeV1AckOp) {
        self.bridgeID = bridgeID
        self.commandID = commandID
        self.op = op
    }

    enum CodingKeys: String, CodingKey {
        case op, result, reason
        case bridgeID = "bridge_id"
        case commandID = "command_id"
        case processEnded = "process_ended"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bridgeID, forKey: .bridgeID)
        try c.encode(commandID, forKey: .commandID)
        try c.encode(op.name, forKey: .op)
        switch op {
        case .lease, .requestClosed:
            break
        case .complete(let result):
            try c.encode(result.rawValue, forKey: .result)
        case .readback(let result, let processEnded):
            if result == .notReceived, !processEnded {
                throw EncodingError.invalidValue(
                    op, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "not_received는 프로세스가 끝났음을 확인한 뒤에만 보낼 수 있다")
                )
            }
            try c.encode(result.rawValue, forKey: .result)
            try c.encode(processEnded, forKey: .processEnded)
        case .decline:
            try c.encode("unsupported_kind", forKey: .reason)
        }
    }
}

// MARK: - 명령 payload (lease 응답 안)

public struct BridgeV1CommandSession: Decodable, Equatable, Sendable {
    public let externalSessionID: String?
    public let workspaceRef: String?
    public let resume: Bool

    public init(externalSessionID: String?, workspaceRef: String?, resume: Bool) {
        self.externalSessionID = externalSessionID
        self.workspaceRef = workspaceRef
        self.resume = resume
    }

    enum CodingKeys: String, CodingKey {
        case resume
        case externalSessionID = "external_session_id"
        case workspaceRef = "workspace_ref"
    }
}

/// 세 종류가 함께 가진 값. `marker`는 Codex가 `clientUserMessageId`로 보내 결과 확인(readback)에 쓴다
public struct BridgeV1CommandCommon: Decodable, Equatable, Sendable {
    public let id: String
    public let agentSessionID: String
    public let agentTaskID: String
    public let turnSeq: Int
    public let stepID: String
    public let adapter: String
    public let marker: String
    public let session: BridgeV1CommandSession

    enum CodingKeys: String, CodingKey {
        case id, adapter, marker, session
        case agentSessionID = "agent_session_id"
        case agentTaskID = "agent_task_id"
        case turnSeq = "turn_seq"
        case stepID = "step_id"
    }
}

public struct BridgeV1MessageCommand: Decodable, Equatable, Sendable {
    public let common: BridgeV1CommandCommon
    public let access: BridgeV1Access
    public let policyMode: BridgeV1PolicyMode
    public let messageID: String
    /// 사용자 메시지 글. 메모리로만 다룬다 (디스크 0, 로그 0)
    public let text: String
    public let closeBeforeRequestID: String?

    enum CodingKeys: String, CodingKey {
        case access, message
        case policyMode = "policy_mode"
        case closeBefore = "close_before"
    }

    enum MessageKeys: String, CodingKey {
        case id, text
    }

    enum CloseKeys: String, CodingKey {
        case providerRequestID = "provider_request_id"
    }

    public init(from decoder: Decoder) throws {
        common = try BridgeV1CommandCommon(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = try c.decode(BridgeV1Access.self, forKey: .access)
        policyMode = try c.decode(BridgeV1PolicyMode.self, forKey: .policyMode)
        let message = try c.nestedContainer(keyedBy: MessageKeys.self, forKey: .message)
        messageID = try message.decode(String.self, forKey: .id)
        text = try message.decode(String.self, forKey: .text)
        // `close_before` 키가 아예 없어도(옛 서버 · 없는 값) 디코딩한다
        let closeIsNull = c.contains(.closeBefore) ? try c.decodeNil(forKey: .closeBefore) : true
        if closeIsNull {
            closeBeforeRequestID = nil
        } else {
            closeBeforeRequestID = try c.nestedContainer(keyedBy: CloseKeys.self, forKey: .closeBefore).decode(String.self, forKey: .providerRequestID)
        }
    }
}

/// 질문 답의 값: 한 글자열 또는 글자열 목록 (다중 선택)
public enum BridgeV1AnswerValue: Codable, Equatable, Sendable {
    case one(String)
    case many([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(String.self) {
            self = .one(one)
        } else {
            self = .many(try c.decode([String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .one(let value): try c.encode(value)
        case .many(let values): try c.encode(values)
        }
    }
}

public struct BridgeV1AnswerCommand: Decodable, Equatable, Sendable {
    public let common: BridgeV1CommandCommon
    public let access: BridgeV1Access
    public let policyMode: BridgeV1PolicyMode
    public let providerRequestID: String
    public let questionKind: BridgeV1QuestionKind
    public let structured: Bool
    public let answers: [String: BridgeV1AnswerValue]?
    public let answerText: String?
    /// true면 값이 서버에 없다 (비밀값): 이 Mac의 메모리(`LocalSecretAnswers`)에서만 온다
    public let answeredLocally: Bool

    enum CodingKeys: String, CodingKey {
        case access, structured, answers
        case policyMode = "policy_mode"
        case providerRequestID = "provider_request_id"
        case questionKind = "question_kind"
        case answerText = "answer_text"
        case answeredLocally = "answered_locally"
    }

    public init(from decoder: Decoder) throws {
        common = try BridgeV1CommandCommon(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access = try c.decode(BridgeV1Access.self, forKey: .access)
        policyMode = try c.decode(BridgeV1PolicyMode.self, forKey: .policyMode)
        providerRequestID = try c.decode(String.self, forKey: .providerRequestID)
        questionKind = try c.decode(BridgeV1QuestionKind.self, forKey: .questionKind)
        structured = try c.decode(Bool.self, forKey: .structured)
        answers = try c.decodeIfPresent([String: BridgeV1AnswerValue].self, forKey: .answers)
        answerText = try c.decodeIfPresent(String.self, forKey: .answerText)
        answeredLocally = try c.decode(Bool.self, forKey: .answeredLocally)
    }
}

public struct BridgeV1CancelCommand: Decodable, Equatable, Sendable {
    public let common: BridgeV1CommandCommon
    public let abandonedRequestID: String?
    public let cancelScope: BridgeV1CancelScope

    enum CodingKeys: String, CodingKey {
        case abandonedRequestID = "abandoned_request_id"
        case cancelScope = "cancel_scope"
    }

    public init(from decoder: Decoder) throws {
        common = try BridgeV1CommandCommon(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        abandonedRequestID = try c.decodeIfPresent(String.self, forKey: .abandonedRequestID)
        cancelScope = try c.decode(BridgeV1CancelScope.self, forKey: .cancelScope)
    }
}

public enum BridgeV1CommandPayload: Decodable, Equatable, Sendable {
    case message(BridgeV1MessageCommand)
    case answer(BridgeV1AnswerCommand)
    case cancel(BridgeV1CancelCommand)
    /// 모르는 kind: 나머지 키는 읽지 않는다 (실행하지 않는다)
    case unsupported(kind: String)

    enum CodingKeys: String, CodingKey {
        case kind
    }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(BridgeV1CommandKind.self, forKey: .kind)
        switch kind {
        case .message: self = .message(try BridgeV1MessageCommand(from: decoder))
        case .answer: self = .answer(try BridgeV1AnswerCommand(from: decoder))
        case .cancel: self = .cancel(try BridgeV1CancelCommand(from: decoder))
        case .unknown(let raw): self = .unsupported(kind: raw)
        }
    }
}

public enum BridgeV1AckResponse: Decodable, Equatable, Sendable {
    case leased(command: BridgeV1CommandPayload, leaseExpiresAt: Date)
    case replay(command: BridgeV1CommandPayload, leaseExpiresAt: Date)
    case withdrawn(reason: BridgeV1WithdrawnReason)
    case stale(reason: BridgeV1StaleReason?)
    case settled(taskState: AgentTaskState?)
    /// 모르는 status: 효과를 만들지 않는 쪽으로 다룬다 (계약 3.3)
    case unknown(status: String)

    enum CodingKeys: String, CodingKey {
        case status, command, reason
        case leaseExpiresAt = "lease_expires_at"
        case taskState = "task_state"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let status = try c.decode(String.self, forKey: .status)
        switch status {
        case "leased", "replay":
            let command = try c.decode(BridgeV1CommandPayload.self, forKey: .command)
            let expires = try BridgeTime.decode(c, .leaseExpiresAt)
            self = status == "leased" ? .leased(command: command, leaseExpiresAt: expires) : .replay(command: command, leaseExpiresAt: expires)
        case "withdrawn":
            self = .withdrawn(reason: try c.decode(BridgeV1WithdrawnReason.self, forKey: .reason))
        case "stale":
            self = .stale(reason: try c.decodeIfPresent(BridgeV1StaleReason.self, forKey: .reason))
        case "settled":
            self = .settled(taskState: try c.decodeIfPresent(AgentTaskState.self, forKey: .taskState))
        default:
            self = .unknown(status: status)
        }
    }
}

// MARK: - 사건 (bridge → 서버)

/// 질문 한 항목의 전송 모양. 길이 상한에 맞추는 일은 `Outbox`가 한다 (계약 2.7)
public struct BridgeV1QuestionOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct BridgeV1QuestionItem: Codable, Equatable, Sendable {
    public var id: String
    public var header: String
    public var text: String
    public var options: [BridgeV1QuestionOption]
    public var multiSelect: Bool
    public var allowOther: Bool
    public var secret: Bool

    public init(id: String, header: String, text: String, options: [BridgeV1QuestionOption], multiSelect: Bool, allowOther: Bool, secret: Bool) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
        self.allowOther = allowOther
        self.secret = secret
    }

    enum CodingKeys: String, CodingKey {
        case id, header, text, options, secret
        case multiSelect = "multi_select"
        case allowOther = "allow_other"
    }
}

public enum BridgeV1PendingQuestionKind: String, Codable, Sendable {
    case input, approval
}

public struct BridgeV1Question: Codable, Equatable, Sendable {
    public var providerRequestID: String
    public var kind: BridgeV1PendingQuestionKind
    public var structured: Bool
    public var questions: [BridgeV1QuestionItem]

    public init(providerRequestID: String, kind: BridgeV1PendingQuestionKind, structured: Bool, questions: [BridgeV1QuestionItem]) {
        self.providerRequestID = providerRequestID
        self.kind = kind
        self.structured = structured
        self.questions = questions
    }

    enum CodingKeys: String, CodingKey {
        case kind, structured, questions
        case providerRequestID = "provider_request_id"
    }
}

/// 접수 전 실패 이유 (사용자에게 정확한 원인이 간다, 계약 3.2)
public enum BridgeV1FailureReason: String, Codable, Sendable {
    case signInNeeded = "sign_in_needed"
    case usageLimited = "usage_limited"
    case spawnFailed = "spawn_failed"
    case versionUnsupported = "version_unsupported"
    case agentError = "agent_error"
}

public struct BridgeV1Event: Encodable, Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case accepted
        case progress
        case turnCompleted
        case cancelled
        case message(text: String)
        case question(text: String, BridgeV1Question)
        case artifact(path: String, hash: String, summary: String)
        case failed(BridgeV1FailureReason?)
        case sessionBound(externalSessionID: String, workspaceRef: String?)
        case reconcile(state: String?)
    }

    public var adapter: String
    public var sessionID: String
    public var taskID: String?
    public var externalTaskID: String?
    public var eventID: String
    public var seq: Int?
    public var turnSeq: Int?
    public var observedAt: Date
    public var body: Body

    public init(
        adapter: String, sessionID: String, taskID: String?, externalTaskID: String?, eventID: String, seq: Int?, turnSeq: Int?,
        observedAt: Date, body: Body
    ) {
        self.adapter = adapter
        self.sessionID = sessionID
        self.taskID = taskID
        self.externalTaskID = externalTaskID
        self.eventID = eventID
        self.seq = seq
        self.turnSeq = turnSeq
        self.observedAt = observedAt
        self.body = body
    }

    /// 서버 `type`
    public var typeName: String {
        switch body {
        case .accepted: "accepted"
        case .progress: "progress"
        case .turnCompleted: "turn_completed"
        case .cancelled: "cancelled"
        case .message: "message"
        case .question: "question"
        case .artifact: "artifact"
        case .failed: "failed"
        case .sessionBound: "session_bound"
        case .reconcile: "reconcile"
        }
    }

    enum CodingKeys: String, CodingKey {
        case adapter, seq, type, payload, text, question
        case sessionRef = "session_ref"
        case agentTaskID = "agent_task_id"
        case externalTaskID = "external_task_id"
        case eventID = "event_id"
        case turnSeq = "turn_seq"
        case observedAt = "observed_at"
    }

    private struct SessionRef: Encodable {
        let agentSessionID: String

        enum CodingKeys: String, CodingKey {
            case agentSessionID = "agent_session_id"
        }
    }

    private struct ArtifactPayload: Encodable {
        let path: String
        let hash: String
        let summary: String
    }

    private struct FailedPayload: Encodable {
        let reason: BridgeV1FailureReason
    }

    private struct SessionBoundPayload: Encodable {
        let externalSessionID: String
        let workspaceRef: String?

        enum CodingKeys: String, CodingKey {
            case externalSessionID = "external_session_id"
            case workspaceRef = "workspace_ref"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(externalSessionID, forKey: .externalSessionID)
            try c.encodeIfPresent(workspaceRef, forKey: .workspaceRef)
        }
    }

    private struct ReconcilePayload: Encodable {
        let state: String
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(adapter, forKey: .adapter)
        try c.encode(SessionRef(agentSessionID: sessionID), forKey: .sessionRef)
        try c.encodeIfPresent(taskID, forKey: .agentTaskID)
        try c.encodeIfPresent(externalTaskID, forKey: .externalTaskID)
        try c.encode(eventID, forKey: .eventID)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(turnSeq, forKey: .turnSeq)
        try c.encode(typeName, forKey: .type)
        switch body {
        case .accepted, .progress, .turnCompleted, .cancelled:
            break
        case .message(let text):
            try c.encode(text, forKey: .text)
        case .question(let text, let question):
            try c.encode(text, forKey: .text)
            try c.encode(question, forKey: .question)
        case .artifact(let path, let hash, let summary):
            try c.encode(ArtifactPayload(path: path, hash: hash, summary: summary), forKey: .payload)
        case .failed(let reason):
            if let reason { try c.encode(FailedPayload(reason: reason), forKey: .payload) }
        case .sessionBound(let externalSessionID, let workspaceRef):
            try c.encode(SessionBoundPayload(externalSessionID: externalSessionID, workspaceRef: workspaceRef), forKey: .payload)
        case .reconcile(let state):
            if let state { try c.encode(ReconcilePayload(state: state), forKey: .payload) }
        }
        try c.encode(BridgeV1Time.string(observedAt), forKey: .observedAt)
    }
}

/// `POST /bridge/events` 본문. 사건은 outbox에 JSON 글자열로 저장돼 있으므로 (저장한 그대로, 같은 event id로 다시 보낸다) 글자열을 이어 붙인다
public enum BridgeV1EventsRequest {
    public static func body(bridgeID: String, eventJSON: [String]) -> Data {
        let escaped = (try? JSONEncoder().encode(bridgeID)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return Data("{\"bridge_id\":\(escaped),\"events\":[\(eventJSON.joined(separator: ","))]}".utf8)
    }
}

public struct BridgeV1EventResult: Decodable, Equatable, Sendable {
    public let eventID: String
    public let status: BridgeV1EventResultStatus
    public let taskState: AgentTaskState?

    enum CodingKeys: String, CodingKey {
        case status
        case eventID = "event_id"
        case taskState = "task_state"
    }
}

public struct BridgeV1EventRejection: Decodable, Equatable, Sendable {
    public let eventID: String
    public let code: String

    public init(eventID: String, code: String) {
        self.eventID = eventID
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case code
        case eventID = "event_id"
    }
}

/// 세 목록이 권위다 (`results[].status`는 진단용)
public struct BridgeV1EventsResponse: Decodable, Equatable, Sendable {
    public let results: [BridgeV1EventResult]
    public let acceptedEventIDs: [String]
    public let retryEventIDs: [String]
    public let rejected: [BridgeV1EventRejection]

    enum CodingKeys: String, CodingKey {
        case results, rejected
        case acceptedEventIDs = "accepted_event_ids"
        case retryEventIDs = "retry_event_ids"
    }
}

// MARK: - heartbeat

public struct BridgeV1HeartbeatTask: Encodable, Equatable, Sendable {
    public var taskID: String
    public var processAlive: Bool
    /// 보낸 사건이 아직 없으면 `null` (키는 반드시 있다)
    public var lastSeq: Int?

    public init(taskID: String, processAlive: Bool, lastSeq: Int?) {
        self.taskID = taskID
        self.processAlive = processAlive
        self.lastSeq = lastSeq
    }

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case processAlive = "process_alive"
        case lastSeq = "last_seq"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(processAlive, forKey: .processAlive)
        if let lastSeq { try c.encode(lastSeq, forKey: .lastSeq) } else { try c.encodeNil(forKey: .lastSeq) }
    }
}

public struct BridgeV1HeartbeatRequest: Encodable, Equatable, Sendable {
    public var bridgeID: String
    public var sentAt: Date
    /// 시작 때만 (없으면 키를 뺀다)
    public var appVersion: String?
    public var tasks: [BridgeV1HeartbeatTask]
    /// 시작 때와 probe 결과가 바뀔 때만 (없으면 키를 뺀다)
    public var adapters: [BridgeV1AdapterReport]?

    public init(bridgeID: String, sentAt: Date, appVersion: String?, tasks: [BridgeV1HeartbeatTask], adapters: [BridgeV1AdapterReport]?) {
        self.bridgeID = bridgeID
        self.sentAt = sentAt
        self.appVersion = appVersion
        self.tasks = tasks
        self.adapters = adapters
    }

    enum CodingKeys: String, CodingKey {
        case tasks, adapters
        case bridgeID = "bridge_id"
        case sentAt = "sent_at"
        case appVersion = "app_version"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bridgeID, forKey: .bridgeID)
        try c.encode(BridgeV1Time.string(sentAt), forKey: .sentAt)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
        try c.encode(tasks, forKey: .tasks)
        try c.encodeIfPresent(adapters, forKey: .adapters)
    }
}

public struct BridgeV1HeartbeatResponse: Decodable, Equatable, Sendable {
    /// 5초 안의 두 번째 heartbeat: 서버가 지난 결과를 그대로 줬다. 성공이다
    public let throttled: Bool
    public let heartbeatIntervalSeconds: Int
    public let serverTime: Date
    public let pendingCommands: Int
    public let unknownTaskIDs: [String]
    public let missingTaskIDs: [String]

    enum CodingKeys: String, CodingKey {
        case throttled
        case heartbeatIntervalSeconds = "heartbeat_interval_seconds"
        case serverTime = "server_time"
        case pendingCommands = "pending_commands"
        case unknownTaskIDs = "unknown_task_ids"
        case missingTaskIDs = "missing_task_ids"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        throttled = try c.decodeIfPresent(Bool.self, forKey: .throttled) ?? false
        heartbeatIntervalSeconds = BridgeV1Clamp.clamp(try c.decode(Int.self, forKey: .heartbeatIntervalSeconds), to: BridgeV1Clamp.heartbeatSeconds)
        serverTime = try BridgeTime.decode(c, .serverTime)
        pendingCommands = try c.decode(Int.self, forKey: .pendingCommands)
        unknownTaskIDs = try c.decode([String].self, forKey: .unknownTaskIDs)
        missingTaskIDs = try c.decode([String].self, forKey: .missingTaskIDs)
    }
}
