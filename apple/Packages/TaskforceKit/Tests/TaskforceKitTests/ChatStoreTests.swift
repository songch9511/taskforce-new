import Foundation
import Supabase
import Testing
@testable import TaskforceKit

/// 대화 저장소: 복원 · 새 대화 · 보내기 상태 기계(재시도 · 중복 · 늦은 응답 · 409) · 상태 구분 · 계정 경계
@MainActor
struct ChatStoreTests {
    let gateway = FakeChatGateway()
    let scope = ChatTestAccount.fixedScope()
    let project = ChatContractFixtures.contextID

    func store(memory: MemoryStore? = nil) -> ChatStore {
        ChatStore(gateway: gateway, scope: scope, memory: memory, now: { .test(500) })
    }

    func serve(_ chats: [ChatConversation], messages: [UUID: [ChatMessage]] = [:], contexts: [WorkContext] = []) {
        gateway.conversationsHandler = { chats }
        gateway.messagesHandler = { messages[$0] ?? [] }
        gateway.contextsHandler = { contexts }
        gateway.lastMessagesHandler = { ids in
            var result: [UUID: ChatMessage] = [:]
            for id in ids { if let last = messages[id]?.last { result[id] = last } }
            return result
        }
    }

    // MARK: 복원 (A03)

    /// 앱을 다시 켜면 서버 대화에서 마지막 대화와 범위를 되살린다 (새 로컬 캐시 없음)
    @Test func restoresTheLastConversationAndItsProjectFromTheServer() async throws {
        let older = Chats.conversation(1, title: "Older", at: 0, last: 100)
        let latest = Chats.conversation(2, title: "Pricing FAQ", at: 10, last: 300, context: project)
        let user = Chats.message(1, in: latest.id, seq: 1, role: .user, text: "Shorter FAQ?", cmid: UUID(), at: 290)
        let reply = Chats.message(2, in: latest.id, seq: 2, role: .assistant, text: "Yes.", replyTo: user.id, at: 300)
        serve([older, latest], messages: [latest.id: [user, reply], older.id: []], contexts: [WorkContext(id: project, name: "Shape launch")])
        let chat = store()
        chat.openChats()
        await chat.settle()
        #expect(chat.mode == .chat && chat.currentID == latest.id)
        #expect(chat.currentTitle == "Pricing FAQ")
        #expect(chat.turns(for: latest.id).map(\.text) == ["Shorter FAQ?", "Yes."])
        #expect(chat.project(for: latest.id)?.name == "Shape launch" && chat.project(for: latest.id)?.basis == .user)
        #expect(chat.entries.map(\.id) == [latest.id, older.id])
    }

    @Test func historyIsNewestFirstWithRealDatesAndPreviews() async throws {
        let first = Chats.conversation(1, title: "First", at: 0, last: 100)
        let second = Chats.conversation(2, title: "Second", at: 50, last: 200)
        let msg = Chats.message(1, in: second.id, seq: 1, role: .assistant, text: "Last words", at: 200)
        serve([first, second], messages: [second.id: [msg]])
        let chat = store()
        await chat.refresh()
        #expect(chat.entries.map(\.title) == ["Second", "First"])
        #expect(chat.entries[0].previewText == "Last words")
        // 미리보기를 읽지 못한 대화는 줄을 비운다 (없는 것처럼 "No messages yet"이라 하지 않는다)
        #expect(chat.entries[1].preview == .unknown && chat.entries[1].previewText == nil)
    }

    @Test func noConversationsShowsTheEmptyHistory() async throws {
        serve([])
        let chat = store()
        chat.openChats()
        await chat.settle()
        #expect(chat.mode == .history && chat.currentID == nil)
        #expect(chat.listIsEmpty && chat.listScreen == .ready(problem: nil))
    }

    // MARK: 읽기 상태

    @Test func readingOfflineFailedAndEmptyAreDifferentScreens() async throws {
        let chat = store()
        #expect(chat.listScreen == .blank, "읽는 중에는 아무 주장도 하지 않는다")
        gateway.conversationsHandler = { throw URLError(.notConnectedToInternet) }
        await chat.refresh()
        #expect(chat.listScreen == .offline && !chat.listIsEmpty)
        gateway.conversationsHandler = { throw FakeChatGateway.Failure() }
        await chat.refresh()
        #expect(chat.listScreen == .failed)
        serve([])
        await chat.refresh()
        #expect(chat.listScreen == .ready(problem: nil) && chat.listIsEmpty)
        // 받은 뒤의 끊김은 목록을 두고 문제만 알린다
        serve([Chats.conversation(1, title: "Keep", last: 10)])
        await chat.refresh()
        gateway.conversationsHandler = { throw URLError(.notConnectedToInternet) }
        await chat.refresh()
        #expect(chat.listScreen == .ready(problem: .offline) && chat.entries.count == 1)
    }

