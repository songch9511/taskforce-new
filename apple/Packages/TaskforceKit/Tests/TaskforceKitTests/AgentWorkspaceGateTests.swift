#if os(macOS) && DEBUG
import Foundation
import Testing
@testable import TaskforceKit

/// 처음 한 번 묻기의 규칙과 순서 (OA D4a2-05, 계약 13.6 "처음 묻기"): 프로젝트 첫 보내기 → 창 → 고름 → 보냄. 같은 프로젝트 두 번째 → 창 0. Ungrouped → 매번. 취소 → 보냄 0. 다른 Mac 대상 → 창 0
struct AgentWorkspaceGateTests {
    typealias Gate = AgentWorkspaceGate
    static let projectA = Gate.Project(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, name: "Acme")
    static let projectB = Gate.Project(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, name: "Beta")

    static func facts(
        session: Bool = false, agent: Bool = true, thisMac: Bool = true, projects: [Gate.Project] = [], withFolder: Set<UUID> = [], conversationFolder: Bool = false,
        conversation: UUID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    ) -> Gate.Facts {
        Gate.Facts(
            conversationID: conversation, conversationHasSession: session, targetIsAgent: agent, targetIsThisMac: thisMac, projects: projects, projectsWithFolder: withFolder,
            conversationHasFolder: conversationFolder
        )
    }

    // MARK: 승인된 문구

    @Test func theApprovedCopyIsExactlyWhatTheUserApproved() {
        #expect(AgentWorkspaceCopy.chooseFolder(forProject: "Acme") == "Choose a folder for Acme")
        #expect(AgentWorkspaceCopy.chooseFolderForSession == "Choose a folder for this session")
        #expect(AgentWorkspaceCopy.choose == "Choose")
        #expect(AgentWorkspaceCopy.rejected == "Choose a folder inside your home folder or on an external drive.")
    }

    /// 대화 머리의 폴더 메뉴 (사용자 승인 2026-10-22): 메뉴 두 줄과 컨트롤의 접근성 이름. 폴더 창의 문구는 위 승인된 "Choose a folder for this session" · "Choose"를 그대로 쓴다
    @Test func theFolderMenuCopyIsExactlyWhatTheUserApproved() {
        #expect(AgentWorkspaceCopy.newChatInAnotherFolder == "New chat in another folder…")
        #expect(AgentWorkspaceCopy.showInFinder == "Show in Finder", "macOS 표준 문구")
        #expect(AgentWorkspaceCopy.folderControl == "Folder")
    }

    // MARK: 규칙

    /// 대화 머리의 "다른 폴더로 새 대화"가 이 대화에 폴더를 적어 준다 — 그 뒤에 프로젝트 칩이 더해져도(폴더 없는 프로젝트) 또 묻지 않는다.
    /// 세션을 정하는 순서(resolver)도 대화 폴더가 프로젝트보다 먼저라, 프로젝트의 폴더를 묻는 것은 쓰이지도 않을 질문이다
    @Test func aConversationThatAlreadyChoseItsFolderNeverAsksForAProjectsFolder() {
        #expect(Gate.decide(Self.facts(projects: [Self.projectA], conversationFolder: true)) == .send)
        #expect(Gate.decide(Self.facts(projects: [Self.projectA, Self.projectB], conversationFolder: true)) == .send)
        // 대화가 고른 폴더가 없으면 지금처럼 프로젝트의 폴더를 묻는다
        #expect(Gate.decide(Self.facts(projects: [Self.projectA], conversationFolder: false)) == .ask(Gate.Ask(scope: .project(Self.projectA.id), message: "Choose a folder for Acme", prompt: "Choose")))
    }

    @Test func aProjectWithoutAFolderAsksOnTheFirstSendOfANewSession() {
        let decision = Gate.decide(Self.facts(projects: [Self.projectA]))
        #expect(decision == .ask(Gate.Ask(scope: .project(Self.projectA.id), message: "Choose a folder for Acme", prompt: "Choose")))
    }

