import Foundation

// OA U3: Taskforce 대화의 원천 `GET /api/v2/review/decisions`(R-dec-m 전에는 `GET /api/v2/review`)의 앱 쪽 모양과 경로 충돌 해소 요청.
// 서버 `contract.ts`의 `reviewDecisionsResponseSchema`(R-dec) · `reviewWithAgentsResponseSchema`(D4b-s) · `resolvePathConflictRequestSchema`를 읽는다. 픽스처는 서버 시험
// `tests/review/review-decisions-contract.test.ts`의 `REVIEW_DECISIONS_JSON`, `review-agents-contract.test.ts`의 `REVIEW_WITH_AGENTS_JSON` · `RESOLVE_*`를 그대로 복사한 것이다 (`Fixtures/taskforce-requests/`).
// 규칙:
// - 구조(필수 키 · 타입)는 엄격하다: 틀리면 디코딩 실패 = "읽지 못함"이지 빈 상태가 아니다.
// - 모르는 결정 종류는 **지우지 않고** `.unknown`으로 둔다. 앱은 그 항목을 건너뛰되 응답이 완전하다고 믿지 않는다 (`TaskforceRequestRules`).
// - 이 앱이 그리는 종류(`confirm` · `result_ready` · `path_conflict`)의 필수 ref가 없거나 모양이 틀리면 그 항목은 읽을 수 없는 항목이다 (`isReadable == false`): 건너뛰고 완전하다고 믿지 않는다.
//   그리지 않는 종류(질문 셋 · C3 실행 셋)의 ref는 읽지도 검사하지도 않는다 (그 세션에서만 답한다).
// - 서버는 문구를 만들지 않는다. 응답에 글이 없다: 경로 · 세션 이름 · 이슈 제목은 앱이 RLS로 읽는다. 제안(`suggestions`)은 읽지 않는다 (U3는 그리지 않는다).
// - 시각은 글자 그대로 둔다 (Date로 바꾸지 않는다): 순서는 서버가 정했고 앱은 다시 정렬하지 않는다.

/// 응답 토큰 하나를 읽는 규칙: 문자열이 아니면 모르는 값이다
private func taskforceToken(_ decoder: Decoder) -> String {
    (try? decoder.singleValueContainer().decode(String.self)) ?? ""
}

/// 결정 대기 종류 (서버 `reviewDecisionKindSchema`). 앱이 그리는 것은 `confirm` · `resultReady` · `pathConflict` 셋뿐이다
public enum TaskforceDecisionKind: Sendable, Hashable, Decodable {
    case approval, reviewFailed, runInput, confirm, agentQuestion, suggestion, blockedDependency
    case agentApproval, agentSecretQuestion, resultReady, pathConflict
    case unknown

    public init(from decoder: Decoder) throws {
        switch taskforceToken(decoder) {
        case "approval": self = .approval
        case "review_failed": self = .reviewFailed
        case "run_input": self = .runInput
        case "confirm": self = .confirm
        case "agent_question": self = .agentQuestion
        case "suggestion": self = .suggestion
        case "blocked_dependency": self = .blockedDependency
        case "agent_approval": self = .agentApproval
        case "agent_secret_question": self = .agentSecretQuestion
        case "result_ready": self = .resultReady
        case "path_conflict": self = .pathConflict
        default: self = .unknown
        }
    }

    /// 앱이 아는 종류인가 (그리지 않아도 안다: 질문 셋 · C3 실행 셋). `.unknown`만 모른다
    public var isKnown: Bool { self != .unknown }

    /// Taskforce 대화가 그리고 세는 종류 (U3-22). 질문은 그 세션에서만, C3 실행 결정은 후속이다
    public var isDrawn: Bool {
        switch self {
        case .confirm, .resultReady, .pathConflict: true
        default: false
        }
    }
}

/// `sources.*`: 그 원천을 읽었나. `ok`만 완전하다
public enum TaskforceSourceStatus: Sendable, Hashable, Decodable {
    case ok, unavailable, unknown

