import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트 대화의 전달 (OA D4a-1, 계약 D4a-10 · 11): 전달 줄을 서버에서 다시 읽는다 (대화를 열 때 · 온라인 복귀 · 깸 · 5초) · Send again · 후보 고르기 · 재시도에서 id · 칩 유지.
/// 고친 두 버그: (1) 앱을 다시 켜면 서버에 저장된 에이전트 메시지를 칩 없이 다시 올렸다 (2) 전달 줄이 메모리뿐이라 대화를 다시 읽으면 사라졌다
@MainActor
struct ChatStoreAgentDeliveryTests {
    typealias Fx = AgentFx
    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let agent = FakeAgentConversationGateway()
    let ticker = ManualTicker()
    let scope = ChatTestAccount.fixedScope()
    let chipAction = UUID(uuidString: "c1000000-0000-4000-8000-000000000001")!

    func store(scope: AccountScope? = nil) -> ChatStore {
        let chat = ChatStore(gateway: gateway, scope: scope ?? self.scope, now: { .test(500) }, sleep: { [ticker] in await ticker.sleep($0) })
        chat.assistant = assistant
        chat.agentConversation = agent
        return chat
    }

    /// 앱을 막 켠 것처럼: 서버 대화와 글을 읽고 그 대화를 보인다
    func open(_ conversation: ChatConversation, messages: [ChatMessage], chat: ChatStore) async {
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in messages }
        gateway.lastMessagesHandler = { _ in [:] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        await chat.settle()
    }

    func serve(_ entries: @escaping @Sendable (Int?) -> [ConversationDeliveryResponse.Entry]) {
        agent.deliveriesHandler = { _, since in ConversationDeliveryResponse(messages: entries(since)) }
    }

    func line(_ chat: ChatStore, _ message: ChatMessage) -> AgentDeliveryState? {
        chat.turns(for: message.conversationID).first { $0.id == message.id }?.delivery?.state
    }

    // MARK: 전달 줄을 서버에서 읽는다 (버그 2)

    @Test func aRestartedAppReadsTheDeliveryLinesFromTheServerWhenTheConversationOpens() async {
        let conversation = Fx.conversation()
        let first = Fx.user(1, in: conversation.id, seq: 1)
        let second = Fx.user(2, in: conversation.id, seq: 2)
        serve { _ in [Fx.entry(first, AgentDelivery(state: .accepted)), Fx.entry(second, AgentDelivery(state: .notSent, reason: .usageLimited))] }
        let chat = store()
        #expect(chat.delivery(forMessage: first.id) == nil, "읽기 전에는 줄이 없다")
        await open(conversation, messages: [first, second], chat: chat)
        #expect(chat.turns(for: conversation.id).map(\.delivery) == [AgentDelivery(state: .accepted), AgentDelivery(state: .notSent, reason: .usageLimited)])
        #expect(agent.reads == [.init(conversation: conversation.id, sinceSeq: nil)], "처음에는 처음부터 한 번")
        // 또 한 번 "다시 켠" 저장소도 같다: 줄은 메모리가 아니라 서버에서 온다
        let restarted = store()
        await open(conversation, messages: [first, second], chat: restarted)
        #expect(restarted.turns(for: conversation.id).map(\.delivery?.state) == [.accepted, .notSent])
    }

    @Test func aTaskforceConversationNeverReadsDeliveries() async {
        let plain = ChatConversation(id: ChatContractFixtures.id(2, prefix: "bcb50000"), createdAt: .test(), lastMessageAt: .test(10))
        let message = Chats.message(1, in: plain.id, seq: 1, role: .user, text: "Hi", cmid: UUID(), at: 1)
        let chat = store()
        await open(plain, messages: [message], chat: chat)
        #expect(agent.reads.isEmpty && chat.turns(for: plain.id).allSatisfy { $0.delivery == nil })
        // 직접 불러도 같다: 에이전트 대화가 아니면 전달 읽기를 서버에 보내지 않는다
        await chat.refreshDeliveries(plain.id)
        await chat.refreshShownDeliveries()
        #expect(agent.reads.isEmpty, "Taskforce 대화는 전달 읽기 route를 부르지 않는다")
    }

    @Test func aHundredAreReadAtATimeAndTheReadContinuesFromTheLastSeq() async {
        let conversation = Fx.conversation()
        let messages = (1...130).map { Fx.user($0, in: conversation.id, seq: $0) }
        serve { since in
            let from = (since ?? 0) + 1
            return messages.filter { $0.seq >= from }.prefix(100).map { Fx.entry($0, AgentDelivery(state: .accepted)) }
        }
        let chat = store()
        await open(conversation, messages: messages, chat: chat)
        #expect(agent.reads.map(\.sinceSeq) == [nil, 100], "100개 → 이어서 100 뒤부터 → 30개로 끝")
        #expect(chat.turns(for: conversation.id).count == 130 && chat.turns(for: conversation.id).allSatisfy { $0.delivery?.state == .accepted })
    }

    // MARK: 5초 다시 읽기