    @Test func aProjectThatHasAFolderNeverAsksAgain() {
        #expect(Gate.decide(Self.facts(projects: [Self.projectA], withFolder: [Self.projectA.id])) == .send)
    }

    @Test func anUngroupedConversationAsksForThisSessionUnlessItAlreadyChoseOne() {
        let conversation = UUID()
        #expect(Gate.decide(Self.facts(conversation: conversation)) == .ask(Gate.Ask(scope: .conversation(conversation), message: "Choose a folder for this session", prompt: "Choose")))
        #expect(Gate.decide(Self.facts(conversationFolder: true, conversation: conversation)) == .send)
    }

    @Test func nothingIsAskedWhenTheSessionExistsOrTheTargetIsNotAnAgentOrAnotherMac() {
        #expect(Gate.decide(Self.facts(session: true, projects: [Self.projectA])) == .send)
        #expect(Gate.decide(Self.facts(agent: false, projects: [Self.projectA])) == .send)
        #expect(Gate.decide(Self.facts(thisMac: false, projects: [Self.projectA])) == .send, "다른 Mac이 정한다")
        #expect(Gate.decide(Self.facts(session: true)) == .send)
    }

    @Test func severalProjectsAskOnlyWhenNoneHasAFolderAndTheFirstByNameIsAsked() {
        let both = [Self.projectA, Self.projectB]
        #expect(Gate.decide(Self.facts(projects: both, withFolder: [Self.projectB.id])) == .send)
        guard case .ask(let ask) = Gate.decide(Self.facts(projects: both)) else {
            Issue.record("물어야 한다")
            return
        }
        #expect(ask.scope == .project(Self.projectA.id))
    }

    // MARK: 보내는 글의 프로젝트

    private func chip(_ kind: ChatAttachmentKind, id: UUID, origin: ChatAttachmentOrigin = .added, title: String = "t") -> AssistantChip {
        AssistantChip(kind: kind, itemID: id, origin: origin, title: title)
    }

    private func index(action: UUID, in projects: [(WorkProject, ContextMemberOrigin)]) -> WorkMembershipIndex {
        WorkMembershipIndex(
            contexts: projects.map { WorkContext(id: $0.0.id, name: $0.0.name) },
            members: projects.map { ContextMember(id: UUID(), contextID: $0.0.id, actionID: action, origin: $0.1) }
        )
    }

    @Test func oneAddedIssueChipTakesTheConfirmedProjectsOfThatIssue() {
        let action = UUID()
        let acme = WorkProject(id: Self.projectA.id, name: "Acme")
        let beta = WorkProject(id: Self.projectB.id, name: "Beta")
        let found = Gate.projects(chips: [chip(.action, id: action)], index: index(action: action, in: [(beta, .user), (acme, .auto)]))
        #expect(found == [Self.projectA, Self.projectB], "이름 순")
        // 모델 후보(inferred)는 프로젝트가 아니다
        let guessed = Gate.projects(chips: [chip(.action, id: action)], index: index(action: action, in: [(acme, .inferred)]))
        #expect(guessed.isEmpty)
    }

    @Test func autoChipsAreNotSentSoTheyDecideNothing() {
        let action = UUID()
        let acme = WorkProject(id: Self.projectA.id, name: "Acme")
        #expect(Gate.projects(chips: [chip(.action, id: action, origin: .auto)], index: index(action: action, in: [(acme, .user)])).isEmpty)
    }

    @Test func severalIssueChipsLeaveTheProjectUnknownBecauseAReferentPickComesNext() {
        let first = UUID()
        let second = UUID()
        let acme = WorkProject(id: Self.projectA.id, name: "Acme")
        let chips = [chip(.action, id: first), chip(.action, id: second)]
        #expect(Gate.projects(chips: chips, index: index(action: first, in: [(acme, .user)])).isEmpty)
        // 프로젝트 칩이 있어도 이슈 칩이 우선이다 (서버가 새 이슈를 만들지 않는다)
        #expect(Gate.projects(chips: chips + [chip(.context, id: Self.projectB.id, title: "Beta")], index: nil).isEmpty)
    }

