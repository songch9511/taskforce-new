import Foundation
import Testing
@testable import TaskforceKit

/// 폴더 창을 기다리는 동안 보내려던 곳이 바뀌면 등록도 전송도 하지 않는다 (Astra P2-2, 코디네이터 13.11): `AgentSendTicket`(계정 · 창 · 대화 · 대상 · 칩 · 초안)과 보내기 순서
@MainActor
struct AgentWorkspaceGateTicketTests {
    static let window = UUID()
    static let conversation = UUID()
    static let agent = AssistantTargetPick.agent(adapter: "agent:claude-code", connectionID: UUID())
    static let chip = AssistantChip(kind: .action, itemID: UUID(), origin: .added, title: "Pricing")

    static func ticket(
        account: AccountScope.Token? = nil, window: UUID = window, conversation: UUID = conversation, hasSession: Bool = false, target: AssistantTargetPick = agent,
        chips: [AssistantChip] = [chip], draft: String = "hello"
    ) -> AgentSendTicket {
        AgentSendTicket(account: account, windowID: window, conversationID: conversation, hasSession: hasSession, target: target, chips: chips, draft: draft)
    }

    // MARK: 같은 곳인가

    @Test func aTicketIsTheSameOnlyWhenEveryFrozenFactIsTheSame() {
        let base = Self.ticket()
        #expect(base == Self.ticket())
        #expect(base != Self.ticket(window: UUID()), "다른 창")
        #expect(base != Self.ticket(conversation: UUID()), "다른 대화")
        #expect(base != Self.ticket(hasSession: true), "세션이 생겼다")
        #expect(base != Self.ticket(target: .taskforce), "다른 대상")
        #expect(base != Self.ticket(target: .agent(adapter: "agent:claude-code", connectionID: UUID())), "다른 연결")
        #expect(base != Self.ticket(chips: []), "칩이 바뀌었다")
        #expect(base != Self.ticket(chips: [AssistantChip(kind: .action, itemID: UUID(), origin: .added, title: "Other")]))
        #expect(base != Self.ticket(draft: "hello!"), "초안이 바뀌었다")
    }

    @Test func aDifferentAccountOrAFreshSessionGenerationIsADifferentTicket() {
        let user = UUID()
        let one = AccountScope.Token(userID: user, epoch: 1)
        #expect(Self.ticket(account: one) == Self.ticket(account: one))
        #expect(Self.ticket(account: one) != Self.ticket(account: AccountScope.Token(userID: UUID(), epoch: 1)), "계정이 바뀌었다")
        #expect(Self.ticket(account: one) != Self.ticket(account: AccountScope.Token(userID: user, epoch: 2)), "같은 계정의 새 세션 세대")
        #expect(Self.ticket(account: one) != Self.ticket(account: nil), "로그아웃")
    }

    @Test func theWindowModelFreezesItsOwnFactsIntoTheTicket() async {
        let host = AssistantWindowModelTests()
        let r = await host.rig()
        r.model.setDraft("hello")
        let token = AccountScope.Token(userID: UUID(), epoch: 3)
        let ticket = r.model.sendTicket(account: token)
        #expect(ticket == AgentSendTicket(
            account: token, windowID: r.model.id, conversationID: r.model.conversationID, hasSession: false, target: r.model.pick, chips: r.model.chips.chips, draft: "hello"
        ))
        r.model.setDraft("hello again")
        #expect(r.model.sendTicket(account: token) != ticket, "초안을 고치면 다른 표다")
        r.model.setDraft("hello")
        #expect(r.model.sendTicket(account: token) == ticket)
        r.model.chooseTarget(r.targets.options[r.targets.options.count - 1])
        #expect(r.model.sendTicket(account: token) != ticket, "대상을 바꿨다: \(r.model.targetName)")
        #expect(r.model.sendTicket(account: token).target.isAgent)
    }

    // MARK: 순서 (가짜 폴더 등록부 · 가짜 폴더 창)

    typealias Folders = AgentWorkspaceGateTests.FakeFolders
    typealias Picker = AgentWorkspaceGateTests.FakePicker

    private func gate(_ folders: Folders, _ picker: Picker) -> AgentWorkspaceSendGate {
        AgentWorkspaceSendGate(folders: folders, picker: picker, isThisMac: { _ in true })
    }

    @Test func aTicketThatStaysTheSameAsksRegistersAndProceeds() async {
        let folders = Folders()
        let picker = Picker()
        let outcome = await gate(folders, picker).prepare(
            conversationID: Self.conversation, hasSession: false, target: Self.agent, projects: [AgentWorkspaceGateTests.projectA], stillCurrent: { true }
        )
        #expect(outcome == .proceed && picker.asked.count == 1 && folders.registered == [.project(AgentWorkspaceGateTests.projectA.id)])
    }

    @Test func aChangeWhileTheServerIsReadMeansNoPanelAndNoRegistration() async {
        let folders = Folders()
        let picker = Picker()
        let outcome = await gate(folders, picker).prepare(
            conversationID: Self.conversation, hasSession: false, target: Self.agent, projects: [AgentWorkspaceGateTests.projectA], stillCurrent: { false }
        )
        #expect(outcome == .cancelled && picker.asked.isEmpty && folders.registered.isEmpty)
    }

    @Test func aChangeWhileThePanelIsOpenRegistersTheChosenFolderForNobody() async {
        let folders = Folders()
        let picker = Picker()
        picker.holds = true
        var changed = false
        let gate = gate(folders, picker)
        let prepare = Task { @MainActor in
            await gate.prepare(
                conversationID: Self.conversation, hasSession: false, target: Self.agent, projects: [AgentWorkspaceGateTests.projectA], stillCurrent: { !changed }
            )
        }
        for _ in 0..<1000 where picker.asked.isEmpty { await Task.yield() }
        #expect(picker.asked.count == 1, "창이 열려 있다")
        changed = true // 창을 기다리는 동안 대화를 바꿨다
        picker.release()
        #expect(await prepare.value == .cancelled)
        #expect(folders.registered.isEmpty, "옛 프로젝트에도 새 대화에도 등록하지 않는다")
    }

    @Test func aConversationThatNeedsNoPanelIsNotHeldUpByTheCheck() async {
        let folders = Folders()
        try? folders.register(path: "/Users/tester/Documents/client-a", scope: .project(AgentWorkspaceGateTests.projectA.id))
        let picker = Picker()
        let outcome = await gate(folders, picker).prepare(
            conversationID: Self.conversation, hasSession: false, target: Self.agent, projects: [AgentWorkspaceGateTests.projectA], stillCurrent: { false }
        )
        #expect(outcome == .proceed && picker.asked.isEmpty, "묻지 않을 일은 그대로 보낸다 (보내기 직전 확인은 보내는 쪽이 한다)")
    }
}
