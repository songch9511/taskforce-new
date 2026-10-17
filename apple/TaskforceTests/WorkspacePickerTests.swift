import Foundation
import Testing
import TaskforceKit
import TaskforceUI
@testable import Taskforce

/// 보내기 직전에 작업 폴더 묻기 (OA D4a2-05, 격리 호스트): 프로젝트 첫 보내기 → 창(가짜 패널) → 고름 → 보냄 1. 같은 프로젝트 두 번째 → 창 0. Ungrouped → 매번. 취소 → 보냄 0.
/// 다른 Mac 대상 → 창 0. 실제 `NSOpenPanel`을 열지 않는다: `ChatRuntime.workspacePicker`는 가짜 패널이다
@MainActor
struct WorkspacePickerTests {
    static let acme = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    /// 가짜 폴더 창: 정해 둔 폴더를 고르고, 거절될 폴더면 창 안 문구를 기록하고 취소로 돌아온다
    @MainActor
    final class FakePanel: AgentWorkspacePicking {
        var choice: String?
        private(set) var asked: [(message: String, prompt: String)] = []
        private(set) var rejections: [String] = []
        /// true면 창이 열린 채 `release()`까지 기다린다
        var holds = false
        private var released = false

        init(choice: String?) { self.choice = choice }

        func release() { released = true }

        func pickFolder(message: String, prompt: String, rejection: String, accepts: @escaping @Sendable (String) -> Bool) async -> String? {
            asked.append((message, prompt))
            var spins = 0
            while holds, !released, spins < 100_000 {
                spins += 1
                await Task.yield()
            }
            guard let choice else { return nil }
            guard accepts(choice) else {
                rejections.append(rejection)
                return nil
            }
            return choice
        }
    }

    private struct Rig {
        let runtime: ChatRuntime
        let panel: FakePanel
        let registry: WorkspaceRegistry
        let temp: URL
        let account: AppChatAccount
        let thisMac: HostBox<Bool>
        let present: HostBox<Bool>

        func cleanup() { try? FileManager.default.removeItem(at: temp) }
    }

    private func rig(choose: String? = "client-a") throws -> Rig {
        let temp = FileManager.default.temporaryDirectory.appending(path: "workspace-picker-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = temp.appending(path: "home").path
        for name in ["client-a", "client-b"] { try FileManager.default.createDirectory(atPath: home + "/Documents/" + name, withIntermediateDirectories: true) }
        let registry = WorkspaceRegistry(file: temp.appending(path: "p/workspaces.json"), rules: WorkspaceFolderRules(home: home, systemRoots: []))
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: AgentChatSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let panel = FakePanel(choice: choose.map { home + "/Documents/" + $0 })
        let thisMac = HostBox(true)
        let present = HostBox(true)
        runtime.workspacePicker = panel
        runtime.workspaceAsking = { present.value ? AgentWorkspaceAsking(folders: registry, isThisMac: { _ in thisMac.value }) : nil }
        return Rig(runtime: runtime, panel: panel, registry: registry, temp: temp, account: account, thisMac: thisMac, present: present)
    }

    private let agent = AssistantTargetPick.agent(adapter: "agent:claude-code", connectionID: UUID())

    private func projectChip(_ id: UUID = acme, title: String = "Acme") -> AssistantChip {
        AssistantChip(kind: .context, itemID: id, origin: .added, title: title)
    }

    @Test func theFirstSendOfAProjectAsksOnceRegistersTheFolderAndSendsThenTheNextSessionOfTheProjectAsksNothing() async throws {
        let r = try rig()
        defer { r.cleanup() }
        let first = await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: agent, chips: [projectChip()])
        #expect(first, "골랐으니 보낸다")
        #expect(r.panel.asked.count == 1 && r.panel.asked.first?.message == "Choose a folder for Acme" && r.panel.asked.first?.prompt == "Choose")
        #expect(r.registry.folder(forProject: Self.acme) != nil, "프로젝트에 폴더가 적혔다")
        let second = await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: agent, chips: [projectChip()])
        #expect(second && r.panel.asked.count == 1, "같은 프로젝트의 두 번째 세션은 창 0")
    }

    @Test func anUngroupedConversationAsksEveryTimeAndKeepsTheChoiceForThatConversation() async throws {
        let r = try rig()
        defer { r.cleanup() }
        let one = UUID()
        let two = UUID()
        #expect(await r.runtime.prepareAgentSend(conversationID: one, hasSession: false, target: agent, chips: []))
        #expect(await r.runtime.prepareAgentSend(conversationID: two, hasSession: false, target: agent, chips: []))
        #expect(r.panel.asked.map(\.message) == ["Choose a folder for this session", "Choose a folder for this session"])
        #expect(r.registry.pending(conversation: one) != nil && r.registry.pending(conversation: two) != nil)
    }

    @Test func cancellingTheFolderPanelDoesNotSendAndWritesNothing() async throws {
        let r = try rig(choose: nil)
        defer { r.cleanup() }
        let sent = await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: agent, chips: [projectChip()])
        #expect(!sent, "취소하면 보내지 않는다 (글은 입력 칸에 그대로 둔다)")
        #expect(r.panel.asked.count == 1 && r.registry.projectFolders().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: r.registry.file.path))
    }

    @Test func aRejectedFolderShowsTheApprovedSentenceInsideThePanelAndSendsNothing() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.panel.choice = r.temp.appending(path: "home").path // 홈 자체: 거절
        let sent = await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: agent, chips: [projectChip()])
        #expect(!sent)
        #expect(r.panel.rejections == ["Choose a folder inside your home folder or on an external drive."])
        #expect(r.registry.projectFolders().isEmpty)
    }

    @Test func aTargetOnAnotherMacOrAnExistingSessionOrTaskforceOrNoBridgeNeverOpensThePanel() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.thisMac.value = false
        #expect(await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: agent, chips: [projectChip()]), "다른 Mac 대상: 그 Mac이 정한다")
        r.thisMac.value = true
        #expect(await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: true, target: agent, chips: [projectChip()]))
        #expect(await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: .taskforce, chips: [projectChip()]))
        r.present.value = false
        #expect(await r.runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: agent, chips: [projectChip()]), "bridge가 꺼졌으면 묻지 않는다")
        #expect(r.panel.asked.isEmpty)
    }

    @Test func pressingSendWhileThePanelIsOpenSendsNothingAndOpensNoSecondPanel() async throws {
        let r = try rig()
        defer { r.cleanup() }
        r.panel.holds = true
        let runtime = r.runtime
        let target = agent
        let chip = projectChip()
        let first = Task { @MainActor in await runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: target, chips: [chip]) }
        while r.panel.asked.isEmpty { await Task.yield() }
        // 창이 떠 있는 동안 다시 보내기를 누른다
        let second = await runtime.prepareAgentSend(conversationID: UUID(), hasSession: false, target: target, chips: [chip])
        #expect(!second, "이미 묻는 중이면 보내지 않는다")
        #expect(r.panel.asked.count == 1)
        r.panel.release()
        #expect(await first.value, "첫 보내기는 고른 뒤 보낸다")
    }
}
