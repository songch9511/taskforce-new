import Foundation

// 기억 (`memory_items`, B1 · B3 PR1). 앱은 RLS로 읽고(본인 행) 쓰기는 서버 `/api/v2/memory`로만 한다.
// 서버 판정(범위 사이 우선 `effectiveMemory`, 정정 규칙, 지금 기억의 효력)은 Swift에 다시 만들지 않는다:
// 앱이 아는 것은 "지금 기억" 조건(`superseded_at is null and revoked_at is null`)과 행의 값뿐이다.

/// 디자인의 kind (Explicit · Observed · Inferred) = 서버의 `origin`. 모르는 값은 그대로 두고 확인(Confirm)을 주지 않는다
public enum MemoryOrigin: Sendable, Hashable {
    case explicit, observed, inferred
    case other(String)

    init(raw: String) {
        switch raw {
        case "explicit": self = .explicit
        case "observed": self = .observed
        case "inferred": self = .inferred
        default: self = .other(raw)
        }
    }
}

/// 범위의 종류. 디자인은 전체(All work)와 프로젝트만 안다: 나머지는 읽기만 하고 옮기지 않는다
public enum MemoryScopeKind: Sendable, Hashable {
    case global, context, action, counterpart, agent
    case other(String)

    init(raw: String) {
        switch raw {
        case "global": self = .global
        case "context": self = .context
        case "action": self = .action
        case "counterpart": self = .counterpart
        case "agent": self = .agent
        default: self = .other(raw)
        }
    }
}

/// 기억의 출처 (`source_ref`): message_id | source_id(+ quote) | artifact_id | event_id 중 하나 이상
public struct MemorySourceRef: Decodable, Sendable, Hashable {
    public let messageID: UUID?
    public let sourceID: UUID?
    public let quote: String?
    public let artifactID: UUID?
    public let eventID: String?

    enum CodingKeys: String, CodingKey {
        case quote
        case messageID = "message_id"
        case sourceID = "source_id"
        case artifactID = "artifact_id"
        case eventID = "event_id"
    }

    public init(messageID: UUID? = nil, sourceID: UUID? = nil, quote: String? = nil, artifactID: UUID? = nil, eventID: String? = nil) {
        self.messageID = messageID
        self.sourceID = sourceID
        self.quote = quote
        self.artifactID = artifactID
        self.eventID = eventID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageID = (try? c.decodeIfPresent(String.self, forKey: .messageID)).flatMap { $0.flatMap(UUID.init(uuidString:)) }
        sourceID = (try? c.decodeIfPresent(String.self, forKey: .sourceID)).flatMap { $0.flatMap(UUID.init(uuidString:)) }
        quote = try? c.decodeIfPresent(String.self, forKey: .quote)
        artifactID = (try? c.decodeIfPresent(String.self, forKey: .artifactID)).flatMap { $0.flatMap(UUID.init(uuidString:)) }
        eventID = try? c.decodeIfPresent(String.self, forKey: .eventID)
    }
}

/// `memory_items` 행. 서버 쓰기 응답의 `item`도 같은 모양이다
public struct MemoryItem: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let scopeKind: MemoryScopeKind
    public let contextID: UUID?
    public let statement: String
    /// 구조화 값 (옮긴 행은 `moved_from`이 옛 행 id다)
    public let value: JSONValue
    public let origin: MemoryOrigin
    public let sourceRef: MemorySourceRef?
    public let observedAt: Date
    public let supersededBy: UUID?
    public let supersededAt: Date?
    public let revokedAt: Date?
    public let confidence: Double?
    /// 출처 원문 글이 지워졌다 (빈 statement)
    public let sourcePurged: Bool
    public let version: Int
    public let createdAt: Date

    public static let columns = """
    id, kind, scope_kind, context_id, action_id, person_id, agent_adapter, subject, statement, value, origin, source_ref, observed_at, \
    valid_from, valid_until, superseded_by, superseded_at, revoked_at, confidence, source_purged, version, created_at, updated_at
    """

    enum CodingKeys: String, CodingKey {
        case id, statement, value, origin, confidence, version
        case scopeKind = "scope_kind"
        case contextID = "context_id"
        case sourceRef = "source_ref"
        case observedAt = "observed_at"
        case supersededBy = "superseded_by"
        case supersededAt = "superseded_at"
        case revokedAt = "revoked_at"
        case sourcePurged = "source_purged"
        case createdAt = "created_at"
    }

    public init(
        id: UUID, scopeKind: MemoryScopeKind = .global, contextID: UUID? = nil, statement: String, value: JSONValue = .object([:]),
        origin: MemoryOrigin, sourceRef: MemorySourceRef? = nil, observedAt: Date, supersededBy: UUID? = nil, supersededAt: Date? = nil,
        revokedAt: Date? = nil, confidence: Double? = nil, sourcePurged: Bool = false, version: Int = 1, createdAt: Date? = nil
    ) {
        self.id = id
        self.scopeKind = scopeKind
        self.contextID = contextID
        self.statement = statement
        self.value = value
        self.origin = origin
        self.sourceRef = sourceRef
        self.observedAt = observedAt
        self.supersededBy = supersededBy
        self.supersededAt = supersededAt
        self.revokedAt = revokedAt
        self.confidence = confidence
        self.sourcePurged = sourcePurged
        self.version = version
        self.createdAt = createdAt ?? observedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scopeKind = MemoryScopeKind(raw: try c.decode(String.self, forKey: .scopeKind))
        contextID = try c.decodeIfPresent(UUID.self, forKey: .contextID)
        statement = try c.decode(String.self, forKey: .statement)
        value = (try? c.decodeIfPresent(JSONValue.self, forKey: .value)) ?? .object([:])
        origin = MemoryOrigin(raw: try c.decode(String.self, forKey: .origin))
        sourceRef = try? c.decodeIfPresent(MemorySourceRef.self, forKey: .sourceRef)
        observedAt = try c.decode(Date.self, forKey: .observedAt)
        supersededBy = try c.decodeIfPresent(UUID.self, forKey: .supersededBy)
        supersededAt = try c.decodeIfPresent(Date.self, forKey: .supersededAt)
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        sourcePurged = try c.decode(Bool.self, forKey: .sourcePurged)
        version = try c.decode(Int.self, forKey: .version)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// "지금 기억" (`isCurrentMemoryItem`, DB 인덱스와 같은 조건). `superseded_by`로 판단하지 않는다:
    /// 정정한 새 행이 지워져 포인터만 비어도 옛 행은 지금 기억이 아니다
    public var isCurrent: Bool { supersededAt == nil && revokedAt == nil }

    /// 아직 확인하지 않은 추정 (확인하면 새 explicit 행이 생기고 이 행은 정정된다)
    public var isUnconfirmedInference: Bool { origin == .inferred && isCurrent }

    /// 다른 범위로 옮겨 온 행이면 옛 행 id (`value.moved_from`)
    public var movedFrom: UUID? {
        value["moved_from"]?.stringValue.flatMap(UUID.init(uuidString:))
    }
}

