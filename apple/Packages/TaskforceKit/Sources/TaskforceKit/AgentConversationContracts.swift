import Foundation

// 대화 API v2 확장의 Swift 모양 (OA D1d-m, Assistant 계약 v3 2–5장). 서버 `src/lib/api/contract.ts`의 `// --- D1d ---` 블록과 같은 이름 · 모양이다
// (JSON 키는 snake_case, 시험 픽스처는 서버 `src/lib/agents/conversation-contract.test.ts`의 `AGENT_CONVERSATION_*` 상수와 같은 JSON).
// 이 파일은 모양만 둔다: 요청 함수는 `AgentConversationEndpoints.swift`, 화면 규칙(전달 상태 문구 · 대상 상태 단어)은 쓰는 쪽이 정한다.
// 서버가 새 값을 더해도 깨지지 않게 모르는 문자열 값은 `.unknown(raw)`로 받고 다시 보낼 때는 받은 문자열 그대로 보낸다 (`OpenStringValue`).
// 계약 값 `"unknown"`(전달 결과 불명)은 이 앱이 모르는 값(`.unknown(raw)`)과 섞지 않는다: `outcomeUnknown`이다 (`AgentCostVisibility`와 같은 방식).

// MARK: - 대상

/// 대화 대상의 종류 (`target_kind`). 모르는 종류는 `.unknown(raw)`
public enum ChatTargetKind: OpenStringValue {
    case taskforce, agent
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "taskforce": self = .taskforce
        case "agent": self = .agent
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .taskforce: "taskforce"
        case .agent: "agent"
        case .unknown(let raw): raw
        }
    }
}

/// 대화 만들기 요청의 대상 (`target`, 계약 3.1): 만든 뒤 바뀌지 않는다. agent는 내 에이전트 연결이 필수이고 세션은 선택(같은 연결의 세션)
public enum ChatTarget: Encodable, Hashable, Sendable {
    case taskforce
    case agent(connectionID: UUID, sessionID: UUID? = nil)

    enum CodingKeys: String, CodingKey {
        case kind
        case connectionID = "connection_id"
        case sessionID = "session_id"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .taskforce:
            try c.encode("taskforce", forKey: .kind)
        case .agent(let connectionID, let sessionID):
            try c.encode("agent", forKey: .kind)
            try c.encode(connectionID.lowercased, forKey: .connectionID)
            try c.encodeIfPresent(sessionID?.lowercased, forKey: .sessionID)
        }
    }
}

/// 대화 행의 대상 열 (`target_kind` · `agent_connection_id` · `agent_session_id`): 만들기 응답과 RLS로 읽은 `conversations` 행이 같다.
/// taskforce는 연결 · 세션이 null이다. 열이 없는 옛 행은 `.taskforce`로 읽는다
public struct ChatConversationTarget: Decodable, Sendable, Hashable {
    public let kind: ChatTargetKind
    public let agentConnectionID: UUID?
    public let agentSessionID: UUID?

    public static let taskforce = ChatConversationTarget(kind: .taskforce)

    enum CodingKeys: String, CodingKey {
        case kind = "target_kind"
        case agentConnectionID = "agent_connection_id"
        case agentSessionID = "agent_session_id"
    }

    public init(kind: ChatTargetKind, agentConnectionID: UUID? = nil, agentSessionID: UUID? = nil) {
        self.kind = kind
        self.agentConnectionID = agentConnectionID
        self.agentSessionID = agentSessionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(ChatTargetKind.self, forKey: .kind) ?? .taskforce
        agentConnectionID = try c.decodeIfPresent(UUID.self, forKey: .agentConnectionID)
        agentSessionID = try c.decodeIfPresent(UUID.self, forKey: .agentSessionID)
    }

    public var isAgent: Bool { kind == .agent }
}

/// `POST /api/v2/conversations` 201 · 200: 기존 대화 행 + 대상 열
public struct ChatCreatedConversation: Decodable, Sendable, Hashable {
    public let conversation: ChatConversation
    public let target: ChatConversationTarget

    enum CodingKeys: String, CodingKey {
        case conversation
    }

    public init(conversation: ChatConversation, target: ChatConversationTarget) {
        self.conversation = conversation
        self.target = target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversation = try c.decode(ChatConversation.self, forKey: .conversation)
        target = try c.decode(ChatConversationTarget.self, forKey: .conversation)
    }
}

