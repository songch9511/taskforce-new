import Foundation
import Testing
@testable import TaskforceKit

/// 세션 패널이 대화를 여는 길 (OA U2 · 검토 반영 3 · 4 · 2): 패널은 대화 id만 안다.
/// - id로 그 행을 직접 읽는다: 목록(최근 100 + 빈 20)에 없는 오래된 대화도 열린다. 첫 읽기가 실패하면 빈 화면이 아니라 오류 + 다시 시도다
/// - 패널이 보이는 대화는 공통 갱신 집합에 든다 (온라인 복귀 · 목록 새로 읽기에서 낡지 않는다)
/// - 대화 대상(행)을 읽기 전에는 보내지 않는다: 확인되지 않은 대상을 Taskforce로 보지 않는다. 에이전트 대상의 `reply: null`은 오류가 아니다
@MainActor
struct ChatStoreSessionPanelTests {
    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let scope = ChatTestAccount.fixedScope()
    let connection = UUID(uuidString: "c0c00000-0000-4000-8000-000000000001")!

    func store() -> ChatStore {
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        return chat
    }

    /// 에이전트 세션의 대화 행 (대상 = agent)
    func agentRow(_ n: Int, last: TimeInterval = 10, archived: Bool = false) -> ChatConversation {
        ChatConversation(
            id: ChatContractFixtures.id(n, prefix: "bcb50000"), title: nil, createdAt: .test(0), lastMessageAt: .test(last), archivedAt: archived ? .test(1) : nil,
            target: ChatConversationTarget(kind: .agent, agentConnectionID: connection, agentSessionID: ChatContractFixtures.id(n, prefix: "5e550000"))
        )
    }

    func serve(list: [ChatConversation] = [], direct: [ChatConversation] = [], messages: [UUID: [ChatMessage]] = [:]) {
        gateway.conversationsHandler = { list }
        gateway.conversationHandler = { id in direct.first { $0.id == id } }
        gateway.messagesHandler = { messages[$0] ?? [] }
        gateway.lastMessagesHandler = { _ in [:] }
    }

    func said(_ id: UUID, _ text: String, seq: Int = 1) -> [UUID: [ChatMessage]] {
        [id: [Chats.message(seq, in: id, seq: seq, role: .assistant, text: text, at: Double(seq))]]
    }

    var conversationReads: [String] { gateway.calls(prefix: "conversation:") }

    // MARK: id로 직접 읽는다

    @Test func aConversationTheListDoesNotKnowIsReadByIDAndOpened() async {
        let row = agentRow(1)
        serve(direct: [row], messages: said(row.id, "Draft v2 is ready."))
        let chat = store()
        chat.ensureLoaded(row.id)
        await chat.settle()
        #expect(chat.screen(for: row.id) == .blank, "행을 읽기 전의 ensureLoaded는 아무것도 읽지 않는다 (지금까지의 동작)")
        await chat.readConversation(row.id)
        #expect(chat.turns(for: row.id).map(\.text) == ["Draft v2 is ready."])
        #expect(chat.screen(for: row.id) == .ready(problem: nil))
        #expect(chat.conversationTarget(for: row.id).isAgent, "행의 대상을 안다")
        #expect(conversationReads.count == 1)
    }

    @Test func aKnownConversationIsNotReadByIDAgain() async {
        let row = agentRow(1)
        serve(list: [row], direct: [row], messages: said(row.id, "hi"))
        let chat = store()
        await chat.refresh()
        let before = conversationReads.count
        await chat.readConversation(row.id)
        #expect(conversationReads.count == before, "목록에 있는 대화는 행을 다시 읽지 않는다")
        #expect(chat.turns(for: row.id).map(\.text) == ["hi"])
    }

