import Foundation

// 저장된 Claude 데스크톱 대화의 값 · 규칙 (OA D3v-m, 계약 `handoffs/oa-external-sessions-contract.md` 27장 · DZ `handoffs/oa-desktop-chat-view-dz` · `docs/agent-gateway.md` 22장).
// 앱은 두 표(`claude_app_chats` · `claude_app_chat_messages`)와 `bridges.device_name`을 **RLS로 직접 읽는다** (쓰기는 지우기 route뿐). 읽은 글(제목 · 말)은 메모리에만 두고 로그 · 디스크에 남기지 않는다.

/// 이 화면의 새 문구: 계약 27장에서 승인된 V1–V6 · V8–V12 (V7 "No saved chats"는 iPhone 빈 화면이라 Mac에 없다).
/// **V13 "Couldn't delete some chats"는 쓰지 않는다**: 서버의 모두 지우기가 원자적이라 일부만 지워지는 일이 없다 (코디네이터 결정 2026-10-23) — 실패는 V5 "Couldn't delete" + 승인된 이유 줄 + Try again이다.
/// **이 밖의 글자를 더하려면 먼저 승인을 받는다.** "저장 중" 표시 · Undo는 어디에도 없다 (Q-D3v3 · DZ "되돌리기 없음": 서버가 바로 지우고 묘비로 같은 말의 재저장도 막는다)
public enum SavedChatsCopy {
    /// V1: Sessions의 절 머리 · Settings › Account의 절
    public static let title = "Saved chats"
    /// V2: 제목이 null인 줄 · 머리
    public static let untitled = "Untitled"
    /// V3 · V4: 지우기 확인 카드
    public static let deleteChatTitle = "Delete this chat?"
    public static let deleteChatDetail = "Deletes the saved copy from all your devices"
    /// V5: 지우기 실패의 굵은 첫 말 (이유 줄은 이미 승인된 오프라인 · 일반 말)
    public static let couldNotDelete = "Couldn't delete"
    /// V6: 절 읽기 실패 (+ "Try again")
    public static let couldNotLoad = "Couldn't load saved chats"
    /// V8–V12: Settings › Account의 모두 지우기 (실패는 V5 `couldNotDelete` + 이유 줄)
    public static let deleteAllRow = "Delete all saved chats"
    public static let deleteAllButton = "Delete…"
    public static let deleteAllTitle = "Delete all saved chats?"
    public static let deleteAllDetail = "Deletes the saved copies from all your devices"
    public static let deleteAllConfirm = "Delete all"

    /// 이미 있는 말 ("Delete"는 확인 카드의 동사 · 머리 단추 · 오른쪽 클릭 메뉴): 새 문구가 아니다
    public static let delete = "Delete"

    /// 승인된 새 문구 전체 (시험이 한 글자까지 맞춘다)
    public static let approved: [String] = [
        title, untitled, deleteChatTitle, deleteChatDetail, couldNotDelete, couldNotLoad,
        deleteAllRow, deleteAllButton, deleteAllTitle, deleteAllDetail, deleteAllConfirm,
    ]
}

/// `claude_app_chats` 한 행 (앱이 읽는 네 열만: `session_ref` · 본문은 읽지 않는다)
public struct SavedChatRecord: Decodable, Equatable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let bridgeID: UUID
    public let title: String?
    public let lastMessageAt: Date

    public init(id: UUID, bridgeID: UUID, title: String?, lastMessageAt: Date) {
        self.id = id
        self.bridgeID = bridgeID
        self.title = title
        self.lastMessageAt = lastMessageAt
    }

    public static let columns = "id, bridge_id, title, last_message_at"

    /// 제목 · id를 찍지 않는다
    public var description: String { "SavedChatRecord()" }
    public var debugDescription: String { description }

    enum CodingKeys: String, CodingKey {
        case id, title
        case bridgeID = "bridge_id"
        case lastMessageAt = "last_message_at"
    }
}

/// Sessions의 Saved chats 줄 하나. 기기 이름은 **이미 규칙을 지난 값**이다: 이 Mac이 보낸 것 · 이름이 없는 Mac은 nil (시각만 보인다)
public struct SavedChatRow: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    /// 서버의 제목. 없거나 빈 글이면 nil
    public let title: String?
    public let lastMessageAt: Date
    public let deviceName: String?

    public init(id: UUID, title: String?, lastMessageAt: Date, deviceName: String?) {
        self.id = id
        self.title = SavedChatRules.cleaned(title)
        self.lastMessageAt = lastMessageAt
        self.deviceName = SavedChatRules.cleaned(deviceName)
    }

    public var isUntitled: Bool { title == nil }

    /// 줄 · 머리의 제목: 제목이 없으면 "Untitled"
    public var displayTitle: String { title ?? SavedChatsCopy.untitled }

    /// 제목 · id를 찍지 않는다
    public var description: String { "SavedChatRow(untitled: \(isUntitled))" }
    public var debugDescription: String { description }
}