// MARK: - 맥락 칩 (계약 2.1 · 2.2)

/// 칩이 가리키는 것의 종류
public enum ChatAttachmentKind: OpenStringValue {
    case action, context, agentSession, run, artifact, source
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "action": self = .action
        case "context": self = .context
        case "agent_session": self = .agentSession
        case "run": self = .run
        case "artifact": self = .artifact
        case "source": self = .source
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .action: "action"
        case .context: "context"
        case .agentSession: "agent_session"
        case .run: "run"
        case .artifact: "artifact"
        case .source: "source"
        case .unknown(let raw): raw
        }
    }
}

/// auto = 패널에 열린 항목(점선 칩, 에이전트로는 보내지 않는다) · added = Ask · 끌어다 놓기 · 첨부
public enum ChatAttachmentOrigin: OpenStringValue {
    case auto, added
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "auto": self = .auto
        case "added": self = .added
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .auto: "auto"
        case .added: "added"
        case .unknown(let raw): raw
        }
    }
}

/// 메시지에 붙는 맥락 칩 하나 (`attachments[]`, 한 메시지에 20개까지). `id`는 소문자 문자열로 보낸다
/// (Action id는 버전 비트가 없는 결정적 id일 수 있다: 형식만 맞으면 받는다)
public struct ChatAttachment: Codable, Sendable, Hashable {
    public let kind: ChatAttachmentKind
    public let id: UUID
    public let origin: ChatAttachmentOrigin

    public static let maxPerMessage = 20

    enum CodingKeys: String, CodingKey {
        case kind, id, origin
    }

    public init(kind: ChatAttachmentKind, id: UUID, origin: ChatAttachmentOrigin) {
        self.kind = kind
        self.id = id
        self.origin = origin
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id.lowercased, forKey: .id)
        try c.encode(origin, forKey: .origin)
    }
}

// MARK: - 전달 표시 (계약 2.4 · 3.2)

/// 에이전트 대상 메시지의 전달 상태. answered ~ cancelled는 메시지 열(또는 답 글), sent · accepted · outcomeUnknown은 dispatched 뒤 전달 단계에서 서버가 계산한다.
/// 계약 값 `"unknown"`은 `outcomeUnknown`(결과 불명)이다. 앱이 모르는 새 값만 `.unknown(raw)`다
public enum AgentDeliveryState: OpenStringValue {
    case answered, queued, needsReferent, notSent, expired, cancelled, sent, accepted
    case outcomeUnknown
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "answered": self = .answered
        case "queued": self = .queued
        case "needs_referent": self = .needsReferent
        case "not_sent": self = .notSent
        case "expired": self = .expired
        case "cancelled": self = .cancelled
        case "sent": self = .sent
        case "accepted": self = .accepted
        case "unknown": self = .outcomeUnknown
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .answered: "answered"
        case .queued: "queued"
        case .needsReferent: "needs_referent"
        case .notSent: "not_sent"
        case .expired: "expired"
        case .cancelled: "cancelled"
        case .sent: "sent"
        case .accepted: "accepted"
        case .outcomeUnknown: "unknown"
        case .unknown(let raw): raw
        }
    }
}

/// 전달 상태의 이유 코드: 계약 2.4의 아홉 + SQL이 실제로 쓰는 여덟 (OD-12). 문구는 쓰는 쪽(D4a)이 정한다
public enum AgentDeliveryReason: OpenStringValue {
    case notConnected, signInNeeded, unsupported, writeGateClosed, sessionExternal, versionUnsupported, usageLimited, spawnFailed, notReceived
    case sessionBusy, liveLimit, queueOrder, sessionClosed, invalidReferent, notFound, alreadyDispatched, questionOpen
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "not_connected": self = .notConnected
        case "sign_in_needed": self = .signInNeeded
        case "unsupported": self = .unsupported
        case "write_gate_closed": self = .writeGateClosed
        case "session_external": self = .sessionExternal
        case "version_unsupported": self = .versionUnsupported
        case "usage_limited": self = .usageLimited
        case "spawn_failed": self = .spawnFailed
        case "not_received": self = .notReceived
        case "session_busy": self = .sessionBusy
        case "live_limit": self = .liveLimit
        case "queue_order": self = .queueOrder
        case "session_closed": self = .sessionClosed
        case "invalid_referent": self = .invalidReferent
        case "not_found": self = .notFound
        case "already_dispatched": self = .alreadyDispatched
        case "question_open": self = .questionOpen
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .notConnected: "not_connected"
        case .signInNeeded: "sign_in_needed"
        case .unsupported: "unsupported"
        case .writeGateClosed: "write_gate_closed"
        case .sessionExternal: "session_external"
        case .versionUnsupported: "version_unsupported"
        case .usageLimited: "usage_limited"
        case .spawnFailed: "spawn_failed"
        case .notReceived: "not_received"
        case .sessionBusy: "session_busy"
        case .liveLimit: "live_limit"
        case .queueOrder: "queue_order"
        case .sessionClosed: "session_closed"
        case .invalidReferent: "invalid_referent"
        case .notFound: "not_found"
        case .alreadyDispatched: "already_dispatched"
        case .questionOpen: "question_open"
        case .unknown(let raw): raw
        }
    }
}

