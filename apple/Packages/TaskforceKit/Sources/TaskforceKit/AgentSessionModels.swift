import Foundation

// OA U2: 에이전트 세션 읽기의 모양 (Mac이 RLS로 읽는 다섯 표, select만).
// 서버는 `agent_sessions` · `agent_tasks` · `execution_runs` · `agent_connections` · `conversations`를 `owner_all` + select grant로 준다
// (`20261113000000_agent_gateway_core.sql`). 아래 `columns`는 화면에 필요한 열만 적는다: 질문 글(`pending_question`)과 결과(`result_refs`)는 읽지 않는다.
// 세션 이름 · 대화 id는 사용자 글이라 메모리에만 두고 로그 · 디스크에 남기지 않는다.
// 모르는 상태 값은 `.unknown(raw)`로 읽는다 (실패로 만들지 않는다).

/// `agent_sessions` 행
public struct AgentSessionRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let connectionID: UUID
    /// 세션 이름 (서버가 첫 메시지 첫 줄 80자로 정하고 사용자가 바꾼다). 비어 있을 수 있다
    public let displayName: String
    public let status: AgentSessionStatus
    /// 첫 턴이 끝나기 전이다 (`external_session_id`가 `pending:<대화 id>`). Open in Terminal은 이때 서버가 409다
    public let isPendingFirstTurn: Bool
    public let lastTurnSeq: Int
    public let createdAt: Date
    public let updatedAt: Date

    public static let columns = "id, connection_id, display_name, status, external_session_id, last_turn_seq, created_at, updated_at"
    static let pendingPrefix = "pending:"

    enum CodingKeys: String, CodingKey {
        case id, status
        case connectionID = "connection_id"
        case displayName = "display_name"
        case externalSessionID = "external_session_id"
        case lastTurnSeq = "last_turn_seq"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: UUID, connectionID: UUID, displayName: String, status: AgentSessionStatus, isPendingFirstTurn: Bool = false, lastTurnSeq: Int,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.displayName = displayName
        self.status = status
        self.isPendingFirstTurn = isPendingFirstTurn
        self.lastTurnSeq = lastTurnSeq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        connectionID = try c.decode(UUID.self, forKey: .connectionID)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        status = AgentSessionStatus(raw: try c.decode(String.self, forKey: .status))
        // 값 자체는 보관하지 않는다: 첫 턴 전인지만 본다
        isPendingFirstTurn = ((try? c.decode(String.self, forKey: .externalSessionID)) ?? "").hasPrefix(Self.pendingPrefix)
        lastTurnSeq = try c.decode(Int.self, forKey: .lastTurnSeq)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// `agent_tasks` 행 (턴 하나). 질문 글 · 결과는 읽지 않는다
public struct AgentTaskRecord: Decodable, Sendable, Hashable {
    public let agentSessionID: UUID
    public let runID: UUID
    public let turnSeq: Int?
    public let state: AgentTaskState
    public let lastLiveState: AgentTaskState?
    public let cancelRequestedAt: Date?

    public static let columns = "agent_session_id, run_id, turn_seq, state, last_live_state, cancel_requested_at"

    enum CodingKeys: String, CodingKey {
        case state
        case agentSessionID = "agent_session_id"
        case runID = "run_id"
        case turnSeq = "turn_seq"
        case lastLiveState = "last_live_state"
        case cancelRequestedAt = "cancel_requested_at"
    }

    public init(
        agentSessionID: UUID, runID: UUID, turnSeq: Int?, state: AgentTaskState, lastLiveState: AgentTaskState? = nil, cancelRequestedAt: Date? = nil
    ) {
        self.agentSessionID = agentSessionID
        self.runID = runID
        self.turnSeq = turnSeq
        self.state = state
        self.lastLiveState = lastLiveState
        self.cancelRequestedAt = cancelRequestedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentSessionID = try c.decode(UUID.self, forKey: .agentSessionID)
        runID = try c.decode(UUID.self, forKey: .runID)
        turnSeq = try c.decodeIfPresent(Int.self, forKey: .turnSeq)
        state = AgentTaskState(raw: try c.decode(String.self, forKey: .state))
        lastLiveState = try c.decodeIfPresent(String.self, forKey: .lastLiveState).map(AgentTaskState.init(raw:))
        cancelRequestedAt = try c.decodeIfPresent(Date.self, forKey: .cancelRequestedAt)
    }

    /// 열린 task: 끝나지 않았다 (연결이 끊긴 것도 재접속을 기다리는 열린 일이다). idle · 끝 상태 · 모르는 값은 열리지 않았다
    public var isOpen: Bool {
        switch state {
        case .dispatched, .accepted, .running, .awaitingAnswer, .unreachable: true
        case .idle, .completed, .failed, .cancelled, .unknown: false
        }
    }
}

/// `execution_runs` 행 중 세션 ↔ 이슈를 잇는 것 (`kind = 'conversation'`). 기존 `RunSummary`는 바꾸지 않고 새 읽기로 둔다
public struct AgentSessionRunRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: String
    public let agentSessionID: UUID?
    public let actionID: UUID

    public static let columns = "id, kind, agent_session_id, action_id"
    public static let conversationKind = "conversation"

    enum CodingKeys: String, CodingKey {
        case id, kind
        case agentSessionID = "agent_session_id"
        case actionID = "action_id"
    }

    public init(id: UUID, kind: String = AgentSessionRunRecord.conversationKind, agentSessionID: UUID?, actionID: UUID) {
        self.id = id
        self.kind = kind
        self.agentSessionID = agentSessionID
        self.actionID = actionID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        agentSessionID = try c.decodeIfPresent(UUID.self, forKey: .agentSessionID)
        actionID = try c.decode(UUID.self, forKey: .actionID)
    }
}