    /// 대화 테이블이 서버 DB에 아직 없다: "Couldn't load your chats"가 아니라 기능이 아직 없다고 말한다
    @Test func missingTablesAreUnavailableNotAFailure() async throws {
        gateway.conversationsHandler = { throw PostgrestError(code: "PGRST205", message: "Could not find the table 'public.conversations'") }
        let chat = store()
        await chat.refresh()
        #expect(chat.isUnavailable && chat.listScreen == .ready(problem: nil) && chat.listIsEmpty)
        #expect(chat.composerPlaceholder == "Chats aren't available yet.")
        // 서버가 켜지면 Try again으로 다시 읽는다
        serve([Chats.conversation(1, title: "Back", last: 10)])
        chat.retryUnavailable()
        await chat.settle()
        #expect(!chat.isUnavailable && chat.entries.map(\.title) == ["Back"])
    }

    @Test func aThreadThatCouldNotBeReadSaysSoInsteadOfLookingEmpty() async throws {
        let one = Chats.conversation(1, title: "One", last: 10)
        serve([one])
        gateway.messagesHandler = { _ in throw URLError(.notConnectedToInternet) }
        let chat = store()
        chat.openChats()
        await chat.settle()
        #expect(chat.currentID == one.id)
        #expect(chat.screen == .offline)
        gateway.messagesHandler = { _ in throw FakeChatGateway.Failure() }
        await chat.loadThread(one.id)
        #expect(chat.screen == .failed)
    }

    // MARK: 새 대화

    @Test func newChatReusesAnUntouchedEmptyChatInsteadOfPilingUp() async throws {
        serve([Chats.conversation(1, title: "Used", last: 10)])
        let chat = store()
        await chat.refresh()
        let first = chat.newChat()
        #expect(chat.locals.count == 1 && chat.currentID == first && chat.mode == .chat)
        // 비어 있는 채 history를 보고 ⌘N을 다시 눌러도 같은 대화
        chat.showHistory()
        #expect(chat.newChat() == first)
        #expect(chat.locals.count == 1)
        // 서버에 있는 손대지 않은 빈 대화도 다시 쓴다
        let empty = Chats.conversation(3, at: 5)
        serve([Chats.conversation(1, title: "Used", last: 10), empty])
        let other = store()
        await other.refresh()
        #expect(other.newChat() == empty.id)
        #expect(other.locals.isEmpty)
        #expect(other.entries.contains { $0.id == empty.id && $0.previewText == "No messages yet" && $0.title == "New chat" })
    }

    /// 서버에 이름이 없는 (다른 길로 만든) 빈 대화를 다시 써도 첫 글이 이름으로 보인다
    @Test func reusedUntitledEmptyChatIsNamedByItsFirstMessage() async throws {
        let empty = Chats.conversation(3, at: 5)
        serve([Chats.conversation(1, title: "Used", last: 10), empty])
        let chat = store()
        await chat.refresh()
        #expect(chat.newChat() == empty.id)
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        #expect(chat.entries.first { $0.id == empty.id }?.title == "New chat")
        await chat.send("Use the shorter FAQ on both pricing pages")
        #expect(chat.entries.first { $0.id == empty.id }?.title == "Use the shorter FAQ on both pricing pages")
        #expect(gateway.calls(prefix: "create").isEmpty, "이미 서버에 있는 대화는 다시 만들지 않는다")
    }

    // MARK: 보내기

    /// 첫 메시지가 이름이 되고, 대화는 첫 보내기에서 서버에 만들어진다
    @Test func firstMessageCreatesTheChatNamedByIt() async throws {
        serve([])
        let chat = store()
        let local = chat.newChat()
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        await chat.send("  Use the shorter FAQ\non both pricing pages  ")
        #expect(gateway.calls(prefix: "create") == ["create:\(local.uuidString)"])
        #expect(chat.locals.isEmpty)
        #expect(chat.currentTitle == "Use the shorter FAQ on both pricing pages")
        let turns = chat.turns(for: local)
        #expect(turns.map(\.text) == ["Use the shorter FAQ\non both pricing pages", "Noted."])
        #expect(turns.allSatisfy { $0.status == .sent })
        // 초안은 비었다
        #expect(chat.draft(for: local) == "")
    }

