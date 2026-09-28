import Foundation

// 서버 API 모델. `src/lib/api/contract.ts`와 같은 모양으로 맞춘다.

public enum ActionOwner: String, Codable, Sendable, CaseIterable {
    case me, other, unknown
}

public enum ActionStatus: String, Codable, Sendable {
    case open, done, dropped
}

/// 지금 할 일 순서의 이유. 서버가 새 이유를 추가해도 앱이 깨지지 않게 모르는 값은 버린다.
public enum RankReason: String, Codable, Sendable, CaseIterable {
    case overdue
    case dueToday = "due_today"
    case dueSoon = "due_soon"
    case external
    case neglected
    case started
}

/// contract.ts `actionSummarySchema`
public struct ActionSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let owner: ActionOwner
    public let status: ActionStatus
    public let dueDate: LocalDate?
    public let counterpart: String?
    public let needsConfirmation: Bool
    /// 확인 요청 이유 (예: "담당 확인", "기한 확인")
    public let confirmReasons: [String]
    public let startedAt: Date?
    public let lastActivityAt: Date

    /// `actions` 행에서 읽을 열 (Supabase 직접 읽기, 서버 `SUMMARY_COLUMNS`와 같다)
    public static let columns =
        "id, title, owner, status, due_date, counterpart, needs_confirmation, confirm_reasons, started_at, last_activity_at"

    enum CodingKeys: String, CodingKey {
        case id, title, owner, status, counterpart
        case dueDate = "due_date"
        case needsConfirmation = "needs_confirmation"
        case confirmReasons = "confirm_reasons"
        case startedAt = "started_at"
        case lastActivityAt = "last_activity_at"
    }

    public init(
        id: UUID, title: String, owner: ActionOwner, status: ActionStatus, dueDate: LocalDate?, counterpart: String?,
        needsConfirmation: Bool, confirmReasons: [String], startedAt: Date?, lastActivityAt: Date
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.status = status
        self.dueDate = dueDate
        self.counterpart = counterpart
        self.needsConfirmation = needsConfirmation
        self.confirmReasons = confirmReasons
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
    }
}

/// contract.ts `rankedActionSchema`. 순서와 점수는 서버가 정한다 — 앱은 받은 순서 그대로 보여준다.
public struct RankedAction: Decodable, Sendable, Hashable, Identifiable {
    public let action: ActionSummary
    public let score: Double
    public let reasons: [RankReason]
    public let daysUntilDue: Int?

    public var id: UUID { action.id }

    enum CodingKeys: String, CodingKey {
        case score, reasons
        case daysUntilDue = "days_until_due"
    }

    public init(action: ActionSummary, score: Double, reasons: [RankReason], daysUntilDue: Int?) {
        self.action = action
        self.score = score
        self.reasons = reasons
        self.daysUntilDue = daysUntilDue
    }

    public init(from decoder: Decoder) throws {
        action = try ActionSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Double.self, forKey: .score)
        reasons = try c.decode([String].self, forKey: .reasons).compactMap(RankReason.init(rawValue:))
        daysUntilDue = try c.decodeIfPresent(Double.self, forKey: .daysUntilDue).map { Int($0.rounded()) }
    }
}

/// 이번 주 그림자 목록 질문 (PRD 지표 5). 서버가 물을 때만 온다.
public struct WeeklyCheckPrompt: Codable, Sendable, Hashable {
    public let weekStart: LocalDate

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
    }

    public init(weekStart: LocalDate) {
        self.weekStart = weekStart
    }
}

/// GET /api/v1/now
public struct NowResponse: Decodable, Sendable, Hashable {
    public let now: [RankedAction]
    public let confirmations: [ActionSummary]
    /// 예전 서버에는 없는 필드라 없으면 nil
    public let weeklyCheck: WeeklyCheckPrompt?

    enum CodingKeys: String, CodingKey {
        case now, confirmations
        case weeklyCheck = "weekly_check"
    }

    public init(now: [RankedAction], confirmations: [ActionSummary], weeklyCheck: WeeklyCheckPrompt?) {
        self.now = now
        self.confirmations = confirmations
        self.weeklyCheck = weeklyCheck
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        now = try c.decode([RankedAction].self, forKey: .now)
        confirmations = try c.decode([ActionSummary].self, forKey: .confirmations)
        weeklyCheck = try c.decodeIfPresent(WeeklyCheckPrompt.self, forKey: .weeklyCheck)
    }
}

