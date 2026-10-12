import Foundation

// 에이전트 adapter · Mac bridge 계약 (0.2.0 A2, 아키텍처 8 · 9장 · 런타임 계약 5장). `src/lib/api/contract.ts`의
// agentCapabilitySchema · agentEventEnvelopeSchema · agentTaskStateSchema · bridge*Schema와 같은 이름 · 모양이다 (JSON 키는 snake_case).
// 아직 이 타입을 쓰는 코드는 없다 (bridge는 D2, Claude Code adapter는 D3).
// 서버 · bridge가 새 값을 더해도 깨지지 않게 모르는 문자열 값은 `.unknown(raw)`로 받고, 다시 보낼 때는 받은 문자열 그대로 보낸다.
// 시각은 ISO 8601 문자열로 주고받는다 (디코더 설정과 상관없이 `PostgresTimestamp`로 읽는다).

/// 모르는 값을 `.unknown(raw)`로 받는 문자열 값 (`ConnectionCallback.Status`와 같은 방식). 인코딩은 원래 문자열 그대로.
public protocol OpenStringValue: Codable, Hashable, Sendable {
    init(raw: String)
    var raw: String { get }
}

extension OpenStringValue {
    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - capability 서술자

/// adapter와 주고받는 길 (`transport`)
public enum AgentTransport: OpenStringValue {
    case remoteAPI, localBridge
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "remote_api": self = .remoteAPI
        case "local_bridge": self = .localBridge
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .remoteAPI: "remote_api"
        case .localBridge: "local_bridge"
        case .unknown(let raw): raw
        }
    }
}

/// 접수 확인의 깊이 (`dispatch.ack_level`): transport(전송 접수) · agent(에이전트가 받음)
public enum AgentAckLevel: OpenStringValue {
    case transport, agent
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "transport": self = .transport
        case "agent": self = .agent
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .transport: "transport"
        case .agent: "agent"
        case .unknown(let raw): raw
        }
    }
}

/// 진행 · 질문 · 결과를 받는 방식 (`events`). `none`은 Optional과 헷갈리지 않게 `.noEvents`
public enum AgentEventsMode: OpenStringValue {
    case push, poll, noEvents
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "push": self = .push
        case "poll": self = .poll
        case "none": self = .noEvents
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .push: "push"
        case .poll: "poll"
        case .noEvents: "none"
        case .unknown(let raw): raw
        }
    }
}

/// 중단 (`cancel`): confirmed(확인되는 중단) · requested_only(요청만, 확인 전 중단 성공으로 보이지 않는다) · unsupported
public enum AgentCancelSupport: OpenStringValue {
    case confirmed, requestedOnly, unsupported
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "confirmed": self = .confirmed
        case "requested_only": self = .requestedOnly
        case "unsupported": self = .unsupported
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .confirmed: "confirmed"
        case .requestedOnly: "requested_only"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

/// 끊긴 뒤 이어 가기 (`resume`)
public enum AgentResumeSupport: OpenStringValue {
    case supported, unsupported
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "supported": self = .supported
        case "unsupported": self = .unsupported
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .supported: "supported"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

/// 외부 비용을 볼 수 있는가 (`cost`). 계약 값 "unknown"(비용을 알 수 없음)은 `.notObservable`이다:
/// 모름은 0이 아니다 (화면은 "Not shared"). `.unknown(raw)`는 이 앱이 모르는 새 값이다
public enum AgentCostVisibility: OpenStringValue {
    case observable, estimated, notObservable
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "observable": self = .observable
        case "estimated": self = .estimated
        case "unknown": self = .notObservable
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .observable: "observable"
        case .estimated: "estimated"
        case .notObservable: "unknown"
        case .unknown(let raw): raw
        }
    }
}

/// 산출물 종류 (`artifacts[]`)
public enum AgentArtifactKind: OpenStringValue {
    case files, diff, url, text
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "files": self = .files
        case "diff": self = .diff
        case "url": self = .url
        case "text": self = .text
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .files: "files"
        case .diff: "diff"
        case .url: "url"
        case .text: "text"
        case .unknown(let raw): raw
        }
    }
}

/// 권한 경계 하나 (contract.ts `boundarySchema`). verified는 통제 테스트에서 실제로 막힘을 본 것만 true.
/// channel이 없으면 null로 보낸다(키를 빼지 않는다), evidence가 없으면 키를 뺀다
public struct AgentBoundary: Codable, Hashable, Sendable {
    public let channel: String?
    public let verified: Bool
    public let evidence: String?