    @Test func anOldConversationBeyondTheListIsKeptAndReReadByTheNextRefreshWhileThePanelShowsIt() async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        serve(list: [listed], direct: [old], messages: said(old.id, "first"))
        let chat = store()
        chat.panelConversations = { [old.id] }
        await chat.refresh()
        await chat.settle()
        #expect(chat.turns(for: old.id).map(\.text) == ["first"], "패널이 보이는 대화는 목록에 없어도 refresh가 직접 읽어 연다")
        serve(list: [listed], direct: [old], messages: said(old.id, "second", seq: 2))
        await chat.refresh()
        #expect(chat.turns(for: old.id).map(\.text) == ["second"], "온라인 복귀 · 목록 새로 읽기가 패널 대화의 글도 다시 읽는다")
        #expect(chat.screen(for: old.id) == .ready(problem: nil) && chat.conversationTarget(for: old.id).isAgent, "목록 갱신이 이 대화를 떨어뜨리지 않는다")
    }

    @Test func aConversationNobodyViewsIsNotKeptWhenTheListLacksIt() async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        serve(list: [listed], direct: [old], messages: said(old.id, "first"))
        let chat = store()
        await chat.readConversation(old.id)
        #expect(chat.screen(for: old.id) == .ready(problem: nil))
        await chat.refresh()
        #expect(chat.screen(for: old.id) == .blank, "아무 화면도 보지 않는 대화는 목록이 말하는 대로 (서버가 사실이다)")
    }

    @Test func aTransientReadFailureOnRefreshKeepsTheOpenPanelConversation() async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        serve(list: [listed], direct: [old], messages: said(old.id, "first"))
        let chat = store()
        chat.panelConversations = { [old.id] }
        await chat.refresh()
        gateway.conversationHandler = { _ in throw URLError(.timedOut) }
        await chat.refresh()
        #expect(chat.turns(for: old.id).map(\.text) == ["first"] && chat.conversationTarget(for: old.id).isAgent, "행을 잠깐 못 읽어도 열린 패널을 비우지 않는다")
    }

    @Test func aFailedFirstReadStaysAsTheErrorScreenAcrossAListRefreshWhileThePanelShowsIt() async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        serve(list: [listed], direct: [], messages: [:])
        let chat = store()
        chat.panelConversations = { [old.id] }
        gateway.conversationHandler = { _ in throw URLError(.notConnectedToInternet) }
        await chat.readConversation(old.id)
        #expect(chat.screen(for: old.id) == .offline)
        await chat.refresh()
        #expect(chat.screen(for: old.id) == .offline, "목록을 새로 읽어도 열린 패널의 오류 화면(다시 시도)이 빈 화면으로 바뀌지 않는다")
        gateway.conversationHandler = { _ in nil }
        await chat.readConversation(old.id)
        await chat.refresh()
        #expect(chat.screen(for: old.id) == .failed, "서버에 없는 대화도 마찬가지")
        gateway.conversationHandler = { _ in old }
        gateway.messagesHandler = { id in [Chats.message(1, in: id, seq: 1, role: .assistant, text: "back", at: 1)] }
        await chat.readConversation(old.id)
        #expect(chat.screen(for: old.id) == .ready(problem: nil) && chat.turns(for: old.id).map(\.text) == ["back"], "다시 시도하면 열린다")
    }

    // MARK: 재검토 반영 3 — 열려 있는 동안 지워지거나 보관된 대화

    /// 후속 조회(목록 새로 읽기)가 `nil` · archived를 돌려주면 일시 실패(아는 행을 남긴다)와 달리 이전 `.ready` 본문을 남기지 않고 오류 화면 + 다시 시도다
    @Test func aPanelConversationDeletedElsewhereBecomesTheErrorScreenNotAStaleBody() async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        serve(list: [listed], direct: [old], messages: said(old.id, "first"))
        let chat = store()
        chat.panelConversations = { [old.id] }
        await chat.refresh()
        #expect(chat.screen(for: old.id) == .ready(problem: nil) && chat.turns(for: old.id).map(\.text) == ["first"])
        serve(list: [listed], direct: [], messages: said(old.id, "first"))
        await chat.refresh()
        #expect(chat.screen(for: old.id) == .failed, "서버에 없으면 이전 본문이 아니라 오류 화면")
        #expect(chat.turns(for: old.id).isEmpty && !chat.isTargetKnown(old.id), "낡은 본문 · 낡은 대상을 남기지 않는다")
        #expect(!chat.canCompose(in: old.id), "보낼 수 없다")
        // 다시 시도: 다시 생기면 열린다
        serve(list: [listed], direct: [old], messages: said(old.id, "back", seq: 2))
        await chat.readConversation(old.id)
        #expect(chat.screen(for: old.id) == .ready(problem: nil) && chat.turns(for: old.id).map(\.text) == ["back"])
    }

    @Test func aPanelConversationArchivedElsewhereBecomesTheErrorScreenToo() async {
        let listed = agentRow(1, last: 100)
        let old = agentRow(2, last: 1)
        serve(list: [listed], direct: [old], messages: said(old.id, "first"))
        let chat = store()
        chat.panelConversations = { [old.id] }
        await chat.refresh()
        serve(list: [listed], direct: [agentRow(2, last: 1, archived: true)], messages: said(old.id, "first"))
        await chat.refresh()
        #expect(chat.screen(for: old.id) == .failed && chat.turns(for: old.id).isEmpty)
    }

    @Test func aConversationInTheListThatIsLaterArchivedAlsoShowsTheErrorScreenWhileThePanelShowsIt() async {
        let row = agentRow(1, last: 100)
        serve(list: [row], direct: [row], messages: said(row.id, "first"))
        let chat = store()
        chat.panelConversations = { [row.id] }
        await chat.refresh()
        #expect(chat.screen(for: row.id) == .ready(problem: nil))
        serve(list: [], direct: [agentRow(1, last: 100, archived: true)], messages: said(row.id, "first"))
        await chat.refresh()
        #expect(chat.screen(for: row.id) == .failed && chat.turns(for: row.id).isEmpty, "목록에서 빠진(보관된) 대화는 본문이 아니라 오류 화면")
    }

    // MARK: 첫 읽기 실패 · 없는 대화

    @Test func aFirstReadFailureShowsOfflineOrFailedAndTryAgainReadsAgain() async {
        let row = agentRow(1)
        serve(direct: [row], messages: said(row.id, "back"))
        let chat = store()
        gateway.conversationHandler = { _ in throw URLError(.notConnectedToInternet) }
        await chat.readConversation(row.id)
        #expect(chat.screen(for: row.id) == .offline, "빈 화면(.blank)이 아니다")
        gateway.conversationHandler = { _ in throw FakeChatGateway.Failure() }
        await chat.readConversation(row.id)
        #expect(chat.screen(for: row.id) == .failed)
        gateway.conversationHandler = { _ in row }
        await chat.readConversation(row.id)
        #expect(chat.screen(for: row.id) == .ready(problem: nil) && chat.turns(for: row.id).map(\.text) == ["back"])
    }

    @Test func aConversationTheServerDoesNotHaveOrArchivedShowsFailedNotBlank() async {
        let missing = agentRow(1)
        serve(direct: [], messages: [:])
        let chat = store()
        await chat.readConversation(missing.id)
        #expect(chat.screen(for: missing.id) == .failed)
        let archived = agentRow(2, archived: true)
        serve(direct: [archived], messages: said(archived.id, "x"))
        await chat.readConversation(archived.id)
        #expect(chat.screen(for: archived.id) == .failed && chat.turns(for: archived.id).isEmpty, "보관한 대화는 열지 않는다")
    }

    @Test func aFailedMessageReadAfterTheRowIsKnownShowsTheErrorToo() async {
        let row = agentRow(1)
        serve(direct: [row])
        gateway.messagesHandler = { _ in throw URLError(.notConnectedToInternet) }
        let chat = store()
        await chat.readConversation(row.id)
        #expect(chat.screen(for: row.id) == .offline)
        gateway.messagesHandler = { _ in [Chats.message(1, in: row.id, seq: 1, role: .assistant, text: "ok", at: 1)] }
        await chat.readConversation(row.id)
        #expect(chat.screen(for: row.id) == .ready(problem: nil))
    }

    @Test func readingDoesNotNavigateTheStore() async {
        let row = agentRow(1)
        serve(direct: [row], messages: said(row.id, "hi"))
        let chat = store()
        let before = (chat.currentID, chat.mode, chat.focusRequest)
        await chat.readConversation(row.id)
        #expect((chat.currentID, chat.mode, chat.focusRequest) == before, "읽기만 한다: 저장소의 현재 대화 · 모드 · 포커스는 그대로")
    }

    // MARK: 대상을 읽기 전에는 보내지 않는다

    @Test func sendingIsBlockedUntilTheTargetIsKnown() async {
        let row = agentRow(1)
        serve(direct: [row], messages: [:])
        let chat = store()
        #expect(!chat.isTargetKnown(row.id) && !chat.canCompose(in: row.id) && !chat.canSend("Also update the wording", in: row.id))
        await chat.send("Also update the wording", in: row.id)
        #expect(assistant.calls.isEmpty && gateway.calls(prefix: "post").isEmpty, "대상을 모르면 어느 길로도 보내지 않는다 (Taskforce로 보지 않는다)")
        #expect(chat.turns(for: row.id).isEmpty, "보낸 것처럼 대기 글도 남기지 않는다")
        await chat.readConversation(row.id)
        #expect(chat.isTargetKnown(row.id) && chat.canCompose(in: row.id))
    }

    @Test func afterTheTargetIsReadAnAgentConversationSendsThroughTheAgentRouteAndANullReplyIsNotAnError() async {
        let row = agentRow(1)
        serve(direct: [row], messages: [:])
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .sent))
        }
        let chat = store()
        await chat.readConversation(row.id)
        await chat.send("Also update the wording", in: row.id)
        #expect(assistant.calls(prefix: "postAgent").count == 1 && gateway.calls(prefix: "post").isEmpty, "에이전트 길로 보낸다")
        let turns = chat.turns(for: row.id)
        #expect(turns.map(\.text) == ["Also update the wording"] && turns.allSatisfy { $0.status == .sent }, "답이 없어도(reply: null) 정상 접수다")
    }

    @Test func aLocalNewChatCanAlwaysBeComposed() {
        serve()
        let chat = store()
        let id = chat.reserveNewChat(target: .taskforce, excluding: [])
        #expect(chat.isTargetKnown(id) && chat.canCompose(in: id), "아직 서버에 없는 새 대화는 고른 대상이 대상이다")
        #expect(!chat.canCompose(in: nil))
    }
}
