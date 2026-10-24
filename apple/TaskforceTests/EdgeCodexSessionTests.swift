import Foundation
import Testing
@testable import Taskforce
@testable import TaskforceKit

@MainActor
struct EdgeCodexSessionTests {
    private func session(_ n: Int) -> CodexLocalSession {
        CodexLocalSession(id: EdgeSessionsTests.id(n), title: "Codex \(n)", updatedAt: Date())
    }

    @Test func codexPrimaryRouteStaysNativeAndDoesNotUseClaude() {
        let rig = EdgeExternalSessionsTests().make()
        rig.shell.openSessions()
        rig.shell.openCodexSession(session(1))
        #expect(rig.shell.codexPanelShown)
        #expect(rig.shell.codexPanelSession?.id == session(1).id)
        #expect(rig.shell.desktopPanelID == nil)
        #expect(rig.shell.desktopConversation == nil)
        #expect(rig.shell.sessionPanelID == nil)
        rig.shell.openCodexSession(session(1))
        #expect(!rig.shell.codexPanelShown)
    }

    @Test func codexCloseNavigationAndLogoutResetPresentation() {
        let rig = EdgeExternalSessionsTests().make()
        var resets = 0
        rig.shell.onResetCodexPresentation = { resets += 1 }
        rig.shell.openSessions()
        rig.shell.openCodexSession(session(1))
        let opened = resets
        rig.shell.dismiss()
        #expect(resets > opened)
        #expect(!rig.shell.codexPanelShown)
        rig.shell.openSessions()
        rig.shell.openCodexSession(session(2))
        rig.shell.accountChanged(nil)
        #expect(rig.shell.codexPanelSession == nil)
        #expect(!rig.shell.codexPanelShown)
    }

    @Test func codexEscapeClosesChildBeforeSession() {
        let rig = EdgeExternalSessionsTests().make()
        rig.shell.openSessions()
        rig.shell.openCodexSession(session(1))
        rig.shell.onEscapeCodexPane = { true }
        rig.shell.escape()
        #expect(rig.shell.codexPanelShown)
        rig.shell.onEscapeCodexPane = { false }
        rig.shell.escape()
        #expect(!rig.shell.codexPanelShown)
        #expect(rig.shell.panelOpen)
    }