/// `needs_referent`의 후보 Action (≤ 3)
public struct AgentReferentCandidate: Decodable, Sendable, Hashable {
    public let actionID: UUID
    public let title: String

    enum CodingKeys: String, CodingKey {
        case title
        case actionID = "action_id"
    }

    public init(actionID: UUID, title: String) {
        self.actionID = actionID
        self.title = title
    }
}

/// 서버가 계산한 전달 표시 (`delivery`). 빠진 후보는 빈 목록이다
public struct AgentDelivery: Decodable, Sendable, Hashable {
    public let state: AgentDeliveryState
    public let reason: AgentDeliveryReason?
    public let candidates: [AgentReferentCandidate]

    enum CodingKeys: String, CodingKey {
        case state, reason, candidates
    }

    public init(state: AgentDeliveryState, reason: AgentDeliveryReason? = nil, candidates: [AgentReferentCandidate] = []) {
        self.state = state
        self.reason = reason
        self.candidates = candidates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(AgentDeliveryState.self, forKey: .state)
        reason = try c.decodeIfPresent(AgentDeliveryReason.self, forKey: .reason)
        candidates = try c.decodeIfPresent([AgentReferentCandidate].self, forKey: .candidates) ?? []
    }
}

/// 보낼 때 빠진 칩 (`attachments_dropped[]`)
public struct AttachmentDropped: Decodable, Sendable, Hashable {
    public enum Reason: OpenStringValue {
        case deleted, accessLost, slackPurged
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "deleted": self = .deleted
            case "access_lost": self = .accessLost
            case "slack_purged": self = .slackPurged
            default: self = .unknown(raw)
            }
        }

        public var raw: String {
            switch self {
            case .deleted: "deleted"
            case .accessLost: "access_lost"
            case .slackPurged: "slack_purged"
            case .unknown(let raw): raw
            }
        }
    }

    public let kind: ChatAttachmentKind
    public let id: UUID
    public let reason: Reason

    public init(kind: ChatAttachmentKind, id: UUID, reason: Reason) {
        self.kind = kind
        self.id = id
        self.reason = reason
    }
}

/// 메시지 때문에 Taskforce가 만든 Action (`created_action`). 번호는 아직 없을 수 있다. id는 버전 비트가 없는 결정적 id일 수 있다
public struct AgentCreatedAction: Decodable, Sendable, Hashable {
    public let id: UUID
    public let number: Int?
    public let title: String
    public let contextID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, number, title
        case contextID = "context_id"
    }

    public init(id: UUID, number: Int?, title: String, contextID: UUID?) {
        self.id = id
        self.number = number
        self.title = title
        self.contextID = contextID
    }
}

/// 전달이 시작시킨 에이전트 작업 (`agent_task`)
public struct AgentTaskRef: Decodable, Sendable, Hashable {
    public let id: UUID
    public let state: AgentTaskState
    public let agentSessionID: UUID

    enum CodingKeys: String, CodingKey {
        case id, state
        case agentSessionID = "agent_session_id"
    }

    public init(id: UUID, state: AgentTaskState, agentSessionID: UUID) {
        self.id = id
        self.state = state
        self.agentSessionID = agentSessionID
    }
}