/// `agent_connections` 행 중 에이전트 이름을 정하는 것
public struct AgentConnectionRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let adapter: String
    /// 이 연결을 돌리는 Mac의 bridge (OA D4a-03): 세션 머리의 알약(Open in Terminal · Resume here)은 이 값이 이 Mac의 bridge id와 같을 때만 보인다. 모르면 nil
    public let bridgeID: UUID?

    public static let columns = "id, adapter, bridge_id"

    enum CodingKeys: String, CodingKey {
        case id, adapter
        case bridgeID = "bridge_id"
    }

    public init(id: UUID, adapter: String, bridgeID: UUID? = nil) {
        self.id = id
        self.adapter = adapter
        self.bridgeID = bridgeID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        adapter = try c.decode(String.self, forKey: .adapter)
        bridgeID = try? c.decodeIfPresent(UUID.self, forKey: .bridgeID)
    }
}

/// `conversations` 행 중 세션에 이어진 대화. 한 세션에 대화가 여럿이면 읽은 순서(새 것이 먼저)에서 첫 것이 가장 새 대화다
public struct AgentSessionConversationRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let agentSessionID: UUID

    public static let columns = "id, agent_session_id"

    enum CodingKeys: String, CodingKey {
        case id
        case agentSessionID = "agent_session_id"
    }

    public init(id: UUID, agentSessionID: UUID) {
        self.id = id
        self.agentSessionID = agentSessionID
    }
}

/// 한 번 읽은 세션 상태 전부
public struct AgentSessionSnapshot: Sendable, Hashable {
    public var sessions: [AgentSessionRecord]
    /// 세션마다 마지막 턴(`turn_seq == last_turn_seq`)의 task. 더 많이 와도 규칙이 `turn_seq` 최대를 고른다
    public var tasks: [AgentTaskRecord]
    public var runs: [AgentSessionRunRecord]
    public var connections: [AgentConnectionRecord]
    /// 새 것이 먼저
    public var conversations: [AgentSessionConversationRecord]

    public static let empty = AgentSessionSnapshot(sessions: [], tasks: [], runs: [], connections: [], conversations: [])

    public init(
        sessions: [AgentSessionRecord], tasks: [AgentTaskRecord], runs: [AgentSessionRunRecord], connections: [AgentConnectionRecord],
        conversations: [AgentSessionConversationRecord]
    ) {
        self.sessions = sessions
        self.tasks = tasks
        self.runs = runs
        self.connections = connections
        self.conversations = conversations
    }
}

/// 링의 종류 (디자인 ActivityRing 7종). 앱의 링 부품(`ActivityRing.Kind`)이 이 값에 대응한다 — Kit은 그리지 않는다
public enum AgentSessionRing: String, Sendable, Hashable, CaseIterable {
    case needsYou, unreachable, stopping, running, done, waiting, idle

    /// 한 이슈의 링을 고르는 차례 (작을수록 먼저, U2-05): needs-you → unreachable → stopping → running → done → waiting. idle은 레일에 오르지 않는다
    public var issueRank: Int? {
        switch self {
        case .needsYou: 0
        case .unreachable: 1
        case .stopping: 2
        case .running: 3
        case .done: 4
        case .waiting: 5
        case .idle: nil
        }
    }

    /// 링의 말 (탭 항목 · 레일 접근성 이름, 디자인 SessionTab). idle은 "Idle"
    public var label: String {
        switch self {
        case .needsYou: "Needs your answer"
        case .unreachable: "Connection lost"
        case .stopping: "Stop requested"
        case .running: "Running"
        case .done: "Done just now"
        case .waiting: "Waiting"
        case .idle: "Idle"
        }
    }
}