    @Test func snapshotCreatesRealTreeAndSelectionNeverUsesRootBody() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "codex:test")
        let model = CodexSessionPanelModel()
        var tasks = BackgroundTaskList()
        tasks.apply(.started(taskID: "child", toolUseID: nil, kind: .agent, name: "Child", at: nil))
        let snapshot = CodexSessionSnapshot(turns: [], tasks: tasks, hasEarlier: false)
        model.start("root", pane: pane) { .snapshot(snapshot) }
        for _ in 0..<100 where !pane.hasAgentTree { await Task.yield() }
        #expect(pane.hasAgentTree)
        #expect(pane.showsTree)
        pane.openAgentChat("child")
        #expect(pane.selectedID == "child")
        #expect(!pane.allowsRootInput)
        pane.openRootChat()
        #expect(!pane.showsTree)
        #expect(pane.allowsRootInput)
        pane.returnToTree()
        #expect(pane.showsTree)
        model.stop()
        #expect(model.sessionID == nil)
        #expect(model.turns.isEmpty)
    }

    @Test func stoppedReadCannotRestoreOldSession() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        let model = CodexSessionPanelModel()
        let gate = SnapshotGate()
        model.start("old", pane: pane) { await gate.read() }
        for _ in 0..<100 {
            if await gate.started { break }
            await Task.yield()
        }
        model.stop()
        await gate.finish()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.sessionID == nil)
        #expect(model.turns.isEmpty)
        #expect(!model.failed)
    }

    @Test func boundedChildTailKeepsTranscriptDuringRefreshAndDisablesUnimplementedPaging() async {
        let tail = BackgroundTaskTailModel(taskID: "child", limits: .init(tailBytes: 2 << 20, maxTailBytes: 2 << 20),
                                           read: { _ in .output(.agent([ClaudeAppTurn(id: "reply", kind: .assistant("Child reply"))], hasEarlier: true)) })
        #expect(!tail.canLoadEarlier)
        await tail.readOnce()
        let shown = tail.state
        await tail.readOnce()
        #expect(tail.state == shown)
        #expect(tail.state != .loading)
        tail.showEarlier()
        #expect(tail.window == 2 << 20)
        tail.stop()
    }

    @Test func rootComposerSendsToSameSessionAndClearsAcceptedDraft() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        let chat = CodexSessionChatModel()
        let gate = SendGate()
        chat.start("root", send: { try await gate.send($0, $1) })
        chat.draft = "  Continue here  "
        let request = chat.submitRoot(pane: pane)
        await gate.waitUntilStarted()
        #expect(chat.isSending)
        #expect(chat.draft == "  Continue here  ")
        #expect(await gate.thread == "root")
        #expect(await gate.text == "Continue here")
        #expect(chat.submitRoot(pane: pane) == nil)
        await gate.finish()
        await request?.value
        #expect(chat.draft.isEmpty)
        #expect(!chat.isSending)
        chat.stop()
    }

    @Test func childComposerSendsContextToRootThenSelectsMain() async throws {
        let pane = childPane()
        let child = try #require(pane.tasks.tasks.first)
        let chat = CodexSessionChatModel()
        let gate = SendGate()
        chat.start("root", send: { try await gate.send($0, $1) })
        chat.setChildDraft("Continue this task", for: child.id)
        let request = chat.submitChild(child, pane: pane)
        await gate.waitUntilStarted()
        #expect(await gate.thread == "root")
        #expect(await gate.text == AgentTreeContextMessage.make(task: child, text: "Continue this task"))
        #expect(pane.selectedID == child.id)
        await gate.finish()
        await request?.value
        #expect(pane.selectedID == nil)
        #expect(pane.showsTree)
        #expect(chat.childDraft(for: child.id).isEmpty)
        chat.stop()
    }

    @Test func rejectedChildMessageKeepsDraftAndSelection() async throws {
        let pane = childPane()
        let child = try #require(pane.tasks.tasks.first)
        let chat = CodexSessionChatModel()
        chat.start("root", send: { _, _ in throw CodexChatSendError.rejected })
        chat.setChildDraft("Keep this", for: child.id)
        await chat.submitChild(child, pane: pane)?.value
        #expect(chat.childDraft(for: child.id) == "Keep this")
        #expect(pane.selectedID == child.id)
        #expect(chat.errorMessage != nil)
        #expect(!chat.isSending)
        chat.stop()
    }

    @Test func acceptedSendDoesNotEraseNewerDraft() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        let chat = CodexSessionChatModel()
        let gate = SendGate()
        chat.start("root", send: { try await gate.send($0, $1) })
        chat.draft = "First"
        let request = chat.submitRoot(pane: pane)
        await gate.waitUntilStarted()
        chat.draft = "Next"
        await gate.finish()
        await request?.value
        #expect(chat.draft == "Next")
        chat.stop()
    }

    @Test func stoppedSendCannotChangeNewSessionOrDraft() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        let chat = CodexSessionChatModel()
        let gate = SendGate()
        chat.start("old", send: { try await gate.send($0, $1) })
        chat.draft = "Old"
        let request = chat.submitRoot(pane: pane)
        await gate.waitUntilStarted()
        chat.stop()
        chat.start("new", send: { _, _ in CodexChatReceipt(threadID: "managed", turnID: "turn") })
        chat.draft = "New"
        await gate.finish(error: .deliveryUnknown)
        await request?.value
        #expect(chat.sessionID == "new")
        #expect(chat.draft == "New")
        #expect(chat.errorMessage == nil)
        #expect(!chat.isSending)
        chat.stop()
    }

    @Test func childAcceptanceDoesNotEraseEditedDraftOrChangeAnotherSelection() async throws {
        let pane = childPane()
        let child = try #require(pane.tasks.tasks.first)
        let chat = CodexSessionChatModel()
        let gate = SendGate()
        chat.start("root", send: { try await gate.send($0, $1) })
        chat.setChildDraft("First", for: child.id)
        let request = chat.submitChild(child, pane: pane)
        await gate.waitUntilStarted()
        chat.setChildDraft("Follow up", for: child.id)
        pane.tasks.apply(.started(taskID: "other", toolUseID: nil, kind: .agent, name: "Other", at: nil))
        pane.openAgentChat("other")
        await gate.finish()
        await request?.value
        #expect(chat.childDraft(for: child.id) == "Follow up")
        #expect(pane.selectedID == "other")
        chat.stop()
    }

    @Test func unknownDeliveryRetainsRootDraftWithoutRetrying() async {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        let chat = CodexSessionChatModel()
        let gate = SendGate()
        chat.start("root", send: { try await gate.send($0, $1) })
        chat.draft = "Keep until confirmed"
        let request = chat.submitRoot(pane: pane)
        await gate.waitUntilStarted()
        await gate.finish(error: .deliveryUnknown)
        await request?.value
        #expect(chat.draft == "Keep until confirmed")
        #expect(chat.errorMessage?.contains("Check the conversation") == true)
        #expect(!chat.isSending)
        chat.stop()
    }

    @Test func managedContinuationPersistsAcrossPanelDetachButStopsOnAccountChange() throws {
        let suite = "CodexChatRuntimeTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = CodexChatRuntime(defaults: defaults)
        let account = UUID()
        let source = EdgeSessionsTests.id(1)
        let managed = EdgeSessionsTests.id(2)
        runtime.adopt(account)
        let chat = try #require(runtime.chat(sourceID: source))
        chat.draft = "Keep while panel closes"
        chat.receive(.managedThread(managed))
        let presentation = EdgeClaudeAppPanelPresentation()
        presentation.codexChat = chat
        presentation.reset()
        #expect(runtime.chat(sourceID: source) === chat)
        #expect(chat.draft == "Keep while panel closes")
        runtime.adopt(nil)
        #expect(chat.sessionID == nil)
        #expect(chat.draft.isEmpty)
        #expect(runtime.chat(sourceID: source) == nil)
        runtime.adopt(account)
        #expect(runtime.chat(sourceID: source)?.managedThreadID == managed)
        runtime.adopt(UUID())
        #expect(runtime.chat(sourceID: source)?.managedThreadID == nil)
        runtime.stop()
    }

    @Test func managedListDuplicatesAreFilteredOnlyForTheirAccountAndValidSource() throws {
        let suite = "CodexManagedListTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = UUID()
        let source = EdgeSessionsTests.id(1)
        let managed = EdgeSessionsTests.id(2)
        let runtime = CodexChatRuntime(defaults: defaults)
        runtime.adopt(account)
        defaults.set(managed, forKey: "codex-managed-thread.\(account.uuidString).\(source)")
        #expect(runtime.isManagedThread(managed))
        #expect(!runtime.isManagedThread(source))
        runtime.adopt(UUID())
        #expect(!runtime.isManagedThread(managed))
        runtime.adopt(account)
        defaults.removeObject(forKey: "codex-managed-thread.\(account.uuidString).\(source)")
        defaults.set(managed, forKey: "codex-managed-thread.\(account.uuidString).invalid")
        #expect(!runtime.isManagedThread(managed))
        defaults.set(managed, forKey: "codex-managed-thread.\(account.uuidString).\(managed)")
        #expect(!runtime.isManagedThread(managed))
        runtime.stop()
    }

    @Test func approvalsRemainSeparateUntilResolvedAndCompletionClearsThem() {
        let chat = CodexSessionChatModel()
        chat.start("root", send: { _, _ in CodexChatReceipt(threadID: "managed", turnID: "turn") })
        chat.receive(.approval(id: "request1", kind: "command", summary: "Command"))
        chat.receive(.approval(id: "request2", kind: "file", summary: "File change"))
        #expect(chat.requests.map(\.id) == ["request1", "request2"])
        chat.receive(.requestResolved(id: "request1"))
        #expect(chat.requests.map(\.id) == ["request2"])
        chat.receive(.turnCompleted(threadID: "managed", turnID: "turn"))
        #expect(chat.requests.isEmpty)
        #expect(!chat.isRunning)
        chat.stop()
    }

    private func childPane() -> SessionSidePaneModel {
        let pane = SessionSidePaneModel(store: InMemoryBackgroundTaskOpenStore())
        pane.usesAgentCanvas = true
        pane.attach(session: "codex:root")
        pane.tasks.apply(.started(taskID: "child", toolUseID: nil, kind: .agent, name: "Child", at: nil))
        pane.openAgentChat("child")
        return pane
    }

    actor SendGate {
        var thread: String?
        var text: String?
        private var continuation: CheckedContinuation<CodexChatReceipt, any Error>?
        func send(_ thread: String, _ text: String) async throws -> CodexChatReceipt {
            self.thread = thread
            self.text = text
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func waitUntilStarted() async {
            for _ in 0..<1000 where continuation == nil { await Task.yield() }
        }
        func finish(error: CodexChatSendError? = nil) {
            if let error { continuation?.resume(throwing: error) }
            else { continuation?.resume(returning: CodexChatReceipt(threadID: "managed", turnID: "turn")) }
            continuation = nil
        }
    }

    actor SnapshotGate {
        private var continuation: CheckedContinuation<CodexLocalSessionReader.SnapshotResult, Never>?
        var started: Bool { continuation != nil }
        func read() async -> CodexLocalSessionReader.SnapshotResult {
            await withCheckedContinuation { continuation = $0 }
        }
        func finish() {
            continuation?.resume(returning: .unreadable)
            continuation = nil
        }
    }
}