/// `POST /api/v2/conversations/{id}/messages` 200 · 에이전트 대상 (계약 2.4): `reply`는 null — 답은 비동기로 대화에 쓰인다 (3.5).
/// `message`는 기존 메시지 모양이다 (전달 열 `delivery_state` · `delivery_reason` · `delivery_expires_at`은 읽지 않는다: 화면은 `delivery`를 쓴다).
/// Taskforce 대상 응답은 이 모양이 아니라 기존 `ChatPostedMessage`다 (OD-7)
public struct AgentPostedMessage: Decodable, Sendable, Hashable {
    public let message: ChatMessage
    public let reply: ChatMessage?
    public let delivery: AgentDelivery
    public let attachmentsDropped: [AttachmentDropped]
    public let createdAction: AgentCreatedAction?
    public let agentTask: AgentTaskRef?

    enum CodingKeys: String, CodingKey {
        case message, reply, delivery
        case attachmentsDropped = "attachments_dropped"
        case createdAction = "created_action"
        case agentTask = "agent_task"
    }

    public init(
        message: ChatMessage, reply: ChatMessage? = nil, delivery: AgentDelivery, attachmentsDropped: [AttachmentDropped] = [],
        createdAction: AgentCreatedAction? = nil, agentTask: AgentTaskRef? = nil
    ) {
        self.message = message
        self.reply = reply
        self.delivery = delivery
        self.attachmentsDropped = attachmentsDropped
        self.createdAction = createdAction
        self.agentTask = agentTask
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(ChatMessage.self, forKey: .message)
        reply = try c.decodeIfPresent(ChatMessage.self, forKey: .reply)
        delivery = try c.decode(AgentDelivery.self, forKey: .delivery)
        attachmentsDropped = try c.decodeIfPresent([AttachmentDropped].self, forKey: .attachmentsDropped) ?? []
        createdAction = try c.decodeIfPresent(AgentCreatedAction.self, forKey: .createdAction)
        agentTask = try c.decodeIfPresent(AgentTaskRef.self, forKey: .agentTask)
    }
}

/// `GET /api/v2/conversations/{id}/delivery?since_seq=` (OD-13): 읽은 메시지의 전달 표시를 서버 계산으로
public struct ConversationDeliveryResponse: Decodable, Sendable, Hashable {
    public struct Entry: Decodable, Sendable, Hashable {
        public let messageID: UUID
        public let seq: Int
        public let delivery: AgentDelivery

        enum CodingKeys: String, CodingKey {
            case seq, delivery
            case messageID = "message_id"
        }

        public init(messageID: UUID, seq: Int, delivery: AgentDelivery) {
            self.messageID = messageID
            self.seq = seq
            self.delivery = delivery
        }
    }

    public let messages: [Entry]

    public init(messages: [Entry]) {
        self.messages = messages
    }
}

/// `POST /api/v2/conversations/{id}/deliver` (Send again) 요청: `message_ids`가 없으면 그 대화의 보류 · 만료 메시지 전부 (1–50개)
public struct AgentDeliverRequest: Encodable, Sendable, Hashable {
    public let messageIDs: [UUID]?

    enum CodingKeys: String, CodingKey {
        case messageIDs = "message_ids"
    }

    public init(messageIDs: [UUID]? = nil) {
        self.messageIDs = messageIDs
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(messageIDs?.map(\.lowercased), forKey: .messageIDs)
    }
}

/// Send again 응답의 항목. requeued = 다시 대기시켰다, skipped = 건너뛰었다 (not_eligible 상태가 아님 · not_found 이 대화의 것이 아님 · unknown_outcome 결과 불명).
/// not_found에는 delivery가 없다
public struct AgentDeliverResult: Decodable, Sendable, Hashable {
    public enum Result: OpenStringValue {
        case requeued, skipped
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "requeued": self = .requeued
            case "skipped": self = .skipped
            default: self = .unknown(raw)
            }
        }

        public var raw: String {
            switch self {
            case .requeued: "requeued"
            case .skipped: "skipped"
            case .unknown(let raw): raw
            }
        }
    }

    public enum SkippedReason: OpenStringValue {
        case notEligible, notFound, unknownOutcome
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "not_eligible": self = .notEligible
            case "not_found": self = .notFound
            case "unknown_outcome": self = .unknownOutcome
            default: self = .unknown(raw)
            }
        }

        public var raw: String {
            switch self {
            case .notEligible: "not_eligible"
            case .notFound: "not_found"
            case .unknownOutcome: "unknown_outcome"
            case .unknown(let raw): raw
            }
        }
    }

    public let messageID: UUID
    public let result: Result
    public let skippedReason: SkippedReason?
    public let delivery: AgentDelivery?

    enum CodingKeys: String, CodingKey {
        case result, delivery
        case messageID = "message_id"
        case skippedReason = "skipped_reason"
    }

    public init(messageID: UUID, result: Result, skippedReason: SkippedReason? = nil, delivery: AgentDelivery? = nil) {
        self.messageID = messageID
        self.result = result
        self.skippedReason = skippedReason
        self.delivery = delivery
    }
}

