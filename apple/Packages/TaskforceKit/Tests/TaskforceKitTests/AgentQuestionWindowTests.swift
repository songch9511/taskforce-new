import Foundation
import Testing
@testable import TaskforceKit

/// Assistant 창 · 세션 패널이 질문 저장소와 만나는 곳 (OA D4b-m-1): 비밀값 질문이 열린 대화의 입력 막기(D4bm-42), 대화 열쇠로 접힌 줄 치우기(D4bm-25),
/// 질문 곁에서 대기열에 든 글 세기(D4bm-31), 세션 저장소가 읽을 때 질문 읽기를 거는 끈
@MainActor
struct AgentQuestionWindowTests {
    typealias F = AgentQuestionFixtures
    typealias Fx = AgentFx

    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let questions = FakeAgentQuestionGateway()
    let scope = ChatTestAccount.fixedScope()

    struct Rig {
        let model: AssistantWindowModel
        let chat: ChatStore
        let store: AgentQuestionStore
        let conversation: ChatConversation
    }

    func rig(messages: [ChatMessage] = []) async -> Rig {
        let conversation = Fx.conversation(session: F.sessionID)
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in messages }
        gateway.lastMessagesHandler = { _ in [:] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        let connection = Fx.connection
        assistant.targetsHandler = { [.taskforce, .agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: connection, state: .ready, access: .write))] }
        let targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true })
        await targets.refresh()
        let model = AssistantWindowModel(conversationID: conversation.id, chat: chat, targets: targets)
        let store = AgentQuestionStore(gateway: questions, scope: scope)
        store.thisMacBridgeID = F.bridgeID
        model.questions = store
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        await chat.settle()
        return Rig(model: model, chat: chat, store: store, conversation: conversation)
    }

    func ask(_ r: Rig, _ json: String) async {
        questions.records = [QFx.record(json)]
        r.store.sessionsRead([QFx.item(conversation: r.conversation.id)])
        await r.store.settle()
    }

    // MARK: 입력 막기

    @Test func aSecretQuestionBlocksThisConversationsComposerWithTheStandardWords() async {
        let r = await rig()
        #expect(!r.model.isBlocked && r.model.placeholder == "Message Claude Code")
        await ask(r, F.secret)
        #expect(r.model.isBlocked && r.model.blockedReason == "" && r.model.placeholder == "Answer the question above first")
        #expect(!r.model.canSend("hello"), "자유 글이 비밀값의 답이 되는 길이 없다: 보내기 원은 조용히 아무 일도 하지 않는다")
        #expect(!r.model.isPristine)
    }

    @Test func aSecretQuestionOnAnotherDeviceBlocksToo() async {
        let r = await rig()
        questions.records = [QFx.record(F.secret)]
        r.store.sessionsRead([QFx.item(conversation: r.conversation.id, bridge: F.otherBridgeID)])
        await r.store.settle()
        #expect(r.model.isBlocked, "다른 기기의 카드를 보는 대화도 일반 보내기로 비밀값을 보낼 수 없다")
    }

    @Test func anOrdinaryQuestionDoesNotBlockTheComposer() async {
        let r = await rig()
        await ask(r, F.single)
        #expect(!r.model.isBlocked && r.model.canSend("hello") && r.model.placeholder == "Message Claude Code")
    }

    @Test func theBlockLiftsWhenTheQuestionIsGone() async {
        let r = await rig()
        await ask(r, F.secret)
        #expect(r.model.isBlocked)
        questions.records = []
        r.store.sessionsRead([QFx.item(conversation: r.conversation.id, state: .running)])
        await r.store.settle()
        #expect(!r.model.isBlocked && r.model.canSend("hello"), "풀리지 않는 막힘은 없다")
    }

    @Test func aDifferentConversationIsNotBlocked() async {
        let r = await rig()
        await ask(r, F.secret)
        let otherChat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        let other = AssistantWindowModel(conversationID: otherChat.reserveNewChat(target: .taskforce, excluding: []), chat: otherChat, targets: AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true }))
        other.questions = r.store
        #expect(!other.isBlocked, "Taskforce 대화 · 다른 세션의 대화는 막지 않는다")
    }

    @Test func anExplicitBlockReasonStillWinsOverTheQuestion() async {
        let r = await rig()
        await ask(r, F.single)
        r.model.blocked = "Some other reason"
        #expect(r.model.isBlocked && r.model.placeholder == "Some other reason")
    }

    // MARK: 대화 열쇠 · 대기열 수

    @Test func eventKeysAreTheServerKeysOfTheMessagesInTheConversation() async {
        let conversation = Fx.conversation(session: F.sessionID)
        let event = ChatMessage(
            id: UUID(), conversationID: conversation.id, seq: 2, role: .event, text: "Answered", createdAt: .test(2),
            externalEventID: AgentQuestionStore.sentEventKey(F.key())
        )
        let user = Fx.user(1, in: conversation.id, seq: 1)
        let r = await rig(messages: [user, event])
        #expect(r.chat.eventKeys(in: r.conversation.id) == [AgentQuestionStore.sentEventKey(F.key())])
        #expect(r.chat.eventKeys(in: UUID()).isEmpty)
    }

    @Test func theCardKnowsHowManyMessagesQueuedBehindIt() async {
        let conversation = Fx.conversation(session: F.sessionID)
        let first = Fx.user(1, in: conversation.id, seq: 1)
        let second = Fx.user(2, in: conversation.id, seq: 2)
        let busy = Fx.user(3, in: conversation.id, seq: 3)
        let agent = FakeAgentConversationGateway()
        agent.deliveriesHandler = { _, _ in
            ConversationDeliveryResponse(messages: [
                Fx.entry(first, AgentDelivery(state: .queued, reason: .questionOpen)), Fx.entry(second, AgentDelivery(state: .queued, reason: .questionOpen)),
                Fx.entry(busy, AgentDelivery(state: .queued, reason: .sessionBusy)),
            ])
        }
        let r = await rig(messages: [first, second, busy])
        r.chat.agentConversation = agent
        await r.chat.refreshDeliveries(conversation.id)
        #expect(AgentQuestionRules.queuedBehindQuestion(r.chat.turns(for: conversation.id)) == 2, "question_open만 센다 (다른 이유로 기다리는 글은 아니다)")
        #expect(AgentQuestionRules.queuedBehindQuestion([]) == 0)
    }

    // MARK: 세션 저장소가 읽을 때

    @Test func theSessionStoreTellsTheQuestionStoreWhatItReadAndNotWhenOnlyTheDoneHoldExpires() async {
        let sessions = FakeAgentSessionGateway()
        sessions.serve(SessionFx.snapshot(state: .awaitingAnswer))
        let store = AgentSessionStore(gateway: sessions, scope: scope)
        var seen: [[AgentSessionItem]] = []
        store.onApplied = { seen.append($0) }
        await store.refresh()
        #expect(seen.count == 1 && seen[0].first?.lastTaskState == .awaitingAnswer && seen[0].first?.ring == .needsYou)
        store.rebuild()
        #expect(seen.count == 1, "Done 만료로 항목만 다시 정할 때는 알리지 않는다")
        sessions.fail(FakeAgentSessionGateway.Failure())
        await store.refresh()
        #expect(seen.count == 1, "읽기가 실패하면 알릴 새 값이 없다")
    }
}
