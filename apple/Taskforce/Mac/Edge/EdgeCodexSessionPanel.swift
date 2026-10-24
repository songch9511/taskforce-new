#if os(macOS)
import AppKit
import SwiftUI
import TaskforceKit
import TaskforceUI

/// Local Codex history polling. It never uses Claude's relay or desktop metrics.
@MainActor
@Observable
final class CodexSessionPanelModel {
    private(set) var sessionID: String?
    private(set) var turns: [ClaudeAppTurn] = []
    private(set) var failed = false
    private(set) var hasEarlier = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loop: Task<Void, Never>?

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        sessionID = nil
        turns = []
        failed = false
        hasEarlier = false
    }

    func start(_ id: String, pane: SessionSidePaneModel,
               read: @escaping @Sendable () async -> CodexLocalSessionReader.SnapshotResult) {
        stop()
        sessionID = id
        let token = generation
        loop = Task { [weak self, weak pane] in
            while !Task.isCancelled {
                let result = await read()
                guard !Task.isCancelled, let self, let pane, self.generation == token else { return }
                switch result {
                case .snapshot(let snapshot):
                    self.turns = snapshot.turns
                    self.hasEarlier = snapshot.hasEarlier
                    self.failed = false
                    pane.tasks = snapshot.tasks
                    // Codex statuses are deliberately unknown; refresh an open tail independently.
                    await pane.tail?.readOnce()
                case .unreadable:
                    self.turns = []
                    self.failed = true
                    pane.returnToTree()
                    pane.tasks = BackgroundTaskList()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct CodexSessionPanelView: View {
    @Bindable var shell: EdgeShellModel
    @Bindable var presentation: EdgeClaudeAppPanelPresentation
    @State private var openFailed = false
    private let reader = CodexLocalSessionReader()

    private var visibleID: String? { shell.codexPanelShown ? shell.codexPanelSession?.id : nil }

    var body: some View {
        SessionPanelFrame(pane: presentation.pane, reduceMotion: shell.reduceMotion,
                          root: shell.codexPanelSession.map { AgentTreeRoot(title: $0.title, agent: .codex) },
                          childComposer: { task in AnyView(contextComposer(task)) }) { width in
            VStack(spacing: 0) {
                if let session = shell.codexPanelSession {
                    PanelHeader(title: session.title, agent: .codex,
                                pill: PanelHeaderPill(title: "Open in Codex") { openInCodex(presentation.codexChat.managedThreadID ?? session.id) },
                                status: "Managed by Taskforce · Continued from Codex")
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.headHeight = $0 }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if presentation.codex.sessionID == session.id {
                                if presentation.codex.failed {
                                    PanelEmptyState(title: "Couldn’t load this chat") {
                                        Button("Try again") { begin(session.id) }.buttonStyle(TFButtonStyle(.secondary, size: .md))
                                    }
                                } else {
                                    if presentation.codex.hasEarlier {
                                        Text("Showing recent messages. Open in Codex for the full conversation.")
                                            .font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
                                    }
                                    ForEach(presentation.codex.turns) { turn in ClaudeAppTurnView(turn: turn) }
                                }
                            }
                        }
                        .padding(TFSpace.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.bodyHeight = $0 }
                    }
                    .defaultScrollAnchor(.bottom)
                    if presentation.pane.allowsRootInput { rootComposer }
                    if openFailed { Text("Couldn’t open Codex.").font(TFFont.footnote).padding(TFSpace.lg) }
                }
            }
            .frame(width: width).frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: presentation.codexChat.managedThreadID) { _, _ in
            guard let id = visibleID else { return }
            beginReading(id)
        }
        .onChange(of: visibleID, initial: true) { _, id in
            presentation.reset()
            openFailed = false
            guard let id, SessionsPanelBody.readsLiveCodexSessions else { return }
            begin(id)
        }
    }

    private func begin(_ id: String) {
        presentation.beginSession("codex:" + id)
        guard let chat = shell.codexChatRuntime.chat(sourceID: id) else { return }
        presentation.codexChat = chat
        beginReading(id)
    }

    private func beginReading(_ id: String) {
        let reader = reader
        let historyID = presentation.codexChat.managedThreadID ?? id
        presentation.pane.makeTail = { task in
            BackgroundTaskTailModel(taskID: task.id, limits: .init(tailBytes: 2 << 20, maxTailBytes: 2 << 20), read: { _ in reader.tail(sessionID: task.id, rootSessionID: historyID, contextRootSessionID: id) })
        }
        presentation.codex.start(id, pane: presentation.pane) { await reader.snapshot(sessionID: historyID, contextSessionID: id) }
    }

    private func openInCodex(_ id: String) {
        guard ExternalSessionRules.isCanonicalUUID(id), let url = URL(string: "codex://threads/\(id)") else { return }
        openFailed = !NSWorkspace.shared.open(url)
    }

    private var rootComposer: some View {
        VStack(alignment: .leading, spacing: TFSpace.sm) {
            deliveryError
            activityStatus
            CodexChatPromptsView(chat: presentation.codexChat)
            Composer(
                text: Binding(get: { presentation.codexChat.draft }, set: {
                    if presentation.pane.allowsRootInput { presentation.codexChat.draft = $0 }
                }), placeholder: "Message Codex…", label: "Message Codex",
                isSending: presentation.codexChat.isSending,
                isRunning: presentation.codexChat.isRunning && !presentation.codexChat.isSending,
                blocked: presentation.codexChat.requests.isEmpty ? nil : "Answer the request above first",
                onStop: { presentation.codexChat.interrupt() },
                claimsFocusOnCreation: !presentation.pane.showsTree,
                sendEnabled: !presentation.codexChat.isRunning,
                onSubmit: { _ in presentation.codexChat.submitRoot(pane: presentation.pane) }
            )
        }
        .padding(TFSpace.lg)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { presentation.footerHeight = $0 }
    }

    @ViewBuilder private var activityStatus: some View {
        if presentation.codexChat.isRunning {
            HStack(spacing: TFSpace.sm) {
                ProgressView().controlSize(.small)
                Text(presentation.codexChat.isPreparingHistory ? "Preparing conversation history…" : "Codex is working…")
                    .font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
            }
        }
    }

    private var deliveryError: some View {
        Group {
            if let message = presentation.codexChat.errorMessage {
                Text(message).font(TFFont.footnote).foregroundStyle(TFColor.textSecondary)
            }
        }
    }

    private func contextComposer(_ task: TaskforceKit.BackgroundTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !presentation.codexChat.requests.isEmpty {
                CodexChatPromptsView(chat: presentation.codexChat).padding(TFSpace.lg)
            }
            activityStatus.padding(.horizontal, TFSpace.lg)
            if presentation.codexChat.isRunning {
                Button("Stop") { presentation.codexChat.interrupt() }
                    .buttonStyle(TFButtonStyle(.secondary, size: .sm)).padding(.horizontal, TFSpace.lg)
            }
            if presentation.codexChat.errorMessage != nil {
                deliveryError.padding([.horizontal, .top], TFSpace.lg)
            }
            AgentTreeContextComposer(
                task: task,
                text: Binding(get: { presentation.codexChat.childDraft(for: task.id) }, set: { presentation.codexChat.setChildDraft($0, for: task.id) }),
                isSending: presentation.codexChat.isSending || presentation.codexChat.isRunning,
                onOpenMain: { presentation.pane.selectRootInTree() },
                onSubmit: { _ in presentation.codexChat.submitChild(task, pane: presentation.pane) }
            )
        }
    }
}
#endif
