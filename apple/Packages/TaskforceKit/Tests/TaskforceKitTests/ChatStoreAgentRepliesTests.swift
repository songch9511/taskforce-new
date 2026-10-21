import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트의 글은 비동기로 대화에 쓰인다 (Claude Code 첫 실사용: 승인 세 번 뒤 마지막 답이 Mac 대화에 끝내 나오지 않았다).
/// `conversation_messages`는 Realtime 발행 대상이 아니고, 대화 글은 열 때 · 질문에 답할 때 · 목록 읽기 때만 다시 읽었다. 그래서 마지막 답은 서버에 있어도 화면은 모르는 채였다.
/// 세션 읽기(열린 task가 있으면 5초마다)가 반영될 때 그 세션의 보이는 대화 글도 다시 읽는다. 비용을 지키는 규칙 (검토 P2 · P3):
/// 읽는 때 = 세션의 **새 일**(턴 번호 · 마지막 사건 순서 · 상태 · 세션 상태 · 갱신 시각이 앞선 것)이 보였을 때뿐 · 같은 대화는 ~4초 안에 한 번(합친다) ·
/// 전달 표시는 다시 읽지 않는다 · 표식은 읽기가 성공한 뒤에만 적고 실패하면 한 번 늦춰 다시 읽는다 · 두 세션 저장소가 같은 일을 두 번 읽게 하지 않는다
@MainActor
struct ChatStoreAgentRepliesTests {
    typealias Fx = AgentFx
    let gateway = FakeChatGateway()
    let agent = FakeAgentConversationGateway()
    let sessionsGateway = FakeAgentSessionGateway()
    /// 대화 저장소의 시계 · 잠들기 (같은 대화는 4초에 한 번 · 실패 뒤 한 번 다시)
    let chatTicker = ManualTicker()
    let sessionTicker = ManualTicker()
    let clock = Mutex2<Date>(.test(500))
    let scope = ChatTestAccount.fixedScope()
    let session = SessionFx.id(1)
    let failures = Mutex2<Int>(0)
    let hold = Mutex2<Bool>(false)
    let latch = Latch()

    struct Rig {
        let chat: ChatStore
        let sessions: AgentSessionStore
        let conversation: ChatConversation
        let thread: Mutex2<[ChatMessage]>
    }

    /// 앱을 막 켠 것처럼: 에이전트 대화 하나를 읽어 보이게 하고, 세션 저장소를 좁게(보이는 대화의 세션만) 읽도록 붙인다 (`EdgeChat`과 같은 연결)
    func rig() async -> Rig {
        let conversation = Fx.conversation(session: session)
        let question = Fx.user(1, in: conversation.id, seq: 1, text: "Create notes.txt in this folder")
        let thread = Mutex2<[ChatMessage]>([question])
        gateway.conversationsHandler = { [conversation] }
        gateway.messagesHandler = { [failures, hold, latch] _ in
            if hold.value { await latch.wait() }
            if failures.value > 0 {
                failures.value -= 1
                throw FakeChatGateway.Failure()
            }
            return thread.value
        }
        gateway.lastMessagesHandler = { _ in [:] }
        let clock = clock
        let chat = ChatStore(gateway: gateway, scope: scope, now: { clock.value }, sleep: { [chatTicker] in await chatTicker.sleep($0) })
        chat.agentConversation = agent
        chat.viewedConversations = { [conversation.id] }
        let sessions = AgentSessionStore(gateway: sessionsGateway, scope: scope, sleep: { [sessionTicker] in await sessionTicker.sleep($0) }, focus: { [chat] in chat.viewedAgentSessionIDs() })
        sessions.onApplied = { [weak chat] items in chat?.agentSessionsRead(items) }
        await chat.refresh()
        await chat.settle()
        return Rig(chat: chat, sessions: sessions, conversation: conversation, thread: thread)
    }

