import Foundation

// 대화 v2 (B2)와 기억 (B3 PR1)의 앱 쪽 모양. 서버 `contract.ts`의 같은 이름 스키마를 읽는다:
// 서버 head `7328e93`(B3 PR1 #123 = B2 `aa017bd` + 커밋 8개) × 이 브랜치 (`ChatContractFixtures`가 그 JSON을 고정한다).
// 앱은 RLS로 읽는 행(`conversations` · `conversation_messages` · `memory_items` · `work_contexts`)과 서버 쓰기 응답을 같은 타입으로 읽는다.
// 모르는 값은 실패로 만들지 않고(목록 전체를 못 읽게 되는 것을 막는다) 가장 덜 주장하는 쪽으로 읽는다.

/// `conversations` 행. `contextID`: 대화의 범위 (nil = All work). `textPurgedAt`: 글 보관 기한 뒤 메시지 글만 비워졌다.
/// `target`: 대화의 대상 열 (`target_kind` · `agent_connection_id` · `agent_session_id`, OA D1d). 열이 없는 옛 행은 Taskforce다
public struct ChatConversation: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String?
    public let contextID: UUID?
    public let createdAt: Date
    public let lastMessageAt: Date?
    public let lastReadAt: Date?
    public let archivedAt: Date?
    public let textPurgedAt: Date?
    public let target: ChatConversationTarget

    public static let columns = "id, title, context_id, created_at, last_message_at, last_read_at, archived_at, text_purged_at, target_kind, agent_connection_id, agent_session_id"

    enum CodingKeys: String, CodingKey {
        case id, title
        case contextID = "context_id"
        case createdAt = "created_at"
        case lastMessageAt = "last_message_at"
        case lastReadAt = "last_read_at"
        case archivedAt = "archived_at"
        case textPurgedAt = "text_purged_at"
    }

    public init(
        id: UUID, title: String? = nil, contextID: UUID? = nil, createdAt: Date, lastMessageAt: Date? = nil, lastReadAt: Date? = nil,
        archivedAt: Date? = nil, textPurgedAt: Date? = nil, target: ChatConversationTarget = .taskforce
    ) {
        self.id = id
        self.title = title
        self.contextID = contextID
        self.createdAt = createdAt
        self.lastMessageAt = lastMessageAt
        self.lastReadAt = lastReadAt
        self.archivedAt = archivedAt
        self.textPurgedAt = textPurgedAt
        self.target = target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        contextID = try c.decodeIfPresent(UUID.self, forKey: .contextID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        textPurgedAt = try c.decodeIfPresent(Date.self, forKey: .textPurgedAt)
        // 대상 열은 같은 행의 다른 키다 (`ChatConversationTarget`이 직접 읽는다)
        target = try ChatConversationTarget(from: decoder)
    }

    /// 같은 행에 다른 대상 열 (대상을 돌려주지 않는 응답 — 범위를 바꾼 PATCH 같은 — 이 알던 대상을 지우지 않게)
    func with(target: ChatConversationTarget) -> ChatConversation {
        ChatConversation(
            id: id, title: title, contextID: contextID, createdAt: createdAt, lastMessageAt: lastMessageAt, lastReadAt: lastReadAt, archivedAt: archivedAt,
            textPurgedAt: textPurgedAt, target: target
        )
    }

    /// 손대지 않은 빈 대화: 메시지가 한 번도 없었다 (`last_message_at`은 메시지를 저장할 때 선다)
    public var isUntouched: Bool { lastMessageAt == nil }
}

public struct ChatConversationResponse: Decodable, Sendable {
    public let conversation: ChatConversation
}

/// `conversation_messages.role`
public enum ChatRole: Sendable, Hashable {
    case user, assistant, event
    case other(String)

    init(raw: String) {
        switch raw {
        case "user": self = .user
        case "assistant": self = .assistant
        case "event": self = .event
        default: self = .other(raw)
        }
    }

    /// 사용자가 쓴 글인가 (나머지는 Taskforce의 말: 아바타 · 이름 없이 패널 전폭)
    public var isUser: Bool { self == .user }
}