/// 세션 패널 머리의 알약 하나 (Open in Terminal · Resume here). 동작은 D4a가 건다 — U2는 자리와 꺼진 이유만 정한다
public enum AgentSessionPill: Sendable, Hashable {
    /// 첫 턴 뒤의 `bound`: Open in Terminal. 턴이 돌거나 질문이 열려 있으면 꺼지고 이유를 툴팁으로 말한다
    case openInTerminal(disabledReason: String?)
    /// `external`: Resume here
    case resumeHere

    public var title: String {
        switch self {
        case .openInTerminal: "Open in Terminal"
        case .resumeHere: "Resume here"
        }
    }

    public var disabledReason: String? {
        if case .openInTerminal(let reason) = self { reason } else { nil }
    }

    public var isEnabled: Bool { disabledReason == nil }

    public static let turnRunning = "Turn is running"
    public static let answerFirst = "Answer the question first"
}

/// 화면이 쓰는 세션 하나 (읽은 값에서 규칙으로 정한 것)
public struct AgentSessionItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    /// 세션 이름: `display_name`, 비었으면 에이전트 이름
    public let name: String
    public let agent: AgentMarkKind
    public let agentName: String
    public let connectionID: UUID
    public let status: AgentSessionStatus
    /// 링. 닫힌 세션은 링이 없다 (탭 · 레일에 없다)
    public let ring: AgentSessionRing?
    /// 상태 줄 · SessionRow 말 (2.5 표). 끝난(`closed`) 세션은 빈 글이다: 상태 말 없이 흐리게 그린다
    public let line: String
    public let createdAt: Date
    public let updatedAt: Date
    /// 이 세션이 일한 이슈 전부 (대화 run의 `action_id`, 처음 만든 차례)
    public let issueIDs: [UUID]
    /// 머리의 "— #139": 마지막 턴의 run이 가리키는 이슈. 하나로 정해지지 않으면 nil
    public let currentIssueID: UUID?
    /// 이 세션의 대화 (여럿이면 가장 새 것). 패널 Composer가 여기로 보낸다
    public let conversationID: UUID?
    /// 열린 task가 있다 (다시 읽기가 5초마다 도는 이유)
    public let hasOpenTask: Bool
    public let pill: AgentSessionPill?
    /// 이 세션 연결을 돌리는 Mac의 bridge id (OA D4a-03, 알약은 그 Mac에서만 보인다). 모르면 nil
    public let connectionBridgeID: UUID?
    /// 마지막 턴의 task 상태 · 그 task에 Stop 요청이 있다 · 세션의 마지막 턴 번호 (OA D4a-13: Stop 원 · "Stop requested" · "may continue")
    public let lastTaskState: AgentTaskState?
    public let cancelRequested: Bool
    public let turnSeq: Int

    public init(
        id: UUID, name: String, agent: AgentMarkKind, agentName: String, connectionID: UUID, status: AgentSessionStatus, ring: AgentSessionRing?,
        line: String, createdAt: Date, updatedAt: Date, issueIDs: [UUID], currentIssueID: UUID?, conversationID: UUID?, hasOpenTask: Bool,
        pill: AgentSessionPill?, connectionBridgeID: UUID? = nil, lastTaskState: AgentTaskState? = nil, cancelRequested: Bool = false, turnSeq: Int = 0
    ) {
        self.id = id
        self.name = name
        self.agent = agent
        self.agentName = agentName
        self.connectionID = connectionID
        self.status = status
        self.ring = ring
        self.line = line
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.issueIDs = issueIDs
        self.currentIssueID = currentIssueID
        self.conversationID = conversationID
        self.hasOpenTask = hasOpenTask
        self.pill = pill
        self.connectionBridgeID = connectionBridgeID
        self.lastTaskState = lastTaskState
        self.cancelRequested = cancelRequested
        self.turnSeq = turnSeq
    }

    public var isClosed: Bool { status == .closed }
    public var isExternal: Bool { status == .external }
    /// 탭 · 레일에 보이는가: 닫힌 세션은 없다
    public var showsInTab: Bool { !isClosed }

    /// SessionRow의 접근성 이름 "{이름} — {에이전트} — {말}". 끝난 세션은 말이 없어 "{이름} — {에이전트}"
    public var rowAccessibilityName: String { line.isEmpty ? "\(name) — \(agentName)" : "\(name) — \(agentName) — \(line)" }
    /// 탭 항목의 접근성 이름 "{이름} · {말}" (말은 상태 줄과 같다: external은 "External · Open in Terminal")
    public var tabAccessibilityName: String { line.isEmpty ? name : "\(name) · \(line)" }
}
