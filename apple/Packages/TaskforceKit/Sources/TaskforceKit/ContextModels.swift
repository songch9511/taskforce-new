import Foundation

// 범위(프로젝트) 멤버십 (S3b)의 앱 쪽 모양. 서버 `contract.ts`의 같은 이름 스키마를 읽는다:
// 서버 head `0da883a`(S3b #125 = B3 `7328e93` + 커밋 4개) × 이 브랜치 (`ContextContractFixtures`가 그 JSON을 고정한다).
// 읽기는 RLS(`work_contexts` · `context_members`), 쓰기는 서버 `/api/v2/contexts/{id}/members[/move]`만 (조건부: `expected_context_version`).
// 모르는 값은 실패로 만들지 않고 가장 덜 주장하는 쪽으로 읽는다 (확인된 멤버로 보지 않는다).

/// `context_members.origin`: user(사용자가 정함, 자동 규칙이 덮지 않는다) · auto(코드 규칙) · inferred(모델 후보, 확인되지 않음).
/// 앱은 이 값을 표시 문자열 · `actions.project` · 이름 일치로 짐작하지 않는다
public enum ContextMemberOrigin: Sendable, Hashable {
    case user, auto, inferred
    case other(String)

    init(raw: String) {
        switch raw {
        case "user": self = .user
        case "auto": self = .auto
        case "inferred": self = .inferred
        default: self = .other(raw)
        }
    }

    /// 확인된 멤버의 출처인가 (user · auto). inferred와 모르는 값은 후보다: 묶음에 들이지 않는다
    public var isConfirmed: Bool {
        switch self {
        case .user, .auto: true
        case .inferred, .other: false
        }
    }
}

/// `context_members` 행 (할 일 멤버만 읽는다) 또는 쓰기 응답의 `member`.
/// 지금 멤버 = `removed_at`이 없는 행. 확인된 멤버 = 거기에 origin이 user · auto. 사용자가 뺀 행은 `removedAt`이 선다 (읽기는 그 행을 가져오지 않는다)
public struct ContextMember: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let contextID: UUID
    /// 할 일 멤버면 그 할 일 (그 밖의 멤버 종류는 nil: 이 앱은 쓰지 않는다)
    public let actionID: UUID?
    public let origin: ContextMemberOrigin
    /// inferred에만 있다
    public let confidence: Double?
    /// 사용자가 뺀 행 (자동 규칙이 다시 넣지 못하게 행이 남는다)
    public let isRemoved: Bool

    public static let columns = "id, context_id, member_kind, action_id, origin, confidence, removed_at"

    enum CodingKeys: String, CodingKey {
        case id, origin, confidence
        case contextID = "context_id"
        case actionID = "action_id"
        case removedAt = "removed_at"
    }

    public init(
        id: UUID, contextID: UUID, actionID: UUID?, origin: ContextMemberOrigin, confidence: Double? = nil, isRemoved: Bool = false
    ) {
        self.id = id
        self.contextID = contextID
        self.actionID = actionID
        self.origin = origin
        self.confidence = confidence
        self.isRemoved = isRemoved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        contextID = try c.decode(UUID.self, forKey: .contextID)
        actionID = try c.decodeIfPresent(UUID.self, forKey: .actionID)
        origin = ContextMemberOrigin(raw: (try? c.decode(String.self, forKey: .origin)) ?? "")
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        // 값이 있으면(null이 아니면) 뺀 행이다. 시각 형식이 낯설어도 "멤버"로 읽지 않는다
        isRemoved = c.contains(.removedAt) && !((try? c.decodeNil(forKey: .removedAt)) ?? true)
    }

    /// 확인된 멤버: 지금 멤버이고 origin이 user · auto
    public var isConfirmed: Bool { !isRemoved && origin.isConfirmed }
    /// 확인되지 않은 후보: 지금 멤버(행)이지만 inferred(또는 모르는 origin)
    public var isCandidate: Bool { !isRemoved && !origin.isConfirmed }
}

// MARK: 쓰기 응답 (서버 `contextMembershipResponseSchema` · `contextMemberMoveResponseSchema`)

/// 쓰기로 실제 바뀐 범위와 그 쓰기 직후의 범위 version. Undo는 이것의 역연산만 이 version을 조건으로 보낸다
public struct ContextVersionRef: Decodable, Sendable, Hashable {
    public let contextID: UUID
    public let contextVersion: Int

