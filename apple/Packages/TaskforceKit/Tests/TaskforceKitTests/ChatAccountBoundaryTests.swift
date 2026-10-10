import Foundation
import Testing
@testable import TaskforceKit

/// 계정 경계 (S1 `ProfileDraft` 방식): 앱 시작 세션 계정 + epoch, 화면과 무관하게 로그아웃 · 다른 계정 · 같은 UUID 재로그인에 초안 · 캐시 · 대기 전송을 비운다.
/// 매 전송 · 재시도 직전 소유 계정을 다시 확인하고, 정상 토큰 갱신은 데이터를 잃지 않는다. 저장 위치 · 기간: 초안과 대기 전송은 `ChatStore` 메모리에만 (디스크 없음)
@MainActor
struct ChatAccountBoundaryTests {
    let gateway = FakeChatGateway()

    func stores(_ account: ChatTestAccount) -> (chat: ChatStore, memory: MemoryStore) {
        let memory = MemoryStore(gateway: gateway, scope: account.scope)
        return (ChatStore(gateway: gateway, scope: account.scope, memory: memory, now: { .test(500) }), memory)
    }

    /// 한 계정이 쓰던 상태: 초안 · 빈 대화 · 읽은 목록
    func fill(_ chat: ChatStore) async -> UUID {
        gateway.conversationsHandler = { [Chats.conversation(1, title: "Mine", last: 10)] }
        gateway.messagesHandler = { id in [Chats.message(1, in: id, seq: 1, role: .user, text: "Private words", cmid: UUID(), at: 5)] }
        await chat.refresh()
        chat.setDraft("my private draft", for: chat.currentID!)
        _ = chat.newChat()
        return chat.currentID!
    }

    @Test func logoutClearsDraftsListThreadsAndLocalChats() async throws {
        let account = try ChatTestAccount.make()
        let (chat, _) = stores(account)
        let local = await fill(chat)
        #expect(!chat.entries.isEmpty && chat.locals.count == 1)
        account.session.apply(event: .signedOut, session: nil)
        #expect(chat.entries.isEmpty && chat.locals.isEmpty && chat.currentID == nil && chat.mode == .history)
        #expect(chat.draft(for: local) == "" && chat.listScreen == .blank)
    }

    /// 같은 UUID가 다시 로그인해도 다른 세션이다: 이전 초안이 돌아오지 않는다
    @Test func relogginInAsTheSameUserStartsFresh() async throws {
        let account = try ChatTestAccount.make()
        let (chat, memory) = stores(account)
        gateway.currentMemoryHandler = { [Memories.item(1)] }
        await memory.loadList()
        let local = await fill(chat)
        chat.setDraft("keep me?", for: local)
        account.relogin()
        #expect(chat.draft(for: local) == "" && chat.entries.isEmpty && chat.locals.isEmpty)
        #expect(memory.items.isEmpty && memory.load == .idle)
    }

    @Test func anotherAccountNeverSeesTheFirstAccountsState() async throws {
        let account = try ChatTestAccount.make()
        let (chat, memory) = stores(account)
        gateway.currentMemoryHandler = { [Memories.item(1, "first account's memory")] }
        await memory.loadList()
        _ = await fill(chat)
        let second = ChatTestAccount.session(userID: UUID())
        try account.storage.save(second)
        account.session.apply(event: .signedIn, session: second)
        #expect(chat.entries.isEmpty && memory.items.isEmpty && chat.currentID == nil)
        #expect(account.scope.token?.userID == second.user.id)
    }

    /// 정상 토큰 갱신은 같은 세션의 데이터를 잃지 않는다
    @Test func tokenRefreshKeepsTheSameSessionsData() async throws {
        let account = try ChatTestAccount.make()
        let (chat, memory) = stores(account)
        gateway.currentMemoryHandler = { [Memories.item(1)] }
        await memory.loadList()
        let local = await fill(chat)
        chat.setDraft("still here", for: local)
        let epoch = account.scope.epoch
        account.session.apply(event: .tokenRefreshed, session: account.signedIn)
        account.session.apply(event: .initialSession, session: account.signedIn)
        #expect(account.scope.epoch == epoch)
        #expect(chat.draft(for: local) == "still here" && !chat.entries.isEmpty && memory.items.count == 1)
    }