    public init(from decoder: Decoder) throws {
        switch taskforceToken(decoder) {
        case "ok": self = .ok
        case "unavailable": self = .unavailable
        default: self = .unknown
        }
    }
}

/// 응답이 읽은 원천의 상태. **믿는 규칙은 `decisions`(와 응답의 `complete`)뿐이다.** `suggestions` · `time_zone`은 앱이 읽지 않는다: 읽기 전용 `GET /api/v2/review/decisions`(R-dec)는
/// `sources`에 `decisions` 하나만 싣는다 (합성 `Decodable`이 선택 키는 없어도 읽는다). 키가 없으면 `nil`이다 — "모른다"가 아니라 "이 응답의 원천이 아니다"이므로 응답을 믿는 데 영향이 없다 (OA U3 검토 1, R-dec Q8)
public struct TaskforceReviewSources: Sendable, Hashable, Decodable {
    public let decisions: TaskforceSourceStatus
    public let suggestions: TaskforceSourceStatus?
    public let timeZone: TaskforceSourceStatus?

    enum CodingKeys: String, CodingKey {
        case decisions, suggestions
        case timeZone = "time_zone"
    }

    public init(decisions: TaskforceSourceStatus, suggestions: TaskforceSourceStatus? = .ok, timeZone: TaskforceSourceStatus? = .ok) {
        self.decisions = decisions
        self.suggestions = suggestions
        self.timeZone = timeZone
    }
}

/// `result_ready` 항목의 ref: 검토하지 않은 산출물이 있는 턴 범위. `session_id`는 지워졌으면 null이다
public struct TaskforceResultRef: Sendable, Hashable, Decodable {
    public let sessionID: UUID?
    public let reviewedTurnSeq: Int
    public let lastTurnSeq: Int
    public let changedAt: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case reviewedTurnSeq = "reviewed_turn_seq"
        case lastTurnSeq = "last_turn_seq"
        case changedAt = "changed_at"
    }

    public init(sessionID: UUID?, reviewedTurnSeq: Int, lastTurnSeq: Int, changedAt: String) {
        self.sessionID = sessionID
        self.reviewedTurnSeq = reviewedTurnSeq
        self.lastTurnSeq = lastTurnSeq
        self.changedAt = changedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 서버 `z.guid()`: 버전 비트가 없는 id도 UUID로 읽는다
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID).map { raw in
            guard let id = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(forKey: .sessionID, in: c, debugDescription: "id 형식이 아닙니다")
            }
            return id
        }
        reviewedTurnSeq = try c.decode(Int.self, forKey: .reviewedTurnSeq)
        lastTurnSeq = try c.decode(Int.self, forKey: .lastTurnSeq)
        changedAt = try c.decode(String.self, forKey: .changedAt)
    }
}

/// `path_conflict` 항목의 ref. 해소는 `POST /api/v2/path-conflicts/{leaseID}/resolve { keep, conflict_version }`
public struct TaskforceConflictRef: Sendable, Hashable, Decodable {
    public let leaseID: UUID
    /// 정수 CAS. 같은 lease에 새 충돌이 생기면 오른다
    public let conflictVersion: Int
    public let holderActionID: UUID
    public let holderRunID: UUID
    public let laterRunID: UUID
    /// lease가 이미 해제됨
    public let released: Bool
    /// 늦게 쓴 run을 멈췄다
    public let stopped: Bool

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
        case conflictVersion = "conflict_version"
        case holderActionID = "holder_action_id"
        case holderRunID = "holder_run_id"
        case laterRunID = "later_run_id"
        case released, stopped
    }

    public init(
        leaseID: UUID, conflictVersion: Int, holderActionID: UUID, holderRunID: UUID, laterRunID: UUID, released: Bool = false, stopped: Bool = true
    ) {
        self.leaseID = leaseID
        self.conflictVersion = conflictVersion
        self.holderActionID = holderActionID
        self.holderRunID = holderRunID
        self.laterRunID = laterRunID
        self.released = released
        self.stopped = stopped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func id(_ key: CodingKeys) throws -> UUID {
            guard let value = UUID(uuidString: try c.decode(String.self, forKey: key)) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "id 형식이 아닙니다")
            }
            return value
        }
        leaseID = try id(.leaseID)
        conflictVersion = try c.decode(Int.self, forKey: .conflictVersion)
        holderActionID = try id(.holderActionID)
        holderRunID = try id(.holderRunID)
        laterRunID = try id(.laterRunID)
        released = try c.decode(Bool.self, forKey: .released)
        stopped = try c.decode(Bool.self, forKey: .stopped)
    }
}

