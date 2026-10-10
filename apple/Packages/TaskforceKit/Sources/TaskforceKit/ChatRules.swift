import Foundation

// Chats의 순수 규칙: 대화 이름 · 목록 정렬과 미리보기 · 빈 대화 다시 쓰기 · 보내기 입력 · 문구.
// 화면 없이 테스트로 고정한다 (`ChatRulesTests`). 서버 판정(기억 효력 · 범위 우선)은 여기에 없다.

/// Chats 화면의 글. 디자인 README의 문구는 글자 그대로, 디자인에 없는 말은 `New copy`로 표시하고 `b3-mac-notes.md`에 적는다
public enum ChatCopy {
    // 디자인 (ChatHistory · ChatItem · Composer · EmptyState)
    public static let noConversations = "No conversations yet."
    public static let newChat = "New chat"
    public static let emptyChatPreview = "No messages yet"
    public static let composerPlaceholder = "Ask Taskforce…"
    public static let composerLabel = "Reply to Taskforce"
    public static let historyTitle = "Chat history"
    public static let chatsTitle = "Chats"
    public static let draftPrefix = "Draft · "
    /// 서버 gate가 꺼졌을 때의 기존 문구 방식 ("Ask isn't available yet.")
    public static let unavailable = "Chats aren't available yet."
    /// 동의 전 (런처의 기존 문구)
    public static let consentNeeded = "Allow AI processing to continue"
    public static let allowAIButton = "Connections"

    // New copy
    /// 읽기 실패 (All work의 "Couldn't load your work"에 맞춘 Chats 판)
    public static let couldNotLoad = "Couldn't load your chats"
    public static let couldNotLoadChat = "Couldn't load this chat"
    /// 제목이 없는데 메시지가 있는 대화 (Mac 앱은 첫 메시지로 제목을 정한다: 다른 길로 만든 대화)
    public static let untitled = "Chat"
    public static let sending = "Sending…"
    public static let notSent = "Not sent"
    public static let noReplyYet = "No reply yet"
    public static let tryAgain = "Try again"
    /// 뒤에 새 메시지가 있어 서버가 답하지 않은 메시지
    public static let notAnswered = "Not answered"
    // ProjectLink (디자인 README: Set by you · No clear link, 이유는 Card)
    public static let projectUngrouped = "Ungrouped"
    public static let projectReasonUser = "You linked this chat to this project."
    public static let projectReasonNone = "This chat isn't linked to a project."
    public static let projectLabel = "Project"
}

/// 대화 이름 (첫 보낸 메시지가 이름이 된다, 디자인 README Chat history)
public enum ChatTitle {
    public static let maxLength = 60

    /// 첫 메시지 → 이름: 줄바꿈 · 연속 공백을 하나로, 60자(글자 단위)까지, 넘으면 말줄임표. 빈 글이면 nil
    public static func make(from text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// 보내는 글 (Composer): Enter로 보내고, 빈 글은 보낼 수 없다. 서버는 앞뒤 공백을 걷고 1–4000자(UTF-16)를 받는다
public enum ChatComposerRules {
    public static let maxLength = 4000

    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 보낼 수 있는 글인가 (비어 있지 않고 서버 한도 안)
    public static func isSendable(_ text: String) -> Bool {
        let normalized = normalized(text)
        return !normalized.isEmpty && normalized.utf16.count <= maxLength
    }
}

/// 손대지 않은 빈 대화 (아직 서버에 없다: 첫 메시지를 보낼 때 만든다). 메모리에만 있다
public struct LocalChat: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    /// 헤더 ProjectLink에서 미리 고른 프로젝트 (첫 메시지를 보낼 때 대화를 만들며 보낸다)
    public var contextID: UUID?

    public init(id: UUID = UUID(), createdAt: Date, contextID: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.contextID = contextID
    }
}

/// 목록 한 줄 (ChatItem): 이름 · 날짜 · 미리보기
public struct ChatListEntry: Sendable, Hashable, Identifiable {
    public enum Preview: Sendable, Hashable {
        /// 쓰던 글 (초안이 미리보기를 이긴다)
        case draft(String)
        /// 마지막 메시지
        case message(String)
        /// 메시지가 없는 대화
        case empty
        /// 메시지는 있는데 미리보기를 읽지 못했다 (보관 기한으로 글이 비워졌거나 최근 읽은 안에 없음): 줄을 비운다
        case unknown
    }

