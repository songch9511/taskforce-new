import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 대화의 이벤트 줄 · 잘린 답 · View full (OA D4a-17 · 18)
/// - `role = 'event'` 행은 서버가 쓴 글을 한 줄로 보인다 (앱은 글을 만들지 않는다)
/// - 서버가 32KB에서 자른 답(`content.truncated`)은 이 Mac 원장에 전문이 있을 때만 View full 링크가 보이고, 누르면 그 자리에서 펼친다
@MainActor
struct ChatStoreAgentEventTests {
    typealias Fx = AgentFx
    let gateway = FakeChatGateway()
    let scope = ChatTestAccount.fixedScope()
    let key = "agent-message:77777777-0000-4000-8000-000000000001:" + String(repeating: "ab", count: 32)

    func store(scope: AccountScope? = nil) -> ChatStore {
        let chat = ChatStore(gateway: gateway, scope: scope ?? self.scope, now: { .test(500) })
        return chat
    }

    func open(_ chat: ChatStore, _ conversation: ChatConversation, _ messages: [ChatMessage]) async {
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in messages }
        gateway.lastMessagesHandler = { _ in [:] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        await chat.settle()
    }

    func agentReply(_ n: Int, in conversation: UUID, seq: Int, text: String = "Draft v2 covers the Pro monthly…", truncated: Bool, key: String? = nil) -> ChatMessage {
        ChatMessage(
            id: ChatContractFixtures.id(n, prefix: "aaaa0000"), conversationID: conversation, seq: seq, role: .assistant, text: text, createdAt: .test(Double(seq)),
            content: ChatMessageContent(truncated: truncated), externalEventID: key
        )
    }

    // MARK: 디코딩

    @Test func theMessageReadsTheTruncatedFlagAndTheServerKeyAndTheEventRole() throws {
        #expect(ChatMessage.columns.contains("external_event_id"))
        let json = """
        {"id":"aaaa0000-0000-4000-8000-000000000001","conversation_id":"bcb50000-0000-4000-8000-000000000001","seq":3,"role":"assistant","client_message_id":null,"text":"cut…",
         "refs":{},"created_at":"2026-10-10T15:27:34.000Z","reply_to":null,"content":{"author":{"kind":"agent","adapter":"agent:codex"},"kind":"reply","truncated":true},
         "external_event_id":"\(key)"}
        """
        let message = try TaskforceJSON.decoder().decode(ChatMessage.self, from: Data(json.utf8))
        #expect(message.content?.truncated == true && message.externalEventID == key && message.role == .assistant)
        let plain = """
        {"id":"aaaa0000-0000-4000-8000-000000000001","conversation_id":"bcb50000-0000-4000-8000-000000000001","seq":3,"role":"assistant","client_message_id":null,"text":"whole",
         "refs":{},"created_at":"2026-10-10T15:27:34.000Z","reply_to":null,"content":{"author":{"kind":"agent","adapter":"agent:codex"},"kind":"reply"}}
        """
        let untouched = try TaskforceJSON.decoder().decode(ChatMessage.self, from: Data(plain.utf8))
        #expect(untouched.content?.truncated == false && untouched.externalEventID == nil, "열이 없는 행 · 자르지 않은 글")
        let event = json.replacingOccurrences(of: "\"role\":\"assistant\"", with: "\"role\":\"event\"")
        #expect(try TaskforceJSON.decoder().decode(ChatMessage.self, from: Data(event.utf8)).role == .event)
    }

    // MARK: 이벤트 줄

    @Test func aRoleEventRowIsOneLineOfTheServersWords() async {
        let conversation = Fx.conversation()
        let event = ChatMessage(id: ChatContractFixtures.id(2, prefix: "aaaa0000"), conversationID: conversation.id, seq: 2, role: .event, text: "Opened in Terminal", createdAt: .test(2))
        let user = Fx.user(1, in: conversation.id, seq: 1)
        let chat = store()
        await open(chat, conversation, [user, event])
        let turns = chat.turns(for: conversation.id)
        #expect(turns.map(\.text) == ["Fix the pricing table", "Opened in Terminal"])
        #expect(turns[1].isEvent && !turns[1].isUser && turns[1].delivery == nil && !turns[0].isEvent)
        #expect(turns[1].citations.isEmpty && turns[1].rememberedIDs.isEmpty)
    }

    @Test func anEventRowKeepsTheServersOrderAmongTheMessagesAndWritesNothingOfItsOwn() async {
        let conversation = Fx.conversation()
        let texts = ["Opened in Terminal", "Resumed here", "Queued messages cancelled", "Answered on this Mac"]
        let events = texts.enumerated().map {
            ChatMessage(id: ChatContractFixtures.id($0.offset + 10, prefix: "aaaa0000"), conversationID: conversation.id, seq: $0.offset + 1, role: .event, text: $0.element, createdAt: .test(Double($0.offset)))
        }
        let chat = store()
        await open(chat, conversation, events)
        #expect(chat.turns(for: conversation.id).map(\.text) == texts, "서버 글 그대로, 같은 차례")
        #expect(chat.turns(for: conversation.id).allSatisfy { $0.isEvent })
    }