    @Test func anUnsettledMessageKeepsRereadingEveryFiveSecondsFromItsSeqAndSettlingStopsIt() async {
        let conversation = Fx.conversation()
        let done = Fx.user(1, in: conversation.id, seq: 1)
        let waiting = Fx.user(2, in: conversation.id, seq: 2)
        let state = Mutex2(AgentDeliveryState.queued)
        serve { _ in [Fx.entry(done, AgentDelivery(state: .accepted)), Fx.entry(waiting, AgentDelivery(state: state.value))] }
        let chat = store()
        await open(conversation, messages: [done, waiting], chat: chat)
        #expect(await eventually { ticker.pendingDelays == [5] }, "queued가 보이는 동안 5초")
        ticker.fire()
        #expect(await eventually { agent.reads.count == 2 })
        #expect(agent.reads[1].sinceSeq == 1, "안 끝난 가장 낮은 seq 2 바로 앞부터")
        #expect(await eventually { ticker.pendingDelays == [5] }, "아직 queued: 다시 5초")
        state.value = .accepted
        ticker.fire()
        #expect(await eventually { agent.reads.count == 3 })
        await quiet()
        #expect(ticker.pendingDelays.isEmpty && line(chat, waiting) == .accepted, "끝나면 멈춘다")
    }

    @Test func aSleepingAppStopsTheReadAndWakingReadsOnce() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let state = Mutex2(AgentDeliveryState.sent)
        serve { _ in [Fx.entry(message, AgentDelivery(state: state.value))] }
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        #expect(await eventually { ticker.pendingDelays == [5] })
        chat.setAsleep(true)
        ticker.fire()
        await quiet()
        #expect(agent.reads.count == 1 && ticker.pendingDelays.isEmpty, "자는 동안 멈춘다")
        state.value = .accepted
        chat.setAsleep(false)
        #expect(await eventually { agent.reads.count == 2 }, "깨면 한 번 읽는다")
        await chat.settle()
        #expect(line(chat, message) == .accepted)
        chat.setAsleep(false)
        await quiet()
        #expect(agent.reads.count == 2, "이미 깨어 있으면 읽지 않는다")
    }

    @Test func comingBackOnlineReadsOnceAndStayingOnlineReadsNothing() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        #expect(agent.reads.count == 1)
        chat.pathChanged(online: false)
        chat.pathChanged(online: true)
        #expect(await eventually { agent.reads.count == 2 })
        chat.pathChanged(online: true)
        await quiet()
        #expect(agent.reads.count == 2, "이미 온라인이면 읽지 않는다")
    }

    // MARK: 읽는 중 · 실패 · 계정

    @Test func theLineIsNotDrawnBeforeTheFirstReadAndStaysWhileRereading() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let latch = Latch()
        serve { _ in [Fx.entry(message, AgentDelivery(state: .queued))] }
        let inner = agent.deliveriesHandler
        agent.deliveriesHandler = { id, since in
            await latch.wait()
            return try await inner(id, since)
        }
        let chat = store()
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in [message] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        #expect(line(chat, message) == nil, "처음 읽기가 오기 전에는 그리지 않는다")
        await latch.open()
        await chat.settle()
        #expect(line(chat, message) == .queued)
        // 다시 읽는 동안 (스피너 없이) 앞 줄이 그대로다
        let second = Latch()
        agent.deliveriesHandler = { _, _ in
            await second.wait()
            return ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .accepted))])
        }
        #expect(await eventually { ticker.pendingDelays == [5] })
        ticker.fire()
        #expect(await second.waitForArrivals(1, timeout: .seconds(3)))
        #expect(line(chat, message) == .queued, "읽는 동안 앞에 받은 줄을 그대로 둔다")
        await second.open()
        #expect(await eventually { line(chat, message) == .accepted })
    }

    /// 이미 읽는 중이면 그 읽기가 서버 값을 가져온다: 같은 대화의 읽기를 겹쳐 보내지 않는다 (열기 · 온라인 복귀 · 깸 · 5초가 한꺼번에 와도 요청은 하나)
    @Test func aSecondReadOfTheSameConversationWhileOneIsInFlightSendsNothing() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let latch = Latch()
        serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
        let inner = agent.deliveriesHandler
        agent.deliveriesHandler = { id, since in
            await latch.wait()
            return try await inner(id, since)
        }
        let chat = store()
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in [message] }
        gateway.lastMessagesHandler = { _ in [:] }
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        async let again: Void = chat.refreshDeliveries(conversation.id)
        #expect(await noSecondRequest(latch), "읽는 중인 대화는 다시 읽지 않는다")
        await latch.open()
        _ = await again
        await chat.settle()
        #expect(agent.reads.count == 1 && line(chat, message) == .accepted)
    }

    @Test func aFailedReadKeepsThePreviousLines() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        serve { _ in [Fx.entry(message, AgentDelivery(state: .queued))] }
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        agent.deliveriesHandler = { _, _ in throw FakeAgentConversationGateway.Failure() }
        await chat.refreshDeliveries(conversation.id)
        #expect(line(chat, message) == .queued, "읽기 실패: 앞 줄 유지")
    }

    @Test func aWriteMadeAfterTheReadStartedIsNotOverwrittenByTheOlderAnswer() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let candidate = AgentReferentCandidate(actionID: chipAction, title: "가격 문구")
        serve { _ in [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: [candidate]))] }
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        // 5초 읽기를 붙잡는다 (옛 값 needs_referent를 돌려줄 것이다)
        let latch = Latch()
        agent.deliveriesHandler = { _, _ in
            await latch.wait()
            return ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: [candidate]))])
        }
        #expect(await eventually { ticker.pendingDelays == [5] })
        ticker.fire()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        agent.referentHandler = { conversation, messageID, _ in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: "t", cmid: UUID(), at: 1), delivery: AgentDelivery(state: .sent))
        }
        await chat.chooseReferent(chipAction, for: message.id, in: conversation.id)
        #expect(line(chat, message) == .sent)
        await latch.open()
        await chat.settle()
        #expect(line(chat, message) == .sent, "읽기를 시작한 뒤에 고른 것이 그 읽기의 옛 응답에 덮이지 않는다")
    }

    // MARK: 재시도 · id (버그 1)

    /// 버그 1: 앱을 다시 켠 뒤 서버에 저장된 에이전트 메시지를 칩 없이 다시 올렸다 (`sentChips`가 메모리뿐): 409 `refs_mismatch`이거나 칩이 어긋난다.
    /// 에이전트 대화의 저장된 메시지는 다시 올리지 않는다 (Send again은 서버 id로 deliver)
    @Test func aStoredAgentMessageIsNeverPostedAgainAfterARestart() async {
        let conversation = Fx.conversation()
        let cmid = UUID()
        let stored = Fx.user(1, in: conversation.id, seq: 1, cmid: cmid)
        serve { _ in [Fx.entry(stored, AgentDelivery(state: .notSent, reason: .writeGateClosed))] }
        assistant.postAgentHandler = { _, _, _ in throw FakeAssistantGateway.Failure() }
        let chat = store()
        await open(conversation, messages: [stored], chat: chat)
        await chat.retry(cmid, in: conversation.id)
        #expect(assistant.calls(prefix: "postAgent").isEmpty && assistant.calls(prefix: "postTaskforce").isEmpty, "저장된 글을 칩 없이 다시 올리지 않는다")
        #expect(gateway.calls(prefix: "post:").isEmpty)
    }

    @Test func aTaskforceChatStillRetriesItsStoredLastMessageWithoutAnAnswer() async {
        let plain = ChatConversation(id: ChatContractFixtures.id(2, prefix: "bcb50000"), createdAt: .test(), lastMessageAt: .test(10))
        let cmid = UUID()
        let stored = Chats.message(1, in: plain.id, seq: 1, role: .user, text: "Hi", cmid: cmid, at: 1)
        gateway.postHandler = { conversation, id, text in Chats.pair(1, in: conversation, seq: 1, cmid: id, text: text) }
        let chat = store()
        await open(plain, messages: [stored], chat: chat)
        await chat.retry(cmid, in: plain.id)
        #expect(gateway.calls(prefix: "post:").count == 1, "Taskforce 대화는 지금 그대로다")
    }

    @Test func aFailedAgentSendRetriesWithTheSameIDAndChipsAndStoresNothingTwice() async {
        let local = store()
        let id = local.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: Fx.connection), excluding: [])
        let chip = ChatAttachment(kind: .action, id: chipAction, origin: .added)
        let latchFail = Mutex2(true)
        assistant.postAgentHandler = { conversation, cmid, text in
            if latchFail.value { throw URLError(.timedOut) }
            return AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .sent))
        }
        await local.send("Fix it", in: id, attachments: [chip])
        let failedTurn = local.turns(for: id)[0]
        #expect(failedTurn.status.canRetry)
        latchFail.value = false
        await local.retry(failedTurn.id, in: id)
        let posts = assistant.calls(prefix: "postAgent")
        #expect(posts.count == 2 && posts[0] == posts[1], "같은 conversation · 같은 client_message_id")
        #expect(assistant.sentAttachments == [[chip], [chip]], "같은 칩")
    }

    // MARK: Send again

    func serveOne(_ delivery: AgentDelivery) -> (ChatConversation, ChatMessage) {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        serve { _ in [Fx.entry(message, delivery)] }
        return (conversation, message)
    }

    @Test func sendAgainDeliversTheStoredMessageByItsServerIDAndTakesTheNewLine() async {
        for state in [AgentDeliveryState.notSent, .expired] {
            let (conversation, message) = serveOne(AgentDelivery(state: state))
            let chat = store()
            await open(conversation, messages: [message], chat: chat)
            agent.deliverHandler = { _, ids in
                AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .queued, reason: .sessionBusy))])
            }
            await chat.sendAgain(message.id, in: conversation.id)
            #expect(agent.delivers.last == .init(conversation: conversation.id, messageIDs: [message.id]), "\(state.raw): 서버 메시지 id 하나")
            #expect(chat.delivery(forMessage: message.id) == AgentDelivery(state: .queued, reason: .sessionBusy), "requeued: 응답의 delivery로 줄을 바꾼다")
            #expect(assistant.calls(prefix: "postAgent").isEmpty, "새 메시지를 올리지 않는다")
        }
    }

    @Test func pressingSendAgainTwiceSendsOneRequest() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent, reason: .writeGateClosed))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let latch = Latch()
        agent.deliverHandler = { _, ids in
            await latch.wait()
            return AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .queued))])
        }
        async let first: Void = chat.sendAgain(message.id, in: conversation.id)
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        #expect(!chat.canSendAgain(message.id, in: conversation.id), "진행 중이면 다시 누르지 않는다")
        async let second: Void = chat.sendAgain(message.id, in: conversation.id)
        #expect(await noSecondRequest(latch), "두 번째 누름은 서버에 가지 않는다")
        await latch.open()
        _ = await (first, second)
        #expect(agent.delivers.count == 1)
        #expect(!chat.canSendAgain(message.id, in: conversation.id), "queued가 됐다")
    }

    @Test func aSkippedResultReadsAgainOrSaysUnknownAndAFailureLeavesTheLine() async {
        // not_eligible · not_found: 다시 읽는다
        for reason in [AgentDeliverResult.SkippedReason.notEligible, .notFound] {
            let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
            let chat = store()
            await open(conversation, messages: [message], chat: chat)
            let before = agent.reads.count
            serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
            agent.deliverHandler = { _, ids in AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .skipped, skippedReason: reason)]) }
            await chat.sendAgain(message.id, in: conversation.id)
            await chat.settle()
            #expect(agent.reads.count == before + 1 && chat.delivery(forMessage: message.id)?.state == .accepted, "\(reason.raw): 서버가 사실이다")
        }
        // unknown_outcome: Unknown 줄
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        agent.deliverHandler = { _, ids in
            AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .skipped, skippedReason: .unknownOutcome, delivery: AgentDelivery(state: .outcomeUnknown))])
        }
        await chat.sendAgain(message.id, in: conversation.id)
        #expect(chat.delivery(forMessage: message.id)?.state == .outcomeUnknown)
        #expect(!chat.canSendAgain(message.id, in: conversation.id), "Unknown에는 Send again이 없다")
        // 요청이 실패하면 줄은 그대로 (새 말 없음), 서버가 사실이라 다시 읽는다
        let (c2, m2) = serveOne(AgentDelivery(state: .expired))
        let other = store()
        await open(c2, messages: [m2], chat: other)
        let reads = agent.reads.count
        agent.deliverHandler = { _, _ in throw FakeAgentConversationGateway.Failure() }
        await other.sendAgain(m2.id, in: c2.id)
        await other.settle()
        #expect(other.delivery(forMessage: m2.id)?.state == .expired && agent.reads.count == reads + 1)
    }

    @Test func sendAgainIsOfferedOnlyForNotSentExpiredAndCancelledWithAReason() async {
        let conversation = Fx.conversation()
        let states: [(AgentDelivery, Bool)] = [
            (AgentDelivery(state: .notSent), true), (AgentDelivery(state: .notSent, reason: .usageLimited), true), (AgentDelivery(state: .expired), true),
            (AgentDelivery(state: .cancelled), true), (AgentDelivery(state: .notSent, reason: .sessionClosed), false), (AgentDelivery(state: .sent), false),
            (AgentDelivery(state: .queued), false), (AgentDelivery(state: .accepted), false), (AgentDelivery(state: .outcomeUnknown), false),
            (AgentDelivery(state: .answered), false), (AgentDelivery(state: .needsReferent), false), (AgentDelivery(state: .unknown("x")), false),
        ]
        let messages = states.indices.map { Fx.user($0 + 1, in: conversation.id, seq: $0 + 1) }
        serve { _ in states.indices.map { Fx.entry(messages[$0], states[$0].0) } }
        let chat = store()
        await open(conversation, messages: messages, chat: chat)
        for (index, expected) in states.map(\.1).enumerated() {
            #expect(chat.canSendAgain(messages[index].id, in: conversation.id) == expected, "\(states[index].0.state.raw) \(states[index].0.reason?.raw ?? "-")")
        }
    }

    // MARK: cancelled의 Send again = 새 메시지 (D4a-07)

    @Test func aCancelledMessageIsSentAgainAsANewMessageWithTheSameTextAndChips() async {
        let local = store()
        let id = local.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: Fx.connection), excluding: [])
        let chip = ChatAttachment(kind: .action, id: chipAction, origin: .added)
        let auto = ChatAttachment(kind: .context, id: UUID(), origin: .auto)
        let seq = Mutex2(0)
        assistant.postAgentHandler = { conversation, cmid, text in
            seq.value += 1
            return AgentPostedMessage(message: Chats.message(seq.value, in: conversation, seq: seq.value, role: .user, text: text, cmid: cmid, at: Double(seq.value)), delivery: AgentDelivery(state: .sent))
        }
        await local.send("Fix the table", in: id, attachments: [chip, auto])
        let original = local.turns(for: id)[0]
        // 서버가 그 메시지를 cancelled로 읽어 준다
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [ConversationDeliveryResponse.Entry(messageID: original.id, seq: 1, delivery: AgentDelivery(state: .cancelled))]) }
        await local.refreshDeliveries(id)
        #expect(local.delivery(forMessage: original.id)?.state == .cancelled && local.canSendAgain(original.id, in: id))
        local.setDraft("my own draft", for: id)
        await local.sendAgain(original.id, in: id)
        let posts = assistant.calls(prefix: "postAgent")
        #expect(posts.count == 2 && posts[0] != posts[1], "새 client_message_id")
        #expect(assistant.sentAttachments == [[chip, auto], [chip, auto]], "같은 칩")
        #expect(agent.delivers.isEmpty, "deliver가 아니다: 새 메시지를 만든다")
        let turns = local.turns(for: id)
        #expect(turns.map(\.text) == ["Fix the table", "Fix the table"], "원래 줄은 그대로 있고 새 메시지가 더해진다")
        #expect(turns[0].id == original.id && local.delivery(forMessage: original.id)?.state == .cancelled, "원래 줄은 그대로")
        #expect(turns[1].delivery?.state == .sent)
        #expect(local.draft(for: id) == "my own draft", "쓰던 글을 지우지 않는다")
    }

    @Test func pressingSendAgainOnACancelledMessageTwiceSendsOnce() async {
        let local = store()
        let id = local.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: Fx.connection), excluding: [])
        let n = Mutex2(0)
        let latch = Latch()
        assistant.postAgentHandler = { conversation, cmid, text in
            n.value += 1
            if n.value == 2 { await latch.wait() }
            return AgentPostedMessage(message: Chats.message(n.value, in: conversation, seq: n.value, role: .user, text: text, cmid: cmid, at: Double(n.value)), delivery: AgentDelivery(state: .sent))
        }
        await local.send("Fix", in: id)
        let original = local.turns(for: id)[0]
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [ConversationDeliveryResponse.Entry(messageID: original.id, seq: 1, delivery: AgentDelivery(state: .cancelled))]) }
        await local.refreshDeliveries(id)
        async let first: Void = local.sendAgain(original.id, in: id)
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        await local.sendAgain(original.id, in: id)
        await latch.open()
        await first
        #expect(assistant.calls(prefix: "postAgent").count == 2, "처음 보내기 + 다시 보내기 하나")
    }

    /// 앱을 다시 켜면 서버가 칩을 읽게 주지 않는다 (`selected`는 서버 전용 열). cancelled를 다시 보내려는데 원래 칩을 모르면 **보내지 않는다**:
    /// 칩 없이 새 메시지를 만들면 지정했던 이슈 대신 다른 이슈에서 실행될 수 있다 (D4a-07). not_sent · expired는 서버 id로 deliver라 칩이 그대로다
    @Test func aCancelledMessageAfterARestartIsNotSentAgainWithoutItsOriginalChips() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .cancelled))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(message: Chats.message(9, in: conversation, seq: 2, role: .user, text: text, cmid: cmid, at: 2), delivery: AgentDelivery(state: .sent))
        }
        await chat.sendAgain(message.id, in: conversation.id)
        #expect(assistant.calls(prefix: "postAgent").isEmpty && agent.delivers.isEmpty, "원래 칩을 모르면 새 메시지를 만들지 않는다")
        let turn = chat.turns(for: conversation.id)[0]
        guard case .failed = turn.status else {
            Issue.record("기존 오류 줄 + Try again이어야 한다: \(turn.status)")
            return
        }
        #expect(turn.status.canRetry && turn.delivery?.state == .cancelled, "줄은 그대로 두고 오류를 보인다")
        // Try again을 눌러도 같다 (칩을 되살릴 길이 없다)
        await chat.retryDelivery(message.id, in: conversation.id)
        #expect(assistant.calls(prefix: "postAgent").isEmpty)
        #expect(chat.turns(for: conversation.id)[0].status.canRetry)
    }

    /// "모른다"와 "칩이 없었다"는 다르다: 이번 실행에서 칩 없이 보낸 글은 칩이 없다는 것을 안다 → 칩 없이 다시 보낸다
    @Test func aCancelledMessageSentWithoutChipsThisRunIsSentAgainWithoutChips() async {
        let local = store()
        let id = local.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: Fx.connection), excluding: [])
        let seq = Mutex2(0)
        assistant.postAgentHandler = { conversation, cmid, text in
            seq.value += 1
            return AgentPostedMessage(message: Chats.message(seq.value, in: conversation, seq: seq.value, role: .user, text: text, cmid: cmid, at: Double(seq.value)), delivery: AgentDelivery(state: .sent))
        }
        await local.send("Fix the table", in: id)
        let original = local.turns(for: id)[0]
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [ConversationDeliveryResponse.Entry(messageID: original.id, seq: 1, delivery: AgentDelivery(state: .cancelled))]) }
        await local.refreshDeliveries(id)
        await local.sendAgain(original.id, in: id)
        #expect(assistant.calls(prefix: "postAgent").count == 2 && assistant.sentAttachments == [[], []], "칩이 없었음을 안다")
    }

    // MARK: Send again · 후보 고르기의 거절 (동의 · 오류)

    private var consentRefusal: APIError { APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage) }

    /// 동의 철회 뒤 Send again이 409로 거절되면 기존 Chat의 동의 안내가 뜬다. 뒤따르는 전달 읽기가 성공해도 가려지지 않는다 (읽기와 별개)
    @Test func aConsentRefusalOnSendAgainShowsTheConsentNoticeAndALaterReadDoesNotHideIt() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent, reason: .writeGateClosed))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let refusal = consentRefusal
        agent.deliverHandler = { _, _ in throw refusal }
        await chat.sendAgain(message.id, in: conversation.id)
        await chat.settle()
        #expect(chat.needsConsent(in: conversation.id), "기존 동의 안내 (Allow AI processing to continue)")
        #expect(chat.turns(for: conversation.id)[0].status == .needsConsent)
        #expect(chat.delivery(forMessage: message.id)?.state == .notSent, "전달 표시는 그대로")
        await chat.refreshDeliveries(conversation.id)
        #expect(chat.needsConsent(in: conversation.id) && chat.turns(for: conversation.id)[0].status == .needsConsent, "읽기가 성공해도 거절을 지우지 않는다")
        // 동의한 뒤 Try again: 같은 Send again을 다시 보낸다
        agent.deliverHandler = { _, ids in
            AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .queued, reason: .sessionBusy))])
        }
        await chat.retryDelivery(message.id, in: conversation.id)
        #expect(agent.delivers.count == 2 && !chat.needsConsent(in: conversation.id) && chat.turns(for: conversation.id)[0].status == .sent)
        #expect(chat.delivery(forMessage: message.id) == AgentDelivery(state: .queued, reason: .sessionBusy))
    }

    @Test func otherSendAgainFailuresShowTheExistingErrorLineAndStayAfterTheRead() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .expired))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let refusal = APIError.server(status: 409, code: .targetMismatch, message: "x")
        agent.deliverHandler = { _, _ in throw refusal }
        await chat.sendAgain(message.id, in: conversation.id)
        await chat.settle()
        #expect(chat.turns(for: conversation.id)[0].status == .failed(ReadFailure.userMessage(refusal)), "서버가 거절했다: 기존 오류 줄")
        #expect(!chat.needsConsent(in: conversation.id))
        // 기능 꺼짐은 기존 "Chats aren't available yet" 안내로 (서버가 꺼져 있으면 읽기도 404다)
        let off = APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
        agent.deliverHandler = { _, _ in throw off }
        agent.deliveriesHandler = { _, _ in throw off }
        await chat.retryDelivery(message.id, in: conversation.id)
        #expect(chat.isUnavailable && chat.turns(for: conversation.id)[0].status == .failed(ChatCopy.unavailable))
    }

    @Test func aRefusedCandidateChoiceKeepsItsErrorAndTryAgainPicksTheSameCandidate() async {
        let candidate = AgentReferentCandidate(actionID: chipAction, title: "가격 문구")
        let (conversation, message) = serveOne(AgentDelivery(state: .needsReferent, candidates: [candidate]))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let refusal = consentRefusal
        agent.referentHandler = { _, _, _ in throw refusal }
        await chat.chooseReferent(chipAction, for: message.id, in: conversation.id)
        await chat.settle()
        #expect(chat.needsConsent(in: conversation.id) && chat.turns(for: conversation.id)[0].status == .needsConsent, "후보 고르기의 거절도 같은 안내")
        #expect(chat.delivery(forMessage: message.id)?.state == .needsReferent, "후보는 그대로")
        agent.referentHandler = { conversation, _, _ in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: "t", cmid: UUID(), at: 1), delivery: AgentDelivery(state: .sent))
        }
        await chat.retryDelivery(message.id, in: conversation.id)
        #expect(agent.referents.map(\.action) == [chipAction, chipAction] && chat.turns(for: conversation.id)[0].status == .sent)
        #expect(chat.delivery(forMessage: message.id)?.state == .sent)
    }

    @Test func aTryAgainWhoseMessageChangedMeanwhileSendsNothingAndClearsTheError() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let refusal = consentRefusal
        agent.deliverHandler = { _, _ in throw refusal }
        await chat.sendAgain(message.id, in: conversation.id)
        #expect(chat.needsConsent(in: conversation.id))
        // 다른 기기에서 이미 처리됐다: 서버가 사실이다
        serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
        await chat.refreshDeliveries(conversation.id)
        let before = agent.delivers.count
        await chat.retryDelivery(message.id, in: conversation.id)
        #expect(agent.delivers.count == before && !chat.needsConsent(in: conversation.id) && line(chat, message) == .accepted)
    }

    // MARK: 거절 안내는 같은 미전달 상태일 때만 (U2 12.1: 새로 읽은 서버 값이 이긴다)

    /// 요청은 서버에 닿았는데 응답을 못 받아 오류 안내가 남았다. 서버가 전달이 진전했다고(sent · accepted …) 새로 읽어 알려 주면 안내는 사라진다.
    /// 같은 미전달 상태(notSent)로 읽히는 동안에는 안내가 남는다
    @Test func aRefusalNoticeIsDroppedAsSoonAsAFreshReadShowsTheDeliveryProgressed() async {
        for progressed in [AgentDeliveryState.sent, .accepted] {
            let (conversation, message) = serveOne(AgentDelivery(state: .notSent, reason: .writeGateClosed))
            let chat = store()
            await open(conversation, messages: [message], chat: chat)
            agent.deliverHandler = { _, _ in throw APIError.transport("response lost") }
            await chat.sendAgain(message.id, in: conversation.id)
            await chat.settle()
            guard case .failed = chat.turns(for: conversation.id)[0].status else {
                Issue.record("서버가 아직 notSent로 읽히는 동안은 오류 줄이 남는다")
                return
            }
            // 사실은 서버가 받았다
            serve { _ in [Fx.entry(message, AgentDelivery(state: progressed))] }
            await chat.refreshDeliveries(conversation.id)
            let turn = chat.turns(for: conversation.id)[0]
            #expect(turn.status == .sent && turn.delivery?.state == progressed && !chat.needsConsent(in: conversation.id), "\(progressed.raw): 진전을 읽었으면 \"Not sent\"가 남지 않는다")
            #expect(!turn.showsStatusInsteadOfDelivery)
        }
    }

    /// 거절 직후의 내 읽기(`afterMyRequest`)가 이미 진전을 읽어도 같다 (응답 실패 → 바로 읽기 → 진전)
    @Test func theReadRightAfterAFailedRequestAlreadyClearsTheNoticeWhenTheServerProgressed() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        serve { _ in [Fx.entry(message, AgentDelivery(state: .sent))] }
        agent.deliverHandler = { _, _ in throw APIError.transport("response lost") }
        await chat.sendAgain(message.id, in: conversation.id)
        await chat.settle()
        #expect(chat.turns(for: conversation.id)[0].status == .sent && line(chat, message) == .sent)
    }

    @Test func aConsentNoticeAndAReferentNoticeAreDroppedWhenTheServerShowsProgressToo() async {
        // 동의 안내: 다른 기기에서 이미 보냈다
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let refusal = consentRefusal
        agent.deliverHandler = { _, _ in throw refusal }
        await chat.sendAgain(message.id, in: conversation.id)
        #expect(chat.needsConsent(in: conversation.id))
        serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
        await chat.refreshDeliveries(conversation.id)
        #expect(!chat.needsConsent(in: conversation.id) && chat.turns(for: conversation.id)[0].status == .sent)
        // 후보 고르기: 응답은 못 받았지만 서버는 골랐다
        let candidate = AgentReferentCandidate(actionID: chipAction, title: "가격 문구")
        let (c2, m2) = serveOne(AgentDelivery(state: .needsReferent, candidates: [candidate]))
        let other = store()
        await open(c2, messages: [m2], chat: other)
        agent.referentHandler = { _, _, _ in throw APIError.transport("response lost") }
        await other.chooseReferent(chipAction, for: m2.id, in: c2.id)
        await other.settle()
        guard case .failed = other.turns(for: c2.id)[0].status else {
            Issue.record("같은 needs_referent로 읽히는 동안은 오류 줄이 남는다")
            return
        }
        serve { _ in [Fx.entry(m2, AgentDelivery(state: .sent))] }
        await other.refreshDeliveries(c2.id)
        #expect(other.turns(for: c2.id)[0].status == .sent && other.delivery(forMessage: m2.id)?.state == .sent)
    }

    @Test func theBlockedCancelledNoticeStaysWhileCancelledAndGoesWhenTheServerMovesOn() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .cancelled))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        await chat.sendAgain(message.id, in: conversation.id)
        await chat.refreshDeliveries(conversation.id)
        #expect(chat.turns(for: conversation.id)[0].status.canRetry, "같은 cancelled로 읽히면 막힘 안내가 남는다")
        serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
        await chat.refreshDeliveries(conversation.id)
        #expect(chat.turns(for: conversation.id)[0].status == .sent)
    }

    /// 기능 꺼짐 → 복구 → 서버가 accepted를 읽어 줌: 안내만이 아니라 입력을 막던 `isUnavailable`도 풀린다 (복구를 확인한 성공 읽기)
    @Test func aSuccessfulReadAfterTheFeatureWasOffClearsTheUnavailableFlagAndTheComposerComesBack() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let off = APIError.server(status: 404, code: .notFound, message: APIError.featureOffMessage)
        agent.deliverHandler = { _, _ in throw off }
        agent.deliveriesHandler = { _, _ in throw off }
        await chat.sendAgain(message.id, in: conversation.id)
        await chat.settle()
        #expect(chat.isUnavailable && chat.turns(for: conversation.id)[0].status == .failed(ChatCopy.unavailable) && !chat.canCompose(in: conversation.id), "기능 꺼짐: 입력이 막힌다")
        // 읽기가 실패하는 동안은 막힌 채다 (복구를 확인하지 못했다)
        await chat.refreshDeliveries(conversation.id)
        #expect(chat.isUnavailable)
        // 서버가 돌아왔고 다른 기기가 보냈다
        serve { _ in [Fx.entry(message, AgentDelivery(state: .accepted))] }
        await chat.refreshDeliveries(conversation.id)
        #expect(!chat.isUnavailable && chat.canCompose(in: conversation.id), "성공한 읽기가 복구를 확인했다: 입력이 돌아온다")
        #expect(chat.turns(for: conversation.id)[0].status == .sent && line(chat, message) == .accepted)
    }

    // MARK: 읽는 중에 필요해진 후속 읽기

    /// `skipped/not_eligible`로 서버가 이미 바뀐 것을 안 직후의 읽기는 옛 읽기에 흡수되면 안 된다: 읽는 중이어도 끝난 뒤 한 번 더 읽는다
    @Test func aFollowUpReadAskedWhileAnOlderReadIsInFlightRunsAfterIt() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let latch = Latch()
        let calls = Mutex2(0)
        agent.deliveriesHandler = { _, _ in
            calls.value += 1
            if calls.value == 1 {
                await latch.wait()
                return ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .notSent))])
            }
            return ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .accepted))])
        }
        let stale = Task { await chat.refreshDeliveries(conversation.id) }
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        agent.deliverHandler = { _, ids in AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .skipped, skippedReason: .notEligible)]) }
        await chat.sendAgain(message.id, in: conversation.id)
        #expect(agent.reads.count == 2, "읽는 중에는 새 요청을 겹쳐 보내지 않는다")
        await latch.open()
        await stale.value
        await chat.settle()
        #expect(line(chat, message) == .accepted && agent.reads.count == 3, "옛 읽기가 끝난 뒤 후속 읽기가 서버 값을 가져온다")
    }

    // MARK: 턴이 시작될 수 있는 입구

    @Test func everyEntryThatMayStartATurnTellsTheOutsideToReadTheSessionAgain() async {
        let (conversation, message) = serveOne(AgentDelivery(state: .notSent))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let started = Mutex2(0)
        chat.onAgentTurnMayStart = { started.value += 1 }
        // 보내기
        let seq = Mutex2(1)
        assistant.postAgentHandler = { conversation, cmid, text in
            seq.value += 1
            return AgentPostedMessage(message: Chats.message(seq.value, in: conversation, seq: seq.value, role: .user, text: text, cmid: cmid, at: Double(seq.value)), delivery: AgentDelivery(state: .sent))
        }
        await chat.send("Fix the table", in: conversation.id)
        #expect(started.value == 1, "보내기")
        // 실패한 Send again은 턴을 시작하지 않았다
        let refusal = consentRefusal
        agent.deliverHandler = { _, _ in throw refusal }
        await chat.sendAgain(message.id, in: conversation.id)
        #expect(started.value == 1, "거절된 요청은 턴을 시작하지 않는다")
        // 성공한 Send again(requeued)
        agent.deliverHandler = { _, ids in AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .sent))]) }
        await chat.retryDelivery(message.id, in: conversation.id)
        #expect(started.value == 2, "Send again")
        // 후보 고르기
        let candidate = AgentReferentCandidate(actionID: chipAction, title: "가격 문구")
        let (c2, m2) = serveOne(AgentDelivery(state: .needsReferent, candidates: [candidate]))
        let other = store()
        await open(c2, messages: [m2], chat: other)
        other.onAgentTurnMayStart = { started.value += 1 }
        agent.referentHandler = { conversation, _, _ in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: "t", cmid: UUID(), at: 1), delivery: AgentDelivery(state: .sent))
        }
        await other.chooseReferent(chipAction, for: m2.id, in: c2.id)
        #expect(started.value == 3, "후보 고르기")
    }

    // MARK: 후보 고르기 (referent)

    @Test func choosingACandidatePostsItAndTakesTheNewLine() async {
        let candidate = AgentReferentCandidate(actionID: chipAction, title: "가격 문구")
        let (conversation, message) = serveOne(AgentDelivery(state: .needsReferent, candidates: [candidate]))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let latch = Latch()
        agent.referentHandler = { conversation, _, _ in
            await latch.wait()
            return AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: "t", cmid: UUID(), at: 1), delivery: AgentDelivery(state: .sent))
        }
        async let first: Void = chat.chooseReferent(chipAction, for: message.id, in: conversation.id)
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        async let second: Void = chat.chooseReferent(chipAction, for: message.id, in: conversation.id)
        #expect(await noSecondRequest(latch), "두 번째 누름은 서버에 가지 않는다")
        await latch.open()
        _ = await (first, second)
        #expect(agent.referents == [.init(conversation: conversation.id, message: message.id, action: chipAction)], "두 번 눌러도 요청은 하나")
        #expect(chat.delivery(forMessage: message.id)?.state == .sent)
    }

    @Test func aFailedReferentReadsAgainAndLeavesTheLine() async {
        let candidate = AgentReferentCandidate(actionID: chipAction, title: "가격 문구")
        let (conversation, message) = serveOne(AgentDelivery(state: .needsReferent, candidates: [candidate]))
        let chat = store()
        await open(conversation, messages: [message], chat: chat)
        let reads = agent.reads.count
        agent.referentHandler = { _, _, _ in throw APIError.server(status: 409, code: .busyRetry, message: "x") }
        await chat.chooseReferent(chipAction, for: message.id, in: conversation.id)
        await chat.settle()
        #expect(chat.delivery(forMessage: message.id)?.state == .needsReferent && agent.reads.count == reads + 1, "다시 읽는다")
    }
}

/// 값 하나를 스레드 사이에 주고받는 작은 상자 (시험 가짜의 응답을 중간에 바꾼다)
final class Mutex2<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