public struct AgentDeliverResponse: Decodable, Sendable, Hashable {
    public let messages: [AgentDeliverResult]

    public init(messages: [AgentDeliverResult]) {
        self.messages = messages
    }
}

/// `POST /api/v2/conversations/{id}/messages/{message_id}/referent` 요청: needs_referent 후보 중 하나
public struct AgentReferentRequest: Encodable, Sendable, Hashable {
    public let actionID: UUID

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
    }

    public init(actionID: UUID) {
        self.actionID = actionID
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actionID.lowercased, forKey: .actionID)
    }
}

// MARK: - 중단 · 세션 (계약 3.8 · 5장)

/// Stop 응답의 항목: 작업마다 취소 결과. `processes: may_continue`는 Codex처럼 턴만 끊는 adapter라 실행 중 명령이 남을 수 있다는 뜻이다
public struct AgentStopResult: Decodable, Sendable, Hashable {
    public enum Cancel: OpenStringValue {
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

    public enum Processes: OpenStringValue {
        case mayContinue
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "may_continue": self = .mayContinue
            default: self = .unknown(raw)
            }
        }

        public var raw: String {
            switch self {
            case .mayContinue: "may_continue"
            case .unknown(let raw): raw
            }
        }
    }

    public let agentTaskID: UUID
    public let cancel: Cancel
    public let processes: Processes?

    enum CodingKeys: String, CodingKey {
        case cancel, processes
        case agentTaskID = "agent_task_id"
    }

    public init(agentTaskID: UUID, cancel: Cancel, processes: Processes? = nil) {
        self.agentTaskID = agentTaskID
        self.cancel = cancel
        self.processes = processes
    }
}

public struct AgentStopResponse: Decodable, Sendable, Hashable {
    public let tasks: [AgentStopResult]

    public init(tasks: [AgentStopResult]) {
        self.tasks = tasks
    }
}

/// 에이전트 세션 한 줄 (`agent_sessions`의 앱 모양). 상태는 기존 `AgentSessionStatus`다
public struct AgentSessionRow: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let connectionID: UUID
    public let displayName: String
    public let status: AgentSessionStatus
    public let lastTurnSeq: Int
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status
        case connectionID = "connection_id"
        case displayName = "display_name"
        case lastTurnSeq = "last_turn_seq"
        case updatedAt = "updated_at"
    }

    public init(id: UUID, connectionID: UUID, displayName: String, status: AgentSessionStatus, lastTurnSeq: Int, updatedAt: Date) {
        self.id = id
        self.connectionID = connectionID
        self.displayName = displayName
        self.status = status
        self.lastTurnSeq = lastTurnSeq
        self.updatedAt = updatedAt
    }
}

public struct AgentSessionResponse: Decodable, Sendable, Hashable {
    public let session: AgentSessionRow

    public init(session: AgentSessionRow) {
        self.session = session
    }
}

/// Resume here 응답: 세션 + 이어서 시작한 첫 메시지 (없으면 null)
public struct AgentResumeResponse: Decodable, Sendable, Hashable {
    public let session: AgentSessionRow
    public let startedMessageID: UUID?

    enum CodingKeys: String, CodingKey {
        case session
        case startedMessageID = "started_message_id"
    }

    public init(session: AgentSessionRow, startedMessageID: UUID?) {
        self.session = session
        self.startedMessageID = startedMessageID
    }
}

// MARK: - 외부 세션 이어받기 (OA 외부 세션 PR2m, 서버 PR2s: `POST /api/v2/agent-sessions/attach`)

