import Foundation
import Testing
@testable import TaskforceKit

/// 가짜 `AssistantGateway`: 대상 목록 · 만들기 · 보내기를 스크립트로 정하고 부른 것을 남긴다
final class FakeAssistantGateway: AssistantGateway, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var _calls: [String] = []
    private var _attachments: [[ChatAttachment]] = []
    private var _targets: [ChatTarget] = []
    func record(_ call: String, attachments: [ChatAttachment]? = nil, target: ChatTarget? = nil) {
        lock.lock()
        _calls.append(call)
        if let attachments { _attachments.append(attachments) }
        if let target { _targets.append(target) }
        lock.unlock()
    }
    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }
    func calls(prefix: String) -> [String] { calls.filter { $0.hasPrefix(prefix) } }
    /// 보낸 칩들 (보낸 차례대로)
    var sentAttachments: [[ChatAttachment]] {
        lock.lock()
        defer { lock.unlock() }
        return _attachments
    }
    var createdTargets: [ChatTarget] {
        lock.lock()
        defer { lock.unlock() }
        return _targets
    }

    nonisolated(unsafe) var targetsHandler: @Sendable () async throws -> [AssistantTarget] = { [.taskforce] }
    nonisolated(unsafe) var createHandler: @Sendable (UUID, String?, UUID?, ChatTarget) async throws -> ChatCreatedConversation = { id, title, context, target in
        var agentConnection: UUID?
        if case .agent(let connection, _) = target { agentConnection = connection }
        return ChatCreatedConversation(
            conversation: ChatConversation(id: id, title: title, contextID: context, createdAt: .test()),
            target: agentConnection.map { ChatConversationTarget(kind: .agent, agentConnectionID: $0) } ?? .taskforce
        )
    }
    nonisolated(unsafe) var postTaskforceHandler: @Sendable (UUID, UUID, String) async throws -> ChatPostedMessage = { _, _, _ in throw Failure() }
    nonisolated(unsafe) var postAgentHandler: @Sendable (UUID, UUID, String) async throws -> AgentPostedMessage = { _, _, _ in throw Failure() }

    func targets() async throws -> [AssistantTarget] { record("targets"); return try await targetsHandler() }

    func createConversation(id: UUID, title: String?, contextID: UUID?, target: ChatTarget) async throws -> ChatCreatedConversation {
        record("create:\(id.uuidString)", target: target)
        return try await createHandler(id, title, contextID, target)
    }

    func postChatMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> ChatPostedMessage {
        record("postTaskforce:\(conversationID.uuidString):\(clientMessageID.uuidString)", attachments: attachments)
        return try await postTaskforceHandler(conversationID, clientMessageID, text)
    }

    func postAgentMessage(conversationID: UUID, clientMessageID: UUID, text: String, attachments: [ChatAttachment]) async throws -> AgentPostedMessage {
        record("postAgent:\(conversationID.uuidString):\(clientMessageID.uuidString)", attachments: attachments)
        return try await postAgentHandler(conversationID, clientMessageID, text)
    }
}

/// Assistant 창이 쓰는 대화 저장소 쪽 (OA U1): 대화 id를 받는 읽기 · 보내기라 창마다 대화가 따로 논다 · 대상은 대화마다 · 칩은 같은 제출로 다시 간다
@MainActor
struct ChatStoreWindowsTests {
    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let scope = ChatTestAccount.fixedScope()
    let connection = UUID(uuidString: "a3333333-3333-4333-8333-333333333333")!
    let action = UUID(uuidString: "c1000000-0000-4000-8000-000000000001")!

    func store() -> ChatStore {
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        return chat
    }

    func serve(_ chats: [ChatConversation], messages: [UUID: [ChatMessage]] = [:]) {
        gateway.conversationsHandler = { chats }
        gateway.messagesHandler = { messages[$0] ?? [] }
        gateway.lastMessagesHandler = { ids in
            var result: [UUID: ChatMessage] = [:]
            for id in ids { if let last = messages[id]?.last { result[id] = last } }
            return result
        }
    }

