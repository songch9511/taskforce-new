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

    // MARK: 기억 쓰기 완료의 세션 경계 (Codex f9c5362): 이전 세션의 완료가 새 세션의 busy · 결과 · 안내를 건드리지 않는다

    /// 세션이 바뀌는 두 길: 같은 UUID 재로그인(새 epoch) · 다른 계정
    enum SessionChange: CaseIterable, Sendable, CustomTestStringConvertible {
        case sameUserRelogin, anotherAccount
        var testDescription: String { self == .sameUserRelogin ? "같은 UUID 재로그인" : "다른 계정" }
    }

    func change(_ account: ChatTestAccount, _ how: SessionChange) throws {
        switch how {
        case .sameUserRelogin:
            account.relogin()
        case .anotherAccount:
            let second = ChatTestAccount.session(userID: UUID())
            try account.storage.save(second)
            account.session.apply(event: .signedIn, session: second)
        }
    }

    /// 새 세션 요청이 대기 중일 때 옛 요청이 늦게 끝나도 새 요청의 busy를 지우지 않는다 (셋째 요청이 한 번에 하나 규칙을 통과하지 못한다)
    @Test(arguments: SessionChange.allCases)
    func anOldConfirmFinishingLateDoesNotReleaseTheNewSessionsBusy(_ how: SessionChange) async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let row = Memories.item(1, "Synthetic pending candidate", origin: .inferred)
        gateway.currentMemoryHandler = { [row] }
        await memory.loadList()
        let oldLatch = Latch(), newLatch = Latch()
        gateway.confirmHandler = { _, _ in await oldLatch.wait(); throw URLError(.timedOut) }
        let oldRequest = Task { await memory.confirm(row.id) }
        while await oldLatch.arrivals == 0 { await Task.yield() }
        try change(account, how)
        await memory.loadList()
        gateway.confirmHandler = { _, _ in await newLatch.wait(); return Memories.item(2) }
        let newRequest = Task { await memory.confirm(row.id) }
        while await newLatch.arrivals == 0 { await Task.yield() }
        #expect(memory.isBusy(row.id))

        await oldLatch.open()
        #expect(await oldRequest.value == .ignored)
        #expect(memory.isBusy(row.id), "옛 요청의 끝이 새 세션 요청의 busy를 지우면 안 된다")
        // 셋째 요청: 막혀야 한다 (막히지 않으면 서버에 둘째 요청이 나가 문에서 기다린다. 그래서 Task로 두고 문을 연 뒤 거둔다)
        let third = Task { await memory.confirm(row.id) }
        for _ in 0..<50 { await Task.yield() }
        #expect(await newLatch.arrivals == 1, "새 요청이 대기 중이면 같은 항목의 셋째 요청은 서버로 나가지 않는다")
        await newLatch.open()
        #expect(await third.value == .ignored)
        guard case .applied = await newRequest.value else {
            Issue.record("새 세션의 요청은 정상 완료해야 한다")
            return
        }
        #expect(!memory.isBusy(row.id))
    }

    /// 옛 요청이 먼저 끝나도(성공 · 서버 오류) 새 세션의 안내 · busy는 그대로다
    @Test(arguments: SessionChange.allCases)
    func anOldEditFailingAfterTheSessionChangedLeavesTheNewSessionsStateAlone(_ how: SessionChange) async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let row = Memories.item(1)
        gateway.currentMemoryHandler = { [row] }
        await memory.loadList()
        let oldLatch = Latch(), newLatch = Latch()
        gateway.editHandler = { _, _ in await oldLatch.wait(); throw APIError.server(status: 500, code: .internalError, message: "old session failure") }
        let oldRequest = Task { await memory.edit(row.id, statement: "Old words") }
        while await oldLatch.arrivals == 0 { await Task.yield() }
        try change(account, how)
        await memory.loadList()
        gateway.editHandler = { _, _ in await newLatch.wait(); return Memories.item(2, "New words") }
        let newRequest = Task { await memory.edit(row.id, statement: "New words") }
        while await newLatch.arrivals == 0 { await Task.yield() }

        await oldLatch.open()
        #expect(await oldRequest.value == .ignored)
        #expect(memory.isBusy(row.id) && memory.feedback(for: row.id) == nil, "옛 실패가 새 세션의 안내를 만들거나 busy를 지우면 안 된다")
        await newLatch.open()
        guard case .applied = await newRequest.value else {
            Issue.record("새 세션의 요청은 정상 완료해야 한다")
            return
        }
        #expect(!memory.isBusy(row.id))
    }

    /// 잊기 200 뒤 후속 목록 읽기를 기다리는 사이 세션이 바뀌면 `.forgotten`이 아니라 `.ignored`다 (호출부가 새 화면을 뒤로 보내지 않는다)
    @Test(arguments: SessionChange.allCases)
    func aForgetWhoseFollowUpReadOutlivesTheSessionIsIgnored(_ how: SessionChange) async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let forgotten = Memories.item(1)
        gateway.currentMemoryHandler = { [forgotten] }
        await memory.loadList()
        let readLatch = Latch()
        gateway.forgetHandler = { _, _ in Memories.item(1, version: 2, revoked: true) }
        gateway.currentMemoryHandler = { await readLatch.wait(); return [] }
        let forgetting = Task { await memory.forget(forgotten.id) }
        while await readLatch.arrivals == 0 { await Task.yield() }
        try change(account, how)
        gateway.currentMemoryHandler = { [forgotten] }
        await memory.loadList()
        await readLatch.open()
        #expect(await forgetting.value == .ignored)
        #expect(memory.items.map(\.id) == [forgotten.id], "새 세션의 목록을 옛 잊기가 고치면 안 된다")
        #expect(memory.feedback(for: forgotten.id) == nil && !memory.isBusy(forgotten.id))
    }

    /// 옛 세션의 잊기 후속 읽기가 새 세션 목록의 "옮긴 후속 행"을 보고 새 세션에 충돌 안내를 남기지 않는다
    @Test(arguments: SessionChange.allCases)
    func aForgetFollowUpNeverMarksTheNewSessionWithAConflict(_ how: SessionChange) async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let forgotten = Memories.item(1)
        gateway.currentMemoryHandler = { [forgotten] }
        await memory.loadList()
        let readLatch = Latch()
        gateway.forgetHandler = { _, _ in Memories.item(1, version: 2, revoked: true) }
        gateway.currentMemoryHandler = { await readLatch.wait(); return [] }
        let forgetting = Task { await memory.forget(forgotten.id) }
        while await readLatch.arrivals == 0 { await Task.yield() }
        try change(account, how)
        let moved = Memories.item(2, value: .object(["moved_from": .string(forgotten.id.uuidString.lowercased())]))
        gateway.currentMemoryHandler = { [moved] }
        await memory.loadList()
        await readLatch.open()
        #expect(await forgetting.value == .ignored)
        #expect(memory.feedback(for: forgotten.id) == nil)
        #expect(memory.items.map(\.id) == [moved.id])
    }

    /// 잊기 409 · 정책 거절(`confirm_unavailable`) 뒤 후속 읽기를 기다리는 사이 세션이 바뀌면 그 결과도 `.ignored`다
    @Test(arguments: SessionChange.allCases)
    func aConflictOrRefusalFollowUpThatOutlivesTheSessionIsIgnored(_ how: SessionChange) async throws {
        for refusal in [false, true] {
            let account = try ChatTestAccount.make()
            let (_, memory) = stores(account)
            let row = Memories.item(1, "Synthetic pending candidate", origin: .inferred)
            gateway.currentMemoryHandler = { [row] }
            await memory.loadList()
            let readLatch = Latch()
            if refusal {
                gateway.confirmHandler = { _, _ in throw APIError.server(status: 409, code: .confirmUnavailable, message: "x") }
            } else {
                gateway.forgetHandler = { _, _ in throw APIError.server(status: 409, code: .conflict, message: "x") }
            }
            gateway.currentMemoryHandler = { await readLatch.wait(); return [row] }
            let writing = Task { refusal ? await memory.confirm(row.id) : await memory.forget(row.id) }
            while await readLatch.arrivals == 0 { await Task.yield() }
            try change(account, how)
            gateway.currentMemoryHandler = { [row] }
            await memory.loadList()
            await readLatch.open()
            #expect(await writing.value == .ignored, "refusal=\(refusal)")
            #expect(memory.feedback(for: row.id) == nil && !memory.isBusy(row.id))
            #expect(memory.canConfirm(row), "옛 세션의 정책 거절이 새 세션의 Confirm을 감추면 안 된다")
        }
    }

    /// 같은 세션: 정상 토큰 갱신이 쓰기 도중 와도 그대로 완료하고, 중복 방지 · 성공 · 실패 뒤 해제는 그대로다
    @Test func aTokenRefreshMidWriteKeepsTheSameSessionsWriteAndItsGuards() async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let row = Memories.item(1, "Synthetic pending candidate", origin: .inferred)
        gateway.currentMemoryHandler = { [row] }
        await memory.loadList()
        let latch = Latch()
        gateway.confirmHandler = { _, _ in await latch.wait(); return Memories.item(2) }
        let writing = Task { await memory.confirm(row.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        #expect(memory.isBusy(row.id))
        #expect(await memory.confirm(row.id) == .ignored, "같은 항목은 한 번에 하나")
        let epoch = account.scope.epoch
        account.session.apply(event: .tokenRefreshed, session: account.signedIn)
        #expect(account.scope.epoch == epoch)
        await latch.open()
        guard case .applied = await writing.value else {
            Issue.record("같은 세션의 정상 갱신 뒤에도 완료해야 한다")
            return
        }
        #expect(!memory.isBusy(row.id) && gateway.calls(prefix: "confirm:").count == 1)

        // 실패는 busy를 풀고 다시 보낼 수 있다
        let next = Memories.item(3, "Another candidate", origin: .inferred)
        gateway.currentMemoryHandler = { [next] }
        await memory.loadList()
        gateway.confirmHandler = { _, _ in throw APIError.server(status: 500, code: .internalError, message: "x") }
        #expect(await memory.confirm(next.id) == .failed)
        #expect(!memory.isBusy(next.id))
        #expect(await memory.confirm(next.id) == .failed)
        #expect(gateway.calls(prefix: "confirm:").count == 3)
    }

    /// 같은 세션: 정상 토큰 갱신이 잊기 후속 읽기 중에 와도 `.forgotten`이다
    @Test func aTokenRefreshDuringTheForgetFollowUpStillForgets() async throws {
        let account = try ChatTestAccount.make()
        let (_, memory) = stores(account)
        let forgotten = Memories.item(1)
        gateway.currentMemoryHandler = { [forgotten] }
        await memory.loadList()
        let readLatch = Latch()
        gateway.forgetHandler = { _, _ in Memories.item(1, version: 2, revoked: true) }
        gateway.currentMemoryHandler = { await readLatch.wait(); return [] }
        let forgetting = Task { await memory.forget(forgotten.id) }
        while await readLatch.arrivals == 0 { await Task.yield() }
        account.session.apply(event: .tokenRefreshed, session: account.signedIn)
        await readLatch.open()
        #expect(await forgetting.value == .forgotten)
        #expect(memory.items.isEmpty && !memory.isBusy(forgotten.id))
    }

    // MARK: 에이전트 대화 (OA D4a-1): 계정이 바뀐 직후 늦게 온 것을 버린다

    private func agentStore(_ account: ChatTestAccount, agent: FakeAgentConversationGateway, assistant: FakeAssistantGateway = FakeAssistantGateway()) -> ChatStore {
        let chat = ChatStore(gateway: gateway, scope: account.scope, now: { .test(500) })
        chat.assistant = assistant
        chat.agentConversation = agent
        return chat
    }

    private func openAgent(_ chat: ChatStore, _ conversation: ChatConversation, _ messages: [ChatMessage]) async {
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in messages }
        gateway.lastMessagesHandler = { _ in [:] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        await chat.settle()
    }

    @Test func aDeliveryReadThatOutlivesTheSessionIsDroppedAndTheLinesAreClearedOnSwitch() async throws {
        let account = try ChatTestAccount.make()
        let agent = FakeAgentConversationGateway()
        let chat = agentStore(account, agent: agent)
        let conversation = AgentFx.conversation()
        let message = AgentFx.user(1, in: conversation.id, seq: 1)
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [AgentFx.entry(message, AgentDelivery(state: .accepted))]) }
        await openAgent(chat, conversation, [message])
        #expect(chat.deliveryCount == 1)
        account.relogin()
        #expect(chat.deliveryCount == 0 && chat.turns(for: conversation.id).isEmpty, "계정이 떠나면 전달 캐시를 비운다")
        // 떠난 계정이 시작한 읽기의 늦은 응답은 새 로그인에 반영되지 않는다
        let latch = Latch()
        agent.deliveriesHandler = { _, _ in
            await latch.wait()
            return ConversationDeliveryResponse(messages: [AgentFx.entry(message, AgentDelivery(state: .notSent, reason: .usageLimited))])
        }
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in [message] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.relogin()
        await latch.open()
        await chat.settle()
        #expect(chat.deliveryCount == 0, "늦은 전달 읽기 응답은 버린다")
    }

    /// 순번은 계정이 떠날 때 비워져 새 계정의 첫 읽기도 1이다: 순번이 같아도 떠난 계정의 늦은 응답은 새 계정에 반영되지 않는다 (순번 · 쥔 시각 말고 계정 확인이 막는다)
    @Test func aLateReadOfTheLeftAccountIsDroppedEvenWhenTheNewAccountsReadHasTheSameSequence() async throws {
        let account = try ChatTestAccount.make()
        let agent = FakeAgentConversationGateway()
        let chat = agentStore(account, agent: agent)
        let conversation = AgentFx.conversation()
        let message = AgentFx.user(1, in: conversation.id, seq: 1)
        let latch = Latch()
        let calls = Mutex2(0)
        agent.deliveriesHandler = { _, _ in
            calls.value += 1
            if calls.value == 1 {
                await latch.wait()
                return ConversationDeliveryResponse(messages: [AgentFx.entry(message, AgentDelivery(state: .notSent, reason: .usageLimited))])
            }
            return ConversationDeliveryResponse(messages: [])
        }
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in [message] }
        gateway.lastMessagesHandler = { _ in [:] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        account.relogin()
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        #expect(await eventually { agent.reads.count == 2 }, "새 계정이 같은 대화를 읽는다 (순번 1)")
        await latch.open()
        await chat.settle()
        #expect(chat.delivery(forMessage: message.id) == nil, "떠난 계정의 notSent는 새 계정에 반영되지 않는다")
    }

    /// 떠난 계정의 늦은 거절(동의 · 오류)은 새 계정에 안내로 남지 않는다
    @Test func aRefusalThatOutlivesTheSessionLeavesNoNoticeForTheNewAccount() async throws {
        let account = try ChatTestAccount.make()
        let agent = FakeAgentConversationGateway()
        let chat = agentStore(account, agent: agent)
        let conversation = AgentFx.conversation()
        let message = AgentFx.user(1, in: conversation.id, seq: 1)
        let candidate = AgentReferentCandidate(actionID: UUID(), title: "가격 문구")
        let ambiguous = AgentFx.user(2, in: conversation.id, seq: 2)
        agent.deliveriesHandler = { _, _ in
            ConversationDeliveryResponse(messages: [
                AgentFx.entry(message, AgentDelivery(state: .notSent, reason: .writeGateClosed)),
                AgentFx.entry(ambiguous, AgentDelivery(state: .needsReferent, candidates: [candidate])),
            ])
        }
        await openAgent(chat, conversation, [message, ambiguous])
        let latch = Latch()
        let refusal = APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage)
        agent.deliverHandler = { _, _ in
            await latch.wait()
            throw refusal
        }
        agent.referentHandler = { _, _, _ in
            await latch.wait()
            throw refusal
        }
        async let again: Void = chat.sendAgain(message.id, in: conversation.id)
        async let pick: Void = chat.chooseReferent(candidate.actionID, for: ambiguous.id, in: conversation.id)
        #expect(await latch.waitForArrivals(2, timeout: .seconds(3)))
        account.relogin()
        await latch.open()
        _ = await (again, pick)
        await openAgent(chat, conversation, [message, ambiguous])
        #expect(!chat.needsConsent(in: conversation.id), "떠난 계정의 동의 안내가 새 계정에 남지 않는다")
        #expect(chat.turns(for: conversation.id).allSatisfy { $0.status == .sent })
    }

    @Test func aSendAgainAndAReferentThatOutliveTheSessionAreDropped() async throws {
        let account = try ChatTestAccount.make()
        let agent = FakeAgentConversationGateway()
        let chat = agentStore(account, agent: agent)
        let conversation = AgentFx.conversation()
        let failed = AgentFx.user(1, in: conversation.id, seq: 1)
        let ambiguous = AgentFx.user(2, in: conversation.id, seq: 2)
        let candidate = AgentReferentCandidate(actionID: UUID(), title: "가격 문구")
        agent.deliveriesHandler = { _, _ in
            ConversationDeliveryResponse(messages: [
                AgentFx.entry(failed, AgentDelivery(state: .notSent, reason: .writeGateClosed)),
                AgentFx.entry(ambiguous, AgentDelivery(state: .needsReferent, candidates: [candidate])),
            ])
        }
        await openAgent(chat, conversation, [failed, ambiguous])
        let deliverLatch = Latch()
        let referentLatch = Latch()
        agent.deliverHandler = { _, ids in
            await deliverLatch.wait()
            return AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .queued))])
        }
        agent.referentHandler = { conversation, _, _ in
            await referentLatch.wait()
            return AgentPostedMessage(message: Chats.message(2, in: conversation, seq: 2, role: .user, text: "t", cmid: UUID(), at: 2), delivery: AgentDelivery(state: .sent))
        }
        async let sendAgain: Void = chat.sendAgain(failed.id, in: conversation.id)
        async let referent: Void = chat.chooseReferent(candidate.actionID, for: ambiguous.id, in: conversation.id)
        let deliverArrived = await deliverLatch.waitForArrivals(1, timeout: .seconds(3))
        let referentArrived = await referentLatch.waitForArrivals(1, timeout: .seconds(3))
        #expect(deliverArrived && referentArrived)
        account.relogin()
        await deliverLatch.open()
        await referentLatch.open()
        await sendAgain
        await referent
        #expect(chat.deliveryCount == 0, "다른 세션이 된 뒤 온 Send again · 후보 고르기 응답은 줄을 쓰지 못한다")
    }
}