/// 결정 항목 하나. `id`는 안정 id(`<kind>:<열쇠>`)이고 `version`은 처리되면 바뀐다 (옛 version으로 행동하지 않는다)
public struct TaskforceDecisionItem: Sendable, Hashable, Decodable {
    public let id: String
    public let kind: TaskforceDecisionKind
    public let actionID: UUID
    public let version: String
    public let urgent: Bool
    public let createdAt: String
    /// 그리는 종류만 ref를 읽는다. 필수 ref가 없거나 모양이 틀리면 nil이고 `isReadable`이 거짓이다
    public let result: TaskforceResultRef?
    public let conflict: TaskforceConflictRef?

    enum CodingKeys: String, CodingKey {
        case id, kind, version, urgent, result, conflict
        case actionID = "action_id"
        case createdAt = "created_at"
    }

    public init(
        id: String, kind: TaskforceDecisionKind, actionID: UUID, version: String, urgent: Bool = false, createdAt: String = "",
        result: TaskforceResultRef? = nil, conflict: TaskforceConflictRef? = nil
    ) {
        self.id = id
        self.kind = kind
        self.actionID = actionID
        self.version = version
        self.urgent = urgent
        self.createdAt = createdAt
        self.result = result
        self.conflict = conflict
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(TaskforceDecisionKind.self, forKey: .kind)
        guard let action = UUID(uuidString: try c.decode(String.self, forKey: .actionID)) else {
            throw DecodingError.dataCorruptedError(forKey: .actionID, in: c, debugDescription: "id 형식이 아닙니다")
        }
        actionID = action
        version = try c.decode(String.self, forKey: .version)
        urgent = (try? c.decode(Bool.self, forKey: .urgent)) ?? false
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        // 그리는 종류의 ref만 읽는다 (읽지 못하면 nil: 읽을 수 없는 항목)
        result = kind == .resultReady ? (try? c.decode(TaskforceResultRef.self, forKey: .result)) : nil
        conflict = kind == .pathConflict ? (try? c.decode(TaskforceConflictRef.self, forKey: .conflict)) : nil
    }

    /// 그리는 종류에 필요한 ref가 모두 있나. 그리지 않는 종류는 ref를 보지 않으니 늘 참이다
    public var isReadable: Bool {
        switch kind {
        case .resultReady: result != nil
        case .pathConflict: conflict != nil
        default: true
        }
    }
}

/// (업무, 종류) 묶음. 목록의 순서가 곧 Needs you 순서다 (긴급 → 오래 기다린 순). 앱은 다시 정렬하지 않는다
public struct TaskforceDecisionGroup: Sendable, Hashable, Decodable {
    public let key: String
    public let actionID: UUID
    public let kind: TaskforceDecisionKind
    public let items: [TaskforceDecisionItem]

    enum CodingKeys: String, CodingKey {
        case key, kind, items
        case actionID = "action_id"
    }

    public init(key: String, actionID: UUID, kind: TaskforceDecisionKind, items: [TaskforceDecisionItem]) {
        self.key = key
        self.actionID = actionID
        self.kind = kind
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        guard let action = UUID(uuidString: try c.decode(String.self, forKey: .actionID)) else {
            throw DecodingError.dataCorruptedError(forKey: .actionID, in: c, debugDescription: "id 형식이 아닙니다")
        }
        actionID = action
        kind = try c.decode(TaskforceDecisionKind.self, forKey: .kind)
        items = try c.decode([TaskforceDecisionItem].self, forKey: .items)
    }
}

