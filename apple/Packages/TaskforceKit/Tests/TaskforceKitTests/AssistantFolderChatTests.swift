import Foundation
import Testing
@testable import TaskforceKit

/// 대화 머리의 "다른 폴더로 새 대화" (사용자 결정 2026-10-21): Claude 세션의 폴더는 세션을 연 뒤 바뀌지 않는다 — 그래서 다른 폴더는 **같은 에이전트의 새 대화**로 연다.
/// 창은 같고(`rebind`), 옛 대화는 그대로이며(글 · 초안 · 폴더), 새 대화에는 고른 폴더가 먼저 적힌다. 폴더를 적지 못하면 아무것도 바꾸지 않는다.
/// 코드 검토(2026-10-22): 대화가 쓰지 않을 폴더(`forgetFolder`)는 지운다 — 대상이 바뀐 빈 대화 · 새로 내주는(다시 쓰이는) 빈 대화 · 버려진 빈 대화 · 창을 못 바꾼 새 대화
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
        /// `forgetFolder`가 불린 대화 (순서대로)
        var forgotten: [UUID] = []
    }

    struct Rig {
        let model: AssistantWindowModel
        let chat: ChatStore
        let targets: AssistantTargetsStore
        let host: Host
        let original: UUID
    }

    struct Refused: Error {}

    /// 부를 때마다 앞서는 시계: 나중에 만든 대화가 "가장 최근 빈 대화"가 되게 (같은 시각이면 다시 쓰이는 대화가 id 순서에 달려 시험이 흔들린다)
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 500.0
        func tick() -> Date {
            lock.withLock {
                seconds += 1
                return .test(seconds)
            }
        }
    }

    /// - agent: 에이전트(Codex) 대화로 시작하나 (아니면 Taskforce 대화)
    /// - existing: 서버에 이미 있는 대화들
    /// - startOnExisting: 처음 보이는 대화가 `existing`의 첫 대화인가 (아니면 서버에 없는 빈 새 대화)
    /// - late: 창이 열린 **뒤에** 서버 목록에 나타난 대화들 (처음 보이는 빈 대화가 그것을 다시 쓰지 않게)
    /// - targetRows: 대상 목록을 이 행들로 (기본: Taskforce + Codex 하나)
    func rig(
        agent: Bool = true, existing: [ChatConversation] = [], startOnExisting: Bool = false, late: [ChatConversation] = [], targetRows: [AssistantTarget]? = nil
    ) async -> Rig {
        gateway.conversationsHandler = { existing }
        let clock = Clock()
        let chat = ChatStore(gateway: gateway, scope: scope, now: { clock.tick() })
        chat.assistant = assistant
        await chat.refresh()
        let connection = codex
        assistant.targetsHandler = {
            targetRows ?? [.taskforce, .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: connection, state: .ready, access: .write))]
        }
        let targets = AssistantTargetsStore(gateway: assistant, scope: scope, canRunAgents: { true })
        await targets.refresh()
        let host = Host()
        let target: AssistantTargetPick = agent ? .agent(adapter: "agent:codex", connectionID: connection) : .taskforce
        let conversation = startOnExisting ? existing[0].id : chat.reserveNewChat(target: target, excluding: [])
        let model = AssistantWindowModel(
            conversationID: conversation, chat: chat, targets: targets,
            openElsewhere: { host.elsewhere },
            rebind: { id in
                host.rebinds.append(id)
                return host.outcome
            }
        )
        model.forgetFolder = { host.forgotten.append($0) }
        if !late.isEmpty {
            gateway.conversationsHandler = { existing + late }
            await chat.refresh()
        }
        return Rig(model: model, chat: chat, targets: targets, host: host, original: conversation)
    }

    private func server(_ number: Int, last: Int? = 10) -> ChatConversation {
        ChatConversation(
            id: ChatContractFixtures.id(number, prefix: "bcb50000"), title: "Chat \(number)", createdAt: .test(), lastMessageAt: last.map { .test(Double($0)) },
            target: ChatConversationTarget(kind: .taskforce)
        )
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
        #expect(r.host.forgotten.isEmpty, "적지 못했으니 지울 폴더도 없다")
    }

    @Test func aWindowThatCannotRebindStaysWhereItIsAndTheFolderJustWrittenIsForgotten() async {
        let r = await rig()
        r.host.outcome = .showsElsewhere(UUID())
        var bound: [UUID] = []
        let started = r.model.startAgentChat { bound.append($0) }
        #expect(!started && r.model.conversationID == r.original)
        #expect(r.host.forgotten == bound && bound.count == 1, "창을 못 바꿨으니 방금 적은 폴더는 새 대화에 고아로 남지 않는다 (코드 검토 P3)")
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

    // MARK: 세션이 이미 있는 대화는 새 대화로 쓰지 않는다 (코드 검토 질문 7)

    @Test func aReusedEmptyConversationThatAlreadyHasASessionIsNeverBoundToAFolder() async {
        // 서버에 있는 빈 에이전트 대화(같은 연결)가 세션을 이미 쥐고 있다: 새 대화가 그것을 다시 쓰게 되어도 폴더를 적지 않고 창도 옮기지 않는다
        let withSession = ChatConversation(
            id: ChatContractFixtures.id(9, prefix: "bcb50000"), title: nil, createdAt: .test(100), lastMessageAt: nil,
            target: ChatConversationTarget(kind: .agent, agentConnectionID: codex, agentSessionID: UUID())
        )
        let r = await rig(late: [withSession])
        var bound = 0
        let started = r.model.startAgentChat { _ in bound += 1 }
        #expect(!started && bound == 0, "세션이 있는 대화에는 폴더를 적지 않는다")
        #expect(r.model.conversationID == r.original && r.host.rebinds.isEmpty && r.host.forgotten.isEmpty)
    }

    // MARK: 쓰지 않을 폴더 지우기 (코드 검토 P2 · P3)

    @Test func changingTheTargetOfAnEmptyLocalChatForgetsItsFolderBecauseTheFolderBelongedToTheOldTargetsMac() async throws {
        let r = await rig()
        r.model.chooseTarget(try #require(r.targets.options.first { !$0.isAgent }))
        #expect(r.host.forgotten == [r.original], "대상이 바뀌면 그 빈 대화가 고른 폴더(옛 대상의 Mac의 것)를 지운다")
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.host.forgotten == [r.original, r.original], "다시 에이전트로 바꿔도 옛 폴더는 돌아오지 않는다")
    }

    @Test func choosingTheSameTargetAgainChangesNothingAndForgetsNothing() async throws {
        let r = await rig()
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.host.forgotten.isEmpty)
    }

    // 폴더는 Mac의 것이다 (코드 검토 재검토 3): 같은 Mac의 다른 에이전트로 바꾸면 그대로, 연결이 다른 Mac으로 바뀌어야 지운다

    private let thisMac = UUID(uuidString: "b1d6e000-0000-4000-8000-000000000001")!
    private let otherMac = UUID(uuidString: "b1d6e000-0000-4000-8000-000000000002")!
    private let claudeConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333335")!
    private let remoteConnection = UUID(uuidString: "a3333333-3333-4333-8333-333333333336")!

    /// Codex · Claude Code가 이 Mac의 연결(같은 bridge), Codex가 다른 Mac에도 하나
    private func macRows(thisMacKnown: Bool = true) -> [AssistantTarget] {
        let here: UUID? = thisMacKnown ? thisMac : nil
        return [
            .taskforce,
            .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: codex, state: .ready, access: .write, bridgeID: here)),
            .agent(.init(adapter: "agent:claude-code", displayName: "Claude Code", connectionID: claudeConnection, state: .ready, access: .write, bridgeID: here)),
            .agent(.init(adapter: "agent:codex", displayName: "Codex", connectionID: remoteConnection, state: .ready, access: .write, bridgeID: otherMac, deviceName: "Studio")),
        ]
    }

    private func option(_ r: Rig, _ name: String, connection: UUID? = nil) throws -> AssistantTargetOption {
        try #require(r.targets.options.first { $0.name == name && (connection == nil || $0.connectionID == connection) })
    }

    @Test func switchingToAnotherAgentOnTheSameMacKeepsTheChosenFolder() async throws {
        let r = await rig(targetRows: macRows())
        r.model.chooseTarget(try option(r, "Claude Code"))
        #expect(r.model.pick.connectionID == claudeConnection, "대상은 바뀌었다")
        #expect(r.host.forgotten.isEmpty, "같은 Mac의 다른 에이전트: 그 Mac에서 고른 폴더는 그대로")
    }

    @Test func switchingToAnAgentOnAnotherMacForgetsTheChosenFolder() async throws {
        let r = await rig(targetRows: macRows())
        r.model.chooseTarget(try option(r, "Codex", connection: remoteConnection))
        #expect(r.host.forgotten == [r.original], "연결이 다른 Mac으로 바뀌었다 → 이 Mac의 폴더를 지운다")
    }

    @Test func switchingToTaskforceOrWhenTheMacIsNotKnownForgetsTheFolder() async throws {
        let r = await rig(targetRows: macRows())
        r.model.chooseTarget(try #require(r.targets.options.first { !$0.isAgent }))
        #expect(r.host.forgotten == [r.original], "Taskforce 대상에는 Mac이 없다")
        // 서버가 Mac(`bridge_id`)을 주지 않은 연결끼리: 같은 Mac이라고 짐작하지 않는다
        let unknown = await rig(targetRows: macRows(thisMacKnown: false))
        unknown.model.chooseTarget(try option(unknown, "Claude Code"))
        #expect(unknown.host.forgotten == [unknown.original], "모르면 지운다 (다른 Mac의 폴더가 남는 것이 더 나쁘다)")
    }

    @Test func aChatHandedOutForTheNewTargetIsCleanedOfAnyOldFolder() async throws {
        let sent = server(1)
        let r = await rig(existing: [sent], startOnExisting: true)
        r.model.chooseTarget(try #require(r.targets.options.last))
        #expect(r.model.conversationID != sent.id)
        #expect(r.host.forgotten == [r.model.conversationID], "새로 내준(다시 쓰인 빈) 대화의 옛 폴더를 지운다. 보낸 옛 대화는 건드리지 않는다")
    }

    @Test func newChatCleansTheReusedChatAndTheEmptyLocalChatItLeaves() async {
        let r = await rig()
        // 더 늦게 만든 다른 빈 대화: New chat이 그것을 다시 쓴다
        let later = r.chat.reserveNewChat(target: .taskforce, excluding: [r.original])
        r.model.newChat()
        #expect(r.model.conversationID == later)
        #expect(Set(r.host.forgotten) == [later, r.original], "다시 쓰인 대화의 옛 폴더 · 떠나는 빈 대화의 폴더 모두 지운다")
    }

    @Test func newChatOnAChatThatWasSentLeavesItsFolderAlone() async {
        let sent = server(1)
        let r = await rig(existing: [sent], startOnExisting: true)
        r.model.newChat()
        #expect(r.host.forgotten == [r.model.conversationID], "보낸 대화의 폴더(세션 핀의 기록)는 건드리지 않는다: 새 대화만 깨끗이")
        #expect(!r.host.forgotten.contains(sent.id))
    }

    @Test func openingAnotherChatForgetsTheFolderOfTheEmptyLocalChatItLeavesButNotOfASentOne() async {
        let sent = server(1)
        let r = await rig(existing: [sent])
        r.model.openConversation(sent.id)
        #expect(r.host.forgotten == [r.original], "떠나는 빈 대화의 폴더를 지운다")
        r.model.openConversation(r.original)
        #expect(r.host.forgotten == [r.original], "보낸 대화(서버 대화)를 떠날 때는 지우지 않는다")
        r.model.openConversation(r.original)
        #expect(r.host.forgotten == [r.original], "같은 대화를 다시 여는 것은 떠나는 것이 아니다")
    }

    @Test func aWindowThatCannotRebindForgetsNothingWhenOpeningAChat() async {
        let sent = server(1)
        let r = await rig(existing: [sent])
        r.host.outcome = .showsElsewhere(UUID())
        r.model.openConversation(sent.id)
        #expect(r.host.forgotten.isEmpty && r.model.conversationID == r.original, "창이 그대로면 그 빈 대화는 아직 보이는 중이다")
    }

    @Test func startingAFreshChatForgetsTheFolderOfTheEmptyLocalChatItLeaves() async {
        let r = await rig()
        var bound: [UUID] = []
        #expect(r.model.startAgentChat { bound.append($0) })
        #expect(r.host.forgotten == [r.original] && !bound.contains(r.original), "떠나는 빈 대화(예전의 새 대화)의 폴더는 지우고, 새로 적은 폴더는 남긴다")
    }

    // MARK: 인라인 안내 (register 실패)

    @Test func aFolderNoticeBelongsToTheConversationItWasShownFor() async {
        let sent = server(1)
        let r = await rig(existing: [sent])
        #expect(r.model.folderNoticeText == nil)
        r.model.showFolderNotice("Something went wrong. Try again in a moment.")
        #expect(r.model.folderNoticeText == "Something went wrong. Try again in a moment.")
        r.model.openConversation(sent.id)
        #expect(r.model.folderNoticeText == nil, "다른 대화로 가면 그 대화의 것이 아니다")
        r.model.openConversation(r.original)
        #expect(r.model.folderNoticeText == nil, "돌아와도 옛 안내는 되살아나지 않는다")
        r.model.showFolderNotice("x")
        r.model.clearFolderNotice()
        #expect(r.model.folderNoticeText == nil)
    }
}