    @Test func aSingleProjectChipWithoutIssuesIsTheProjectTheServerPutsTheNewIssueIn() {
        #expect(Gate.projects(chips: [chip(.context, id: Self.projectB.id, title: "Beta")], index: nil) == [Self.projectB])
        #expect(Gate.projects(chips: [chip(.context, id: Self.projectA.id), chip(.context, id: Self.projectB.id)], index: nil).isEmpty, "프로젝트 칩이 여럿이면 서버는 어느 프로젝트에도 넣지 않는다")
        #expect(Gate.projects(chips: [], index: nil).isEmpty)
    }

    @Test func anIssueWhoseMembershipIsNotReadYetIsTreatedAsUngrouped() {
        #expect(Gate.projects(chips: [chip(.action, id: UUID())], index: .unknown).isEmpty)
        #expect(Gate.projects(chips: [chip(.action, id: UUID())], index: nil).isEmpty)
    }

    // MARK: 순서 (가짜 폴더 등록부 · 가짜 폴더 창)

    final class FakeFolders: AgentWorkspaceFolders, @unchecked Sendable {
        struct Rejected: Error {}
        private let lock = NSLock()
        private var projects: Set<UUID> = []
        private var conversations: Set<UUID> = []
        var acceptsAnything = true
        private(set) var registered: [Gate.Scope] = []
        func hasFolder(forProject id: UUID) -> Bool { lock.withLock { projects.contains(id) } }
        func hasFolder(forConversation id: UUID) -> Bool { lock.withLock { conversations.contains(id) } }
        func accepts(path: String) -> Bool { acceptsAnything }
        func register(path: String, scope: Gate.Scope) throws {
            guard acceptsAnything else { throw Rejected() }
            lock.withLock {
                registered.append(scope)
                switch scope {
                case .project(let id): projects.insert(id)
                case .conversation(let id): conversations.insert(id)
                }
            }
        }
    }

    @MainActor
    final class FakePicker: AgentWorkspacePicking {
        var choice: String? = "/Users/tester/Documents/client-a"
        private(set) var asked: [(message: String, prompt: String, rejection: String)] = []
        /// true면 창이 열린 채 `release()`까지 기다린다 (두 번 눌러도 한 창). 기다림에는 상한이 있다: 막이 없을 때 시험이 멈추지 않고 실패한다
        var holds = false
        private var released = false

        func release() { released = true }

        func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String? {
            asked.append((message, prompt, rejection))
            var spins = 0
            while holds, !released, spins < 100_000 {
                spins += 1
                await Task.yield()
            }
            return choice
        }
    }

    @MainActor
    private func gate(_ folders: FakeFolders, _ picker: FakePicker, thisMac: Bool = true, calls: Locked<Int> = Locked(0)) -> AgentWorkspaceSendGate {
        AgentWorkspaceSendGate(folders: folders, picker: picker, isThisMac: { _ in calls.set(calls.get() + 1); return thisMac })
    }

    private let agent = AssistantTargetPick.agent(adapter: "agent:claude-code", connectionID: UUID())

    @MainActor
    @Test func theFirstSendOfAProjectAsksOnceRegistersAndProceedsThenTheNextSessionDoesNotAsk() async {
        let folders = FakeFolders()
        let picker = FakePicker()
        let gate = gate(folders, picker)
        let first = await gate.prepare(conversationID: UUID(), hasSession: false, target: agent, projects: [Self.projectA])
        #expect(first == .proceed && picker.asked.count == 1)
        #expect(picker.asked.first?.message == "Choose a folder for Acme" && picker.asked.first?.prompt == "Choose")
        #expect(picker.asked.first?.rejection == "Choose a folder inside your home folder or on an external drive.")
        #expect(folders.registered == [.project(Self.projectA.id)])
        let second = await gate.prepare(conversationID: UUID(), hasSession: false, target: agent, projects: [Self.projectA])
        #expect(second == .proceed && picker.asked.count == 1, "같은 프로젝트의 다음 세션은 창 0")
    }