/// 메시지가 가리키거나 만든 것 (서버가 쓴다). 없는 목록은 빈 목록으로 읽는다
public struct ChatRefs: Decodable, Sendable, Hashable {
    public let memoryItemIDs: [UUID]
    public let contextIDs: [UUID]
    public let actionIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case memoryItemIDs = "memory_item_ids"
        case contextIDs = "context_ids"
        case actionIDs = "action_ids"
    }

    public static let none = ChatRefs(memoryItemIDs: [], contextIDs: [], actionIDs: [])

    public init(memoryItemIDs: [UUID], contextIDs: [UUID], actionIDs: [UUID]) {
        self.memoryItemIDs = memoryItemIDs
        self.contextIDs = contextIDs
        self.actionIDs = actionIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memoryItemIDs = Self.ids(c, .memoryItemIDs)
        contextIDs = Self.ids(c, .contextIDs)
        actionIDs = Self.ids(c, .actionIDs)
    }

    /// 잘못된 id 하나가 메시지 전체를 못 읽게 하지 않는다
    private static func ids(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [UUID] {
        (try? c.decodeIfPresent([String].self, forKey: key))?.compactMap(UUID.init(uuidString:)) ?? []
    }
}

/// 답의 근거 인용 (`askCitationSchema`): 원문에서 그대로 잘라 낸 구절
public struct ChatCitation: Decodable, Sendable, Hashable {
    public let sourceID: String
    public let sourceTitle: String?
    public let sourceKind: String
    public let occurredAt: Date?
    public let externalURL: URL?
    public let quote: String

    enum CodingKeys: String, CodingKey {
        case quote
        case sourceID = "source_id"
        case sourceTitle = "source_title"
        case sourceKind = "source_kind"
        case occurredAt = "occurred_at"
        case externalURL = "external_url"
    }

    public init(sourceID: String, sourceTitle: String?, sourceKind: String, occurredAt: Date?, externalURL: URL?, quote: String) {
        self.sourceID = sourceID
        self.sourceTitle = sourceTitle
        self.sourceKind = sourceKind
        self.occurredAt = occurredAt
        self.externalURL = externalURL
        self.quote = quote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle)
        sourceKind = try c.decode(String.self, forKey: .sourceKind)
        occurredAt = try? c.decodeIfPresent(Date.self, forKey: .occurredAt)
        // 잘못된 링크 하나가 인용 전체를 못 읽게 하지 않는다
        externalURL = (try? c.decodeIfPresent(String.self, forKey: .externalURL)).flatMap { $0.flatMap(URL.init(string:)) }
        quote = try c.decode(String.self, forKey: .quote)
    }
}

/// assistant 답의 내용 (`content`). 앱은 인용만 쓴다: 구간 등급 배지 · 제안은 아직 그리지 않는다.
/// 무엇을 기억했는지는 `content`가 아니라 메시지의 `refs.memory_item_ids`다 (`content.used`는 답을 만들 때 읽은 것)
public struct ChatMessageContent: Decodable, Sendable, Hashable {
    public let citations: [ChatCitation]

    enum CodingKeys: String, CodingKey {
        case citations
    }

    public init(citations: [ChatCitation] = []) {
        self.citations = citations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        citations = (try? c.decodeIfPresent([ChatCitation].self, forKey: .citations)) ?? []
    }
}

/// `conversation_messages` 행. 서버 전용 열(`selected` · `reply_lease_until`)은 읽지 않는다
public struct ChatMessage: Decodable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let seq: Int
    public let role: ChatRole
    public let clientMessageID: UUID?
    public let text: String
    public let refs: ChatRefs
    public let createdAt: Date
    public let replyTo: UUID?
    public let content: ChatMessageContent?

    public static let columns = "id, conversation_id, seq, role, client_message_id, text, refs, created_at, reply_to, content"

    enum CodingKeys: String, CodingKey {
        case id, seq, role, text, refs, content
        case conversationID = "conversation_id"
        case clientMessageID = "client_message_id"
        case createdAt = "created_at"
        case replyTo = "reply_to"
    }

    public init(
        id: UUID, conversationID: UUID, seq: Int, role: ChatRole, clientMessageID: UUID? = nil, text: String, refs: ChatRefs = .none,
        createdAt: Date, replyTo: UUID? = nil, content: ChatMessageContent? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.seq = seq
        self.role = role
        self.clientMessageID = clientMessageID
        self.text = text
        self.refs = refs
        self.createdAt = createdAt
        self.replyTo = replyTo
        self.content = content
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        seq = try c.decode(Int.self, forKey: .seq)
        role = ChatRole(raw: try c.decode(String.self, forKey: .role))
        clientMessageID = try c.decodeIfPresent(UUID.self, forKey: .clientMessageID)
        text = try c.decode(String.self, forKey: .text)
        refs = (try? c.decodeIfPresent(ChatRefs.self, forKey: .refs)) ?? .none
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        replyTo = try c.decodeIfPresent(UUID.self, forKey: .replyTo)
        content = try? c.decodeIfPresent(ChatMessageContent.self, forKey: .content)
    }

    /// 이 답이 보여 줄 기억의 id: 이 답이 가리키는 것(`refs`, 서버가 쓴다). 순서를 지키고 겹치지 않는다
    public var rememberedIDs: [UUID] {
        var seen = Set<UUID>()
        return refs.memoryItemIDs.filter { seen.insert($0).inserted }
    }
}