    enum CodingKeys: String, CodingKey {
        case contextID = "context_id"
        case contextVersion = "context_version"
    }

    public init(contextID: UUID, contextVersion: Int) {
        self.contextID = contextID
        self.contextVersion = contextVersion
    }
}

/// 실제로 바뀐 것: 확인된 멤버가 된 범위(`added`)와 확인된 멤버가 아니게 된 범위(`removed`).
/// 이미 멤버였던 도착 범위 · auto → user 승격 · inferred 후보를 뺌 · 멤버가 아니던 것을 뺌은 목록에 없다. 둘 다 비면 되돌릴 것이 없다
public struct ContextChange: Decodable, Sendable, Hashable {
    public let added: [ContextVersionRef]
    public let removed: [ContextVersionRef]

    public init(added: [ContextVersionRef] = [], removed: [ContextVersionRef] = []) {
        self.added = added
        self.removed = removed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

/// `POST /api/v2/contexts/{id}/members` 200
public struct ContextMemberWriteResponse: Decodable, Sendable, Hashable {
    public let member: ContextMember
    /// 쓰기 직후의 그 범위 version
    public let contextVersion: Int
    public let change: ContextChange

    enum CodingKeys: String, CodingKey {
        case member, change
        case contextVersion = "context_version"
    }

    public init(member: ContextMember, contextVersion: Int, change: ContextChange) {
        self.member = member
        self.contextVersion = contextVersion
        self.change = change
    }
}

/// `POST /api/v2/contexts/{to}/members/move` 200
public struct ContextMemberMoveResponse: Decodable, Sendable, Hashable {
    /// 도착(경로) 범위의 지금 멤버
    public let member: ContextMember
    /// 출발 범위에서 사용자가 뺀 행
    public let fromMember: ContextMember
    public let contextVersion: Int
    public let fromContextVersion: Int
    public let change: ContextChange

    enum CodingKeys: String, CodingKey {
        case member, change
        case fromMember = "from_member"
        case contextVersion = "context_version"
        case fromContextVersion = "from_context_version"
    }

    public init(member: ContextMember, fromMember: ContextMember, contextVersion: Int, fromContextVersion: Int, change: ContextChange) {
        self.member = member
        self.fromMember = fromMember
        self.contextVersion = contextVersion
        self.fromContextVersion = fromContextVersion
        self.change = change
    }
}

// MARK: 쓰기 요청 (서버 strict 스키마와 같은 키만 보낸다)

public enum ContextMemberOp: String, Sendable, Hashable {
    case add, remove
}

/// `POST /api/v2/contexts/{id}/members`: `member_kind`는 `action`뿐, `expected_context_version`은 필수 (요청이 본 범위 version)
struct ContextMemberWriteRequest: Encodable {
    let op: ContextMemberOp
    let actionID: UUID
    let expectedContextVersion: Int

    enum CodingKeys: String, CodingKey {
        case op
        case memberKind = "member_kind"
        case memberID = "member_id"
        case expectedContextVersion = "expected_context_version"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op.rawValue, forKey: .op)
        try c.encode("action", forKey: .memberKind)
        try c.encode(actionID.lowercased, forKey: .memberID)
        try c.encode(expectedContextVersion, forKey: .expectedContextVersion)
    }
}

/// `POST /api/v2/contexts/{to}/members/move`: 경로 = 도착 범위. 두 범위의 version 조건이 모두 필수
struct ContextMemberMoveRequest: Encodable {
    let actionID: UUID
    let fromContextID: UUID
    let expectedContextVersion: Int
    let expectedFromContextVersion: Int

    enum CodingKeys: String, CodingKey {
        case memberKind = "member_kind"
        case memberID = "member_id"
        case fromContextID = "from_context_id"
        case expectedContextVersion = "expected_context_version"
        case expectedFromContextVersion = "expected_from_context_version"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("action", forKey: .memberKind)
        try c.encode(actionID.lowercased, forKey: .memberID)
        try c.encode(fromContextID.lowercased, forKey: .fromContextID)
        try c.encode(expectedContextVersion, forKey: .expectedContextVersion)
        try c.encode(expectedFromContextVersion, forKey: .expectedFromContextVersion)
    }
}