    func snapshot(_ state: AgentTaskState, turn: Int = 1, seq: Int?, status: AgentSessionStatus = .bound, updated: Double = 0) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            sessions: [SessionFx.session(1, status: status, turn: turn, updated: updated)], tasks: [SessionFx.task(1, state: state, turn: turn, seq: seq)],
            runs: [SessionFx.run(session: 1, turn: turn, action: SessionFx.issue(1))], connections: SessionFx.connections, conversations: []
        )
    }

    func reply(_ n: Int, seq: Int, in conversation: UUID, _ text: String) -> ChatMessage {
        Chats.message(n, in: conversation, seq: seq, role: .assistant, text: text, at: Double(seq))
    }

    func texts(_ rig: Rig) -> [String] { rig.chat.turns(for: rig.conversation.id).map(\.text) }

    func threadReads(_ rig: Rig) -> Int { gateway.calls(prefix: "messages:\(rig.conversation.id.uuidString)").count }

    /// 세션을 한 번 읽고 반영된 글 읽기가 끝날 때까지
    func read(_ rig: Rig, _ snapshot: AgentSessionSnapshot) async {
        sessionsGateway.serve(snapshot)
        await rig.sessions.refresh()
        await rig.chat.settle()
    }

    func item(_ n: Int = 1, open: Bool, state: AgentTaskState?, turn: Int = 1, seq: Int?, status: AgentSessionStatus = .bound, updated: Date = .test(0)) -> AgentSessionItem {
        AgentSessionItem(
            id: SessionFx.id(n), name: "S\(n)", agent: .claudeCode, agentName: "Claude Code", connectionID: SessionFx.claudeConnection, status: status, ring: nil, line: "",
            createdAt: .test(0), updatedAt: updated, issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: open, pill: nil, lastTaskState: state, turnSeq: turn,
            lastEventSeq: seq
        )
    }

    // MARK: 첫 실사용의 결함

    @Test func theFinalReplyWrittenAfterTheLastReadAppearsWhenTheTurnCloses() async {
        let r = await rig()
        await read(r, snapshot(.running, seq: 5))
        #expect(texts(r) == ["Create notes.txt in this folder"])
        // 에이전트가 마지막 답을 쓰고 턴을 끝낸다 (글이 먼저 쓰이고 그 뒤 turn_completed가 task를 idle로 바꾼다)
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Created notes.txt as asked."))
        clock.value = clock.value.addingTimeInterval(5)
        await read(r, snapshot(.idle, seq: 9))
        #expect(texts(r) == ["Create notes.txt in this folder", "Created notes.txt as asked."], "닫히는 읽기에서 마지막 답을 읽는다")
    }

    @Test func aReplyWrittenWhileTheTurnIsStillRunningAppearsOnTheNextSessionReadThatSawNewEvents() async {
        let r = await rig()
        await read(r, snapshot(.running, seq: 5))
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Looking at the folder first."))
        clock.value = clock.value.addingTimeInterval(5)
        await read(r, snapshot(.running, seq: 6))
        #expect(texts(r).last == "Looking at the folder first.")
        #expect(r.chat.turns(for: r.conversation.id).last?.isUser == false)
    }

    @Test func aTurnThatWasNeverSeenOpenIsStillReadWhenItsTurnAdvances() async {
        let r = await rig()
        await read(r, snapshot(.idle, turn: 1, seq: 3))
        let before = threadReads(r)
        clock.value = clock.value.addingTimeInterval(10)
        // 둘째 턴이 두 번의 읽기 사이에 시작하고 끝났다
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Second turn done."))
        await read(r, snapshot(.idle, turn: 2, seq: 8))
        #expect(threadReads(r) == before + 1)
        #expect(texts(r).last == "Second turn done.")
    }

    // MARK: 필요 없는 읽기는 하지 않는다 (검토 P2)

    @Test func anOpenTaskWhoseSnapshotDidNotChangeIsNotReread() async {
        let r = await rig()
        await read(r, snapshot(.running, seq: 5))
        let afterFirst = threadReads(r)
        clock.value = clock.value.addingTimeInterval(10)
        for _ in 0..<3 { await read(r, snapshot(.running, seq: 5)) }
        #expect(threadReads(r) == afterFirst, "열린 task여도 새 일이 없으면 5초마다 글을 읽지 않는다")
    }

    @Test func aQuietSessionIsNotReread() async {
        let r = await rig()
        await read(r, snapshot(.idle, seq: 5))
        let before = threadReads(r)
        for _ in 0..<3 { await read(r, snapshot(.idle, seq: 5)) }
        #expect(threadReads(r) == before, "쉬는 세션은 그대로면 글을 다시 읽지 않는다")
    }

    @Test func anOlderSnapshotNeverMovesTheMarkBackwards() async {
        let r = await rig()
        await read(r, snapshot(.running, seq: 9))
        let afterFirst = threadReads(r)
        clock.value = clock.value.addingTimeInterval(10)
        await read(r, snapshot(.running, seq: 5))
        #expect(threadReads(r) == afterFirst, "다른 저장소의 낡은 읽기는 새 일이 아니다")
        await read(r, snapshot(.running, seq: 9))
        #expect(threadReads(r) == afterFirst, "표식이 뒤로 가지 않았으니 같은 값도 그대로")
        await read(r, snapshot(.running, seq: 10))
        #expect(threadReads(r) == afterFirst + 1)
    }

    @Test func aSessionStatusOrUpdateChangeAtTheSameSequenceCountsAsNews() async {
        let r = await rig()
        await read(r, snapshot(.idle, seq: 5))
        let before = threadReads(r)
        clock.value = clock.value.addingTimeInterval(10)
        await read(r, snapshot(.idle, seq: 5, status: .closed))
        #expect(threadReads(r) == before + 1, "세션 상태가 바뀌었다 (Mark에 status)")
        clock.value = clock.value.addingTimeInterval(10)
        await read(r, snapshot(.idle, seq: 5, status: .closed, updated: 30))
        #expect(threadReads(r) == before + 2, "갱신 시각이 앞섰다")
    }

    @Test func aShownSessionIsReadOnceTheFirstTimeItIsSeenEvenWhenItLooksQuiet() async {
        // `agent_sessions.updated_at`은 턴이 끝나도 바뀌지 않는다: 갱신 시각이 오래된 쉬는 세션에도 앱이 안 보던 사이에 끝난 턴의 답이 있을 수 있다.
        // 그래서 보이는 대화의 세션은 처음 볼 때 한 번 읽는다 (요청 한 번)
        let r = await rig()
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Finished while the window was closed."))
        r.chat.agentSessionsRead([item(open: false, state: .idle, seq: 3, updated: .test(100))])
        await r.chat.settle()
        #expect(threadReads(r) == 2 && texts(r).last == "Finished while the window was closed.")
        // 한 번뿐이다: 같은 읽기가 또 와도 그대로
        clock.value = clock.value.addingTimeInterval(10)
        r.chat.agentSessionsRead([item(open: false, state: .idle, seq: 3, updated: .test(100))])
        await r.chat.settle()
        #expect(threadReads(r) == 2)
    }

    @Test func aSessionSeenWhileItsConversationWasHiddenIsReadWhenItIsShownLater() async {
        let shown = Fx.conversation(1, session: session, last: 20)
        let hidden = Fx.conversation(2, session: SessionFx.id(2), last: 10)
        gateway.conversationsHandler = { [shown, hidden] }
        gateway.messagesHandler = { id in [Fx.user(id == shown.id ? 1 : 2, in: id, seq: 1)] }
        gateway.lastMessagesHandler = { _ in [:] }
        let clock = clock
        let chat = ChatStore(gateway: gateway, scope: scope, now: { clock.value }, sleep: { [chatTicker] in await chatTicker.sleep($0) })
        chat.agentConversation = agent
        let visible = Mutex2<Set<UUID>>([])
        chat.viewedConversations = { visible.value }
        await chat.refresh()
        await chat.settle()
        let quiet = item(2, open: false, state: .idle, seq: 4)
        chat.agentSessionsRead([quiet])
        await chat.settle()
        let hiddenReads = { gateway.calls(prefix: "messages:\(hidden.id.uuidString)").count }
        #expect(hiddenReads() == 0, "보이지 않는 동안은 읽지 않는다 (표식도 적지 않는다)")
        visible.value = [hidden.id]
        chat.agentSessionsRead([quiet])
        await chat.settle()
        #expect(hiddenReads() == 1, "처음 보이는 때 한 번")
    }

    @Test func aFollowReadDoesNotRefreshTheDeliveryLines() async {
        let r = await rig()
        let deliveryReads = agent.reads.count
        await read(r, snapshot(.running, seq: 5))
        #expect(threadReads(r) == 2)
        #expect(agent.reads.count == deliveryReads, "5초 따라 읽기가 전달 표시 전체를 다시 읽지 않는다")
    }

    @Test func twoStoresReportingTheSameNewsReadTheThreadOnce() async {
        let r = await rig()
        let news = item(open: true, state: .running, seq: 7)
        r.chat.agentSessionsRead([news])
        r.chat.agentSessionsRead([news])
        await r.chat.settle()
        #expect(threadReads(r) == 2, "처음 한 번 + 읽기 하나뿐")
        clock.value = clock.value.addingTimeInterval(10)
        r.chat.agentSessionsRead([news])
        await r.chat.settle()
        #expect(threadReads(r) == 2, "다른 저장소가 같은 일을 또 알려도 그대로")
    }

    @Test func marksAreNeverDroppedWhenASessionIsMissingFromOneRead() async {
        let r = await rig()
        let known = item(open: false, state: .idle, seq: 5, updated: .test(100))
        r.chat.agentSessionsRead([known])
        await r.chat.settle()
        let before = threadReads(r)
        clock.value = clock.value.addingTimeInterval(10)
        r.chat.agentSessionsRead([])
        r.chat.agentSessionsRead([known])
        await r.chat.settle()
        #expect(threadReads(r) == before, "좁은 저장소가 초점을 잠깐 바꿨다 돌아와도 처음 보는 세션으로 취급하지 않는다")
    }

    // MARK: 다시 연결 · 깸 (두 번의 읽기가 모두 실패한 마지막 답)

    /// 마지막 답의 따라 읽기가 두 번 다 실패해 표식이 안 적혔다: 글이 서버에 있는데 화면에 없다
    private func stuckWithoutTheFinalReply() async -> Rig {
        let r = await rig()
        await read(r, snapshot(.running, turn: 1, seq: 3))
        clock.value = clock.value.addingTimeInterval(10)
        failures.value = 2
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Final reply."))
        await read(r, snapshot(.idle, turn: 2, seq: 9))
        #expect(await eventually { !chatTicker.pendingDelays.isEmpty })
        chatTicker.fire()
        #expect(await eventually { failures.value == 0 })
        await r.chat.settle()
        #expect(texts(r) == ["Create notes.txt in this folder"], "두 번 다 실패했다")
        #expect(await eventually { chatTicker.pendingDelays.isEmpty })
        clock.value = clock.value.addingTimeInterval(10)
        return r
    }

    @Test func comingBackOnlineRereadsTheShownConversationsSoAMissedFinalReplyAppears() async {
        let r = await stuckWithoutTheFinalReply()
        r.chat.pathChanged(online: false)
        r.chat.pathChanged(online: true)
        await r.chat.settle()
        #expect(await eventually { texts(r).last == "Final reply." }, "세션 읽기 없이도 글을 다시 읽는다")
    }

    @Test func wakingTheMacRereadsTheShownConversationsToo() async {
        let r = await stuckWithoutTheFinalReply()
        r.chat.setAsleep(true)
        r.chat.setAsleep(false)
        await r.chat.settle()
        #expect(await eventually { texts(r).last == "Final reply." })
    }

    @Test func anUnchangedNetworkAndWakeStateRereadsNothing() async {
        let r = await rig()
        let before = threadReads(r)
        r.chat.pathChanged(online: true)
        r.chat.setAsleep(false)
        await r.chat.settle()
        #expect(threadReads(r) == before, "바뀐 것이 없다")
    }

    // MARK: 4초 안에는 한 번 (합친다)

    @Test func newsInsideTheWindowIsCoalescedIntoOneDelayedRead() async {
        let r = await rig()
        await read(r, snapshot(.running, seq: 5))
        let afterFirst = threadReads(r)
        clock.value = clock.value.addingTimeInterval(1)
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Step two done."))
        await read(r, snapshot(.running, seq: 6))
        #expect(threadReads(r) == afterFirst, "4초 안이라 바로 읽지 않는다")
        #expect(await eventually { chatTicker.pendingDelays.contains { abs($0 - 3) < 0.01 } }, "남은 3초 뒤 한 번")
        // 그 사이 또 새 일 (같은 읽기에 합쳐진다)
        clock.value = clock.value.addingTimeInterval(1)
        await read(r, snapshot(.running, seq: 7))
        #expect(chatTicker.pendingDelays.count == 1, "예약은 하나")
        chatTicker.fire()
        #expect(await eventually { threadReads(r) == afterFirst + 1 && texts(r).last == "Step two done." })
    }

    @Test func newsThatArrivesWhileAFollowReadIsInFlightGetsOneFollowUpRead() async {
        let r = await rig()
        hold.value = true
        sessionsGateway.serve(snapshot(.running, seq: 5))
        await r.sessions.refresh()
        #expect(await latch.waitForArrivals(1, timeout: .seconds(3)), "첫 따라 읽기가 붙잡혔다")
        let inFlight = threadReads(r)
        // 읽는 중에 새 일: 지금 도는 읽기에는 들어 있지 않을 수 있다
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Arrived during the read."))
        sessionsGateway.serve(snapshot(.running, seq: 6))
        await r.sessions.refresh()
        #expect(threadReads(r) == inFlight, "겹쳐 읽지 않는다")
        hold.value = false
        await latch.open()
        await r.chat.settle()
        #expect(await eventually { chatTicker.pendingDelays.count == 1 }, "끝난 뒤 한 번 더 읽도록 예약한다")
        chatTicker.fire()
        #expect(await eventually { threadReads(r) == inFlight + 1 }, "예약이 풀리면 한 번 더 읽는다")
        await r.chat.settle()
        #expect(texts(r).last == "Arrived during the read.")
        #expect(threadReads(r) == inFlight + 1, "그 한 번뿐")
    }

    // MARK: 읽기가 성공한 뒤에만 표식 · 실패하면 한 번 다시

    @Test func theMarkIsCommittedOnlyAfterASuccessfulReadAndAFailureRetriesOnce() async {
        let r = await rig()
        await read(r, snapshot(.running, turn: 1, seq: 3))
        clock.value = clock.value.addingTimeInterval(10)
        failures.value = 1
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Final reply."))
        await read(r, snapshot(.idle, turn: 2, seq: 9))
        #expect(texts(r) == ["Create notes.txt in this folder"], "읽기가 실패했다: 아직 안 보인다")
        #expect(await eventually { chatTicker.pendingDelays.contains { abs($0 - 4) < 0.01 } }, "한 번 늦춰 다시 읽는다")
        chatTicker.fire()
        #expect(await eventually { texts(r).last == "Final reply." }, "재시도가 마지막 답을 가져왔다")
        let afterRetry = threadReads(r)
        clock.value = clock.value.addingTimeInterval(10)
        await read(r, snapshot(.idle, turn: 2, seq: 9))
        #expect(threadReads(r) == afterRetry, "성공 뒤에 표식을 적었다: 같은 값은 다시 읽지 않는다")
    }

    @Test func aSecondFailureGivesUpButTheMarkStaysSoTheNextSessionReadTriesAgain() async {
        let r = await rig()
        await read(r, snapshot(.running, turn: 1, seq: 3))
        clock.value = clock.value.addingTimeInterval(10)
        failures.value = 2
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Final reply."))
        await read(r, snapshot(.idle, turn: 2, seq: 9))
        #expect(await eventually { !chatTicker.pendingDelays.isEmpty })
        chatTicker.fire()
        #expect(await eventually { failures.value == 0 })
        await r.chat.settle()
        #expect(texts(r) == ["Create notes.txt in this folder"])
        #expect(await eventually { chatTicker.pendingDelays.isEmpty }, "재시도는 한 번뿐")
        // 표식이 적히지 않았으니 같은 읽기가 다시 오면 읽는다
        clock.value = clock.value.addingTimeInterval(10)
        await read(r, snapshot(.idle, turn: 2, seq: 9))
        #expect(texts(r).last == "Final reply.")
    }

    // MARK: 보이는 대화만

    @Test func aConversationThatIsNotShownIsNotRead() async {
        // 대화 둘: 마지막 대화(1)가 현재 대화로 보이고, 둘째(2)는 어디에도 보이지 않는다
        let shown = Fx.conversation(1, session: session, last: 20)
        let hidden = Fx.conversation(2, session: SessionFx.id(2), last: 10)
        gateway.conversationsHandler = { [shown, hidden] }
        gateway.messagesHandler = { id in [Fx.user(id == shown.id ? 1 : 2, in: id, seq: 1)] }
        gateway.lastMessagesHandler = { _ in [:] }
        let clock = clock
        let chat = ChatStore(gateway: gateway, scope: scope, now: { clock.value }, sleep: { [chatTicker] in await chatTicker.sleep($0) })
        chat.agentConversation = agent
        await chat.refresh()
        await chat.settle()
        let hiddenReads = { gateway.calls(prefix: "messages:\(hidden.id.uuidString)").count }
        let before = (gateway.calls(prefix: "messages:\(shown.id.uuidString)").count, hiddenReads())
        chat.agentSessionsRead([item(2, open: true, state: .running, seq: 4)])
        await chat.settle()
        #expect(hiddenReads() == before.1, "보이지 않는 대화는 읽지 않는다 (보일 때 열면서 읽는다)")
        chat.agentSessionsRead([item(1, open: true, state: .running, seq: 4)])
        await chat.settle()
        #expect(gateway.calls(prefix: "messages:\(shown.id.uuidString)").count == before.0 + 1 && hiddenReads() == before.1, "보이는 대화만 읽는다")
    }

    // MARK: 규칙

    @Test func theRuleReadsOnlyNewsAndCommitsMarksOnlyWhenTheCallerSaysSo() {
        let first = AgentThreadFollow.plan(items: [item(1, open: true, state: .running, seq: 5), item(2, open: false, state: .idle, seq: 3)], marks: [:])
        #expect(Set(first.keys) == [SessionFx.id(1), SessionFx.id(2)], "처음 보는 세션은 열려 있든 쉬든 한 번 읽는다 (갱신 시각은 턴이 끝나도 바뀌지 않는다)")
        let steady = AgentThreadFollow.plan(items: [item(1, open: true, state: .running, seq: 5), item(2, open: false, state: .idle, seq: 3)], marks: first)
        #expect(steady.isEmpty, "그대로면 열린 세션도 읽지 않는다")
        let news = AgentThreadFollow.plan(items: [item(1, open: false, state: .idle, seq: 9), item(2, open: false, state: .idle, turn: 2, seq: 4)], marks: first)
        #expect(Set(news.keys) == [SessionFx.id(1), SessionFx.id(2)], "마지막 사건 순서 · 턴이 앞섰다")
        let older = AgentThreadFollow.plan(items: [item(1, open: true, state: .running, seq: 2)], marks: first)
        #expect(older.isEmpty, "낡은 읽기는 새 일이 아니다")
    }
}