    public init(channel: String?, verified: Bool, evidence: String? = nil) {
        self.channel = channel
        self.verified = verified
        self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case channel, verified, evidence
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        verified = try c.decode(Bool.self, forKey: .verified)
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channel, forKey: .channel)
        try c.encode(verified, forKey: .verified)
        try c.encodeIfPresent(evidence, forKey: .evidence)
    }
}

/// adapter capability 서술자 (contract.ts `agentCapabilitySchema`). bridge가 등록할 때 보낸다.
/// 쓰기는 동작 × 모드의 경계(approval_gate · target_scope · revocation)가 모두 verified일 때만 서버가 켠다 (I05). 앱은 판단하지 않는다
public struct AgentCapability: Codable, Hashable, Sendable {
    public struct Session: Codable, Hashable, Sendable {
        public let list: Bool
        public let attachExisting: Bool
        public let create: Bool
        public let workspaceScoped: Bool

        public init(list: Bool, attachExisting: Bool, create: Bool, workspaceScoped: Bool) {
            self.list = list
            self.attachExisting = attachExisting
            self.create = create
            self.workspaceScoped = workspaceScoped
        }

        enum CodingKeys: String, CodingKey {
            case list, create
            case attachExisting = "attach_existing"
            case workspaceScoped = "workspace_scoped"
        }
    }

    public struct Dispatch: Codable, Hashable, Sendable {
        public let ackLevel: AgentAckLevel
        public let maxInstructionChars: Int

        public init(ackLevel: AgentAckLevel, maxInstructionChars: Int) {
            self.ackLevel = ackLevel
            self.maxInstructionChars = maxInstructionChars
        }

        enum CodingKeys: String, CodingKey {
            case ackLevel = "ack_level"
            case maxInstructionChars = "max_instruction_chars"
        }
    }

    public struct Question: Codable, Hashable, Sendable {
        public let receive: Bool
        public let answer: Bool

        public init(receive: Bool, answer: Bool) {
            self.receive = receive
            self.answer = answer
        }
    }

    public struct Enforcement: Codable, Hashable, Sendable {
        public let approvalGate: AgentBoundary
        public let targetScope: AgentBoundary
        public let revocation: AgentBoundary
        public let budget: AgentBoundary

        public init(approvalGate: AgentBoundary, targetScope: AgentBoundary, revocation: AgentBoundary, budget: AgentBoundary) {
            self.approvalGate = approvalGate
            self.targetScope = targetScope
            self.revocation = revocation
            self.budget = budget
        }

        enum CodingKeys: String, CodingKey {
            case revocation, budget
            case approvalGate = "approval_gate"
            case targetScope = "target_scope"
        }
    }

    /// "agent:<이름>" (예: agent:claude-code)
    public let adapter: String
    public let transport: AgentTransport
    public let session: Session
    public let dispatch: Dispatch
    public let events: AgentEventsMode
    public let question: Question
    public let cancel: AgentCancelSupport
    public let resume: AgentResumeSupport
    public let enforcement: Enforcement
    public let cost: AgentCostVisibility
    public let artifacts: [AgentArtifactKind]

    public init(
        adapter: String, transport: AgentTransport, session: Session, dispatch: Dispatch, events: AgentEventsMode, question: Question,
        cancel: AgentCancelSupport, resume: AgentResumeSupport, enforcement: Enforcement, cost: AgentCostVisibility, artifacts: [AgentArtifactKind]
    ) {
        self.adapter = adapter
        self.transport = transport
        self.session = session
        self.dispatch = dispatch
        self.events = events
        self.question = question
        self.cancel = cancel
        self.resume = resume
        self.enforcement = enforcement
        self.cost = cost
        self.artifacts = artifacts
    }
}

// MARK: - 사건 봉투 · 원격 작업