/// PATCH /api/v1/actions/:id. 바꿀 필드만 보낸다. 기한은 "없음"으로 지울 수 있다 (`null`).
public struct ActionEdit: Encodable, Sendable, Equatable {
    public enum DueChange: Sendable, Equatable {
        case set(LocalDate)
        case clear
    }

    public var title: String?
    public var due: DueChange?
    /// `.open` 또는 `.done`만 (삭제는 DELETE)
    public var status: ActionStatus?
    /// `.me` 또는 `.other`만
    public var owner: ActionOwner?

    public init(title: String? = nil, due: DueChange? = nil, status: ActionStatus? = nil, owner: ActionOwner? = nil) {
        self.title = title
        self.due = due
        self.status = status
        self.owner = owner
    }

    public var isEmpty: Bool { title == nil && due == nil && status == nil && owner == nil }

    /// 고치기 화면의 값과 지금 값을 비교해 바뀐 것만 담는다. 빈 제목은 보내지 않고, 담당은 나 · 다른 사람으로만 바꾼다.
    public static func changes(
        title: String, due: LocalDate?, owner: ActionOwner?,
        from current: (title: String, due: LocalDate?, owner: ActionOwner)
    ) -> ActionEdit {
        var edit = ActionEdit()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != current.title {
            edit.title = String(trimmed.prefix(200))
        }
        if due != current.due {
            edit.due = due.map(DueChange.set) ?? .clear
        }
        if let owner, owner != .unknown, owner != current.owner {
            edit.owner = owner
        }
        return edit
    }

    enum CodingKeys: String, CodingKey {
        case title, status, owner
        case dueDate = "due_date"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        switch due {
        case .set(let date): try c.encode(date, forKey: .dueDate)
        case .clear: try c.encodeNil(forKey: .dueDate)
        case nil: break
        }
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(owner, forKey: .owner)
    }
}

struct ActionResponse: Decodable {
    let action: ActionSummary
}

/// POST /api/v1/actions 결과 (201 created · 200 already_tracked)
public struct CreateActionResponse: Decodable, Sendable, Hashable {
    public enum Status: String, Sendable {
        /// 새 할 일로 추가함
        case created
        /// 고른 구절이 이미 근거인 할 일이 있어 그 할 일을 그대로 돌려줌
        case alreadyTracked = "already_tracked"
    }

    public let action: ActionSummary
    public let status: Status

    enum CodingKeys: String, CodingKey {
        case action, status
    }

    public init(action: ActionSummary, status: Status) {
        self.action = action
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(ActionSummary.self, forKey: .action)
        // status가 없는 옛 서버 · 모르는 값은 추가된 것으로 본다
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(Status.init(rawValue:)) } ?? .created
    }
}

/// POST /api/v1/actions/:id/handoff
public struct HandoffResponse: Decodable, Sendable, Hashable {
    public let actionID: UUID
    public let title: String
    /// 그대로 복사해 AI 도구에 붙여 넣는 문서
    public let markdown: String

    enum CodingKeys: String, CodingKey {
        case title, markdown
        case actionID = "action_id"
    }
}

/// POST /api/v1/sources/:id/missing 결과
public struct MissingReportResponse: Decodable, Sendable, Hashable {
    public enum Status: String, Decodable, Sendable {
        /// 새 할 일로 추가함
        case created
        /// 이미 있는 할 일과 같음
        case alreadyTracked = "already_tracked"
    }

    /// 파이프라인의 어느 단계에서 놓쳤는지 (지표 4용, 화면에는 쓰지 않는다)
    public enum Stage: String, Decodable, Sendable {
        case processingFailed = "processing_failed"
        case notExtracted = "not_extracted"
        case judgeRejected = "judge_rejected"
        case mergeAbsorbed = "merge_absorbed"
    }

    public let status: Status
    public let action: ActionSummary
    public let stage: Stage?

    enum CodingKeys: String, CodingKey {
        case status, action, stage
    }

    public init(status: Status, action: ActionSummary, stage: Stage?) {
        self.status = status
        self.action = action
        self.stage = stage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(Status.self, forKey: .status)
        action = try c.decode(ActionSummary.self, forKey: .action)
        // 모르는 단계가 와도 결과는 보여준다
        stage = (try? c.decodeIfPresent(String.self, forKey: .stage)).flatMap { $0.flatMap(Stage.init(rawValue:)) }
    }
}

/// POST /api/v1/weekly-check `answer`
public enum WeeklyCheckAnswer: String, Encodable, Sendable {
    case yes, no, skipped
}

// MARK: - Supabase 직접 읽기 (RLS, 읽기 전용)