    /// 로그아웃 전에 보낸 요청의 늦은 응답은 다음 로그인(같은 UUID)에 반영되지 않는다
    @Test func aSendThatOutlivesTheSessionIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let (chat, _) = stores(account)
        gateway.conversationsHandler = { [] }
        let id = chat.newChat()
        let latch = Latch()
        gateway.postHandler = { conversation, cmid, text in
            await latch.wait()
            return Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
        }
        let sending = Task { await chat.send("Sent before logout") }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        await sending.value
        #expect(chat.turns(for: id).isEmpty && chat.entries.isEmpty)
        #expect(chat.threads.isEmpty)
    }

    /// 매 전송 직전에 소유 계정을 다시 본다: 대화를 만드는 사이 떠난 계정의 글은 서버에 보내지 않는다
    @Test func theOwnerIsCheckedRightBeforeTheMessageIsPosted() async throws {
        let account = try ChatTestAccount.make()
        let (chat, _) = stores(account)
        _ = chat.newChat()
        let latch = Latch()
        gateway.createHandler = { id, title, context in
            await latch.wait()
            return ChatConversation(id: id, title: title, contextID: context, createdAt: .test())
        }
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        let sending = Task { await chat.send("Hello") }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        await sending.value
        #expect(gateway.calls(prefix: "post").isEmpty, "떠난 계정의 글을 새 세션이 보내지 않는다")
    }

    /// 다시 보내기 직전에도 확인한다: 실패한 글은 계정이 떠나면 사라지고, 다른 세션이 다시 보낼 수 없다
    @Test func aFailedMessageCannotBeRetriedByAnotherSession() async throws {
        let account = try ChatTestAccount.make()
        let (chat, _) = stores(account)
        gateway.conversationsHandler = { [Chats.conversation(1, title: "Mine", last: 10)] }
        await chat.refresh()
        gateway.postHandler = { _, _, _ in throw APIError.server(status: 503, code: .internalError, message: "x") }
        await chat.send("Will fail")
        let cmid = try #require(chat.turns(for: chat.currentID!).first?.clientMessageID)
        account.relogin()
        gateway.conversationsHandler = { [Chats.conversation(1, title: "Mine", last: 10)] }
        await chat.refresh()
        gateway.postHandler = { conversation, id, text in Chats.pair(1, in: conversation, seq: 1, cmid: id, text: text) }
        await chat.retry(cmid)
        #expect(gateway.calls(prefix: "post").count == 1, "옛 세션의 글은 다시 보내지지 않는다")
    }

    @Test func signedOutStoresDoNothing() async throws {
        let scope = AccountScope(currentAccount: { nil })
        let chat = ChatStore(gateway: gateway, scope: scope)
        let memory = MemoryStore(gateway: gateway, scope: scope)
        _ = chat.newChat()
        chat.setDraft("nope", for: chat.currentID!)
        await chat.send("nope")
        await chat.refresh()
        await memory.loadList()
        #expect(gateway.calls.isEmpty)
        #expect(chat.draft(for: chat.currentID!) == "")
    }

    @Test func aMemoryWriteThatOutlivesTheSessionIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let item = Memories.item(1, origin: .inferred)
        gateway.currentMemoryHandler = { [item] }
        await memory.loadList()
        let latch = Latch()
        gateway.confirmHandler = { _, _ in await latch.wait(); return Memories.item(2) }
        let writing = Task { await memory.confirm(item.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        #expect(await writing.value == .ignored)
        #expect(memory.items.isEmpty && memory.resolve(item.id) == item.id && memory.referenced.isEmpty)
    }
}
