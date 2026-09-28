import Foundation

// 프로필 · 동의 · 원문 보내기 · 물어보기 모델. `src/lib/api/contract.ts`와 같은 모양이고, 새 필드는 없어도 읽는다.

/// GET · PUT /api/v1/profile
public struct Profile: Codable, Sendable, Hashable {
    /// 원문에서 사용자를 부르는 기본 이름
    public var displayName: String?
    /// 다른 호칭 · 영문 이름 · 받아쓰기가 자주 틀리는 이름
    public var aliases: [String]
    public var emails: [String]
    /// 외부 AI 처리 동의 시각. 예전 서버에는 없는 필드라 없으면 nil. 동의 · 철회는 `/consent`로만 한다 (PUT에 보내지 않는다).
    public let aiConsentAt: Date?
    /// 서버가 동의 필드를 알려 주는지 (예전 서버면 false: 동의 없이도 처리한다)
    public let reportsConsent: Bool

    public static let empty = Profile(displayName: nil, aliases: [], emails: [], aiConsentAt: nil, reportsConsent: false)

    public var hasAIConsent: Bool { aiConsentAt != nil }

    public init(displayName: String?, aliases: [String], emails: [String], aiConsentAt: Date?, reportsConsent: Bool) {
        self.displayName = displayName
        self.aliases = aliases
        self.emails = emails
        self.aiConsentAt = aiConsentAt
        self.reportsConsent = reportsConsent
    }

    enum CodingKeys: String, CodingKey {
        case aliases, emails
        case displayName = "display_name"
        case aiConsentAt = "ai_consent_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        reportsConsent = c.contains(.aiConsentAt)
        // 시각을 못 읽어도 값이 있으면 동의한 것으로 본다
        if let raw = try? c.decodeIfPresent(String.self, forKey: .aiConsentAt) {
            aiConsentAt = PostgresTimestamp.parse(raw) ?? .distantPast
        } else {
            aiConsentAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(emails, forKey: .emails)
    }

    /// 프로필 화면의 입력을 서버 규칙(이름 1~50자, 별칭 20개까지)에 맞춘다. 빈 이름은 nil.
    public static func edited(name: String, aliases: [String], keeping current: Profile) -> Profile {
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50))
        var seen = Set<String>()
        let cleanAliases = aliases
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50)) }
            .filter { !$0.isEmpty && $0 != trimmedName && seen.insert($0).inserted }
        return Profile(
            displayName: trimmedName.isEmpty ? nil : trimmedName,
            aliases: Array(cleanAliases.prefix(20)),
            emails: current.emails,
            aiConsentAt: current.aiConsentAt,
            reportsConsent: current.reportsConsent
        )
    }

    /// "Kim, 김대표" 같은 쉼표 목록 → 별칭
    public static func aliases(fromList text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// 외부 AI 처리 동의를 언제 물을지. 기존 사용자도 모두 동의 없이 시작한다.
/// 연결이 있거나(있는 연결의 원문을 읽으려면) 연결을 더하려 할 때만 묻고, 목록 보기는 막지 않는다.
public enum AIConsentRule {
    /// 서버가 동의 필드를 알려 주는데 아직 동의하지 않았는지
    public static func isMissing(_ profile: Profile?) -> Bool {
        guard let profile else { return false }
        return profile.reportsConsent && !profile.hasAIConsent
    }

    /// 로그인 뒤 한 번 동의 화면을 띄울지
    public static func shouldPrompt(profile: Profile?, hasConnections: Bool) -> Bool {
        isMissing(profile) && hasConnections
    }
}

/// POST /api/v1/sources
public struct CreateSourceRequest: Encodable, Sendable, Equatable {
    /// contract.ts `MAX_SOURCE_TEXT`
    public static let maxTextLength = 200_000

    public let kind: SourceKind
    public let text: String
    public let title: String?
    public let occurredAt: Date?

    public init(kind: SourceKind, text: String, title: String? = nil, occurredAt: Date? = nil) {
        self.kind = kind
        self.text = text
        self.title = title
        self.occurredAt = occurredAt
    }

    enum CodingKeys: String, CodingKey {
        case kind, text, title
        case occurredAt = "occurred_at"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(title, forKey: .title)
        if let occurredAt {
            try c.encode(occurredAt.formatted(.iso8601), forKey: .occurredAt)
        }
    }
}

public struct CreateSourceResponse: Decodable, Sendable, Hashable {
    public let sourceID: UUID
    public let status: String

    enum CodingKeys: String, CodingKey {
        case status
        case sourceID = "source_id"
    }
}

/// POST /api/v1/ask 결과. 근거가 없으면 `unknown`이 true이고 답은 "모른다"는 말이다.
public struct AskResponse: Decodable, Sendable, Hashable {
    public let answer: String
    public let unknown: Bool
    public let citations: [AskCitation]

    enum CodingKeys: String, CodingKey {
        case answer, unknown, citations
    }

    public init(answer: String, unknown: Bool, citations: [AskCitation]) {
        self.answer = answer
        self.unknown = unknown
        self.citations = citations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        unknown = try c.decodeIfPresent(Bool.self, forKey: .unknown) ?? false
        // 인용 하나가 이상해도 답은 보여 준다
        citations = (try? c.decodeIfPresent([Lossy<AskCitation>].self, forKey: .citations))?.compactMap(\.value) ?? []
    }
}

public struct AskCitation: Decodable, Sendable, Hashable, Identifiable {
    public let actionID: UUID?
    public let sourceID: UUID
    public let sourceTitle: String?
    public let sourceKind: SourceKind
    public let occurredAt: Date?
    public let externalURL: URL?
    public let quote: String

    public var id: String { "\(sourceID)-\(quote.hashValue)" }

    public var service: SourceService { SourceService.infer(externalURL: externalURL, kind: sourceKind) }

    enum CodingKeys: String, CodingKey {
        case quote
        case actionID = "action_id"
        case sourceID = "source_id"
        case sourceTitle = "source_title"
        case sourceKind = "source_kind"
        case occurredAt = "occurred_at"
        case externalURL = "external_url"
    }

    public init(
        actionID: UUID?, sourceID: UUID, sourceTitle: String?, sourceKind: SourceKind, occurredAt: Date?, externalURL: URL?,
        quote: String
    ) {
        self.actionID = actionID
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceKind = sourceKind
        self.occurredAt = occurredAt
        self.externalURL = externalURL
        self.quote = quote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try? c.decodeIfPresent(UUID.self, forKey: .actionID)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceKind = (try? c.decodeIfPresent(String.self, forKey: .sourceKind)).flatMap { $0.flatMap(SourceKind.init(rawValue:)) } ?? .note
        occurredAt = try? c.decodeIfPresent(Date.self, forKey: .occurredAt)
        externalURL = (try? c.decodeIfPresent(String.self, forKey: .externalURL)).flatMap { $0.flatMap(URL.init(string:)) }
        quote = try c.decode(String.self, forKey: .quote)
    }
}

/// 배열 안 원소 하나를 못 읽어도 나머지는 읽는다
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

struct AskRequest: Encodable {
    let question: String
}

struct StartConnectionResponse: Decodable {
    let url: URL
}

struct ConnectionRequestBody: Encodable {
    let provider: String
}

struct ConsentRequest: Encodable {
    let aiProcessing = true

    enum CodingKeys: String, CodingKey {
        case aiProcessing = "ai_processing"
    }
}