public struct MemoryItemResponse: Decodable, Sendable {
    public let item: MemoryItem
}

// MARK: 쓰기 요청

struct MemoryVersionRequest: Encodable {
    let expectedVersion: Int

    enum CodingKeys: String, CodingKey {
        case expectedVersion = "expected_version"
    }
}

/// `PATCH /api/v2/memory/{id}`의 한 값을 바꾸는 방법. 키를 빼면 옛 값을 이어받고(`.inherit`), 비우려면 값에 따라 다르다:
/// `value`는 `{}`(`null`은 서버가 400), `valid_from` · `valid_until`은 `null`
public enum MemoryFieldEdit<Value: Sendable & Equatable>: Sendable, Equatable {
    case inherit
    case set(Value)
    case clear
}

/// 기억 정정 요청. 앱은 지금 글(`statement`)만 바꾼다: 나머지는 `.inherit`로 키를 보내지 않는다
public struct MemoryEdit: Sendable, Equatable {
    public var expectedVersion: Int
    public var statement: String
    public var value: MemoryFieldEdit<[String: JSONValue]> = .inherit
    public var validFrom: MemoryFieldEdit<String> = .inherit
    public var validUntil: MemoryFieldEdit<String> = .inherit

    public init(
        expectedVersion: Int, statement: String, value: MemoryFieldEdit<[String: JSONValue]> = .inherit,
        validFrom: MemoryFieldEdit<String> = .inherit, validUntil: MemoryFieldEdit<String> = .inherit
    ) {
        self.expectedVersion = expectedVersion
        self.statement = statement
        self.value = value
        self.validFrom = validFrom
        self.validUntil = validUntil
    }
}

extension MemoryEdit: Encodable {
    enum CodingKeys: String, CodingKey {
        case statement, value
        case expectedVersion = "expected_version"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }

    /// 서버 `memoryEditRequestSchema`는 strict다: 빠진 키 = 옛 값 상속, `value: null`은 400 → 비우는 `value`는 `{}`
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedVersion, forKey: .expectedVersion)
        try c.encode(statement, forKey: .statement)
        switch value {
        case .inherit: break
        case .set(let object): try c.encode(object, forKey: .value)
        case .clear: try c.encode([String: JSONValue](), forKey: .value)
        }
        for (field, key) in [(validFrom, CodingKeys.validFrom), (validUntil, .validUntil)] {
            switch field {
            case .inherit: break
            case .set(let date): try c.encode(date, forKey: key)
            case .clear: try c.encodeNil(forKey: key)
            }
        }
    }
}

/// 범위 옮기기의 대상: 전체(All work) 또는 내 active 범위 (프로젝트)
public enum MemoryTarget: Sendable, Hashable {
    case global
    case context(UUID)
}

struct MemoryScopeRequest: Encodable {
    let expectedVersion: Int
    let target: MemoryTarget

    enum CodingKeys: String, CodingKey {
        case expectedVersion = "expected_version"
        case scopeKind = "scope_kind"
        case contextID = "context_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedVersion, forKey: .expectedVersion)
        switch target {
        case .global:
            try c.encode("global", forKey: .scopeKind)
        case .context(let id):
            try c.encode("context", forKey: .scopeKind)
            try c.encode(id.lowercased, forKey: .contextID)
        }
    }
}
