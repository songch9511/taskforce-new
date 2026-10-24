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
