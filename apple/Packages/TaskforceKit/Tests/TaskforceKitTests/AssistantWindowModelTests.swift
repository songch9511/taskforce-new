import Foundation
import Testing
@testable import TaskforceKit

/// 창 하나의 상태 (OA U1): 대화 하나 · 칩 · 대상 · History/대화 · 새 대화. 창이 여럿이어도 서로의 대화 · 초안 · 칩을 건드리지 않는다
@MainActor
struct AssistantWindowModelTests {
    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let scope = ChatTestAccount.fixedScope()
    let codex = UUID(uuidString: "a3333333-3333-4333-8333-333333333334")!
    let action1 = UUID(uuidString: "c1000000-0000-4000-8000-000000000001")!
    let action2 = UUID(uuidString: "c1000000-0000-4000-8000-000000000002")!

    final class Host {
        var elsewhere: Set<UUID> = []
        var rebinds: [UUID] = []
        var outcome: AssistantWindowRegistry.RebindOutcome = .rebound
    }

    struct Rig {
        let model: AssistantWindowModel
        let chat: ChatStore
        let targets: AssistantTargetsStore
        let host: Host
    }

    func rig(loadTargets: Bool = true, existing: [ChatConversation] = []) async -> Rig {
        gateway.conversationsHandler = { existing }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        await chat.refresh()
        let codexConnection = codex
        assistant.targetsHandler = {
            [
                .taskforce,
                .agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: nil, state: .notConnected, access: nil)),
                .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: codexConnection, state: .ready, access: .write)),
            ]
        }
        let targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true })
        if loadTargets { await targets.refresh() }
        let host = Host()
        let conversation = existing.first?.id ?? chat.reserveNewChat(target: .taskforce, excluding: [])
        let model = AssistantWindowModel(
            conversationID: conversation, chat: chat, targets: targets,
            openElsewhere: { host.elsewhere },
            rebind: { id in
                host.rebinds.append(id)
                return host.outcome
            }
        )
        return Rig(model: model, chat: chat, targets: targets, host: host)
    }

    func item(_ id: UUID, _ title: String) -> AssistantChip {
        AssistantChip(kind: .action, itemID: id, origin: .auto, title: title)
    }

    // MARK: 보이는 것

    @Test func aFreshWindowIsAnEmptyNewChatForTaskforce() async {
        let r = await rig()
        #expect(r.model.title == "New chat" && r.model.mode == .chat)
        #expect(r.model.isEmptyConversation && r.model.pick == .taskforce && !r.model.toAgent)
        #expect(r.model.targetName == "Taskforce" && r.model.placeholder == "Ask Taskforce")
        #expect(r.model.chips.chips.isEmpty)
    }

    @Test func thePlaceholderFollowsTheChipsAndTheTarget() async {
        let r = await rig()
        r.model.followOpenItem(item(action1, "Pricing"))
        #expect(r.model.placeholder == "Ask about Pricing")
        r.model.followOpenItem(nil)
        r.model.addChip(AssistantChip(kind: .context, itemID: UUID(), origin: .added, title: "Shape launch"))
        #expect(r.model.placeholder == "Ask about these")
        r.model.chooseTarget(try! #require(r.targets.options.last))
        #expect(r.model.placeholder == "Message Codex" && r.model.targetName == "Codex" && r.model.toAgent)
        #expect(r.model.chipLabel(r.model.chips.chips[0]) == "Pricing · Not sent", "에이전트 대상이면 auto 칩에 접미사")
        #expect(r.model.chipLabel(r.model.chips.chips[1]) == "Shape launch")
    }

    @Test func aBlockedPromptShowsWhyAndRefusesToSend() async {
        let r = await rig()
        r.chat.setDraft("hello", for: r.model.conversationID)
        r.model.blocked = ""
        #expect(r.model.placeholder == "Answer the question above first" && r.model.isBlocked)
        #expect(!r.model.canSend)
        await r.model.send("hello")
        #expect(r.chat.turns(for: r.model.conversationID).isEmpty && gateway.calls(prefix: "create").isEmpty)
        r.model.blocked = nil
        #expect(r.model.canSend, "질문에 답하면 같은 글을 보낼 수 있다")
        r.chat.setDraft("   ", for: r.model.conversationID)
        #expect(!r.model.canSend, "빈 글은 못 보낸다")
    }

    // MARK: 보내기와 칩

    @Test func sendingCarriesEveryChipAndTurnsAutoIntoAddedForTaskforce() async {
        let r = await rig()
        r.model.followOpenItem(item(action1, "Pricing"))
        r.model.addChip(AssistantChip(kind: .action, itemID: action2, origin: .added, title: "Onboarding"))
        gateway.createHandler = { id, title, context in ChatConversation(id: id, title: title, contextID: context, createdAt: .test()) }
        assistant.postTaskforceHandler = { conversation, cmid, text in Chats.pair(1, in: conversation, seq: 1, cmid: cmid, text: text) }
        await r.model.send("Compare these")
        #expect(assistant.sentAttachments == [[
            ChatAttachment(kind: .action, id: action1, origin: .auto), ChatAttachment(kind: .action, id: action2, origin: .added),
        ]], "보낼 때의 칩 그대로 (auto는 origin auto로)")
        #expect(r.model.chips.chips.map(\.origin) == [.added, .added], "보낸 뒤 auto는 added로 남는다")
        #expect(r.chat.turns(for: r.model.conversationID).map(\.text) == ["Compare these", "Noted."])
        #expect(!r.model.isEmptyConversation)
    }

    @Test func anAgentSendLeavesTheAutoChipAutoAndDashed() async {
        let r = await rig()
        r.model.chooseTarget(try! #require(r.targets.options.last))
        r.model.followOpenItem(item(action1, "Pricing"))
        assistant.postAgentHandler = { conversation, cmid, text in
            AgentPostedMessage(message: Chats.message(1, in: conversation, seq: 1, role: .user, text: text, cmid: cmid, at: 1), delivery: AgentDelivery(state: .sent))
        }
        await r.model.send("이어서 해 줘")
        #expect(r.model.chips.chips.map(\.origin) == [.auto])
        #expect(r.chat.turns(for: r.model.conversationID).first?.delivery?.state == .sent)
        #expect(r.model.pick.isAgent, "보낸 뒤에도 대상은 에이전트 그대로")
    }

    @Test func aMessageThatCannotBeSentChangesNothing() async {
        let r = await rig()
        r.model.followOpenItem(item(action1, "Pricing"))
        await r.model.send("   ")
        #expect(r.model.chips.chips.map(\.origin) == [.auto], "빈 글은 칩도 그대로")
        #expect(assistant.calls.filter { $0 != "targets" }.isEmpty)
    }

    @Test func thePromptTextIsTheDraftOfThisConversation() async {
        let r = await rig()
        r.model.setDraft("half written")
        #expect(r.model.draft == "half written" && r.chat.draft(for: r.model.conversationID) == "half written")
        #expect(r.model.canSend)
    }

    // MARK: 대상 바꾸기

    @Test func choosingATargetBeforeTheFirstMessageJustChangesTheTarget() async {
        let r = await rig()
        let id = r.model.conversationID
        r.model.chooseTarget(try! #require(r.targets.options.last))
        #expect(r.model.conversationID == id && r.host.rebinds.isEmpty, "빈 대화는 같은 대화에서 대상만 바뀐다")
        #expect(r.model.pick == .agent(adapter: "agent:codex", connectionID: codex))
        r.model.chooseTarget(r.targets.options[0])
        #expect(r.model.pick == .taskforce)
    }

    @Test func choosingAnotherTargetAfterTheFirstMessageOpensANewChatInTheSameWindow() async throws {
        let existing = Chats.conversation(1, title: "Pricing", last: 10)
        let r = await rig(existing: [existing])
        let old = r.model.conversationID
        #expect(old == existing.id)
        r.model.followOpenItem(item(action1, "Pricing"))
        r.model.setDraft("unsent thought")
        r.model.chooseTarget(try #require(r.targets.options.last))
        let new = r.model.conversationID
        #expect(new != old && r.host.rebinds == [new], "같은 창이 새 대화로 바뀐다 (앞 대화는 History에 남는다)")
        #expect(r.chat.entries.contains { $0.id == old }, "앞 대화는 그대로 남는다")
        #expect(r.model.pick == .agent(adapter: "agent:codex", connectionID: codex) && r.model.isEmptyConversation)
        #expect(r.model.chips.chips.map(\.title) == ["Pricing"], "같은 칩을 가진 새 대화")
        #expect(r.model.draft == "unsent thought" && r.chat.draft(for: old) == "", "쓰던 글은 새 대화로 따라온다")
    }

    /// 서버에 아직 없어도 보낸(또는 보내다 실패한) 글이 있으면 첫 메시지가 지난 대화다: 대상이 새 대화로 바뀐다
    @Test func aChatWhoseFirstSendFailedIsNoLongerFreeToChangeItsTarget() async throws {
        let r = await rig()
        let first = r.model.conversationID
        gateway.createHandler = { _, _, _ in throw URLError(.timedOut) }
        await r.model.send("hello")
        #expect(r.chat.hasMessages(first) && r.chat.isLocalChat(first))
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.model.conversationID != first && r.host.rebinds == [r.model.conversationID], "보내려던 글이 남은 대화의 대상은 그대로 두고 새 대화로")
        #expect(r.chat.pick(for: first) == .taskforce)
    }

    @Test func choosingTheAgentThisChatAlreadyTalksToOpensNothingNew() async throws {
        let codexConnection = codex
        let agentChat = ChatConversation(
            id: ChatContractFixtures.id(7, prefix: "bcb50000"), title: "Fix the build", createdAt: .test(), lastMessageAt: .test(50),
            target: ChatConversationTarget(kind: .agent, agentConnectionID: codexConnection)
        )
        let r = await rig(existing: [agentChat])
        let option = try #require(r.targets.options.last)
        #expect(option.name == "Codex" && r.model.option?.name == "Codex", "서버 대화의 에이전트는 연결로 행을 찾는다")
        r.model.chooseTarget(option)
        #expect(r.model.conversationID == agentChat.id && r.host.rebinds.isEmpty)
        r.model.chooseTarget(r.targets.options[0])
        #expect(r.model.conversationID != agentChat.id, "Taskforce로 바꾸면 새 대화")
    }

    @Test func choosingTheCurrentTargetAgainChangesNothing() async throws {
        let existing = Chats.conversation(1, title: "Pricing", last: 10)
        let r = await rig(existing: [existing])
        r.model.chooseTarget(r.targets.options[0])
        #expect(r.model.conversationID == existing.id && r.host.rebinds.isEmpty)
    }

    @Test func aNewChatForTheNewTargetNeverTakesAChatAnotherWindowHolds() async throws {
        let existing = Chats.conversation(1, title: "Pricing", last: 10)
        let r = await rig(existing: [existing])
        let held = r.chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: codex), excluding: [])
        r.host.elsewhere = [held]
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.model.conversationID != held, "다른 창이 쥔 빈 대화는 쓰지 않는다")
    }

    @Test func changingTheTargetNeverTakesAnEmptyChatThatHoldsAnotherDraft() async throws {
        let b = Chats.conversation(2, title: "Launch", last: 20)
        let r = await rig(existing: [b])
        // A: 쓰던 글이 남은 빈 새 대화 (창은 닫혀 있다)
        let a = r.chat.reserveNewChat(target: .taskforce, excluding: [r.model.conversationID])
        r.chat.setDraft("A draft", for: a)
        // B 창에서 글을 쓰고 대상을 바꾼다
        r.chat.setDraft("B draft", for: r.model.conversationID)
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.model.conversationID != a && r.model.conversationID != b.id, "A는 다른 초안을 쥐고 있어 다시 쓰지 않는다")
        #expect(r.chat.draft(for: a) == "A draft", "A의 초안은 그대로")
        #expect(r.chat.pick(for: a) == .taskforce, "A의 대상도 그대로")
        #expect(r.chat.draft(for: r.model.conversationID) == "B draft", "B의 글은 새 대화로 따라온다")
        #expect(r.chat.draft(for: b.id) == "")
    }

    @Test func changingTheTargetStillReusesAnEmptyChatThatHoldsNoDraft() async throws {
        let b = Chats.conversation(2, title: "Launch", last: 20)
        let r = await rig(existing: [b])
        let a = r.chat.reserveNewChat(target: .taskforce, excluding: [r.model.conversationID])
        r.chat.setDraft("B draft", for: r.model.conversationID)
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.model.conversationID == a, "초안 없는 빈 대화는 다시 쓴다 (빈 대화가 쌓이지 않게)")
        #expect(r.chat.draft(for: a) == "B draft")
    }

    // MARK: 새 대화 · History

    @Test func newChatStartsFreshForTaskforceWithNoChipsInTheSameWindow() async {
        let existing = Chats.conversation(1, title: "Pricing", last: 10)
        let r = await rig(existing: [existing])
        r.model.followOpenItem(item(action1, "Pricing"))
        r.model.newChat()
        #expect(r.model.conversationID != existing.id && r.host.rebinds == [r.model.conversationID])
        #expect(r.model.chips.chips.isEmpty && r.model.pick == .taskforce && r.model.mode == .chat)
        // 열린 항목은 다시 새 대화의 auto 칩이 된다 (옛 대화에서 뺀 칩 기억은 따라오지 않는다)
        r.model.followOpenItem(item(action1, "Pricing"))
        #expect(r.model.chips.chips.map(\.title) == ["Pricing"])
    }

    @Test func historyReplacesTheBodyOfTheSameWindowAndOpeningAChatGoesBack() async {
        let a = Chats.conversation(1, title: "A", last: 10)
        let b = Chats.conversation(2, title: "B", last: 20)
        let r = await rig(existing: [a, b])
        #expect(r.model.conversationID == a.id)
        r.model.followOpenItem(item(action1, "Pricing"))
        r.model.toggleHistory()
        #expect(r.model.mode == .history && r.model.title == "Chat history")
        r.model.openConversation(b.id)
        #expect(r.model.mode == .chat && r.model.conversationID == b.id && r.host.rebinds == [b.id])
        #expect(r.model.chips.chips.isEmpty, "다른 대화를 열면 칩은 그 대화의 것")
        r.model.toggleHistory()
        r.model.toggleHistory()
        #expect(r.model.mode == .chat, "History를 다시 누르면 대화로")
    }

    @Test func openingAChatThatAnotherWindowShowsLeavesThisWindowAsItIs() async {
        let a = Chats.conversation(1, title: "A", last: 10)
        let b = Chats.conversation(2, title: "B", last: 20)
        let r = await rig(existing: [a, b])
        r.host.outcome = .showsElsewhere(UUID())
        r.model.toggleHistory()
        r.model.openConversation(b.id)
        #expect(r.model.conversationID == a.id && r.model.mode == .history, "같은 대화는 그 창을 앞으로 가져오고 이 창은 그대로")
    }

    @Test func escapeFromHistoryGoesBackToTheChat() async {
        let r = await rig()
        r.model.toggleHistory()
        #expect(r.model.escapeInner())
        #expect(r.model.mode == .chat)
        #expect(!r.model.escapeInner(), "대화에서는 안쪽이 없다: 창을 숨긴다")
    }

    @Test func historyListsChatsOfBothTargetsNewestFirst() async {
        let agentChat = ChatConversation(
            id: ChatContractFixtures.id(7, prefix: "bcb50000"), title: "Fix the build", createdAt: .test(), lastMessageAt: .test(50),
            target: ChatConversationTarget(kind: .agent, agentConnectionID: codex)
        )
        let plain = Chats.conversation(8, title: "Pricing", last: 10)
        let r = await rig(existing: [plain, agentChat])
        let entries = r.model.historyEntries
        #expect(entries.map(\.title).prefix(2) == ["Fix the build", "Pricing"])
        #expect(r.model.mark(for: entries[0]) == .codex && r.model.mark(for: entries[1]) == nil, "에이전트 대화에만 마크")
    }

    // MARK: 높이

    @Test func onlyAnEmptyChatInTheChatBodyGetsTheTallFloor() async {
        let existing = Chats.conversation(1, title: "Pricing", last: 10)
        let r = await rig(existing: [existing])
        #expect(!r.model.isEmptyConversation, "메시지가 있었던 대화")
        let fresh = await rig()
        #expect(fresh.model.isEmptyConversation)
        fresh.model.toggleHistory()
        #expect(!fresh.model.isEmptyConversation, "History 본문은 빈 대화가 아니다")
    }
}