public enum SourceKind: String, Codable, Sendable {
    case meeting, message, email, doc, note, task
}

public enum ProcessingStatus: String, Codable, Sendable {
    case pending, processing, done, failed
}

/// `actions` 행 (상세 화면용)
public struct ActionRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let scopeSummary: String?
    public let owner: ActionOwner
    public let counterpart: String?
    public let dueDate: LocalDate?
    public let status: ActionStatus
    public let needsConfirmation: Bool
    public let confirmReasons: [String]
    public let startedAt: Date?
    public let lastActivityAt: Date
    public let createdAt: Date

    public static let columns =
        "id, title, scope_summary, owner, counterpart, due_date, status, needs_confirmation, confirm_reasons, started_at, last_activity_at, created_at"

    enum CodingKeys: String, CodingKey {
        case id, title, owner, counterpart, status
        case scopeSummary = "scope_summary"
        case dueDate = "due_date"
        case needsConfirmation = "needs_confirmation"
        case confirmReasons = "confirm_reasons"
        case startedAt = "started_at"
        case lastActivityAt = "last_activity_at"
        case createdAt = "created_at"
    }
}

public enum EvidenceRole: String, Codable, Sendable {
    case created, updated, completed, duplicate
}

/// `evidence` 행: 원문 인용 구절
public struct EvidenceRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let actionID: UUID
    public let sourceID: UUID
    public let quote: String
    public let role: EvidenceRole
    public let createdAt: Date

    public static let columns = "id, action_id, source_id, quote, role, created_at"

    enum CodingKeys: String, CodingKey {
        case id, quote, role
        case actionID = "action_id"
        case sourceID = "source_id"
        case createdAt = "created_at"
    }

    public init(id: UUID, actionID: UUID, sourceID: UUID, quote: String, role: EvidenceRole, createdAt: Date) {
        self.id = id
        self.actionID = actionID
        self.sourceID = sourceID
        self.quote = quote
        self.role = role
        self.createdAt = createdAt
    }
}

public enum EventActor: String, Codable, Sendable {
    case ai, user
}

/// `action_events` 행: 변경 이력
public struct ActionEventRecord: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let actionID: UUID
    /// created, due_changed, … user_reported_missing. 모르는 종류도 받는다.
    public let type: String
    public let before: JSONValue?
    public let after: JSONValue?
    public let sourceID: UUID?
    public let actor: EventActor
    public let rule: String?
    public let createdAt: Date

    public static let columns = "id, action_id, type, before, after, source_id, actor, rule, created_at"

    enum CodingKeys: String, CodingKey {
        case id, type, before, after, actor, rule
        case actionID = "action_id"
        case sourceID = "source_id"
        case createdAt = "created_at"
    }

    public init(
        id: UUID, actionID: UUID, type: String, before: JSONValue?, after: JSONValue?, sourceID: UUID?, actor: EventActor,
        rule: String?, createdAt: Date
    ) {
        self.id = id
        self.actionID = actionID
        self.type = type
        self.before = before
        self.after = after
        self.sourceID = sourceID
        self.actor = actor
        self.rule = rule
        self.createdAt = createdAt
    }
}

/// `sources` 행 (목록용, 원문 제외)
public struct SourceSummary: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kind: SourceKind
    public let title: String?
    public let occurredAt: Date
    public let externalURL: URL?
    public let createdAt: Date
    public let processingStatus: ProcessingStatus

    public static let columns = "id, kind, title, occurred_at, external_url, created_at, processing_status"

    enum CodingKeys: String, CodingKey {
        case id, kind, title
        case occurredAt = "occurred_at"
        case externalURL = "external_url"
        case createdAt = "created_at"
        case processingStatus = "processing_status"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        // 잘못된 링크 하나 때문에 목록 전체를 못 읽는 일이 없게
        externalURL = (try? c.decodeIfPresent(String.self, forKey: .externalURL)).flatMap { $0.flatMap(URL.init(string:)) }
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        processingStatus = try c.decode(ProcessingStatus.self, forKey: .processingStatus)
    }
}

/// `sources` 행 하나 + 원문
public struct SourceRecord: Decodable, Sendable, Hashable, Identifiable {
    public let summary: SourceSummary
    public let rawText: String

    public var id: UUID { summary.id }

    public static let columns = SourceSummary.columns + ", raw_text"

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
    }

    public init(from decoder: Decoder) throws {
        summary = try SourceSummary(from: decoder)
        rawText = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .rawText)
    }
}