/// 사건 종류 (contract.ts `agentEventTypeSchema`). unsupported: bridge가 모르는 명령 kind를 받았다 (서버는 run needs_capability)
public enum AgentEventType: OpenStringValue {
    case accepted, progress, question, artifact, completed, failed, cancelled, unreachable, reconcile, unsupported
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "accepted": self = .accepted
        case "progress": self = .progress
        case "question": self = .question
        case "artifact": self = .artifact
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "unreachable": self = .unreachable
        case "reconcile": self = .reconcile
        case "unsupported": self = .unsupported
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .accepted: "accepted"
        case .progress: "progress"
        case .question: "question"
        case .artifact: "artifact"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unreachable: "unreachable"
        case .reconcile: "reconcile"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

/// 사건 봉투 (contract.ts `agentEventEnvelopeSchema`). bridge → 서버. (bridge, event_id)로 한 번만 적용된다.
/// payload에는 글을 담지 않는다 (질문 글 · 결과 글은 따로). 선택 값(seq · directive_version · result_revision)이 없으면 키를 뺀다
public struct AgentEventEnvelope: Codable, Hashable, Sendable {
    public let adapter: String
    public let sessionID: String
    public let externalTaskID: String
    public let eventID: String
    public let seq: Int?
    public let type: AgentEventType
    public let directiveVersion: Int?
    public let resultRevision: Int?
    public let payload: [String: JSONValue]
    public let observedAt: Date

    public init(
        adapter: String, sessionID: String, externalTaskID: String, eventID: String, seq: Int? = nil, type: AgentEventType,
        directiveVersion: Int? = nil, resultRevision: Int? = nil, payload: [String: JSONValue] = [:], observedAt: Date
    ) {
        self.adapter = adapter
        self.sessionID = sessionID
        self.externalTaskID = externalTaskID
        self.eventID = eventID
        self.seq = seq
        self.type = type
        self.directiveVersion = directiveVersion
        self.resultRevision = resultRevision
        self.payload = payload
        self.observedAt = observedAt
    }

    enum CodingKeys: String, CodingKey {
        case adapter, seq, type, payload
        case sessionID = "session_id"
        case externalTaskID = "external_task_id"
        case eventID = "event_id"
        case directiveVersion = "directive_version"
        case resultRevision = "result_revision"
        case observedAt = "observed_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        adapter = try c.decode(String.self, forKey: .adapter)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        externalTaskID = try c.decode(String.self, forKey: .externalTaskID)
        eventID = try c.decode(String.self, forKey: .eventID)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        type = try c.decode(AgentEventType.self, forKey: .type)
        directiveVersion = try c.decodeIfPresent(Int.self, forKey: .directiveVersion)
        resultRevision = try c.decodeIfPresent(Int.self, forKey: .resultRevision)
        payload = try c.decode([String: JSONValue].self, forKey: .payload)
        observedAt = try BridgeTime.decode(c, .observedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(adapter, forKey: .adapter)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(externalTaskID, forKey: .externalTaskID)
        try c.encode(eventID, forKey: .eventID)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(directiveVersion, forKey: .directiveVersion)
        try c.encodeIfPresent(resultRevision, forKey: .resultRevision)
        try c.encode(payload, forKey: .payload)
        try c.encode(BridgeTime.string(observedAt), forKey: .observedAt)
    }
}

/// 원격 작업 상태 (`agent_tasks.state`). unreachable은 실패가 아니다 (재접속 reconcile을 기다린다)
public enum AgentTaskState: OpenStringValue {
    case dispatched, accepted, running, awaitingAnswer, completed, failed, cancelled, unreachable
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "dispatched": self = .dispatched
        case "accepted": self = .accepted
        case "running": self = .running
        case "awaiting_answer": self = .awaitingAnswer
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        case "unreachable": self = .unreachable
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .dispatched: "dispatched"
        case .accepted: "accepted"
        case .running: "running"
        case .awaitingAnswer: "awaiting_answer"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .unreachable: "unreachable"
        case .unknown(let raw): raw
        }
    }
}

// MARK: - bridge 명령 · 등록 · 사건 · heartbeat

/// 명령 종류 (`bridge_commands.kind`). 모르는 kind는 실행하지 않고 `.unsupported` 사건으로 답한다 (추측 실행 금지)
public enum BridgeCommandKind: OpenStringValue {
    case dispatch, message, cancel, reconcile, check
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "dispatch": self = .dispatch
        case "message": self = .message
        case "cancel": self = .cancel
        case "reconcile": self = .reconcile
        case "check": self = .check
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .dispatch: "dispatch"
        case .message: "message"
        case .cancel: "cancel"
        case .reconcile: "reconcile"
        case .check: "check"
        case .unknown(let raw): raw
        }
    }
}