    @Test func nothingLooksSentBeforeTheServerConfirmsAndSecondSendWaits() async throws {
        serve([])
        let chat = store()
        let id = chat.newChat()
        let latch = Latch()
        gateway.postHandler = { conversation, cmid, text in
            await latch.wait()
            return Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
        }
        let first = Task { await chat.send("Hello") }
        while await latch.arrivals == 0 { await Task.yield() }
        let sending = chat.turns(for: id)
        #expect(sending.count == 1 && sending[0].status == .sending && sending[0].isUser)
        #expect(chat.isSending)
        await chat.send("Another while sending")
        #expect(gateway.calls(prefix: "post").count == 1, "보내는 중에는 다음 글을 보내지 않는다")
        await latch.open()
        await first.value
        #expect(chat.turns(for: id).map(\.status) == [.sent, .sent] && !chat.isSending)
    }

    @Test func failureKeepsTheTextAndRetryReusesTheSameSubmission() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        let attempts = Counter()
        gateway.postHandler = { conversation, cmid, text in
            if attempts.next() == 1 { throw APIError.server(status: 503, code: .internalError, message: "x") }
            return Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
        }
        await chat.send("Please check pricing")
        let failed = try #require(chat.turns(for: existing.id).first)
        #expect(failed.status == .failed("Something went wrong. Try again in a moment.") && failed.status.canRetry)
        #expect(failed.text == "Please check pricing")
        await chat.retry(try #require(failed.clientMessageID))
        let posts = gateway.calls(prefix: "post")
        #expect(posts.count == 2)
        // 같은 conversation · 같은 client_message_id
        #expect(posts[0] == posts[1])
        #expect(chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
        #expect(chat.turns(for: existing.id).count == 2)
    }