    func chip(_ origin: ChatAttachmentOrigin = .added) -> ChatAttachment { ChatAttachment(kind: .action, id: action, origin: origin) }

    func agentPosted(_ conversation: UUID, cmid: UUID, text: String, delivery: AgentDelivery) -> AgentPostedMessage {
        AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: delivery)
    }

    // MARK: 창마다 대화 하나

    @Test func twoWindowsKeepTheirOwnConversationsDraftsAndSends() async throws {
        let a = Chats.conversation(1, title: "Pricing", last: 10)
        let b = Chats.conversation(2, title: "Launch", last: 20)
        serve([a, b])
        let chat = store()
        await chat.refresh()
        chat.ensureLoaded(a.id)
        chat.ensureLoaded(b.id)
        await chat.settle()
        let navigation = (chat.currentID, chat.mode, chat.focusRequest)
        chat.setDraft("draft for A", for: a.id)
        chat.setDraft("draft for B", for: b.id)
        gateway.postHandler = { conversation, cmid, text in Chats.pair(conversation == a.id ? 1 : 3, in: conversation, seq: 1, cmid: cmid, text: text) }
        await chat.send("Hello from B", in: b.id, attachments: [])
        #expect(chat.turns(for: b.id).map(\.text) == ["Hello from B", "Noted."])
        #expect(chat.turns(for: a.id).isEmpty, "A는 그대로")
        #expect(chat.draft(for: a.id) == "draft for A", "B를 보내도 A의 초안은 남는다")
        #expect(chat.draft(for: b.id) == "", "보낸 B의 초안은 비었다")
        #expect(chat.currentID == navigation.0 && chat.mode == navigation.1 && chat.focusRequest == navigation.2, "창의 대화는 저장소의 currentID · mode · 포커스를 건드리지 않는다")
    }

    @Test func contextualSendPreservesTheIndependentMainDraft() async {
        let row = Chats.conversation(1, title: "Main", last: 10)
        serve([row])
        let chat = store()
        await chat.refresh()
        chat.ensureLoaded(row.id)
        await chat.settle()
        chat.setDraft("Unfinished Main draft", for: row.id)
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        #expect(await chat.send("Regarding selected agent: check links", in: row.id, preservingDraft: true))
        #expect(chat.draft(for: row.id) == "Unfinished Main draft")
        #expect(chat.turns(for: row.id).map(\.text) == ["Regarding selected agent: check links", "Noted."])
    }

    @Test func failedContextualSendAlsoPreservesTheMainDraft() async {
        let row = Chats.conversation(1, title: "Main", last: 10)
        serve([row])
        let chat = store()
        await chat.refresh()
        chat.ensureLoaded(row.id)
        await chat.settle()
        chat.setDraft("Unfinished Main draft", for: row.id)
        gateway.postHandler = { _, _, _ in throw APIError.unexpectedStatus(503) }
        #expect(await chat.send("Regarding selected agent: check links", in: row.id, preservingDraft: true))
        #expect(chat.draft(for: row.id) == "Unfinished Main draft")
        #expect(chat.turns(for: row.id).first?.text == "Regarding selected agent: check links")
    }

    @Test func contextualSendReturnsFalseWhenNoPendingTurnWasAccepted() async {
        let row = Chats.conversation(1, title: "Main", last: 10)
        serve([row])
        let chat = store()
        await chat.refresh()
        chat.ensureLoaded(row.id)
        await chat.settle()
        chat.setDraft("Main draft", for: row.id)
        #expect(!(await chat.send("   ", in: row.id, preservingDraft: true)))
        #expect(!(await chat.send("Context", in: UUID(), preservingDraft: true)))
        #expect(chat.draft(for: row.id) == "Main draft" && chat.turns(for: row.id).isEmpty)
    }

    @Test func refreshReadsEveryConversationAWindowShowsNotOnlyTheSharedCurrentOne() async throws {
        let a = Chats.conversation(1, title: "A", last: 20)
        let b = Chats.conversation(2, title: "B", last: 10)
        serve([a, b])
        let chat = store()
        chat.viewedConversations = { [b.id, UUID()] }
        await chat.refresh()
        #expect(chat.currentID == a.id, "공유 currentID는 마지막 대화")
        #expect(chat.turns(for: b.id).isEmpty)
        let reply = Chats.message(1, in: b.id, seq: 1, role: .assistant, text: "new reply", at: 5)
        serve([a, b], messages: [b.id: [reply]])
        await chat.refresh()
        #expect(chat.turns(for: b.id).map(\.text) == ["new reply"], "창이 보이는 B도 ⌘3 · 온라인 복귀 때 다시 읽는다")
        #expect(gateway.calls(prefix: "messages").count >= 2)
    }

    @Test func refreshWithoutWindowsReadsOnlyTheCurrentConversation() async throws {
        let a = Chats.conversation(1, title: "A", last: 20)
        let b = Chats.conversation(2, title: "B", last: 10)
        serve([a, b], messages: [b.id: [Chats.message(1, in: b.id, seq: 1, role: .assistant, text: "hidden", at: 5)]])
        let chat = store()
        await chat.refresh()
        #expect(chat.currentID == a.id && chat.turns(for: b.id).isEmpty, "창이 안 보이는 대화를 읽지 않는다")
    }

    @Test func sendingInOneConversationDoesNotBlockAnother() async throws {
        let a = Chats.conversation(1, title: "A", last: 10)
        let b = Chats.conversation(2, title: "B", last: 20)
        serve([a, b])
        let chat = store()
        await chat.refresh()
        let latch = Latch()
        gateway.postHandler = { conversation, cmid, text in
            if conversation == a.id { await latch.wait() }
            return Chats.pair(conversation == a.id ? 1 : 3, in: conversation, seq: 1, cmid: cmid, text: text)
        }
        let first = Task { await chat.send("slow", in: a.id, attachments: []) }
        _ = await latch.waitForArrivals(1, timeout: .seconds(5))
        #expect(chat.isSending(in: a.id) && !chat.isSending(in: b.id))
        await chat.send("fast", in: b.id, attachments: [])
        #expect(chat.turns(for: b.id).map(\.status) == [.sent, .sent], "A가 보내는 중이어도 B는 보낸다")
        #expect(chat.canCompose(in: b.id))
        await latch.open()
        await first.value
        #expect(!chat.isSending(in: a.id))
    }

    @Test func screenAndTitleAreReadPerConversation() async throws {
        let a = Chats.conversation(1, title: "Pricing", last: 10)
        let b = Chats.conversation(2, title: "Launch", last: 20)
        serve([a, b], messages: [a.id: [Chats.message(1, in: a.id, seq: 1, role: .user, text: "hi")]])
        gateway.messagesHandler = { id in
            if id == b.id { throw URLError(.notConnectedToInternet) }
            return [Chats.message(1, in: a.id, seq: 1, role: .user, text: "hi")]
        }
        let chat = store()
        await chat.refresh()
        chat.ensureLoaded(a.id)
        chat.ensureLoaded(b.id)
        await chat.settle()
        #expect(chat.screen(for: a.id) == .ready(problem: nil))
        #expect(chat.screen(for: b.id) == .offline, "B만 읽지 못했다")
        #expect(chat.title(for: a.id) == "Pricing" && chat.title(for: b.id) == "Launch")
        #expect(chat.title(for: UUID()) == ChatCopy.newChat)
        #expect(chat.screen(for: nil) == .blank)
    }

    @Test func loadingAConversationForAWindowDoesNotNavigateTheStore() async throws {
        let a = Chats.conversation(1, title: "A", last: 10)
        let b = Chats.conversation(2, title: "B", last: 20)
        serve([a, b], messages: [a.id: [Chats.message(1, in: a.id, seq: 1, role: .user, text: "hi")]])
        let chat = store()
        await chat.refresh()
        let before = (chat.currentID, chat.mode, chat.focusRequest)
        chat.ensureLoaded(a.id)
        await chat.settle()
        #expect(chat.turns(for: a.id).map(\.text) == ["hi"], "읽어 온다")
        #expect((chat.currentID, chat.mode, chat.focusRequest) == before, "읽기만 한다: 저장소의 현재 대화 · 모드 · 포커스는 그대로")
        chat.ensureLoaded(UUID())
        await chat.settle()
        #expect(gateway.calls(prefix: "messages").count == 2, "refresh가 되살린 대화 하나 + 창이 연 대화 하나. 서버에 없는 대화는 읽지 않는다")
    }

    // MARK: 새 대화

    @Test func reserveNewChatReusesAnEmptyChatUnlessAnotherWindowHoldsIt() async throws {
        serve([])
        let chat = store()
        let first = chat.reserveNewChat(target: .taskforce, excluding: [])
        #expect(chat.locals.map(\.id) == [first])
        #expect(chat.reserveNewChat(target: .taskforce, excluding: []) == first, "손대지 않은 빈 대화는 다시 쓴다")
        let second = chat.reserveNewChat(target: .taskforce, excluding: [first])
        #expect(second != first && chat.locals.count == 2, "다른 창이 쥔 빈 대화는 쓰지 않고 새로 만든다")
        #expect(chat.currentID == nil, "저장소의 currentID는 그대로")
    }

    /// 서버에 이미 있는 빈 대화의 대상은 바뀌지 않는다: 대상이 같은 것만 다시 쓴다
    @Test func anEmptyServerChatIsOnlyReusedForTheSameTarget() async throws {
        let plainEmpty = Chats.conversation(1, title: nil, at: 10)
        let agentEmpty = ChatConversation(
            id: ChatContractFixtures.id(2, prefix: "bcb50000"), createdAt: .test(20), target: ChatConversationTarget(kind: .agent, agentConnectionID: connection)
        )
        serve([plainEmpty, agentEmpty])
        let chat = store()
        await chat.refresh()
        #expect(chat.reserveNewChat(target: .taskforce, excluding: []) == plainEmpty.id, "Taskforce 새 대화는 빈 Taskforce 대화를 다시 쓴다 (더 새로운 에이전트 빈 대화가 아니라)")
        #expect(chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: connection), excluding: []) == agentEmpty.id, "같은 연결의 에이전트 새 대화는 그 빈 대화")
        let otherConnection = UUID()
        let fresh = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: otherConnection), excluding: [])
        #expect(fresh != agentEmpty.id && fresh != plainEmpty.id && chat.isLocalChat(fresh), "다른 연결이면 새 로컬 대화")
        #expect(chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: nil), excluding: []) != agentEmpty.id, "연결을 모르는 에이전트는 서버 대화를 다시 쓰지 않는다")
    }

    @Test func aLocalChatCanChangeItsTargetUntilItsFirstMessage() async throws {
        serve([])
        let chat = store()
        let id = chat.reserveNewChat(target: .taskforce, excluding: [])
        #expect(chat.pick(for: id) == .taskforce)
        let codex = AssistantTargetPick.agent(adapter: "agent:codex", connectionID: connection)
        chat.setLocalTarget(codex, for: id)
        #expect(chat.pick(for: id) == codex && chat.conversationTarget(for: id).isAgent)
        chat.setLocalTarget(.taskforce, for: id)
        #expect(chat.pick(for: id) == .taskforce)
        // 서버에 있는 대화의 대상은 바꾸지 않는다
        let existing = Chats.conversation(5, title: "X", last: 10)
        serve([existing])
        await chat.refresh()
        chat.setLocalTarget(codex, for: existing.id)
        #expect(chat.conversationTarget(for: existing.id) == .taskforce)
    }

    @Test func aReusedEmptyChatTakesTheRequestedTarget() async throws {
        serve([])
        let chat = store()
        let first = chat.reserveNewChat(target: .taskforce, excluding: [])
        let codex = AssistantTargetPick.agent(adapter: "agent:codex", connectionID: connection)
        #expect(chat.reserveNewChat(target: codex, excluding: []) == first)
        #expect(chat.pick(for: first) == codex, "다시 쓰는 빈 대화도 이번에 고른 대상으로")
    }

    @Test func lastConversationIsTheNewestServerChat() async throws {
        let older = Chats.conversation(1, title: "Older", at: 0, last: 100)
        let latest = Chats.conversation(2, title: "Latest", at: 10, last: 300)
        serve([older, latest])
        let chat = store()
        #expect(chat.lastConversationID == nil)
        await chat.refresh()
        _ = chat.reserveNewChat(target: .taskforce, excluding: [])
        #expect(chat.lastConversationID == latest.id, "빈 로컬 대화는 마지막 대화가 아니다")
    }

    // MARK: 에이전트 대상

    @Test func anAgentChatIsCreatedWithItsConnectionThenSentWithTheChips() async throws {
        serve([])
        let chat = store()
        let id = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: connection), excluding: [])
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(
                message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1),
                delivery: AgentDelivery(state: .sent), agentTask: nil
            )
        }
        await chat.send("이어서 해 줘", in: id, attachments: [chip(.added), chip(.auto)])
        #expect(assistant.createdTargets == [.agent(connectionID: connection)])
        #expect(assistant.calls(prefix: "postAgent").count == 1 && assistant.calls(prefix: "postTaskforce").isEmpty)
        #expect(gateway.calls(prefix: "create").isEmpty && gateway.calls(prefix: "post").isEmpty, "에이전트 대화는 Taskforce 쪽 만들기 · 보내기를 거치지 않는다")
        #expect(assistant.sentAttachments == [[chip(.added), chip(.auto)]], "칩은 origin과 함께 간다: auto를 보낼지는 서버가 정한다")
        let target = chat.conversationTarget(for: id)
        #expect(target.isAgent && target.agentConnectionID == connection, "만든 뒤의 대상은 서버 응답의 대상 열이다")
        let turns = chat.turns(for: id)
        #expect(turns.count == 1, "답은 비동기로 대화에 쓰인다: 지금은 사용자 글뿐")
        #expect(turns[0].status == .sent, "에이전트 대화는 'No reply yet'을 말하지 않는다")
        #expect(turns[0].delivery?.state == .sent)
    }

    @Test func deliveryStaysWithItsMessageAndTheNextMessageGetsItsOwn() async throws {
        serve([])
        let chat = store()
        let id = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: connection), excluding: [])
        let counter = Counter()
        assistant.postAgentHandler = { conversation, cmid, text in
            let n = counter.next()
            let state: AgentDeliveryState = n == 1 ? .accepted : .notSent
            return AgentPostedMessage(
                message: Chats.message(n, in: conversation, seq: n, role: .user, text: text, cmid: cmid, at: Double(n)),
                delivery: AgentDelivery(state: state, reason: n == 1 ? nil : .writeGateClosed)
            )
        }
        await chat.send("first", in: id, attachments: [])
        await chat.send("second", in: id, attachments: [])
        let turns = chat.turns(for: id)
        #expect(turns.map(\.text) == ["first", "second"])
        #expect(turns.map { $0.delivery?.state } == [.accepted, .notSent])
        #expect(turns[1].delivery?.reason == .writeGateClosed)
    }

    @Test func anAgentChatWithoutAConnectionFailsLocallyAndCallsNothing() async throws {
        serve([])
        let chat = store()
        let id = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: nil), excluding: [])
        await chat.send("hello", in: id, attachments: [])
        #expect(assistant.calls(prefix: "create").isEmpty && assistant.calls(prefix: "post").isEmpty && gateway.calls(prefix: "create").isEmpty)
        let turn = try #require(chat.turns(for: id).first)
        #expect(turn.status == .failed(ChatCopy.agentNotConnected) && turn.status.canRetry)
        #expect(ChatCopy.agentNotConnected == "Not connected")
        #expect(chat.locals.map(\.id) == [id], "만들지 못했으니 로컬 대화로 남는다")
        // 연결이 생긴 뒤(대상을 다시 고름) 같은 글을 다시 보낸다
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .sent))
        }
        chat.setLocalTarget(.agent(adapter: "agent:codex", connectionID: connection), for: id)
        await chat.retry(try #require(turn.clientMessageID), in: id)
        #expect(assistant.createdTargets == [.agent(connectionID: connection)])
        #expect(chat.turns(for: id).first?.delivery?.state == .sent)
    }

    @Test func anAgentSendThatFailsCanRetryWithTheSameSubmissionAndChips() async throws {
        serve([])
        let chat = store()
        let id = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: connection), excluding: [])
        let attempts = Counter()
        assistant.postAgentHandler = { conversation, cmid, text in
            if attempts.next() == 1 { throw APIError.server(status: 503, code: .internalError, message: "x") }
            return AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .queued, reason: .sessionBusy))
        }
        await chat.send("hello", in: id, attachments: [chip()])
        let failed = try #require(chat.turns(for: id).first)
        #expect(failed.status.canRetry)
        await chat.retry(try #require(failed.clientMessageID), in: id)
        let posts = assistant.calls(prefix: "postAgent")
        #expect(posts.count == 2 && posts[0] == posts[1], "같은 conversation · 같은 client_message_id")
        #expect(assistant.sentAttachments == [[chip()], [chip()]], "같은 제출은 같은 칩")
        #expect(chat.turns(for: id).count == 1 && chat.turns(for: id)[0].delivery?.state == .queued)
        #expect(assistant.calls(prefix: "create").count == 1, "대화는 한 번만 만든다: 두 번째 시도는 이미 서버에 있는 대화로 보낸다")
    }

    @Test func serverRowsCarryTheirTargetIntoTheStoreAndTheHistory() async throws {
        let agentChat = ChatConversation(
            id: ChatContractFixtures.id(7, prefix: "bcb50000"), title: "Fix the build", createdAt: .test(), lastMessageAt: .test(50),
            target: ChatConversationTarget(kind: .agent, agentConnectionID: connection)
        )
        let plain = Chats.conversation(8, title: "Pricing", last: 10)
        serve([agentChat, plain])
        let chat = store()
        await chat.refresh()
        #expect(chat.conversationTarget(for: agentChat.id).isAgent && !chat.conversationTarget(for: plain.id).isAgent)
        let entries = chat.entries
        #expect(entries.first { $0.id == agentChat.id }?.target.agentConnectionID == connection, "History에는 두 대상의 대화가 모두 있다")
        #expect(entries.first { $0.id == plain.id }?.target == .taskforce)
        let local = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: connection), excluding: [])
        let localEntry = try #require(chat.entries.first { $0.id == local })
        #expect(localEntry.target.isAgent && localEntry.localAdapter == "agent:codex")
    }

    /// RLS로 읽는 `conversations` 행: 대상 열이 있으면 읽고, 없으면(옛 행) Taskforce, 열 이름은 읽는 열 목록에 든다
    @Test func aConversationRowReadsItsTargetColumns() throws {
        let agentRow = #"""
        {"id":"bcb50000-0000-4000-8000-000000000007","title":"Fix the build","context_id":null,"created_at":"2026-10-14T01:00:00.000Z","last_message_at":"2026-10-14T01:05:00.000Z",
         "last_read_at":null,"archived_at":null,"text_purged_at":null,"target_kind":"agent","agent_connection_id":"a3333333-3333-4333-8333-333333333333","agent_session_id":"a4444444-4444-4444-8444-444444444444"}
        """#
        let agent = try TaskforceJSON.decoder().decode(ChatConversation.self, from: Data(agentRow.utf8))
        #expect(agent.target == ChatConversationTarget(kind: .agent, agentConnectionID: connection, agentSessionID: UUID(uuidString: "a4444444-4444-4444-8444-444444444444")))
        #expect(agent.title == "Fix the build" && agent.lastMessageAt != nil)
        let oldRow = agentRow.replacingOccurrences(of: #","target_kind":"agent","agent_connection_id":"a3333333-3333-4333-8333-333333333333","agent_session_id":"a4444444-4444-4444-8444-444444444444""#, with: "")
        #expect(try TaskforceJSON.decoder().decode(ChatConversation.self, from: Data(oldRow.utf8)).target == .taskforce)
        let taskforce = agentRow.replacingOccurrences(of: #""target_kind":"agent","agent_connection_id":"a3333333-3333-4333-8333-333333333333","agent_session_id":"a4444444-4444-4444-8444-444444444444""#, with: #""target_kind":"taskforce","agent_connection_id":null,"agent_session_id":null"#)
        #expect(try TaskforceJSON.decoder().decode(ChatConversation.self, from: Data(taskforce.utf8)).target == .taskforce)
        for column in ["target_kind", "agent_connection_id", "agent_session_id"] {
            #expect(ChatConversation.columns.contains(column), "RLS 읽기가 \(column)을 고른다")
        }
    }

    /// 범위를 바꾸는 PATCH 응답이 대상 열을 주지 않아도 에이전트 대화가 Taskforce로 바뀌지 않는다
    @Test func changingTheProjectOfAnAgentChatKeepsItsTarget() async throws {
        let agentChat = ChatConversation(
            id: ChatContractFixtures.id(7, prefix: "bcb50000"), title: "Fix the build", createdAt: .test(), lastMessageAt: .test(50),
            target: ChatConversationTarget(kind: .agent, agentConnectionID: connection)
        )
        serve([agentChat])
        let project = ChatContractFixtures.contextID
        gateway.updateHandler = { id, context in ChatConversation(id: id, title: "Fix the build", contextID: context, createdAt: .test(), lastMessageAt: .test(50)) }
        let chat = store()
        await chat.refresh()
        await chat.chooseProject(project, in: agentChat.id)
        #expect(chat.conversationTarget(for: agentChat.id).isAgent && chat.conversationTarget(for: agentChat.id).agentConnectionID == connection)
        #expect(chat.conversations.first { $0.id == agentChat.id }?.contextID == project)
        await chat.undoProject(in: agentChat.id)
        #expect(chat.conversationTarget(for: agentChat.id).isAgent, "되돌려도 대상은 그대로")
        #expect(chat.currentID != nil, "창의 프로젝트 바꾸기는 저장소의 현재 대화와 상관없다 (refresh가 되살린 대화)")
    }

    // MARK: Taskforce 대상의 칩

    @Test func aTaskforceMessageWithChipsUsesTheChipRouteAndWithoutChipsTheOldOne() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = store()
        await chat.refresh()
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        assistant.postTaskforceHandler = { conversation, cmid, text in Chats.pair(3, in: conversation, seq: 3, cmid: cmid, text: text) }
        await chat.send("plain", in: existing.id, attachments: [])
        await chat.send("with chip", in: existing.id, attachments: [chip(.auto)])
        #expect(gateway.calls(prefix: "post").count == 1, "칩이 없으면 기존 보내기 그대로")
        #expect(assistant.calls(prefix: "postTaskforce").count == 1 && assistant.sentAttachments == [[chip(.auto)]])
        #expect(chat.turns(for: existing.id).map(\.text) == ["plain", "Noted.", "with chip", "Noted."])
    }

    @Test func withoutAnAssistantGatewayTheOldRoutesStillWork() async throws {
        let existing = Chats.conversation(1, title: "Chat", last: 10)
        serve([existing])
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        await chat.refresh()
        gateway.postHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        await chat.send("hi", in: existing.id, attachments: [chip()])
        #expect(gateway.calls(prefix: "post").count == 1, "AssistantGateway가 없는 런타임(견본 등)은 기존 경로로 칩 없이 보낸다")
        #expect(chat.turns(for: existing.id).map(\.status) == [.sent, .sent])
    }

    // MARK: 계정

    @Test func leavingTheAccountClearsTargetsAndDeliveries() async throws {
        serve([])
        let account = try ChatTestAccount.make()
        let chat = ChatStore(gateway: gateway, scope: account.scope, now: { .test(500) })
        chat.assistant = assistant
        let id = chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: connection), excluding: [])
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .sent))
        }
        await chat.send("x", in: id, attachments: [])
        #expect(chat.turns(for: id).first?.delivery != nil)
        account.session.apply(event: .signedOut, session: nil)
        #expect(chat.turns(for: id).isEmpty && chat.deliveryCount == 0)
        #expect(chat.locals.isEmpty)
    }
}
