import Foundation
import Testing
@testable import TaskforceKit

/// 에이전트의 글은 비동기로 대화에 쓰인다 (Claude Code 첫 실사용: 승인 세 번 뒤 마지막 답이 Mac 대화에 끝내 나오지 않았다).
/// `conversation_messages`는 Realtime 발행 대상이 아니고, 대화 글은 열 때 · 질문에 답할 때 · 목록 읽기 때만 다시 읽었다. 그래서 마지막 답은 서버에 있어도 화면은 모르는 채였다.
/// 세션 읽기(열린 task가 있으면 5초마다)가 반영될 때 그 세션의 보이는 대화 글도 다시 읽는다: 열린 동안, 그리고 턴이 바뀌었을 때 한 번 더
@MainActor
struct ChatStoreAgentRepliesTests {
    typealias Fx = AgentFx
    let gateway = FakeChatGateway()
    let agent = FakeAgentConversationGateway()
    let sessionsGateway = FakeAgentSessionGateway()
    let ticker = ManualTicker()
    let scope = ChatTestAccount.fixedScope()
    let session = SessionFx.id(1)

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
        gateway.messagesHandler = { _ in thread.value }
        gateway.lastMessagesHandler = { _ in [:] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) }, sleep: { [ticker] in await ticker.sleep($0) })
        chat.agentConversation = agent
        chat.viewedConversations = { [conversation.id] }
        let sessions = AgentSessionStore(gateway: sessionsGateway, scope: scope, sleep: { [ticker] in await ticker.sleep($0) }, focus: { [chat] in chat.viewedAgentSessionIDs() })
        sessions.onApplied = { [weak chat] items in chat?.agentSessionsRead(items) }
        await chat.refresh()
        await chat.settle()
        return Rig(chat: chat, sessions: sessions, conversation: conversation, thread: thread)
    }

    func snapshot(_ state: AgentTaskState, turn: Int = 1) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            sessions: [SessionFx.session(1, turn: turn)], tasks: [SessionFx.task(1, state: state, turn: turn)],
            runs: [SessionFx.run(session: 1, turn: turn, action: SessionFx.issue(1))], connections: SessionFx.connections, conversations: []
        )
    }

    func reply(_ n: Int, seq: Int, in conversation: UUID, _ text: String) -> ChatMessage {
        Chats.message(n, in: conversation, seq: seq, role: .assistant, text: text, at: Double(seq))
    }

    func texts(_ rig: Rig) -> [String] { rig.chat.turns(for: rig.conversation.id).map(\.text) }

    func threadReads(_ rig: Rig) -> Int { gateway.calls(prefix: "messages:\(rig.conversation.id.uuidString)").count }

    // MARK: 첫 실사용의 결함

    @Test func theFinalReplyWrittenAfterTheLastReadAppearsWhenTheTurnCloses() async {
        let r = await rig()
        // 턴이 돌고 있다: 아직 답이 없다
        sessionsGateway.serve(snapshot(.running))
        await r.sessions.refresh()
        await r.chat.settle()
        #expect(texts(r) == ["Create notes.txt in this folder"])
        // 에이전트가 마지막 답을 쓰고 턴을 끝낸다 (서버는 글을 먼저 쓰고 task를 idle로 바꾼다)
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Created notes.txt as asked."))
        sessionsGateway.serve(snapshot(.idle))
        await r.sessions.refresh()
        await r.chat.settle()
        #expect(texts(r) == ["Create notes.txt in this folder", "Created notes.txt as asked."], "닫히는 읽기에서 마지막 답을 읽는다")
    }

    @Test func aReplyWrittenWhileTheTurnIsStillRunningAppearsOnTheNextSessionRead() async {
        let r = await rig()
        sessionsGateway.serve(snapshot(.running))
        await r.sessions.refresh()
        await r.chat.settle()
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Looking at the folder first."))
        await r.sessions.refresh()
        await r.chat.settle()
        #expect(texts(r).last == "Looking at the folder first.", "열린 task가 있는 동안은 읽을 때마다 글도 다시 읽는다")
        #expect(r.chat.turns(for: r.conversation.id).last?.isUser == false)
    }

    @Test func aTurnThatWasNeverSeenOpenIsStillReadWhenTheSessionsTurnAdvances() async {
        let r = await rig()
        sessionsGateway.serve(snapshot(.idle, turn: 1))
        await r.sessions.refresh()
        await r.chat.settle()
        let before = threadReads(r)
        // 둘째 턴이 두 번의 읽기 사이에 시작하고 끝났다
        r.thread.value.append(reply(2, seq: 2, in: r.conversation.id, "Second turn done."))
        sessionsGateway.serve(snapshot(.idle, turn: 2))
        await r.sessions.refresh()
        await r.chat.settle()
        #expect(threadReads(r) == before + 1)
        #expect(texts(r).last == "Second turn done.")
    }

    // MARK: 필요 없는 읽기는 하지 않는다

    @Test func aQuietSessionIsNotReread() async {
        let r = await rig()
        sessionsGateway.serve(snapshot(.idle))
        await r.sessions.refresh()
        await r.chat.settle()
        let before = threadReads(r)
        for _ in 0..<3 {
            await r.sessions.refresh()
            await r.chat.settle()
        }
        #expect(threadReads(r) == before, "쉬는 세션은 그대로면 글을 다시 읽지 않는다")
    }

    @Test func aConversationThatIsNotShownIsNotRead() async {
        // 대화 둘: 마지막 대화(1)가 현재 대화로 보이고, 둘째(2)는 어디에도 보이지 않는다
        let shown = Fx.conversation(1, session: session, last: 20)
        let hidden = Fx.conversation(2, session: SessionFx.id(2), last: 10)
        gateway.conversationsHandler = { [shown, hidden] }
        gateway.messagesHandler = { id in [Fx.user(id == shown.id ? 1 : 2, in: id, seq: 1)] }
        gateway.lastMessagesHandler = { _ in [:] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) }, sleep: { [ticker] in await ticker.sleep($0) })
        chat.agentConversation = agent
        await chat.refresh()
        await chat.settle()
        func open(_ n: Int) -> AgentSessionItem {
            AgentSessionItem(
                id: SessionFx.id(n), name: "S\(n)", agent: .claudeCode, agentName: "Claude Code", connectionID: SessionFx.claudeConnection, status: .bound, ring: nil, line: "",
                createdAt: SessionFx.at(0), updatedAt: SessionFx.at(0), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: true, pill: nil,
                lastTaskState: .running, turnSeq: 1
            )
        }
        let hiddenReads = { gateway.calls(prefix: "messages:\(hidden.id.uuidString)").count }
        let before = (gateway.calls(prefix: "messages:\(shown.id.uuidString)").count, hiddenReads())
        chat.agentSessionsRead([open(2)])
        await chat.settle()
        #expect(hiddenReads() == before.1, "보이지 않는 대화는 읽지 않는다 (보일 때 열면서 읽는다)")
        chat.agentSessionsRead([open(1)])
        await chat.settle()
        #expect(gateway.calls(prefix: "messages:\(shown.id.uuidString)").count == before.0 + 1 && hiddenReads() == before.1, "보이는 대화만 읽는다")
    }

    @Test func anotherSessionsProgressDoesNotRereadThisConversation() async {
        let r = await rig()
        sessionsGateway.serve(snapshot(.idle))
        await r.sessions.refresh()
        await r.chat.settle()
        let before = threadReads(r)
        // 다른 세션 둘째가 돌고 있다
        let other = AgentSessionItem(
            id: SessionFx.id(2), name: "Other", agent: .claudeCode, agentName: "Claude Code", connectionID: SessionFx.claudeConnection, status: .bound, ring: nil, line: "",
            createdAt: SessionFx.at(0), updatedAt: SessionFx.at(0), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: true, pill: nil,
            lastTaskState: .running, turnSeq: 1
        )
        r.chat.agentSessionsRead([other])
        await r.chat.settle()
        #expect(threadReads(r) == before)
    }

    // MARK: 규칙

    @Test func theRuleRereadsOpenSessionsAndSessionsWhoseTurnOrStateChangedSinceLastSeen() {
        func item(_ n: Int, open: Bool, state: AgentTaskState?, turn: Int) -> AgentSessionItem {
            AgentSessionItem(
                id: SessionFx.id(n), name: "S\(n)", agent: .claudeCode, agentName: "Claude Code", connectionID: SessionFx.claudeConnection, status: .bound, ring: nil, line: "",
                createdAt: SessionFx.at(0), updatedAt: SessionFx.at(0), issueIDs: [], currentIssueID: nil, conversationID: nil, hasOpenTask: open, pill: nil,
                lastTaskState: state, turnSeq: turn
            )
        }
        let first = AgentThreadFollow.plan(items: [item(1, open: true, state: .running, turn: 1), item(2, open: false, state: .idle, turn: 1)], marks: [:])
        #expect(first.reread == [SessionFx.id(1)], "처음 보는 쉬는 세션은 읽지 않는다 (대화를 열 때 이미 읽었다)")
        let second = AgentThreadFollow.plan(items: [item(1, open: false, state: .idle, turn: 1), item(2, open: false, state: .idle, turn: 2)], marks: first.marks)
        #expect(second.reread == [SessionFx.id(1), SessionFx.id(2)], "닫힌 세션(상태가 바뀜) · 턴이 바뀐 세션")
        let third = AgentThreadFollow.plan(items: [item(1, open: false, state: .idle, turn: 1)], marks: second.marks)
        #expect(third.reread.isEmpty && third.marks.keys.sorted { $0.uuidString < $1.uuidString } == [SessionFx.id(1)], "그대로면 읽지 않고 사라진 세션의 표식은 버린다")
    }
}