/// `GET /api/v2/review/decisions`(와 같은 결정 모양의 `GET /api/v2/review`) 응답 중 U3가 읽는 것. `decisions`가 null이면 모르는 것이다 (비어 있는 것이 아니다)
public struct TaskforceReviewResponse: Sendable, Hashable, Decodable {
    public let generatedAt: String
    /// 모든 원천을 읽었다
    public let complete: Bool
    /// 완전하고 결정도 제안도 없다. 이 앱은 결정만 읽으니 "No decisions waiting"은 이 값이 아니라 `decisionsOK`에서 나온다
    public let empty: Bool
    public let sources: TaskforceReviewSources
    public let decisions: [TaskforceDecisionGroup]?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case complete, empty, sources, decisions
    }

    public init(
        generatedAt: String = "", complete: Bool = true, empty: Bool = false, sources: TaskforceReviewSources = TaskforceReviewSources(decisions: .ok),
        decisions: [TaskforceDecisionGroup]?
    ) {
        self.generatedAt = generatedAt
        self.complete = complete
        self.empty = empty
        self.sources = sources
        self.decisions = decisions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        complete = try c.decode(Bool.self, forKey: .complete)
        empty = try c.decode(Bool.self, forKey: .empty)
        sources = try c.decode(TaskforceReviewSources.self, forKey: .sources)
        decisions = try c.decodeIfPresent([TaskforceDecisionGroup].self, forKey: .decisions)
    }

    /// 결정 원천을 읽었고 목록이 있다 (결정만 본다: 제안 원천이 `unavailable`이어도 결정 목록은 믿을 수 있다)
    public var decisionsOK: Bool { sources.decisions == .ok && decisions != nil }

    /// 모든 항목 (서버 순서: 묶음 순서, 묶음 안 순서)
    public var items: [TaskforceDecisionItem] { (decisions ?? []).flatMap(\.items) }
}

// MARK: 경로 충돌 해소

/// 어느 쪽을 남기나 (서버 `keep`). holder = 먼저 쓴 쪽 · later = 늦게 쓴 쪽
public enum TaskforceConflictKeep: String, Sendable, Hashable, Codable {
    case holder, later

    /// 번호 키: 1 = 먼저 쓴 쪽, 2 = 늦게 쓴 쪽 (FileConflictPage)
    public init?(key: Int) {
        switch key {
        case 1: self = .holder
        case 2: self = .later
        default: return nil
        }
    }

    public var key: Int { self == .holder ? 1 : 2 }
}

/// `POST /api/v2/path-conflicts/{lease_id}/resolve` 본문 (strict): `conflict_version`은 1…2,147,483,647 (DB integer)
struct TaskforceResolveConflictRequest: Encodable {
    let keep: TaskforceConflictKeep
    let conflictVersion: Int

    enum CodingKeys: String, CodingKey {
        case keep
        case conflictVersion = "conflict_version"
    }
}

/// 200 `{ "status": "resolved" }`. 다른 status 값은 읽을 수 없는 응답이다 (성공으로 말하지 않는다)
public struct TaskforceResolveConflictResponse: Sendable, Hashable, Decodable {
    public let status: String
    public var isResolved: Bool { status == "resolved" }
}

/// 경로 충돌 하나의 앱 쪽 상세: RLS로 읽은 경로와 두 run의 세션 (서버 응답에는 글이 없다). 경로는 사용자 글이라 메모리에만 두고 로그에 남기지 않는다
public struct TaskforceConflictDetail: Sendable, Hashable {
    public let leaseID: UUID
    public let relPath: String
    public let holderRunID: UUID
    public let laterRunID: UUID
    public let holderSessionID: UUID?
    public let laterSessionID: UUID?

    public init(leaseID: UUID, relPath: String, holderRunID: UUID, laterRunID: UUID, holderSessionID: UUID?, laterSessionID: UUID?) {
        self.leaseID = leaseID
        self.relPath = relPath
        self.holderRunID = holderRunID
        self.laterRunID = laterRunID
        self.holderSessionID = holderSessionID
        self.laterSessionID = laterSessionID
    }
}
