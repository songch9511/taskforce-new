import Foundation
import Testing
@testable import TaskforceKit

/// Assistant 창의 에이전트 대화 (OA D4a-1): 전달 줄 · Send again · 후보 고르기 메뉴 · Stop · 세션 읽기 · View full. 창 하나의 상태가 서버 값을 화면 말로 옮긴다
@MainActor
struct AssistantAgentWindowTests {
    typealias Fx = AgentFx
    typealias SFx = SessionFx

    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let agent = FakeAgentConversationGateway()
    let sessionGateway = FakeAgentSessionGateway()
    let scope = ChatTestAccount.fixedScope()
    let codex = Fx.connection
    let action = UUID(uuidString: "c1000000-0000-4000-8000-000000000001")!

    struct Rig {
        let model: AssistantWindowModel
        let chat: ChatStore
        let targets: AssistantTargetsStore
        let stop: AgentStopStore
        let sessions: AgentSessionStore
        let conversation: ChatConversation
    }

    func rig(session: UUID? = SFx.id(1), targetState: AgentTargetState = .ready, messages: [ChatMessage] = []) async -> Rig {
        let conversation = Fx.conversation(session: session)
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { _ in messages }
        gateway.lastMessagesHandler = { _ in [:] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        chat.agentConversation = agent
        let connection = codex
        assistant.targetsHandler = {
            [.taskforce, .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: connection, state: targetState, access: .write))]
        }
        let targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true })
        await targets.refresh()
        let sessions = AgentSessionStore(gateway: sessionGateway, scope: scope, focus: { chat.viewedAgentSessionIDs() })
        let stop = AgentStopStore(conversations: agent, sessions: nil, scope: scope)
        let model = AssistantWindowModel(conversationID: conversation.id, chat: chat, targets: targets)
        model.agent = AssistantAgentSupport(stop: stop, sessions: sessions)
        chat.viewedConversations = { [conversation.id] }
        await chat.refresh()
        await chat.settle()
        return Rig(model: model, chat: chat, targets: targets, stop: stop, sessions: sessions, conversation: conversation)
    }

    func turn(_ r: Rig, _ message: ChatMessage) -> ChatTurn { r.chat.turns(for: r.conversation.id).first { $0.id == message.id }! }

    // MARK: 전달 줄에 쓰는 사실

    @Test func theDeliveryLineKnowsTheAgentNameAndTheConnectionsTargetState() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .queued))]) }
        let offline = await rig(targetState: .unreachable, messages: [message])
        let queued = offline.model.deliveryLine(for: turn(offline, message))
        #expect(queued?.combined == "Queued · Mac is offline", "연결의 대상 상태가 unreachable이고 이유가 없다")
        let ready = await rig(targetState: .ready, messages: [message])
        #expect(ready.model.deliveryLine(for: turn(ready, message))?.combined == "Queued")
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .notSent, reason: .signInNeeded))]) }
        let signedOut = await rig(messages: [message])
        #expect(signedOut.model.deliveryLine(for: turn(signedOut, message))?.combined == "Not sent · Not signed in to Codex")
    }

    @Test func aTurnWithoutADeliveryHasNoLineAndTaskforceTurnsNeverDo() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let r = await rig(messages: [message])
        #expect(r.model.deliveryLine(for: turn(r, message)) == nil, "읽기 전에는 그리지 않는다")
    }

    // MARK: Send again · 후보 고르기

    @Test func theLinkActionsGoToTheChatStoreByServerMessageID() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .notSent, reason: .writeGateClosed))]) }
        agent.deliverHandler = { _, ids in AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .queued))]) }
        let r = await rig(messages: [message])
        #expect(r.model.canSendAgain(turn(r, message)))
        await r.model.sendAgain(turn(r, message))
        #expect(agent.delivers == [.init(conversation: r.conversation.id, messageIDs: [message.id])])
        #expect(!r.model.canSendAgain(turn(r, message)), "queued가 됐다")
    }

    /// 거절된 Send again은 전달 줄 대신 기존 상태 줄(동의 안내 · 오류 + Try again)로 보이고, Try again이 창에서 같은 요청을 다시 보낸다
    @Test func aRefusedSendAgainShowsTheStatusLineInsteadOfTheDeliveryLineAndTryAgainResendsIt() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .notSent, reason: .writeGateClosed))]) }
        let refusal = APIError.server(status: 409, code: .conflict, message: APIError.consentRequiredMessage)
        agent.deliverHandler = { _, _ in throw refusal }
        let r = await rig(messages: [message])
        #expect(!turn(r, message).showsStatusLine, "처음에는 전달 줄")
        await r.model.sendAgain(turn(r, message))
        let refused = turn(r, message)
        #expect(refused.status == .needsConsent && refused.showsStatusLine && refused.delivery?.state == .notSent)
        agent.deliverHandler = { _, ids in AgentDeliverResponse(messages: [AgentDeliverResult(messageID: ids![0], result: .requeued, delivery: AgentDelivery(state: .queued))]) }
        await r.model.retryDelivery(refused)
        #expect(agent.delivers.count == 2 && !turn(r, message).showsStatusLine, "다시 보내져 전달 줄로 돌아왔다")
    }

    /// 거절된 후보 고르기: 창의 Try again이 지금 후보 목록으로 메뉴를 다시 열고, 다른 후보를 고를 수 있다
    @Test func tryAgainAfterARefusedCandidateChoiceReopensTheMenuWithTheCurrentCandidates() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let a = AgentReferentCandidate(actionID: action, title: "가격 문구")
        let b = AgentReferentCandidate(actionID: UUID(), title: "온보딩")
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: [a, b]))]) }
        let missing = APIError.server(status: 404, code: .notFound, message: "No such issue")
        agent.referentHandler = { conversation, _, id in
            if id == a.actionID { throw missing }
            return AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: "t", cmid: UUID(), at: 1), delivery: AgentDelivery(state: .sent))
        }
        let r = await rig(messages: [message])
        r.model.openReferentMenu(for: message.id)
        await r.model.chooseReferent(a.actionID)
        #expect(r.model.referentMenu == nil && turn(r, message).showsStatusLine && turn(r, message).showsDeliveryLine, "메뉴는 닫혔고 오류 줄 옆에 전달 줄(고르기 링크)이 있다")
        // 서버가 새로 알려 준 후보: A는 지워졌다
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: [b]))]) }
        await r.chat.refreshDeliveries(r.conversation.id)
        await r.model.retryDelivery(turn(r, message))
        #expect(r.model.referentMenu?.candidates == [b], "Try again은 지금 후보로 메뉴를 다시 연다")
        #expect(agent.referents.map(\.action) == [a.actionID], "낡은 선택을 다시 보내지 않았다")
        await r.model.chooseReferent(b.actionID)
        #expect(agent.referents.map(\.action) == [a.actionID, b.actionID] && turn(r, message).delivery?.state == .sent && !turn(r, message).showsStatusLine)
    }

    /// 서버가 후보를 바꾼 뒤 바로 Try again을 눌러도(그 사이 읽지 않았어도) 메뉴는 지금 후보로 열린다: Try again이 먼저 서버 값을 읽는다
    @Test func tryAgainReadsTheCurrentCandidatesBeforeReopeningTheMenu() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let a = AgentReferentCandidate(actionID: action, title: "가격 문구")
        let b = AgentReferentCandidate(actionID: UUID(), title: "온보딩")
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: [a, b]))]) }
        agent.referentHandler = { _, _, _ in throw APIError.server(status: 409, code: .conflict, message: "issue is done") }
        let r = await rig(messages: [message])
        r.model.openReferentMenu(for: message.id)
        await r.model.chooseReferent(a.actionID)
        await r.chat.settle()
        // 그 뒤 서버가 후보를 줄였다 (읽지 않은 채 Try again)
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: [b]))]) }
        await r.model.retryDelivery(turn(r, message))
        #expect(r.model.referentMenu?.candidates == [b])
    }

    @Test func theDeliveryLineStaysNextToTheErrorOnlyWhileTheChoiceIsStillOpen() {
        func make(_ status: ChatTurn.Status, _ delivery: AgentDelivery?) -> ChatTurn {
            ChatTurn(id: UUID(), isUser: true, text: "t", createdAt: .test(1), status: status, clientMessageID: UUID(), delivery: delivery)
        }
        let candidates = [AgentReferentCandidate(actionID: UUID(), title: "x")]
        #expect(make(.sent, AgentDelivery(state: .queued)).showsDeliveryLine && !make(.sent, AgentDelivery(state: .queued)).showsStatusLine)
        #expect(make(.failed("x"), AgentDelivery(state: .needsReferent, candidates: candidates)).showsDeliveryLine, "고르기가 열려 있으면 오류 옆에 링크가 남는다")
        #expect(make(.needsConsent, AgentDelivery(state: .needsReferent, candidates: candidates)).showsStatusLine)
        #expect(!make(.failed("x"), AgentDelivery(state: .notSent)).showsDeliveryLine, "Send again 오류는 전달 줄을 대신한다")
        #expect(!make(.sending, nil).showsDeliveryLine && make(.sending, nil).showsStatusLine)
    }

    @Test func theStatusLineShowsInsteadOfTheDeliveryLineOnlyForAnUnreadOrRetryableTurn() {
        func make(_ status: ChatTurn.Status, delivery: AgentDelivery?) -> ChatTurn {
            ChatTurn(id: UUID(), isUser: true, text: "t", createdAt: .test(1), status: status, clientMessageID: UUID(), delivery: delivery)
        }
        #expect(make(.sending, delivery: nil).showsStatusLine, "아직 전달 표시를 모른다")
        #expect(make(.failed("x"), delivery: nil).showsStatusLine)
        #expect(!make(.sent, delivery: AgentDelivery(state: .queued)).showsStatusLine)
        #expect(make(.needsConsent, delivery: AgentDelivery(state: .notSent)).showsStatusLine)
        #expect(make(.failed("x"), delivery: AgentDelivery(state: .expired)).showsStatusLine)
    }

    @Test func theReferentMenuListsTheCandidatesPicksOneAndClosesWithEscape() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        let candidates = [AgentReferentCandidate(actionID: action, title: "가격 문구"), AgentReferentCandidate(actionID: UUID(), title: "온보딩")]
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .needsReferent, candidates: candidates))]) }
        agent.referentHandler = { conversation, _, _ in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: "t", cmid: UUID(), at: 1), delivery: AgentDelivery(state: .sent))
        }
        let r = await rig(messages: [message])
        #expect(r.model.referentMenu == nil)
        r.model.openReferentMenu(for: message.id)
        #expect(r.model.referentMenu?.messageID == message.id && r.model.referentMenu?.candidates == candidates)
        // Esc는 메뉴부터 닫는다 (History · 창 숨김보다 먼저)
        #expect(r.model.escapeInner())
        #expect(r.model.referentMenu == nil && r.model.mode == .chat)
        r.model.openReferentMenu(for: message.id)
        await r.model.chooseReferent(action)
        #expect(agent.referents == [.init(conversation: r.conversation.id, message: message.id, action: action)])
        #expect(r.model.referentMenu == nil, "고르면 메뉴가 닫힌다")
        #expect(r.chat.delivery(forMessage: message.id)?.state == .sent)
    }

    @Test func aReferentMenuOnlyOpensForAMessageThatNeedsOne() async {
        let conversation = Fx.conversation()
        let message = Fx.user(1, in: conversation.id, seq: 1)
        agent.deliveriesHandler = { _, _ in ConversationDeliveryResponse(messages: [Fx.entry(message, AgentDelivery(state: .queued))]) }
        let r = await rig(messages: [message])
        r.model.openReferentMenu(for: message.id)
        #expect(r.model.referentMenu == nil)
        r.model.openReferentMenu(for: UUID())
        #expect(r.model.referentMenu == nil)
    }

    // MARK: Stop

    @Test func theCircleIsStopWhileTheConversationsSessionHasAnOpenTaskAndNothingElseWasRead() async {
        let r = await rig()
        #expect(!r.model.stopPresentation.showsStop, "세션을 아직 읽지 않았다")
        sessionGateway.serve(SFx.snapshot(state: .running))
        await r.sessions.refresh()
        #expect(sessionGateway.reads == 0 && sessionGateway.narrowReads == [[SFx.id(1)]], "열린 대화의 세션만 좁게")
        #expect(r.model.stopPresentation == AgentStopRules.Presentation(showsStop: true, line: nil))
        sessionGateway.serve(SFx.snapshot(state: .idle))
        await r.sessions.refresh()
        #expect(!r.model.stopPresentation.showsStop && r.model.sessionItem?.lastTaskState == .idle)
    }

    @Test func stoppingPostsTheConversationRouteOnceAndShowsStopRequested() async {
        let r = await rig()
        sessionGateway.serve(SFx.snapshot(state: .running))
        await r.sessions.refresh()
        let latch = Latch()
        agent.stopHandler = { _ in
            await latch.wait()
            return AgentStopResponse(tasks: [AgentStopResult(agentTaskID: UUID(), cancel: .requestedOnly)])
        }
        async let first: Void = r.model.stop()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)))
        await r.model.stop()
        await latch.open()
        await first
        #expect(agent.stops == [r.conversation.id], "두 번 눌러도 한 번")
        #expect(r.model.stopPresentation.line == .requested && r.model.stopPresentation.showsStop)
        #expect(r.model.stopLineText == "Stop requested · not confirmed")
    }

    @Test func theMayContinueWordIsTheUnapprovedCandidateAndAbsentBeforeApproval() async {
        let r = await rig()
        sessionGateway.serve(SFx.snapshot(state: .running))
        await r.sessions.refresh()
        agent.stopHandler = { _ in AgentStopResponse(tasks: [AgentStopResult(agentTaskID: UUID(), cancel: .confirmed, processes: .mayContinue)]) }
        await r.model.stop()
        sessionGateway.serve(SFx.snapshot(state: .cancelled))
        await r.sessions.refresh()
        #expect(r.model.stopPresentation == AgentStopRules.Presentation(showsStop: false, line: .mayContinue))
        #expect(r.model.stopLineText(copy: .candidates) == "Stopped · commands may still be running")
        #expect(r.model.stopLineText(copy: .approved) == nil, "승인 전에는 그 말을 쓰지 않는다")
    }

    // MARK: 세션 id

    @Test func theConversationsSessionComesFromItsRowOrFromTheFirstSendsAnswer() async {
        let r = await rig(session: nil)
        #expect(r.chat.agentSessionID(for: r.conversation.id) == nil && r.model.sessionItem == nil)
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(
                message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .sent),
                agentTask: AgentTaskRef(id: UUID(), state: .dispatched, agentSessionID: SFx.id(1))
            )
        }
        await r.chat.send("Go", in: r.conversation.id)
        #expect(r.chat.agentSessionID(for: r.conversation.id) == SFx.id(1), "세션은 첫 전달 때 서버가 만든다: 보낸 응답이 알려 준다")
        #expect(r.chat.viewedAgentSessionIDs() == [SFx.id(1)])
        let withRow = await rig(session: SFx.id(2))
        #expect(withRow.chat.agentSessionID(for: withRow.conversation.id) == SFx.id(2))
        #expect(withRow.chat.viewedAgentSessionIDs() == [SFx.id(2)])
    }

    @Test func aTaskforceConversationHasNoSessionAndNothingIsFocused() async {
        let plain = ChatConversation(id: ChatContractFixtures.id(5, prefix: "bcb50000"), createdAt: .test(), lastMessageAt: .test(5))
        gateway.conversationsHandler = { [plain] }
        gateway.messagesHandler = { _ in [] }
        gateway.lastMessagesHandler = { _ in [:] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.viewedConversations = { [plain.id] }
        await chat.refresh()
        #expect(chat.agentSessionID(for: plain.id) == nil && chat.viewedAgentSessionIDs().isEmpty)
    }
}
