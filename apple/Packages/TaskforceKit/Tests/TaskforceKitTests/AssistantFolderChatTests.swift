import Foundation
import Testing
@testable import TaskforceKit

/// 대화 머리의 "다른 폴더로 새 대화" (사용자 결정 2026-10-21): Claude 세션의 폴더는 세션을 연 뒤 바뀌지 않는다 — 그래서 다른 폴더는 **같은 에이전트의 새 대화**로 연다.
/// 창은 같고(`rebind`), 옛 대화는 그대로이며(글 · 초안 · 폴더), 새 대화에는 고른 폴더가 먼저 적힌다. 폴더를 적지 못하면 아무것도 바꾸지 않는다
@MainActor
struct AssistantFolderChatTests {
    let gateway = FakeChatGateway()
    let assistant = FakeAssistantGateway()
    let scope = ChatTestAccount.fixedScope()
    let codex = UUID(uuidString: "a3333333-3333-4333-8333-333333333334")!

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
        let original: UUID
    }

    struct Refused: Error {}

    /// - agent: 에이전트(Codex) 대화로 시작하나 (아니면 Taskforce 대화)
    func rig(agent: Bool = true) async -> Rig {
        gateway.conversationsHandler = { [] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        await chat.refresh()
        let connection = codex
        assistant.targetsHandler = {
            [.taskforce, .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: connection, state: .ready, access: .write))]
        }
        let targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true })
        await targets.refresh()
        let host = Host()
        let target: AssistantTargetPick = agent ? .agent(adapter: "agent:codex", connectionID: connection) : .taskforce
        let conversation = chat.reserveNewChat(target: target, excluding: [])
        let model = AssistantWindowModel(
            conversationID: conversation, chat: chat, targets: targets,
            openElsewhere: { host.elsewhere },
            rebind: { id in
                host.rebinds.append(id)
                return host.outcome
            }
        )
        return Rig(model: model, chat: chat, targets: targets, host: host, original: conversation)
    }

    @Test func itOpensAFreshConversationForTheSameAgentInTheSameWindowWithTheFolderWrittenFirst() async {
        let r = await rig()
        var bound: [UUID] = []
        let started = r.model.startAgentChat { bound.append($0) }
        #expect(started)
        #expect(r.model.conversationID != r.original && bound == [r.model.conversationID] && r.host.rebinds == [r.model.conversationID], "새 대화 id에 폴더를 적고 창이 그 대화로 간다")
        #expect(r.model.pick.isSame(as: .agent(adapter: "agent:codex", connectionID: codex)) && r.model.toAgent, "같은 에이전트 · 같은 연결")
        #expect(r.model.targetName == "Codex" && r.model.placeholder == "Message Codex")
        #expect(r.model.mode == .chat && r.chat.isLocalChat(r.model.conversationID) && !r.chat.hasMessages(r.model.conversationID), "빈 새 대화, 입력할 준비")
    }

    @Test func theOldConversationIsLeftExactlyAsItWasWithItsDraftAndItsTarget() async {
        let r = await rig()
        r.chat.setDraft("half-typed message", for: r.original)
        let before = r.chat.pick(for: r.original)
        r.model.startAgentChat { _ in }
        #expect(r.chat.draft(for: r.original) == "half-typed message", "옛 대화의 초안은 그 대화에 남는다 (새 대화로 옮기지 않는다)")
        #expect(r.chat.pick(for: r.original) == before)
        #expect(r.model.draft.isEmpty, "새 대화는 깨끗하다")
        #expect(r.model.conversationID != r.original, "초안이 있는 옛 대화를 다시 쓰지 않는다")
    }

    @Test func theNewConversationNeverReusesTheCurrentOneOrOneWithADraftOrOneAnotherWindowShows() async {
        let r = await rig()
        // 다른 창이 쥐고 있는 같은 에이전트의 빈 대화, 초안이 남은 빈 대화
        let shown = r.chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: codex), excluding: [r.original])
        r.host.elsewhere = [shown]
        let drafted = r.chat.reserveNewChat(target: .agent(adapter: "agent:codex", connectionID: codex), excluding: [r.original, shown])
        r.chat.setDraft("keep me", for: drafted)
        r.model.startAgentChat { _ in }
        #expect(![r.original, shown, drafted].contains(r.model.conversationID))
        #expect(r.chat.draft(for: drafted) == "keep me")
    }

    @Test func chipsAndTheHistoryScreenGoBackToAFreshStartLikeANewChat() async {
        let r = await rig()
        r.model.addChip(AssistantChip(kind: .action, itemID: UUID(), origin: .added, title: "Pricing"))
        r.model.toggleHistory()
        let focus = r.model.focusRequest
        r.model.startAgentChat { _ in }
        #expect(r.model.chips.chips.isEmpty && r.model.mode == .chat)
        #expect(r.model.focusRequest == focus + 1, "새 대화의 입력칸에 포커스")
    }

    @Test func ifTheFolderCannotBeWrittenNothingChangesAndNothingIsRebound() async {
        let r = await rig()
        r.model.addChip(AssistantChip(kind: .action, itemID: UUID(), origin: .added, title: "Pricing"))
        r.model.toggleHistory()
        let focus = r.model.focusRequest
        let started = r.model.startAgentChat { _ in throw Refused() }
        #expect(!started)
        #expect(r.model.conversationID == r.original && r.host.rebinds.isEmpty)
        #expect(r.model.chips.chips.count == 1 && r.model.mode == .history && r.model.focusRequest == focus)
    }

    @Test func aWindowThatCannotRebindStaysWhereItIs() async {
        let r = await rig()
        r.host.outcome = .showsElsewhere(UUID())
        let started = r.model.startAgentChat { _ in }
        #expect(!started && r.model.conversationID == r.original)
    }

    @Test func aTaskforceConversationHasNoFolderToChooseAndNothingHappens() async {
        let r = await rig(agent: false)
        var bound = 0
        let started = r.model.startAgentChat { _ in bound += 1 }
        #expect(!started && bound == 0 && r.model.conversationID == r.original && r.host.rebinds.isEmpty)
    }

    @Test func aServerConversationOfAnAgentKeepsItsConnectionForTheNewOne() async {
        let existing = ChatConversation(
            id: ChatContractFixtures.id(7, prefix: "bcb50000"), title: "Fix the build", createdAt: .test(), lastMessageAt: .test(50),
            target: ChatConversationTarget(kind: .agent, agentConnectionID: codex)
        )
        gateway.conversationsHandler = { [existing] }
        let chat = ChatStore(gateway: gateway, scope: scope, now: { .test(500) })
        chat.assistant = assistant
        await chat.refresh()
        let connection = codex
        assistant.targetsHandler = {
            [.taskforce, .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: connection, state: .ready, access: .write))]
        }
        let targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true })
        await targets.refresh()
        let model = AssistantWindowModel(conversationID: existing.id, chat: chat, targets: targets)
        #expect(model.startAgentChat { _ in })
        #expect(model.conversationID != existing.id && model.pick.connectionID == codex && model.targetName == "Codex")
    }
}