    /// 응답을 못 받았지만(전송 오류) 서버가 이미 저장하고 답했으면 읽어서 맞춘다 — 중복 없이 한 쌍
    @Test func lostResponseIsReconciledFromTheServerWithoutDuplicates() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        let stored = Box<[ChatMessage]>([])
        gateway.messagesHandler = { _ in stored.value }
        gateway.postHandler = { conversation, cmid, text in
            let pair = Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
            stored.value = [pair.message, pair.reply]
            throw URLError(.networkConnectionLost)
        }
        await chat.send("Hello there")
        let turns = chat.turns(for: existing.id)
        #expect(turns.map(\.text) == ["Hello there", "Noted."])
        #expect(turns.map(\.status) == [.sent, .sent])
    }

    /// 서버가 저장했지만 답이 아직 없다(처리 중 409 · 마지막 글): "No reply yet" + 같은 id로 Try again
    @Test func storedButUnansweredMessageOffersRetryWithItsOwnID() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        let cmid = UUID()
        let user = Chats.message(1, in: existing.id, seq: 1, role: .user, text: "Still there?", cmid: cmid, at: 10)
        serve([existing], messages: [existing.id: [user]])
        let chat = store()
        chat.openChats()
        await chat.settle()
        let turns = chat.turns(for: existing.id)
        #expect(turns.map(\.status) == [.noReply])
        gateway.postHandler = { conversation, id, text in
            #expect(id == cmid && text == "Still there?")
            return Chats.pair(1, in: conversation, seq: 1, cmid: id, text: text)
        }
        await chat.retry(cmid)
        #expect(chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
        #expect(chat.turns(for: existing.id).map(\.text) == ["Still there?", "Noted."])
    }

    /// 뒤에 새 메시지가 있어 서버가 답하지 않은 글은 다시 보낼 수 없다
    @Test func anEarlierUnansweredMessageIsNotAnswered() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 20)
        let first = Chats.message(1, in: existing.id, seq: 1, role: .user, text: "One", cmid: UUID(), at: 10)
        let second = Chats.message(2, in: existing.id, seq: 2, role: .user, text: "Two", cmid: UUID(), at: 11)
        let reply = Chats.message(3, in: existing.id, seq: 3, role: .assistant, text: "Answer to two", replyTo: second.id, at: 12)
        serve([existing], messages: [existing.id: [first, second, reply]])
        let chat = store()
        chat.openChats()
        await chat.settle()
        let turns = chat.turns(for: existing.id)
        #expect(turns.map(\.status) == [.notAnswered, .sent, .sent])
        #expect(!turns[0].status.canRetry)
    }

    /// 같은 쌍이 두 번 와도 한 번만 반영한다: 응답이 오기 전에 서버를 다시 읽어 이미 그 쌍이 들어왔는데 (늦은 응답이) 같은 쌍을 또 가져온다
    @Test func duplicateResponsesApplyOnce() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        let stored = Box<[ChatMessage]>([])
        gateway.messagesHandler = { _ in stored.value }
        let latch = Latch()
        gateway.postHandler = { conversation, cmid, text in
            let pair = Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
            stored.value = [pair.message, pair.reply]
            await latch.wait()
            return pair
        }
        let sending = Task { await chat.send("Once") }
        while await latch.arrivals == 0 { await Task.yield() }
        // 응답을 기다리는 사이 서버를 읽어 그 쌍이 먼저 들어온다 (보내는 중 표시는 응답이 올 때까지 둔다)
        await chat.loadThread(existing.id)
        #expect(chat.turns(for: existing.id).map(\.text) == ["Once", "Noted."])
        await latch.open()
        await sending.value
        // 같은 쌍을 또 받아도 줄이 늘지 않고 한 번만 있다
        #expect(chat.turns(for: existing.id).map(\.text) == ["Once", "Noted."])
        #expect(chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
        #expect(chat.threads[existing.id]?.messages.count == 2 && chat.threads[existing.id]?.pending.isEmpty == true)
    }

    /// 대화를 옮긴 뒤 늦게 온 응답은 그 대화에 반영된다 (지금 보는 대화를 건드리지 않는다)
    @Test func lateResponseLandsInItsOwnConversation() async throws {
        let a = Chats.conversation(1, title: "A", last: 10)
        let b = Chats.conversation(2, title: "B", last: 20)
        serve([a, b])
        let chat = store()
        await chat.refresh()
        chat.open(a.id)
        await chat.settle()
        let latch = Latch()
        gateway.postHandler = { conversation, cmid, text in
            await latch.wait()
            return Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
        }
        let sending = Task { await chat.send("For A") }
        while await latch.arrivals == 0 { await Task.yield() }
        chat.open(b.id)
        #expect(chat.currentID == b.id)
        await latch.open()
        await sending.value
        #expect(chat.turns(for: a.id).map(\.text) == ["For A", "Noted."])
        #expect(chat.turns(for: b.id).isEmpty)
        #expect(chat.currentID == b.id)
    }

    // MARK: 409 · 기능 꺼짐 · 동의

    @Test func consentNeededIsItsOwnStateNotAFailure() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        gateway.postHandler = { _, _, _ in throw APIError.server(status: 409, code: .conflict, message: "외부 AI 처리 동의가 필요해요.") }
        await chat.send("Hi")
        #expect(chat.turns(for: existing.id).map(\.status) == [.needsConsent])
        #expect(chat.needsConsent)
        // 동의한 뒤 같은 글을 다시 보낸다
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        await chat.retry(try #require(chat.turns(for: existing.id).first?.clientMessageID))
        #expect(!chat.needsConsent && chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
    }

    @Test func otherConflictsAreReconciledFromTheServer() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        let stored = Box<[ChatMessage]>([])
        gateway.messagesHandler = { _ in stored.value }
        gateway.postHandler = { conversation, cmid, text in
            // 같은 메시지를 다른 쪽이 처리하는 중: 서버에는 글이 있고 답은 아직 없다
            stored.value = [Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 11)]
            throw APIError.server(status: 409, code: .conflict, message: "같은 메시지를 처리하고 있습니다.")
        }
        await chat.send("Slow one")
        let turns = chat.turns(for: existing.id)
        #expect(turns.count == 1 && turns[0].status == .noReply && !chat.needsConsent)
    }

    @Test func featureOffIsNotDressedUpAsAFailure() async throws {
        serve([])
        let chat = store()
        let id = chat.newChat()
        gateway.createHandler = { _, _, _ in throw APIError.server(status: 404, code: .notFound, message: "없는 경로입니다.") }
        await chat.send("Hello")
        #expect(chat.isUnavailable)
        #expect(chat.composerPlaceholder == "Chats aren't available yet.")
        #expect(!chat.canCompose)
        #expect(chat.turns(for: id).map(\.status) == [.failed("Chats aren't available yet.")])
        #expect(gateway.calls(prefix: "post").isEmpty, "만들지 못했으면 보내지 않는다")
        // 다시 시도하면 새로 확인한다
        chat.retryUnavailable()
        #expect(chat.canCompose)
    }

    /// 꺼짐 안내 뒤 사용자가 Try again을 누르면 안내를 걷고 같은 글을 다시 보낸다 (아직 꺼져 있으면 다시 404로 안다)
    @Test func tryAgainAfterFeatureOffAsksTheServerAgain() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        gateway.postHandler = { _, _, _ in throw APIError.server(status: 404, code: .notFound, message: "없는 경로입니다.") }
        await chat.send("Hello")
        #expect(chat.isUnavailable)
        let cmid = try #require(chat.turns(for: existing.id).first?.clientMessageID)
        await chat.retry(cmid)
        #expect(gateway.calls(prefix: "post").count == 2 && chat.isUnavailable, "다시 물었고 아직 꺼져 있다")
        // 켜졌다
        gateway.postHandler = { conversation, id, text in Chats.pair(1, in: conversation, seq: 1, cmid: id, text: text) }
        await chat.retry(cmid)
        #expect(!chat.isUnavailable && chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
    }

    /// 목록을 읽는 사이 이 기기가 첫 보내기로 만든 대화는 (그 읽기에 없어도) 서버가 지운 것이 아니다: 닫히지 않는다
    @Test func aChatCreatedWhileTheListIsBeingReadIsNotDropped() async throws {
        serve([Chats.conversation(1, title: "Old", last: 10)])
        let chat = store()
        await chat.refresh()
        let id = chat.newChat()
        // 다음 읽기는 늦게 끝나고, 그 결과에는 새 대화가 없다
        let latch = Latch()
        gateway.conversationsHandler = { await latch.wait(); return [Chats.conversation(1, title: "Old", last: 10)] }
        let reading = Task { await chat.refresh() }
        while await latch.arrivals == 0 { await Task.yield() }
        let stored = Box<[ChatMessage]>([])
        gateway.messagesHandler = { _ in stored.value }
        gateway.postHandler = { conversation, cmid, text in
            let pair = Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
            stored.value = [pair.message, pair.reply]
            return pair
        }
        await chat.send("First words")
        #expect(chat.turns(for: id).map(\.status) == [.sent, .sent])
        await latch.open()
        await reading.value
        #expect(chat.currentID == id && chat.mode == .chat)
        #expect(chat.turns(for: id).map(\.text) == ["First words", "Noted."])
        #expect(chat.entries.contains { $0.id == id })
    }

    // MARK: 겹친 읽기 (Codex 읽기 검토 P2 B)

    func citation(_ quote: String) -> ChatCitation {
        ChatCitation(sourceID: "synthetic-source", sourceTitle: "Synthetic", sourceKind: "doc", occurredAt: nil, externalURL: nil, quote: quote)
    }

    /// 같은 대화의 겹친 읽기: 새 응답(인용 0) 뒤에 늦게 끝난 옛 응답(인용 1)이 화면을 되돌리지 않는다 (인용 부활 0)
    @Test func aLateOlderThreadReadDoesNotRevertANewerOne() async throws {
        let chatRow = Chats.conversation(701, title: "Synthetic chat", last: 1)
        let old = Chats.message(702, in: chatRow.id, seq: 2, role: .assistant, text: "Synthetic reply", citations: [citation("Synthetic old quote")])
        let new = Chats.message(702, in: chatRow.id, seq: 2, role: .assistant, text: "Synthetic reply", citations: [])
        serve([chatRow], messages: [chatRow.id: [old]])
        let chat = store()
        await chat.refresh()
        #expect(chat.turns(for: chatRow.id).first?.citations.count == 1)
        let latch = Latch()
        gateway.messagesHandler = { _ in
            await latch.wait()
            return [old]
        }
        let stale = Task { await chat.loadThread(chatRow.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        // 원문 정리 뒤의 새 읽기(같은 답, 인용 0)가 먼저 끝난다
        gateway.messagesHandler = { _ in [new] }
        await chat.loadThread(chatRow.id)
        #expect(chat.turns(for: chatRow.id).first?.citations.isEmpty == true)
        await latch.open()
        await stale.value
        #expect(chat.turns(for: chatRow.id).first?.citations.isEmpty == true, "늦게 끝난 옛 읽기가 지운 인용을 되살리지 않는다")
    }

    /// 서로 다른 대화의 읽기는 서로 막지 않는다
    @Test func readsOfDifferentConversationsDoNotBlockEachOther() async throws {
        let a = Chats.conversation(711, title: "A", last: 2)
        let b = Chats.conversation(712, title: "B", last: 1)
        let aMessage = Chats.message(711, in: a.id, seq: 1, role: .assistant, text: "From A")
        let bMessage = Chats.message(712, in: b.id, seq: 1, role: .assistant, text: "From B")
        serve([a, b], messages: [a.id: [], b.id: []])
        let chat = store()
        await chat.refresh()
        let latch = Latch()
        gateway.messagesHandler = { id in
            if id == a.id {
                await latch.wait()
                return [aMessage]
            }
            return [bMessage]
        }
        let slowA = Task { await chat.loadThread(a.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        await chat.loadThread(b.id)
        #expect(chat.turns(for: b.id).map(\.text) == ["From B"], "A의 느린 읽기가 B를 막지 않는다")
        await latch.open()
        await slowA.value
        #expect(chat.turns(for: a.id).map(\.text) == ["From A"] && chat.turns(for: b.id).map(\.text) == ["From B"])
    }

    /// 기존 보호 유지: 읽기를 시작한 뒤 로컬에서 POST 결과를 반영했으면 그 옛 읽기(보내기 전 상태)가 덮지 않고 다시 읽는다
    @Test func aReadStartedBeforeASendDoesNotEraseTheSentPair() async throws {
        let existing = Chats.conversation(721, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        let stored = Box<[ChatMessage]>([])
        let latch = Latch()
        let calls = Counter()
        gateway.messagesHandler = { _ in
            if calls.next() == 1 {
                await latch.wait()
                return []
            }
            return stored.value
        }
        gateway.postHandler = { conversation, cmid, text in
            let pair = Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text)
            stored.value = [pair.message, pair.reply]
            return pair
        }
        let stale = Task { await chat.loadThread(existing.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        await chat.send("Sent while reading")
        #expect(chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
        await latch.open()
        await stale.value
        #expect(chat.turns(for: existing.id).map(\.text) == ["Sent while reading", "Noted."])
    }

    /// 계정이 바뀐 뒤 늦게 온 읽기는 반영하지 않는다
    @Test func aLateThreadReadAfterTheAccountLeftIsDropped() async throws {
        let account = try ChatTestAccount.make()
        let row = Chats.conversation(731, title: "Mine", last: 1)
        serve([row], messages: [row.id: []])
        let chat = ChatStore(gateway: gateway, scope: account.scope, now: { .test(500) })
        await chat.refresh()
        let latch = Latch()
        gateway.messagesHandler = { id in
            await latch.wait()
            return [Chats.message(731, in: id, seq: 1, role: .assistant, text: "Private words of the previous session")]
        }
        let late = Task { await chat.loadThread(row.id) }
        while await latch.arrivals == 0 { await Task.yield() }
        account.relogin()
        await latch.open()
        await late.value
        #expect(chat.threads.isEmpty && chat.turns(for: row.id).isEmpty)
    }

    // MARK: 초안

    @Test func draftsStayPerConversationAndWinThePreview() async throws {
        let a = Chats.conversation(1, title: "A", last: 10)
        let b = Chats.conversation(2, title: "B", last: 20)
        serve([a, b], messages: [a.id: [Chats.message(1, in: a.id, seq: 1, role: .assistant, text: "Hi from A", at: 10)]])
        let chat = store()
        await chat.refresh()
        chat.setDraft("Can you compare plan B with", for: a.id)
        chat.open(b.id)
        chat.open(a.id)
        #expect(chat.draft(for: a.id) == "Can you compare plan B with" && chat.draft(for: b.id) == "")
        #expect(chat.entries.first { $0.id == a.id }?.previewText == "Draft · Can you compare plan B with")
        #expect(chat.entries.first { $0.id == b.id }?.preview == .unknown || chat.entries.first { $0.id == b.id }?.preview == .empty)
    }

    // MARK: 프로젝트 (명시적 선택)

    @Test func projectLinkIsExplicitAndUndoable() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing], contexts: [WorkContext(id: project, name: "Shape launch")])
        let chat = store()
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        var link = try #require(chat.project(for: existing.id))
        #expect(link.basis == .none && link.name == "Ungrouped" && link.basis.label == "No clear link" && !link.canUndo)
        #expect(link.choices.map(\.name) == ["Ungrouped", "Shape launch"])
        await chat.chooseProject(project)
        #expect(gateway.calls(prefix: "update") == ["update:\(existing.id.uuidString):\(project.uuidString)"])
        link = try #require(chat.project(for: existing.id))
        #expect(link.basis == .user && link.basis.label == "Set by you" && link.name == "Shape launch" && link.canUndo)
        await chat.undoProject()
        link = try #require(chat.project(for: existing.id))
        #expect(link.basis == .none && !link.canUndo)
        #expect(gateway.calls(prefix: "update").last == "update:\(existing.id.uuidString):nil")
    }

    @Test func noLinkRowWhenThereIsNothingToChooseAndNothingLinked() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing], contexts: [])
        let chat = store()
        await chat.refresh()
        #expect(chat.project(for: existing.id) == nil)
    }

    @Test func aProjectPickedOnABlankChatIsSentWhenItIsCreated() async throws {
        serve([], contexts: [WorkContext(id: project, name: "Shape launch")])
        let chat = store()
        await chat.refresh()
        let id = chat.newChat()
        await chat.chooseProject(project)
        #expect(gateway.calls(prefix: "update").isEmpty, "서버에 없는 대화는 쓰지 않는다")
        gateway.createHandler = { id, title, context in
            #expect(context == self.project)
            return ChatConversation(id: id, title: title, contextID: context, createdAt: .test())
        }
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        await chat.send("Hi")
        #expect(chat.project(for: id)?.contextID == project)
    }

    // MARK: 원문 삭제

    @Test func textDeletedByRetentionIsShownAsDeletedNotAsOldText() async throws {
        let purged = ChatConversation(id: ChatContractFixtures.id(1, prefix: "bcb50000"), title: "Old", contextID: nil, createdAt: .test(), lastMessageAt: .test(5), textPurgedAt: .test(9))
        let blank = Chats.message(1, in: purged.id, seq: 1, role: .user, text: "", cmid: UUID(), at: 1)
        let reply = Chats.message(2, in: purged.id, seq: 2, role: .assistant, text: "", replyTo: blank.id, at: 2)
        serve([purged], messages: [purged.id: [blank, reply]])
        let chat = store()
        chat.openChats()
        await chat.settle()
        #expect(chat.turns(for: purged.id).map(\.textDeleted) == [true, true])
        #expect(chat.entries.first?.preview == .unknown)
    }

    /// 접근을 잃은 대화(다른 곳에서 지움 · 보관)는 열려 있어도 닫는다 (옛 글을 다시 보이지 않는다)
    @Test func aConversationRemovedElsewhereIsClosed() async throws {
        let a = Chats.conversation(1, title: "A", last: 10)
        let msg = Chats.message(1, in: a.id, seq: 1, role: .user, text: "Secret old words", cmid: UUID(), at: 5)
        serve([a], messages: [a.id: [msg]])
        let chat = store()
        chat.openChats()
        await chat.settle()
        #expect(chat.turns(for: a.id).count == 1)
        serve([])
        await chat.refresh()
        #expect(chat.currentID == nil && chat.mode == .history)
        #expect(chat.turns(for: a.id).isEmpty && chat.entries.isEmpty)
    }

    // MARK: 기억 노트

    @Test func repliesLoadWhatTheyRemembered() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        let remembered = Memories.item(5, "Keeps pricing-page FAQs short")
        serve([existing])
        gateway.memoryItemsHandler = { ids in ids.contains(remembered.id) ? [remembered] : [] }
        let memory = MemoryStore(gateway: gateway, scope: scope)
        let chat = store(memory: memory)
        await chat.refresh()
        chat.open(existing.id)
        await chat.settle()
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text, memory: [remembered.id]) }
        await chat.send("Use the shorter FAQ")
        let reply = try #require(chat.turns(for: existing.id).last)
        #expect(reply.rememberedIDs == [remembered.id])
        #expect(memory.noteState(for: remembered.id) == .current(remembered))
    }
}

/// 테스트가 바꾸는 값 상자
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