/// 이어받기 응답 `{ status, conversation_id, workspace_ref, session }` (서버 `attachAgentSessionResponseSchema`). 201 `created` · 200 `existing`(같은 Claude id가 이미 묶여 있다, 멱등).
/// `workspace_ref`는 **서버에 저장된 값**이다: `existing`은 다른 기기의 옛 값을 돌려줄 수 있어 앱이 보낸 값과 같은지 확인한다 (`AttachServerFacts`). 응답의 `session`에는 외부 세션 id가 없다 —
/// 그 값은 이 Mac이 RLS로 그 행을 읽어 대조한다
public struct AttachAgentSessionResponse: Decodable, Sendable, Hashable {
    public enum Status: String, Decodable, Sendable { case created, existing }

    public let status: Status
    public let conversationID: UUID
    public let workspaceRef: String
    public let session: AgentSessionRow

    enum CodingKeys: String, CodingKey {
        case status, session
        case conversationID = "conversation_id"
        case workspaceRef = "workspace_ref"
    }

    public init(status: Status, conversationID: UUID, workspaceRef: String, session: AgentSessionRow) {
        self.status = status
        self.conversationID = conversationID
        self.workspaceRef = workspaceRef
        self.session = session
    }
}

// MARK: - 대상 목록 (계약 4.5 · OD-20)

/// 에이전트 대상의 상태. `unreachable`(heartbeat 90초 넘음)과 `sign_in_needed`(D1d는 내지 않는다, D2a에서 온다)를 모두 읽는다
public enum AgentTargetState: OpenStringValue {
    case ready, notConnected, signInNeeded, unreachable, unsupported
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "ready": self = .ready
        case "not_connected": self = .notConnected
        case "sign_in_needed": self = .signInNeeded
        case "unreachable": self = .unreachable
        case "unsupported": self = .unsupported
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .ready: "ready"
        case .notConnected: "not_connected"
        case .signInNeeded: "sign_in_needed"
        case .unreachable: "unreachable"
        case .unsupported: "unsupported"
        case .unknown(let raw): raw
        }
    }
}

/// 지금 열려 있는 접근 등급 (`access`): write = 쓸 수 있다 · read_only = 읽기만 (그래도 메시지는 받는다)
public enum AgentAccessLevel: OpenStringValue {
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

/// `GET /api/v2/assistant/targets`의 한 행. 에이전트는 **연결**마다 한 행이다 (같은 adapter의 연결이 둘이면 행 둘, OD-20).
/// 모르는 kind는 목록 전체를 못 읽게 하지 않고 `.other(kind)`로 읽는다
public enum AssistantTarget: Decodable, Sendable, Hashable {
    case taskforce
    case agent(Agent)
    case other(String)

    public struct Agent: Sendable, Hashable {
        /// `agent:claude-code` · `agent:codex` 같은 adapter id (모르는 adapter도 그대로)
        public let adapter: String
        public let displayName: String
        /// 활성 연결이 없는 켜진 adapter는 null
        public let connectionID: UUID?
        public let state: AgentTargetState
        public let access: AgentAccessLevel?
        /// 이 연결을 돌리는 Mac의 bridge id (OA F1s: 서버가 연결의 `bridge_id`를 준다). 연결 없음 · bridge가 지워짐 · 옛 서버면 nil
        public let bridgeID: UUID?
        /// 그 Mac의 표시 이름 (OA F1s, 1–64 코드 포인트). 모르면(옛 Mac · 연결 없음 · 폐기 · 옛 서버) nil — 이름을 짐작하지 않는다
        public let deviceName: String?

        public init(
            adapter: String, displayName: String, connectionID: UUID?, state: AgentTargetState, access: AgentAccessLevel?,
            bridgeID: UUID? = nil, deviceName: String? = nil
        ) {
            self.adapter = adapter
            self.displayName = displayName
            self.connectionID = connectionID
            self.state = state
            self.access = access
            self.bridgeID = bridgeID
            self.deviceName = deviceName
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, adapter, state, access
        case displayName = "display_name"
        case connectionID = "connection_id"
        case bridgeID = "bridge_id"
        case deviceName = "device_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "taskforce":
            self = .taskforce
        case "agent":
            self = .agent(Agent(
                adapter: try c.decode(String.self, forKey: .adapter),
                displayName: try c.decode(String.self, forKey: .displayName),
                connectionID: try c.decodeIfPresent(UUID.self, forKey: .connectionID),
                state: try c.decode(AgentTargetState.self, forKey: .state),
                access: try c.decodeIfPresent(AgentAccessLevel.self, forKey: .access),
                // 옛 서버는 두 키를 주지 않는다 (decodeIfPresent). 새 서버도 모르면 null이다
                bridgeID: try c.decodeIfPresent(UUID.self, forKey: .bridgeID),
                deviceName: try c.decodeIfPresent(String.self, forKey: .deviceName)
            ))
        default:
            self = .other(kind)
        }
    }
}

public struct AssistantTargetsResponse: Decodable, Sendable, Hashable {
    public let targets: [AssistantTarget]