/// 서버 → bridge 명령 (contract.ts `bridgeCommandSchema`). payload의 묶음은 고치지 않고 그대로 에이전트에 넣는다
public struct BridgeCommand: Decodable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let bridgeID: UUID
    public let kind: BridgeCommandKind
    public let payload: [String: JSONValue]
    public let leaseUntil: Date?
    public let ackedAt: Date?
    public let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, kind, payload
        case bridgeID = "bridge_id"
        case leaseUntil = "lease_until"
        case ackedAt = "acked_at"
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bridgeID = try c.decode(UUID.self, forKey: .bridgeID)
        kind = try c.decode(BridgeCommandKind.self, forKey: .kind)
        payload = try c.decode([String: JSONValue].self, forKey: .payload)
        leaseUntil = try BridgeTime.decodeIfPresent(c, .leaseUntil)
        ackedAt = try BridgeTime.decodeIfPresent(c, .ackedAt)
        createdAt = try BridgeTime.decode(c, .createdAt)
    }
}

/// GET /api/v1/bridge/commands 응답
public struct BridgeCommandsResponse: Decodable, Sendable {
    public let commands: [BridgeCommand]
}

/// POST /api/v1/bridge/register 본문: 기기당 하나
public struct BridgeRegisterRequest: Encodable, Hashable, Sendable {
    public let deviceID: String
    public let appVersion: String
    public let capabilities: [AgentCapability]

    public init(deviceID: String, appVersion: String, capabilities: [AgentCapability]) {
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case capabilities
        case deviceID = "device_id"
        case appVersion = "app_version"
    }
}

public struct BridgeRegisterResponse: Decodable, Hashable, Sendable {
    public let bridgeID: UUID
    public let heartbeatIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case bridgeID = "bridge_id"
        case heartbeatIntervalSeconds = "heartbeat_interval_seconds"
    }
}

/// POST /api/v1/bridge/events 본문 (outbox 재생 포함)
public struct BridgeEventsRequest: Encodable, Hashable, Sendable {
    public let bridgeID: UUID
    public let events: [AgentEventEnvelope]

    public init(bridgeID: UUID, events: [AgentEventEnvelope]) {
        self.bridgeID = bridgeID
        self.events = events
    }

    enum CodingKeys: String, CodingKey {
        case events
        case bridgeID = "bridge_id"
    }
}

/// 서버가 받은(이미 받은 것 포함) event_id. bridge는 이 사건을 outbox에서 지운다
public struct BridgeEventsResponse: Decodable, Hashable, Sendable {
    public let acceptedEventIDs: [String]

    enum CodingKeys: String, CodingKey {
        case acceptedEventIDs = "accepted_event_ids"
    }
}

/// POST /api/v1/bridge/heartbeat 본문 (30초마다). 살아 있는 작업마다 (task_id, process_alive, last_seq)
public struct BridgeHeartbeat: Codable, Hashable, Sendable {
    public struct TaskBeat: Codable, Hashable, Sendable {
        public let taskID: UUID
        public let processAlive: Bool
        public let lastSeq: Int

        public init(taskID: UUID, processAlive: Bool, lastSeq: Int) {
            self.taskID = taskID
            self.processAlive = processAlive
            self.lastSeq = lastSeq
        }

        enum CodingKeys: String, CodingKey {
            case taskID = "task_id"
            case processAlive = "process_alive"
            case lastSeq = "last_seq"
        }
    }

    public let bridgeID: UUID
    public let sentAt: Date
    public let tasks: [TaskBeat]

    public init(bridgeID: UUID, sentAt: Date, tasks: [TaskBeat]) {
        self.bridgeID = bridgeID
        self.sentAt = sentAt
        self.tasks = tasks
    }

    enum CodingKeys: String, CodingKey {
        case tasks
        case bridgeID = "bridge_id"
        case sentAt = "sent_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bridgeID = try c.decode(UUID.self, forKey: .bridgeID)
        sentAt = try BridgeTime.decode(c, .sentAt)
        tasks = try c.decode([TaskBeat].self, forKey: .tasks)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bridgeID, forKey: .bridgeID)
        try c.encode(BridgeTime.string(sentAt), forKey: .sentAt)
        try c.encode(tasks, forKey: .tasks)
    }
}

/// bridge 계약의 시각: 보낼 때는 UTC ISO 8601(밀리초, `Z`), 받을 때는 `PostgresTimestamp`가 읽는 모든 모양
enum BridgeTime {
    static func string(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
        let string = try c.decode(String.self, forKey: key)
        guard let date = PostgresTimestamp.parse(string) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "시각 형식이 아닙니다: \(string)")
        }
        return date
    }

    static func decodeIfPresent<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date? {
        guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
        return try decode(c, key)
    }
}