    public let id: UUID
    public let title: String
    public let date: Date
    public let preview: Preview
    /// 서버에 아직 없는 빈 대화
    public let isLocal: Bool

    /// ChatItem이 그리는 미리보기 줄 (모르면 nil)
    public var previewText: String? {
        switch preview {
        case .draft(let text): ChatCopy.draftPrefix + text
        case .message(let text): text
        case .empty: ChatCopy.emptyChatPreview
        case .unknown: nil
        }
    }
}

public enum ChatHistoryRules {
    /// 목록: 새 것이 위 (마지막 활동 = 마지막 메시지, 없으면 만든 때). 같은 시각이면 id로 고정한다
    public static func entries(
        conversations: [ChatConversation], locals: [LocalChat], previews: [UUID: String], drafts: [UUID: String]
    ) -> [ChatListEntry] {
        var result: [ChatListEntry] = []
        for chat in conversations where chat.archivedAt == nil {
            let hasMessages = !chat.isUntouched
            let title = chat.title.flatMap { $0.isEmpty ? nil : $0 } ?? (hasMessages ? ChatCopy.untitled : ChatCopy.newChat)
            result.append(ChatListEntry(
                id: chat.id, title: title, date: chat.lastMessageAt ?? chat.createdAt,
                preview: preview(hasMessages: hasMessages, last: previews[chat.id], draft: drafts[chat.id]), isLocal: false
            ))
        }
        for chat in locals {
            result.append(ChatListEntry(
                id: chat.id, title: ChatCopy.newChat, date: chat.createdAt,
                preview: preview(hasMessages: false, last: nil, draft: drafts[chat.id]), isLocal: true
            ))
        }
        return result.sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
    }

    private static func preview(hasMessages: Bool, last: String?, draft: String?) -> ChatListEntry.Preview {
        if let draft = draft?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
            return .draft(oneLine(draft))
        }
        if let last, case let text = oneLine(last), !text.isEmpty { return .message(text) }
        return hasMessages ? .unknown : .empty
    }

    /// 한 줄로: 줄바꿈 · 연속 공백을 하나로
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// New chat이 다시 쓸 손대지 않은 빈 대화. 지금 열린 대화가 비어 있으면 그것, 아니면 가장 최근 빈 대화 (없으면 nil → 새로 만든다).
    /// 빈 대화 = 메시지가 한 번도 없음 (초안이 있어도 빈 대화다: 다시 열면 그 초안이 보인다). 보내는 중이거나 보내지 못한 글이 남은 대화(`occupied`)는 비어 있지 않다
    public static func reusableEmptyChat(
        current: UUID?, conversations: [ChatConversation], locals: [LocalChat], occupied: Set<UUID>
    ) -> UUID? {
        var empties: [(id: UUID, createdAt: Date)] = []
        for chat in conversations where chat.archivedAt == nil && chat.isUntouched && !occupied.contains(chat.id) {
            empties.append((chat.id, chat.createdAt))
        }
        for chat in locals where !occupied.contains(chat.id) {
            empties.append((chat.id, chat.createdAt))
        }
        if let current, empties.contains(where: { $0.id == current }) { return current }
        return empties.max { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }?.id
    }

    /// 목록의 날짜: 실제 날짜 ("Oct 8", 올해가 아니면 "Oct 8, 2025"). "Today" · "Sample"은 쓰지 않는다
    public static func dateLabel(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        DueText.date(LocalDate(date: date, timeZone: timeZone), today: LocalDate(date: now, timeZone: timeZone))
    }
}
