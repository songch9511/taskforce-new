import Foundation
import Testing
@testable import TaskforceKit

/// Chats의 순수 규칙: 이름 · 정렬 · 미리보기 · 빈 대화 다시 쓰기 · 보내기 입력 · 문구
struct ChatRulesTests {
    @Test func titleIsTheFirstMessageOnOneLine() {
        #expect(ChatTitle.make(from: "  Use the shorter FAQ\n\n on   both pages ") == "Use the shorter FAQ on both pages")
        #expect(ChatTitle.make(from: "  \n ") == nil)
        let long = String(repeating: "가", count: 80)
        let title = ChatTitle.make(from: long)
        #expect(title == String(repeating: "가", count: 60) + "…")
        #expect(ChatTitle.make(from: String(repeating: "a", count: 60)) == String(repeating: "a", count: 60))
        // 서버 한도(200자) 안
        #expect((title?.utf16.count ?? 0) <= 200)
    }

    @Test func composerNeedsRealTextWithinTheServerLimit() {
        #expect(!ChatComposerRules.isSendable("") && !ChatComposerRules.isSendable(" \n\t "))
        #expect(ChatComposerRules.isSendable("hi") && ChatComposerRules.normalized("  hi \n") == "hi")
        #expect(ChatComposerRules.isSendable(String(repeating: "a", count: 4000)))
        #expect(!ChatComposerRules.isSendable(String(repeating: "a", count: 4001)))
        // 서버는 UTF-16으로 센다
        #expect(!ChatComposerRules.isSendable(String(repeating: "😀", count: 2001)))
    }

    @Test func historyIsNewestFirstByLastActivityAndNeverShowsArchived() {
        let old = Chats.conversation(1, title: "Old", at: 0, last: 100)
        let revived = Chats.conversation(2, title: "Revived", at: 10, last: 900)
        let fresh = Chats.conversation(3, at: 500)
        let archived = ChatConversation(id: ChatContractFixtures.id(4, prefix: "bcb50000"), title: "Gone", createdAt: .test(), lastMessageAt: .test(1000), archivedAt: .test(1001))
        let local = LocalChat(id: ChatContractFixtures.id(5, prefix: "bcb50000"), createdAt: .test(700))
        let entries = ChatHistoryRules.entries(conversations: [old, fresh, archived, revived], locals: [local], previews: [:], drafts: [:])
        #expect(entries.map(\.title) == ["Revived", "New chat", "New chat", "Old"])
        #expect(entries.map(\.isLocal) == [false, true, false, false])
        #expect(!entries.contains { $0.title == "Gone" })
    }

    /// 초안이 미리보기를 이기고(`Draft · …`), 비어 있으면 "No messages yet", 읽지 못한 것은 줄을 비운다
    @Test func previewLineFollowsTheDesign() {
        let used = Chats.conversation(1, title: "Used", last: 10)
        let empty = Chats.conversation(2, title: "Empty", at: 5)
        let entries = ChatHistoryRules.entries(
            conversations: [used, empty], locals: [], previews: [used.id: "Should I finish\nShape's design today?"],
            drafts: [empty.id: "  Can you compare plan B with  "]
        )
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0) })
        #expect(byTitle["Used"]?.previewText == "Should I finish Shape's design today?")
        #expect(byTitle["Empty"]?.previewText == "Draft · Can you compare plan B with")
        let plain = ChatHistoryRules.entries(conversations: [empty], locals: [], previews: [:], drafts: [:])
        #expect(plain[0].previewText == "No messages yet")
        let unread = ChatHistoryRules.entries(conversations: [used], locals: [], previews: [:], drafts: [:])
        #expect(unread[0].previewText == nil)
        // 제목이 없는데 메시지가 있는 대화는 "New chat"이 아니다
        let untitled = Chats.conversation(3, title: nil, last: 20)
        #expect(ChatHistoryRules.entries(conversations: [untitled], locals: [], previews: [:], drafts: [:])[0].title == "Chat")
    }

    @Test func datesAreRealDates() {
        let tz = TimeZone(identifier: "Asia/Seoul")!
        let now = Date(timeIntervalSince1970: 1_791_709_200)  // 2026-10-11
        #expect(ChatHistoryRules.dateLabel(now, now: now, timeZone: tz) == "Oct 11")
        #expect(ChatHistoryRules.dateLabel(now.addingTimeInterval(-86_400 * 11), now: now, timeZone: tz) == "Sep 30")
        #expect(ChatHistoryRules.dateLabel(now.addingTimeInterval(-86_400 * 400), now: now, timeZone: tz).hasSuffix("2025"))
    }

    @Test func reuseRulePrefersTheOpenEmptyChatThenTheNewestEmpty() {
        let used = Chats.conversation(1, title: "Used", last: 10)
        let emptyOld = Chats.conversation(2, at: 5)
        let emptyNew = Chats.conversation(3, at: 50)
        let local = LocalChat(id: ChatContractFixtures.id(9, prefix: "bcb50000"), createdAt: .test(30))
        // 열린 대화가 비어 있으면 그것
        #expect(ChatHistoryRules.reusableEmptyChat(current: emptyOld.id, conversations: [used, emptyOld, emptyNew], locals: [local], occupied: []) == emptyOld.id)
        // 아니면 가장 최근 빈 대화
        #expect(ChatHistoryRules.reusableEmptyChat(current: used.id, conversations: [used, emptyOld, emptyNew], locals: [local], occupied: []) == emptyNew.id)
        // 쓴 대화뿐이면 없음 → 새로 만든다
        #expect(ChatHistoryRules.reusableEmptyChat(current: used.id, conversations: [used], locals: [], occupied: []) == nil)
        // 보내는 중이거나 실패한 글이 남은 대화는 비어 있지 않다
        #expect(ChatHistoryRules.reusableEmptyChat(current: nil, conversations: [emptyNew], locals: [local], occupied: [emptyNew.id]) == local.id)
    }

    @Test func nothingInTheCopyIsBanned() {
        let strings = [
            ChatCopy.noConversations, ChatCopy.newChat, ChatCopy.emptyChatPreview, ChatCopy.composerPlaceholder, ChatCopy.unavailable,
            ChatCopy.consentNeeded, ChatCopy.couldNotLoad, ChatCopy.sending, ChatCopy.notSent, ChatCopy.noReplyYet, ChatCopy.tryAgain,
            MemoryCopy.listFootnote, MemoryCopy.inferredFootnote, MemoryCopy.noLongerRemembered, MemoryCopy.purgedStatement,
            MemoryCopy.writesUnavailable, MemoryCopy.rewriteToSave, MemoryCopy.emptyList,
        ]
        for text in strings {
            for banned in ["caught up", "nothing here", "claude", "anthropic", "!", "✨", "magic"] {
                #expect(!text.localizedCaseInsensitiveContains(banned), "\(text)")
            }
        }
        // 디자인 문구는 글자 그대로
        #expect(ChatCopy.noConversations == "No conversations yet.")
        #expect(MemoryCopy.listFootnote == "Remembered things are context, not permission. They never give an agent access to anything.")
        #expect(MemoryCopy.inferredFootnote == "Inferred items are not used in any work until you confirm them.")
        #expect(MemoryCopy.forgetDetail == "Work already done with it stays as it is.")
    }
}
