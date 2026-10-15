import Foundation
import Testing
@testable import TaskforceKit

/// 세션 패널이 대화를 여는 길 (OA U2): 세션 패널은 대화 id만 안다. 대화 목록을 아직 읽지 않았거나(앱을 연 뒤 처음) 방금 만든 세션이면
/// `ensureLoaded`는 목록에 없는 대화라 아무것도 읽지 않는다 → 목록을 먼저 읽고 글을 읽는 `ensureLoadedReadingListFirst`
@MainActor
struct ChatStoreSessionPanelTests {
    let gateway = FakeChatGateway()
    let scope = ChatTestAccount.fixedScope()

    func store() -> ChatStore { ChatStore(gateway: gateway, scope: scope, now: { .test(500) }) }

    func serve(_ chats: [ChatConversation], messages: [UUID: [ChatMessage]] = [:]) {
        gateway.conversationsHandler = { chats }
        gateway.messagesHandler = { messages[$0] ?? [] }
        gateway.lastMessagesHandler = { ids in
            var result: [UUID: ChatMessage] = [:]
            for id in ids { if let last = messages[id]?.last { result[id] = last } }
            return result
        }
    }

    @Test func aConversationTheListDoesNotKnowYetIsLoadedAfterTheListIsRead() async {
        let a = Chats.conversation(1, title: "A", last: 10)
        serve([a], messages: [a.id: [Chats.message(1, in: a.id, seq: 1, role: .assistant, text: "Draft v2 is ready.")]])
        let chat = store()
        chat.ensureLoaded(a.id)
        await chat.settle()
        #expect(chat.screen(for: a.id) == .blank, "목록을 읽기 전의 ensureLoaded는 아무것도 읽지 않는다 (지금까지의 동작)")
        chat.ensureLoadedReadingListFirst(a.id)
        await chat.settle()
        #expect(chat.turns(for: a.id).map(\.text) == ["Draft v2 is ready."])
        #expect(chat.screen(for: a.id) == .ready(problem: nil))
    }

    @Test func aKnownConversationDoesNotReadTheListAgain() async {
        let a = Chats.conversation(1, title: "A", last: 10)
        serve([a], messages: [a.id: [Chats.message(1, in: a.id, seq: 1, role: .assistant, text: "hi")]])
        let chat = store()
        await chat.refresh()
        let listReads = gateway.calls(prefix: "conversations").count
        chat.ensureLoadedReadingListFirst(a.id)
        await chat.settle()
        #expect(gateway.calls(prefix: "conversations").count == listReads, "이미 아는 대화는 목록을 다시 읽지 않는다")
        #expect(chat.turns(for: a.id).map(\.text) == ["hi"])
    }

    @Test func aConversationTheServerDoesNotHaveIsNotRead() async {
        let a = Chats.conversation(1, title: "A", last: 10)
        serve([a])
        let chat = store()
        let missing = UUID()
        chat.ensureLoadedReadingListFirst(missing)
        await chat.settle()
        #expect(chat.screen(for: missing) == .blank)
        #expect(!gateway.calls(prefix: "messages").contains { $0.contains(missing.uuidString) }, "목록에도 없는 대화의 글은 읽지 않는다")
    }

    @Test func aFailedListReadLeavesTheConversationUnreadAndKeepsTheStoreNavigation() async {
        let a = Chats.conversation(1, title: "A", last: 10)
        serve([a])
        gateway.conversationsHandler = { throw URLError(.notConnectedToInternet) }
        let chat = store()
        let before = (chat.currentID, chat.mode, chat.focusRequest)
        chat.ensureLoadedReadingListFirst(a.id)
        await chat.settle()
        #expect(chat.screen(for: a.id) == .blank)
        #expect((chat.currentID, chat.mode, chat.focusRequest) == before, "읽기만 한다: 저장소의 현재 대화 · 모드 · 포커스는 그대로")
    }
}