    @MainActor
    @Test func anUngroupedConversationAsksEveryNewConversation() async {
        let folders = FakeFolders()
        let picker = FakePicker()
        let gate = gate(folders, picker)
        let one = UUID()
        let two = UUID()
        #expect(await gate.prepare(conversationID: one, hasSession: false, target: agent, projects: []) == .proceed)
        #expect(await gate.prepare(conversationID: two, hasSession: false, target: agent, projects: []) == .proceed)
        #expect(picker.asked.map(\.message) == ["Choose a folder for this session", "Choose a folder for this session"])
        #expect(folders.registered == [.conversation(one), .conversation(two)])
        // 같은 대화의 다시 보내기(첫 보내기가 실패했다)는 이미 고른 폴더를 쓴다
        let again = await gate.prepare(conversationID: one, hasSession: false, target: agent, projects: [])
        #expect(again == .proceed && picker.asked.count == 2)
    }

    @MainActor
    @Test func cancellingTheFolderPanelSendsNothingAndRegistersNothing() async {
        let folders = FakeFolders()
        let picker = FakePicker()
        picker.choice = nil
        let outcome = await gate(folders, picker).prepare(conversationID: UUID(), hasSession: false, target: agent, projects: [Self.projectA])
        #expect(outcome == .cancelled && folders.registered.isEmpty)
    }

    @MainActor
    @Test func aFolderTheRegistryRejectsAfterThePickDoesNotSend() async {
        let folders = FakeFolders()
        folders.acceptsAnything = false
        let outcome = await gate(folders, FakePicker()).prepare(conversationID: UUID(), hasSession: false, target: agent, projects: [Self.projectA])
        #expect(outcome == .cancelled)
    }

    @MainActor
    @Test func aTargetOnAnotherMacOrWithoutAConnectionOrWithASessionNeverOpensThePanel() async {
        let folders = FakeFolders()
        let picker = FakePicker()
        let calls = Locked(0)
        let otherMac = gate(folders, picker, thisMac: false, calls: calls)
        #expect(await otherMac.prepare(conversationID: UUID(), hasSession: false, target: agent, projects: [Self.projectA]) == .proceed)
        #expect(calls.get() == 1, "묻게 될 때만 이 Mac인지 확인한다")
        let mine = gate(folders, picker, calls: calls)
        #expect(await mine.prepare(conversationID: UUID(), hasSession: true, target: agent, projects: [Self.projectA]) == .proceed)
        #expect(await mine.prepare(conversationID: UUID(), hasSession: false, target: .taskforce, projects: [Self.projectA]) == .proceed)
        #expect(await mine.prepare(conversationID: UUID(), hasSession: false, target: .agent(adapter: "agent:claude-code", connectionID: nil), projects: [Self.projectA]) == .proceed)
        #expect(calls.get() == 1, "세션이 있거나 Taskforce 대상이면 서버를 읽지 않는다")
        #expect(picker.asked.isEmpty && folders.registered.isEmpty)
    }

    @MainActor
    @Test func pressingSendAgainWhileThePanelIsOpenDoesNotOpenASecondPanelNorSend() async {
        let folders = FakeFolders()
        let picker = FakePicker()
        picker.holds = true
        let gate = gate(folders, picker)
        let conversation = UUID()
        let first = Task { await gate.prepare(conversationID: conversation, hasSession: false, target: agent, projects: [Self.projectA]) }
        while picker.asked.isEmpty { await Task.yield() }
        let second = await gate.prepare(conversationID: conversation, hasSession: false, target: agent, projects: [Self.projectA])
        #expect(second == .cancelled && picker.asked.count == 1)
        picker.release()
        #expect(await first.value == .proceed)
    }
}
#endif
