import Foundation

/// 대화 행의 서버 쪽 새로움 순서. 응답이 끝난 순서가 아니라 이 순서로 "더 새 행"을 가린다 (`ChatStore`: 목록 교체 · id로 읽은 행 · 직접 읽은 행).
/// `conversations`에는 `updated_at` · version 열이 없다 (`20261103000000_context_core.sql`). 그래서 서버가 행을 바꿀 때 앞으로만 가는 열로 순서를 만든다:
/// `last_message_at`(메시지를 저장할 때 선다, nil이 가장 오래됨) → `last_read_at` → `text_purged_at`(한 번 서면 지워지지 않는다)
struct ChatRowVersion: Comparable, Sendable {
    let lastMessageAt: Date
    let lastReadAt: Date
    let textPurged: Bool

    static func < (lhs: ChatRowVersion, rhs: ChatRowVersion) -> Bool {
        if lhs.lastMessageAt != rhs.lastMessageAt { return lhs.lastMessageAt < rhs.lastMessageAt }
        if lhs.lastReadAt != rhs.lastReadAt { return lhs.lastReadAt < rhs.lastReadAt }
        return !lhs.textPurged && rhs.textPurged
    }
}

extension ChatConversation {
    var rowVersion: ChatRowVersion {
        ChatRowVersion(lastMessageAt: lastMessageAt ?? .distantPast, lastReadAt: lastReadAt ?? .distantPast, textPurged: textPurgedAt != nil)
    }
}