    public init(targets: [AssistantTarget]) {
        self.targets = targets
    }
}

// MARK: - 질문에 답하기 (계약 3.6)

/// 질문 하나의 답: 단일 글(2000자까지) 또는 선택지 배열(다중 선택, 10개까지)
public enum ConversationAnswerValue: Encodable, Sendable, Hashable {
    case text(String)
    case choices([String])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let value): try c.encode(value)
        case .choices(let values): try c.encode(values)
        }
    }
}

/// `POST /api/v2/agent-tasks/{id}/answer` 요청: 질문 id마다 답 하나
public struct AgentAnswerRequest: Encodable, Sendable, Hashable {
    public let providerRequestID: String
    public let answers: [String: ConversationAnswerValue]

    enum CodingKeys: String, CodingKey {
        case answers
        case providerRequestID = "provider_request_id"
    }

    public init(providerRequestID: String, answers: [String: ConversationAnswerValue]) {
        self.providerRequestID = providerRequestID
        self.answers = answers
    }
}

/// 답 응답: answered(처음) · duplicate(같은 답을 다시 보냄) + 닫힌 단계 id
public struct AgentAnswerResponse: Decodable, Sendable, Hashable {
    public enum Status: OpenStringValue {
        case answered, duplicate
        case unknown(String)

        public init(raw: String) {
            switch raw {
            case "answered": self = .answered
            case "duplicate": self = .duplicate
            default: self = .unknown(raw)
            }
        }

        public var raw: String {
            switch self {
            case .answered: "answered"
            case .duplicate: "duplicate"
            case .unknown(let raw): raw
            }
        }
    }

    public let status: Status
    public let stepID: UUID

    enum CodingKeys: String, CodingKey {
        case status
        case stepID = "step_id"
    }

    public init(status: Status, stepID: UUID) {
        self.status = status
        self.stepID = stepID
    }
}

// MARK: - 오류 코드

/// 대화 v2 에이전트 확장이 더하는 오류 코드 (`{"error":{"code","message"}}`의 code). `busy_retry`는 잠금 경합이 재시도를 넘긴 것: 쓰기 0이고 같은 요청을 다시 보내도 된다.
/// 기존 v2 코드(`conflict` · `not_found` …)는 `APIErrorCode`가 안다. 모르는 코드는 `.unknown(raw)`
public enum AgentConversationErrorCode: OpenStringValue {
    case targetMismatch, questionStale, secretRequiresLocal, sessionBusy, approvalViaReview, busyRetry
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "target_mismatch": self = .targetMismatch
        case "question_stale": self = .questionStale
        case "secret_requires_local": self = .secretRequiresLocal
        case "session_busy": self = .sessionBusy
        case "approval_via_review": self = .approvalViaReview
        case "busy_retry": self = .busyRetry
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .targetMismatch: "target_mismatch"
        case .questionStale: "question_stale"
        case .secretRequiresLocal: "secret_requires_local"
        case .sessionBusy: "session_busy"
        case .approvalViaReview: "approval_via_review"
        case .busyRetry: "busy_retry"
        case .unknown(let raw): raw
        }
    }
}

/// 오류 응답 본문에서 code를 그대로 읽는다. `APIError`는 모르는 코드를 상태 코드로 짐작해 버리므로(`409` → `conflict`) 새 코드가 필요한 곳은
/// 응답 본문을 이 모양으로 읽는다
public struct AgentConversationErrorBody: Decodable, Sendable, Hashable {
    public struct Detail: Decodable, Sendable, Hashable {
        public let code: AgentConversationErrorCode
        public let message: String
    }

    public let error: Detail

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    public var code: AgentConversationErrorCode { error.code }
}