/// `POST /api/v2/conversations/{id}/messages` 200: 저장한 사용자 메시지 + 답. 같은 제출을 다시 보내도 같은 쌍이다
public struct ChatPostedMessage: Decodable, Sendable, Hashable {
    public let message: ChatMessage
    public let reply: ChatMessage

    public init(message: ChatMessage, reply: ChatMessage) {
        self.message = message
        self.reply = reply
    }
}

/// `work_contexts` 행 (범위 = 프로젝트). popup에는 active만 (보관된 범위는 서버가 404)
public struct WorkContext: Decodable, Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        case active, archived
        case other(String)

        init(raw: String) {
            switch raw {
            case "active": self = .active
            case "archived": self = .archived
            default: self = .other(raw)
            }
        }
    }

    public let id: UUID
    public let name: String
    public let status: Status
    /// 멤버십 쓰기의 조건 (`expected_context_version`): 앱이 RLS로 읽은 값. 읽지 못했으면 nil (그 범위에는 쓰지 않는다)
    public let contextVersion: Int?
    /// 프로젝트 아이콘 (OA U2, 서버 `icon`). 풀 밖 이름 · 열이 없는 DB는 folder
    public let icon: ProjectIconName
    /// 이름 · 아이콘 · 상태를 바꿀 때의 조건 (`expected_version`, 서버 `version`). 열이 없는 DB · 읽지 못했으면 nil
    public let version: Int?

    /// 아이콘 · version 열이 없는 DB(`20261117000000_context_icon_version.sql` 전)에서는 `columnsWithoutIcon`으로 다시 읽는다 (`TaskforceReads.workContexts`)
    public static let columns = columnsWithoutIcon + ", icon, version"
    static let columnsWithoutIcon = "id, name, kind, status, context_version, last_activity_at"

    enum CodingKeys: String, CodingKey {
        case id, name, status, icon, version
        case contextVersion = "context_version"
    }

    public init(
        id: UUID, name: String, status: Status = .active, contextVersion: Int? = nil, icon: ProjectIconName = .folder, version: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.contextVersion = contextVersion
        self.icon = icon
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = Status(raw: (try? c.decode(String.self, forKey: .status)) ?? "")
        contextVersion = try? c.decodeIfPresent(Int.self, forKey: .contextVersion)
        // 모양이 어긋난 값 하나가 범위 목록 전체를 못 읽게 하지 않는다
        icon = ProjectIconName(raw: (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? nil)
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
    }

    public var isActive: Bool { status == .active }
}

// MARK: 쓰기 요청 (서버 `contract.ts`의 strict 스키마와 같은 키만 보낸다)

/// `POST /api/v2/conversations`. `id`는 앱이 정한다: 같은 id로 다시 보내면 서버가 그 대화를 돌려준다 (201 새로 · 200 이미 있음)
struct CreateConversationRequest: Encodable {
    let id: UUID
    let title: String?
    let contextID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, title
        case contextID = "context_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.lowercased, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        if let contextID {
            try c.encode(contextID.lowercased, forKey: .contextID)
        } else {
            try c.encodeNil(forKey: .contextID)
        }
    }
}

/// `POST /api/v2/conversations/{id}/messages`. 같은 `client_message_id`는 같은 제출이다: 다시 보낼 때 같은 글 · 같은 대상을 보낸다
struct PostChatMessageRequest: Encodable {
    let clientMessageID: UUID
    let text: String

    enum CodingKeys: String, CodingKey {
        case text
        case clientMessageID = "client_message_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientMessageID.lowercased, forKey: .clientMessageID)
        try c.encode(text, forKey: .text)
    }
}

/// `PATCH /api/v2/conversations/{id}`: 헤더 ProjectLink에서 사용자가 명시적으로 고른 범위. nil = All work (`null`을 보낸다)
struct UpdateConversationRequest: Encodable {
    let contextID: UUID?

    enum CodingKeys: String, CodingKey {
        case contextID = "context_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let contextID {
            try c.encode(contextID.lowercased, forKey: .contextID)
        } else {
            try c.encodeNil(forKey: .contextID)
        }
    }
}
