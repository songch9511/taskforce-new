import Foundation
import Testing
import TaskforceKit
@testable import Taskforce

/// 폴더 창을 기다리는 동안 보내려던 곳이 바뀌면 보내지 않는다 (Astra P2-2, 코디네이터 13.11, 격리 호스트): 창이 눌렀을 때의 계정 · 창 · 대화 · 대상 · 칩 · 초안을 고정하고 등록 · 전송 직전에 다시 본다.
/// 폴더 창은 가짜 패널이고 서버는 가짜 게이트웨이다. 실제 `NSOpenPanel` · 서버 · `claude` 0
@MainActor
struct WorkspacePickerSendTests {
    @MainActor
    private struct Rig {
        let runtime: ChatRuntime
        let panel: WorkspacePickerTests.FakePanel
        let registry: WorkspaceRegistry
        let model: AssistantWindowModel
        let conversation: UUID
        let temp: URL
        let account: AppChatAccount

        func cleanup() { try? FileManager.default.removeItem(at: temp) }
        var turns: [ChatTurn] { runtime.chat.turns(for: conversation) }
    }

    private func rig() throws -> Rig {
        let temp = FileManager.default.temporaryDirectory.appending(path: "send-from-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = temp.appending(path: "home").path
        try FileManager.default.createDirectory(atPath: home + "/Documents/client-a", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appending(path: "p"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let registry = WorkspaceRegistry(file: temp.appending(path: "p/workspaces.json"), rules: WorkspaceFolderRules(home: home, systemRoots: []))
        let account = try AppChatAccount.make()
        let runtime = ChatRuntime(gateway: AgentChatSampleGateway(), contextGateway: IssueSampleContextGateway(), scope: account.scope, now: { Date() }, issueScreens: true)
        let panel = WorkspacePickerTests.FakePanel(choice: home + "/Documents/client-a")
        runtime.workspacePicker = panel
        runtime.workspaceAsking = { AgentWorkspaceAsking(folders: registry, isThisMac: { _ in true }) }
        let conversation = runtime.chat.reserveNewChat(target: .agent(adapter: "agent:claude-code", connectionID: UUID()), excluding: [])
        let model = AssistantWindowModel(conversationID: conversation, chat: runtime.chat, targets: runtime.targets)
        model.setDraft("ship it")
        return Rig(runtime: runtime, panel: panel, registry: registry, model: model, conversation: conversation, temp: temp, account: account)
    }

    /// 창이 열려 있는 동안 `change`를 하고 닫는다
    private func sendWhileThePanelIsOpen(_ r: Rig, change: @MainActor () -> Void) async {
        r.panel.holds = true
        let runtime = r.runtime
        let model = r.model
        let sending = Task { @MainActor in await runtime.sendFromWindow(model) }
        while r.panel.asked.isEmpty { await Task.yield() }
        change()
        r.panel.release()
        await sending.value
    }

    @Test func anUnchangedWindowAsksOnceRegistersTheFolderAndSendsTheDraft() async throws {
        let r = try rig()
        defer { r.cleanup() }
        #expect(r.model.toAgent && r.model.canSend)
        await r.runtime.sendFromWindow(r.model)
        #expect(r.panel.asked.count == 1)
        #expect(r.registry.pending(conversation: r.conversation) != nil, "고른 폴더가 이 대화에 적혔다")
        #expect(r.turns.count == 1 && r.model.draft.isEmpty, "보냈다")
    }

    @Test func aDraftEditedWhileThePanelIsOpenSendsNothingRegistersNothingAndKeepsTheDraft() async throws {
        let r = try rig()
        defer { r.cleanup() }
        await sendWhileThePanelIsOpen(r) { r.model.setDraft("something else entirely") }
        #expect(r.registry.pending(conversation: r.conversation) == nil && r.registry.projectFolders().isEmpty)
        #expect(r.turns.isEmpty, "다른 글을 옛 확인으로 보내지 않는다")
        #expect(r.model.draft == "something else entirely", "초안을 지우지 않는다")
    }

    @Test func aChipAddedWhileThePanelIsOpenSendsNothing() async throws {
        let r = try rig()
        defer { r.cleanup() }
        await sendWhileThePanelIsOpen(r) { r.model.addChip(AssistantChip(kind: .action, itemID: UUID(), origin: .added, title: "Pricing")) }
        #expect(r.registry.pending(conversation: r.conversation) == nil)
        #expect(r.turns.isEmpty && r.model.draft == "ship it")
    }

    @Test func aTargetChangedWhileThePanelIsOpenSendsNothing() async throws {
        let r = try rig()
        defer { r.cleanup() }
        await sendWhileThePanelIsOpen(r) { r.runtime.chat.setLocalTarget(.taskforce, for: r.conversation) }
        #expect(r.registry.pending(conversation: r.conversation) == nil)
        #expect(r.turns.isEmpty && r.model.draft == "ship it")
    }

    @Test func anAccountThatLeftWhileThePanelIsOpenSendsNothing() async throws {
        let r = try rig()
        defer { r.cleanup() }
        await sendWhileThePanelIsOpen(r) { r.runtime.scope.accountLeft() }
        #expect(r.registry.pending(conversation: r.conversation) == nil)
        #expect(r.turns.isEmpty)
    }
}