/// 앱이 읽는 `claude_app_chat_messages`의 칸 (`mac_ref` · `reply_to`는 읽지 않는다). 역할은 글 그대로 들고 있다가 `SavedChatMessage`가 모르는 값을 거른다
public struct SavedChatMessageRecord: Decodable, Equatable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let role: String
    public let body: String
    public let truncated: Bool
    public let toolNames: [String]
    public let saidAt: Date
    public let seq: Int64

    public init(id: UUID, role: String, body: String, truncated: Bool, toolNames: [String], saidAt: Date, seq: Int64) {
        self.id = id
        self.role = role
        self.body = body
        self.truncated = truncated
        self.toolNames = toolNames
        self.saidAt = saidAt
        self.seq = seq
    }

    public static let columns = "id, role, body, truncated, tool_names, said_at, seq"

    enum CodingKeys: String, CodingKey {
        case id, role, body, truncated, seq
        case toolNames = "tool_names"
        case saidAt = "said_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        body = try c.decode(String.self, forKey: .body)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        toolNames = try c.decodeIfPresent([String].self, forKey: .toolNames) ?? []
        saidAt = try c.decode(Date.self, forKey: .saidAt)
        seq = try c.decode(Int64.self, forKey: .seq)
    }

    /// 글을 찍지 않는다
    public var description: String { "SavedChatMessageRecord(role: \(role))" }
    public var debugDescription: String { description }
}

/// 화면이 그리는 말 하나 (역할을 아는 것만)
public struct SavedChatMessage: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Role: Equatable, Sendable { case user, assistant }

    public let id: UUID
    public let role: Role
    public let body: String
    public let truncated: Bool
    /// 이 답 **앞에서** 쓴 도구 단계의 이름만, 순서대로 (≤ 40). 사용자 글은 비어 있다
    public let toolNames: [String]
    public let saidAt: Date
    public let seq: Int64

    public init(id: UUID, role: Role, body: String, truncated: Bool, toolNames: [String], saidAt: Date, seq: Int64) {
        self.id = id
        self.role = role
        self.body = body
        self.truncated = truncated
        self.toolNames = toolNames
        self.saidAt = saidAt
        self.seq = seq
    }

    /// 모르는 역할이면 nil (더 새 서버의 새 역할이 보기를 깨뜨리지 않는다)
    public init?(_ record: SavedChatMessageRecord) {
        let role: Role
        switch record.role {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        self.init(id: record.id, role: role, body: record.body, truncated: record.truncated, toolNames: record.toolNames, saidAt: record.saidAt, seq: record.seq)
    }

    public var description: String { "SavedChatMessage(role: \(role))" }
    public var debugDescription: String { description }
}

/// 줄 · 말을 정하는 순수 규칙
public enum SavedChatRules {
    /// 처음 보이는 줄 수 (그다음은 Show all)
    public static let foldLimit = 3
    /// 한 번에 읽는 대화 수 (`range`)
    public static let pageSize = 20

    /// 앞뒤 공백을 걷고 빈 글이면 nil
    static func cleaned(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 기기 이름: **이 Mac이 보낸 것은 반복하지 않고**, 이름이 없는(null · 빈 글 · 폐기로 비워진) Mac은 시각만 보인다.
    /// 이 Mac의 bridge를 아직 모르면(`thisMac == nil`) 이름이 있는 Mac은 이름을 보인다
    public static func deviceName(bridgeID: UUID, names: [UUID: String], thisMac: UUID?) -> String? {
        if let thisMac, bridgeID == thisMac { return nil }
        return cleaned(names[bridgeID])
    }

    /// 서버 순서(새 대화가 위) 그대로의 줄들
    public static func rows(_ records: [SavedChatRecord], deviceNames: [UUID: String], thisMac: UUID?) -> [SavedChatRow] {
        records.map { record in
            SavedChatRow(
                id: record.id, title: record.title, lastMessageAt: record.lastMessageAt,
                deviceName: deviceName(bridgeID: record.bridgeID, names: deviceNames, thisMac: thisMac)
            )
        }
    }

    /// 접힌 목록: 처음 셋 + Show all
    public struct Fold: Equatable, Sendable {
        public var visible: [SavedChatRow]
        public var hiddenCount: Int
        /// Show all · Show less 링크가 있나 (셋보다 많다)
        public var togglesFold: Bool
        public var expanded: Bool
    }

    public static func fold(_ rows: [SavedChatRow], expanded: Bool) -> Fold {
        let toggles = rows.count > foldLimit
        let open = expanded && toggles
        return Fold(
            visible: open ? rows : Array(rows.prefix(foldLimit)), hiddenCount: open ? 0 : max(0, rows.count - foldLimit), togglesFold: toggles, expanded: open
        )
    }
}

public enum SavedChatMessages {
    /// 보이는 순서: `said_at`, 같으면 `seq` 오름차순. 모르는 역할은 뺀다
    public static func ordered(_ records: [SavedChatMessageRecord]) -> [SavedChatMessage] {
        records.compactMap { SavedChatMessage($0) }.sorted { lhs, rhs in
            lhs.saidAt != rhs.saidAt ? lhs.saidAt < rhs.saidAt : lhs.seq < rhs.seq
        }
    }
}