    // MARK: View full

    @Test func theLinkShowsOnlyWhenThisMacHasTheFullTextAndExpandsInPlace() async {
        let conversation = Fx.conversation()
        let cut = agentReply(1, in: conversation.id, seq: 1, truncated: true, key: key)
        let full = String(repeating: "Mina asked for Thursday. ", count: 2000)
        let chat = store()
        chat.fullTextLookup = { requested in requested == self.key ? full : nil }
        await open(chat, conversation, [cut])
        var turn = chat.turns(for: conversation.id)[0]
        #expect(turn.isTruncated && turn.canViewFull && turn.fullText == nil, "링크는 보이고 전문은 아직 펼치지 않았다")
        chat.viewFull(cut.id)
        turn = chat.turns(for: conversation.id)[0]
        #expect(turn.fullText == full && turn.canViewFull, "그 자리에서 펼친다 (수만 자)")
        // 대화를 다시 읽어도 펼친 채다
        await chat.loadThread(conversation.id)
        await chat.settle()
        #expect(chat.turns(for: conversation.id)[0].fullText == full)
    }

    @Test func noLinkWhenTheMacHasNoFullTextOrTheReplyWasNotCut() async {
        let conversation = Fx.conversation()
        let missing = agentReply(1, in: conversation.id, seq: 1, truncated: true, key: key)
        let noKey = agentReply(2, in: conversation.id, seq: 2, truncated: true, key: nil)
        let whole = agentReply(3, in: conversation.id, seq: 3, truncated: false, key: key)
        let chat = store()
        chat.fullTextLookup = { _ in nil }
        await open(chat, conversation, [missing, noKey, whole])
        #expect(chat.turns(for: conversation.id).map(\.canViewFull) == [false, false, false], "다른 Mac이거나 정리됐으면 링크가 없다")
        chat.viewFull(missing.id)
        #expect(chat.turns(for: conversation.id)[0].fullText == nil, "없는 전문을 펼치지 않는다")
        // 자르지 않은 글은 찾지도 않는다
        let looked = Mutex2([String]())
        let again = store()
        again.fullTextLookup = { requested in
            looked.value.append(requested)
            return "x"
        }
        await open(again, conversation, [whole, noKey])
        #expect(looked.value.isEmpty)
        #expect(again.turns(for: conversation.id).map(\.canViewFull) == [false, false])
    }

    /// 없는 전문은 펼치지 않는다: 링크가 없을 때 눌러도 아무것도 남지 않는다 (나중에 전문이 찾아져도 저절로 펼쳐지지 않는다)
    @Test func pressingViewFullBeforeTheTextIsFoundLeavesNothingToExpandLater() async {
        let conversation = Fx.conversation()
        let cut = agentReply(1, in: conversation.id, seq: 1, truncated: true, key: key)
        let chat = store()
        chat.fullTextLookup = { _ in nil }
        await open(chat, conversation, [cut])
        chat.viewFull(cut.id)
        let full = String(repeating: "Mina asked for Thursday. ", count: 200)
        chat.fullTextLookup = { _ in full }
        await chat.lookupFullTexts(in: conversation.id)
        let turn = chat.turns(for: conversation.id)[0]
        #expect(turn.canViewFull && turn.fullText == nil, "찾아졌어도 사용자가 누르기 전에는 접혀 있다")
        chat.viewFull(cut.id)
        #expect(chat.turns(for: conversation.id)[0].fullText == full)
    }

    @Test func aRuntimeWithoutALedgerHasNoLinks() async {
        let conversation = Fx.conversation()
        let chat = store()
        await open(chat, conversation, [agentReply(1, in: conversation.id, seq: 1, truncated: true, key: key)])
        #expect(chat.turns(for: conversation.id)[0].isTruncated && !chat.turns(for: conversation.id)[0].canViewFull)
    }

    @Test func aLateLookupAfterAnAccountChangeIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let conversation = Fx.conversation()
        let cut = agentReply(1, in: conversation.id, seq: 1, truncated: true, key: key)
        let latch = Latch()
        let chat = store(scope: account.scope)
        chat.fullTextLookup = { _ in
            await latch.wait()
            return "the first account's full text"
        }
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in [cut] }
        gateway.lastMessagesHandler = { _ in [:] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.session.apply(event: .signedOut, session: nil)
        await latch.open()
        await chat.settle()
        #expect(chat.turns(for: conversation.id).isEmpty, "계정이 떠나면 비웠다")
        // 다른 계정이 같은 대화 id를 읽어도 앞 계정의 전문이 보이지 않는다
        let second = ChatTestAccount.session(userID: UUID())
        try account.storage.save(second)
        account.session.apply(event: .signedIn, session: second)
        chat.fullTextLookup = { _ in nil }
        await open(chat, conversation, [cut])
        #expect(!chat.turns(for: conversation.id)[0].canViewFull && chat.turns(for: conversation.id)[0].fullText == nil)
    }
}
